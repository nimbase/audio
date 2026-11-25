## AIFF/AIFC demuxer (`AiffReader`).
##
## Ports `symphonia-format-riff` aiff/mod+chunks: FORM container (AIFF
## and AIFC forms), big-endian chunk walk with even padding, COMM
## (PCM widths 1..32 rounded up, AIFC compression types incl. sowt/
## twos/raw/in24/in32/23ni/fl32/fl64/alaw/ulaw), SSND sound data,
## NAME/AUTH/`(c) `/ANNO text tags; MARK/COMT/APPL/ID3 parsed and
## skipped (no chapters/attachments in this package). PCM packetization
## (1152 frames/packet), `1/rate` timebase, floor packet-aligned seek.

import std/math
import std/options
import ./../audio
import ./../codecs
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../units
import ./wav

const
  AiffFormatInfo* = FormatInfo(id: FormatAiff, shortName: "aiff",
    longName: "Audio Interchange File Format")

type
  AiffReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    packetInfo*: PacketInfo
    dataStart*: int
    dataEnd*: int
    metadata*: MetadataLog

proc probeAiff*(data: openArray[uint8]): int =
  if data.len < 12:
    return 0
  if not (data[0] == 0x46'u8 and data[1] == 0x4f'u8 and
      data[2] == 0x52'u8 and data[3] == 0x4d'u8):
    return 0
  let isAiff = data[8] == 0x41'u8 and data[9] == 0x49'u8 and
    data[10] == 0x46'u8 and data[11] == 0x46'u8
  let isAifc = data[8] == 0x41'u8 and data[9] == 0x49'u8 and
    data[10] == 0x46'u8 and data[11] == 0x43'u8
  if not (isAiff or isAifc):
    return 0
  255

proc readExtended80(r: var Reader): uint32 =
  ## 80-bit IEEE extended (BE) to truncated u32 rate.
  var b: array[10, uint8]
  for i in 0 ..< 10:
    b[i] = r.readByte()
  let sign = (b[0] and 0x80) != 0
  let exp = ((b[0].int and 0x7f) shl 8) or b[1].int
  var mant = 0'u64
  for i in 2 ..< 10:
    mant = (mant shl 8) or b[i].uint64
  if exp == 0x7fff:
    raise decodeError("aiff: sample rate is not a real number")
  if exp == 0 and mant == 0:
    raise decodeError("aiff: sample rate cannot be 0")
  if sign:
    raise decodeError("aiff: sample rate cannot be 0")
  # value = mant * 2^(exp - 16383 - 63)
  let e = exp - 16383 - 63
  var v: float64
  if e >= 0:
    v = mant.float64 * pow(2.0, e.float64)
  else:
    v = mant.float64 / pow(2.0, (-e).float64)
  if v <= 0.0 or v >= 4_294_967_295.0:
    raise decodeError("aiff: sample rate cannot be 0")
  v.uint32

proc skipPascal(r: var Reader) =
  var n = r.readByte().int
  if (n and 1) == 0:
    inc n
  r.ignoreBytes(n)

proc readPascal(r: var Reader): string =
  let n = r.readByte().int
  var bytes = r.readBytesExact(n)
  if (n and 1) == 0:
    discard r.readByte()
  var stop = bytes.len
  for i, b in bytes:
    if b == 0:
      stop = i
      break
  result = newString(stop)
  for i in 0 ..< stop:
    result[i] = bytes[i].char

proc aiffChannels(n: int): Channels =
  case n
  of 1:
    ChMono
  of 2:
    ChStereo
  of 3:
    Ch3
  else:
    discrete(n)

proc aiffCodecForWidth(valid, nch: int): tuple[codec: AudioCodecId,
    bits: int] =
  case valid
  of 1 .. 8:
    (CodecPcmS8, 8)
  of 9 .. 16:
    (CodecPcmS16Be, 16)
  of 17 .. 24:
    (CodecPcmS24Be, 24)
  of 25 .. 32:
    (CodecPcmS32Be, 32)
  else:
    raise decodeError("aiff: bits per sample for pcm must be between 1-32 bits")

type
  AiffFmt* = object
    codec*: AudioCodecId
    bits*: int
    validBits*: int
    channels*: Channels
    rate*: uint32

proc parseAiffComm(r: var Reader; isAifc: bool): AiffFmt =
  let nch = r.readU16Be().int
  discard r.readU32Be() # numSampleFrames (unused for duration)
  let valid = r.readU16Be().int
  let rate = readExtended80(r)
  if nch < 1:
    raise decodeError("aiff: invalid channel count")
  let channels = aiffChannels(nch)
  if not isAifc:
    let (codec, bits) = aiffCodecForWidth(valid, nch)
    return AiffFmt(codec: codec, bits: bits, validBits: valid,
      channels: channels, rate: rate)
  var ctyp: array[4, uint8]
  for i in 0 ..< 4:
    ctyp[i] = r.readByte()
  r.skipPascal()
  let c = "" & cast[char](ctyp[0]) & cast[char](ctyp[1]) &
    cast[char](ctyp[2]) & cast[char](ctyp[3])
  case c
  of "none", "NONE":
    let (codec, bits) = aiffCodecForWidth(valid, nch)
    AiffFmt(codec: codec, bits: bits, validBits: valid,
      channels: channels, rate: rate)
  of "twos", "TWOS":
    if valid != 16:
      raise decodeError("aiff: bits per sample for twos must be 16 bits")
    AiffFmt(codec: CodecPcmS16Be, bits: 16, validBits: valid,
      channels: channels, rate: rate)
  of "sowt", "SOWT":
    if valid != 16:
      raise decodeError("aiff: bits per sample for sowt must be 16 bits")
    AiffFmt(codec: CodecPcmS16Le, bits: 16, validBits: valid,
      channels: channels, rate: rate)
  of "raw ", "RAW ":
    if valid != 8:
      raise decodeError("aiff: bits per sample for raw must be 8 bits")
    AiffFmt(codec: CodecPcmU8, bits: 8, validBits: valid,
      channels: channels, rate: rate)
  of "in24", "IN24":
    if valid != 24:
      raise decodeError("aifc: bits per sample invalid for in14")
    AiffFmt(codec: CodecPcmS24Be, bits: 24, validBits: valid,
      channels: channels, rate: rate)
  of "in32", "IN32":
    if valid != 32:
      raise decodeError("aifc: bits per sample invalid for in32")
    AiffFmt(codec: CodecPcmS32Be, bits: 32, validBits: valid,
      channels: channels, rate: rate)
  of "23ni", "23NI":
    if valid != 32:
      raise decodeError("aifc: bits per sample invalid for 23ni")
    AiffFmt(codec: CodecPcmS32Le, bits: 32, validBits: valid,
      channels: channels, rate: rate)
  of "fl32", "FL32":
    AiffFmt(codec: CodecPcmF32Be, bits: 32, validBits: valid,
      channels: channels, rate: rate)
  of "fl64", "FL64":
    AiffFmt(codec: CodecPcmF64Be, bits: 64, validBits: valid,
      channels: channels, rate: rate)
  of "alaw", "ALAW":
    AiffFmt(codec: CodecPcmALaw, bits: 16, validBits: valid,
      channels: channels, rate: rate)
  of "ulaw", "ULAW":
    AiffFmt(codec: CodecPcmMuLaw, bits: 16, validBits: valid,
      channels: channels, rate: rate)
  else:
    raise unsupportedError("aifc: compression type not supported")

proc skipChunkPayload(r: var Reader; stop: int) =
  ## Skips unread payload bytes of the current chunk.
  if r.pos < stop:
    r.ignoreBytes(stop - r.pos)

proc openAiff*(data: seq[uint8]): AiffReader =
  if probeAiff(data) == 0:
    raise unsupportedError("aiff: missing aiff riff stream marker")
  var r = newReader(data)
  discard r.readFourCc()
  let riffLen = r.readU32Be()
  if riffLen < 4:
    raise decodeError("aiff: invalid riff length")
  let form = r.readFourCc()
  let isAifc = form == [0x41'u8, 0x49, 0x46, 0x43]
  let formEnd = 8 + riffLen.int
  var fmt = none(AiffFmt)
  var packetInfo = withoutBlocks(1)
  var blockSize = 0
  var metaLog = MetadataLog()
  var dataStart = -1
  var dataEndOpt: Option[int] = none(int)
  let bodyStart = r.pos
  while r.pos < formEnd:
    if ((r.pos - bodyStart) and 1) == 1:
      r.ignoreBytes(1)
      continue
    if formEnd - r.pos < 8:
      break
    var tag: array[4, uint8]
    for i in 0 ..< 4:
      tag[i] = r.readByte()
    let chunkLen = r.readU32Be().int
    let bodyEnd = r.pos + chunkLen
    if bodyEnd > formEnd:
      raise decodeError("aiff: chunk length exceeds parent chunk length")
    let bodyClamp = min(bodyEnd, data.len)
    let t = "" & cast[char](tag[0]) & cast[char](tag[1]) &
      cast[char](tag[2]) & cast[char](tag[3])
    if t == "COMM":
      if fmt.isSome:
        raise decodeError("aiff: multiple common chunks")
      let f = parseAiffComm(r, isAifc)
      if r.pos > bodyEnd:
        raise decodeError("aiff: malformed common chunk")
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
      blockSize = f.bits div 8 * f.channels.channelCount()
      packetInfo = withoutBlocks(blockSize.uint32)
      fmt = some(f)
    elif t == "SSND":
      if dataStart >= 0:
        raise decodeError("aiff: multiple sound data chunks")
      if chunkLen < 8:
        raise decodeError("aiff: invalid chunk size for sound chunk")
      let offset = r.readU32Be().int
      let blk = r.readU32Be()
      if blk != 0:
        raise unsupportedError("aiff: no support for aiff block-aligned data")
      if offset > chunkLen - 8:
        raise decodeError("aiff: sound data offset too large")
      r.ignoreBytes(offset)
      dataStart = r.pos
      dataEndOpt = some(min(dataStart + (chunkLen - 8 - offset),
        data.len))
      break # Sound data is last; packetization starts here.
    elif t == "NAME" or t == "AUTH" or t == "(c) " or t == "ANNO":
      var bytes = r.readBytesExact(min(chunkLen, bodyClamp - r.pos))
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
      var stop = bytes.len
      for i, b in bytes:
        if b == 0:
          stop = i
          break
      var text = newString(stop)
      for i in 0 ..< stop:
        text[i] = bytes[i].char
      var rev = MetadataRevision()
      let stdKey =
        case t
        of "NAME":
          some("track_title")
        of "AUTH":
          some("encoder")
        of "(c) ":
          some("copyright")
        else:
          some("comment")
      rev.addTag(newTag(t, strValue(text), stdKey))
      metaLog.push(rev)
    else:
      # MARK/COMT/APPL/ID3/FVER/INST and unknown chunks: skip.
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
    if r.pos < bodyClamp:
      r.ignoreBytes(bodyClamp - r.pos)
  if fmt.isNone:
    raise decodeError("aiff: missing common element")
  if dataStart < 0:
    raise unsupportedError("aiff: missing sound data chunk")
  let f = fmt.get
  var params = forCodec(f.codec)
  params.sampleRate = some(f.rate)
  params.channels = some(f.channels)
  params.bitsPerSample = some(f.bits.uint32)
  params.bitsPerCodedSample = some(f.validBits.uint32)
  params.maxFramesPerPacket = some(packetInfo.maxFramesPerPacket)
  params.framesPerBlock = some(1'u64)
  var track = newTrack(0, params)
  let dataEnd = dataEndOpt.get
  let nFrames = packetInfo.getNumFramesAt((dataEnd - dataStart).uint64)
  track.numFrames = some(nFrames)
  track.duration = some(newDuration(nFrames))
  result = AiffReader(r: r, tracks: @[track], packetInfo: packetInfo,
    dataStart: dataStart, dataEnd: dataEnd, metadata: metaLog)
  result.r.pos = dataStart

proc trackCount*(w: AiffReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: AiffReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: AiffReader): Option[uint64] = w.tracks[0].numFrames

proc nextPacket*(w: AiffReader): Option[Packet] =
  let info = w.packetInfo
  if w.r.pos >= w.dataEnd:
    return none(Packet)
  let blocksLeft = (w.dataEnd - w.r.pos).uint64 div info.blockSize
  if blocksLeft == 0:
    return none(Packet)
  let blocks = min(blocksLeft, info.maxBlocksPerPacket)
  let dur = blocks * info.framesPerBlock
  let nBytes = (blocks * info.blockSize).int
  let rel = (w.r.pos - w.dataStart).uint64
  let pts = newTimestamp(info.getNumFramesAt(rel).int64)
  let buf = w.r.readBytesExact(nBytes)
  some(newPacket(0, pts, newDuration(dur), buf))

proc seek*(w: AiffReader; to: SeekTo): SeekedTo =
  let track = w.tracks[0]
  var req: Timestamp
  if to.byTime:
    if track.timeBase.isNone:
      raise seekError(skUnseekable)
    let ts = track.timeBase.get.calcTimestamp(to.time)
    if ts.isNone:
      raise seekError(skUnseekable)
    req = ts.get
  else:
    if to.tsTrackId != 0:
      raise seekError(skInvalidTrack)
    req = to.ts
  if req.isNegative:
    raise seekError(skOutOfRange)
  if track.numFrames.isSome and
      req.get.uint64 > track.numFrames.get:
    raise seekError(skOutOfRange)
  let actual = w.packetInfo.getActualTs(req)
  w.r.pos = w.dataStart + (actual.get.uint64 * w.packetInfo.blockSize).int
  SeekedTo(trackId: 0, requiredTs: req, actualTs: actual)
