## FLAC codec: decoder plus encoder.
##
## Decoder ports `symphonia-bundle-flac` (`decoder.rs`): constant, verbatim,
## fixed (orders 0-4) and LPC (orders 1-32) subframes, Rice/Rice2
## partitions with escape, wasted bits, mid/side + left/right-side
## decorrelation, MSB-aligned S32 output, MD5 validation. Wrapping
## arithmetic matches the reference release behavior bit-for-bit and
## never raises on hostile input.
##
## The encoder is new work (subset: fixed predictors + verbatim, Rice
## order-0 partitions, independent channels, optional wasted bits).

import std/options
import ./../audio
import ./../checksum
import ./../codecs
import ./../errors
import ./../io
import ./../packet

# ------------------------------------------------------------ StreamInfo ---

type
  StreamInfo* = object
    ## Parsed STREAMINFO block (34 bytes). Lives here (rather than with
    ## the demuxer) so the decoder can parse `extra_data`, mirroring how
    ## Symphonia shares it via `symphonia-common`.
    blockLenMin*, blockLenMax*: uint16
    frameByteLenMin*, frameByteLenMax*: uint32
    sampleRate*: uint32
    channels*: Channels
    bitsPerSample*: uint32
    nSamples*: Option[uint64]
    md5*: Option[array[16, uint8]]

proc parseStreamInfo*(data: openArray[uint8]): StreamInfo =
  if data.len != 34:
    raise decodeError("flac: invalid stream info block size")
  var r = newReader(data)
  result.blockLenMin = r.readU16Be()
  result.blockLenMax = r.readU16Be()
  if result.blockLenMin < 16 or result.blockLenMax < 16:
    raise decodeError("flac: minimum block length is 16 samples")
  if result.blockLenMax < result.blockLenMin:
    raise decodeError("flac: maximum block length is less than the minimum")
  result.frameByteLenMin = r.readU24Be()
  result.frameByteLenMax = r.readU24Be()
  if result.frameByteLenMin > 0 and result.frameByteLenMax > 0 and
      result.frameByteLenMax < result.frameByteLenMin:
    raise decodeError("flac: maximum frame length is less than the minimum")
  var br = newBitReader(r.readBytesExact(8))
  result.sampleRate = br.readBits(20)
  if result.sampleRate == 0:
    raise decodeError("flac: stream sample rate out of bounds")
  let nch = br.readBits(3) + 1
  result.channels = flacChannels(nch.int)
  result.bitsPerSample = br.readBits(5) + 1
  if result.bitsPerSample < 4 or result.bitsPerSample > 32:
    raise decodeError("flac: stream bits per sample are out of bounds")
  let total = br.readBits64(36)
  result.nSamples = if total == 0: none(uint64) else: some(total)
  var digest: array[16, uint8]
  let md5bytes = r.readBytesExact(16)
  for i in 0 ..< 16:
    digest[i] = md5bytes[i]
  var zero = true
  for b in digest:
    if b != 0:
      zero = false
      break
  result.md5 = if zero: none(array[16, uint8]) else: some(digest)

proc writeStreamInfo*(info: StreamInfo): seq[uint8] =
  ## Serializes to the 34-byte block (new work, for the muxer).
  var w = newWriter()
  w.writeU16Be(info.blockLenMin)
  w.writeU16Be(info.blockLenMax)
  w.writeU24Be(info.frameByteLenMin)
  w.writeU24Be(info.frameByteLenMax)
  var bw = newBitWriter()
  bw.writeBits(info.sampleRate, 20)
  bw.writeBits(info.channels.channelCount().uint32 - 1, 3)
  bw.writeBits(info.bitsPerSample - 1, 5)
  let total = if info.nSamples.isSome: info.nSamples.get else: 0'u64
  bw.writeBits(cast[uint32](total shr 32) and 0x0f'u32, 4)
  bw.writeBits(cast[uint32](total and 0xffff_ffff'u64), 32)
  bw.flush()
  w.writeBytes(bw.toBytes())
  if info.md5.isSome:
    w.writeBytes(info.md5.get)
  else:
    w.writeBytes(newSeq[uint8](16))
  w.toBytes()

# ---------------------------------------------------------- Frame header ---

type
  BlockSequenceKind* = enum
    bsSample
    bsFrame

  BlockSequence* = object
    case kind*: BlockSequenceKind
    of bsSample:
      sample*: uint64
    of bsFrame:
      frame*: uint32

  ChannelAssignmentKind* = enum
    caIndependent
    caLeftSide
    caRightSide
    caMidSide

  ChannelAssignment* = object
    case kind*: ChannelAssignmentKind
    of caIndependent:
      channels*: uint32
    else:
      discard

  FrameHeader* = object
    sequence*: BlockSequence
    blockSamples*: uint16
    assignment*: ChannelAssignment
    bitsPerSample*: Option[uint32]
    sampleRate*: Option[uint32]

const
  FlacMinFrameHeaderSize* = 6
  FlacMaxFrameHeaderSize* = 16
  FlacMaxFrameSize* = 16 * 1024 * 1024

proc syncFrame*(r: var Reader): uint16 =
  ## Scans for the 14-bit sync code (`0xFFF8` masked), returning the full
  ## 16-bit word (low bit = blocking strategy).
  var sync = 0'u16
  while (sync and 0xfffc'u16) != 0xfff8'u16:
    sync = (sync shl 8) or r.readByte().uint16
  sync

proc readFrameHeader*(r: var Reader; sync: uint16): FrameHeader =
  ## Parses and CRC8-verifies a frame header (sync word included in CRC).
  var crcBytes: seq[uint8] = @[cast[uint8](sync shr 8), cast[uint8](sync)]
  template takeByte(): uint8 =
    let bb = r.readByte()
    crcBytes.add(bb)
    bb
  template takeBytes(n: int): seq[uint8] =
    let bq = r.readBytesExact(n)
    crcBytes.add(bq)
    bq
  let fixed = (sync and 1) == 0
  let descBytes = takeBytes(2)
  let desc = (descBytes[0].uint16 shl 8) or descBytes[1].uint16
  let blockSizeEnc = (desc shr 12) and 0xf
  let sampleRateEnc = (desc shr 8) and 0xf
  let channelsEnc = (desc shr 4) and 0xf
  let bpsEnc = (desc shr 1) and 0x7
  if (desc and 1) == 1:
    raise decodeError("flac: frame header reserved bit is not set to mandatory value")
  # Parse the UTF-8 sequence number, folding every consumed byte into the
  # header CRC.
  var seqNum: uint64
  let first = takeByte()
  let mask: uint8 =
    if first < 0x80: 0x80'u8 # sentinel: single byte
    elif first < 0xe0: 0x1f
    elif first < 0xf0: 0x0f
    elif first < 0xf8: 0x07
    elif first < 0xfc: 0x03
    elif first < 0xfe: 0x01
    elif first == 0xfe: 0x00
    else: raise decodeError("flac: frame sequence number is not valid")
  if mask == 0x80'u8:
    seqNum = first.uint64
  else:
    seqNum = (first and mask).uint64
    var zeros = 0
    var m = mask
    while (m and 0x80'u8) == 0:
      inc zeros
      m = (m shl 1) and 0xff'u8
    for _ in 2 ..< zeros:
      seqNum = (seqNum shl 6) or (takeByte() and 0x3f'u8).uint64
  if fixed:
    if seqNum > 0x7fff_ffff'u64:
      raise decodeError("flac: frame sequence number exceeds 31-bits")
    result.sequence = BlockSequence(kind: bsFrame, frame: cast[uint32](seqNum))
  else:
    if seqNum > 0x000f_ffff_ffff'u64:
      raise decodeError("flac: sample sequence number exceeds 36-bits")
    result.sequence = BlockSequence(kind: bsSample, sample: seqNum)
  var blockSamples: uint16
  case blockSizeEnc
  of 1: blockSamples = 192
  of 2 .. 5: blockSamples = cast[uint16](576 * (1 shl (blockSizeEnc - 2)))
  of 6: blockSamples = takeByte().uint16 + 1
  of 7:
    let bs = takeBytes(2)
    let v = (bs[0].uint16 shl 8) or bs[1].uint16
    if v == 0xffff'u16:
      raise decodeError("flac: block size not allowed to be greater than 65535")
    blockSamples = v + 1
  of 8 .. 15: blockSamples = cast[uint16](256 * (1 shl (blockSizeEnc - 8)))
  else: raise decodeError("flac: block size set to reserved value")
  result.blockSamples = blockSamples
  var rate: Option[uint32] = none(uint32)
  case sampleRateEnc
  of 0: discard
  of 1: rate = some(88_200'u32)
  of 2: rate = some(176_400'u32)
  of 3: rate = some(192_000'u32)
  of 4: rate = some(8_000'u32)
  of 5: rate = some(16_000'u32)
  of 6: rate = some(22_050'u32)
  of 7: rate = some(24_000'u32)
  of 8: rate = some(32_000'u32)
  of 9: rate = some(44_100'u32)
  of 10: rate = some(48_000'u32)
  of 11: rate = some(96_000'u32)
  of 12: rate = some(takeByte().uint32 * 1000)
  of 13:
    let b = takeBytes(2)
    rate = some((b[0].uint32 shl 8) or b[1].uint32)
  of 14:
    let b = takeBytes(2)
    rate = some(((b[0].uint32 shl 8) or b[1].uint32) * 10)
  else: raise decodeError("flac: sample rate set to reserved value")
  if rate.isSome and (rate.get < 1 or rate.get > 655_350):
    raise decodeError("flac: sample rate out of bounds")
  result.sampleRate = rate
  var bps: Option[uint32] = none(uint32)
  case bpsEnc
  of 0: discard
  of 1: bps = some(8'u32)
  of 2: bps = some(12'u32)
  of 4: bps = some(16'u32)
  of 5: bps = some(20'u32)
  of 6: bps = some(24'u32)
  of 7: bps = some(32'u32)
  else: raise decodeError("flac: bits per sample set to reserved value")
  result.bitsPerSample = bps
  case channelsEnc
  of 0 .. 7:
    result.assignment = ChannelAssignment(kind: caIndependent,
      channels: channelsEnc + 1)
  of 8:
    result.assignment = ChannelAssignment(kind: caLeftSide)
  of 9:
    result.assignment = ChannelAssignment(kind: caRightSide)
  of 10:
    result.assignment = ChannelAssignment(kind: caMidSide)
  else:
    raise decodeError("flac: channel assignment set to reserved value")
  let computed = crc8(crcBytes)
  let expected = r.readByte()
  if computed != expected:
    raise decodeError("flac: computed frame header CRC does not match expected CRC")

proc isLikelyFrameHeader*(buf: openArray[uint8]): bool =
  if buf.len < FlacMinFrameHeaderSize:
    return false
  if buf[0] != 0xff'u8:
    return false
  if (buf[1] and 0xfc'u8) != 0xf8'u8:
    return false
  if (buf[2] and 0xf0'u8) == 0x00'u8:
    return false
  if (buf[2] and 0x0f'u8) == 0x0f'u8:
    return false
  if ((buf[3] and 0xf0'u8) shr 4) >= 0x0b'u8:
    return false
  if (buf[3] and 0x0e'u8) == 0x06'u8:
    return false
  if (buf[3] and 0x01'u8) == 1'u8:
    return false
  true

# -------------------------------------------------------------- Validator ---

type
  FlacValidator* = object
    md5: Md5

proc initValidator*(v: var FlacValidator) =
  v.md5.initMd5()

proc updateValidator*(v: var FlacValidator; buf: AudioBuffer[int32];
    bps: uint32) =
  ## Feeds interleaved LE samples at byte-rounded width (pre-shift).
  var bytesPerSample: int
  if bps == 0:
    return
  elif bps <= 8:
    bytesPerSample = 1
  elif bps <= 16:
    bytesPerSample = 2
  elif bps <= 24:
    bytesPerSample = 3
  elif bps <= 32:
    bytesPerSample = 4
  else:
    raise decodeError("flac: invalid bit width")
  let nch = buf.planes.len
  let n = buf.numFrames
  var scratch = newSeq[uint8](nch * n * bytesPerSample)
  for ch in 0 ..< nch:
    for i in 0 ..< n:
      let s = buf.planes[ch][i]
      let base = (i * nch + ch) * bytesPerSample
      case bytesPerSample
      of 1:
        scratch[base] = cast[uint8](cast[int8](s))
      of 2:
        let v = cast[uint16](cast[int16](s))
        scratch[base] = v.uint8
        scratch[base + 1] = (v shr 8).uint8
      of 3:
        let v = cast[uint32](s) and 0xffffff'u32
        scratch[base] = v.uint8
        scratch[base + 1] = (v shr 8).uint8
        scratch[base + 2] = (v shr 16).uint8
      else:
        let v = cast[uint32](s)
        scratch[base] = v.uint8
        scratch[base + 1] = (v shr 8).uint8
        scratch[base + 2] = (v shr 16).uint8
        scratch[base + 3] = (v shr 24).uint8
  v.md5.update(scratch)

proc validatorDigest*(v: FlacValidator): array[16, uint8] =
  v.md5.digest()

# ------------------------------------------------------------ Subframes ---

proc riceSignedToI32*(word: uint32): int32 =
  let div2 = cast[int32](word shr 1)
  let sign = -cast[int32](word and 1)
  div2 xor sign

proc decorrelateLeftSide(left: openArray[int32]; side: var openArray[int32]) =
  for i in 0 ..< side.len:
    side[i] = left[i] -% side[i]

proc decorrelateRightSide(right: openArray[int32]; side: var openArray[int32]) =
  for i in 0 ..< side.len:
    side[i] = side[i] +% right[i]

proc decorrelateMidSide(mid: var openArray[int32]; side: var openArray[int32]) =
  for i in 0 ..< mid.len:
    let m = mid[i]
    let s = side[i]
    let mm = (m shl 1) or (s and 1)
    mid[i] = (mm +% s) shr 1
    side[i] = (mm -% s) shr 1

proc decodeRicePartition(bs: var BitReader; paramWidth: int;
    buf: var openArray[int32]; off, count: int) =
  let riceParam = bs.readBits(paramWidth).int
  if riceParam < (1 shl paramWidth) - 1:
    for i in 0 ..< count:
      let q = bs.readUnaryZeros()
      let r = bs.readBits(riceParam)
      buf[off + i] = riceSignedToI32((q shl riceParam) or r)
  else:
    let residualBits = bs.readBits(5).int
    for i in 0 ..< count:
      buf[off + i] = signExtend(bs.readBits(residualBits), residualBits)

proc decodeResidual(bs: var BitReader; nPrelude: int;
    buf: var openArray[int32]) =
  let methodEnc = bs.readBits(2)
  let paramWidth =
    case methodEnc
    of 0: 4
    of 1: 5
    else: raise decodeError("flac: residual method set to reserved value")
  let order = bs.readBits(4)
  let nPartitions = 1 shl order.int
  let nPartSamples = buf.len shr order.int
  if nPrelude > nPartSamples:
    raise decodeError("flac: residual partition too small for given predictor order")
  if nPartitions * nPartSamples != buf.len:
    raise decodeError("flac: block size is not same as encoded residual")
  var pos = nPrelude
  bs.decodeRicePartition(paramWidth, buf, pos, nPartSamples - nPrelude)
  pos += nPartSamples - nPrelude
  while pos < buf.len:
    let n = min(nPartSamples, buf.len - pos)
    bs.decodeRicePartition(paramWidth, buf, pos, n)
    pos += n

proc decodeConstant(bs: var BitReader; bps: int; buf: var openArray[int32]) =
  let v = signExtend(bs.readBits(bps), bps)
  for s in buf.mitems:
    s = v

proc decodeVerbatim(bs: var BitReader; bps: int; buf: var openArray[int32]) =
  for s in buf.mitems:
    s = signExtend(bs.readBits(bps), bps)

proc fixedPredict(order: int; buf: var openArray[int32]) =
  case order
  of 0: discard
  of 1:
    for i in 1 ..< buf.len:
      buf[i] = buf[i] +% buf[i - 1]
  of 2:
    for i in 2 ..< buf.len:
      let a = -1'i64 *% buf[i - 2].int64
      let b = 2'i64 *% buf[i - 1].int64
      buf[i] = buf[i] +% cast[int32](a +% b)
  of 3:
    for i in 3 ..< buf.len:
      let a = buf[i - 3].int64
      let b = -3'i64 *% buf[i - 2].int64
      let c = 3'i64 *% buf[i - 1].int64
      buf[i] = buf[i] +% cast[int32](a +% b +% c)
  of 4:
    for i in 4 ..< buf.len:
      let a = -1'i64 *% buf[i - 4].int64
      let b = 4'i64 *% buf[i - 3].int64
      let c = -6'i64 *% buf[i - 2].int64
      let d = 4'i64 *% buf[i - 1].int64
      buf[i] = buf[i] +% cast[int32](a +% b +% c +% d)
  else: raise decodeError("flac: fixed predictor orders greater than 4 invalid")

proc lpcPredict(order: int; coeffs: openArray[int32]; shift: int;
    buf: var openArray[int32]) =
  ## Generic order-32 LPC (specialized dispatch is an optimization only).
  const N = 32
  let nPrefill = min(N, buf.len) - order
  for i in order ..< order + nPrefill:
    var predicted = 0'i64
    for j in 0 ..< order:
      predicted = predicted +% coeffs[N - order + j].int64 *%
        buf[i - order + j].int64
    buf[i] = buf[i] +% cast[int32](predicted shr shift)
  if buf.len <= N:
    return
  for i in N ..< buf.len:
    var predicted = 0'i64
    for j in 0 ..< N:
      predicted = predicted +% coeffs[j].int64 *% buf[i - N + j].int64
    buf[i] = buf[i] +% cast[int32](predicted shr shift)

proc decodeFixedLinear(bs: var BitReader; bps, order: int;
    buf: var openArray[int32]) =
  if order > buf.len:
    raise decodeError("flac: fixed predictor order is greater than the block size")
  if order > 0:
    bs.decodeVerbatim(bps, buf.toOpenArray(0, order - 1))
  bs.decodeResidual(order, buf)
  fixedPredict(order, buf)

proc decodeLinear(bs: var BitReader; bps, order: int;
    buf: var openArray[int32]) =
  if order > buf.len:
    raise decodeError("flac: predictor order is greater than the block size")
  if order < 1 or order > 32:
    raise decodeError("flac: predictor order out of range")
  bs.decodeVerbatim(bps, buf.toOpenArray(0, order - 1))
  let qlpPrecision = bs.readBits(4).int + 1
  if qlpPrecision > 15:
    raise decodeError("flac: qlp precision set to reserved value")
  let qlpShift = signExtend(bs.readBits(5), 5)
  if qlpShift < 0:
    raise unsupportedError("flac: lpc shifts less than 0 are not supported")
  var coeffs: array[32, int32]
  for i in 0 ..< order:
    coeffs[31 - i] = signExtend(bs.readBits(qlpPrecision), qlpPrecision)
  bs.decodeResidual(order, buf)
  lpcPredict(order, coeffs, qlpShift.int, buf)

proc decodeSubframe*(bs: var BitReader; frameBps: int;
    buf: var openArray[int32]) =
  if bs.readBit():
    raise decodeError("flac: subframe padding is not 0")
  let enc = bs.readBits(6)
  var order = -1
  var linear = false
  var verbatim = false
  if enc == 0x00:
    discard # Constant.
  elif enc == 0x01:
    verbatim = true
  elif enc >= 0x08 and enc <= 0x0f:
    order = (enc and 0x07).int
    if order > 4:
      raise decodeError("flac: fixed predictor orders of greater than 4 are invalid")
  elif enc >= 0x20 and enc <= 0x3f:
    order = ((enc and 0x1f).int) + 1
    linear = true
  else:
    raise decodeError("flac: subframe type set to reserved value")
  let dropped =
    if bs.readBit(): bs.readUnaryZeros().int + 1
    else: 0
  if dropped > frameBps:
    raise decodeError("flac: dropped bits per sample is greater than the frame bits per sample")
  let bps = frameBps - dropped
  if enc == 0x00:
    bs.decodeConstant(bps, buf)
  elif verbatim:
    bs.decodeVerbatim(bps, buf)
  elif linear:
    bs.decodeLinear(bps, order, buf)
  else:
    bs.decodeFixedLinear(bps, order, buf)
  if dropped > 0:
    for s in buf.mitems:
      s = s shl dropped

# ------------------------------------------------------------- Decoder ---

type
  FlacDecoder* = ref object of AudioDecoder
    params*: AudioCodecParameters
    info*: StreamInfo
    buf*: AudioSamples # sfS32, MSB-aligned output.
    verify*: bool
    validator*: FlacValidator

proc isSupportedFlacCodec*(id: AudioCodecId): bool {.inline.} =
  id == CodecFlac

proc newFlacDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): FlacDecoder =
  if params.codec != CodecFlac:
    raise unsupportedError("flac: invalid codec")
  if params.extraData.len == 0:
    raise unsupportedError("flac: missing extra data")
  let info = parseStreamInfo(params.extraData)
  var amended = params
  amended.sampleRate = some(info.sampleRate)
  amended.bitsPerSample = some(info.bitsPerSample)
  amended.maxFramesPerPacket = some(info.blockLenMax.uint64)
  amended.channels = some(info.channels)
  if info.md5.isSome:
    amended.verificationMd5 = info.md5
  let spec = newAudioSpec(info.sampleRate, info.channels)
  result = FlacDecoder(params: amended, info: info,
    buf: newAudioSamples(sfS32, spec, info.blockLenMax.int),
    verify: opts.verify)
  result.validator.initValidator()

proc decodeFrames(d: FlacDecoder; data: seq[uint8]) =
  var r = newReader(data)
  let sync = syncFrame(r)
  let header = readFrameHeader(r, sync)
  var bps =
    if header.bitsPerSample.isSome: header.bitsPerSample.get
    elif d.params.bitsPerSample.isSome: d.params.bitsPerSample.get
    else: raise decodeError("flac: bits per sample not provided")
  if bps > 32:
    raise decodeError("flac: invalid bit width")
  let n = header.blockSamples.int
  if n > d.buf.s32.capacity:
    raise decodeError("flac: allocation would overflow buffer")
  d.buf.s32.renderWith(n, i):
    discard i
  var bs = newBitReader(r.readBytes(r.remaining()))
  case header.assignment.kind
  of caIndependent:
    let nch = header.assignment.channels.int
    if nch != d.buf.s32.planes.len:
      raise decodeError("flac: unexpected channel assignment")
    for i in 0 ..< nch:
      bs.decodeSubframe(bps.int, d.buf.s32.planes[i].toOpenArray(0, n - 1))
  of caLeftSide:
    if d.buf.s32.planes.len != 2:
      raise decodeError("flac: unexpected channel assignment")
    bs.decodeSubframe(bps.int, d.buf.s32.planes[0].toOpenArray(0, n - 1))
    bs.decodeSubframe(bps.int + 1, d.buf.s32.planes[1].toOpenArray(0, n - 1))
    decorrelateLeftSide(d.buf.s32.planes[0].toOpenArray(0, n - 1),
      d.buf.s32.planes[1].toOpenArray(0, n - 1))
  of caMidSide:
    if d.buf.s32.planes.len != 2:
      raise decodeError("flac: unexpected channel assignment")
    bs.decodeSubframe(bps.int, d.buf.s32.planes[0].toOpenArray(0, n - 1))
    bs.decodeSubframe(bps.int + 1, d.buf.s32.planes[1].toOpenArray(0, n - 1))
    decorrelateMidSide(d.buf.s32.planes[0].toOpenArray(0, n - 1),
      d.buf.s32.planes[1].toOpenArray(0, n - 1))
  of caRightSide:
    if d.buf.s32.planes.len != 2:
      raise decodeError("flac: unexpected channel assignment")
    bs.decodeSubframe(bps.int + 1, d.buf.s32.planes[0].toOpenArray(0, n - 1))
    bs.decodeSubframe(bps.int, d.buf.s32.planes[1].toOpenArray(0, n - 1))
    decorrelateRightSide(d.buf.s32.planes[1].toOpenArray(0, n - 1),
      d.buf.s32.planes[0].toOpenArray(0, n - 1))
  if d.verify:
    d.validator.updateValidator(d.buf.s32, bps)
  if bps < 32:
    let shift = (32 - bps).int
    for p in 0 ..< d.buf.s32.planes.len:
      for i in 0 ..< n:
        d.buf.s32.planes[p][i] = d.buf.s32.planes[p][i] shl shift
  # The footer CRC is verified by the demuxer during indexing.

method codecParams*(d: FlacDecoder): AudioCodecParameters = d.params

method reset*(d: FlacDecoder) =
  discard

method decodePacket*(d: FlacDecoder; pkt: Packet): AudioSamples =
  try:
    d.decodeFrames(pkt.data)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  d.buf

method lastDecoded*(d: FlacDecoder): AudioSamples = d.buf

method finalize*(d: FlacDecoder): FinalizeResult =
  if d.verify:
    if d.params.verificationMd5.isSome:
      let decoded = d.validator.validatorDigest()
      result.verifyOk = some(decoded == d.params.verificationMd5.get)
    else:
      result.verifyOk = none(bool)

proc flacDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newFlacDecoder(params, opts)

proc registerFlac*() =
  registerAudioDecoder(CodecFlac, flacDecoderFactory)

# ------------------------------------------------------------- Encoder ---

proc riceUnsigned*(v: int32): uint32 {.inline.} =
  ## Signed residual to unsigned Rice code.
  cast[uint32]((v shl 1) xor (v shr 31))

proc bestRiceParam*(residuals: openArray[int32]): tuple[k: int, escape: bool,
    width: int] =
  ## Picks the cheapest Rice parameter (order-0 partition), or the binary
  ## escape when raw coding wins. Returns (k, isEscape, escapeWidth).
  var bestK = 0
  var bestCost = high(int64)
  let n = residuals.len
  for k in 0 ..< 15:
    var cost = n.int64 * (1 + k).int64
    for r in residuals:
      cost += (riceUnsigned(r) shr k).int64
    if cost < bestCost:
      bestCost = cost
      bestK = k
  # Escape cost: 5-bit width field + n * width.
  var width = 0
  for r in residuals:
    let need =
      if r >= 0:
        if r == 0: 1
        else:
          var b = 0
          var v = r.uint32
          while v != 0:
            inc b
            v = v shr 1
          b + 1
      else:
        var b = 0
        var v = cast[uint32](not r)
        while v != 0:
          inc b
          v = v shr 1
        b + 1
    width = max(width, need)
  let escapeCost = 5'i64 + n.int64 * width.int64
  # Rice header cost: 4-bit param (order-0 partition header is 4 + 4 bits,
  # accounted by the caller); compare payload only here.
  if escapeCost < bestCost:
    (0, true, width)
  else:
    (bestK, false, 0)

proc encodeRicePartition*(w: var BitWriter; residuals: openArray[int32]) =
  ## Emits an order-0 Rice partition (method 00, partition order 0).
  w.writeBits(0, 2) # method: Rice, 4-bit params
  w.writeBits(0, 4) # partition order 0
  let (k, escape, width) = bestRiceParam(residuals)
  if escape:
    w.writeBits(0x0f, 4)
    w.writeBits(width.uint32, 5)
    for r in residuals:
      w.writeSigned(r, width)
  else:
    w.writeBits(k.uint32, 4)
    for r in residuals:
      let u = riceUnsigned(r)
      w.writeUnary(u shr k)
      if k > 0:
        w.writeBits(u and ((1'u32 shl k) - 1), k)

proc fixedResiduals*(order: int; samples: openArray[int32]): seq[int32] =
  ## Inverse fixed predictor: warm-up samples verbatim, rest residuals.
  result = newSeq[int32](samples.len)
  for i in 0 ..< min(order, samples.len):
    result[i] = samples[i]
  case order
  of 0:
    for i in 0 ..< samples.len:
      result[i] = samples[i]
  of 1:
    for i in 1 ..< samples.len:
      result[i] = samples[i] -% samples[i - 1]
  of 2:
    for i in 2 ..< samples.len:
      result[i] = samples[i] -% (2 *% samples[i - 1] -% samples[i - 2])
  of 3:
    for i in 3 ..< samples.len:
      result[i] = samples[i] -% (3 *% samples[i - 1] -% 3 *% samples[i - 2] +%
        samples[i - 3])
  of 4:
    for i in 4 ..< samples.len:
      result[i] = samples[i] -% (4 *% samples[i - 1] -% 6 *% samples[i - 2] +%
        4 *% samples[i - 3] -% samples[i - 4])
  else:
    raise decodeError("flac: fixed predictor orders greater than 4 invalid")

proc trailingZeros(v: int32): int =
  var u = cast[uint32](v)
  if u == 0:
    return 32
  while (u and 1) == 0:
    inc result
    u = u shr 1

proc encodeSubframe*(w: var BitWriter; samples: openArray[int32];
    bps: int) =
  ## Chooses constant / fixed 0..4 / verbatim by actual bit cost.
  let n = samples.len
  var allEqual = true
  for i in 1 ..< n:
    if samples[i] != samples[0]:
      allEqual = false
      break
  if allEqual:
    # Constant always wins ties (smallest header, no residuals).
    w.writeBit(false)
    w.writeBits(0x00, 6)
    w.writeBit(false)
    w.writeSigned(samples[0], bps)
    return
  # Wasted bits from trailing zeros.
  var tz = 32
  for s in samples:
    tz = min(tz, trailingZeros(s))
  let dropped = min(tz, bps - 1)
  var src = newSeq[int32](n)
  for i in 0 ..< n:
    src[i] =
      if dropped > 0: samples[i] shr dropped
      else: samples[i]
  let sbps = bps - dropped
  # Verbatim cost baseline.
  var bestCost = 8 + n * sbps
  var bestOrder = -2 # -2 = verbatim, -1 = unused, 0..4 fixed
  for order in 0 .. 4:
    if order >= n:
      break
    let res = fixedResiduals(order, src)
    # Residual payload cost with optimal Rice.
    let (k, escape, width) = bestRiceParam(res.toOpenArray(order, n - 1))
    var cost = 8 + order * sbps + 2 + 4 + 4
    if escape:
      cost += 5 + (n - order) * width
    else:
      cost += (n - order) * (1 + k)
      for i in order ..< n:
        cost += (riceUnsigned(res[i]) shr k).int
    if cost < bestCost:
      bestCost = cost
      bestOrder = order
  w.writeBit(false)
  if bestOrder == -2:
    w.writeBits(0x01, 6)
    w.writeBit(dropped > 0)
    if dropped > 0:
      # Unary-coded (dropped - 1): zeros then a one.
      for _ in 1 ..< dropped:
        w.writeBit(false)
      w.writeBit(true)
    for s in src:
      w.writeSigned(s, sbps)
  else:
    w.writeBits((0x08 or bestOrder).uint32, 6)
    w.writeBit(dropped > 0)
    if dropped > 0:
      for _ in 1 ..< dropped:
        w.writeBit(false)
      w.writeBit(true)
    let res = fixedResiduals(bestOrder, src)
    for i in 0 ..< bestOrder:
      w.writeSigned(src[i], sbps)
    var tail = newSeq[int32](n - bestOrder)
    for i in 0 ..< tail.len:
      tail[i] = res[bestOrder + i]
    w.encodeRicePartition(tail)

proc encodeFlacFrame*(planes: openArray[seq[int32]]; frameNum: uint32;
    bps: int): seq[uint8] =
  ## Encodes one independent-channels frame (new work).
  let nch = planes.len
  let n = planes[0].len
  # Byte-oriented header first (sync + desc + frame number + blocksize).
  var w = newWriter()
  w.writeU16Be(0xfff8'u16) # Sync word, fixed blocking strategy.
  let blockEnc =
    if n <= 255: 6
    else: 7
  let desc = (blockEnc.uint16 shl 12) or
    ((nch - 1).uint16 shl 4) # rate 0, bps 0, reserved 0
  w.writeU16Be(desc)
  if frameNum < 0x80:
    w.writeByte(cast[uint8](frameNum))
  elif frameNum < 0x800:
    w.writeByte(cast[uint8](0xc0 or (frameNum shr 6)))
    w.writeByte(cast[uint8](0x80 or (frameNum and 0x3f)))
  elif frameNum < 0x10000:
    w.writeByte(cast[uint8](0xe0 or (frameNum shr 12)))
    w.writeByte(cast[uint8](0x80 or ((frameNum shr 6) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or (frameNum and 0x3f)))
  else:
    w.writeByte(cast[uint8](0xf0 or (frameNum shr 18)))
    w.writeByte(cast[uint8](0x80 or ((frameNum shr 12) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((frameNum shr 6) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or (frameNum and 0x3f)))
  if blockEnc == 6:
    w.writeByte(cast[uint8](n - 1))
  else:
    w.writeU16Be(cast[uint16](n - 1))
  var hdrBytes = w.toBytes()
  let crc = crc8(hdrBytes)
  w.writeByte(crc)
  # Subframes are bit-packed from the byte-aligned header end.
  var bw = newBitWriter()
  bw.buf = w.toBytes()
  for p in 0 ..< nch:
    bw.encodeSubframe(planes[p].toOpenArray(0, n - 1), bps)
  bw.flush()
  let frame = bw.toBytes()
  var fw = newWriter()
  fw.writeBytes(frame)
  fw.writeU16Be(crc16Ansi(frame))
  fw.toBytes()
