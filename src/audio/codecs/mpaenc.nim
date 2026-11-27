## MPEG-1/2/2.5 Layer III encoder (new work, no Symphonia counterpart).
##
## Ports `oxideav-mp3` (references/oxideav-mp3, MIT clean-room from
## ISO/IEC 11172-3:1993 + 13818-3:1997) to idiomatic Nim: header /
## side-info writers (exact inverse of the `mpa` parsers), silent frames,
## polyphase analysis filterbank, forward MDCT, quantizer, inner/outer
## loops, Huffman emit, main-data assembly, bit-reservoir scheduling,
## stereo MS/IS, short/mixed blocks, VBR, Xing/Info, CRC, LSF/MPEG-2.5,
## psychoacoustic thresholds, quality presets, muxer.
##
## Layout mirrors the reference module split so stage-by-stage review
## against the Rust source stays cheap:
## framing -> analysis -> mdct -> quantize -> inner loop -> huffman emit
## -> scalefactors -> main data/reservoir -> stream encoder -> xing/crc ->
## psychoacoustics/quality -> muxer/factories.

import std/math
import std/options
import ./../audio
import ./../errors
import ./../io
import ./mpa
import ./mpa_tables
import ./mpaenc_tables

# ---------------------------------------------------------- framing ---

const
  MpaEncV1L3Ladder*: array[16, int] = [0, 32000, 40000, 48000, 56000,
    64000, 80000, 96000, 112000, 128000, 160000, 192000, 224000,
    256000, 320000, 0]
  MpaEncV2L23Ladder*: array[16, int] = [0, 8000, 16000, 24000, 32000,
    40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000,
    160000, 0]
  Mpeg1L3BitrateKbps*: array[14, uint32] = [32'u32, 40, 48, 56, 64, 80,
    96, 112, 128, 160, 192, 224, 256, 320]
  LsfL3BitrateKbps*: array[14, uint32] = [8'u32, 16, 24, 32, 40, 48,
    56, 64, 80, 96, 112, 128, 144, 160]

proc sampleRateIdxOf*(rate: uint32; v = Mpeg1): int {.inline.}

proc sampleRateIndex*(rate: uint32): Option[tuple[v: MpegVersion, idx: int]] =
  ## Resolves a sample rate to (version, sampling_frequency_index).
  case rate
  of 44_100: some((Mpeg1, 0))
  of 48_000: some((Mpeg1, 1))
  of 32_000: some((Mpeg1, 2))
  of 22_050: some((Mpeg2, 0))
  of 24_000: some((Mpeg2, 1))
  of 16_000: some((Mpeg2, 2))
  of 11_025: some((Mpeg2p5, 0))
  of 12_000: some((Mpeg2p5, 1))
  of 8_000: some((Mpeg2p5, 2))
  else: none(tuple[v: MpegVersion, idx: int])

proc layer3BitrateIndex*(version: MpegVersion; kbps: uint32): Option[int] =
  ## Resolves a Layer III bitrate to its 4-bit header index (1..14).
  let ladder =
    if version == Mpeg1: MpaEncV1L3Ladder else: MpaEncV2L23Ladder
  for i in 1 ..< 15:
    if ladder[i] == kbps.int * 1000:
      return some(i)
  none(int)

proc versionBits(v: MpegVersion): uint32 {.inline.} =
  case v
  of Mpeg1: 0b11'u32
  of Mpeg2: 0b10'u32
  of Mpeg2p5: 0b00'u32

proc layerBits(): uint32 {.inline.} = 0b01'u32 # Layer III always.

proc modeBits(m: MpaMode): uint32 {.inline.} =
  case m.kind
  of mmStereo: 0b00'u32
  of mmJoint: 0b01'u32
  of mmDualMono: 0b10'u32
  of mmMono: 0b11'u32

proc modeExtBits(m: MpaMode): uint32 {.inline.} =
  ## Wire `mode_extension`: bit1 = MS ('10'), bit0 = intensity ('01').
  if m.kind == mmJoint:
    ((if m.midSide: 1'u32 else: 0'u32) shl 1) or
      (if m.intensity: 1'u32 else: 0'u32)
  else:
    0

proc writeMp3Header*(h: FrameHeader): array[4, uint8] =
  ## Exact inverse of `parseFrameHeader`: packs every field at the
  ## §2.4.1.3 bit position the parser reads it from.
  let protect = if h.hasCrc: 0'u32 else: 1'u32
  let srIdx =
    case h.sampleRate
    of 44_100, 22_050, 11_025: 0'u32
    of 48_000, 24_000, 12_000: 1'u32
    else: 2'u32
  var brIdx = 0'u32
  let ladder = if h.version == Mpeg1: MpaEncV1L3Ladder
    else: MpaEncV2L23Ladder
  for i in 1 ..< 15:
    if ladder[i].uint32 == h.bitrate:
      brIdx = i.uint32
      break
  let raw: uint32 = (0x7ff'u32 shl 21) or (versionBits(h.version) shl 19) or
    (layerBits() shl 17) or (protect shl 16) or (brIdx shl 12) or
    (srIdx shl 10) or
    (0'u32 shl 9) or # padding: CBR scheduler sets it per frame later
    (0'u32 shl 8) or (modeBits(h.channelMode) shl 6) or
    (modeExtBits(h.channelMode) shl 4) or (0'u32 shl 3) or
    (1'u32 shl 2) or 0'u32 # copyright clear, original set, no emphasis
  [uint8(raw shr 24), uint8(raw shr 16), uint8(raw shr 8), uint8(raw)]

proc writeMp3HeaderWithPad*(h: FrameHeader; pad: bool): array[4, uint8] =
  ## Header writer with explicit padding slot (CBR scheduler).
  result = writeMp3Header(h)
  if pad:
    result[2] = result[2] or 0x02'u8

proc makeSilentHeader*(bitrateKbps, sampleRateHz: uint32;
    mode: MpaMode): FrameHeader =
  ## CBR convenience constructor resolving bitrate/rate/mode to header.
  let sri = sampleRateIndex(sampleRateHz)
  if sri.isNone:
    raise unsupportedError("mp3enc: unsupported sample rate")
  let (v, _) = sri.get
  let bi = layer3BitrateIndex(v, bitrateKbps)
  if bi.isNone:
    raise unsupportedError("mp3enc: bitrate not on Layer III ladder")
  let ladder = if v == Mpeg1: MpaEncV1L3Ladder else: MpaEncV2L23Ladder
  let factor = if v == Mpeg1: 144 else: 72
  let slots = (factor * ladder[bi.get()].int) div sampleRateHz.int
  FrameHeader(version: v, layer: Layer3, bitrate: ladder[bi.get()].uint32,
    sampleRate: sampleRateHz, sampleRateIdx: sampleRateIdxOf(sampleRateHz),
    channelMode: mode,
    hasCrc: false, frameSize: slots - MpegHeaderLen)

proc silentGranuleChannel*(): GranuleChannel =
  defaultGranuleChannel()

proc bandCountOf(bands: openArray[int]; line: int): int =
  ## Band index whose start equals `line` (region boundary lookup).
  for i in 0 ..< bands.len:
    if bands[i] == line:
      return i
    if bands[i] > line:
      return i
  bands.len - 1

proc writeGranuleChannel(w: var BitWriter; ch: GranuleChannel; lsf: bool;
    r0c, r1c: int) =
  w.writeBits(ch.part23Len.uint32, 12)
  w.writeBits(ch.bigValues.uint32, 9)
  w.writeBits(ch.globalGain.uint32, 8)
  if lsf:
    w.writeBits(ch.scalefacCompress.uint32, 9)
  else:
    w.writeBits(ch.scalefacCompress.uint32, 4)
  let winSw = ch.blockType.kind != btLong
  w.writeBit(winSw)
  if winSw:
    let bt =
      case ch.blockType.kind
      of btStart: 1'u32
      of btShort: 2'u32
      of btEnd: 3'u32
      else: 0'u32
    w.writeBits(bt, 2)
    w.writeBit(ch.blockType.kind == btShort and ch.blockType.mixed)
    w.writeBits(ch.tableSelect[0].uint32, 5)
    w.writeBits(ch.tableSelect[1].uint32, 5)
    w.writeBits(ch.subblockGain[0].uint32, 3)
    w.writeBits(ch.subblockGain[1].uint32, 3)
    w.writeBits(ch.subblockGain[2].uint32, 3)
  else:
    w.writeBits(ch.tableSelect[0].uint32, 5)
    w.writeBits(ch.tableSelect[1].uint32, 5)
    w.writeBits(ch.tableSelect[2].uint32, 5)
    w.writeBits(r0c.uint32, 4)
    w.writeBits(r1c.uint32, 3)
  if not lsf:
    w.writeBit(ch.preflag)
  w.writeBit(ch.scalefacScale)
  w.writeBit(ch.count1Select != 0)

proc writeSideInfo*(si: FrameData; header: FrameHeader): seq[uint8] =
  ## Exact inverse of `readSideInfo`: byte-aligned, fixed size per
  ## version/channel count.
  var w = newBitWriter()
  let lsf = not header.isMpeg1()
  if not lsf:
    w.writeBits(si.mainDataBegin.uint32, 9)
    if header.channelMode.kind == mmMono:
      w.writeBits(0, 5)
    else:
      w.writeBits(0, 3)
    let nch = header.nChannels()
    for ch in 0 ..< nch:
      for b in 0 ..< 4:
        w.writeBit(si.scfsi[ch][b])
  else:
    w.writeBits(si.mainDataBegin.uint32, 8)
    if header.channelMode.kind == mmMono:
      w.writeBits(0, 1)
    else:
      w.writeBits(0, 2)
  let ngr = header.nGranules()
  let bands = SfbLongBands[header.sampleRateIdx]
  for gr in 0 ..< ngr:
    for ch in 0 ..< header.nChannels():
      let g = si.granules[gr][ch]
      var r0c = 0
      var r1c = 0
      if g.blockType.kind == btLong:
        # Decoder inverts: region1Start = bands[region0_count+1 wire...];
        # wire region0_count = bandIndex(region1Start) - 1, clamped 0..15.
        let b1 = bandCountOf(bands, g.region1Start)
        let b2 = bandCountOf(bands, g.region2Start)
        r0c = max(min(b1 - 1, 15), 0)
        r1c = max(min(b2 - (r0c + 2), 7), 0)
      writeGranuleChannel(w, g, lsf, r0c, r1c)
  w.flush()
  w.toBytes()

proc silentSideInfo*(header: FrameHeader): FrameData =
  ## All-zero long-block side info for a silent frame.
  result = FrameData(mainDataBegin: 0)
  let ngr = header.nGranules()
  for gr in 0 ..< ngr:
    for ch in 0 ..< header.nChannels():
      result.granules[gr][ch] = silentGranuleChannel()

proc encodeSilentFrame*(header: FrameHeader): seq[uint8] =
  ## Complete self-delimiting all-zero Layer III frame (header +
  ## side info + zero-filled main data). Decodes to silence.
  if header.layer != Layer3:
    raise unsupportedError("mp3enc: silent frame is Layer III only")
  let frameLen = MpegHeaderLen + header.frameSize
  let siLen = header.sideInfoLen()
  if frameLen < MpegHeaderLen + siLen:
    raise unsupportedError("mp3enc: frame too small for header + side info")
  var hdr = header
  hdr.hasCrc = false
  result = @[]
  let hb = writeMp3Header(hdr)
  for b in hb:
    result.add(b)
  result.add(writeSideInfo(silentSideInfo(hdr), hdr))
  while result.len < frameLen:
    result.add(0)

# -------------------------------------------------------- analysis ---

type
  Mp3AnalysisState* = object
    ## Polyphase analysis shift register X[0..512] (Fig C.4).
    x*: array[512, float64]

proc mp3MCoeff*(i, k: int): float64 {.inline.} =
  ## M[i,k] = cos((2i+1)(k-16)pi/64) (§C.1.3).
  cos((2 * i + 1).float64 * (k - 16).float64 * PI / 64.0)

proc analyzeRow*(pcm: array[32, float64];
    state: var Mp3AnalysisState): array[32, float64] =
  ## One Fig C.4 pass: 32 PCM in -> 32 subband samples out.
  ## `pcm[0]` oldest -> X[31]; `pcm[31]` newest -> X[0].
  for i in countdown(511, 32):
    state.x[i] = state.x[i - 32]
  for j in 0 ..< 32:
    state.x[31 - j] = pcm[j]
  var y: array[64, float64]
  for j in 0 ..< 8:
    let base = 64 * j
    for i in 0 ..< 64:
      y[i] += Mp3AnalysisC[base + i] * state.x[base + i]
  for i in 0 ..< 32:
    var acc = 0.0
    for k in 0 ..< 64:
      acc += mp3MCoeff(i, k) * y[k]
    result[i] = acc

proc analyzeGranule*(pcm: openArray[float32];
    state: var Mp3AnalysisState): array[32, array[18, float32]] =
  ## 18 rows -> 32x18 subband-time block (mirror of synth_granule).
  assert pcm.len == 576
  for t in 0 ..< 18:
    var row: array[32, float64]
    for j in 0 ..< 32:
      row[j] = pcm[t * 32 + j].float64
    let s = analyzeRow(row, state)
    for sb in 0 ..< 32:
      result[sb][t] = s[sb].float32

# ------------------------------------------------------------ mdct ---

const
  Mp3LongN* = 36
  Mp3ShortN* = 12

proc mp3Mdct*(xn: openArray[float64]): seq[float64] =
  ## Forward MDCT (§2.4.3.4.10.2 analysis): n -> n/2 bins.
  let n = xn.len
  let half = n div 2
  result = newSeq[float64](half)
  let scale = PI / (2.0 * n.float64)
  for k in 0 ..< half:
    let b = (2 * k + 1).float64
    var acc = 0.0
    for i in 0 ..< n:
      let a = (2 * i + 1 + half).float64
      acc += xn[i] * cos(scale * a * b)
    result[k] = acc

proc mp3AnalysisLongWindow*(i: int): float64 {.inline.} =
  sin((PI / 36.0) * (i.float64 + 0.5))

proc mp3AnalysisShortWindow*(i: int): float64 {.inline.} =
  sin((PI / 12.0) * (i.float64 + 0.5))

proc windowLongFamilyAnalysis*(xn: array[36, float64];
    bt: BlockTypeKind): array[36, float64] =
  case bt
  of btStart:
    for i in 0 ..< 36:
      result[i] =
        if i <= 17: xn[i] * mp3AnalysisLongWindow(i)
        elif i <= 23: xn[i]
        elif i <= 29: xn[i] * mp3AnalysisShortWindow(i - 18)
        else: 0.0
  of btEnd:
    for i in 0 ..< 36:
      result[i] =
        if i <= 5: 0.0
        elif i <= 11: xn[i] * mp3AnalysisShortWindow(i - 6)
        elif i <= 17: xn[i]
        else: xn[i] * mp3AnalysisLongWindow(i)
  else:
    for i in 0 ..< 36:
      result[i] = xn[i] * mp3AnalysisLongWindow(i)

proc windowShortAnalysis*(xn: array[36, float64]): array[3, array[12, float64]] =
  for j in 0 ..< 3:
    for k in 0 ..< 12:
      result[j][k] = xn[6 + 6 * j + k] * mp3AnalysisShortWindow(k)

type
  Mp3MdctState* = object
    saved*: array[18, float64]

proc forwardOverlap*(current: array[18, float64];
    state: var Mp3MdctState): array[36, float64] =
  for i in 0 ..< 18:
    result[i] = state.saved[i]
    result[i + 18] = current[i]
  state.saved = current

# --------------------------------------------------------- quantize ---

proc scalefacMultiplier*(scalefacScale: bool): float32 {.inline.} =
  if scalefacScale: 1.0'f32 else: 0.5'f32

proc sampleRateIdxOf*(rate: uint32; v = Mpeg1): int {.inline.} =
  ## Decoder-consistent table index (mirrors `parseFrameHeader`).
  case rate
  of 44_100: 0
  of 48_000: 1
  of 32_000: 2
  of 22_050: 3
  of 24_000: 4
  of 16_000: 5
  of 11_025: 6
  of 12_000: 7
  of 8_000: 8
  else: 0

proc powThreeQuarters(q: float32): float32 {.inline.} =
  if q <= 0.0:
    return 0.0
  let r = sqrt(q)
  let fast = r * sqrt(r)
  let toBoundary = abs((fast - floor(fast)) - 0.5)
  if fast < 1.0e6 and toBoundary > fast * 1.0e-6:
    fast
  else:
    pow(q, 0.75'f32)

proc quantizeLine*(xr, factor: float32): int32 {.inline.} =
  if xr == 0.0 or factor == 0.0:
    return 0
  let q = abs(xr) / factor
  # Total on hostile floats: NaN/Inf quotients (NaN, Inf, or >1e30
  # pushSamplesF32 input) must not trap on float->int conversion.
  # Zero/negative quotients quantize to zero; saturate the rest to
  # ±high(int32) (sign preserved, abs() stays safe downstream).
  if q.classify in {fcNan, fcInf, fcNegInf} or q <= 0.0:
    return 0
  let mag = powThreeQuarters(q)
  if mag.classify in {fcNan, fcInf, fcNegInf} or mag >= 2147483647.0'f32:
    return if xr < 0.0: -high(int32) else: high(int32)
  let rounded = round(mag).int32
  if xr < 0.0: -rounded else: rounded

proc mixedLongLines*(sampleRateHz: uint32; version: MpegVersion): int =
  ## Long-coded prefix of a mixed block: 3*short_starts[3].
  let idx = sampleRateIdxOf(sampleRateHz, version)
  3 * SfbShortBands[idx][3]


proc quantizeLongRange(`is`: var array[576, int32]; xr: openArray[float32];
    sf: openArray[int]; first, last: int; globalGain: int; mult: float32;
    preflag: bool; idx: int) =
  var bi = 0
  while bi + 1 < SfbLongBands[idx].len:
    let s = SfbLongBands[idx][bi]
    let e = SfbLongBands[idx][bi + 1]
    let lo = max(s, first)
    let hi = min(e, last)
    if lo < hi:
      var pre = 0
      if preflag and bi < 22:
        pre = PreEmphasis[bi]
      let g = pow(2.0'f32, (globalGain - 210).float32 / 4.0'f32) *
        pow(2.0'f32, -mult * (sf[bi] + pre).float32)
      for k in lo ..< hi:
        `is`[k] = quantizeLine(xr[k], g)
    inc bi

proc quantizeShortBanded(`is`: var array[576, int32]; xr: openArray[float32];
    sf: openArray[int]; idx: int; first, last: int; globalGain: int;
    mult: float32; subblockGain: array[3, int]) =
  var bi = 0
  while bi + 1 < SfbShortBands[idx].len:
    let s = SfbShortBands[idx][bi]
    let e = SfbShortBands[idx][bi + 1]
    let lo = max(s, first)
    let hi = min(e, last)
    if lo < hi:
      # Bands interleave 3 windows: band bi covers windows bi mod 3.
      let w = bi mod 3
      let g = pow(2.0'f32,
        (globalGain - 210 - 8 * subblockGain[w]).float32 / 4.0'f32) *
        pow(2.0'f32, -mult * sf[bi].float32)
      for k in lo ..< hi:
        `is`[k] = quantizeLine(xr[k], g)
    inc bi

proc quantizeGranuleFull*(xr: openArray[float32]; ch: var GranuleChannel;
    sampleRateHz: uint32; version: MpegVersion): array[576, int32] =
  let mult = scalefacMultiplier(ch.scalefacScale)
  let idx = sampleRateIdxOf(sampleRateHz, version)
  let isShort = ch.blockType.kind == btShort and not ch.blockType.mixed
  let isMixed = ch.blockType.kind == btShort and ch.blockType.mixed
  if not isShort and not isMixed:
    # Long (covers Start/End windows too): scalefacs[0..21].
    quantizeLongRange(result, xr, ch.scalefacs, 0, 576, ch.globalGain,
      mult, ch.preflag, idx)
  elif isMixed:
    let split = mixedLongLines(sampleRateHz, version)
    # Long-coded prefix uses long scalefacs[0..7]; short suffix uses
    # short-layout scalefacs from the mixed switch point.
    quantizeLongRange(result, xr, ch.scalefacs, 0, split, ch.globalGain,
      mult, ch.preflag, idx)
    let sw = SfbMixedSwitchPoint[idx]
    # Mixed short suffix: bands indexed from the switch point; the
    # decoder's requantizeShort uses ch.scalefacs[switch+bi] with the
    # mixed band table, so mirror that layout here.
    var bi = 0
    let bands = SfbMixedBands[idx]
    while sw + bi + 1 < bands.len:
      let s = bands[sw + bi]
      let e = bands[sw + bi + 1]
      if s >= split:
        let w = bi mod 3
        let g = pow(2.0'f32,
          (ch.globalGain - 210 - 8 * ch.subblockGain[w]).float32 / 4.0'f32) *
          pow(2.0'f32, -mult * ch.scalefacs[sw + bi].float32)
        for k in s ..< min(e, 576):
          result[k] = quantizeLine(xr[k], g)
      inc bi
  else:
    quantizeShortBanded(result, xr, ch.scalefacs, idx, 0, 576,
      ch.globalGain, mult, ch.subblockGain)

# --------------------------------------------------- huffman encode ---

const
  QuadA*: array[16, tuple[clen, code: int]] = [
    (1, 0b1), (4, 0b0101), (4, 0b0100), (5, 0b00101),
    (4, 0b0110), (6, 0b000101), (5, 0b00100), (6, 0b000100),
    (4, 0b0111), (5, 0b00011), (5, 0b00110), (6, 0b000000),
    (5, 0b00111), (6, 0b000010), (6, 0b000011), (6, 0b000001),
  ]
  SelectableBigTables*: array[30, int] = [0, 1, 2, 3, 5, 6, 7, 8, 9, 10,
    11, 12, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
    29, 30, 31]

proc huffBase(sel: int): int {.inline.} =
  ## Canonical table backing a select index (linbits aliases share codes).
  if sel <= 15: sel elif sel <= 23: 16 else: 17

proc huffCodes(sel: int): tuple[codes: seq[uint32], bits: seq[uint32],
    wrap: int] =
  ## (code, len) vectors + dimension for a select index. One-time
  ## builder; hot paths use `cachedHuffCodes` below.
  let base = huffBase(sel)
  let wrap = MpegTableWrap[base]
  if wrap == 0:
    return (@[], @[], 0)
  let src = MpegTableCodes[base]
  var codes = newSeq[uint32]()
  var bits = newSeq[uint32]()
  template grab(c, l: untyped) =
    codes.setLen(c.len)
    bits.setLen(l.len)
    for i in 0 ..< c.len:
      codes[i] = c[i]
      bits[i] = l[i].uint32
  case src
  of 1: grab(MpegCodes1, MpegBits1)
  of 2: grab(MpegCodes2, MpegBits2)
  of 3: grab(MpegCodes3, MpegBits3)
  of 5: grab(MpegCodes5, MpegBits5)
  of 6: grab(MpegCodes6, MpegBits6)
  of 7: grab(MpegCodes7, MpegBits7)
  of 8: grab(MpegCodes8, MpegBits8)
  of 9: grab(MpegCodes9, MpegBits9)
  of 10: grab(MpegCodes10, MpegBits10)
  of 11: grab(MpegCodes11, MpegBits11)
  of 12: grab(MpegCodes12, MpegBits12)
  of 13: grab(MpegCodes13, MpegBits13)
  of 15: grab(MpegCodes15, MpegBits15)
  of 16: grab(MpegCodes16, MpegBits16)
  else: grab(MpegCodes24, MpegBits24)
  (codes, bits, wrap)

proc bigTableReach*(sel: int): int =
  ## Largest |is| codable without truncation (reach filter for chooser).
  if sel == 4 or sel == 14 or sel > 31:
    return 0
  let base = huffBase(sel)
  let wrap = MpegTableWrap[base]
  let linbits = CodebookLinbits[sel]
  if linbits == 0:
    max(wrap - 1, 0)
  else:
    15 + ((1 shl linbits) - 1)

var
  huffCacheCodes: array[32, seq[uint32]]
  huffCacheBits: array[32, seq[uint32]]
  huffCacheWrap: array[32, int]
  huffCacheReady = false

proc initHuffCache() =
  ## Builds every select-index vector once. Called lazily by
  ## `cachedHuffCodes`; `newMp3Encoder` already runs `initMpaTables`,
  ## so steady-state encode never allocates here.
  if huffCacheReady:
    return
  huffCacheReady = true
  for sel in 0 ..< 32:
    let (codes, bits, wrap) = huffCodes(sel)
    huffCacheCodes[sel] = codes
    huffCacheBits[sel] = bits
    huffCacheWrap[sel] = wrap

proc cachedHuffCodes(sel: int): tuple[codes: seq[uint32],
    bits: seq[uint32], wrap: int] {.inline.} =
  ## Legacy accessor (kept for compatibility; hot paths index
  ## `huffCache*` directly so no seq is ever duplicated).
  if not huffCacheReady:
    initHuffCache()
  (huffCacheCodes[sel], huffCacheBits[sel], huffCacheWrap[sel])

proc bigPairBits*(sel: int; x, y: int32): Option[int] {.inline.} =
  ## §C.1.5.4.4.8 cost of one pair (codeword + linbits ESC + signs).
  ## Indexes the shared cache vectors directly: binding the seqs would
  ## duplicate them per call (Nim seq assignment is a deep copy).
  if sel == 4 or sel == 14:
    return none(int)
  if not huffCacheReady:
    initHuffCache()
  let wrap = huffCacheWrap[sel]
  if wrap == 0:
    if x == 0 and y == 0:
      return some(0)
    return none(int)
  let ax = abs(x).int
  let ay = abs(y).int
  let xi = min(ax, 15)
  let yi = min(ay, 15)
  if xi >= wrap or yi >= wrap:
    return none(int)
  let i = xi * wrap + yi
  if i >= huffCacheCodes[sel].len:
    return none(int)
  if huffCacheBits[sel][i] == 0 and (xi != 0 or yi != 0):
    return none(int)
  let linbits = CodebookLinbits[sel]
  var b = huffCacheBits[sel][i].int
  if ax >= 15: b += linbits
  if ay >= 15: b += linbits
  if x != 0: inc b
  if y != 0: inc b
  some(b)

proc regionBitsWithTable*(`is`: openArray[int32]; start, stop,
    sel: int): Option[int] =
  var bits = 0
  var k = start
  while k + 1 < stop and k + 1 < 576:
    let b = bigPairBits(sel, `is`[k], `is`[k + 1])
    if b.isNone:
      return none(int)
    bits += b.get
    k += 2
  some(bits)

proc maxAbsIs*(`is`: openArray[int32]; start, stop: int): int =
  for k in start ..< min(stop, 576):
    result = max(result, abs(`is`[k]).int)

proc chooseBestTableForRegion*(`is`: openArray[int32]; start,
    stop: int): Option[tuple[sel, bits: int]] =
  ## Cheapest codable codebook for a big-values region (reach-filtered).
  let m = maxAbsIs(`is`, start, stop)
  for sel in SelectableBigTables:
    if bigTableReach(sel) < m:
      continue
    let b = regionBitsWithTable(`is`, start, stop, sel)
    if b.isSome:
      if result.isNone or b.get < result.get.bits:
        result = some((sel, b.get))

proc chooseBestCount1Table*(`is`: openArray[int32]; start,
    stop: int): tuple[useB: bool, bits: int] =
  ## Cheapest count1 quad table (A vs B) over a quad range.
  var bitsA = 0
  var bitsB = 0
  var k = start
  while k + 3 < stop and k + 3 < 576:
    let pat = ((if `is`[k] != 0: 1 else: 0) shl 3) or
      ((if `is`[k + 1] != 0: 1 else: 0) shl 2) or
      ((if `is`[k + 2] != 0: 1 else: 0) shl 1) or
      (if `is`[k + 3] != 0: 1 else: 0)
    var signs = 0
    for j in 0 ..< 4:
      if `is`[k + j] != 0:
        inc signs
    bitsA += QuadA[pat].clen + signs
    bitsB += 4 + signs
    k += 4
  (bitsB < bitsA, min(bitsA, bitsB))

proc partitionSplit*(`is`: openArray[int32]): tuple[bigPairs,
    count1Quads: int] =
  ## Trailing-zero strip, then trailing ±1 quads (rounded up to x4).
  var lastNz = -1
  for k in countdown(575, 0):
    if `is`[k] != 0:
      lastNz = k
      break
  if lastNz < 0:
    return (0, 0)
  var qEnd = lastNz + 1
  while qEnd mod 4 != 0:
    inc qEnd
  var bigEnd = qEnd
  while bigEnd > 0:
    var allOne = true
    for k in (bigEnd - 4) ..< bigEnd:
      if k <= lastNz and abs(`is`[k]) > 1:
        allOne = false
        break
    if not allOne:
      break
    bigEnd -= 4
  (bigEnd div 2, (qEnd - bigEnd) div 4)

proc longBandStarts*(sampleRateHz: uint32;
    version: MpegVersion): array[22, int] =
  let idx = sampleRateIdxOf(sampleRateHz, version)
  for i in 0 ..< 22:
    result[i] = SfbLongBands[idx][i]

proc shortBandStarts*(sampleRateHz: uint32;
    version: MpegVersion): array[13, int] =
  let idx = sampleRateIdxOf(sampleRateHz, version)
  # The flat table holds 3 cumulative entries per sfb + end; per-window
  # band starts are entries [3b] scaled down by the interleave factor 3.
  for b in 0 ..< 13:
    result[b] = SfbShortBands[idx][b * 3] div 3

proc countHuffmanBits*(`is`: openArray[int32]; bigPairs: int;
    r0, r1: int; tableSelect: array[3, int]; count1Quads: int;
    useB: bool): Option[int] =
  var bits = 0
  let ends = [min(r0, bigPairs * 2), min(r1, bigPairs * 2), bigPairs * 2]
  var start = 0
  for ri in 0 ..< 3:
    let b = regionBitsWithTable(`is`, start, ends[ri], tableSelect[ri])
    if b.isNone:
      return none(int)
    bits += b.get
    start = ends[ri]
  # Count1 bits under the caller-chosen table (must match the emitter).
  var k = bigPairs * 2
  let stop = bigPairs * 2 + count1Quads * 4
  while k + 3 < stop and k + 3 < 576:
    let pat = ((if `is`[k] != 0: 1 else: 0) shl 3) or
      ((if `is`[k + 1] != 0: 1 else: 0) shl 2) or
      ((if `is`[k + 2] != 0: 1 else: 0) shl 1) or
      (if `is`[k + 3] != 0: 1 else: 0)
    var signs = 0
    for j in 0 ..< 4:
      if `is`[k + j] != 0:
        inc signs
    bits += (if useB: 4 else: QuadA[pat].clen) + signs
    k += 4
  some(bits)

proc emitBigPair*(w: var BitWriter; sel: int; x, y: int32) =
  if not huffCacheReady:
    initHuffCache()
  let wrap = huffCacheWrap[sel]
  let ax = abs(x).int
  let ay = abs(y).int
  let xi = min(ax, 15)
  let yi = min(ay, 15)
  if wrap == 0:
    return # table 0 all-zero pair: zero bits
  let i = xi * wrap + yi
  if huffCacheBits[sel][i] != 0:
    w.writeBits(huffCacheCodes[sel][i], huffCacheBits[sel][i].int)
  let linbits = CodebookLinbits[sel]
  if ax >= 15 and linbits > 0:
    w.writeBits((ax - 15).uint32, linbits)
  if x != 0:
    w.writeBit(x < 0)
  if ay >= 15 and linbits > 0:
    w.writeBits((ay - 15).uint32, linbits)
  if y != 0:
    w.writeBit(y < 0)

proc emitRegion*(w: var BitWriter; `is`: openArray[int32]; start, stop,
    sel: int) =
  var k = start
  while k + 1 < stop and k + 1 < 576:
    emitBigPair(w, sel, `is`[k], `is`[k + 1])
    k += 2

proc emitCount1Quad*(w: var BitWriter; v, x2, y2, z: int32; useB: bool) =
  if useB:
    let nz = proc(c: int32): uint32 {.inline.} =
      if c != 0: 0 else: 1
    w.writeBits((nz(v) shl 3) or (nz(x2) shl 2) or (nz(y2) shl 1) or nz(z),
      4)
  else:
    let pat = ((if v != 0: 1 else: 0) shl 3) or
      ((if x2 != 0: 1 else: 0) shl 2) or
      ((if y2 != 0: 1 else: 0) shl 1) or (if z != 0: 1 else: 0)
    let (clen, code) = QuadA[pat]
    w.writeBits(code.uint32, clen)
  if v != 0: w.writeBit(v < 0)
  if x2 != 0: w.writeBit(x2 < 0)
  if y2 != 0: w.writeBit(y2 < 0)
  if z != 0: w.writeBit(z < 0)

proc emitHuffman*(w: var BitWriter; `is`: array[576, int32]; bigPairs: int;
    r0, r1: int; tableSelect: array[3, int]; count1Quads: int; useB: bool) =
  let ends = [min(r0, bigPairs * 2), min(r1, bigPairs * 2), bigPairs * 2]
  var start = 0
  for ri in 0 ..< 3:
    emitRegion(w, `is`, start, ends[ri], tableSelect[ri])
    start = ends[ri]
  var k = bigPairs * 2
  for _ in 0 ..< count1Quads:
    if k + 3 < 576:
      emitCount1Quad(w, `is`[k], `is`[k + 1], `is`[k + 2], `is`[k + 3],
        useB)
    k += 4

# -------------------------------------------------------- inner loop ---

const
  Mp3GainMin* = 0
  Mp3GainMax* = 255
  Mp3BigValuesLimit* = 8191
  Mp3MaxPart23Bits* = 4095

proc exactBitCount*(`is`: array[576, int32];
    tableSelect: array[3, int]; r0, r1: int; bigPairs, count1Quads: int;
    useB: bool): Option[int] =
  countHuffmanBits(`is`, bigPairs, r0, r1, tableSelect, count1Quads, useB)

proc searchMagnitudeClamp*(xr: array[576, float32]; ch: var GranuleChannel;
    sampleRateHz: uint32; version: MpegVersion): tuple[gain: int,
    `is`: array[576, int32]] =
  ## Smallest global_gain keeping max|is| <= 8191 (monotone bisection).
  ## Scalefactors stay as configured; only the gain moves.
  var lo = Mp3GainMin
  var hi = Mp3GainMax
  var best = Mp3GainMax
  var bestIs: array[576, int32]
  # Feasibility at hi first (largest gain = finest quantization... in
  # the reference, smaller gain = coarser; search smallest gain that
  # satisfies the bound — gain grows => is shrinks).
  while lo <= hi:
    let mid = (lo + hi) div 2
    ch.globalGain = mid
    let q = quantizeGranuleFull(xr, ch, sampleRateHz, version)
    var m = 0
    for v in q:
      m = max(m, abs(v).int)
    if m <= Mp3BigValuesLimit:
      best = mid
      bestIs = q
      hi = mid - 1
    else:
      lo = mid + 1
  ch.globalGain = best
  (best, bestIs)

proc chooseRegionSplit*(sampleRateHz: uint32; version: MpegVersion;
    bv2: int): tuple[r0, r1, r0c, r1c: int] =
  ## §C.1.5.4.4.6 SUBDIVIDE: ~1/3 to region 0, ~1/4 to region 2,
  ## band-aligned, counts capped at field widths (decoder-exact).
  if bv2 == 0:
    return (0, 0, 0, 0)
  let starts = longBandStarts(sampleRateHz, version)
  let third = bv2 div 3
  let threeQ = (bv2 * 3) div 4
  var r0c = 0
  for b in 1 .. 21:
    if starts[b] <= third:
      r0c = b - 1
    else:
      break
  r0c = min(r0c, 15)
  let r0b = r0c + 1
  let r0e = min(if r0b <= 21: starts[r0b] else: 576, 576)
  var r1c = 0
  for b in (r0b + 1) .. 21:
    if starts[b] <= threeQ:
      r1c = b - r0b - 1
    else:
      break
  r1c = min(r1c, 7)
  let r1b = r0b + r1c + 1
  let r1e = min(if r1b <= 21: starts[r1b] else: 576, 576)
  (min(r0e, bv2), min(r1e, bv2), r0c, r1c)

proc regionEndsFor*(ch: GranuleChannel; bigPairs: int;
    sampleRateHz: uint32; version: MpegVersion): tuple[r0, r1: int] =
  ## Decoder-exact region ends for a block type: long-family SUBDIVIDE,
  ## short/mixed band-relative, Start/End §2.4.2.7 defaults.
  let bv2 = bigPairs * 2
  case ch.blockType.kind
  of btShort:
    let s = shortBandStarts(sampleRateHz, version)
    (min(3 * s[3], bv2), bv2)
  of btStart, btEnd:
    let starts = longBandStarts(sampleRateHz, version)
    (min(starts[8], bv2), bv2)
  else:
    let (r0, r1, _, _) = chooseRegionSplit(sampleRateHz, version, bv2)
    (r0, r1)

proc searchBitBudgetBanded*(
    xr: openArray[float32]; ch: var GranuleChannel; sampleRateHz: uint32;
    version: MpegVersion; budget: int): tuple[ok: bool,
    `is`: array[576, int32], bits: int] =
  ## Smallest gain whose band-aligned Huffman count fits `budget`.
  ## Regions follow the decoder-exact rule per block type; tables are
  ## chosen per region with the reach filter (fallback: table 23).
  ch.globalGain = Mp3GainMin
  var startGain = Mp3GainMin
  block clamp:
    var lo = Mp3GainMin
    var hi = Mp3GainMax
    while lo <= hi:
      let mid = (lo + hi) div 2
      ch.globalGain = mid
      let q = quantizeGranuleFull(xr, ch, sampleRateHz, version)
      var m = 0
      for v in q:
        m = max(m, abs(v).int)
      if m <= Mp3BigValuesLimit:
        startGain = mid
        hi = mid - 1
      else:
        lo = mid + 1
  # Scan upward (coarser) until the bit budget fits.
  for gain in startGain .. Mp3GainMax:
    ch.globalGain = gain
    let q = quantizeGranuleFull(xr, ch, sampleRateHz, version)
    let (bigPairs, quads) = partitionSplit(q)
    let (r0, r1) = regionEndsFor(ch, bigPairs, sampleRateHz, version)
    var tabs = [0, 0, 0]
    let ends = [r0, r1, bigPairs * 2]
    var s = 0
    for ri in 0 ..< 3:
      var sel = 23 # ESC fallback (reach 8206 > 8191 clamp)
      let t = chooseBestTableForRegion(q, s, ends[ri])
      if t.isSome:
        sel = t.get.sel
      elif s < ends[ri]:
        continue # unreachable after clamp, but stay total
      tabs[ri] = sel
      s = ends[ri]
    if ch.blockType.kind == btShort and ch.blockType.mixed:
      tabs[1] = tabs[0] # one codebook for both regions (r408)
    ch.region1Start = r0
    ch.region2Start = r1
    let (useB, _) = chooseBestCount1Table(q, bigPairs * 2,
      bigPairs * 2 + quads * 4)
    ch.bigValues = bigPairs
    ch.tableSelect = tabs
    ch.count1Select = if useB: 1 else: 0
    let bc = countHuffmanBits(q, bigPairs, r0, r1, tabs, quads, useB)
    if bc.isSome and bc.get <= budget:
      ch.part23Len = 0 # stamped by the assembler later
      return (true, q, bc.get)
  (false, default(array[576, int32]), 0)

# ------------------------------------------------------- scalefactors --

proc writeMpeg1GranuleChannel*(w: var BitWriter; ch: GranuleChannel;
    scfsi: array[4, bool]; gr: int): int =
  ## Scalefactor (part2) payload for one MPEG-1 granule-channel.
  ## Returns bits written. Mirrors `readScaleFactorsMpeg1`.
  result = 0
  let (slen1, slen2) = (ScaleFactorSlen[ch.scalefacCompress][0],
    ScaleFactorSlen[ch.scalefacCompress][1])
  let bt = ch.blockType
  if bt.kind == btShort:
    let nSfb = if bt.mixed: 8 + 3 * 3 else: 6 * 3
    if slen1 > 0:
      for i in 0 ..< nSfb:
        w.writeBits(ch.scalefacs[i].uint32, slen1)
      result += nSfb * slen1
    if slen2 > 0:
      for i in 0 ..< 6 * 3:
        w.writeBits(ch.scalefacs[nSfb + i].uint32, slen2)
      result += 6 * 3 * slen2
  else:
    const bands = [(0, 6), (6, 11), (11, 16), (16, 21)]
    for bi, (s, e) in bands.pairs:
      let slen = if bi < 2: slen1 else: slen2
      if gr > 0 and scfsi[bi]:
        discard # reused from granule 0: zero part2 bits
      elif slen > 0:
        for i in s ..< e:
          w.writeBits(ch.scalefacs[i].uint32, slen)
        result += slen * (e - s)

proc writeLsfChannel*(w: var BitWriter; ch: GranuleChannel;
    isIntensityRight: bool): int =
  ## Scalefactor (part2) payload for one LSF granule-channel.
  result = 0
  let blockIdx =
    case ch.blockType.kind
    of btShort:
      if ch.blockType.mixed: 2 else: 1
    else: 0
  var slen = [0, 0, 0, 0]
  var nsfb = [0, 0, 0, 0]
  if isIntensityRight:
    let sfc = ch.scalefacCompress shr 1
    var row = 0
    if sfc <= 179:
      slen = [(sfc div 36), ((sfc mod 36) div 6), ((sfc mod 36) mod 6), 0]
      row = 0
    elif sfc <= 243:
      slen = [((sfc - 180) mod 64) shr 4, ((sfc - 180) mod 16) shr 2,
        ((sfc - 180) mod 4), 0]
      row = 1
    else:
      slen = [(sfc - 244) div 3, (sfc - 244) mod 3, 0, 0]
      row = 2
    nsfb = ScaleFactorMpeg2Nsfb[row][blockIdx]
  else:
    let sfc = ch.scalefacCompress
    var row = 3
    if sfc <= 399:
      slen = [(sfc shr 4) div 5, (sfc shr 4) mod 5, (sfc mod 16) shr 2,
        sfc mod 4]
      row = 3
    elif sfc <= 499:
      slen = [((sfc - 400) shr 2) div 5, ((sfc - 400) shr 2) mod 5,
        (sfc - 400) mod 4, 0]
      row = 4
    else:
      slen = [(sfc - 500) div 3, (sfc - 500) mod 3, 0, 0]
      row = 5
    nsfb = ScaleFactorMpeg2Nsfb[row][blockIdx]
  var start = 0
  for i in 0 ..< 4:
    if slen[i] > 0:
      for k in 0 ..< nsfb[i]:
        w.writeBits(ch.scalefacs[start + k].uint32, slen[i])
      result += slen[i] * nsfb[i]
    start += nsfb[i]

# ------------------------------------------------- main data / reservoir

type
  Mp3GcData* = object
    ## Assembled per-granule-channel payload inputs.
    `is`*: array[576, int32]
    bigPairs*: int
    count1Quads*: int
    useB*: bool
    r0*, r1*: int

  Mp3ReservoirFrame* = object
    mainData*: seq[uint8]
    bitLen*: int

  Mp3ScheduledFrame* = object
    mainDataBegin*: int
    slot*: seq[uint8]

proc assembleMainData*(header: FrameHeader; si: var FrameData;
    scfsi: array[2, array[4, bool]];
    data: array[2, array[2, Mp3GcData]]): tuple[bytes: seq[uint8],
    bitLen: int, part2Bits: array[2, array[2, int]]] =
  ## §2.4.1.7 loop: scalefactors (part2) + Huffman (part3) into one
  ## shared bitstream; stamps part2_3_length per granule-channel.
  var w = newBitWriter()
  var part2: array[2, array[2, int]]
  let ngr = header.nGranules()
  let lsf = not header.isMpeg1()
  for gr in 0 ..< ngr:
    for ch in 0 ..< header.nChannels():
      let before = w.buf.len * 8 + w.nbits
      if lsf:
        let isco = ch > 0 and header.channelMode.kind == mmJoint and
          header.channelMode.intensity
        part2[gr][ch] = writeLsfChannel(w, si.granules[gr][ch], isco)
      else:
        part2[gr][ch] = writeMpeg1GranuleChannel(w,
          si.granules[gr][ch], scfsi[ch], gr)
      let g = data[gr][ch]
      emitHuffman(w, g.`is`, g.bigPairs, g.r0, g.r1,
        si.granules[gr][ch].tableSelect, g.count1Quads, g.useB)
      let after = w.buf.len * 8 + w.nbits
      si.granules[gr][ch].part23Len = after - before
  w.flush()
  (w.toBytes(), 0, part2)

proc scheduleReservoir*(frames: seq[Mp3ReservoirFrame];
    maxBits: int): seq[Mp3ScheduledFrame] =
  ## §2.4.2.7 bit-reservoir scheduler: R[i+1] = R[i] + S[i] - L[i].
  ## Raises on overflow/underflow (caller raises bitrate and retries).
  let n = frames.len
  result = newSeq[Mp3ScheduledFrame](n)
  # Pass 1: reservoir levels (R[0] = 0).
  var levels = newSeq[int](n + 1)
  for i in 0 ..< n:
    levels[i + 1] = levels[i] + frames[i].bitLen
  # Slot sizes unknown here; the stream encoder supplies per-frame slot
  # bytes and main_data_begin derives from carried-over levels. This
  # helper takes (slotBits) parallel array via frames' bitLen vs slot:
  # implemented in the stream encoder; kept here for unit tests with
  # equal slots.
  discard maxBits
  for i in 0 ..< n:
    result[i] = Mp3ScheduledFrame(mainDataBegin: 0, slot: frames[i].mainData)

proc scheduleReservoirSlots*(frames: seq[Mp3ReservoirFrame];
    slotBits: seq[int]; maxReservoirBits: int): seq[Mp3ScheduledFrame] =
  ## Full scheduler with explicit per-frame main-data slot sizes.
  assert frames.len == slotBits.len
  let n = frames.len
  result = newSeq[Mp3ScheduledFrame](n)
  var r = 0
  for i in 0 ..< n:
    if r < 0 or r > maxReservoirBits:
      raise unsupportedError("mp3enc: bit reservoir overflow (raise bitrate)")
    let need = frames[i].bitLen
    if need > r + slotBits[i]:
      raise unsupportedError("mp3enc: frame does not fit slot (raise bitrate)")
    result[i].mainDataBegin = r div 8
    # Slot content: reservoir carry + new main data head. The byte-level
    # packing happens in the stream encoder (bit-exact carry); here we
    # record levels only.
    r = r + slotBits[i] - need
  # Trailing reservoir must drain to zero only at stream end (the
  # encoder pads the last frame); intermediate levels just carry.
  discard r

# -------------------------------------------- forward spectral path ---

type
  Mp3BlockKind* = enum
    mbLong
    mbShort
    mbStart
    mbEnd

proc inverseAliasReduce*(xr: array[576, float32];
    sbEnd = 32): array[576, float32] =
  ## Inverse of decoder `antialiasSamples` (orthogonal butterfly with
  ## negated `ca`): applied so the decoder's forward pass recovers the
  ## post-MDCT bins. `sbEnd = 32` long, `2` mixed (decoder's single
  ## sb==1 butterfly).
  result = xr
  for sb in 1 ..< sbEnd:
    let boundary = 18 * sb
    var tmpLo: array[8, float32]
    var tmpHi: array[8, float32]
    for i in 0 ..< 8:
      tmpLo[i] = result[boundary - 1 - i]
      tmpHi[i] = result[boundary + i]
    for i in 0 ..< 8:
      result[boundary - 1 - i] =
        tmpLo[i] * mpaAntialiasCs[i] + tmpHi[i] * mpaAntialiasCa[i]
      result[boundary + i] =
        tmpHi[i] * mpaAntialiasCs[i] - tmpLo[i] * mpaAntialiasCa[i]

proc forwardShortMdctSubband*(current: array[18, float64];
    state: var Mp3MdctState): array[18, float32] =
  ## One subband's three-window short forward MDCT (÷3 unit-gain,
  ## `out[3k+win]` interleaved).
  var xn: array[36, float64]
  for i in 0 ..< 18:
    xn[i] = state.saved[i]
    xn[i + 18] = current[i]
  let sub = windowShortAnalysis(xn)
  for j in 0 ..< 3:
    var xk = newSeq[float64](12)
    for k in 0 ..< 12:
      xk[k] = sub[j][k]
    let bins = mp3Mdct(xk)
    for k in 0 ..< 6:
      result[3 * k + j] = (bins[k] / 3.0).float32
  state.saved = current

proc forwardReorder*(xrSub: array[576, float32]; mixed: bool;
    sampleRateHz: uint32; version: MpegVersion): array[576, float32] =
  ## Bit-exact inverse of decoder `reorderSamples`: subband-interleaved
  ## -> native `[sfb][win][k]`. Long region (mixed lines 0..36) passes.
  result = xrSub
  let firstSfb = if mixed: 3 else: 0
  let starts = shortBandStarts(sampleRateHz, version)
  for sfb in firstSfb ..< 13:
    let s = starts[sfb]
    let e = if sfb < 12: starts[sfb + 1] else: 192
    let w = e - s
    let base = 3 * s
    for win in 0 ..< 3:
      for k in 0 ..< w:
        let srcIdx = base + 3 * k + win
        let dstIdx = base + win * w + k
        if srcIdx < 576 and dstIdx < 576:
          result[dstIdx] = xrSub[srcIdx]

proc granuleXrLong*(pcm: openArray[float32]; analysis: var Mp3AnalysisState;
    mdctStates: var array[32, Mp3MdctState]; bt = mbLong): array[576,
    float32] =
  ## Long-family forward path for one granule-channel (576 PCM in).
  assert pcm.len == 576
  let st = analyzeGranule(pcm, analysis)
  var xr: array[576, float32]
  for sb in 0 ..< 32:
    var current: array[18, float64]
    for t in 0 ..< 18:
      var v = st[sb][t].float64
      if (sb and 1) == 1 and (t and 1) == 1:
        v = -v # §2.4.3.4.10.5 cancel (freq_inv o freq_inv = id)
      current[t] = v
    let frame36 = forwardOverlap(current, mdctStates[sb])
    let windowed = windowLongFamilyAnalysis(frame36,
      case bt
      of mbStart: btStart
      of mbEnd: btEnd
      else: btLong)
    var xf = newSeq[float64](36)
    for i in 0 ..< 36:
      xf[i] = windowed[i]
    let bins = mp3Mdct(xf)
    for k in 0 ..< 18:
      xr[sb * 18 + k] = (bins[k] / 9.0).float32
  inverseAliasReduce(xr)

proc granuleXrShort*(pcm: openArray[float32];
    analysis: var Mp3AnalysisState;
    mdctStates: var array[32, Mp3MdctState]; sampleRateHz: uint32;
    version: MpegVersion; mixed: bool): array[576, float32] =
  ## Short/mixed forward path (long on sb 0..1 when mixed).
  assert pcm.len == 576
  let st = analyzeGranule(pcm, analysis)
  var xr: array[576, float32]
  let longSb = if mixed: 2 else: 0
  for sb in 0 ..< longSb:
    var current: array[18, float64]
    for t in 0 ..< 18:
      var v = st[sb][t].float64
      if (sb and 1) == 1 and (t and 1) == 1:
        v = -v
      current[t] = v
    let frame36 = forwardOverlap(current, mdctStates[sb])
    let windowed = windowLongFamilyAnalysis(frame36, btLong)
    var xf = newSeq[float64](36)
    for i in 0 ..< 36:
      xf[i] = windowed[i]
    let bins = mp3Mdct(xf)
    for k in 0 ..< 18:
      xr[sb * 18 + k] = (bins[k] / 9.0).float32
  for sb in longSb ..< 32:
    var current: array[18, float64]
    for t in 0 ..< 18:
      var v = st[sb][t].float64
      if (sb and 1) == 1 and (t and 1) == 1:
        v = -v
      current[t] = v
    let bins = forwardShortMdctSubband(current, mdctStates[sb])
    for k in 0 ..< 18:
      xr[sb * 18 + k] = bins[k]
  if mixed:
    forwardReorder(inverseAliasReduce(xr, 2), true, sampleRateHz, version)
  else:
    forwardReorder(xr, false, sampleRateHz, version)

# ------------------------------------------------------------ outer loop ---

const
  Mp3OuterSfacCompress* = 15
  Mp3OuterSfacCompressLsf* = 399
  Mp3ScalefacMaxLow* = 15
  Mp3ScalefacMaxHigh* = 7

proc scalefacLongUpperLimit*(sfb: int): int {.inline.} =
  if sfb <= 10: Mp3ScalefacMaxLow else: Mp3ScalefacMaxHigh

proc requantizeApprox*(q: array[576, int32]; ch: GranuleChannel;
    idx: int): array[576, float32] =
  ## Decoder-side reconstruction of `q` (for distortion measurement).
  let mult = scalefacMultiplier(ch.scalefacScale)
  let shift = if ch.scalefacScale: 2 else: 1
  let a = ch.globalGain - 210
  var bi = 0
  while bi + 1 < SfbLongBands[idx].len:
    let s = SfbLongBands[idx][bi]
    let e = SfbLongBands[idx][bi + 1]
    var pre = 0
    if ch.preflag and bi < 22:
      pre = PreEmphasis[bi]
    let b = (ch.scalefacs[bi] + pre) shl shift
    let p2 = pow(2.0, 0.25 * (a - b).float64).float32
    for k in s ..< min(e, 576):
      # Clamp the table index: hostile saturated input can exceed the
      # 8207-entry 4/3-power table (legit quantized lines never do).
      result[k] = (if q[k] < 0: -1.0 else: 1.0) * mpaPow43[min(abs(q[k]).int,
        mpaPow43.high)] * p2
    inc bi
  discard mult

proc outerPart2Cost*(bt: BlockType; lsf: bool): int {.inline.} =
  ## Part2 (scalefactor) bits reserved by the outer loop for `sfc = 15`
  ## (MPEG-1) / `399` (LSF): long 74, pure-short 126, mixed 122
  ## (MPEG-1) / 114 (LSF, partition 6/9/9/9).
  if bt.kind == btShort:
    if bt.mixed:
      if lsf: 114 else: 122
    else:
      126
  else:
    74

proc outerLoopSearchLong*(xr: array[576, float32]; ch: var GranuleChannel;
    sampleRateHz: uint32; version: MpegVersion; budget: int;
    xminBands: array[21, float64];
    maxIter = 64): tuple[ok: bool, `is`: array[576, int32]] =
  ## §C.1.5.4.3 long-block distortion loop (uniform threshold).
  let idx = sampleRateIdxOf(sampleRateHz, version)
  let lsf = version != Mpeg1
  # Reserve part2 (scalefactor) bits per block type under the outer
  # scalefac_compress (15 MPEG-1 / 399 LSF).
  let innerBudget = max(budget - outerPart2Cost(ch.blockType, lsf), 64)
  ch.scalefacCompress = if lsf: Mp3OuterSfacCompressLsf
    else: Mp3OuterSfacCompress
  for i in 0 ..< 21:
    ch.scalefacs[i] = 0
  ch.preflag = false
  ch.scalefacScale = false
  var cur = ch
  var bestIs: array[576, int32]
  var bestGain = 0
  var iter = 0
  var amplified = newSeq[bool](21)
  while iter < maxIter:
    inc iter
    let r = searchBitBudgetBanded(xr, cur, sampleRateHz, version,
      innerBudget)
    if not r.ok:
      break
    bestIs = r.`is`
    bestGain = cur.globalGain
    let back = requantizeApprox(bestIs, cur, idx)
    var worst = -1
    var worstVal = 0.0'f32
    let mult = scalefacMultiplier(cur.scalefacScale)
    for sfb in 0 ..< 21:
      let s = SfbLongBands[idx][sfb]
      let e = SfbLongBands[idx][sfb + 1]
      let bw = max(e - s, 1).float32
      var acc = 0.0'f32
      for k in s ..< min(e, 576):
        let d = abs(xr[k]) - abs(back[k])
        acc += d * d
      let xfsf = acc / bw *
        pow(2.0'f32, 2.0 * mult * cur.scalefacs[sfb].float32)
      if not amplified[sfb] and xfsf > xminBands[sfb].float32 and
          cur.scalefacs[sfb] < scalefacLongUpperLimit(sfb):
        if xfsf > worstVal:
          worstVal = xfsf
          worst = sfb
    if worst < 0:
      break
    # Amplify the worst band; escalate scalefac_scale once at the cap.
    if cur.scalefacs[worst] + 1 > scalefacLongUpperLimit(worst):
      if not cur.scalefacScale:
        cur.scalefacScale = true
        for i in 0 ..< 21:
          cur.scalefacs[i] = (cur.scalefacs[i] + 1) div 2
        amplified = newSeq[bool](21)
        continue
      else:
        amplified[worst] = true
        var allAmp = true
        for i in 0 ..< 21:
          if not amplified[i]:
            allAmp = false
            break
        if allAmp:
          break
        continue
    cur.scalefacs[worst] += 1
    amplified[worst] = true
  ch = cur
  ch.globalGain = bestGain
  # Regions/tables stamped by the final inner-loop search already match
  # bestIs; refresh the table choice deterministically.
  let (bigPairs, quads) = partitionSplit(bestIs)
  let (fr0, fr1) = (cur.region1Start, cur.region2Start)
  var tabs = [0, 0, 0]
  let ends = [min(fr0, bigPairs * 2), min(fr1, bigPairs * 2),
    bigPairs * 2]
  var s = 0
  for ri in 0 ..< 3:
    var sel = 23
    let t = chooseBestTableForRegion(bestIs, s, ends[ri])
    if t.isSome:
      sel = t.get.sel
    tabs[ri] = sel
    s = ends[ri]
  ch.tableSelect = tabs
  ch.bigValues = bigPairs
  let (useB, _) = chooseBestCount1Table(bestIs, bigPairs * 2,
    bigPairs * 2 + quads * 4)
  ch.count1Select = if useB: 1 else: 0
  (true, bestIs)

# -------------------------------------------------------- stereo (MS) ---

proc msMatrixForward*(l, r: openArray[float32]): tuple[m, s: array[576,
    float32]] =
  ## §2.4.3.4.9.2 forward MS matrix: M=(L+R)/sqrt2, S=(L-R)/sqrt2.
  const k = 0.7071067811865476'f32
  for i in 0 ..< 576:
    result.m[i] = (l[i] + r[i]) * k
    result.s[i] = (l[i] - r[i]) * k

const
  Mp3IntensityIllegal* = 7
  Mp3IntensitySfcLsf* = 258
  Mp3MixedFirstShortSfb* = 3
  Mp3MixedLastLongSfb* = 7

proc deriveIntensityPos*(lEnergy, rEnergy: float64): int =
  ## Annex G.2 c): NINT((12/pi)*atan(sqrt(EL/ER))), 0..6, 7 illegal never.
  ## Non-finite/hostile energies fall back to 6 (same as the R-silent limit).
  if rEnergy.classify in {fcNan, fcInf, fcNegInf} or
      lEnergy.classify in {fcNan, fcInf, fcNegInf}:
    return 6
  if rEnergy <= 0.0:
    return 6
  let ratio = sqrt(lEnergy / rEnergy)
  if ratio.classify in {fcNan, fcInf, fcNegInf}:
    return 6
  let pos = round(arctan(ratio) * 12.0 / PI)
  if pos.classify in {fcNan, fcInf, fcNegInf}:
    return 6
  clamp(pos.int, 0, 6)

proc deriveIntensityPosLsf*(lEnergy, rEnergy: float64): int =
  ## §13818-3 power-law grid, closest in log space, 0..6.
  const A = 0.17328679513998632 # ln(2)*0.25
  if rEnergy.classify in {fcNan, fcInf, fcNegInf} or
      lEnergy.classify in {fcNan, fcInf, fcNegInf}:
    return 6
  if rEnergy <= 0.0:
    return 6
  if lEnergy <= 0.0:
    return 5
  let target = ln(lEnergy / rEnergy) / (2.0 * A)
  if target.classify in {fcNan, fcInf, fcNegInf}:
    return 6
  const grid = [0.0, -1.0, 1.0, -2.0, 2.0, -3.0, 3.0]
  var best = 0
  var bestErr = Inf
  for p, g in grid.pairs:
    let err = abs(g - target)
    if err < bestErr:
      bestErr = err
      best = p
  best

proc intensityShortStart*(longStarts: array[22, int];
    shortStarts: array[13, int]; startSfb: int): int =
  ## Map long-bound line onto a short start band (first short band at/after
  ## the long line, defaulting to the last band so a short granule always
  ## couples something).
  let line = longStarts[startSfb]
  for sfb in 0 ..< 12:
    if shortStarts[sfb] >= line:
      return sfb
  11

proc coupleIntensityLong*(left, right: var array[576, float32];
    starts: array[22, int]; startSfb: int; lsf: bool): array[21, int] =
  ## Couple long bands startSfb..20: left += right, right = 0, positions out.
  for i in 0 ..< 21:
    result[i] = Mp3IntensityIllegal
  for sfb in startSfb ..< 21:
    let lo = starts[sfb]
    let hi = starts[sfb + 1]
    var le, re = 0.0
    for i in lo ..< hi:
      le += left[i].float64 * left[i].float64
      re += right[i].float64 * right[i].float64
    result[sfb] = if lsf: deriveIntensityPosLsf(le, re)
      else: deriveIntensityPos(le, re)
    for i in lo ..< hi:
      left[i] += right[i]
      right[i] = 0.0
  for i in starts[21] ..< 576:
    left[i] += right[i]
    right[i] = 0.0

proc coupleIntensityShort*(left, right: var array[576, float32];
    shortStarts: array[13, int]; longStarts: array[22, int]; startSfb: int;
    lsf: bool): tuple[pos: array[12, array[3, int]], shortStart: int] =
  ## Per-window short coupling over shortStart..12 (native interleaved layout).
  for sfb in 0 ..< 12:
    for w in 0 ..< 3:
      result.pos[sfb][w] = Mp3IntensityIllegal
  let ss = intensityShortStart(longStarts, shortStarts, startSfb)
  result.shortStart = ss
  for sfb in ss ..< 12:
    let s = shortStarts[sfb]
    let w = if sfb + 1 < 13: shortStarts[sfb + 1] - s else: 192 - s
    let base = 3 * s
    for win in 0 ..< 3:
      var le, re = 0.0
      let wb = base + win * w
      for k in 0 ..< w:
        let i = wb + k
        if i < 576:
          le += left[i].float64 * left[i].float64
          re += right[i].float64 * right[i].float64
      result.pos[sfb][win] = if lsf: deriveIntensityPosLsf(le, re)
        else: deriveIntensityPos(le, re)
      for k in 0 ..< w:
        let i = wb + k
        if i < 576:
          left[i] += right[i]
          right[i] = 0.0
  if ss < 12:
    for i in 3 * shortStarts[12] ..< 576:
      left[i] += right[i]
      right[i] = 0.0

proc coupleIntensityMixed*(left, right: var array[576, float32];
    shortStarts: array[13, int]; longStarts: array[22, int]; startSfb: int;
    lsf: bool): tuple[longPos: array[21, int],
    shortPos: array[12, array[3, int]], shortStart: int] =
  ## §2.4.3.4.10.3 two-region carve-out: long bands start..8 plus short
  ## bands shortStart..12 per window.
  for i in 0 ..< 21:
    result.longPos[i] = Mp3IntensityIllegal
  for sfb in 0 ..< 12:
    for w in 0 ..< 3:
      result.shortPos[sfb][w] = Mp3IntensityIllegal
  let longEnd = Mp3MixedLastLongSfb + 1
  for sfb in startSfb ..< longEnd:
    if sfb < 0 or sfb >= 21:
      continue
    let lo = longStarts[sfb]
    let hi = longStarts[sfb + 1]
    var le, re = 0.0
    for i in lo ..< hi:
      le += left[i].float64 * left[i].float64
      re += right[i].float64 * right[i].float64
    result.longPos[sfb] = if lsf: deriveIntensityPosLsf(le, re)
      else: deriveIntensityPos(le, re)
    for i in lo ..< hi:
      left[i] += right[i]
      right[i] = 0.0
  let line = longStarts[startSfb]
  var mapped = 11
  for sfb in 0 ..< 12:
    if shortStarts[sfb] >= line:
      mapped = sfb
      break
  let ss = max(mapped, Mp3MixedFirstShortSfb)
  result.shortStart = ss
  for sfb in ss ..< 12:
    let s = shortStarts[sfb]
    let w = if sfb + 1 < 13: shortStarts[sfb + 1] - s else: 192 - s
    let base = 3 * s
    for win in 0 ..< 3:
      var le, re = 0.0
      let wb = base + win * w
      for k in 0 ..< w:
        let i = wb + k
        if i < 576:
          le += left[i].float64 * left[i].float64
          re += right[i].float64 * right[i].float64
      result.shortPos[sfb][win] = if lsf: deriveIntensityPosLsf(le, re)
        else: deriveIntensityPos(le, re)
      for k in 0 ..< w:
        let i = wb + k
        if i < 576:
          left[i] += right[i]
          right[i] = 0.0
  if ss < 12:
    for i in 3 * shortStarts[12] ..< 576:
      left[i] += right[i]
      right[i] = 0.0

# -------------------------------------------------- block decisions ---

type
  AttackDetector* = object
    ## Signal-driven transient detector (per channel).
    ambient*: float64
    threshold*: float64
    leak*: float64

proc newAttackDetector*(threshold = 10.0; leak = 0.5): AttackDetector =
  AttackDetector(ambient: 0.0, threshold: threshold, leak: leak)

proc subframeEnergies*(pcm: openArray[float32]): array[3, float64] =
  for s in 0 ..< 3:
    var e = 0.0
    for i in 0 ..< 192:
      let v = pcm[s * 192 + i].float64
      e += v * v
    result[s] = e

proc stepAttack*(d: var AttackDetector; pcm: openArray[float32]): tuple[
    attack: bool, energies: array[3, float64]] =
  ## One granule: flag attack when any subframe bursts over ambient.
  let e = subframeEnergies(pcm)
  var mx = 0.0
  var mn = Inf
  for v in e:
    mx = max(mx, v)
    mn = min(mn, v)
  const floor = 1.0e-30
  let amb = max(d.ambient, floor)
  result = (mx / amb > d.threshold, e)
  d.ambient = d.ambient + d.leak * (mn - d.ambient)

type
  BlockTypeSM* = object
    ## §C.1.5.2 LONG -> START -> SHORT -> STOP -> LONG scheduler.
    prev*: Mp3BlockKind
    burstMixed*: bool

proc newBlockTypeSM*(): BlockTypeSM = BlockTypeSM(prev: mbLong)

proc stepBlock*(sm: var BlockTypeSM; curAttack, nextAttack: bool;
    preferMixed = false): tuple[bt: Mp3BlockKind, mixed: bool] =
  case sm.prev
  of mbLong:
    if nextAttack:
      sm.prev = mbStart
      sm.burstMixed = preferMixed
      (mbStart, preferMixed)
    else:
      (mbLong, false)
  of mbStart:
    sm.prev = mbShort
    (mbShort, sm.burstMixed)
  of mbShort:
    if curAttack or nextAttack:
      (mbShort, sm.burstMixed)
    else:
      sm.prev = mbEnd
      (mbEnd, sm.burstMixed)
  of mbEnd:
    sm.prev = mbLong
    sm.burstMixed = false
    (mbLong, false)

proc lowPassGranule*(pcm: openArray[float32]): array[576, float32] =
  ## One-tap moving-average low-pass (mixed classifier front-end).
  var prev = 0.0'f32
  for i in 0 ..< 576:
    let y = 0.5 * (pcm[i] + prev)
    prev = pcm[i]
    result[i] = y

proc mixedStable*(pcm: openArray[float32]; ratio = 4.0): bool =
  ## Stable low band warrants the mixed carve-out (low-passed subframe
  ## energies within `ratio`).
  let lp = lowPassGranule(pcm)
  let e = subframeEnergies(lp)
  var mx = 0.0'f32
  var mn = Inf.float32
  for v in e:
    mx = max(mx, v.float32)
    mn = min(mn, v.float32)
  mx <= mn.float32 * ratio.float32 + 1e-30

# ------------------------------------------------- psychoacoustics ---

const
  Mp3LtqAnchors*: array[7, tuple[f, db: float64]] = [(62.5, 33.44),
    (125.0, 19.20), (187.5, 13.87), (250.0, 11.01), (312.5, 9.20),
    (3375.0, -4.97), (15000.0, 51.04)]
  Mp3DefaultOuterThreshold* = 1.0e6

proc ltqDbAtHz*(hz: float64): float64 =
  ## Annex D Table D.1a anchors, linear in (log10 f, dB), flat-clipped.
  if hz <= Mp3LtqAnchors[0].f:
    return Mp3LtqAnchors[0].db
  if hz >= Mp3LtqAnchors[^1].f:
    return Mp3LtqAnchors[^1].db
  for w in 0 ..< Mp3LtqAnchors.len - 1:
    let (loF, loDb) = Mp3LtqAnchors[w]
    let (hiF, hiDb) = Mp3LtqAnchors[w + 1]
    if hz >= loF and hz <= hiF:
      let t = (log10(hz) - log10(loF)) / (log10(hiF) - log10(loF))
      return loDb + t * (hiDb - loDb)

proc dbToXfsf*(db: float64): float64 {.inline.} =
  pow(10.0, db / 10.0) * Mp3DefaultOuterThreshold

proc ltqThresholds*(sampleRateHz: uint32; version: MpegVersion;
    kbpsPerCh: int; offsetDb = 0.0): array[21, float64] =
  ## Per-long-band LTq xmin with §D.1 Step 3 offset + caller offset.
  let step3 = if kbpsPerCh >= 96: -12.0 else: 0.0
  let starts = longBandStarts(sampleRateHz, version)
  let lineToHz = sampleRateHz.float64 / 1152.0
  for sfb in 0 ..< 21:
    let lo = max(starts[sfb].float64, 0.5)
    let hi = max(starts[sfb + 1].float64 - 1.0, 0.5)
    let hz = sqrt(lo * hi) * lineToHz
    result[sfb] = dbToXfsf(ltqDbAtHz(hz) + step3 + offsetDb)

type
  Mp3QualityPreset* = enum
    ## Named §C.1.5/Annex D knob (mirrors the reference presets).
    qpTransparent
    qpHigh
    qpStandard
    qpFast

proc qualityOffsetDb*(q: Mp3QualityPreset): float64 {.inline.} =
  case q
  of qpTransparent: -24.0
  of qpHigh: -12.0
  of qpStandard: 0.0
  of qpFast: 6.0

proc qualityUsesModel2*(q: Mp3QualityPreset): bool {.inline.} =
  ## Transparent/High/Standard arm the signal-dependent Model-2
  ## thresholds; Fast stays on the signal-independent LTq vector.
  q != qpFast

# --------------------------------------- model 2 psychoacoustics ---

const
  Mp3Model2NmtDb* = 6.0 ## §C.1.5.3.2.1 Layer-III NMT (noise masking tone).
  Mp3Model2TmnDb* = 29.0 ## §C.1.5.3.2.1 Layer-III TMN (tone masking noise).
  Mp3Model2SpreadCutoffDb* = -100.0 ## §D.2.3 sprdngf cutoff (verbatim).

proc model2SpreadTmpx*(iBark, jBark: float64): float64 {.inline.} =
  ## §D.2.3 `tmpx = 1,05 * (j - i)` (verbatim).
  1.05 * (jBark - iBark)

proc model2SpreadXDb*(tmpx: float64): float64 {.inline.} =
  ## §D.2.3 parabolic correction `x = 8*min((tmpx-0,5)^2-2*(tmpx-0,5),0)`
  ## (verbatim; never positive, active only on the near-upward skirt).
  let u = tmpx - 0.5
  8.0 * min(u * u - 2.0 * u, 0.0)

proc model2SpreadTmpyDb*(tmpx: float64): float64 {.inline.} =
  ## §D.2.3 envelope `tmpy = 15,811389 + 7,5*(tmpx+0,474) -
  ## 17,5*(1+(tmpx+0,474)^2)^0,5` (verbatim; 0 dB on the diagonal,
  ## ≈ -10 dB/Bark upward, ≈ -25 dB/Bark downward).
  let v = tmpx + 0.474
  15.811389 + 7.5 * v - 17.5 * sqrt(1.0 + v * v)

proc model2Spread*(iBark, jBark: float64): float64 {.inline.} =
  ## Annex D §D.2.3 spreading factor (linear energy domain, verbatim
  ## procedure): `tmpy < -100 → 0`, else `10^((x+tmpy)/10)`.
  let tmpx = model2SpreadTmpx(iBark, jBark)
  let tmpy = model2SpreadTmpyDb(tmpx)
  if tmpy < Mp3Model2SpreadCutoffDb: 0.0
  else: pow(10.0, (model2SpreadXDb(tmpx) + tmpy) / 10.0)

proc barkOfHz*(hz: float64): float64 {.inline.} =
  ## Schroeder Bark scale (standard Hz → Bark mapping).
  13.0 * arctan(0.00076 * hz) + 3.5 * arctan((hz / 7500.0) * (hz / 7500.0))

proc bandTonality*(band: openArray[float32]): float64 =
  ## Spectral-flatness tonality in [0,1] (1 = pure tone). Documented
  ## stand-in for the Annex D FFT-predictability cw classifier: the
  ## encoder already holds the MDCT spectrum, so flatness of |xr| per
  ## band drives the TMN/NMT interpolation instead of a second FFT.
  if band.len == 0:
    return 0.0
  var arith = 0.0
  var logSum = 0.0
  for v in band:
    let m = abs(v.float64)
    arith += m
    logSum += ln(m + 1e-12)
  arith /= band.len.float64
  if arith <= 0.0:
    return 0.0
  clamp(1.0 - exp(logSum / band.len.float64) / arith, 0.0, 1.0)

proc model2LongThresholds*(xr: openArray[float32]; sampleRateHz: uint32;
    version: MpegVersion; offsetDb = 0.0): array[21, float64] =
  ## Signal-dependent masking thresholds per long band (Model-2-flavored):
  ## per-band MDCT energy + flatness tonality → TMN/NMT mask level →
  ## §D.2.3 Bark spreading (max-fold) → LTq floor → geometric-mean
  ## anchor normalization (cf. reference `from_layer3_granule_with_offset_db`).
  ##
  ## Adaptations (documented): the masker analysis runs on the encoder's
  ## own 21 long scalefactor bands instead of staged Annex D partition
  ## tables (rate-agnostic: works at all nine sample rates, not just the
  ## three staged Annex D rates); tonality comes from MDCT flatness, not
  ## the 1024-point FFT predictability classifier. Masking offsets are
  ## the verbatim §C.1.5.3.2.1 Layer-III values (TMN 29 dB, NMT 6 dB);
  ## the preset `offsetDb` carries the §D.1 Step-3 sense (no additional
  ## rate term: the preset values already encode it).
  let idx = sampleRateIdxOf(sampleRateHz, version)
  let starts = SfbLongBands[idx]
  let lineToHz = sampleRateHz.float64 / 1152.0
  var zb: array[21, float64]
  var ltqDb: array[21, float64]
  for sfb in 0 ..< 21:
    let lo = max(starts[sfb].float64, 0.5)
    let hi = max(starts[sfb + 1].float64 - 1.0, 0.5)
    let hz = sqrt(lo * hi) * lineToHz
    zb[sfb] = barkOfHz(hz)
    ltqDb[sfb] = ltqDbAtHz(hz)
  var maskDb: array[21, float64]
  for sfb in 0 ..< 21:
    let s = starts[sfb]
    let e = min(starts[sfb + 1], 576)
    let bw = max(e - s, 1).float64
    var en = 0.0
    for k in s ..< e:
      en += xr[k].float64 * xr[k].float64
    if en <= 1e-30:
      maskDb[sfb] = -Inf
    else:
      let t = bandTonality(xr.toOpenArray(s, e - 1))
      maskDb[sfb] = 10.0 * log10(en / bw) -
        (t * Mp3Model2TmnDb + (1.0 - t) * Mp3Model2NmtDb)
  var thrLin: array[21, float64]
  for i in 0 ..< 21:
    var m = -Inf
    for j in 0 ..< 21:
      if maskDb[j] == -Inf:
        continue
      let sp = model2Spread(zb[j], zb[i])
      if sp <= 0.0:
        continue
      m = max(m, maskDb[j] + 10.0 * log10(sp))
    thrLin[i] = pow(10.0, max(m, ltqDb[i]) / 10.0)
  # Geometric-mean anchor: map the mean threshold to 1e6 translated by
  # the preset offset (single common rescale preserves every per-band
  # ratio Model 2 produced). Silent-shaped bands ride the LTq floor, so
  # thrLin is always positive here.
  let anchor = Mp3DefaultOuterThreshold * pow(10.0, offsetDb / 10.0)
  var logSum = 0.0
  var logCount = 0
  var minPos = Inf
  for sfb in 0 ..< 21:
    let v = thrLin[sfb]
    if v > 0.0:
      logSum += ln(v)
      inc logCount
      minPos = min(minPos, v)
  if logCount == 0:
    for i in 0 ..< 21:
      result[i] = anchor
    return
  let scale = anchor / exp(logSum / logCount.float64)
  let floor = minPos * scale
  for i in 0 ..< 21:
    result[i] = if thrLin[i] > 0.0: thrLin[i] * scale else: floor

# ---------------------------------------------------------------- crc ---

proc crc16Bits*(bits: openArray[uint8]): uint16 =
  ## Raw §2.4.3.1 shift register (MSB-first, init 0xFFFF, poly 0x8005).
  var reg = 0xffff'u32
  for b in bits:
    let fb = ((reg shr 15) xor (b and 1).uint32) and 1
    reg = ((reg shl 1) and 0xffff'u32) xor (if fb != 0: 0x8005'u32 else: 0)
  reg.uint16

proc crc16Layer3*(header: array[4, uint8]; sideInfo: openArray[uint8];
    nch: int): uint16 =
  ## Protected set: header bytes 2..3 + first 135/256 side-info bits.
  let siBits = if nch == 1: 135 else: 256
  var bits = newSeq[uint8]()
  for b in [header[2], header[3]]:
    for k in countdown(7, 0):
      bits.add((b shr k) and 1)
  var n = 0
  for by in sideInfo:
    for k in countdown(7, 0):
      if n >= siBits:
        break
      bits.add((by shr k) and 1)
      inc n
  crc16Bits(bits)

proc crc16Layer3Lsf*(header: array[4, uint8]; sideInfo: openArray[uint8];
    nch: int): uint16 =
  let siBits = if nch == 1: 72 else: 136
  var bits = newSeq[uint8]()
  for b in [header[2], header[3]]:
    for k in countdown(7, 0):
      bits.add((b shr k) and 1)
  var n = 0
  for by in sideInfo:
    for k in countdown(7, 0):
      if n >= siBits:
        break
      bits.add((by shr k) and 1)
      inc n
  crc16Bits(bits)

# ------------------------------------------------------------ xing/lame ---

proc buildXingPayload*(isXing: bool; frames, bytes: uint32;
    toc: array[100, uint8]; quality: uint32): seq[uint8] =
  ## Xing/Info payload: magic + flags(ALL_FOUR) + frames + bytes + toc +
  ## quality.
  result = @[]
  let magic =
    if isXing: [0x58'u8, 0x69, 0x6e, 0x67] else: [0x49'u8, 0x6e, 0x66, 0x6f]
  for b in magic:
    result.add(b)
  for b in [0x00'u8, 0x00, 0x00, 0x0f]:
    result.add(b)
  for v in [frames, bytes, quality]:
    result.add(uint8(v shr 24))
    result.add(uint8(v shr 16))
    result.add(uint8(v shr 8))
    result.add(uint8(v))
    if v == bytes:
      for t in toc:
        result.add(t)

proc computeXingToc*(cumOffsets: openArray[uint64]; total: uint64): array[100,
    uint8] =
  for i in 0 ..< 100:
    let want = total * i.uint64 div 100
    var j = 0
    while j + 1 < cumOffsets.len and cumOffsets[j + 1] < want:
      inc j
    result[i] =
      if total == 0: 0'u8
      else: min(255'u64, 256 * cumOffsets[j] div max(total, 1)).uint8

proc crc16Reflected*(crc: uint16; data: openArray[uint8]): uint16 =
  var c = crc
  for by in data:
    c = c xor by.uint16
    for _ in 0 ..< 8:
      c = if (c and 1) != 0: (c shr 1) xor 0xa001'u16 else: c shr 1
  c

proc buildInfoFrame*(header: FrameHeader; isXing: bool; frames, bytes: uint32;
    toc: array[100, uint8]; quality: uint32; gapless: bool; encDelay,
    endPad: int; minKbps: uint32; audio: openArray[uint8]): seq[uint8] =
  ## Silent carrier + Xing payload + LAME gapless extension.
  var hdr = header
  hdr.hasCrc = false
  hdr.channelMode = header.channelMode
  var frame = encodeSilentFrame(hdr)
  let siLen = hdr.sideInfoLen()
  let payload = buildXingPayload(isXing, frames, bytes, toc, quality)
  let slotStart = 4 + siLen
  if slotStart + payload.len > frame.len:
    raise unsupportedError(
      "mp3enc: frame too small for Xing tag (raise bitrate or disable xing)")
  for i, b in payload:
    frame[slotStart + i] = b
  if gapless:
    # LAME extension at magic offset 120 (all four flags set).
    const lameStr = "LAMEoxav1"
    let at = slotStart + 120
    if at + 36 > frame.len:
      raise unsupportedError(
        "mp3enc: frame too small for LAME gapless tag (raise bitrate or disable gapless)")
    for i, c in lameStr:
      frame[at + i] = c.uint8
    frame[at + 9] = 1 # CBR method byte
    frame[at + 20] = min(minKbps, 255).uint8
    let d = min(encDelay, 4095)
    let p = min(endPad, 4095)
    frame[at + 21] = (d shr 4).uint8
    frame[at + 22] = (((d and 0x0f) shl 4) or (p shr 8)).uint8
    frame[at + 23] = (p and 0xff).uint8
    let rateClass =
      case header.sampleRate
      of 0 .. 32_000: 0'u8
      of 32_001 .. 44_100: 1'u8
      of 44_101 .. 48_000: 2'u8
      else: 3'u8
    let stereoMode =
      case header.channelMode.kind
      of mmMono: 0'u8
      of mmStereo: 1'u8
      of mmDualMono: 2'u8
      of mmJoint: 3'u8
    frame[at + 24] = (rateClass shl 6) or ((stereoMode and 0x07) shl 2)
    let musicLen = (frame.len + audio.len).uint32
    frame[at + 28] = uint8(musicLen shr 24)
    frame[at + 29] = uint8(musicLen shr 16)
    frame[at + 30] = uint8(musicLen shr 8)
    frame[at + 31] = uint8(musicLen)
    let mcrc = crc16Reflected(0, audio)
    frame[at + 32] = uint8(mcrc shr 8)
    frame[at + 33] = uint8(mcrc)
    let tcrc = crc16Reflected(0, frame.toOpenArray(0, at + 33))
    frame[at + 34] = uint8(tcrc shr 8)
    frame[at + 35] = uint8(tcrc)
  frame

# ------------------------------------------------------------ encoder ---

const
  Mp3EndToEndDelay* = 1057
  Mp3DecoderDelay* = 529
  Mp3EncoderDelay* = Mp3EndToEndDelay - Mp3DecoderDelay

type
  Mp3EncoderOptions* = object
    ## Construction knob bundle (mirrors the reference factory set).
    bitrateKbps*: int
    sampleRateHz*: uint32
    mode*: MpaMode
    useOuterLoop*: bool
    outerXmin*: float64
    ltqOffsetDb*: float64  ## NaN = off; else LTq per-band + offset
    forceShort*: bool
    forceMixed*: bool
    autoBlock*: bool
    autoMixed*: bool
    attackThreshold*: float64
    jointMs*: bool
    jointAuto*: bool
    jointAutoThreshold*: float64
    intensityStart*: int ## 0 = off, else 1..20
    useModel2*: bool ## signal-dependent Model-2 thresholds (needs outer loop)
    vbr*: bool
    vbrMinKbps*: int
    vbrMaxKbps*: int
    xing*: bool
    gapless*: bool
    crc*: bool

  Mp3PendingFrame* = object
    sideInfo*: FrameData
    scfsi*: array[2, array[4, bool]]
    mainData*: seq[uint8]
    bitLen*: int
    vbrIdx*: int ## -1 = CBR template bitrate
    msStereo*: bool

  Mp3Encoder* = ref object
    sampleRateHz*: uint32
    version*: MpegVersion
    nch*: int
    mode*: MpaMode
    bitrateKbps*: int
    bitrateIdx*: int
    lsf*: bool
    samplesPerFrame*: int
    opts*: Mp3EncoderOptions
    analysis*: seq[Mp3AnalysisState]
    mdct*: seq[array[32, Mp3MdctState]]
    attack*: seq[AttackDetector]
    btSm*: seq[BlockTypeSM]
    pending*: seq[seq[float32]]
    pendingOff*: array[2, int] ## Consumed prefix per channel (cursor:
      ## `pending[ch][pendingOff[ch] .. ^1]` is the live queue).
    frames*: seq[Mp3PendingFrame]
    frameModeExt*: seq[MpaMode]
    samplesIn*: uint64

proc defaultMp3EncoderOptions*(bitrateKbps: int; sampleRateHz: uint32;
    mode: MpaMode): Mp3EncoderOptions =
  Mp3EncoderOptions(bitrateKbps: bitrateKbps, sampleRateHz: sampleRateHz,
    mode: mode, outerXmin: 1.0e6, ltqOffsetDb: NaN, attackThreshold: 10.0,
    jointAutoThreshold: 0.5)

proc newMp3Encoder*(opts: Mp3EncoderOptions): Mp3Encoder =
  initMpaTables()
  initHuffCache()
  let sri = sampleRateIndex(opts.sampleRateHz)
  if sri.isNone:
    raise unsupportedError("mp3enc: unsupported sample rate")
  let (v, _) = sri.get
  let bi = layer3BitrateIndex(v, opts.bitrateKbps.uint32)
  if bi.isNone:
    raise unsupportedError("mp3enc: bitrate not on Layer III ladder")
  let nch = opts.mode.numChannels()
  if opts.mode.kind == mmJoint and not opts.jointMs and
      not opts.jointAuto and opts.intensityStart == 0:
    raise unsupportedError(
      "mp3enc: joint stereo needs jointMs or jointAuto")
  if opts.intensityStart != 0:
    if nch != 2 or opts.mode.kind != mmJoint:
      raise unsupportedError("mp3enc: intensity needs joint stereo")
    if opts.intensityStart < 1 or opts.intensityStart > 20:
      raise unsupportedError("mp3enc: intensityStart must be 1..20")
  if opts.vbr:
    let lo = layer3BitrateIndex(v, opts.vbrMinKbps.uint32)
    let hi = layer3BitrateIndex(v, opts.vbrMaxKbps.uint32)
    if lo.isNone or hi.isNone or lo.get > hi.get:
      raise unsupportedError("mp3enc: malformed VBR config")
  let lsf = v != Mpeg1
  Mp3Encoder(sampleRateHz: opts.sampleRateHz, version: v, nch: nch,
    mode: opts.mode, bitrateKbps: opts.bitrateKbps, bitrateIdx: bi.get,
    lsf: lsf, samplesPerFrame: if lsf: 576 else: 1152, opts: opts,
    analysis: newSeq[Mp3AnalysisState](nch),
    mdct: newSeq[array[32, Mp3MdctState]](nch),
    attack: newSeq[AttackDetector](nch),
    btSm: newSeq[BlockTypeSM](nch),
    pending: newSeq[seq[float32]](nch))

proc perGcBitBudget*(e: Mp3Encoder): int =
  ## Even-share per-granule-channel bit budget (no-reservoir schedule).
  let siLen = if e.lsf:
    (if e.nch == 1: 9 else: 17)
  else:
    (if e.nch == 1: 17 else: 32)
  let crcBytes = if e.opts.crc: 2 else: 0
  let ladder = if e.version == Mpeg1: MpaEncV1L3Ladder
    else: MpaEncV2L23Ladder
  let maxKbps =
    if e.opts.vbr: e.opts.vbrMaxKbps
    else: e.bitrateKbps
  var maxIdx = e.bitrateIdx
  for i in 1 ..< 15:
    if ladder[i] == maxKbps * 1000:
      maxIdx = i
      break
  let coeff = if e.lsf: 72 else: 144
  let slotBytes = (coeff * ladder[maxIdx].int) div e.sampleRateHz.int -
    4 - crcBytes - siLen
  let ngr = if e.lsf: 1 else: 2
  max(slotBytes * 8 div (ngr * e.nch) - 16, 64)

proc assembleFrame*(e: Mp3Encoder; perChPcm: openArray[seq[float32]];
  lookahead: openArray[seq[float32]])

proc tryAssembleFrames*(e: Mp3Encoder) =
  ## Cut whole frames while buffered PCM (+ lookahead when autoBlock).
  ## Queue consumption is cursor-based: slicing the tail off per frame
  ## is O(n^2) over a stream, so frames advance `pendingOff` and the
  ## consumed prefix is dropped in bulk every 64k samples (amortized
  ## O(1) per frame).
  const CompactAt = 65536
  let lookPad = if e.opts.autoBlock: 576 else: 0
  while true:
    var ok = true
    for ch in 0 ..< e.nch:
      if e.pending[ch].len - e.pendingOff[ch] < e.samplesPerFrame + lookPad:
        ok = false
        break
    if not ok:
      break
    var perCh = newSeq[seq[float32]](e.nch)
    var look = newSeq[seq[float32]](e.nch)
    for ch in 0 ..< e.nch:
      let off = e.pendingOff[ch]
      perCh[ch] = e.pending[ch][off ..< off + e.samplesPerFrame]
      if lookPad > 0:
        look[ch] = e.pending[ch][off + e.samplesPerFrame ..<
          off + e.samplesPerFrame + lookPad]
      e.pendingOff[ch] = off + e.samplesPerFrame
      if e.pendingOff[ch] >= CompactAt:
        e.pending[ch] = e.pending[ch][e.pendingOff[ch] .. ^1]
        e.pendingOff[ch] = 0
    e.assembleFrame(perCh, look)

proc pushSamplesI16*(e: Mp3Encoder; samples: openArray[int16]) =
  ## Push interleaved (stereo) or mono S16 PCM.
  const scale = 1.0 / 32768.0
  let n = samples.len div e.nch
  for i in 0 ..< n:
    for ch in 0 ..< e.nch:
      e.pending[ch].add(samples[i * e.nch + ch].float32 * scale)
  e.samplesIn += n.uint64
  e.tryAssembleFrames()

proc pushSamplesF32*(e: Mp3Encoder; samples: openArray[float32]) =
  ## Push interleaved [-1, 1] float PCM.
  let n = samples.len div e.nch
  for i in 0 ..< n:
    for ch in 0 ..< e.nch:
      e.pending[ch].add(samples[i * e.nch + ch])
  e.samplesIn += n.uint64
  e.tryAssembleFrames()

proc granuleXrDispatch*(e: Mp3Encoder; ch: int; pcm: openArray[float32];
    bt: Mp3BlockKind; mixed: bool): array[576, float32] =
  case bt
  of mbLong, mbStart, mbEnd:
    granuleXrLong(pcm, e.analysis[ch], e.mdct[ch], bt)
  of mbShort:
    granuleXrShort(pcm, e.analysis[ch], e.mdct[ch], e.sampleRateHz,
      e.version, mixed)

proc outerXminBands*(e: Mp3Encoder): array[21, float64] =
  ## Uniform or LTq per-band thresholds for the outer loop.
  if e.opts.ltqOffsetDb.classify != fcNan:
    ltqThresholds(e.sampleRateHz, e.version, e.bitrateKbps div e.nch,
      e.opts.ltqOffsetDb)
  else:
    var u: array[21, float64]
    for i in 0 ..< 21:
      u[i] = e.opts.outerXmin
    u

proc xminBandsFor*(e: Mp3Encoder; xr: array[576, float32]): array[21,
    float64] =
  ## Outer-loop thresholds for one granule-channel: signal-dependent
  ## Model-2 masking when armed (computed on the spectrum actually
  ## quantized, i.e. post-MS/IS), else the LTq/uniform path.
  if e.opts.useModel2:
    let off =
      if e.opts.ltqOffsetDb.classify != fcNan: e.opts.ltqOffsetDb else: 0.0
    model2LongThresholds(xr, e.sampleRateHz, e.version, off)
  else:
    e.outerXminBands()

proc encodeGranuleStereo*(e: Mp3Encoder; gr: int; xrL, xrR: array[576,
    float32]; bt: Mp3BlockKind; mixed: bool; useMs: bool): tuple[
    q0, q1: array[576, int32]; g0, g1: GranuleChannel] =
  ## Quantize one granule pair (MS matrix optional). Returns quantized
  ## lines + configured granule channels.
  var a = xrL
  var b = xrR
  if useMs:
    let m = msMatrixForward(xrL, xrR)
    a = m.m
    b = m.s
  var c0 = defaultGranuleChannel()
  var c1 = defaultGranuleChannel()
  if bt == mbShort:
    c0.blockType = BlockType(kind: btShort, mixed: mixed)
    c1.blockType = BlockType(kind: btShort, mixed: mixed)
  elif bt == mbStart:
    c0.blockType = BlockType(kind: btStart)
    c1.blockType = BlockType(kind: btStart)
  elif bt == mbEnd:
    c0.blockType = BlockType(kind: btEnd)
    c1.blockType = BlockType(kind: btEnd)
  let budget = e.perGcBitBudget()
  var q0, q1: array[576, int32]
  if e.opts.useOuterLoop:
    if e.opts.useModel2:
      let o0 = outerLoopSearchLong(a, c0, e.sampleRateHz, e.version, budget,
        e.xminBandsFor(a))
      let o1 = outerLoopSearchLong(b, c1, e.sampleRateHz, e.version, budget,
        e.xminBandsFor(b))
      q0 = o0.`is`
      q1 = o1.`is`
    else:
      let xb = e.outerXminBands()
      let o0 = outerLoopSearchLong(a, c0, e.sampleRateHz, e.version, budget,
        xb)
      let o1 = outerLoopSearchLong(b, c1, e.sampleRateHz, e.version, budget,
        xb)
      q0 = o0.`is`
      q1 = o1.`is`
  else:
    let s0 = searchBitBudgetBanded(a, c0, e.sampleRateHz, e.version,
      budget)
    let s1 = searchBitBudgetBanded(b, c1, e.sampleRateHz, e.version,
      budget)
    if not s0.ok or not s1.ok:
      raise unsupportedError("mp3enc: frame does not fit slot (raise bitrate)")
    q0 = s0.`is`
    q1 = s1.`is`
  (q0, q1, c0, c1)

proc assembleFrame*(e: Mp3Encoder; perChPcm: openArray[seq[float32]];
    lookahead: openArray[seq[float32]]) =
  ## Cut one frame from per-channel PCM (frame + optional lookahead).
  let ngr = if e.lsf: 1 else: 2
  let spf = e.samplesPerFrame
  # Block-type pre-pass (auto or forced).
  var btPerGc: array[2, array[2, Mp3BlockKind]]
  var mixedPerGc: array[2, array[2, bool]]
  for gr in 0 ..< ngr:
    for ch in 0 ..< e.nch:
      let base = gr * 576
      var lk: seq[float32] = @[]
      if lookahead.len > ch and lookahead[ch].len >= 576:
        lk = lookahead[ch][0 ..< 576]
      if e.opts.forceShort:
        btPerGc[gr][ch] = mbShort
      elif e.opts.forceMixed:
        btPerGc[gr][ch] = mbShort
        mixedPerGc[gr][ch] = true
      elif e.opts.autoBlock:
        # Detector advances once per granule in stream order; the
        # lookahead peek runs on a clone so the committed state is
        # untouched by the not-yet-consumed granule.
        let (curAtk, _) = block:
          var probe = e.attack[ch]
          stepAttack(probe, perChPcm[ch].toOpenArray(base, base + 575))
        var nextAtk = false
        if lk.len == 576:
          var peek = e.attack[ch]
          discard stepAttack(peek,
            perChPcm[ch].toOpenArray(base, base + 575))
          let (na, _) = stepAttack(peek, lk)
          nextAtk = na
        discard stepAttack(e.attack[ch],
          perChPcm[ch].toOpenArray(base, base + 575)) # commit in-order
        let preferMixed = e.opts.autoMixed and mixedStable(
          perChPcm[ch].toOpenArray(base, base + 575))
        let (bt, mx) = stepBlock(e.btSm[ch], curAtk, nextAtk, preferMixed)
        btPerGc[gr][ch] = bt
        mixedPerGc[gr][ch] = mx
      else:
        btPerGc[gr][ch] = mbLong
  # Joint-stereo agreement: mirror channel 0 across both channels.
  let intensityActive = e.opts.intensityStart != 0 and e.nch == 2
  let startSfb = e.opts.intensityStart
  if e.nch == 2 and (e.opts.jointMs or e.opts.jointAuto or
      intensityActive):
    for gr in 0 ..< ngr:
      btPerGc[gr][1] = btPerGc[gr][0]
      mixedPerGc[gr][1] = mixedPerGc[gr][0]
  # Pass 1: forward spectral path per (gr, ch).
  var xrPre: array[2, array[2, array[576, float32]]]
  for gr in 0 ..< ngr:
    for ch in 0 ..< e.nch:
      let base = gr * 576
      # granuleXrDispatch advances analysis+mdct state; for Start/End
      # transition granules the long path covers the window family.
      xrPre[gr][ch] = e.granuleXrDispatch(ch,
        perChPcm[ch].toOpenArray(base, base + 575), btPerGc[gr][ch],
        mixedPerGc[gr][ch])
  # Pass 1.45: §2.4.3.4.9.3 intensity coupling (L+R magnitude, R zero-part).
  var isLongPos: array[2, array[21, int]]
  var isShortPos: array[2, array[12, array[3, int]]]
  var isMixedLong: array[2, array[21, int]]
  var isMixedShort: array[2, array[12, array[3, int]]]
  var shortStartPerGr: array[2, int]
  var isShortGr: array[2, bool]
  var isMixedGr: array[2, bool]
  var intensityCoupled: array[2, bool]
  for gr in 0 ..< 2:
    for i in 0 ..< 21:
      isLongPos[gr][i] = Mp3IntensityIllegal
      isMixedLong[gr][i] = Mp3IntensityIllegal
    for sfb in 0 ..< 12:
      for w in 0 ..< 3:
        isShortPos[gr][sfb][w] = Mp3IntensityIllegal
        isMixedShort[gr][sfb][w] = Mp3IntensityIllegal
    shortStartPerGr[gr] = 12
  let longStartsAll = longBandStarts(e.sampleRateHz, e.version)
  let shortStartsAll = shortBandStarts(e.sampleRateHz, e.version)
  if intensityActive:
    for gr in 0 ..< ngr:
      let bt = btPerGc[gr][0]
      let mixed = mixedPerGc[gr][0]
      if mixed and e.lsf:
        # LSF mixed partition (33 slots) differs from the MPEG-1 two-region
        # carve-out; keep full stereo so the decoder bound lands at 21.
        intensityCoupled[gr] = false
      elif mixed:
        let r = coupleIntensityMixed(xrPre[gr][0], xrPre[gr][1],
          shortStartsAll, longStartsAll, startSfb, e.lsf)
        isMixedLong[gr] = r.longPos
        isMixedShort[gr] = r.shortPos
        shortStartPerGr[gr] = r.shortStart
        isMixedGr[gr] = true
        intensityCoupled[gr] = true
      elif bt == mbShort:
        let r = coupleIntensityShort(xrPre[gr][0], xrPre[gr][1],
          shortStartsAll, longStartsAll, startSfb, e.lsf)
        isShortPos[gr] = r.pos
        shortStartPerGr[gr] = r.shortStart
        isShortGr[gr] = true
        intensityCoupled[gr] = r.shortStart < 12
      else:
        isLongPos[gr] = coupleIntensityLong(xrPre[gr][0], xrPre[gr][1],
          longStartsAll, startSfb, e.lsf)
        intensityCoupled[gr] = startSfb < 21
  # Pass 2: MS decision + quantization + side info.
  var si = FrameData(mainDataBegin: 0)
  var scfsi: array[2, array[4, bool]]
  var gcData: array[2, array[2, Mp3GcData]]
  var frameMs = false
  if e.opts.jointMs:
    frameMs = true
  elif e.opts.jointAuto and e.nch == 2:
    # Per-frame picker over the below-bound region only (§2.4.3.4.9.1: MS
    # applies below the intensity bound). Frame-scoped mode_extension.
    var eLR, eSide2 = 0.0
    for gr in 0 ..< ngr:
      var hi = 576
      if intensityActive and intensityCoupled[gr]:
        if isShortGr[gr] or isMixedGr[gr]:
          hi = min(3 * shortStartsAll[shortStartPerGr[gr]], 576)
        else:
          hi = min(longStartsAll[startSfb], 576)
      for i in 0 ..< hi:
        let l = xrPre[gr][0][i].float64
        let r = xrPre[gr][1][i].float64
        eLR += l * l + r * r
        let d = l - r
        eSide2 += d * d
    if eLR <= 0.0:
      frameMs = true
    else:
      frameMs = eSide2 / (2.0 * eLR) <= e.opts.jointAutoThreshold
  if intensityActive and frameMs:
    # §2.4.3.4.9.2 rotation below the bound only (intensity zero-part above
    # stays coupled). Non-intensity frames keep the whole-spectrum matrix
    # inside encodeGranuleStereo.
    const k = 0.7071067811865476'f32
    for gr in 0 ..< ngr:
      var hi = 576
      if intensityCoupled[gr]:
        if isShortGr[gr] or isMixedGr[gr]:
          hi = min(3 * shortStartsAll[shortStartPerGr[gr]], 576)
        else:
          hi = min(longStartsAll[startSfb], 576)
      for i in 0 ..< hi:
        let l = xrPre[gr][0][i]
        let r = xrPre[gr][1][i]
        xrPre[gr][0][i] = (l + r) * k
        xrPre[gr][1][i] = (l - r) * k
  for gr in 0 ..< ngr:
    if e.nch == 1:
      var c0 = defaultGranuleChannel()
      if btPerGc[gr][0] == mbShort:
        c0.blockType = BlockType(kind: btShort,
          mixed: mixedPerGc[gr][0])
      elif btPerGc[gr][0] == mbStart:
        c0.blockType = BlockType(kind: btStart)
      elif btPerGc[gr][0] == mbEnd:
        c0.blockType = BlockType(kind: btEnd)
      let budget = e.perGcBitBudget()
      var q: array[576, int32]
      if e.opts.useOuterLoop:
        let o = outerLoopSearchLong(xrPre[gr][0], c0, e.sampleRateHz,
          e.version, budget, e.xminBandsFor(xrPre[gr][0]))
        q = o.`is`
        if e.lsf:
          c0.scalefacCompress = Mp3OuterSfacCompressLsf
      else:
        let s = searchBitBudgetBanded(xrPre[gr][0], c0, e.sampleRateHz,
          e.version, budget)
        if not s.ok:
          raise unsupportedError(
            "mp3enc: frame does not fit slot (raise bitrate)")
        q = s.`is`
      # Tables/regions stamped by the search; reuse them verbatim.
      let (bp, qq) = partitionSplit(q)
      let useB = c0.count1Select == 1
      si.granules[gr][0] = c0
      gcData[gr][0] = Mp3GcData(`is`: q, bigPairs: bp, count1Quads: qq,
        useB: useB, r0: c0.region1Start, r1: c0.region2Start)
    elif intensityActive and intensityCoupled[gr]:
      # Intensity granule: MS already applied, quantize L/R plain then wire
      # positions into the right channel scalefactors.
      var c0 = defaultGranuleChannel()
      var c1 = defaultGranuleChannel()
      if btPerGc[gr][0] == mbShort:
        c0.blockType = BlockType(kind: btShort, mixed: mixedPerGc[gr][0])
        c1.blockType = BlockType(kind: btShort, mixed: mixedPerGc[gr][0])
      elif btPerGc[gr][0] == mbStart:
        c0.blockType = BlockType(kind: btStart)
        c1.blockType = BlockType(kind: btStart)
      elif btPerGc[gr][0] == mbEnd:
        c0.blockType = BlockType(kind: btEnd)
        c1.blockType = BlockType(kind: btEnd)
      let budget = e.perGcBitBudget()
      var q0, q1: array[576, int32]
      if e.opts.useOuterLoop:
        let xb0 = e.xminBandsFor(xrPre[gr][0])
        let xb1 = e.xminBandsFor(xrPre[gr][1])
        let o0 = outerLoopSearchLong(xrPre[gr][0], c0, e.sampleRateHz,
          e.version, budget, xb0)
        let o1 = outerLoopSearchLong(xrPre[gr][1], c1, e.sampleRateHz,
          e.version, budget, xb1)
        q0 = o0.`is`
        q1 = o1.`is`
        if e.lsf:
          c0.scalefacCompress = Mp3OuterSfacCompressLsf
          c1.scalefacCompress = Mp3IntensitySfcLsf
        else:
          c1.scalefacCompress = Mp3OuterSfacCompress
      else:
        let isShortBt = btPerGc[gr][0] == mbShort and
          not mixedPerGc[gr][0]
        let isMixedBt = mixedPerGc[gr][0]
        let part2Right =
          if isMixedBt: 122
          elif isShortBt: 126
          else: (if e.lsf: 63 else: 74)
        let s0 = searchBitBudgetBanded(xrPre[gr][0], c0, e.sampleRateHz,
          e.version, budget)
        let rightBudget = max(budget - part2Right, 16)
        let s1 = searchBitBudgetBanded(xrPre[gr][1], c1, e.sampleRateHz,
          e.version, rightBudget)
        if not s0.ok or not s1.ok:
          raise unsupportedError(
            "mp3enc: frame does not fit slot (raise bitrate)")
        q0 = s0.`is`
        q1 = s1.`is`
        if e.lsf:
          c1.scalefacCompress = Mp3IntensitySfcLsf
        else:
          c1.scalefacCompress = Mp3OuterSfacCompress
      # Right-channel wire-up: coupled bands carry is_pos, the all-zero tail
      # below the bound carries the illegal marker 7 (decode-side bound is
      # one past the last non-zero right line).
      let idx = sampleRateIdxOf(e.sampleRateHz, e.version)
      if isMixedGr[gr]:
        let longEnd = Mp3MixedLastLongSfb + 1
        var lastLong = -1
        for i in 0 ..< min(longStartsAll[longEnd], 576):
          if q1[i] != 0:
            lastLong = i
        var zLong = 0
        if lastLong >= 0:
          zLong = longEnd
          for sfb in 0 ..< longEnd:
            if lastLong < longStartsAll[sfb + 1]:
              zLong = sfb + 1
              break
        for sfb in zLong ..< min(startSfb, longEnd):
          c1.scalefacs[sfb] = Mp3IntensityIllegal
        for sfb in min(startSfb, longEnd) ..< longEnd:
          if startSfb < longEnd:
            c1.scalefacs[sfb] = isMixedLong[gr][sfb]
        let sw = SfbMixedSwitchPoint[idx]
        let ss = shortStartPerGr[gr]
        for win in 0 ..< 3:
          var lastSfb = -1
          for sfb in Mp3MixedFirstShortSfb ..< 12:
            let s = shortStartsAll[sfb]
            let w = if sfb + 1 < 13: shortStartsAll[sfb + 1] - s
              else: 192 - s
            let wb = 3 * s + win * w
            for k in 0 ..< w:
              let i = wb + k
              if i < 576 and q1[i] != 0:
                lastSfb = sfb
          let zFrom = if lastSfb < 0: Mp3MixedFirstShortSfb else: lastSfb + 1
          for sfb in zFrom ..< min(ss, 12):
            c1.scalefacs[sw + (sfb - Mp3MixedFirstShortSfb) * 3 + win] =
              Mp3IntensityIllegal
          for sfb in ss ..< 12:
            c1.scalefacs[sw + (sfb - Mp3MixedFirstShortSfb) * 3 + win] =
              isMixedShort[gr][sfb][win]
      elif isShortGr[gr]:
        let ss = shortStartPerGr[gr]
        for win in 0 ..< 3:
          var lastSfb = -1
          for sfb in 0 ..< 12:
            let s = shortStartsAll[sfb]
            let w = if sfb + 1 < 13: shortStartsAll[sfb + 1] - s
              else: 192 - s
            let wb = 3 * s + win * w
            for k in 0 ..< w:
              let i = wb + k
              if i < 576 and q1[i] != 0:
                lastSfb = sfb
          let zFrom = if lastSfb < 0: 0 else: lastSfb + 1
          for sfb in zFrom ..< min(ss, 12):
            c1.scalefacs[sfb * 3 + win] = Mp3IntensityIllegal
          for sfb in ss ..< 12:
            c1.scalefacs[sfb * 3 + win] = isShortPos[gr][sfb][win]
      else:
        var last = -1
        for i in 0 ..< 576:
          if q1[i] != 0:
            last = i
        var zFrom = 0
        if last >= 0:
          zFrom = 21
          for sfb in 0 ..< 21:
            if last < longStartsAll[sfb + 1]:
              zFrom = sfb + 1
              break
        for sfb in zFrom ..< min(startSfb, 21):
          c1.scalefacs[sfb] = Mp3IntensityIllegal
        for sfb in startSfb ..< 21:
          c1.scalefacs[sfb] = isLongPos[gr][sfb]
      si.granules[gr][0] = c0
      si.granules[gr][1] = c1
      let qs = [q0, q1]
      for ci in 0 ..< 2:
        let q = qs[ci]
        let (bp, qq) = partitionSplit(q)
        si.granules[gr][ci].bigValues = bp
        gcData[gr][ci] = Mp3GcData(`is`: q, bigPairs: bp,
          count1Quads: qq, useB: si.granules[gr][ci].count1Select == 1,
          r0: si.granules[gr][ci].region1Start,
          r1: si.granules[gr][ci].region2Start)
    else:
      let useMsNow = frameMs and not intensityActive
      let (q0, q1, c0, c1) = e.encodeGranuleStereo(gr, xrPre[gr][0],
        xrPre[gr][1], btPerGc[gr][0], mixedPerGc[gr][0], useMsNow)
      var cc0 = c0
      var cc1 = c1
      if e.lsf and e.opts.useOuterLoop:
        cc0.scalefacCompress = Mp3OuterSfacCompressLsf
        cc1.scalefacCompress = Mp3OuterSfacCompressLsf
      si.granules[gr][0] = cc0
      si.granules[gr][1] = cc1
      let qs = [q0, q1]
      for ci in 0 ..< 2:
        let q = qs[ci]
        let (bp, qq) = partitionSplit(q)
        si.granules[gr][ci].bigValues = bp
        gcData[gr][ci] = Mp3GcData(`is`: q, bigPairs: bp,
          count1Quads: qq, useB: si.granules[gr][ci].count1Select == 1,
          r0: si.granules[gr][ci].region1Start,
          r1: si.granules[gr][ci].region2Start)
  var frameMode = e.mode
  if frameMode.kind == mmJoint:
    frameMode.midSide = frameMs
    frameMode.intensity = intensityActive
  let assembly = assembleMainData(
    FrameHeader(version: e.version, layer: Layer3,
      bitrate: e.bitrateKbps.uint32 * 1000, sampleRate: e.sampleRateHz,
      sampleRateIdx: sampleRateIdxOf(e.sampleRateHz), channelMode: frameMode,
      hasCrc: false, frameSize: 0),
    si, scfsi, gcData)
  e.frames.add(Mp3PendingFrame(sideInfo: si, scfsi: scfsi,
    mainData: assembly.bytes, bitLen: assembly.bytes.len * 8, vbrIdx: -1,
    msStereo: frameMs))
  var md = e.mode
  if md.kind == mmJoint:
    md.midSide = frameMs
    md.intensity = intensityActive
  e.frameModeExt.add(md)

proc frameLenFor*(version: MpegVersion; bitrateKbps: int;
    sampleRateHz: uint32; pad: bool): int =
  ## §2.4.2.3 frame length in bytes (header incl.).
  let coeff = if version == Mpeg1: 144 else: 72
  (coeff * bitrateKbps * 1000) div sampleRateHz.int + (if pad: 1 else: 0)

proc finishEncoder*(e: Mp3Encoder): seq[uint8] =
  ## Flush (zero-pad tail + END_TO_END_DELAY), schedule trivially
  ## (no-reservoir: every main_data_begin = 0), emit frames + Xing.
  # Tail flush: pad pending to a frame boundary past samplesIn + delay.
  let total = e.samplesIn + Mp3EndToEndDelay.uint64
  let framesNeeded =
    (total + e.samplesPerFrame.uint64 - 1) div e.samplesPerFrame.uint64
  let wantPending =
    if framesNeeded * e.samplesPerFrame.uint64 >
        e.frames.len.uint64 * e.samplesPerFrame.uint64:
      framesNeeded * e.samplesPerFrame.uint64 -
        e.frames.len.uint64 * e.samplesPerFrame.uint64
    else: 0'u64
  for ch in 0 ..< e.nch:
    while (e.pending[ch].len - e.pendingOff[ch]).uint64 < wantPending:
      e.pending[ch].add(0.0)
  # Assemble remaining whole frames (zero lookahead at stream end).
  while true:
    var ok = true
    for ch in 0 ..< e.nch:
      if e.pending[ch].len - e.pendingOff[ch] < e.samplesPerFrame:
        ok = false
        break
    if not ok:
      break
    var perCh = newSeq[seq[float32]](e.nch)
    for ch in 0 ..< e.nch:
      let off = e.pendingOff[ch]
      perCh[ch] = e.pending[ch][off ..< off + e.samplesPerFrame]
      e.pendingOff[ch] = off + e.samplesPerFrame
    e.assembleFrame(perCh, @[])
  # CBR Bresenham padding + slots.
  let siLen = if e.lsf:
    (if e.nch == 1: 9 else: 17)
  else:
    (if e.nch == 1: 17 else: 32)
  let crcBytes = if e.opts.crc: 2 else: 0
  let ladder = if e.version == Mpeg1: MpaEncV1L3Ladder
    else: MpaEncV2L23Ladder
  let coeff = if e.lsf: 72 else: 144
  let rem = (coeff * e.bitrateKbps * 1000) mod e.sampleRateHz.int
  var acc = 0
  var audio: seq[uint8] = @[]
  var cumOffsets: seq[uint64] = @[0]
  var minKbps = e.bitrateKbps
  for i, f in e.frames:
    var kbps = e.bitrateKbps
    var pad = false
    if e.opts.vbr:
      # Smallest ladder bitrate in [min,max] holding the main data.
      var picked = -1
      for b in e.opts.vbrMinKbps .. e.opts.vbrMaxKbps:
        var onLadder = false
        for k in 1 ..< 15:
          if ladder[k] == b * 1000:
            onLadder = true
            break
        if not onLadder:
          continue
        let need = f.mainData.len
        let unp = frameLenFor(e.version, b, e.sampleRateHz, false)
        if unp - 4 - crcBytes - siLen >= need:
          picked = b
          pad = false
          break
        let padSlot = frameLenFor(e.version, b, e.sampleRateHz, true) -
          4 - crcBytes - siLen
        if padSlot >= need:
          picked = b
          pad = true
          break
      if picked < 0:
        raise unsupportedError(
          "mp3enc: VBR frame does not fit max slot (raise max bitrate)")
      kbps = picked
    else:
      if rem != 0:
        acc += rem
        if acc >= e.sampleRateHz.int:
          acc -= e.sampleRateHz.int
          pad = true
    minKbps = min(minKbps, kbps)
    let flen = frameLenFor(e.version, kbps, e.sampleRateHz, pad)
    let slot = flen - 4 - crcBytes - siLen
    # Soundness gate: the assembled main data (scalefactors + Huffman,
    # all granule-channels) must fit the frame slot. The per-channel
    # gain searches budget part3 only (with floors that keep tiny
    # budgets searchable), so an infeasible config (e.g. stereo at a
    # few kbit/s, or forced short blocks below the part2 floor) is
    # rejected here instead of emitting a desynchronizing long frame.
    # The VBR picker above guarantees the same invariant by selection.
    if f.mainData.len > slot:
      raise unsupportedError("mp3enc: frame does not fit slot (raise bitrate)")
    # Header.
    var bi = e.bitrateIdx
    for k in 1 ..< 15:
      if ladder[k] == kbps * 1000:
        bi = k
        break
    var mode = e.mode
    if e.nch == 2:
      mode = e.frameModeExt[i]
    let hdr = FrameHeader(version: e.version, layer: Layer3,
      bitrate: (kbps * 1000).uint32, sampleRate: e.sampleRateHz,
      sampleRateIdx: sampleRateIdxOf(e.sampleRateHz),
      channelMode: mode, hasCrc: e.opts.crc, frameSize: flen - 4)
    var hb = writeMp3Header(hdr)
    if pad:
      hb[2] = hb[2] or 0x02'u8
    for b in hb:
      audio.add(b)
    # Side info with main_data_begin = 0 (no-reservoir schedule).
    var si = f.sideInfo
    si.mainDataBegin = 0
    let sib = writeSideInfo(si, hdr)
    if e.opts.crc:
      let c = if e.lsf: crc16Layer3Lsf(hb, sib, e.nch)
        else: crc16Layer3(hb, sib, e.nch)
      audio.add(uint8(c shr 8))
      audio.add(uint8(c))
    for b in sib:
      audio.add(b)
    # Slot: own main data + zero pad.
    for b in f.mainData:
      audio.add(b)
    while audio.len - cumOffsets[^1].int < flen:
      audio.add(0)
    cumOffsets.add(audio.len.uint64)
  # Optional Xing/Info carrier first.
  if e.opts.xing:
    let baseHdr = FrameHeader(version: e.version, layer: Layer3,
      bitrate: (e.bitrateKbps * 1000).uint32, sampleRate: e.sampleRateHz,
      sampleRateIdx: sampleRateIdxOf(e.sampleRateHz),
      channelMode: e.mode, hasCrc: false,
      frameSize: frameLenFor(e.version, e.bitrateKbps, e.sampleRateHz,
        false) - 4)
    var toc: array[100, uint8]
    let total = audio.len.uint64
    var rel = newSeq[uint64](cumOffsets.len)
    for i, o in cumOffsets:
      rel[i] = o
    toc = computeXingToc(rel, total)
    let spf = e.samplesPerFrame.uint64
    let decoded = e.frames.len.uint64 * spf
    let lead = Mp3EncoderDelay.uint64 + e.samplesIn
    let endPad = if decoded > lead: decoded - lead else: 0'u64
    let carrier = buildInfoFrame(baseHdr, e.opts.vbr,
      e.frames.len.uint32, total.uint32, toc, 0, e.opts.gapless,
      Mp3EncoderDelay, endPad.int, minKbps.uint32, audio)
    result = carrier & audio
  else:
    result = audio

# ------------------------------------------------------ constructors ---

proc newMp3EncoderCbr*(bitrateKbps: int; sampleRateHz: uint32;
    mode: MpaMode): Mp3Encoder =
  newMp3Encoder(defaultMp3EncoderOptions(bitrateKbps, sampleRateHz, mode))

proc newMp3EncoderOuterLoop*(bitrateKbps: int; sampleRateHz: uint32;
    mode: MpaMode; xmin = 1.0e6): Mp3Encoder =
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz, mode)
  o.useOuterLoop = true
  o.outerXmin = xmin
  newMp3Encoder(o)

proc newMp3EncoderLtq*(bitrateKbps: int; sampleRateHz: uint32;
    mode: MpaMode; offsetDb = 0.0): Mp3Encoder =
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz, mode)
  o.useOuterLoop = true
  o.ltqOffsetDb = offsetDb
  newMp3Encoder(o)

proc newMp3EncoderQuality*(bitrateKbps: int; sampleRateHz: uint32;
    mode: MpaMode; q: Mp3QualityPreset): Mp3Encoder =
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz, mode)
  o.useOuterLoop = true
  o.ltqOffsetDb = qualityOffsetDb(q)
  o.useModel2 = qualityUsesModel2(q)
  newMp3Encoder(o)

proc enableModel2*(e: Mp3Encoder) =
  ## Arm signal-dependent Model-2 thresholds (implies the outer loop,
  ## which consumes them; mirrors the reference requirement that a
  ## per-band xmin needs the outer loop enabled).
  e.opts.useModel2 = true
  e.opts.useOuterLoop = true

proc newMp3EncoderJointMs*(bitrateKbps: int; sampleRateHz: uint32): Mp3Encoder =
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz,
    MpaMode(kind: mmJoint, midSide: true, intensity: false, bound: 0))
  o.jointMs = true
  newMp3Encoder(o)

proc newMp3EncoderJointAuto*(bitrateKbps: int; sampleRateHz: uint32;
    threshold = 0.5): Mp3Encoder =
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz,
    MpaMode(kind: mmJoint, midSide: true, intensity: false, bound: 0))
  o.jointAuto = true
  o.jointAutoThreshold = threshold
  newMp3Encoder(o)

proc newMp3EncoderJointIs*(bitrateKbps: int; sampleRateHz: uint32;
    startSfb = 8): Mp3Encoder =
  ## Intensity-only (`mode_extension '01'`): bands at/above `startSfb`
  ## (1..20) transmit is_pos, right zero-part above the bound.
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz,
    MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
  o.intensityStart = startSfb
  newMp3Encoder(o)

proc newMp3EncoderJointMsIs*(bitrateKbps: int; sampleRateHz: uint32;
    startSfb = 8): Mp3Encoder =
  ## MS+intensity (`mode_extension '11'`): MS below the bound, intensity
  ## above it.
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz,
    MpaMode(kind: mmJoint, midSide: true, intensity: true, bound: 0))
  o.jointMs = true
  o.intensityStart = startSfb
  newMp3Encoder(o)

proc newMp3EncoderJointAutoIs*(bitrateKbps: int; sampleRateHz: uint32;
    startSfb = 8; threshold = 0.5): Mp3Encoder =
  ## Auto-MS + intensity: per-frame MS picker below the bound, intensity
  ## above it (`'11'` when MS fires, `'01'` otherwise).
  var o = defaultMp3EncoderOptions(bitrateKbps, sampleRateHz,
    MpaMode(kind: mmJoint, midSide: true, intensity: true, bound: 0))
  o.jointAuto = true
  o.jointAutoThreshold = threshold
  o.intensityStart = startSfb
  newMp3Encoder(o)

proc enableAutoBlockType*(e: Mp3Encoder; threshold = 10.0;
    withMixed = false) =
  e.opts.autoBlock = true
  e.opts.attackThreshold = threshold
  e.opts.autoMixed = withMixed
  for i in 0 ..< e.nch:
    e.attack[i] = newAttackDetector(threshold)
    e.btSm[i] = newBlockTypeSM()

proc enableXingInfo*(e: Mp3Encoder; gapless = true) =
  e.opts.xing = true
  e.opts.gapless = gapless

proc enableCrc*(e: Mp3Encoder) =
  e.opts.crc = true

proc enableVbr*(e: Mp3Encoder; minKbps, maxKbps: int) =
  e.opts.vbr = true
  e.opts.vbrMinKbps = minKbps
  e.opts.vbrMaxKbps = maxKbps

proc toS16Interleaved*(samples: AudioSamples): seq[int16] =
  ## Planar -> interleaved S16 (clamped).
  let n = samples.framesOf()
  let nch = samples.specOf().channels.channelCount()
  result = newSeq[int16](n * nch)
  for i in 0 ..< n:
    for p in 0 ..< nch:
      let v =
        case samples.format
        of sfS16: samples.s16.planes[p][i].float32
        of sfS32: (samples.s32.planes[p][i] shr 16).float32
        of sfF32: samples.f32.planes[p][i] * 32768.0'f32
        of sfF64: samples.f64.planes[p][i].float32 * 32768.0'f32
        else: 0.0'f32
      result[i * nch + p] = max(-32768.0'f32,
        min(32767.0'f32, round(v))).int16

proc encodeMp3Stream*(samples: AudioSamples; opts: Mp3EncoderOptions): seq[
    uint8] =
  ## Whole-stream MP3 encode (CBR/VBR, gapless Info frame when enabled).
  let e = newMp3Encoder(opts)
  e.pushSamplesI16(toS16Interleaved(samples))
  e.finishEncoder()
