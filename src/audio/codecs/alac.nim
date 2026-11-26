## Apple Lossless Audio Codec (ALAC) decoder (no encoder — encoders for
## ALAC are out of scope; Symphonia ships decode-only too).
##
## Ports `symphonia-codec-alac` (MagicCookie from `symphonia-common`
## apple/audio/alac): 24/48-byte magic cookie (with `frma`/`alac` atom
## prefix skips) incl. CoreAudio channel-layout mapping, SCE/CPE/LFE/
## DSE/FIL raw framing, subframe Rice coding with history + zero runs,
## LPC prediction with adaptive coefficients, mid-side decorrelation,
## tail-bit reattachment. Output is planar `sfS32`, left-justified to
## 32 bits. Bitstream is MSB-first (`LtrBitReader`).

import std/bitops
import std/math
import std/options
import ./../audio
import ./../codecs
import ./../errors
import ./../io
import ./../packet
import ./../source
import ./../units

type
  AlacCookie* = object
    frameLength*: uint32
    bitDepth*: int
    pb*: int
    mb*: int
    kb*: int
    numChannels*: int
    sampleRate*: uint32
    channels*: Channels

proc alacChannelsByCount*(n: int): Channels =
  case n
  of 1:
    ChMono
  of 2:
    ChStereo
  of 3:
    Ch3
  of 4:
    ChQuad
  of 5:
    Ch5
  of 6:
    Ch51
  of 7:
    Ch7
  of 8:
    Ch71
  else:
    raise decodeError("common (alac): unknown channel layout for number of channels")

proc readAlacCookie*(data: openArray[uint8]): AlacCookie =
  ## Parses an ALAC magic cookie (24 or 48 bytes, optional 12-byte
  ## `frma`/`alac` atom prefixes).
  if data.len < 24:
    raise unsupportedError("common (alac): magic cookie size too small")
  var off = 0
  if data[4] == 0x66'u8 and data[5] == 0x72'u8 and data[6] == 0x6d'u8 and
      data[7] == 0x61'u8:
    off = 12
  if data.len - off >= 12 and data[off + 4] == 0x61'u8 and
      data[off + 5] == 0x6c'u8 and data[off + 6] == 0x61'u8 and
      data[off + 7] == 0x63'u8:
    off += 12
  let blen = data.len - off
  if blen != 24 and blen != 48:
    raise unsupportedError("common (alac): invalid magic cookie size")
  var r = newReader(data.toOpenArray(off, data.len - 1))
  let frameLength = r.readU32Be()
  let compat = r.readByte()
  let bitDepth = r.readByte().int
  let pb = r.readByte().int
  let mb = r.readByte().int
  let kb = r.readByte().int
  let nch = r.readByte().int
  discard r.readU16Be()
  discard r.readU32Be()
  discard r.readU32Be()
  let rate = r.readU32Be()
  if compat > 0:
    raise unsupportedError("common (alac): not compatible with alac version 0")
  if bitDepth > 32:
    raise decodeError("common (alac): invalid bit depth")
  if nch < 1 or nch > 8:
    raise decodeError("common (alac): invalid number of channels")
  var channels = alacChannelsByCount(nch)
  if blen == 48:
    if r.readU32Be() != 24:
      raise decodeError("common (alac): invalid channel layout info size")
    if not (r.readByte() == 0x63'u8 and r.readByte() == 0x68'u8 and
        r.readByte() == 0x61'u8 and r.readByte() == 0x6e'u8):
      raise decodeError("common (alac): invalid channel layout info id")
    if r.readU32Be() != 0:
      raise decodeError("common (alac): invalid channel layout info version")
    let tag = r.readU32Be()
    let layout =
      case tag
      of 0x640001'u32:
        ChMono
      of 0x650002'u32:
        ChStereo
      of 0x710003'u32:
        Ch3
      of 0x740004'u32:
        ChQuad
      of 0x780005'u32:
        Ch5
      of 0x7c0006'u32:
        Ch51
      of 0x8e0007'u32:
        Ch7
      of 0x7f0008'u32:
        Ch71
      else:
        raise decodeError("common (alac): invalid channel layout tag")
    if nch != layout.channelCount():
      raise decodeError(
        "common (alac): the number of channels differs from the channel layout")
    if r.readU32Be() != 0 or r.readU32Be() != 0:
      raise decodeError(
        "common (alac): reserved values in channel layout info are not 0")
    channels = layout
  AlacCookie(frameLength: frameLength, bitDepth: bitDepth, pb: pb,
    mb: mb, kb: kb, numChannels: nch, sampleRate: rate, channels: channels)

proc alacChannelMap*(channels: Channels): array[8, int] =
  ## ALAC stream channel index -> output plane index.
  if channels == ChMono:
    [0, 0, 0, 0, 0, 0, 0, 0]
  elif channels == ChStereo:
    [0, 1, 0, 0, 0, 0, 0, 0]
  elif channels == Ch3:
    [2, 0, 1, 0, 0, 0, 0, 0]
  elif channels == ChQuad:
    [2, 0, 1, 3, 0, 0, 0, 0]
  elif channels == Ch5:
    [2, 0, 1, 3, 4, 0, 0, 0]
  elif channels == Ch51:
    [2, 0, 1, 4, 5, 3, 0, 0]
  elif channels == Ch7:
    [2, 0, 1, 5, 6, 4, 3, 0]
  elif channels == Ch71:
    [2, 4, 5, 0, 1, 6, 7, 3]
  else:
    raise decodeError("alac: unsupported channel layout")

# ------------------------------------------------------------ codec ---

type
  AlacElementChannel* = object
    bps*: int
    kb*: uint32
    mb*: uint32
    mode*: int
    shift*: int
    pbFactor*: uint32
    lpcOrder*: int
    lpcCoeffs*: array[32, int32]

proc readAlacElementChannel*[L](bs: var L; cookie: AlacCookie;
    bps: int): AlacElementChannel =
  try:
    result.mode = bs.readLtrBits(4).int
    result.shift = bs.readLtrBits(4).int
    result.pbFactor = bs.readLtrBits(3) * cookie.pb.uint32 div 4
    result.lpcOrder = bs.readLtrBits(5).int
    for i in 0 ..< result.lpcOrder:
      result.lpcCoeffs[i] = bs.readLtrSigned(16)
  except EndOfStream:
    raise decodeError("alac: truncated element header")
  result.bps = bps
  result.kb = cookie.kb.uint32
  result.mb = cookie.mb.uint32

proc lg3a*(v: uint32): uint32 {.inline.} =
  31'u32 - countLeadingZeroBits((v shr 9) + 3).uint32

proc readLtrUnaryCapped[L](bs: var L; cap: int): int =
  ## Counts leading 1 bits up to `cap`; the terminating 0 is consumed
  ## unless the cap is reached.
  while result < cap:
    var b = 0'u32
    try:
      b = bs.readLtrBits(1)
    except EndOfStream:
      raise decodeError("alac: truncated rice code")
    if b == 0:
      return
    inc result

proc readRiceCode*[L](bs: var L; k, bps: uint32): uint32 =
  let prefix = readLtrUnaryCapped(bs, 9).uint32
  if prefix > 8:
    try:
      return bs.readLtrBits(bps.int)
    except EndOfStream:
      raise decodeError("alac: truncated rice code")
  elif k > 1:
    var value = (prefix shl k) - prefix
    var suffix = 0'u32
    try:
      suffix = bs.readLtrBits((k - 1).int)
    except EndOfStream:
      raise decodeError("alac: truncated rice code")
    if suffix > 0:
      try:
        value = value + (suffix shl 1) + bs.readLtrBits(1) - 1
      except EndOfStream:
        raise decodeError("alac: truncated rice code")
    return value
  elif k == 1:
    return prefix
  else:
    return 0

proc riceToSigned*(v: uint32): int32 {.inline.} =
  cast[int32](v shr 1) xor -(cast[int32](v and 1))

proc clipMsbs*(v: int32; n: int): int32 {.inline.} =
  (v shl n) shr n

proc readResiduals*[L](bs: var L; e: var AlacElementChannel;
    dst: var openArray[int32]) =
  var mb = e.mb
  var signToggle = 0'u32
  var zeroRunEnd = 0
  for i in 0 ..< dst.len:
    if i < zeroRunEnd:
      continue
    let k = lg3a(mb)
    let val = readRiceCode(bs, min(k, e.kb), e.bps.uint32) + signToggle
    dst[i] = riceToSigned(val)
    if val > 0xffff'u32:
      mb = 0xffff'u32
    else:
      mb = mb + e.pbFactor * val - ((e.pbFactor * mb) shr 9)
    signToggle = 0
    if mb < 128 and i + 1 < dst.len:
      let k2 = (countLeadingZeroBits(mb) - 24).uint32 + ((mb + 16) shr 6)
      let zeros = readRiceCode(bs, min(k2, e.kb), 16)
      if zeros < 0xffff'u32:
        signToggle = 1
      mb = 0
      zeroRunEnd = i + 1 + zeros.int

# ---------------------------------------------------------- predict ---

proc predictSamples(e: var AlacElementChannel; dst: var openArray[int32]) =
  if e.mode > 0 and e.mode < 15:
    raise decodeError("alac: invalid mode")
  if e.lpcOrder == 0 or dst.len == 0:
    return
  let numClip = 32 - e.bps
  if e.lpcOrder == 31 or e.mode == 15:
    for i in 1 ..< dst.len:
      dst[i] = clipMsbs(dst[i] +% dst[i - 1], numClip)
  let order = e.lpcOrder
  for i in 1 ..< min(1 + order, dst.len):
    dst[i] = clipMsbs(dst[i] +% dst[i - 1], numClip)
  for i in 1 + order ..< dst.len:
    var res = dst[i]
    let past0 = dst[i - order - 1]
    var sum = 0'i32
    for j in 0 ..< order:
      sum = sum +% (e.lpcCoeffs[order - 1 - j] *%
        (dst[i - order + j] -% past0))
    let shiftVal = e.shift
    let val = (sum +% ((1'i32 shl shiftVal) shr 1)) shr shiftVal
    dst[i] = clipMsbs(dst[i] +% past0 +% val, numClip)
    if res != 0:
      if res > 0:
        for j in 0 ..< order:
          let ci = order - 1 - j
          let sample = dst[i - order + j]
          let v = past0 -% sample
          let sign = sgn(v).int32
          e.lpcCoeffs[ci] = e.lpcCoeffs[ci] -% sign
          res = res -% ((1'i32 +% j.int32) *% ((sign *% v) shr shiftVal))
          if res <= 0:
            break
      else:
        for j in 0 ..< order:
          let ci = order - 1 - j
          let sample = dst[i - order + j]
          let v = past0 -% sample
          let sign = sgn(v).int32
          e.lpcCoeffs[ci] = e.lpcCoeffs[ci] +% sign
          res = res -% ((1'i32 +% j.int32) *% ((-sign *% v) shr shiftVal))
          if res >= 0:
            break

proc decorrelateMidSide(s0, s1: var openArray[int32]; weight: int32;
    shift: int) =
  assert s0.len == s1.len
  for i in 0 ..< s0.len:
    let a = s0[i]
    let b = s1[i]
    s0[i] = a +% b -% ((b *% weight) shr shift)
    s1[i] = s0[i] -% b

# ------------------------------------------------------------ frame ---

proc decodeSceOrCpe*[L](cookie: AlacCookie; bs: var L;
    tails: var openArray[uint16]; out0: var openArray[int32];
    out1: var openArray[int32]; hasOut1: bool): int =
  let isCpe = hasOut1
  discard bs.readLtrBits(4) # element instance tag
  try:
    if bs.readLtrBits(12) != 0:
      raise decodeError("alac: unused header bits not 0")
  except EndOfStream:
    raise decodeError("alac: truncated element header")
  var isPartial = false
  var shift = 0
  var isUncompressed = false
  try:
    isPartial = bs.readLtrBool()
    shift = (bs.readLtrBits(2).int) * 8
    isUncompressed = bs.readLtrBool()
  except EndOfStream:
    raise decodeError("alac: truncated element header")
  if shift >= 24 or shift >= cookie.bitDepth:
    raise decodeError("alac: invalid shift value")
  var numSamples = cookie.frameLength.int
  if isPartial:
    try:
      numSamples = bs.readLtrBits(32).int
    except EndOfStream:
      raise decodeError("alac: truncated element header")
  if numSamples > cookie.frameLength.int:
    raise decodeError("alac: frame length exceeds maximum frame length")
  if not isUncompressed:
    let bpsi = cookie.bitDepth - shift + (if isCpe: 1 else: 0)
    if bpsi > 32:
      raise decodeError("alac: bits per coded sample exceed 32")
    var midShift = 0
    var midWeight = 0'i32
    try:
      midShift = bs.readLtrBits(8).int
      midWeight = bs.readLtrSigned(8)
    except EndOfStream:
      raise decodeError("alac: truncated element header")
    if not isCpe and (shift != 0 or midWeight != 0):
      raise decodeError("alac: invalid mixing information for mono channel")
    var elem0 = readAlacElementChannel(bs, cookie, bpsi)
    var elem1 = AlacElementChannel()
    if isCpe:
      elem1 = readAlacElementChannel(bs, cookie, bpsi)
    if shift > 0:
      let n = (if isCpe: 2 else: 1) * numSamples
      if n > tails.len:
        raise decodeError("alac: invalid data")
      try:
        for i in 0 ..< n:
          tails[i] = bs.readLtrBits(shift).uint16
      except EndOfStream:
        raise decodeError("alac: truncated tail bits")
    readResiduals(bs, elem0, out0.toOpenArray(0, numSamples - 1))
    predictSamples(elem0, out0.toOpenArray(0, numSamples - 1))
    if isCpe:
      if not hasOut1:
        raise decodeError("alac: missing second channel element")
      readResiduals(bs, elem1, out1.toOpenArray(0, numSamples - 1))
      predictSamples(elem1, out1.toOpenArray(0, numSamples - 1))
      if midWeight != 0:
        if midShift > 31:
          raise decodeError("alac: mid_side_shift is greater than 31 bit")
        decorrelateMidSide(out0.toOpenArray(0, numSamples - 1),
          out1.toOpenArray(0, numSamples - 1), midWeight, midShift)
    if shift > 0:
      if isCpe:
        for i in 0 ..< numSamples:
          out0[i] = (out0[i] shl shift) or tails[2 * i].int32
          out1[i] = (out1[i] shl shift) or tails[2 * i + 1].int32
      else:
        for i in 0 ..< numSamples:
          out0[i] = (out0[i] shl shift) or tails[i].int32
  else:
    try:
      if isCpe:
        for i in 0 ..< numSamples:
          out0[i] = bs.readLtrSigned(cookie.bitDepth)
          out1[i] = bs.readLtrSigned(cookie.bitDepth)
      else:
        for i in 0 ..< numSamples:
          out0[i] = bs.readLtrSigned(cookie.bitDepth)
    except EndOfStream:
      raise decodeError("alac: truncated uncompressed samples")
  numSamples

# ---------------------------------------------------------- decoder ---

type
  AlacDecoder* = ref object of AudioDecoder
    opts*: AudioDecoderOptions
    params*: AudioCodecParameters
    cookie*: AlacCookie
    chanMap*: array[8, int]
    tails*: seq[uint16]
    spec*: AudioSpec
    buf*: AudioSamples

proc newAlacDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): AlacDecoder =
  if params.codec != CodecAlac:
    raise unsupportedError("alac: invalid codec")
  if params.extraData.len == 0:
    raise unsupportedError("alac: missing extra data")
  let cookie = readAlacCookie(params.extraData)
  const MaxFrame = 4096'u32 * 16
  if cookie.frameLength > MaxFrame:
    raise unsupportedError("common (alac): frame length too large")
  let spec = newAudioSpec(cookie.sampleRate, cookie.channels)
  var fixed = params
  fixed.sampleRate = some(cookie.sampleRate)
  fixed.channels = some(cookie.channels)
  fixed.bitsPerSample = some(cookie.bitDepth.uint32)
  let maxTails = min(2, cookie.numChannels) * cookie.frameLength.int
  AlacDecoder(opts: opts, params: fixed, cookie: cookie,
    chanMap: alacChannelMap(cookie.channels),
    tails: newSeq[uint16](maxTails), spec: spec,
    buf: newAudioSamples(sfS32, spec, cookie.frameLength.int))

proc decodeAlacData[L](d: AlacDecoder; bs: var L) =
  ## Packet core over any MSB-first bit cursor (owning or view).
  let nch = d.cookie.numChannels
  var nextCh = 0
  var numFrames = 0
  d.buf.s32.clear()
  d.buf.s32.renderWith(d.cookie.frameLength.int, i):
    discard i
  for p in 0 ..< d.buf.s32.planes.len:
    for i in 0 ..< d.buf.s32.planes[p].len:
      d.buf.s32.planes[p][i] = 0
  try:
    while true:
      let tag = bs.readLtrBits(3)
      case tag
      of 0, 3:
        let plane = d.chanMap[nextCh]
        numFrames = decodeSceOrCpe(d.cookie, bs, d.tails,
          d.buf.s32.planes[plane].toOpenArray(0, d.cookie.frameLength.int - 1),
          d.buf.s32.planes[plane].toOpenArray(0, d.cookie.frameLength.int - 1),
          false)
        inc nextCh
      of 1:
        if nextCh + 2 > nch:
          break
        let p0 = d.chanMap[nextCh]
        let p1 = d.chanMap[nextCh + 1]
        numFrames = decodeSceOrCpe(d.cookie, bs, d.tails,
          d.buf.s32.planes[p0].toOpenArray(0, d.cookie.frameLength.int - 1),
          d.buf.s32.planes[p1].toOpenArray(0, d.cookie.frameLength.int - 1),
          true)
        nextCh += 2
      of 4:
        discard bs.readLtrBits(4)
        let align = bs.readLtrBool()
        var count = bs.readLtrBits(8).int
        if count == 255:
          count += bs.readLtrBits(8).int
        if align:
          bs.realignLtr()
        bs.ignoreLtrBits(count * 8)
      of 6:
        var count = bs.readLtrBits(4).int
        if count == 15:
          count += bs.readLtrBits(8).int - 1
        bs.ignoreLtrBits(count * 8)
      of 2, 5:
        raise decodeError("alac: unsupported element")
      of 7:
        break
      else:
        raise decodeError("alac: invalid data")
      if nextCh >= nch:
        break
  except EndOfStream:
    raise decodeError("alac: truncated packet")
  d.buf.s32.truncate(numFrames)
  let shift = 32 - d.cookie.bitDepth
  if shift > 0:
    for p in 0 ..< d.buf.s32.planes.len:
      for i in 0 ..< numFrames:
        d.buf.s32.planes[p][i] = d.buf.s32.planes[p][i] shl shift

proc decodeAlacPacket(d: AlacDecoder; data: seq[uint8]) =
  ## Owning entry: copies `data` into a cached reader (as before).
  var bs = newLtrBitReader(data)
  d.decodeAlacData(bs)

proc decodeAlacWin*(d: AlacDecoder; win: ByteWindow) =
  ## Zero-copy decode straight from a byte window (mapping or pool).
  var vr = viewReaderOf(win)
  var vbs = vr.restLtr()
  d.decodeAlacData(vbs)

proc decodeAlacView*(d: AlacDecoder; src: MappedSource; off, len: int) =
  ## Zero-copy decode straight from a mapping window.
  d.decodeAlacWin(byteWindow(src, off, len))

proc applyGaplessTrims(d: AlacDecoder; trimStart, trimEnd: Duration) =
  if d.opts.gapless and d.buf.framesOf() > 0:
    let total = d.buf.framesOf()
    let dropFirst = min(trimStart.get.int, total)
    let keep = total - dropFirst
    let dropLast = min(trimEnd.get.int, keep)
    if dropFirst > 0 or dropLast > 0:
      d.buf.s32.shift(dropFirst)
      d.buf.s32.truncate(d.buf.s32.numFrames - dropLast)

method codecParams*(d: AlacDecoder): AudioCodecParameters = d.params

method reset*(d: AlacDecoder) =
  discard

method decodePacket*(d: AlacDecoder; pkt: Packet): AudioSamples =
  try:
    d.decodeAlacPacket(pkt.data)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  except EndOfStream:
    d.buf.clearSamples()
    raise decodeError("alac: truncated packet")
  except IndexDefect, RangeDefect:
    d.buf.clearSamples()
    raise decodeError("alac: invalid bitstream")
  d.applyGaplessTrims(pkt.trimStart, pkt.trimEnd)
  d.buf

proc decodePacketView*(d: AlacDecoder; v: PacketView): AudioSamples =
  ## View-based `decodePacket`: identical output (incl. gapless trims),
  ## no packet copy.
  try:
    d.decodeAlacWin(v.win)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  except EndOfStream:
    d.buf.clearSamples()
    raise decodeError("alac: truncated packet")
  except IndexDefect, RangeDefect:
    d.buf.clearSamples()
    raise decodeError("alac: invalid bitstream")
  d.applyGaplessTrims(v.trimStart, v.trimEnd)
  d.buf

method lastDecoded*(d: AlacDecoder): AudioSamples = d.buf

proc alacDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newAlacDecoder(params, opts)

proc registerAlac*() =
  registerAudioDecoder(CodecAlac, alacDecoderFactory)
