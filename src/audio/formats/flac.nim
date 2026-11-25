## FLAC demuxer (`FlacReader`) and muxer (`encodeFlacStream`).
##
## Demuxer ports `symphonia-bundle-flac` (`demuxer.rs`, `parser.rs` minus
## the streaming fragment machinery): `fLaC` marker, metadata blocks
## (StreamInfo required, VorbisComment tags, others skipped by length),
## frame indexing with header-CRC8 + footer-CRC16 verification, seek by
## binary search. Deviation: the reference parses packets on demand from
## a seekable stream; this reader is in-memory and builds an exact frame
## index on open, which makes seek trivial and integrity fail-closed.
##
## The muxer (`encodeFlacStream`) is new work: StreamInfo + minimal
## VorbisComment + frames from `encodeFlacFrame`.

import std/options
import std/sequtils
import ./../audio
import ./../checksum
import ./../codecs
import ./../codecs/flac
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../units

const
  FlacFormatInfo* = FormatInfo(id: FormatFlac, shortName: "flac",
    longName: "Free Lossless Audio Codec Native")
  FlacStreamMarker: array[4, uint8] = [0x66'u8, 0x4c, 0x61, 0x43] # "fLaC"
  FlacExtensions* = ["flac"]
  FlacMimeTypes* = ["audio/flac"]

type
  MetadataBlockType* = enum
    mbtStreamInfo = 0
    mbtPadding = 1
    mbtApplication = 2
    mbtSeekTable = 3
    mbtVorbisComment = 4
    mbtCuesheet = 5
    mbtPicture = 6

  FlacFrameIndex* = object
    offset*: int
    ts*: uint64
    samples*: uint16

  FlacReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    params*: AudioCodecParameters
    info*: StreamInfo
    index*: seq[FlacFrameIndex]
    audioStart*: int
    audioEnd*: int
    metadata*: MetadataLog
    posIdx*: int # Index position matching r.pos.

proc matchTag(data: openArray[uint8]; at: int;
    tag: array[4, uint8]): bool =
  data.len >= at + 4 and data[at] == tag[0] and data[at + 1] == tag[1] and
    data[at + 2] == tag[2] and data[at + 3] == tag[3]

proc probeFlac*(data: openArray[uint8]): int =
  ## 255 if `data` opens with `fLaC`, else 0.
  if matchTag(data, 0, FlacStreamMarker): 255 else: 0

# ------------------------------------------------------- metadata -------

const vorbisStdKeys = [
  ("TITLE", "track_title"), ("ARTIST", "artist"), ("ALBUM", "album"),
  ("GENRE", "genre"), ("DATE", "date"), ("TRACKNUMBER", "track_number"),
  ("COMMENT", "comment"), ("ENCODER", "encoder"), ("COPYRIGHT", "copyright"),
  ("ALBUMARTIST", "album_artist"), ("DISCNUMBER", "disc_number"),
]

proc parseVorbisComment*(r: var Reader; bodyLen: int): MetadataRevision =
  ## Parses a VorbisComment block. Unknown keys kept verbatim.
  let start = r.pos
  template need(n: int) =
    if r.pos + n > start + bodyLen:
      raise decodeError("flac: truncated vorbis comment")
  need(8)
  let vendorLen = r.readU32Le().int
  need(vendorLen + 4)
  let vendor = r.readBytesExact(vendorLen)
  var text = newString(vendor.len)
  for i, b in vendor:
    text[i] = b.char
  result.addTag(newTag("VENDOR", strValue(text), none(string)))
  let count = r.readU32Le().int
  for _ in 0 ..< count:
    need(4)
    let n = r.readU32Le().int
    need(n)
    let entry = r.readBytesExact(n)
    var eq = -1
    for i, b in entry:
      if b == uint8('='):
        eq = i
        break
    if eq < 0:
      continue
    var key = newString(eq)
    for i in 0 ..< eq:
      key[i] = entry[i].char
    var value = newString(n - eq - 1)
    for i in 0 ..< n - eq - 1:
      value[i] = entry[eq + 1 + i].char
    var stdKey = none(string)
    let upper =
      block:
        var u = key
        for i in 0 ..< u.len:
          if u[i] >= 'a' and u[i] <= 'z':
            u[i] = chr(ord(u[i]) - 32)
        u
    for (raw, std) in vorbisStdKeys:
      if upper == raw:
        stdKey = some(std)
        break
    result.addTag(newTag(key, strValue(value), stdKey))

# ---------------------------------------------------------- index -------

proc seqOf(header: FrameHeader): uint64 =
  case header.sequence.kind
  of bsSample: header.sequence.sample
  of bsFrame: header.sequence.frame.uint64

proc fillStream(header: var FrameHeader; info: StreamInfo) =
  ## Fills rate/bps from StreamInfo for strict comparison.
  if header.sampleRate.isNone:
    header.sampleRate = some(info.sampleRate)
  if header.bitsPerSample.isNone:
    header.bitsPerSample = some(info.bitsPerSample)

proc headerAt(data: seq[uint8]; q: int): Option[FrameHeader] =
  ## Sync + parse + CRC8 at `q`, no strict checks. None on any failure.
  if q + 1 >= data.len:
    return none(FrameHeader)
  if data[q] != 0xff'u8 or (data[q + 1] and 0xfc'u8) != 0xf8'u8:
    return none(FrameHeader)
  if data.len - q < FlacMinFrameHeaderSize:
    return none(FrameHeader)
  if not isLikelyFrameHeader(data.toOpenArray(q,
      min(q + FlacMaxFrameHeaderSize - 1, data.len - 1))):
    return none(FrameHeader)
  var r = newReader(data.toOpenArray(q, data.len - 1))
  var sync = 0'u16
  try:
    sync = syncFrame(r)
  except AudioError:
    return none(FrameHeader)
  try:
    some(readFrameHeader(r, sync))
  except AudioError:
    none(FrameHeader)

proc verifyFooter(data: seq[uint8]; s, e: int): bool =
  ## Checks the BE CRC16 footer over bytes [s, e).
  if e - s < 4:
    return false
  let foot = (data[e - 2].uint16 shl 8) or data[e - 1].uint16
  crc16Ansi(data.toOpenArray(s, e - 3)) == foot

proc calcTs(info: StreamInfo; header: FrameHeader): uint64 =
  let fixed = info.blockLenMin == info.blockLenMax
  case header.sequence.kind
  of bsSample:
    header.sequence.sample
  of bsFrame:
    if fixed:
      header.sequence.frame.uint64 * info.blockLenMin.uint64
    else:
      header.sequence.frame.uint64 * header.blockSamples.uint64

proc strictCheck(info: StreamInfo; header: FrameHeader;
    lastSeq: uint64; hasLast: bool; isFixed: bool): bool =
  if header.sampleRate.isSome and header.sampleRate.get != info.sampleRate:
    return false
  if header.bitsPerSample.isSome and
      header.bitsPerSample.get != info.bitsPerSample:
    return false
  if header.blockSamples > info.blockLenMax:
    return false
  let mono =
    case header.sequence.kind
    of bsSample:
      not isFixed and (header.sequence.sample > lastSeq or
        (not hasLast and header.sequence.sample == 0))
    of bsFrame:
      isFixed and (header.sequence.frame.uint64 > lastSeq or
        (not hasLast and header.sequence.frame == 0))
  if not mono:
    return false
  let nch =
    case header.assignment.kind
    of caIndependent: header.assignment.channels.int
    else: 2
  nch == info.channels.channelCount()

proc buildIndex(data: seq[uint8]; info: StreamInfo;
    start: int): tuple[index: seq[FlacFrameIndex], lastSeq: uint64,
    hasLast: bool] =
  ## Eager frame table with full integrity verification.
  var index: seq[FlacFrameIndex] = @[]
  var pos = start
  var lastSeq = 0'u64
  var hasLast = false
  let isFixed = info.blockLenMin == info.blockLenMax
  # Minimal header for the strict check (rate/bps from StreamInfo so the
  # check matches the reference, which fills them in first).
  while pos < data.len:
    # Scan for the sync word.
    var syncAt = -1
    var p = pos
    while p + 1 < data.len:
      if data[p] == 0xff'u8 and (data[p + 1] and 0xfc'u8) == 0xf8'u8:
        syncAt = p
        break
      inc p
    if syncAt < 0:
      break
    let h0 = headerAt(data, syncAt)
    if h0.isNone:
      pos = syncAt + 1
      continue
    var hdr = h0.get
    fillStream(hdr, info)
    if not strictCheck(info, hdr, lastSeq, hasLast, isFixed):
      pos = syncAt + 1
      continue
    # Find the frame end: the next header that is monotonic and strict.
    # A footer mismatch means a false boundary: keep scanning.
    var frameEnd = -1
    var q = syncAt + 2
    while q + 1 < data.len:
      if data[q] == 0xff'u8 and (data[q + 1] and 0xfc'u8) == 0xf8'u8:
        let h1 = headerAt(data, q)
        if h1.isSome:
          var hh = h1.get
          fillStream(hh, info)
          if seqOf(hh) > seqOf(hdr) and
              strictCheck(info, hh, seqOf(hdr), true, isFixed) and
              verifyFooter(data, syncAt, q):
            frameEnd = q
            break
      inc q
    if frameEnd < 0:
      # Last frame runs to end of data.
      frameEnd = data.len
      if not verifyFooter(data, syncAt, frameEnd):
        raise decodeError("flac: frame footer CRC mismatch")
    let ts = calcTs(info, hdr)
    index.add(FlacFrameIndex(offset: syncAt, ts: ts,
      samples: hdr.blockSamples))
    lastSeq = seqOf(hdr)
    hasLast = true
    pos = frameEnd
  (index, lastSeq, hasLast)

# ---------------------------------------------------------- demuxer ------

proc openFlac*(data: seq[uint8]): FlacReader =
  ## Opens a complete native FLAC stream held in memory.
  var r = newReader(data)
  if r.remaining() < 4 or r.readFourCc() != [0x66'u8, 0x4c, 0x61, 0x43]:
    raise unsupportedError("flac: missing flac stream marker")
  var trackOpt: Option[Track] = none(Track)
  var paramsOpt: Option[AudioCodecParameters] = none(AudioCodecParameters)
  var infoOpt: Option[StreamInfo] = none(StreamInfo)
  var metaLog = MetadataLog()
  var done = false
  while not done:
    if r.remaining() < 4:
      raise decodeError("flac: truncated metadata block header")
    let headerByte = r.readByte()
    let isLast = (headerByte and 0x80'u8) != 0
    let blockType = headerByte and 0x7f'u8
    let bodyLen = r.readU24Be().int
    if r.remaining() < bodyLen:
      raise decodeError("flac: truncated metadata block")
    let body = r.readBytesExact(bodyLen)
    case blockType
    of 0: # StreamInfo
      if trackOpt.isSome:
        raise decodeError("flac: found more than one stream info block")
      if body.len != 34:
        raise decodeError("flac: invalid stream info block size")
      let info = parseStreamInfo(body)
      var codecParams = forCodec(CodecFlac)
      codecParams.extraData = body
      codecParams.sampleRate = some(info.sampleRate)
      codecParams.bitsPerSample = some(info.bitsPerSample)
      codecParams.channels = some(info.channels)
      if info.md5.isSome:
        codecParams.verificationMd5 = info.md5
      var track = newTrack(0, codecParams)
      if info.nSamples.isSome:
        track.numFrames = info.nSamples
        track.duration = some(newDuration(info.nSamples.get))
      trackOpt = some(track)
      paramsOpt = some(codecParams)
      infoOpt = some(info)
      # maxFramesPerPacket needs block_len_max: set below.
    of 4: # VorbisComment
      var br = newReader(body)
      metaLog.push(parseVorbisComment(br, bodyLen))
    else:
      discard # Application/SeekTable/Cuesheet/Picture/Padding/Unknown.
    done = isLast
  if trackOpt.isNone or paramsOpt.isNone or infoOpt.isNone:
    raise decodeError("flac: no stream info block")
  var params = paramsOpt.get
  let info = infoOpt.get
  params.maxFramesPerPacket = some(info.blockLenMax.uint64)
  # Rebuild the track with the final params (max frames known now).
  var track = newTrack(0, params)
  if info.nSamples.isSome:
    track.numFrames = info.nSamples
    track.duration = some(newDuration(info.nSamples.get))
  let audioStart = r.pos
  let (index, _, _) = buildIndex(data, info, audioStart)
  if index.len == 0:
    raise decodeError("flac: no audio frames")
  result = FlacReader(r: r, tracks: @[track], params: params, info: info,
    index: index, audioStart: audioStart, audioEnd: data.len,
    metadata: metaLog)
  result.r.pos = audioStart

proc trackCount*(w: FlacReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: FlacReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: FlacReader): Option[uint64] = w.tracks[0].numFrames

proc nextPacket*(w: FlacReader): Option[Packet] =
  ## Packets slice whole frames by index (amortized O(1) via posIdx).
  while w.posIdx < w.index.len and w.index[w.posIdx].offset < w.r.pos:
    inc w.posIdx
  if w.posIdx >= w.index.len or w.index[w.posIdx].offset != w.r.pos:
    return none(Packet)
  let fr = w.index[w.posIdx]
  let start = fr.offset
  let stop =
    if w.posIdx + 1 < w.index.len: w.index[w.posIdx + 1].offset
    else: w.audioEnd
  w.r.pos = stop
  inc w.posIdx
  some(newPacket(0, newTimestamp(cast[int64](fr.ts)),
    newDuration(fr.samples.uint64), w.r.data[start ..< stop]))

proc seek*(w: FlacReader; to: SeekTo): SeekedTo =
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
      cast[uint64](req.get) > track.numFrames.get:
    raise seekError(skOutOfRange)
  # Binary search the last frame with ts <= req.
  var found = 0
  var lo = 0
  var hi = w.index.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    if cast[int64](w.index[mid].ts) <= req.get:
      found = mid
      lo = mid + 1
    else:
      hi = mid - 1
  let fr = w.index[found]
  w.r.pos = fr.offset
  w.posIdx = found
  SeekedTo(trackId: 0, requiredTs: req,
    actualTs: newTimestamp(cast[int64](fr.ts)))

# ------------------------------------------------------------ muxer ------

proc toRawPlanes*(samples: AudioSamples; bps: uint32): seq[seq[int32]] =
  ## Extracts raw LSB-aligned values at `bps` width.
  case samples.format
  of sfS16:
    if bps != 16:
      raise unsupportedError("flac: s16 needs 16 bits per sample")
    result = newSeq[seq[int32]](samples.s16.planes.len)
    for p in 0 ..< result.len:
      result[p] = newSeq[int32](samples.s16.numFrames)
      for i in 0 ..< samples.s16.numFrames:
        result[p][i] = samples.s16.planes[p][i].int32
  of sfS24:
    if bps != 24:
      raise unsupportedError("flac: s24 needs 24 bits per sample")
    result = newSeq[seq[int32]](samples.s24.planes.len)
    for p in 0 ..< result.len:
      result[p] = newSeq[int32](samples.s24.numFrames)
      for i in 0 ..< samples.s24.numFrames:
        result[p][i] = samples.s24.planes[p][i]
  of sfS32:
    # MSB-aligned decoder output: shift down to raw width.
    if bps > 32 or bps < 4:
      raise unsupportedError("flac: invalid bits per sample")
    let shift = (32 - bps).int
    result = newSeq[seq[int32]](samples.s32.planes.len)
    for p in 0 ..< result.len:
      result[p] = newSeq[int32](samples.s32.numFrames)
      for i in 0 ..< samples.s32.numFrames:
        result[p][i] = samples.s32.planes[p][i] shr shift
  else:
    raise unsupportedError("flac: encoder needs s16, s24 or s32 input")

proc encodeFlacStream*(samples: AudioSamples; sampleRate: uint32;
    bitsPerSample = 0'u32): seq[uint8] =
  ## Muxes planar samples into a complete native FLAC stream (new work).
  let bps =
    if bitsPerSample != 0: bitsPerSample
    else:
      case samples.format
      of sfS16: 16'u32
      of sfS24: 24'u32
      of sfS32: 32'u32
      else: raise unsupportedError("flac: encoder needs s16, s24 or s32")
  let planes = toRawPlanes(samples, bps)
  let nch = planes.len
  if nch < 1 or nch > 8:
    raise unsupportedError("flac: invalid channel count")
  if sampleRate == 0 or sampleRate > 655_350:
    raise unsupportedError("flac: sample rate out of bounds")
  let n = samples.framesOf()
  if n == 0:
    raise unsupportedError("flac: no frames to encode")
  const BlockSize = 4096
  let blk = min(n, BlockSize)
  var info = StreamInfo(blockLenMin: cast[uint16](blk),
    blockLenMax: cast[uint16](blk), frameByteLenMin: 0,
    frameByteLenMax: 0, sampleRate: sampleRate,
    channels: flacChannels(nch), bitsPerSample: bps,
    nSamples: some(n.uint64), md5: none(array[16, uint8]))
  # MD5 over the input (validator scheme: interleaved LE at byte width).
  var validator: FlacValidator
  validator.initValidator()
  var tmp = AudioBuffer[int32](
    spec: newAudioSpec(sampleRate, flacChannels(nch)), planes: planes,
    numFrames: n, capacity: n)
  validator.updateValidator(tmp, bps)
  info.md5 = some(validator.validatorDigest())
  # min == max declares fixed blocking; a short tail block is legal
  # (the strict header check only rejects blocks larger than the max).
  var w = newWriter()
  w.writeBytes([0x66'u8, 0x4c, 0x61, 0x43])
  # StreamInfo (not last).
  w.writeByte(0x00)
  w.writeU24Be(34)
  w.writeBytes(writeStreamInfo(info))
  # Minimal VorbisComment (last): vendor "openAudio", no tags.
  let vendor = "openAudio"
  w.writeByte(0x80 or 4)
  var vc = newWriter()
  vc.writeU32Le(vendor.len.uint32)
  vc.writeBytes(vendor.toBytes())
  vc.writeU32Le(0)
  let vcBytes = vc.toBytes()
  w.writeU24Be(vcBytes.len.uint32)
  w.writeBytes(vcBytes)
  # Frames.
  var frameNum = 0'u32
  var off = 0
  while off < n:
    let m = min(blk, n - off)
    var blockPlanes = newSeq[seq[int32]](nch)
    for p in 0 ..< nch:
      blockPlanes[p] = planes[p].toOpenArray(off, off + m - 1).toSeq()
    w.writeBytes(encodeFlacFrame(blockPlanes, frameNum, bps.int))
    inc frameNum
    off += m
  w.toBytes()
