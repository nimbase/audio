## ADPCM codecs: MS, IMA-WAV, IMA-QT decoders plus encoders.
##
## Decoders port `symphonia-codec-adpcm` (`codec_ms.rs`, `codec_ima_wav.rs`,
## `codec_ima_qt.rs`, `common*.rs`): tables and block layouts verbatim.
## Output is `sfS32` with 16-bit samples MSB-aligned (`sample << 16`),
## exactly like the reference.
##
## Nibble order differs per codec: MS emits upper-then-lower, both IMA
## variants lower-then-upper.
##
## Encoders (`encodeMs*`, `encodeIma*`) are new work: Symphonia has no
## encoders. They are closed-loop (analysis-by-synthesis): each nibble is
## chosen by running the exact decoder step for all candidates and keeping
## the minimum-absolute-error reconstruction. MS tries all 7 predictors
## per block and keeps the best.

import std/options
import ./../audio
import ./../codecs
import ./../errors
import ./../io
import ./../packet
import ./../source
import ./../units

const
  MsAdaptTable*: array[16, int32] = [230'i32, 230, 230, 230, 307, 409, 512,
    614, 768, 614, 512, 409, 307, 230, 230, 230]
  MsCoeffs1*: array[7, int32] = [256'i32, 512, 0, 192, 240, 460, 392]
  MsCoeffs2*: array[7, int32] = [0'i32, -256, 0, 64, 0, -208, -232]
  MsDeltaMin = 16'i32

  ImaIndexTable*: array[16, int32] = [-1'i32, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8]
  ImaStepTable*: array[89, int32] = [7'i32, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]

type
  AdpcmKind* = enum
    akMs
    akImaWav
    akImaQt

  AdpcmDecoder* = ref object of AudioDecoder
    params*: AudioCodecParameters
    kind*: AdpcmKind
    framesPerBlock*: int
    buf*: AudioSamples # sfS32, MSB-aligned S16 values.

proc upperNibble(b: uint8): uint8 {.inline.} = b shr 4
proc lowerNibble(b: uint8): uint8 {.inline.} = b and 0x0f'u8

proc signedNibble(nib: uint8): int32 {.inline.} =
  if (nib and 0x08'u8) != 0: nib.int32 - 16 else: nib.int32

# ---------------------------------------------------------- MS decode ---

type
  MsStatus = object
    coeff1, coeff2: int32
    delta: int32
    sample1, sample2: int32

proc msPredict(s1, s2, c1, c2, delta: int32; nib: uint8): int32 =
  ## Predicted (clamped) sample for `nib` without mutating state.
  ## Wrapping arithmetic matches Symphonia release behavior bit-for-bit
  ## and never raises on hostile input.
  let sn = signedNibble(nib)
  clampI16(((s1 * c1 + s2 * c2) div 256) +% (sn *% delta))

proc msExpand(st: var MsStatus; b: uint8; upper: bool): int32 =
  let nib = if upper: upperNibble(b) else: lowerNibble(b)
  let predicted = msPredict(st.sample1, st.sample2, st.coeff1, st.coeff2,
    st.delta, nib)
  st.sample2 = st.sample1
  st.sample1 = predicted
  st.delta = max((MsAdaptTable[nib.int] *% st.delta) div 256, MsDeltaMin)
  st.sample1 shl 16

proc readMsMonoPreamble[R](r: var R): MsStatus =
  let predictor = r.readByte().int
  if predictor > 6:
    raise unsupportedError("adpcm: block predictor exceeds range")
  result.coeff1 = MsCoeffs1[predictor]
  result.coeff2 = MsCoeffs2[predictor]
  result.delta = cast[int16](r.readU16Le()).int32
  result.sample1 = cast[int16](r.readU16Le()).int32
  result.sample2 = cast[int16](r.readU16Le()).int32

proc readMsStereoPreamble[R](r: var R): tuple[left, right: MsStatus] =
  let lp = r.readByte().int
  if lp > 6:
    raise unsupportedError("adpcm: block predictor exceeds range")
  let rp = r.readByte().int
  if rp > 6:
    raise unsupportedError("adpcm: block predictor exceeds range")
  let ld = cast[int16](r.readU16Le()).int32
  let rd = cast[int16](r.readU16Le()).int32
  let ls1 = cast[int16](r.readU16Le()).int32
  let rs1 = cast[int16](r.readU16Le()).int32
  let ls2 = cast[int16](r.readU16Le()).int32
  let rs2 = cast[int16](r.readU16Le()).int32
  result.left = MsStatus(coeff1: MsCoeffs1[lp], coeff2: MsCoeffs2[lp],
    delta: ld, sample1: ls1, sample2: ls2)
  result.right = MsStatus(coeff1: MsCoeffs1[rp], coeff2: MsCoeffs2[rp],
    delta: rd, sample1: rs1, sample2: rs2)

proc decodeMsMono*[R](r: var R; outp: var openArray[int32];
    framesPerBlock: int) =
  checkDecode(framesPerBlock >= 2 and framesPerBlock mod 2 == 0,
    "adpcm: invalid ms mono block size")
  var st = readMsMonoPreamble(r)
  outp[0] = st.sample2 shl 16
  outp[1] = st.sample1 shl 16
  for b in 1 ..< framesPerBlock div 2:
    let byte = r.readByte()
    outp[b * 2] = st.msExpand(byte, true)
    outp[b * 2 + 1] = st.msExpand(byte, false)

proc decodeMsStereo*[R](r: var R; left, right: var openArray[int32];
    framesPerBlock: int) =
  checkDecode(framesPerBlock >= 2, "adpcm: invalid ms stereo block size")
  var st = readMsStereoPreamble(r)
  left[0] = st.left.sample2 shl 16
  left[1] = st.left.sample1 shl 16
  right[0] = st.right.sample2 shl 16
  right[1] = st.right.sample1 shl 16
  for f in 2 ..< framesPerBlock:
    let byte = r.readByte()
    left[f] = st.left.msExpand(byte, true)
    right[f] = st.right.msExpand(byte, false)

# --------------------------------------------------------- IMA decode ---

type
  ImaStatus = object
    predictor: int32 # i16 range.
    stepIndex: int32 # 0..88.

proc imaStep(predictor, stepIndex: int32; nib: uint8): tuple[pred, idx: int32] =
  ## One decoder step without mutating state. Returns the clamped
  ## predictor and the new step index.
  let step = ImaStepTable[stepIndex]
  let diff = ((2 * (nib and 0x07'u8).int32 + 1) * step) shr 3
  let pred =
    if (nib and 0x08'u8) != 0: clampI16(predictor - diff)
    else: clampI16(predictor + diff)
  let idx = clamp(stepIndex + ImaIndexTable[nib.int], 0'i32, 88'i32)
  (pred, idx)

proc imaExpand(st: var ImaStatus; b: uint8; upper: bool): int32 =
  let nib = if upper: upperNibble(b) else: lowerNibble(b)
  let (pred, idx) = imaStep(st.predictor, st.stepIndex, nib)
  st.predictor = pred
  st.stepIndex = idx
  st.predictor shl 16

proc readImaWavPreamble[R](r: var R): ImaStatus =
  let predictor = cast[int16](r.readU16Le()).int32
  let stepIndex = r.readByte().int32
  if stepIndex > 88:
    raise decodeError("adpcm (ima): invalid step index")
  discard r.readByte() # Reserved.
  ImaStatus(predictor: predictor, stepIndex: stepIndex)

proc decodeImaWavMono*[R](r: var R; outp: var openArray[int32];
    framesPerBlock: int) =
  let dataBytes = (framesPerBlock - 1) div 2
  # Trailing frames when (frames-1) is odd stay silent (the reference
  # leaves them uninitialized; silence is strictly safer).
  var st = readImaWavPreamble(r)
  if outp.len > 0:
    outp[0] = st.predictor shl 16
  for b in 0 ..< dataBytes:
    let byte = r.readByte()
    if 1 + b * 2 < outp.len:
      outp[1 + b * 2] = st.imaExpand(byte, false)
    if 1 + b * 2 + 1 < outp.len:
      outp[1 + b * 2 + 1] = st.imaExpand(byte, true)

proc decodeImaWavStereo*[R](r: var R; left, right: var openArray[int32];
    framesPerBlock: int) =
  if framesPerBlock == 0 or (framesPerBlock - 1) mod 8 != 0:
    raise decodeError("adpcm (ima): frames_per_block - 1 must be a multiple of 8")
  let dataBytes = framesPerBlock - 1
  var l = readImaWavPreamble(r)
  var rr = readImaWavPreamble(r)
  left[0] = l.predictor shl 16
  right[0] = rr.predictor shl 16
  for index in 0 ..< dataBytes:
    let channel = (index div 4) and 1
    let offset = (index div 8) * 8
    let byte = index mod 4
    let nibbles = r.readByte()
    if channel == 0:
      left[1 + offset + byte * 2] = l.imaExpand(nibbles, false)
      left[1 + offset + byte * 2 + 1] = l.imaExpand(nibbles, true)
    else:
      right[1 + offset + byte * 2] = rr.imaExpand(nibbles, false)
      right[1 + offset + byte * 2 + 1] = rr.imaExpand(nibbles, true)

proc readImaQtPreamble[R](r: var R): ImaStatus =
  let header = r.readU16Be()
  let predictor = cast[int16](header and 0xff80'u16).int32
  let stepIndex = min((header and 0x7f'u16).int32, 88)
  ImaStatus(predictor: predictor, stepIndex: stepIndex)

proc decodeImaQtMono*[R](r: var R; outp: var openArray[int32]) =
  ## IMA-QT blocks are fixed: 2-byte header + 32 data bytes = 64 frames.
  checkDecode(outp.len >= 64, "adpcm (ima-qt): output needs 64 frames")
  var st = readImaQtPreamble(r)
  for b in 0 ..< 32:
    let nibbles = r.readByte()
    outp[b * 2] = st.imaExpand(nibbles, false)
    outp[b * 2 + 1] = st.imaExpand(nibbles, true)

proc decodeImaQtStereo*[R](r: var R; left, right: var openArray[int32]) =
  r.decodeImaQtMono(left)
  r.decodeImaQtMono(right)

# ------------------------------------------------------------ decoder ---

proc isSupportedAdpcmCodec*(id: AudioCodecId): bool =
  id == CodecAdpcmMs or id == CodecAdpcmImaWav or id == CodecAdpcmImaQt

proc newAdpcmDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): AdpcmDecoder =
  if not isSupportedAdpcmCodec(params.codec):
    raise unsupportedError("adpcm: invalid codec")
  if params.maxFramesPerPacket.isNone:
    raise unsupportedError("adpcm: maximum frames per packet is required")
  let framesPerBlock =
    if params.framesPerBlock.isSome: params.framesPerBlock.get.int else: 0
  if framesPerBlock == 0:
    raise unsupportedError("adpcm: valid frames per block is required")
  if params.sampleRate.isNone:
    raise unsupportedError("adpcm: sample rate is required")
  if params.channels.isNone:
    raise unsupportedError("adpcm: channels or channel_layout is required")
  let nch = params.channels.get.channelCount()
  if nch < 1 or nch > 2:
    raise unsupportedError("adpcm: up to two channels are supported")
  let kind =
    if params.codec == CodecAdpcmMs: akMs
    elif params.codec == CodecAdpcmImaWav: akImaWav
    else: akImaQt
  let spec = newAudioSpec(params.sampleRate.get, params.channels.get)
  let capacity = min(params.maxFramesPerPacket.get, 4_194_304'u64).int
  AdpcmDecoder(params: params, kind: kind, framesPerBlock: framesPerBlock,
    buf: newAudioSamples(sfS32, spec, capacity))

proc decodeFramesFrom[R](d: AdpcmDecoder; r: var R; total: int) =
  ## Block decode core over any byte cursor (owning or view).
  let nch = d.buf.specOf().channels.channelCount()
  let framesPerBlock = d.framesPerBlock
  checkDecode(framesPerBlock > 0, "adpcm: invalid frames per block")
  d.buf.clearSamples()
  d.buf.growSamples(total)
  # renderWith commits `total` frames; the loops below fill every one
  # for well-formed packets (short tails stay silent).
  d.buf.s32.renderWith(total, i):
    discard i
  case d.kind
  of akMs:
    if nch == 1:
      var blocks = 0
      while blocks * framesPerBlock < total:
        let off = blocks * framesPerBlock
        let n = min(framesPerBlock, total - off)
        checkDecode(n == framesPerBlock, "adpcm: truncated ms block")
        r.decodeMsMono(d.buf.s32.planes[0].toOpenArray(off, off + n - 1),
          framesPerBlock)
        inc blocks
    else:
      var blocks = 0
      while blocks * framesPerBlock < total:
        let off = blocks * framesPerBlock
        let n = min(framesPerBlock, total - off)
        checkDecode(n == framesPerBlock, "adpcm: truncated ms block")
        r.decodeMsStereo(
          d.buf.s32.planes[0].toOpenArray(off, off + n - 1),
          d.buf.s32.planes[1].toOpenArray(off, off + n - 1),
          framesPerBlock)
        inc blocks
  of akImaWav:
    if nch == 1:
      var blocks = 0
      while blocks * framesPerBlock < total:
        let off = blocks * framesPerBlock
        let n = min(framesPerBlock, total - off)
        checkDecode(n == framesPerBlock, "adpcm: truncated ima block")
        r.decodeImaWavMono(d.buf.s32.planes[0].toOpenArray(off, off + n - 1),
          framesPerBlock)
        inc blocks
    else:
      var blocks = 0
      while blocks * framesPerBlock < total:
        let off = blocks * framesPerBlock
        let n = min(framesPerBlock, total - off)
        checkDecode(n == framesPerBlock, "adpcm: truncated ima block")
        r.decodeImaWavStereo(
          d.buf.s32.planes[0].toOpenArray(off, off + n - 1),
          d.buf.s32.planes[1].toOpenArray(off, off + n - 1),
          framesPerBlock)
        inc blocks
  of akImaQt:
    # Fixed 64-frame mono blocks (128 frames per stereo pair).
    let unit = if nch == 1: 64 else: 128
    var blocks = 0
    while blocks * unit < total:
      let off = blocks * unit
      let n = min(unit, total - off)
      checkDecode(n == unit, "adpcm: truncated ima-qt block")
      if nch == 1:
        r.decodeImaQtMono(d.buf.s32.planes[0].toOpenArray(off, off + n - 1))
      else:
        r.decodeImaQtStereo(
          d.buf.s32.planes[0].toOpenArray(off, off + n - 1),
          d.buf.s32.planes[1].toOpenArray(off, off + n - 1))
      inc blocks

method codecParams*(d: AdpcmDecoder): AudioCodecParameters = d.params

method reset*(d: AdpcmDecoder) =
  ## No inter-packet state: nothing to do.
  discard

proc decodeFrames(d: AdpcmDecoder; data: seq[uint8]; total: int) =
  ## Owning decode (as before; `data` is an owned packet).
  var r = newReader(data)
  d.decodeFramesFrom(r, total)

proc decodeAdpcmWin*(d: AdpcmDecoder; win: ByteWindow; total: int) =
  ## Zero-copy decode straight from a byte window (mapping or pool).
  var vr = viewReaderOf(win)
  d.decodeFramesFrom(vr, total)

proc decodeAdpcmView*(d: AdpcmDecoder; src: MappedSource; off, len,
    total: int) =
  ## Zero-copy decode straight from a mapping window.
  d.decodeAdpcmWin(byteWindow(src, off, len), total)

proc packetTotal*(d: AdpcmDecoder; blockDur: Duration): int =
  ## Block-aligned frame count for a packet duration.
  let unit =
    if d.kind == akImaQt:
      if d.buf.specOf().channels.channelCount() == 1: 64'u64 else: 128'u64
    else:
      d.framesPerBlock.uint64
  (blockDur.get div unit * unit).int

proc decodePacketView*(d: AdpcmDecoder; v: PacketView): AudioSamples =
  ## View-based `decodePacket`: identical output, no packet copy.
  try:
    d.decodeAdpcmWin(v.win, d.packetTotal(v.blockDur()))
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  d.buf

method decodePacket*(d: AdpcmDecoder; pkt: Packet): AudioSamples =
  try:
    # Block count derives from the packet duration like the reference
    # (block_dur / frames_per_block). IMA-QT uses fixed 64-frame mono
    # blocks (128 per stereo pair) regardless of frames_per_block.
    let total = d.packetTotal(pkt.blockDur())
    d.decodeFrames(pkt.data, total)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  d.buf

method lastDecoded*(d: AdpcmDecoder): AudioSamples = d.buf

proc adpcmDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newAdpcmDecoder(params, opts)

proc registerAdpcm*() =
  registerAudioDecoder(CodecAdpcmMs, adpcmDecoderFactory)
  registerAudioDecoder(CodecAdpcmImaWav, adpcmDecoderFactory)
  registerAudioDecoder(CodecAdpcmImaQt, adpcmDecoderFactory)

# ------------------------------------------------------------ encoders ---

proc toS16Samples*(buf: AudioSamples): tuple[spec: AudioSpec,
    planes: seq[seq[int16]]] =
  ## Encoder input: `sfS16` directly, or `sfS32` holding MSB-aligned S16
  ## (the decoder's output format) shifted down.
  case buf.format
  of sfS16:
    (buf.s16.spec, buf.s16.planes)
  of sfS32:
    var planes = newSeq[seq[int16]](buf.s32.planes.len)
    for p in 0 ..< planes.len:
      planes[p] = newSeq[int16](buf.s32.numFrames)
      for i in 0 ..< buf.s32.numFrames:
        planes[p][i] = cast[int16](buf.s32.planes[p][i] shr 16)
    (buf.s32.spec, planes)
  else:
    raise unsupportedError("adpcm: encoder needs s16 or s32 input")

proc encodeMsMonoBlock*(samples: openArray[int16]): seq[uint8] =
  ## Encodes one even-length (>= 2) mono MS-ADPCM block.
  let frames = samples.len
  checkDecode(frames >= 2 and frames mod 2 == 0,
    "adpcm: ms mono block needs even frames >= 2")
  var maxAbs = 0'i32
  for i in 2 ..< frames:
    let a = abs(samples[i].int32 - samples[i - 1].int32)
    if a > maxAbs:
      maxAbs = a
  let delta0 = clamp(maxAbs div 16, 16'i32, 8192'i32)
  var bestPred = 0
  var bestErr = high(int64)
  var bestNibbles: seq[uint8] = @[]
  for pred in 0 ..< 7:
    let c1 = MsCoeffs1[pred]
    let c2 = MsCoeffs2[pred]
    var s1 = samples[1].int32
    var s2 = samples[0].int32
    var delta = delta0
    var err = 0'i64
    var nibbles = newSeq[uint8](frames - 2)
    for i in 2 ..< frames:
      var best = 0'u8
      var bestE = high(int32)
      var bestS1 = s1
      for nib in 0 ..< 16:
        let p = msPredict(s1, s2, c1, c2, delta, cast[uint8](nib))
        let e = abs(p - samples[i].int32)
        if e < bestE:
          bestE = e
          best = cast[uint8](nib)
          bestS1 = p
      nibbles[i - 2] = best
      err += bestE.int64
      s2 = s1
      s1 = bestS1
      # Wrapping multiply exactly simulates the decoder (release
      # semantics), so the search can never raise on overflow.
      delta = max((MsAdaptTable[best.int] *% delta) div 256, MsDeltaMin)
    if err < bestErr:
      bestErr = err
      bestPred = pred
      bestNibbles = nibbles
  # Emit the winning predictor with the initial delta.
  var w = newWriter()
  w.writeByte(cast[uint8](bestPred))
  w.writeU16Le(cast[uint16](cast[int16](delta0)))
  w.writeU16Le(cast[uint16](samples[1]))
  w.writeU16Le(cast[uint16](samples[0]))
  for i in countup(0, bestNibbles.len - 1, 2):
    let hi = bestNibbles[i]
    let lo =
      if i + 1 < bestNibbles.len: bestNibbles[i + 1] else: 0'u8
    w.writeByte((hi shl 4) or lo)
  w.toBytes()

proc encodeMsStereoBlock*(left, right: openArray[int16]): seq[uint8] =
  ## Encodes one stereo MS-ADPCM block (both channels same length >= 2).
  ## Channels are independent except for byte interleaving, so each is
  ## optimized as a mono block and reframed.
  checkDecode(left.len == right.len and left.len >= 2,
    "adpcm: ms stereo block needs matching channels, frames >= 2")
  let frames = left.len
  # The mono block engine needs even lengths; pad odd inputs by repeating
  # the final sample, then use only the first frames-2 nibbles.
  let paddedLen = if frames mod 2 == 1: frames + 1 else: frames
  var lp = newSeq[int16](paddedLen)
  var rp = newSeq[int16](paddedLen)
  for i in 0 ..< paddedLen:
    lp[i] = left[min(i, frames - 1)]
    rp[i] = right[min(i, frames - 1)]
  let lb = encodeMsMonoBlock(lp)
  let rb = encodeMsMonoBlock(rp)
  # Mono block layout is [pred, delta2, s1_2, s2_2] + data; stereo
  # interleaves the preamble fields, then emits one byte per frame
  # holding the L nibble up top and the R nibble down low.
  var w = newWriter()
  w.writeByte(lb[0])
  w.writeByte(rb[0])
  w.writeBytes(lb[1 .. 2])
  w.writeBytes(rb[1 .. 2])
  w.writeBytes(lb[3 .. 4])
  w.writeBytes(rb[3 .. 4])
  w.writeBytes(lb[5 .. 6])
  w.writeBytes(rb[5 .. 6])
  var lnibs = newSeq[uint8]()
  for b in lb[7 .. ^1]:
    lnibs.add(b shr 4)
    lnibs.add(b and 0x0f'u8)
  var rnibs = newSeq[uint8]()
  for b in rb[7 .. ^1]:
    rnibs.add(b shr 4)
    rnibs.add(b and 0x0f'u8)
  checkDecode(lnibs.len >= frames - 2 and rnibs.len >= frames - 2,
    "adpcm: ms stereo reframe failed")
  for f in 2 ..< frames:
    w.writeByte((lnibs[f - 2] shl 4) or rnibs[f - 2])
  w.toBytes()

proc encodeImaNibbles(samples: openArray[int16]; initIdx: int32): seq[uint8] =
  ## Closed-loop IMA nibble search shared by WAV and QT framings.
  var st = ImaStatus(predictor: clampI16(samples[0].int32),
    stepIndex: initIdx)
  result = newSeq[uint8](samples.len - 1)
  for i in 1 ..< samples.len:
    var best = 0'u8
    var bestE = high(int32)
    var bestP = st.predictor
    var bestI = st.stepIndex
    for n in 0 ..< 16:
      let (p, idx) = imaStep(st.predictor, st.stepIndex, cast[uint8](n))
      let e = abs(p - samples[i].int32)
      if e < bestE:
        bestE = e
        best = cast[uint8](n)
        bestP = p
        bestI = idx
    result[i - 1] = best
    st.predictor = bestP
    st.stepIndex = bestI

proc bestImaInitIndex(samples: openArray[int16]): int32 =
  ## Picks the initial step index over a coarse grid using the first
  ## samples (fast path), minimizing reconstruction error.
  let probe = min(samples.len, 65)
  var best = 0'i32
  var bestErr = high(int64)
  var idx = 0'i32
  while idx <= 88:
    var st = ImaStatus(predictor: clampI16(samples[0].int32),
      stepIndex: idx)
    var err = 0'i64
    for i in 1 ..< probe:
      var be = high(int32)
      var bp = st.predictor
      var bi = st.stepIndex
      for n in 0 ..< 16:
        let (p, ni) = imaStep(st.predictor, st.stepIndex, cast[uint8](n))
        let e = abs(p - samples[i].int32)
        if e < be:
          be = e
          bp = p
          bi = ni
      st.predictor = bp
      st.stepIndex = bi
      err += be.int64
    if err < bestErr:
      bestErr = err
      best = idx
    idx += 8
  best

proc packImaNibblesLowerFirst(nibbles: openArray[uint8]): seq[uint8] =
  var w = newWriter()
  var i = 0
  while i < nibbles.len:
    let lo = nibbles[i]
    let hi =
      if i + 1 < nibbles.len: nibbles[i + 1] else: 0'u8
    w.writeByte(lo or (hi shl 4))
    i += 2
  w.toBytes()

proc encodeImaWavMonoBlock*(samples: openArray[int16]): seq[uint8] =
  ## Encodes one mono IMA-WAV block (odd frame count >= 1).
  checkDecode(samples.len >= 1 and samples.len mod 2 == 1,
    "adpcm: ima wav mono block needs odd frames >= 1")
  let initIdx = bestImaInitIndex(samples)
  let nibbles = encodeImaNibbles(samples, initIdx)
  var w = newWriter()
  w.writeU16Le(cast[uint16](clampI16(samples[0].int32)))
  w.writeByte(cast[uint8](initIdx))
  w.writeByte(0) # Reserved.
  w.writeBytes(packImaNibblesLowerFirst(nibbles))
  w.toBytes()

proc encodeImaWavStereoBlock*(left, right: openArray[int16]): seq[uint8] =
  ## Encodes one stereo IMA-WAV block ((frames-1) multiple of 8).
  checkDecode(left.len == right.len and left.len >= 1 and
    (left.len - 1) mod 8 == 0,
    "adpcm: ima wav stereo needs (frames-1) multiple of 8")
  let li = bestImaInitIndex(left)
  let ri = bestImaInitIndex(right)
  let lnib = encodeImaNibbles(left, li)
  let rnib = encodeImaNibbles(right, ri)
  var w = newWriter()
  w.writeU16Le(cast[uint16](clampI16(left[0].int32)))
  w.writeByte(cast[uint8](li))
  w.writeByte(0)
  w.writeU16Le(cast[uint16](clampI16(right[0].int32)))
  w.writeByte(cast[uint8](ri))
  w.writeByte(0)
  # Interleave in 8-frame groups: 4 bytes L, 4 bytes R per group.
  let groups = (left.len - 1) div 8
  for g in 0 ..< groups:
    for b in 0 ..< 4:
      let o = g * 8 + b * 2
      w.writeByte(lnib[o] or (lnib[o + 1] shl 4))
    for b in 0 ..< 4:
      let o = g * 8 + b * 2
      w.writeByte(rnib[o] or (rnib[o + 1] shl 4))
  w.toBytes()

proc encodeImaQtMonoBlock*(samples: openArray[int16]): seq[uint8] =
  ## Encodes one 64-frame IMA-QT block (2-byte BE header + 32 bytes).
  checkDecode(samples.len == 64, "adpcm: ima-qt mono block needs 64 frames")
  let initIdx = bestImaInitIndex(samples)
  let nibbles = encodeImaNibbles(samples, initIdx)
  let pred = clampI16(samples[0].int32)
  var w = newWriter()
  w.writeU16Be((cast[uint16](pred) and 0xff80'u16) or
    cast[uint16](min(initIdx, 88)))
  w.writeBytes(packImaNibblesLowerFirst(nibbles))
  w.toBytes()

proc encodeImaQtStereoBlock*(left, right: openArray[int16]): seq[uint8] =
  checkDecode(left.len == 64 and right.len == 64,
    "adpcm: ima-qt stereo block needs 64 frames per channel")
  encodeImaQtMonoBlock(left) & encodeImaQtMonoBlock(right)
