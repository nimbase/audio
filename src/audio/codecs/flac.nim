## FLAC codec: decoder plus encoder.
##
## Decoder ports `symphonia-bundle-flac` (`decoder.rs`): constant, verbatim,
## fixed (orders 0-4) and LPC (orders 1-32) subframes, Rice/Rice2
## partitions with escape, wasted bits, mid/side + left/right-side
## decorrelation, MSB-aligned S32 output, MD5 validation. Wrapping
## arithmetic matches the reference release behavior bit-for-bit and
## never raises on hostile input.
##
## FLAC encoder (callsites use `encodeSubframeEx` through frames).
##
## Full RFC 9639 encoder (new work): constant / fixed 0-4 / LPC 1-32
## (apodized autocorrelation + Levinson-Durbin, per-order precision and
## non-negative shift search) with exact bit-cost selection, wasted
## bits, partitioned Rice (4-bit and, at level >= 3, 5-bit Rice2) with
## escape, mid-side / left-side / right-side decorrelation, fixed or
## variable blocking, explicit rate/depth/blocksize header codings,
## frame CRC-8 and footer CRC-16, seek table + MD5 finalization in the
## muxer. `FlacEncoderOptions.level` (0-8, default 5) scales the search
## effort; output is always lossless and deterministic.

import std/math
import std/options
import ./../audio
import ./../checksum
import ./../codecs
import ./../errors
import ./../io
import ./../packet
import ./../source

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

proc syncFrame*[R](r: var R): uint16 =
  ## Scans for the 14-bit sync code (`0xFFF8` masked), returning the full
  ## 16-bit word (low bit = blocking strategy).
  var sync = 0'u16
  while (sync and 0xfffc'u16) != 0xfff8'u16:
    sync = (sync shl 8) or r.readByte().uint16
  sync

proc readFrameHeader*[R](r: var R; sync: uint16): FrameHeader =
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
    else:
      # 0xFE would need a 7-byte sequence (only for >= 2^31 samples);
      # reject instead of hanging the zero-counter below.
      raise decodeError("flac: frame sequence number is not valid")
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

proc decodeRicePartition[B](bs: var B; paramWidth: int;
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

proc decodeResidual[B](bs: var B; nPrelude: int;
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

proc decodeConstant[B](bs: var B; bps: int; buf: var openArray[int32]) =
  let v = signExtend(bs.readBits(bps), bps)
  for s in buf.mitems:
    s = v

proc decodeVerbatim[B](bs: var B; bps: int; buf: var openArray[int32]) =
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

proc decodeFixedLinear[B](bs: var B; bps, order: int;
    buf: var openArray[int32]) =
  if order > buf.len:
    raise decodeError("flac: fixed predictor order is greater than the block size")
  if order > 0:
    bs.decodeVerbatim(bps, buf.toOpenArray(0, order - 1))
  bs.decodeResidual(order, buf)
  fixedPredict(order, buf)

proc decodeLinear[B](bs: var B; bps, order: int;
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

proc decodeSubframe*[B](bs: var B; frameBps: int;
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

proc decodeFramesHead[R](d: FlacDecoder;
    r: var R): tuple[header: FrameHeader, bps: uint32, n: int] =
  ## Sync + header parse, shared by the owning and zero-copy paths.
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
  (header, bps, n)

proc decodeFramesBody[B](d: FlacDecoder; header: FrameHeader; bps: uint32;
    n: int; bs: var B) =
  ## Subframe decode over any MSB-first bit cursor.
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

proc decodeFrames(d: FlacDecoder; data: seq[uint8]) =
  ## Owning decode: the bit reader copies the packet tail (as before).
  var r = newReader(data)
  let (header, bps, n) = d.decodeFramesHead(r)
  var bs = newBitReader(r.readBytes(r.remaining()))
  d.decodeFramesBody(header, bps, n, bs)

proc decodeFlacWin*(d: FlacDecoder; win: ByteWindow) =
  ## Zero-copy decode straight from a byte window (mapping or pool).
  var vr = viewReaderOf(win)
  let (header, bps, n) = d.decodeFramesHead(vr)
  var vbs = vr.restBits()
  try:
    d.decodeFramesBody(header, bps, n, vbs)
  except AudioError as e:
    d.buf.clearSamples()
    raise e

proc decodeFlacView*(d: FlacDecoder; src: MappedSource; off, len: int) =
  ## Zero-copy decode straight from a mapping window.
  d.decodeFlacWin(byteWindow(src, off, len))

proc decodePacketView*(d: FlacDecoder; v: PacketView): AudioSamples =
  ## View-based `decodePacket`: identical output, no packet copy.
  d.decodeFlacWin(v.win)
  d.buf

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



# ------------------------------------------------ Full encoder (RFC 9639) ---

type
  FlacEncoderOptions* = object
    ## Compression effort knob. Higher levels spend more search time for
    ## smaller files; output is always lossless and deterministic.
    level*: range[0 .. 8]
    blockSize*: int        ## 0 = level default (4096, subset-legal).
    variableBlock*: bool  ## Variable-block-size strategy (sample numbers).
    writeSeekTable*: bool ## Emit a seek table (default true).

proc defaultFlacEncoderOptions*(): FlacEncoderOptions {.inline.} =
  FlacEncoderOptions(level: 5, blockSize: 0, variableBlock: false,
    writeSeekTable: true)

proc maxLpcOrder*(opts: FlacEncoderOptions): int =
  ## LPC order cap per level (subset caps at 12 for <= 48 kHz; L7/L8 are
  ## for high rates or explicitly non-subset streams).
  case opts.level
  of 0, 1: 0
  of 2: 6
  of 3: 8
  of 4, 5: 12
  of 6: 16
  of 7: 24
  else: 32

proc maxPartitionOrder*(opts: FlacEncoderOptions): int =
  case opts.level
  of 0, 1, 2: 0
  of 3: 2
  of 4: 3
  of 5: 4
  of 6: 6
  else: 8

proc doDecorrelate*(opts: FlacEncoderOptions): bool {.inline.} =
  opts.level >= 1

proc encoderBlockSize*(opts: FlacEncoderOptions): int =
  if opts.blockSize != 0:
    if opts.blockSize < 16 or opts.blockSize > 65535:
      raise unsupportedError("flac: block size out of bounds")
    return opts.blockSize
  4096

# ---------------------------------------------------------- LPC estimate ---

proc levinsonDurbin*(r: openArray[float64];
    order: int): tuple[coeffs: seq[float64], err: float64] =
  ## Solves the Yule-Walker equations up to `order`, returning the
  ## order-`order` coefficients and the prediction error energy.
  result.coeffs = newSeq[float64](order)
  result.err = 0.0
  if order == 0 or r[0] <= 0.0:
    return
  var a = newSeq[float64](order)
  var e = r[0]
  for i in 1 .. order:
    var acc = r[i]
    for j in 0 ..< i - 1:
      acc -= a[j] * r[i - 1 - j]
    let k = acc / e
    if k != k or k <= -1.0 or k >= 1.0:
      # Unstable reflection: truncate here (fewer, stable orders win).
      for j in 0 ..< i - 1:
        result.coeffs[j] = a[j]
      result.err = e
      return
    for j in 0 ..< i - 1:
      a[j] = a[j] - k * a[i - 2 - j]
    a[i - 1] = k
    e *= 1.0 - k * k
    if e <= 0.0 or e != e:
      for j in 0 .. i - 1:
        result.coeffs[j] = a[j]
      result.err = e
      return
  result.coeffs = a
  result.err = e

proc quantizeLpc*(a: openArray[float64];
    precision: int): tuple[ok: bool, shift: int, coeffs: seq[int32]] =
  ## Quantizes float coefficients to `precision`-bit integers with a
  ## non-negative shift (RFC B.4 forbids negative shifts). `precision` is
  ## the stored width (1..15; 16+ is the 0b1111 forbidden pattern).
  result.ok = false
  result.coeffs = @[]
  if precision < 1 or precision > 15:
    return
  var maxA = 0.0
  for v in a:
    let m = abs(v)
    if m > maxA:
      maxA = m
  if maxA == 0.0:
    result = (true, 0, newSeq[int32](a.len))
    return
  let limit = (1 shl (precision - 1)).float64 - 1.0
  if maxA >= (1 shl (precision - 1)).float64:
    return # Does not fit even at shift 0.
  var shift = 0
  if maxA > 0.0:
    shift = floor(log2(limit / maxA)).int
  if shift > 31:
    shift = 31
  if shift < 0:
    return
  result.shift = shift
  result.coeffs = newSeq[int32](a.len)
  let gain = pow(2.0, shift.float64)
  for i, v in a:
    let q = round(v * gain)
    if abs(q) >= (1 shl (precision - 1)).float64:
      return # Rounding overflow: reject this precision.
    result.coeffs[i] = q.int32
  result.ok = true

proc lpcResiduals*(order: int; coeffs: openArray[int32]; shift: int;
    samples: openArray[int32]): seq[int32] =
  ## Exact integer residuals (wrapping), mirroring `lpcPredict` bit-for-bit.
  result = newSeq[int32](samples.len)
  for i in 0 ..< min(order, samples.len):
    result[i] = samples[i]
  for i in order ..< samples.len:
    var predicted = 0'i64
    for j in 0 ..< order:
      # qc[j] taps x[i-1-j] (newest-first), matching the bitstream order
      # the decoder applies (first transmitted coefficient hits x[i-1]).
      predicted = predicted +% coeffs[j].int64 *%
        samples[i - 1 - j].int64
    let p = cast[int32](predicted shr shift)
    result[i] = samples[i] -% p

# ------------------------------------------------- Partitioned residual ---

type
  RiceChoice* = object
    escape*: bool
    k*: int    ## Rice parameter (valid unless `escape`).
    width*: int ## Escape width (valid if `escape`).
    bits*: int ## Total bits for this partition, incl. parameter field.

proc escapeWidth*(res: openArray[int32]): int =
  ## Minimum raw width holding every residual (decoder `signExtend` rule).
  for r in res:
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
    result = max(result, need)

proc chooseRice*(res: openArray[int32];
    allowRice2: bool): RiceChoice =
  ## Exact cheapest coding of one partition (4-bit params, optional 5-bit
  ## Rice2, 4-bit escape). Payload cost of parameter `k` is
  ## `sum((folded shr k) + 1 + k)`.
  var maxU = 0'u32
  for r in res:
    let u = riceUnsigned(r)
    if u > maxU:
      maxU = u
  var bitLen = 0
  var t = maxU
  while t != 0:
    inc bitLen
    t = t shr 1
  var maxK = bitLen # Larger k only grows `n * (1 + k)` once q is all 0.
  if not allowRice2:
    maxK = min(maxK, 14)
  else:
    maxK = min(maxK, 30)
  var bestK = 0
  var bestPayload = high(int64)
  for k in 0 .. maxK:
    var c = res.len.int64 * (1 + k).int64
    for r in res:
      c += (riceUnsigned(r) shr k).int64
    if c < bestPayload:
      bestPayload = c
      bestK = k
  let useRice2 = bestK > 14
  let riceBits = (if useRice2: 5 else: 4) + bestPayload.int
  let escW = escapeWidth(res)
  # Widths above 31 are not representable in the 5-bit escape field;
  # Rice (k <= 30) always wins those comparisons anyway.
  let escBits = 4 + 5 + res.len * escW
  if escW <= 31 and escBits < riceBits:
    RiceChoice(escape: true, k: 0, width: escW, bits: escBits)
  else:
    RiceChoice(escape: false, k: bestK, width: 0, bits: riceBits)

proc choosePartitions*(residuals: openArray[int32]; nPrelude, maxPO: int;
    allowRice2: bool): tuple[po: int, method5: bool,
    choices: seq[RiceChoice], bits: int] =
  ## Exact cheapest partition order (method + order header included).
  ## Skips orders where the block is not divisible or the first partition
  ## cannot hold the warm-up samples (decoder hard errors on both).
  let n = residuals.len
  result = (0, false, @[], high(int))
  var po = 0
  while po <= maxPO:
    let nPart = 1 shl po
    if nPart > n or n mod nPart != 0:
      break # Larger orders only get worse here.
    let partLen = n div nPart
    if partLen < max(nPrelude, 1):
      inc po
      continue
    var choices = newSeq[RiceChoice](nPart)
    var total = 2 + 4
    var need5 = false
    for i in 0 ..< nPart:
      let lo = if i == 0: nPrelude else: i * partLen
      let hi = (i + 1) * partLen
      let ch = chooseRice(residuals.toOpenArray(lo, hi - 1), allowRice2)
      if ch.k > 14:
        need5 = true
      total += ch.bits
      choices[i] = ch
    if total < result.bits:
      result = (po, need5, choices, total)
    inc po

proc emitRiceChoice(w: var BitWriter; res: openArray[int32];
    ch: RiceChoice; method5: bool) =
  if ch.escape:
    w.writeBits(if method5: 0x1f'u32 else: 0x0f'u32,
      if method5: 5 else: 4)
    w.writeBits(ch.width.uint32, 5)
    for r in res:
      w.writeSigned(r, ch.width)
  else:
    w.writeBits(ch.k.uint32, if method5: 5 else: 4)
    for r in res:
      let u = riceUnsigned(r)
      w.writeUnary(u shr ch.k)
      if ch.k > 0:
        w.writeBits(u and ((1'u32 shl ch.k) - 1), ch.k)

proc encodeRicePartitions*(w: var BitWriter; residuals: openArray[int32];
    nPrelude, maxPO: int; allowRice2 = true) =
  ## Emits method + order + per-partition Rice codes (new work).
  let (po, method5, choices, _) = choosePartitions(residuals, nPrelude,
    maxPO, allowRice2)
  let n = residuals.len
  let partLen = n div (1 shl po)
  w.writeBits(if method5: 1'u32 else: 0'u32, 2)
  w.writeBits(po.uint32, 4)
  for i, ch in choices:
    let lo = if i == 0: nPrelude else: i * partLen
    emitRiceChoice(w, residuals.toOpenArray(lo, (i + 1) * partLen - 1), ch,
      method5)

# --------------------------------------- Apodization (windowing) ---

type
  ApodizationKind* = enum
    akRectangular
    akTukey
    akWelch

proc apodize*(x: openArray[int32]; kind: ApodizationKind;
    buf: var seq[float64]) =
  ## Applies a window for autocorrelation (estimation only; exact
  ## residuals are always computed on the unwindowed signal, so this
  ## cannot affect losslessness). Tukey uses p = 0.5 like libFLAC.
  let n = x.len
  if buf.len != n:
    buf.setLen(n)
  case kind
  of akRectangular:
    for i in 0 ..< n:
      buf[i] = x[i].float64
  of akTukey:
    const p = 0.5
    for i in 0 ..< n:
      let t = i.float64 / n.float64
      var w: float64
      if t < p / 2.0:
        w = 0.5 * (1.0 + cos(PI * (2.0 * t / p - 1.0)))
      elif t <= 1.0 - p / 2.0:
        w = 1.0
      else:
        w = 0.5 * (1.0 + cos(PI * (2.0 * t / p - 2.0 / p + 1.0)))
      buf[i] = x[i].float64 * w
  of akWelch:
    for i in 0 ..< n:
      let t = (2.0 * i.float64 / n.float64) - 1.0
      buf[i] = x[i].float64 * (1.0 - t * t)

proc autocorrelateF*(x: openArray[float64]; maxLag: int): seq[float64] =
  result = newSeq[float64](maxLag + 1)
  for lag in 0 .. maxLag:
    var s = 0.0
    for i in 0 ..< x.len - lag:
      s += x[i] * x[i + lag]
    result[lag] = s

proc lpcWindows*(level: int): seq[ApodizationKind] =
  case level
  of 5, 6: @[akRectangular, akTukey]
  of 7 .. 8: @[akRectangular, akTukey, akWelch]
  else: @[akRectangular]

# ------------------------------------------------------------ LPC encode ---

proc emitWastedFlag(w: var BitWriter; dropped: int) =
  w.writeBit(dropped > 0)
  if dropped > 0:
    # Unary-coded (dropped - 1): zeros then a one.
    for _ in 1 ..< dropped:
      w.writeBit(false)
    w.writeBit(true)

const LpcPrecisions = [6, 9, 12, 15]

proc encodeLpcCandidate(w: var BitWriter; samples: openArray[int32];
    sbps, order, precision, shift, dropped: int; coeffs: openArray[int32];
    maxPO: int; allowRice2: bool) =
  w.writeBits((0x20 or (order - 1)).uint32, 6)
  w.emitWastedFlag(dropped)
  for i in 0 ..< order:
    w.writeSigned(samples[i], sbps)
  w.writeBits((precision - 1).uint32, 4)
  w.writeSigned(shift.int32, 5)
  for c in coeffs:
    w.writeSigned(c, precision)
  let full = lpcResiduals(order, coeffs, shift, samples)
  encodeRicePartitions(w, full.toOpenArray(0, samples.len - 1), order,
    maxPO, allowRice2)

proc tryLpcSubframe*(samples: openArray[int32]; sbps, maxOrder: int;
    allowRice2: bool;
    windows: openArray[ApodizationKind]): tuple[ok: bool, order, precision,
    shift: int, coeffs, res: seq[int32], rankBits: int] =
  ## Searches windows x LPC orders x precisions by cheap rank-0 Rice. The
  ## caller upgrades the winner to full partitioned Rice for the final
  ## decision. Returns the winner with exact residuals (always computed
  ## on the unwindowed signal, so windowing cannot break losslessness,
  ## it only improves the estimate).
  result.ok = false
  result.rankBits = high(int)
  result.res = @[]
  let n = samples.len
  let maxO = min(maxOrder, n - 1)
  if maxO < 1:
    return
  var win = newSeq[float64](n)
  for wk in windows:
    apodize(samples, wk, win)
    let r = autocorrelateF(win, maxO)
    for order in 1 .. maxO:
      let (a, _) = levinsonDurbin(r.toOpenArray(0, order), order)
      for precision in LpcPrecisions:
        let (ok, shift, qc) = quantizeLpc(a, precision)
        if not ok:
          continue
        let res = lpcResiduals(order, qc, shift, samples)
        let (_, _, _, rbits) = choosePartitions(res.toOpenArray(0, n - 1),
          order, 0, allowRice2)
        let bits = 6 + order * sbps + 4 + 5 + order * precision + rbits
        if bits < result.rankBits:
          result = (true, order, precision, shift, qc, res, bits)

# ------------------------------------------------- Subframe selection ---

proc emitFixedBody(w: var BitWriter; src: openArray[int32]; sbps, order,
    dropped, maxPO: int; allowRice2: bool) =
  w.writeBits((0x08 or order).uint32, 6)
  w.emitWastedFlag(dropped)
  for i in 0 ..< order:
    w.writeSigned(src[i], sbps)
  let full = fixedResiduals(order, src)
  encodeRicePartitions(w, full.toOpenArray(0, src.len - 1), order, maxPO,
    allowRice2)

proc fixedBodyBits(src: openArray[int32]; sbps, order, maxPO: int;
    allowRice2: bool): int =
  let full = fixedResiduals(order, src)
  let (_, _, _, rbits) = choosePartitions(full, order, maxPO, allowRice2)
  6 + order * sbps + rbits

proc emitVerbatimBody(w: var BitWriter; src: openArray[int32];
    sbps, dropped: int) =
  w.writeBits(0x01, 6)
  w.emitWastedFlag(dropped)
  for s in src:
    w.writeSigned(s, sbps)

proc encodeSubframeEx*(w: var BitWriter; samples: openArray[int32];
    bps: int; opts: FlacEncoderOptions) =
  ## Chooses constant / fixed 0..4 / LPC / verbatim by exact bit cost,
  ## with partitioned Rice (4-bit and, at level >= 3, 5-bit Rice2).
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
  let maxPO = maxPartitionOrder(opts)
  let allowRice2 = opts.level >= 3
  # Stage 1: rank predictors with cheap order-0 Rice. Verbatim stores raw
  # samples (no residual coding); fixed/LPC get a final exact upgrade.
  let verbBody = 6 + n * sbps
  var bestFixedOrder = -1
  var bestFixedRank = high(int)
  for order in 0 .. 4:
    if order >= n:
      break
    let body = fixedBodyBits(src.toOpenArray(0, n - 1), sbps, order, 0,
      allowRice2)
    if body < bestFixedRank:
      bestFixedRank = body
      bestFixedOrder = order
  var bestLpc = (false, 0, 0, 0, newSeq[int32](), newSeq[int32](), 0)
  let maxO = maxLpcOrder(opts)
  if maxO > 0:
    let (ok, order, precision, shift, coeffs, res, _) = tryLpcSubframe(
      src.toOpenArray(0, n - 1), sbps, maxO, allowRice2,
      lpcWindows(opts.level))
    if ok:
      bestLpc = (true, order, precision, shift, coeffs, res, 0)
  # Stage 2: exact partitioned-Rice totals for the finalists.
  var bestKind = 0 # 0 verbatim, 1 fixed, 2 lpc.
  var bestBody = verbBody
  if bestFixedOrder >= 0:
    let full = fixedResiduals(bestFixedOrder, src)
    let (_, _, _, rbits) = choosePartitions(full.toOpenArray(0, n - 1),
      bestFixedOrder, maxPO, allowRice2)
    let body = 6 + bestFixedOrder * sbps + rbits
    if body < bestBody:
      bestBody = body
      bestKind = 1
  if bestLpc[0]:
    let (_, _, _, rbits) = choosePartitions(
      bestLpc[5].toOpenArray(0, n - 1), bestLpc[1], maxPO, allowRice2)
    let body = 6 + bestLpc[1] * sbps + 4 + 5 + bestLpc[1] *
      bestLpc[2] + rbits
    if body < bestBody:
      bestBody = body
      bestKind = 2
  w.writeBit(false)
  case bestKind
  of 1:
    emitFixedBody(w, src.toOpenArray(0, n - 1), sbps, bestFixedOrder,
      dropped, maxPO, allowRice2)
  of 2:
    encodeLpcCandidate(w, src.toOpenArray(0, n - 1), sbps, bestLpc[1],
      bestLpc[2], bestLpc[3], dropped, bestLpc[4], maxPO, allowRice2)
  else:
    emitVerbatimBody(w, src.toOpenArray(0, n - 1), sbps, dropped)

# -------------------------------------------------- Stereo + framing ---

proc stereoPairBits(left, right: openArray[int32]; bps: int;
    opts: FlacEncoderOptions; kind: int): int =
  ## Exact bit cost of one stereo candidate (0 independent, 1 left-side,
  ## 2 right-side, 3 mid-side).
  let n = left.len
  var tw = newBitWriter()
  case kind
  of 0:
    tw.encodeSubframeEx(left.toOpenArray(0, n - 1), bps, opts)
    tw.encodeSubframeEx(right.toOpenArray(0, n - 1), bps, opts)
  of 1:
    var side = newSeq[int32](n)
    for i in 0 ..< n:
      side[i] = left[i] -% right[i]
    tw.encodeSubframeEx(left.toOpenArray(0, n - 1), bps, opts)
    tw.encodeSubframeEx(side.toOpenArray(0, n - 1), bps + 1, opts)
  of 2:
    var side = newSeq[int32](n)
    for i in 0 ..< n:
      side[i] = left[i] -% right[i]
    tw.encodeSubframeEx(side.toOpenArray(0, n - 1), bps + 1, opts)
    tw.encodeSubframeEx(right.toOpenArray(0, n - 1), bps, opts)
  else:
    var side = newSeq[int32](n)
    var mid = newSeq[int32](n)
    for i in 0 ..< n:
      side[i] = left[i] -% right[i]
      mid[i] = (left[i] +% right[i]) shr 1
    tw.encodeSubframeEx(mid.toOpenArray(0, n - 1), bps, opts)
    tw.encodeSubframeEx(side.toOpenArray(0, n - 1), bps + 1, opts)
  tw.buf.len * 8 + tw.nbits

proc decideStereoAssignment*(left, right: openArray[int32]; bps: int;
    opts: FlacEncoderOptions): uint32 =
  ## Returns the winning header channel bits (1/8/9/10). Candidates are
  ## quick-ranked with level-0 cost, then the winner and independent get
  ## a full search (relative comparison only needs the top two).
  const encs = [1'u32, 8'u32, 9'u32, 10'u32]
  const quickOpts = FlacEncoderOptions(level: 0, blockSize: 0,
    variableBlock: false, writeSeekTable: true)
  var quick = [high(int), high(int), high(int), high(int)]
  for k in 0 .. 3:
    quick[k] = stereoPairBits(left, right, bps, quickOpts, k)
  var first = 0
  for k in 1 .. 3:
    if quick[k] < quick[first]:
      first = k
  var best = first
  var bestBits = stereoPairBits(left, right, bps, opts, first)
  if first != 0:
    let indepBits = stereoPairBits(left, right, bps, opts, 0)
    if indepBits < bestBits:
      bestBits = indepBits
      best = 0
  encs[best]

proc emitStereoPair*(bw: var BitWriter; left, right: openArray[int32];
    bps: int; opts: FlacEncoderOptions; chanEnc: uint32) =
  let n = left.len
  case chanEnc
  of 8:
    var side = newSeq[int32](n)
    for i in 0 ..< n:
      side[i] = left[i] -% right[i]
    bw.encodeSubframeEx(left.toOpenArray(0, n - 1), bps, opts)
    bw.encodeSubframeEx(side.toOpenArray(0, n - 1), bps + 1, opts)
  of 9:
    var side = newSeq[int32](n)
    for i in 0 ..< n:
      side[i] = left[i] -% right[i]
    bw.encodeSubframeEx(side.toOpenArray(0, n - 1), bps + 1, opts)
    bw.encodeSubframeEx(right.toOpenArray(0, n - 1), bps, opts)
  of 10:
    var side = newSeq[int32](n)
    var mid = newSeq[int32](n)
    for i in 0 ..< n:
      side[i] = left[i] -% right[i]
      mid[i] = (left[i] +% right[i]) shr 1
    bw.encodeSubframeEx(mid.toOpenArray(0, n - 1), bps, opts)
    bw.encodeSubframeEx(side.toOpenArray(0, n - 1), bps + 1, opts)
  else:
    bw.encodeSubframeEx(left.toOpenArray(0, n - 1), bps, opts)
    bw.encodeSubframeEx(right.toOpenArray(0, n - 1), bps, opts)

proc blockSizeCoding(n: int): tuple[enc: int, extra: seq[uint8]] =
  ## Shortest legal block-size coding (table first, uncommon fallback).
  if n == 192:
    return (1, @[])
  for k in 0 .. 4:
    if n == 576 * (1 shl k):
      return (2 + k, @[])
  for k in 0 .. 7:
    if n == 256 * (1 shl k):
      return (8 + k, @[])
  if n >= 16 and n <= 256:
    return (6, @[cast[uint8](n - 1)])
  if n > 256 and n <= 65535:
    return (7, @[cast[uint8]((n - 1) shr 8), cast[uint8](n - 1)])
  raise unsupportedError("flac: block size out of bounds")

proc rateCoding(rate: uint32): tuple[enc: int, extra: seq[uint8]] =
  ## Shortest legal sample-rate coding (table first, uncommon fallback,
  ## streaminfo reference last). Covers 1..655350 Hz.
  const table = [(88_200'u32, 1), (176_400'u32, 2), (192_000'u32, 3),
    (8_000'u32, 4), (16_000'u32, 5), (22_050'u32, 6), (24_000'u32, 7),
    (32_000'u32, 8), (44_100'u32, 9), (48_000'u32, 10), (96_000'u32, 11)]
  for (r, e) in table:
    if rate == r:
      return (e, @[])
  if rate mod 1000 == 0 and rate div 1000 <= 255 and rate div 1000 >= 1:
    return (12, @[cast[uint8](rate div 1000)])
  if rate >= 1 and rate <= 65535:
    return (13, @[cast[uint8](rate shr 8), cast[uint8](rate)])
  if rate mod 10 == 0 and rate div 10 <= 65535:
    return (14, @[cast[uint8]((rate div 10) shr 8),
      cast[uint8](rate div 10)])
  (0, @[])

proc bpsCoding(bps: uint32): int =
  case bps
  of 8: 1
  of 12: 2
  of 16: 4
  of 20: 5
  of 24: 6
  of 32: 7
  else: 0 # Refer to StreamInfo (only legal fallback for odd widths).

proc writeUtf8Num(w: var Writer; v: uint64) =
  ## UTF-8 coded number (frame or sample number, at most 31 bits: longer
  ## values need the 7-byte form, which this package's decoder rejects to
  ## avoid an ambiguous tail; streams that long are rejected at the muxer).
  if v < 0x80:
    w.writeByte(cast[uint8](v))
  elif v < 0x800:
    w.writeByte(cast[uint8](0xc0 or (v shr 6)))
    w.writeByte(cast[uint8](0x80 or (v and 0x3f)))
  elif v < 0x10000:
    w.writeByte(cast[uint8](0xe0 or (v shr 12)))
    w.writeByte(cast[uint8](0x80 or ((v shr 6) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or (v and 0x3f)))
  elif v < 0x200000:
    w.writeByte(cast[uint8](0xf0 or (v shr 18)))
    w.writeByte(cast[uint8](0x80 or ((v shr 12) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((v shr 6) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or (v and 0x3f)))
  elif v < 0x4000000:
    w.writeByte(cast[uint8](0xf8 or (v shr 24)))
    w.writeByte(cast[uint8](0x80 or ((v shr 18) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((v shr 12) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((v shr 6) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or (v and 0x3f)))
  elif v < 0x80000000'u64:
    w.writeByte(cast[uint8](0xfc or (v shr 30)))
    w.writeByte(cast[uint8](0x80 or ((v shr 24) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((v shr 18) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((v shr 12) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or ((v shr 6) and 0x3f)))
    w.writeByte(cast[uint8](0x80 or (v and 0x3f)))
  else:
    raise limitError("flac: sequence number exceeds 31 bits")

proc encodeFlacFrameEx*(planes: openArray[seq[int32]]; seqNum: uint64;
    variable: bool; bps, sampleRate: uint32;
    opts: FlacEncoderOptions): seq[uint8] =
  ## Encodes one frame (fixed or variable blocking strategy) with full
  ## header codings and channel decorrelation (new work).
  let nch = planes.len
  let n = planes[0].len
  if n < 1 or n > 65535:
    raise unsupportedError("flac: block size out of bounds")
  if seqNum >= 0x80000000'u64:
    raise limitError("flac: sequence number exceeds 31 bits")
  if nch < 1 or nch > 8:
    raise unsupportedError("flac: channel count out of bounds")
  let (bsEnc, bsExtra) = blockSizeCoding(n)
  let (rateEnc, rateExtra) = rateCoding(sampleRate)
  let bpsEnc = bpsCoding(bps)
  var chanEnc: uint32
  # The side channel needs one extra bit, which is unrepresentable at
  # 32-bit depth (subframe widths cap at 32): 32-bit stereo is always
  # independent, matching the reference encoder.
  let canDecor = nch == 2 and doDecorrelate(opts) and bps < 32
  if canDecor:
    chanEnc = decideStereoAssignment(planes[0].toOpenArray(0, n - 1),
      planes[1].toOpenArray(0, n - 1), bps.int, opts)
  else:
    chanEnc = (nch - 1).uint32
  var w = newWriter()
  w.writeU16Be(0xfff8'u16 or (if variable: 1'u16 else: 0'u16))
  let desc = (bsEnc.uint16 shl 12) or (rateEnc.uint16 shl 8) or
    (chanEnc.uint16 shl 4) or (bpsEnc.uint16 shl 1)
  w.writeU16Be(desc)
  w.writeUtf8Num(seqNum)
  w.writeBytes(bsExtra)
  w.writeBytes(rateExtra)
  let hdrBytes = w.toBytes()
  w.writeByte(crc8(hdrBytes))
  # Subframes are bit-packed from the byte-aligned header end.
  var bw = newBitWriter()
  bw.buf = w.toBytes()
  if canDecor and chanEnc >= 8:
    emitStereoPair(bw, planes[0].toOpenArray(0, n - 1),
      planes[1].toOpenArray(0, n - 1), bps.int, opts, chanEnc)
  else:
    for p in 0 ..< nch:
      bw.encodeSubframeEx(planes[p].toOpenArray(0, n - 1), bps.int, opts)
  bw.flush()
  let frame = bw.toBytes()
  var fw = newWriter()
  fw.writeBytes(frame)
  fw.writeU16Be(crc16Ansi(frame))
  fw.toBytes()

