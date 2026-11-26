## Matroska / WebM demuxer (`MkvReader`), audio only.
##
## Ports `symphonia-format-mkv` demuxer/ebml/segment/lacing/codecs for the
## audio subset: EBML header (`DocType` matroska/webm), `Segment` walk
## (`SeekHead`/`Info`/`Tracks`/`Cluster`/`Cues`, `Tags`/`Attachments`/
## `Chapters` skipped), track mapping (`A_VORBIS`, `A_FLAC`, `A_OPUS`,
## `A_MPEG/L1|L2|L3`, `A_AAC*`, `A_ALAC`, `A_PCM/INT|FLOAT` variants),
## `CodecPrivate` handling (Vorbis Xiph headers, FLAC STREAMINFO, raw
## passthrough otherwise), Block/SimpleBlock delacing (none/Xiph/
## fixed/EBML), timestamp conversion via TimestampScale, eager packet
## index, cue-assisted floor seek.
## Deviations: in-memory with an eager packet index (no streaming);
## video/subtitle tracks and attachments/chapters/tags are skipped, only
## audio tracks are exposed; unknown audio codecs (`A_AC3`, `A_DTS`, ...)
## are skipped; `DiscardPadding`/`CodecDelay` gapless trims are parsed
## but not applied (as in the reference); `A_OPUS` demuxes but has no
## registered decoder yet (decode raises `ekUnsupported`).

import std/math
import std/options
import std/tables
import ./../audio
import ./../codecs
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../source
import ./../units

const
  MkvFormatInfo* = FormatInfo(id: FormatMkv, shortName: "matroska",
    longName: "Matroska / WebM")
  MkvMaxDepth* = 16
  MkvMaxBlockFrames* = 64

type
  MkvPacket* = object
    trackIdx*: int
    pts*: int64
    dur*: uint64
    data*: seq[uint8]

  MkvCue* = object
    timeNs*: uint64
    trackNum*: uint64
    clusterPos*: uint64
    relPos*: Option[uint64]

  MkvTrackState* = object
    trackNum*: uint32
    trackIdx*: int
    sampleRate*: uint32
    trackScale*: float64
    tickNs*: float64 ## Nanoseconds per track tick.
    timeBase*: TimeBase
    codecDelayTicks*: int64
    defaultDurTicks*: uint64
    hasDefaultDur*: bool

  MkvReader* = ref object
    r*: Reader
    segmentStart*: int ## Absolute offset of Segment payload start.
    tracks*: seq[Track]
    trackStates*: seq[MkvTrackState]
    trackIdxByNum*: Table[uint32, int]
    packets*: seq[MkvPacket]
    posIdx*: int
    cues*: seq[MkvCue]
    segTimeBase*: TimeBase
    segScale*: uint64
    segDur*: Option[uint64] ## Segment ticks.
    metadata*: MetadataLog

# ------------------------------------------------------------- EBML ---

type
  EbmlHeader* = object
    id*: uint32
    dataPos*: int
    dataSize*: Option[uint64] ## None = unknown size (extends to parent end).
    headerLen*: int

proc readEbmlId[R](r: var R): tuple[id: uint32, len: int] =
  if r.remaining() < 1:
    raise newException(EndOfStream, "mkv: end of stream")
  let b0 = r.readByte()
  var ln = 1
  var mask = 0x80'u8
  while (b0 and mask) == 0:
    mask = mask shr 1
    inc ln
    if ln > 4:
      raise decodeError("mkv (ebml): invalid element id length")
  if r.remaining() < ln - 1:
    raise newException(EndOfStream, "mkv: end of stream")
  var id = b0.uint32
  for _ in 1 ..< ln:
    id = (id shl 8) or r.readByte().uint32
  (id, ln)

proc readEbmlSize[R](r: var R): tuple[size: Option[uint64], len: int] =
  if r.remaining() < 1:
    raise newException(EndOfStream, "mkv: end of stream")
  let b0 = r.readByte()
  var ln = 1
  var mask = 0x80'u8
  while (b0 and mask) == 0:
    mask = mask shr 1
    inc ln
    if ln > 8:
      raise decodeError("mkv (ebml): invalid data size length")
  if r.remaining() < ln - 1:
    raise newException(EndOfStream, "mkv: end of stream")
  var v = (b0 xor (0x80'u8 shr (ln - 1))).uint64
  for _ in 1 ..< ln:
    v = (v shl 8) or r.readByte().uint64
  var allOne = true
  var m = (1'u64 shl (7 * ln)) - 1
  if ln == 8:
    m = high(uint64) shr 1
  if v != m:
    allOne = false
  if allOne:
    (none(uint64), ln)
  else:
    (some(v), ln)

proc readHeader[R](r: var R; parentEnd: int): Option[EbmlHeader] =
  ## Reads one element header or returns none at end of parent. `parentEnd`
  ## is -1 for unknown (extends to EOF).
  if parentEnd >= 0:
    if r.pos >= parentEnd:
      return none(EbmlHeader)
    if parentEnd - r.pos < 2:
      return none(EbmlHeader)
  elif r.remaining() < 2:
    return none(EbmlHeader)
  let start = r.pos
  let (id, _) = r.readEbmlId()
  let (size, _) = r.readEbmlSize()
  let dataPos = r.pos
  if size.isSome:
    let stop = dataPos + size.get.int
    if parentEnd >= 0 and stop > parentEnd:
      # Overrun: swallow to parent end like the reference.
      r.pos = parentEnd
      return none(EbmlHeader)
    if stop > bufLen(r):
      raise decodeError("mkv (ebml): element overruns file")
  EbmlHeader(id: id, dataPos: dataPos, dataSize: size,
    headerLen: dataPos - start).some

proc elemEnd(h: EbmlHeader; parentEnd: int; fileLen: int): int =
  if h.dataSize.isSome: h.dataPos + h.dataSize.get.int
  elif parentEnd >= 0: parentEnd
  else: fileLen

proc skipElem[R](r: var R; h: EbmlHeader; parentEnd: int) =
  r.pos = elemEnd(h, parentEnd, bufLen(r))

proc readUIntElem[R](r: var R; h: EbmlHeader; parentEnd: int): uint64 =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  let n = stop - r.pos
  if n < 0 or n > 8:
    raise decodeError("mkv (ebml): invalid unsigned integer size")
  var v = 0'u64
  for _ in 0 ..< n:
    v = (v shl 8) or r.readByte().uint64
  v

proc readSIntElem[R](r: var R; h: EbmlHeader; parentEnd: int): int64 =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  let n = stop - r.pos
  if n < 0 or n > 8:
    raise decodeError("mkv (ebml): invalid signed integer size")
  if n == 0:
    return 0
  var v = 0'u64
  for _ in 0 ..< n:
    v = (v shl 8) or r.readByte().uint64
  # Sign-extend from 8*n bits.
  let shift = 64 - 8 * n
  cast[int64](v shl shift) shr shift

proc readFloatElem[R](r: var R; h: EbmlHeader; parentEnd: int): float64 =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  let n = stop - r.pos
  if n == 0:
    return 0.0
  elif n == 4:
    let bits = r.readU32Be()
    cast[float32](bits).float64
  elif n == 8:
    let bits = r.readU64Be()
    cast[float64](bits)
  else:
    raise decodeError("mkv (ebml): invalid float size")

proc readStringElem[R](r: var R; h: EbmlHeader; parentEnd: int): string =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  let n = stop - r.pos
  if n < 0:
    raise decodeError("mkv (ebml): element overruns parent")
  var bytes = r.readBytesExact(n)
  var stopAt = bytes.len
  for i, b in bytes:
    if b == 0:
      stopAt = i
      break
  result = newString(stopAt)
  for i in 0 ..< stopAt:
    result[i] = bytes[i].char

proc readBinaryElem[R](r: var R; h: EbmlHeader; parentEnd: int): seq[uint8] =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  let n = stop - r.pos
  if n < 0:
    raise decodeError("mkv (ebml): element overruns parent")
  r.readBytesExact(n)

proc probeMkv*(data: openArray[uint8]): int =
  if data.len < 4:
    return 0
  if data[0] == 0x1a'u8 and data[1] == 0x45'u8 and data[2] == 0xDF'u8 and
      data[3] == 0xA3'u8:
    255
  else:
    0

# Element IDs.
const
  EidEbml* = 0x1A45DFA3'u32
  EidDocType* = 0x4282'u32
  EidSegment* = 0x18538067'u32
  EidSeekHead* = 0x114D9B74'u32
  EidSeek* = 0x4DBB'u32
  EidSeekId* = 0x53AB'u32
  EidSeekPos* = 0x53AC'u32
  EidInfo* = 0x1549A966'u32
  EidTimestampScale* = 0x2AD7B1'u32
  EidDuration* = 0x4489'u32
  EidTitle* = 0x7BA9'u32
  EidMuxingApp* = 0x4D80'u32
  EidWritingApp* = 0x5741'u32
  EidTracks* = 0x1654AE6B'u32
  EidTrackEntry* = 0xAE'u32
  EidTrackNumber* = 0xD7'u32
  EidTrackUid* = 0x73C5'u32
  EidTrackType* = 0x83'u32
  EidFlagEnabled* = 0xB9'u32
  EidFlagDefault* = 0x88'u32
  EidFlagForced* = 0x55AA'u32
  EidFlagLacing* = 0x9C'u32
  EidDefaultDuration* = 0x23E383'u32
  EidCodecId* = 0x86'u32
  EidCodecPrivate* = 0x63A2'u32
  EidCodecName* = 0x258688'u32
  EidCodecDelay* = 0x56AA'u32
  EidSeekPreRoll* = 0x56BB'u32
  EidTrackTimestampScale* = 0x23314F'u32
  EidLanguage* = 0x22B59C'u32
  EidTrackName* = 0x536E'u32
  EidAudio* = 0xE1'u32
  EidChannels* = 0x9F'u32
  EidSamplingFreq* = 0xB5'u32
  EidOutSamplingFreq* = 0x78B5'u32
  EidBitDepth* = 0x6264'u32
  EidVideo* = 0xE0'u32
  EidCluster* = 0x1F43B675'u32
  EidClusterTimestamp* = 0xE7'u32
  EidSimpleBlock* = 0xA3'u32
  EidBlockGroup* = 0xA0'u32
  EidBlock* = 0xA1'u32
  EidBlockDuration* = 0x9B'u32
  EidRefBlock* = 0xFB'u32
  EidDiscardPadding* = 0x75A2'u32
  EidCues* = 0x1C53BB6B'u32
  EidCuePoint* = 0xBB'u32
  EidCueTime* = 0xB3'u32
  EidCueTrackPos* = 0xB7'u32
  EidCueTrack* = 0xF7'u32
  EidCueClusterPos* = 0xF1'u32
  EidCueRelPos* = 0xF0'u32
  EidCueBlockNum* = 0x5378'u32
  EidTags* = 0x1254C367'u32
  EidAttachments* = 0x1941A469'u32
  EidChapters* = 0x1043A770'u32
  EidVoid* = 0xEC'u32
  EidCrc32* = 0xBF'u32

proc isSegmentLevel(id: uint32): bool =
  id in [EidSeekHead, EidInfo, EidTracks, EidCluster, EidCues, EidTags,
    EidAttachments, EidChapters, EidVoid, EidCrc32]

type
  RawTrack* = object
    number*: uint64
    uid*: uint64
    trackType*: uint64
    hasType*: bool
    codecId*: string
    codecPrivate*: seq[uint8]
    hasPrivate*: bool
    channels*: uint64
    sampleRate*: float64
    hasSampleRate*: bool
    bitDepth*: uint64
    hasBitDepth*: bool
    defaultDurationNs*: uint64
    hasDefaultDur*: bool
    codecDelayNs*: uint64
    trackScale*: float64
    language*: string
    isAudio*: bool

proc parseAudio[R](r: var R; h: EbmlHeader; parentEnd: int;
    t: var RawTrack) =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  while true:
    let ch = r.readHeader(stop)
    if ch.isNone:
      break
    let c = ch.get
    case c.id
    of EidChannels:
      t.channels = r.readUIntElem(c, stop)
    of EidSamplingFreq:
      t.sampleRate = r.readFloatElem(c, stop)
      t.hasSampleRate = true
    of EidOutSamplingFreq:
      discard r.readFloatElem(c, stop)
    of EidBitDepth:
      t.bitDepth = r.readUIntElem(c, stop)
      t.hasBitDepth = true
    else:
      r.skipElem(c, stop)

proc parseTrackEntry[R](r: var R; h: EbmlHeader;
    parentEnd: int): RawTrack =
  result = RawTrack(channels: 1, sampleRate: 8000.0, trackScale: 1.0,
    language: "eng")
  let stop = elemEnd(h, parentEnd, bufLen(r))
  while true:
    let ch = r.readHeader(stop)
    if ch.isNone:
      break
    let c = ch.get
    case c.id
    of EidTrackNumber:
      result.number = r.readUIntElem(c, stop)
    of EidTrackUid:
      result.uid = r.readUIntElem(c, stop)
    of EidTrackType:
      result.trackType = r.readUIntElem(c, stop)
      result.hasType = true
    of EidFlagEnabled, EidFlagDefault, EidFlagForced, EidFlagLacing,
        EidSeekPreRoll:
      discard r.readUIntElem(c, stop)
    of EidCodecName, EidTrackName:
      discard r.readStringElem(c, stop)
    of EidDefaultDuration:
      result.defaultDurationNs = r.readUIntElem(c, stop)
      result.hasDefaultDur = true
    of EidCodecId:
      result.codecId = r.readStringElem(c, stop)
    of EidCodecPrivate:
      result.codecPrivate = r.readBinaryElem(c, stop)
      result.hasPrivate = true
    of EidCodecDelay:
      result.codecDelayNs = r.readUIntElem(c, stop)
    of EidTrackTimestampScale:
      result.trackScale = r.readFloatElem(c, stop)
    of EidLanguage:
      result.language = r.readStringElem(c, stop)
    of EidAudio:
      parseAudio(r, c, stop, result)
      r.pos = elemEnd(c, stop, bufLen(r))
    of EidVideo:
      result.isAudio = false
      r.skipElem(c, stop)
    else:
      r.skipElem(c, stop)
  if result.hasType:
    result.isAudio = result.trackType == 2
  else:
    result.isAudio = result.codecId.len >= 2 and
      result.codecId[0] == 'A' and result.codecId[1] == '_'

proc readXiphSizes(data: openArray[uint8]; pos: var int;
    count: int): seq[uint64] =
  result = @[]
  for _ in 0 ..< count:
    var v = 0'u64
    while true:
      if pos >= data.len:
        raise decodeError("mkv: truncated vorbis codec private")
      let b = data[pos]
      inc pos
      v += b.uint64
      if b != 0xff:
        break
    result.add(v)

proc vorbisExtra(data: openArray[uint8]): seq[uint8] =
  if data.len < 1:
    raise decodeError("mkv: missing vorbis codec private")
  let nLens = data[0].int
  var pos = 1
  let sizes = readXiphSizes(data, pos, nLens)
  var packets: seq[seq[uint8]] = @[]
  for i in 0 ..< nLens:
    let ln = sizes[i].int
    if pos + ln > data.len:
      raise decodeError("mkv: truncated vorbis codec private")
    packets.add(@(data.toOpenArray(pos, pos + ln - 1)))
    pos += ln
  packets.add(@(data.toOpenArray(pos, data.len - 1)))
  var idp: seq[uint8] = @[]
  var setup: seq[uint8] = @[]
  for p in packets:
    if p.len > 0 and p[0] == 0x01:
      idp = p
    elif p.len > 0 and p[0] == 0x05:
      setup = p
  if idp.len == 0:
    raise decodeError("mkv: missing vorbis ident header")
  if setup.len == 0:
    raise decodeError("mkv: missing vorbis setup header")
  idp & setup

proc flacExtra(data: openArray[uint8]): seq[uint8] =
  if data.len < 4 or not (data[0] == 0x66'u8 and data[1] == 0x4c'u8 and
      data[2] == 0x61'u8 and data[3] == 0x43'u8):
    raise decodeError("mkv (flac): missing flac stream marker")
  var pos = 4
  while pos + 4 <= data.len:
    let last = (data[pos] and 0x80) != 0
    let typ = data[pos] and 0x7f
    let ln = (data[pos+1].int shl 16) or (data[pos+2].int shl 8) or
      data[pos+3].int
    pos += 4
    if pos + ln > data.len:
      raise decodeError("mkv (flac): truncated metadata block")
    if typ == 0:
      if ln != 34:
        raise decodeError("isomp4 (flac): invalid stream info block length")
      return @(data.toOpenArray(pos, pos + ln - 1))
    pos += ln
    if last:
      break
  raise decodeError("mkv (flac): missing stream info block")

proc mapAudioTrack(t: RawTrack): Option[AudioCodecParameters] =
  if not t.isAudio:
    return none(AudioCodecParameters)
  if t.number == 0 or t.number > high(uint32).uint64:
    raise decodeError("mkv: invalid track number")
  let rate =
    if t.hasSampleRate: t.sampleRate
    else: 8000.0
  if rate <= 0.0 or rate >= 4_294_967_295.0:
    raise decodeError("mkv: invalid sampling frequency")
  let nch = t.channels.int
  if nch < 1 or nch > 64:
    raise decodeError("mkv: invalid channel count")
  var params = forCodec(CodecNull)
  var mapped = true
  case t.codecId
  of "A_VORBIS":
    params = forCodec(CodecVorbis)
    if not t.hasPrivate:
      raise decodeError("mkv: missing vorbis codec private")
    params.extraData = vorbisExtra(t.codecPrivate)
  of "A_FLAC":
    params = forCodec(CodecFlac)
    if t.hasPrivate:
      params.extraData = flacExtra(t.codecPrivate)
  of "A_OPUS":
    params = forCodec(CodecOpus)
    if t.hasPrivate:
      params.extraData = t.codecPrivate
  of "A_MPEG/L1":
    params = forCodec(CodecMp1)
  of "A_MPEG/L2":
    params = forCodec(CodecMp2)
  of "A_MPEG/L3":
    params = forCodec(CodecMp3)
  of "A_AAC", "A_AAC/MPEG2/MAIN", "A_AAC/MPEG2/LC", "A_AAC/MPEG2/LC/SBR",
      "A_AAC/MPEG2/SSR", "A_AAC/MPEG4/MAIN", "A_AAC/MPEG4/LC",
      "A_AAC/MPEG4/LC/SBR", "A_AAC/MPEG4/SSR", "A_AAC/MPEG4/LTP":
    params = forCodec(CodecAac)
    if t.hasPrivate:
      params.extraData = t.codecPrivate
  of "A_ALAC":
    params = forCodec(CodecAlac)
    if t.hasPrivate:
      params.extraData = t.codecPrivate
    else:
      raise decodeError("mkv: missing ALAC codec private")
  of "A_PCM/INT/BIG":
    if not t.hasBitDepth:
      return none(AudioCodecParameters)
    case t.bitDepth
    of 16: params = forCodec(CodecPcmS16Be)
    of 24: params = forCodec(CodecPcmS24Be)
    of 32: params = forCodec(CodecPcmS32Be)
    else: return none(AudioCodecParameters)
  of "A_PCM/INT/LIT":
    if not t.hasBitDepth:
      return none(AudioCodecParameters)
    case t.bitDepth
    of 16: params = forCodec(CodecPcmS16Le)
    of 24: params = forCodec(CodecPcmS24Le)
    of 32: params = forCodec(CodecPcmS32Le)
    else: return none(AudioCodecParameters)
  of "A_PCM/FLOAT/IEEE":
    if not t.hasBitDepth:
      return none(AudioCodecParameters)
    case t.bitDepth
    of 32: params = forCodec(CodecPcmF32Le)
    of 64: params = forCodec(CodecPcmF64Le)
    else: return none(AudioCodecParameters)
  else:
    mapped = false
  if not mapped:
    return none(AudioCodecParameters)
  params.sampleRate = some(rate.uint32)
  params.channels = some(discrete(nch))
  if t.hasBitDepth:
    params.bitsPerSample = some(t.bitDepth.uint32)
    params.bitsPerCodedSample = some(t.bitDepth.uint32)
  some(params)

proc readVintUnsigned(data: openArray[uint8]; pos: var int): uint64 =
  if pos >= data.len:
    raise decodeError("mkv: truncated block header")
  let b0 = data[pos]
  var ln = 1
  var mask = 0x80'u8
  while (b0 and mask) == 0:
    mask = mask shr 1
    inc ln
    if ln > 8:
      raise decodeError("mkv (ebml): invalid data size length")
  if pos + ln > data.len:
    raise decodeError("mkv: truncated block header")
  var v = (b0 xor (0x80'u8 shr (ln - 1))).uint64
  for i in 1 ..< ln:
    v = (v shl 8) or data[pos + i].uint64
  pos += ln
  v

proc readVintSigned(data: openArray[uint8]; pos: var int): int64 =
  if pos >= data.len:
    raise decodeError("mkv: truncated block header")
  let b0 = data[pos]
  var ln = 1
  var mask = 0x80'u8
  while (b0 and mask) == 0:
    mask = mask shr 1
    inc ln
    if ln > 8:
      raise decodeError("mkv (ebml): invalid data size length")
  if pos + ln > data.len:
    raise decodeError("mkv: truncated block header")
  var v = (b0 xor (0x80'u8 shr (ln - 1))).uint64
  for i in 1 ..< ln:
    v = (v shl 8) or data[pos + i].uint64
  pos += ln
  v.int64 - ((1'i64 shl (7 * ln - 1)) - 1)

proc segToTrack(seg: uint64; scale: float64): int64 =
  if scale == 1.0:
    if seg > uint64(high(int64)):
      return high(int64)
    return seg.int64
  let v = (seg.float64 / scale).round()
  if v > high(int64).float64 or v != v:
    return high(int64)
  v.int64

proc nsToTrack(ns: uint64; tickNs: float64): uint64 =
  if tickNs <= 0.0 or tickNs != tickNs:
    return 0
  let v = (ns.float64 / tickNs).round()
  if v != v or v > high(uint64).float64:
    return high(uint64)
  v.uint64

proc extractFrames(blockData: openArray[uint8];
    states: seq[MkvTrackState]; byNum: Table[uint32, int];
    clusterTs: uint64; blockDur: Option[uint64];
    outPackets: var seq[MkvPacket]) =
  var pos = 0
  let trackVint = readVintUnsigned(blockData, pos)
  if trackVint == 0 or trackVint > high(uint32).uint64:
    raise decodeError("mkv: invalid track number")
  let trackNum = trackVint.uint32
  if not byNum.hasKey(trackNum):
    raise decodeError("mkv: invalid track number for block")
  let si = byNum[trackNum]
  let st = states[si]
  if pos + 3 > blockData.len:
    raise decodeError("mkv: truncated block header")
  let rel = cast[int16]((blockData[pos].uint16 shl 8) or
    blockData[pos + 1].uint16).int64
  pos += 2
  let flags = blockData[pos]
  inc pos
  let lacing = (flags shr 1) and 0x3
  var nFrames = 1
  if lacing != 0:
    if pos >= blockData.len:
      raise decodeError("mkv: truncated block header")
    nFrames = blockData[pos].int + 1
    inc pos
    if nFrames > MkvMaxBlockFrames:
      raise decodeError("mkv: too many laced frames")
  var sizes: seq[int] = @[]
  if lacing == 1: # Xiph
    var total = 0
    for _ in 0 ..< nFrames - 1:
      var v = 0
      while true:
        if pos >= blockData.len:
          raise decodeError("mkv: truncated lacing sizes")
        let b = blockData[pos].int
        inc pos
        v += b
        if b != 0xff:
          break
      sizes.add(v)
      total += v
      if total > blockData.len - pos:
        raise decodeError("mkv: total of laced frame sizes exceeds block")
  elif lacing == 3: # EBML
    var total = 0'i64
    var prev = 0'i64
    for i in 0 ..< nFrames - 1:
      var sz: int64
      if i == 0:
        sz = readVintUnsigned(blockData, pos).int64
      else:
        sz = prev + readVintSigned(blockData, pos)
      if sz < 0:
        raise decodeError("mkv: invalid ebml lacing size")
      sizes.add(sz.int)
      total += sz
      prev = sz
      if total > (blockData.len - pos).int64:
        raise decodeError("mkv: total of laced frame sizes exceeds block")
  elif lacing == 2: # Fixed-size
    let rest = blockData.len - pos
    if rest mod nFrames != 0:
      raise decodeError("mkv: invalid block size")
    let each = rest div nFrames
    for _ in 0 ..< nFrames - 1:
      sizes.add(each)
  # Timestamps: cluster (segment ticks) -> track ticks, then relative + delay.
  let clusterTrack = segToTrack(clusterTs, st.trackScale)
  if clusterTrack > high(int64) - 32768 or
      clusterTrack < low(int64) + 32768 + st.codecDelayTicks:
    return # overflow -> skip block like the reference
  var pts = clusterTrack + rel - st.codecDelayTicks
  var base: uint64
  if blockDur.isSome:
    base = blockDur.get
  elif st.hasDefaultDur:
    base = st.defaultDurTicks * nFrames.uint64
  else:
    base = 0
  var acc = 0'u64
  for i in 0 ..< nFrames:
    var d: uint64
    if base == 0:
      d = 0
    else:
      acc += base
      d = acc div nFrames.uint64
      acc = acc mod nFrames.uint64
    var ln: int
    if i < sizes.len:
      ln = sizes[i]
    else:
      ln = blockData.len - pos
    if ln < 0 or pos + ln > blockData.len:
      raise decodeError("mkv: total of laced frame sizes exceeds block")
    var payload = newSeq[uint8](ln)
    for j in 0 ..< ln:
      payload[j] = blockData[pos + j]
    pos += ln
    # Negative PTS (codec-delay preroll) frames are emitted as-is, like
    # the reference: `checked_sub_unsigned` only fails on true overflow.
    outPackets.add(MkvPacket(trackIdx: si, pts: pts, dur: d,
      data: payload))
    pts += d.int64

proc pcmPayloadDur*(params: AudioCodecParameters; sampleRate: uint32;
    nch: int; tickNs: float64; byteLen: int): Option[uint64] =
  ## Duration of a PCM payload in track ticks. Files omit these durations;
  ## the frame count is exactly computable from payload bytes.
  var bytesPerSample = 0'u64
  case params.codec
  of CodecPcmS16Le, CodecPcmS16Be, CodecPcmU16Le, CodecPcmU16Be:
    bytesPerSample = 2
  of CodecPcmS24Le, CodecPcmS24Be, CodecPcmU24Le, CodecPcmU24Be,
      CodecPcmS32Le, CodecPcmS32Be, CodecPcmU32Le, CodecPcmU32Be,
      CodecPcmF32Le, CodecPcmF32Be:
    bytesPerSample = 4
  of CodecPcmF64Le, CodecPcmF64Be:
    bytesPerSample = 8
  of CodecPcmS8, CodecPcmU8:
    bytesPerSample = 1
  else:
    return none(uint64)
  let bytesPerFrame = bytesPerSample * nch.uint64
  if bytesPerFrame == 0:
    return none(uint64)
  let frames = byteLen.uint64 div bytesPerFrame
  if frames == 0:
    return none(uint64)
  some(nsToTrack((frames.float64 / sampleRate.float64 * 1e9).uint64,
    tickNs))

proc extractFrameSpans(base: ptr UncheckedArray[uint8]; len: int;
    blkStart, blkLen: int; states: seq[MkvTrackState];
    byNum: Table[uint32, int]; clusterTs: uint64;
    blockDur: Option[uint64]): seq[tuple[trackIdx: int, pts: int64,
    dur: uint64, start, stop: int]] =
  ## Lace-frame splitter recording absolute spans instead of copying
  ## payloads. Lace frames are contiguous inside the block, so every span
  ## decodes from a direct mapping view (no pool needed for MKV).
  var r = ViewReader(base: cast[ptr UncheckedArray[uint8]](
    cast[int](base) +% blkStart), len: blkLen, pos: 0)
  var pos = 0
  let trackVint = readVintUnsigned(toOpenArray(base, blkStart,
    blkStart + blkLen - 1), pos)
  if trackVint == 0 or trackVint > high(uint32).uint64:
    raise decodeError("mkv: invalid track number")
  let trackNum = trackVint.uint32
  if not byNum.hasKey(trackNum):
    raise decodeError("mkv: invalid track number for block")
  let si = byNum[trackNum]
  let st = states[si]
  r.pos = pos
  if r.remaining() < 3:
    raise decodeError("mkv: truncated block header")
  let rel = cast[int16](r.readU16Be()).int64
  let flags = r.readByte()
  let lacing = (flags shr 1) and 0x3
  var nFrames = 1
  if lacing != 0:
    if r.remaining() < 1:
      raise decodeError("mkv: truncated block header")
    nFrames = r.readByte().int + 1
    if nFrames > MkvMaxBlockFrames:
      raise decodeError("mkv: too many laced frames")
  pos = r.pos
  var sizes: seq[int] = @[]
  if lacing == 1: # Xiph
    var total = 0
    for _ in 0 ..< nFrames - 1:
      var v = 0
      while true:
        if pos >= blkLen:
          raise decodeError("mkv: truncated lacing sizes")
        let b = base[blkStart + pos].int
        inc pos
        v += b
        if b != 0xff:
          break
      sizes.add(v)
      total += v
      if total > blkLen - pos:
        raise decodeError("mkv: total of laced frame sizes exceeds block")
  elif lacing == 3: # EBML
    var total = 0'i64
    var prev = 0'i64
    for i in 0 ..< nFrames - 1:
      var sz: int64
      if i == 0:
        sz = readVintUnsigned(toOpenArray(base, blkStart,
          blkStart + blkLen - 1), pos).int64
      else:
        sz = prev + readVintSigned(toOpenArray(base, blkStart,
          blkStart + blkLen - 1), pos)
      if sz < 0:
        raise decodeError("mkv: invalid ebml lacing size")
      sizes.add(sz.int)
      total += sz
      prev = sz
      if total > (blkLen - pos).int64:
        raise decodeError("mkv: total of laced frame sizes exceeds block")
  elif lacing == 2: # Fixed-size
    let rest = blkLen - pos
    if rest mod nFrames != 0:
      raise decodeError("mkv: invalid block size")
    let each = rest div nFrames
    for _ in 0 ..< nFrames - 1:
      sizes.add(each)
  # Timestamps: cluster (segment ticks) -> track ticks, then relative + delay.
  let clusterTrack = segToTrack(clusterTs, st.trackScale)
  if clusterTrack > high(int64) - 32768 or
      clusterTrack < low(int64) + 32768 + st.codecDelayTicks:
    return # overflow -> skip block like the reference
  var pts = clusterTrack + rel - st.codecDelayTicks
  var baseDur: uint64
  if blockDur.isSome:
    baseDur = blockDur.get
  elif st.hasDefaultDur:
    baseDur = st.defaultDurTicks * nFrames.uint64
  else:
    baseDur = 0
  var acc = 0'u64
  for i in 0 ..< nFrames:
    var d: uint64
    if baseDur == 0:
      d = 0
    else:
      acc += baseDur
      d = acc div nFrames.uint64
      acc = acc mod nFrames.uint64
    var ln: int
    if i < sizes.len:
      ln = sizes[i]
    else:
      ln = blkLen - pos
    if ln < 0 or pos + ln > blkLen:
      raise decodeError("mkv: total of laced frame sizes exceeds block")
    # Negative PTS (codec-delay preroll) frames are emitted as-is, like
    # the reference: `checked_sub_unsigned` only fails on true overflow.
    result.add((si, pts, d, blkStart + pos, blkStart + pos + ln))
    pos += ln
    pts += d.int64

proc parseCues[R](r: var R; h: EbmlHeader; parentEnd: int;
    cues: var seq[MkvCue]) =
  let stop = elemEnd(h, parentEnd, bufLen(r))
  while true:
    let ph = r.readHeader(stop)
    if ph.isNone:
      break
    let p = ph.get
    if p.id != EidCuePoint:
      r.skipElem(p, stop)
      continue
    let pEnd = elemEnd(p, stop, bufLen(r))
    var cueTime = none(uint64)
    while true:
      let qh = r.readHeader(pEnd)
      if qh.isNone:
        break
      let q = qh.get
      case q.id
      of EidCueTime:
        cueTime = some(r.readUIntElem(q, pEnd))
      of EidCueTrackPos:
        let tEnd = elemEnd(q, pEnd, bufLen(r))
        var trackNum = 0'u64
        var hasTrack = false
        var cPos = 0'u64
        var hasPos = false
        var rel = none(uint64)
        while true:
          let th = r.readHeader(tEnd)
          if th.isNone:
            break
          let t = th.get
          case t.id
          of EidCueTrack:
            trackNum = r.readUIntElem(t, tEnd)
            hasTrack = true
          of EidCueClusterPos:
            cPos = r.readUIntElem(t, tEnd)
            hasPos = true
          of EidCueRelPos:
            rel = some(r.readUIntElem(t, tEnd))
          else:
            r.skipElem(t, tEnd)
        if cueTime.isSome and hasTrack and hasPos and trackNum != 0:
          cues.add(MkvCue(timeNs: cueTime.get, trackNum: trackNum,
            clusterPos: cPos, relPos: rel))
      else:
        r.skipElem(q, pEnd)

type
  MkvHead* = object
    ## Result of the shared segment scan: tracks, cues, and cluster
    ## ranges. All positions are absolute file offsets.
    segmentStart*: int
    tracks*: seq[Track]
    trackStates*: seq[MkvTrackState]
    trackIdxByNum*: Table[uint32, int]
    cues*: seq[MkvCue]
    segTimeBase*: TimeBase
    segScale*: uint64
    segDur*: Option[uint64]
    clusterRanges*: seq[array[2, int]]

proc scanMkvHead[R](r: var R; totalLen: int): MkvHead =
  ## EBML header + segment walk shared by both opens (tracks, cues,
  ## cluster ranges); `R` is `Reader` or `ViewReader`.
  # EBML header.
  let ebmlH = r.readHeader(-1)
  if ebmlH.isNone or ebmlH.get.id != EidEbml:
    raise decodeError("mkv: missing ebml header")
  let ebmlEnd = elemEnd(ebmlH.get, -1, totalLen)
  var docType = ""
  while true:
    let ch = r.readHeader(ebmlEnd)
    if ch.isNone:
      break
    let c = ch.get
    if c.id == EidDocType:
      docType = r.readStringElem(c, ebmlEnd)
    else:
      r.skipElem(c, ebmlEnd)
  if docType != "matroska" and docType != "webm":
    raise unsupportedError("mkv: not a matroska / webm file")
  # Segment.
  let segH = r.readHeader(-1)
  if segH.isNone or segH.get.id != EidSegment:
    raise unsupportedError("mkv: missing segment element")
  let seg = segH.get
  let segStart = seg.dataPos
  let segEnd = elemEnd(seg, -1, totalLen)
  result.segmentStart = segStart
  var scale = 1_000_000'u64
  var segDurF = none(float64)
  var rawTracks: seq[RawTrack] = @[]
  var cues: seq[MkvCue] = @[]
  var clusterRanges: seq[array[2, int]] = @[]
  r.pos = segStart
  while true:
    let ch = r.readHeader(segEnd)
    if ch.isNone:
      break
    let c = ch.get
    case c.id
    of EidInfo:
      let iEnd = elemEnd(c, segEnd, totalLen)
      while true:
        let ih = r.readHeader(iEnd)
        if ih.isNone:
          break
        let ic = ih.get
        case ic.id
        of EidTimestampScale:
          scale = r.readUIntElem(ic, iEnd)
          if scale == 0:
            raise decodeError("mkv: invalid timestamp scale")
        of EidDuration:
          segDurF = some(r.readFloatElem(ic, iEnd))
        else:
          r.skipElem(ic, iEnd)
    of EidTracks:
      let tEnd = elemEnd(c, segEnd, totalLen)
      while true:
        let th = r.readHeader(tEnd)
        if th.isNone:
          break
        let t = th.get
        if t.id == EidTrackEntry:
          rawTracks.add(parseTrackEntry(r, t, tEnd))
          r.pos = elemEnd(t, tEnd, totalLen)
        else:
          r.skipElem(t, tEnd)
    of EidCues:
      parseCues(r, c, segEnd, cues)
      r.pos = elemEnd(c, segEnd, totalLen)
    of EidCluster:
      clusterRanges.add([c.dataPos, elemEnd(c, segEnd, totalLen)])
      r.pos = elemEnd(c, segEnd, totalLen)
    else:
      # SeekHead, Tags, Attachments, Chapters, Void, CRC32: skipped.
      r.skipElem(c, segEnd)
  if rawTracks.len == 0:
    raise decodeError("mkv: missing Tracks element")
  if scale > high(uint32).uint64:
    raise unsupportedError("mkv: timestamp scale too large")
  let segTbOpt = tryNewTimeBase(scale.uint32, NsPerSec)
  if segTbOpt.isNone:
    raise decodeError("mkv: invalid timestamp scale")
  let segTimeBase = segTbOpt.get
  var segDur: Option[uint64] = none(uint64)
  if segDurF.isSome and segDurF.get == segDurF.get and segDurF.get >= 0.0:
    segDur = some(segDurF.get.round().uint64)
  # Build audio tracks.
  var tracks: seq[Track] = @[]
  var trackStates: seq[MkvTrackState] = @[]
  var trackIdxByNum = initTable[uint32, int]()
  for t in rawTracks:
    let mapped = mapAudioTrack(t)
    if mapped.isNone:
      continue
    var params = mapped.get
    var track = newTrack(t.number.uint32, params)
    var tb = segTimeBase
    var tscale = t.trackScale
    if tscale != tscale or tscale <= 0.0:
      tscale = 1.0
    if tscale != 1.0:
      let scaled = tb.scale(tscale)
      if scaled.isNone:
        raise decodeError("mkv: track timebase is invalid")
      tb = scaled.get
    track.timeBase = some(tb)
    if segDur.isSome:
      let dTicks = nsToTrack(
        (segDur.get.float64 * scale.float64).round().uint64,
        scale.float64 * tscale)
      track.duration = some(newDuration(dTicks))
    let idx = tracks.len
    tracks.add(track)
    let tickNs = scale.float64 * tscale
    trackIdxByNum[t.number.uint32] = idx
    trackStates.add(MkvTrackState(trackNum: t.number.uint32,
      trackIdx: idx, sampleRate: params.sampleRate.get,
      trackScale: tscale, tickNs: tickNs,
      codecDelayTicks: nsToTrack(t.codecDelayNs, tickNs).int64,
      defaultDurTicks: (if t.hasDefaultDur:
        nsToTrack(t.defaultDurationNs, tickNs) else: 0),
      hasDefaultDur: t.hasDefaultDur))
    # Per-track codec params already carry sampleRate/channels/extraData.
    tracks[idx].codec = params
  if tracks.len == 0:
    raise unsupportedError("mkv: no audio track found")
  MkvHead(segmentStart: segStart, tracks: tracks, trackStates: trackStates,
    trackIdxByNum: trackIdxByNum, cues: cues, segTimeBase: segTimeBase,
    segScale: scale, segDur: segDur, clusterRanges: clusterRanges)

proc openMkv*(data: seq[uint8]): MkvReader =
  if probeMkv(data) == 0:
    raise unsupportedError("mkv: missing ebml stream marker")
  var r = newReader(data)
  let h = scanMkvHead(r, data.len)
  result = MkvReader(r: r, segmentStart: h.segmentStart, tracks: h.tracks,
    trackStates: h.trackStates, trackIdxByNum: h.trackIdxByNum,
    packets: @[], posIdx: 0, cues: h.cues, segTimeBase: h.segTimeBase,
    segScale: h.segScale, segDur: h.segDur, metadata: MetadataLog())
  # Clusters -> packet index (file order, like the reference).
  result.packets = @[]
  var rr = newReader(data)
  for cr in h.clusterRanges:
    rr.pos = cr[0]
    # Walk raw cluster payload: first element should be Timestamp/blocks.
    # Reconstruct end-bounded walk.
    let cEnd = cr[1]
    var clusterTs = none(uint64)
    while rr.pos < cEnd:
      let ch = rr.readHeader(cEnd)
      if ch.isNone:
        break
      let c = ch.get
      case c.id
      of EidClusterTimestamp:
        clusterTs = some(rr.readUIntElem(c, cEnd))
      of EidSimpleBlock:
        if clusterTs.isNone:
          rr.skipElem(c, cEnd)
          continue
        let payload = rr.readBinaryElem(c, cEnd)
        extractFrames(payload, result.trackStates, result.trackIdxByNum,
          clusterTs.get, none(uint64), result.packets)
      of EidBlockGroup:
        if clusterTs.isNone:
          rr.skipElem(c, cEnd)
          continue
        let gEnd = elemEnd(c, cEnd, data.len)
        var bdata: seq[uint8] = @[]
        var hasData = false
        var dur = none(uint64)
        while true:
          let gh = rr.readHeader(gEnd)
          if gh.isNone:
            break
          let g = gh.get
          case g.id
          of EidBlock:
            bdata = rr.readBinaryElem(g, gEnd)
            hasData = true
          of EidBlockDuration:
            dur = some(rr.readUIntElem(g, gEnd))
          of EidRefBlock, EidDiscardPadding:
            discard rr.readSIntElem(g, gEnd)
          else:
            rr.skipElem(g, gEnd)
        if hasData:
          extractFrames(bdata, result.trackStates, result.trackIdxByNum,
            clusterTs.get, dur, result.packets)
      else:
        rr.skipElem(c, cEnd)
  # PCM duration synthesis: for PCM tracks the frame count is exactly
  # computable from payload bytes, so fill in durations the file omits.
  # (The reference leaves them zero; compressed packets keep zero.)
  for p in result.packets.mitems:
    if p.dur != 0:
      continue
    let ti = p.trackIdx
    let params = result.tracks[ti].codec
    if params.sampleRate.isNone or params.channels.isNone:
      continue
    let st = result.trackStates[ti]
    let d = pcmPayloadDur(params, params.sampleRate.get,
      params.channels.get.channelCount(), st.tickNs, p.data.len)
    if d.isSome:
      p.dur = d.get
  result.r.pos = h.segmentStart

proc trackCount*(w: MkvReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: MkvReader): MediaInfo =
  MediaInfo(timeBase: some(w.segTimeBase), startTs: ZeroTimestamp,
    duration: (if w.segDur.isSome: some(newDuration(w.segDur.get))
      else: none(Duration)))

proc numFrames*(w: MkvReader): Option[uint64] =
  if w.packets.len == 0:
    return some(0'u64)
  none(uint64)

proc nextPacket*(w: MkvReader): Option[Packet] =
  if w.posIdx >= w.packets.len:
    return none(Packet)
  let p = w.packets[w.posIdx]
  inc w.posIdx
  let trackId = w.trackStates[p.trackIdx].trackNum
  some(newPacket(trackId, newTimestamp(p.pts), newDuration(p.dur), p.data))

proc mkvSeekPos[P](tracks: seq[Track]; trackStates: seq[MkvTrackState];
    packets: seq[P]; cues: seq[MkvCue]; to: SeekTo): tuple[posIdx: int,
    seeked: SeekedTo] =
  ## Cue-assisted search shared by both seeks. Packet types only need
  ## trackIdx/pts/dur fields (`>=` break matches the reference).
  if tracks.len == 0:
    raise seekError(skUnseekable)
  var trackIdx = 0
  var req: Timestamp
  if to.byTime:
    if to.timeTrackId.isSome:
      let tid = to.timeTrackId.get
      var found = -1
      for i, t in tracks:
        if t.id == tid:
          found = i
          break
      if found < 0:
        raise seekError(skInvalidTrack)
      trackIdx = found
    let tb = tracks[trackIdx].timeBase
    if tb.isNone:
      raise seekError(skUnseekable)
    let ts = tb.get.calcTimestamp(to.time)
    if ts.isNone:
      raise seekError(skUnseekable)
    req = ts.get
  else:
    var found = -1
    for i, t in tracks:
      if t.id == to.tsTrackId:
        found = i
        break
    if found < 0:
      raise seekError(skInvalidTrack)
    trackIdx = found
    req = to.ts
  if req.isNegative:
    raise seekError(skOutOfRange)
  let st = trackStates[trackIdx]
  let trackNum = st.trackNum
  # Upper bound from max packet end on this track.
  var maxEnd = 0'i64
  for p in packets:
    if p.trackIdx == trackIdx:
      let e = p.pts + p.dur.int64
      if e > maxEnd:
        maxEnd = e
  if req.get > maxEnd and packets.len > 0:
    raise seekError(skOutOfRange)
  # Cue-assisted: last cue at or before target on this track.
  var startIdx = 0
  if cues.len > 0:
    let targetNs = req.get.float64 * st.tickNs
    var best = -1
    for i, cue in cues:
      if cue.trackNum == trackNum and cue.timeNs.float64 <= targetNs:
        best = i
    if best >= 0:
      let cue = cues[best]
      # Find first packet at/after cue time on this track.
      let cueTicks = nsToTrack(cue.timeNs, st.tickNs).int64
      for i, p in packets:
        if p.trackIdx == trackIdx and p.pts + p.dur.int64 >= cueTicks and
            p.pts <= req.get:
          startIdx = i
          break
  var idx = startIdx
  while idx < packets.len:
    let p = packets[idx]
    # Reference break condition (`>=`): first packet whose end reaches the
    # target. Zero-duration packets act as points (`pts >= req`).
    if p.trackIdx == trackIdx and p.pts + p.dur.int64 >= req.get:
      break
    inc idx
  if idx >= packets.len:
    # Target past last packet start but within range: clamp to last packet.
    var last = -1
    for i in countdown(packets.len - 1, 0):
      if packets[i].trackIdx == trackIdx:
        last = i
        break
    if last < 0:
      raise seekError(skOutOfRange)
    idx = last
  (idx, SeekedTo(trackId: tracks[trackIdx].id, requiredTs: req,
    actualTs: newTimestamp(packets[idx].pts)))

proc seek*(w: MkvReader; to: SeekTo): SeekedTo =
  let (posIdx, seeked) = mkvSeekPos(w.tracks, w.trackStates, w.packets,
    w.cues, to)
  w.posIdx = posIdx
  seeked

# -------------------------------------------------- mapped demuxer ---

type
  MkvSegPacket* = object
    ## One audio frame as a mapping window. Lace frames are contiguous
    ## inside their block, so every span decodes zero-copy (no pool).
    trackIdx*: int
    pts*: int64
    dur*: uint64
    start*: int
    stop*: int

  MkvMappedReader* = ref object
    ## Streaming Matroska/WebM demuxer over a memory-mapped file. The
    ## eager index stores offsets (+ cue table) only; packets are mapping
    ## windows, so no file-sized heap copy exists. Keep the reader open
    ## while any view is in use; `close` unmaps. Decode with the existing
    ## per-codec `decodePacketView` (Vorbis/FLAC/MP3/AAC/ALAC/PCM all
    ## covered); Opus stays demux-only as before.
    src*: MappedSource
    segmentStart*: int
    tracks*: seq[Track]
    trackStates*: seq[MkvTrackState]
    trackIdxByNum*: Table[uint32, int]
    packets*: seq[MkvSegPacket]
    posIdx*: int
    cues*: seq[MkvCue]
    segTimeBase*: TimeBase
    segScale*: uint64
    segDur*: Option[uint64]
    metadata*: MetadataLog

proc openMkvMapped*(path: string): MkvMappedReader =
  ## Maps `path` and runs the shared segment scan. The cluster walk
  ## records frame spans; packet windows stay zero-copy.
  let src = openMappedSource(path)
  try:
    if probeMkv(src.packetBytes(0, src.mappedLen)) == 0:
      raise unsupportedError("mkv: missing ebml stream marker")
    var vr = viewReader(src, 0, src.mappedLen)
    let h = scanMkvHead(vr, src.mappedLen)
    let (base, len) = src.mappedBase()
    var packets: seq[MkvSegPacket] = @[]
    # One file-wide cursor with absolute positions, mirroring the owning
    # walk (per-element cursors would mix relative and absolute ends).
    var cr = viewReader(src, 0, len)
    for hcr in h.clusterRanges:
      cr.pos = hcr[0]
      # Walk raw cluster payload: first element should be Timestamp/blocks.
      # Reconstruct end-bounded walk.
      let cEnd = hcr[1]
      var clusterTs = none(uint64)
      while cr.pos < cEnd:
        let ch = cr.readHeader(cEnd)
        if ch.isNone:
          break
        let c = ch.get
        case c.id
        of EidClusterTimestamp:
          clusterTs = some(cr.readUIntElem(c, cEnd))
        of EidSimpleBlock:
          if clusterTs.isNone:
            cr.pos = elemEnd(c, cEnd, len)
            continue
          # Block payload window: dataPos..elemEnd.
          let bEnd = elemEnd(c, cEnd, len)
          for f in extractFrameSpans(base, len, c.dataPos,
              bEnd - c.dataPos, h.trackStates, h.trackIdxByNum,
              clusterTs.get, none(uint64)):
            packets.add(MkvSegPacket(trackIdx: f.trackIdx, pts: f.pts,
              dur: f.dur, start: f.start, stop: f.stop))
        of EidBlockGroup:
          if clusterTs.isNone:
            cr.pos = elemEnd(c, cEnd, len)
            continue
          let gEnd = elemEnd(c, cEnd, len)
          var hasData = false
          var dur = none(uint64)
          var bStart = -1
          var bLen = 0
          while true:
            let gh = cr.readHeader(gEnd)
            if gh.isNone:
              break
            let g = gh.get
            case g.id
            of EidBlock:
              bStart = g.dataPos
              bLen = elemEnd(g, gEnd, len) - g.dataPos
              hasData = true
            of EidBlockDuration:
              dur = some(cr.readUIntElem(g, gEnd))
            of EidRefBlock, EidDiscardPadding:
              discard cr.readSIntElem(g, gEnd)
            else:
              discard
            cr.pos = elemEnd(g, gEnd, len)
          if hasData:
            for f in extractFrameSpans(base, len, bStart, bLen,
                h.trackStates, h.trackIdxByNum, clusterTs.get, dur):
              packets.add(MkvSegPacket(trackIdx: f.trackIdx, pts: f.pts,
                dur: f.dur, start: f.start, stop: f.stop))
        else:
          discard
        cr.pos = elemEnd(c, cEnd, len)
    # PCM duration synthesis from span lengths.
    for p in packets.mitems:
      if p.dur != 0:
        continue
      let params = h.tracks[p.trackIdx].codec
      if params.sampleRate.isNone or params.channels.isNone:
        continue
      let st = h.trackStates[p.trackIdx]
      let d = pcmPayloadDur(params, params.sampleRate.get,
        params.channels.get.channelCount(), st.tickNs, p.stop - p.start)
      if d.isSome:
        p.dur = d.get
    result = MkvMappedReader(src: src, segmentStart: h.segmentStart,
      tracks: h.tracks, trackStates: h.trackStates,
      trackIdxByNum: h.trackIdxByNum, packets: packets, posIdx: 0,
      cues: h.cues, segTimeBase: h.segTimeBase, segScale: h.segScale,
      segDur: h.segDur, metadata: MetadataLog())
  except AudioError:
    src.close()
    raise

proc close*(w: MkvMappedReader) =
  ## Unmaps the file. Outstanding views become invalid.
  if w != nil and w.src != nil:
    w.src.close()

proc trackCount*(w: MkvMappedReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: MkvMappedReader): MediaInfo =
  MediaInfo(timeBase: some(w.segTimeBase), startTs: ZeroTimestamp,
    duration: (if w.segDur.isSome: some(newDuration(w.segDur.get))
      else: none(Duration)))

proc numFrames*(w: MkvMappedReader): Option[uint64] =
  if w.packets.len == 0:
    return some(0'u64)
  none(uint64)

proc nextPacketView*(w: MkvMappedReader): Option[PacketView] =
  ## Next frame as a mapping window. Lace frames are contiguous, so this
  ## never copies; decode with the per-codec `decodePacketView`.
  if w.posIdx >= w.packets.len:
    return none(PacketView)
  let p = w.packets[w.posIdx]
  inc w.posIdx
  let trackId = w.trackStates[p.trackIdx].trackNum
  some(PacketView(trackId: trackId, pts: newTimestamp(p.pts),
    dts: newTimestamp(p.pts), dur: newDuration(p.dur),
    trimStart: ZeroDuration, trimEnd: ZeroDuration,
    win: byteWindow(w.src, p.start, p.stop - p.start), owner: w.src))

proc nextPacket*(w: MkvMappedReader): Option[Packet] =
  ## Owning-copy packets (same timing as `nextPacketView`, bounded copy).
  let v = w.nextPacketView()
  if v.isNone:
    return none(Packet)
  let pv = v.get
  var pkt = newPacket(pv.trackId, pv.pts, pv.dur, pv.packetSeq())
  pkt.trimStart = pv.trimStart
  pkt.trimEnd = pv.trimEnd
  some(pkt)

proc seek*(w: MkvMappedReader; to: SeekTo): SeekedTo =
  let (posIdx, seeked) = mkvSeekPos(w.tracks, w.trackStates, w.packets,
    w.cues, to)
  w.posIdx = posIdx
  seeked
