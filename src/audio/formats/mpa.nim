## MP3 (MPEG-1/2/2.5 Layers 1-3) demuxer (`MpaReader`).
##
## Ports `symphonia-bundle-mp3` demuxer/header: byte-wise frame resync
## with strict next-frame similarity gate, Xing/Info (incl. LAME
## delay/padding, CRC-16-ANSI-LE checked) and VBRI duration headers,
## CBR fallback estimation, per-packet PTS/duration with gapless trims
## derived from the valid-frame window, and binary-search seek with
## bit-reservoir (`main_data_begin`) backtrack.
## Deviations: in-memory with an eager packet index; ID3v2/v1/Lyrics
## tags are skipped as junk by resync (as in the reference, which has
## no explicit ID3 parsing here).

import std/options
import ./../checksum
import ./../codecs
import ./../codecs/mpa
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../source
import ./../units

const
  MpaFormatInfo* = FormatInfo(id: FormatMp3, shortName: "mp3",
    longName: "MPEG Audio Layer 3 Native")

type
  MpaPacket* = object
    start*: int ## Byte offset of the 4-byte header.
    stop*: int  ## One past the frame end.
    pts*: int64
    dur*: uint64
    trimStart*: uint64
    trimEnd*: uint64

  MpaReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    packets*: seq[MpaPacket]
    posIdx*: int
    metadata*: MetadataLog
    firstPacketPos*: int
    delay*: int64

proc probeMpa*(data: openArray[uint8]): int =
  var off = 0
  # Skip a single leading ID3v2 tag for usability (the reference probe
  # scores frame-first data only, while `openMpa` resyncs past tags).
  if data.len >= 10 and data[0] == 0x49'u8 and data[1] == 0x44'u8 and
      data[2] == 0x33'u8 and data[3] < 0xff'u8 and data[4] < 0xff'u8 and
      (data[5] and 0x0f'u8) == 0 and (data[6] and 0x80'u8) == 0 and
      (data[7] and 0x80'u8) == 0 and (data[8] and 0x80'u8) == 0 and
      (data[9] and 0x80'u8) == 0:
    let sz = (data[6].int shl 21) or (data[7].int shl 14) or
      (data[8].int shl 7) or data[9].int
    if 10 + sz <= data.len:
      off = 10 + sz
  if data.len - off < 4:
    return 0
  let w = (data[off].uint32 shl 24) or (data[off + 1].uint32 shl 16) or
    (data[off + 2].uint32 shl 8) or data[off + 3].uint32
  if not isFrameSynced(w) or not checkHeader(w):
    return 0
  var hdr: FrameHeader
  try:
    hdr = parseFrameHeader(w)
  except AudioError:
    return 0
  if data.len - off < 4 + hdr.frameSize:
    return 127
  let w2off = off + 4 + hdr.frameSize
  if data.len - w2off < 4:
    return 127
  let w2 = (data[w2off].uint32 shl 24) or (data[w2off + 1].uint32 shl 16) or
    (data[w2off + 2].uint32 shl 8) or data[w2off + 3].uint32
  if not isFrameSynced(w2):
    return 0
  try:
    discard parseFrameHeader(w2)
  except AudioError:
    return 0
  if not hdr.isSimilar(w2):
    return 0
  255

proc syncMpaFrame*(data: openArray[uint8]; pos: var int): uint32 =
  ## Byte-wise sync; on success `pos` is past the 4-byte header.
  var sync = 0'u32
  while true:
    if pos >= data.len:
      raise newException(EndOfStream, "mpa: end of stream")
    while not isFrameSynced(sync):
      if pos >= data.len:
        raise newException(EndOfStream, "mpa: end of stream")
      sync = (sync shl 8) or data[pos].uint32
      inc pos
    if checkHeader(sync):
      return sync
    if pos >= data.len:
      raise newException(EndOfStream, "mpa: end of stream")
    sync = (sync shl 8) or data[pos].uint32
    inc pos

proc readMpaFrame*(data: openArray[uint8]; pos: var int): tuple[header: FrameHeader,
    start: int] =
  ## Strict frame read: sync + parse, then verify the next frame looks
  ## similar; on failure rewind to the second byte and retry.
  while true:
    var synced = false
    while pos < data.len:
      let sync =
        try:
          syncMpaFrame(data, pos)
        except EndOfStream:
          raise
      let frameStart = pos - MpegHeaderLen
      var hdr: FrameHeader
      try:
        hdr = parseFrameHeader(sync)
      except AudioError:
        continue
      synced = true
      let bodyEnd = pos + hdr.frameSize
      if bodyEnd > data.len:
        raise newException(EndOfStream, "mpa: truncated frame")
      if bodyEnd + 4 > data.len:
        return (hdr, frameStart)
      let w2 = (data[bodyEnd].uint32 shl 24) or
        (data[bodyEnd + 1].uint32 shl 16) or
        (data[bodyEnd + 2].uint32 shl 8) or data[bodyEnd + 3].uint32
      if not isFrameSynced(w2) or not hdr.isSimilar(w2):
        pos = frameStart + 1
        synced = false
        break
      return (hdr, frameStart)
    if not synced and pos >= data.len:
      raise newException(EndOfStream, "mpa: end of stream")

proc infoTagOffset*(header: FrameHeader): int {.inline.} =
  MpegHeaderLen + header.sideInfoLen()

proc isMaybeInfoTag*(data: openArray[uint8]; header: FrameHeader): bool =
  if header.layer != Layer3:
    return false
  let off = infoTagOffset(header)
  if data.len < off + 8:
    return false
  let isXing = data[off] == 0x58'u8 and data[off + 1] == 0x69'u8 and
    data[off + 2] == 0x6e'u8 and data[off + 3] == 0x67'u8
  let isInfo = data[off] == 0x49'u8 and data[off + 1] == 0x6eu8 and
    data[off + 2] == 0x66'u8 and data[off + 3] == 0x6f'u8
  if not (isXing or isInfo):
    return false
  for i in header.headerSize() ..< off:
    if data[i] != 0:
      return false
  true

proc readBeU24*(data: openArray[uint8]; at: int): uint32 {.inline.} =
  (data[at].uint32 shl 16) or (data[at + 1].uint32 shl 8) or
    data[at + 2].uint32

proc tryReadInfoTag*(data: openArray[uint8]; header: FrameHeader): tuple[ok: bool,
    numFrames: uint32, delay, padding: int] =
  ## Parses a Xing/Info (+LAME) tag; (false,_,_,_) when absent/invalid.
  result = (false, 0, 0, 0)
  if not isMaybeInfoTag(data, header):
    return
  let off = infoTagOffset(header)
  var crc = crc16AnsiLe(data.toOpenArray(0, off - 1))
  var p = off + 4
  try:
    proc takeU32(data: openArray[uint8]; p: var int;
        crc: var uint16): uint32 =
      if p + 4 > data.len:
        raise newException(EndOfStream, "short tag")
      let v = (data[p].uint32 shl 24) or (data[p + 1].uint32 shl 16) or
        (data[p + 2].uint32 shl 8) or data[p + 3].uint32
      crc = crc16AnsiLe(data.toOpenArray(p, p + 3), crc)
      p += 4
      v
    proc takeBytes(data: openArray[uint8]; p: var int; n: int;
        crc: var uint16): bool =
      if p + n > data.len:
        return false
      crc = crc16AnsiLe(data.toOpenArray(p, p + n - 1), crc)
      p += n
      true
    let flags = takeU32(data, p, crc)
    var numFrames = 0'u32
    if (flags and 1) != 0:
      numFrames = takeU32(data, p, crc)
    if (flags and 2) != 0:
      discard takeU32(data, p, crc)
    if (flags and 4) != 0:
      if not takeBytes(data, p, 100, crc):
        return
    if (flags and 8) != 0:
      discard takeU32(data, p, crc)
    if data.len - p < 24:
      return (true, numFrames, 0, 0)
    let enc0 = data[p]
    let enc1 = data[p + 1]
    let enc2 = data[p + 2]
    let enc3 = data[p + 3]
    if not takeBytes(data, p, 9, crc):
      return (true, numFrames, 0, 0)
    if not takeBytes(data, p, 2, crc):
      return (true, numFrames, 0, 0)
    if not takeBytes(data, p, 4, crc):
      return (true, numFrames, 0, 0)
    if not takeBytes(data, p, 2, crc):
      return (true, numFrames, 0, 0)
    if not takeBytes(data, p, 2, crc):
      return (true, numFrames, 0, 0)
    if not takeBytes(data, p, 2, crc):
      return (true, numFrames, 0, 0)
    if data.len - p < 3:
      return (true, numFrames, 0, 0)
    let trim = readBeU24(data, p)
    crc = crc16AnsiLe(data.toOpenArray(p, p + 2), crc)
    p += 3
    let isLame = (enc0 == 0x4c'u8 and enc1 == 0x41'u8 and
      enc2 == 0x4d'u8 and enc3 == 0x45'u8) or
      (enc0 == 0x4c'u8 and enc1 == 0x61'u8 and enc2 == 0x76'u8 and
      (enc3 == 0x66'u8 or enc3 == 0x63'u8))
    var delay = 0
    var padding = 0
    if isLame:
      delay = 529 + (trim shr 12).int
      padding = (trim and 0xfff).int - 529
      if padding < 0:
        padding = 0
    var tagCrc: uint16 = 0
    var hasCrc = false
    if data.len - p >= 12:
      if not takeBytes(data, p, 2 + 2 + 2 + 4 + 2, crc):
        return (true, numFrames, delay, padding)
      if header.hasCrc or (enc0 == 0x4c'u8 and enc1 == 0x41'u8 and
          enc2 == 0x4d'u8 and enc3 == 0x45'u8):
        if data.len - p < 2:
          return (true, numFrames, delay, padding)
        tagCrc = (data[p].uint16 shl 8) or data[p + 1].uint16
        hasCrc = true
    if hasCrc and tagCrc != 0 and tagCrc != crc:
      return (false, 0, 0, 0)
    return (true, numFrames, delay, padding)
  except EndOfStream:
    return (false, 0, 0, 0)

proc vbriTagOffset*(): int {.inline.} = MpegHeaderLen + 32

proc isMaybeVbriTag*(data: openArray[uint8]; header: FrameHeader): bool =
  if header.layer != Layer3:
    return false
  let off = vbriTagOffset()
  if data.len < off + 26:
    return false
  if not (data[off] == 0x56'u8 and data[off + 1] == 0x42'u8 and
      data[off + 2] == 0x52'u8 and data[off + 3] == 0x49'u8):
    return false
  for i in header.headerSize() ..< off:
    if data[i] != 0:
      return false
  true

proc tryReadVbriTag*(data: openArray[uint8];
    header: FrameHeader): tuple[ok: bool, numFrames: uint32] =
  result = (false, 0)
  if not isMaybeVbriTag(data, header):
    return
  try:
    var r = newReader(data.toOpenArray(vbriTagOffset(), data.len - 1))
    if r.readBytesExact(4) != @[0x56'u8, 0x42, 0x52, 0x49]:
      return
    if r.readU16Be() != 1:
      return
    discard r.readU16Be()
    discard r.readU16Be()
    discard r.readU32Be()
    let n = r.readU32Be()
    return (true, n)
  except AudioError:
    return (false, 0)

proc estimateNumFrames*(data: openArray[uint8]; start: int): Option[uint64] =
  ## CBR average over up to 16 frames / 16 KiB.
  var pos = start
  var totalLen = 0
  var totalFrames = 0
  while totalFrames <= 16 and totalLen <= 16 * 1024:
    if pos + 4 > data.len:
      break
    let w = (data[pos].uint32 shl 24) or (data[pos + 1].uint32 shl 16) or
      (data[pos + 2].uint32 shl 8) or data[pos + 3].uint32
    var hdr: FrameHeader
    try:
      hdr = parseFrameHeader(w)
    except AudioError:
      break
    totalLen += MpegHeaderLen + hdr.frameSize
    totalFrames += 1
    pos += MpegHeaderLen + hdr.frameSize
  if totalFrames == 0:
    return none(uint64)
  let avg = totalLen.float64 / totalFrames.float64
  some(uint64((data.len - start).float64 / avg))

type
  MpaScan* = object
    ## Result of the shared resync scan: track plus the eager packet
    ## index. All offsets are absolute file positions.
    track*: Track
    packets*: seq[MpaPacket]
    firstPacketPos*: int
    delay*: int64

proc scanMpa*(data: openArray[uint8]): MpaScan =
  ## Full resync scan. Shared by the owning and mapped opens; slicing an
  ## `openArray` borrows, so the mapped path copies nothing here.
  var pos = 0
  let (header, firstStart) =
    try:
      readMpaFrame(data, pos)
    except EndOfStream:
      raise decodeError("mpa: no frames found")
  var params = forCodec(codecOfLayer(header.layer))
  params.sampleRate = some(header.sampleRate)
  params.channels = some(header.channelMode.channelsOf())
  var track = newTrack(0, params)
  var numFrames: Option[uint64] = none(uint64)
  var delay = 0
  let firstBody = data[firstStart .. firstStart + 3 + header.frameSize]
  let info = tryReadInfoTag(firstBody, header)
  if info.ok:
    delay = info.delay
    if info.numFrames != 0:
      let total = info.numFrames.uint64 * header.numFrames().uint64
      let drop = (info.delay + info.padding).uint64
      numFrames =
        if total > drop: some(total - drop)
        else: some(0'u64)
    pos = firstStart + MpegHeaderLen + header.frameSize
  else:
    let vbri = tryReadVbriTag(firstBody, header)
    if vbri.ok:
      numFrames = some(vbri.numFrames.uint64 * header.numFrames().uint64)
      pos = firstStart + MpegHeaderLen + header.frameSize
    else:
      pos = firstStart
      let est = estimateNumFrames(data, pos)
      if est.isSome:
        numFrames = some(est.get * header.numFrames().uint64)
  if numFrames.isSome:
    track.numFrames = numFrames
    track.duration = some(newDuration(numFrames.get))
  var packetList: seq[MpaPacket] = @[]
  var nextTs = -delay.int64
  let validEnd =
    if numFrames.isSome: some(numFrames.get.int64)
    else: none(int64)
  while true:
    var hdr: FrameHeader
    var start = 0
    try:
      let fr = readMpaFrame(data, pos)
      hdr = fr.header
      start = fr.start
    except EndOfStream:
      break
    let stop = start + MpegHeaderLen + hdr.frameSize
    let fbody = data[start ..< stop]
    if isMaybeInfoTag(fbody, hdr):
      if tryReadInfoTag(fbody, hdr).ok:
        pos = stop
        continue
    elif isMaybeVbriTag(fbody, hdr):
      if tryReadVbriTag(fbody, hdr).ok:
        pos = stop
        continue
    var dur = hdr.numFrames().uint64
    var trimStart = 0'u64
    var trimEnd = 0'u64
    if nextTs < 0:
      trimStart = min(uint64(-nextTs), dur)
    if validEnd.isSome:
      let over = (nextTs + dur.int64) - validEnd.get
      if over > 0:
        trimEnd = min(uint64(over), dur - trimStart)
    dur -= trimStart + trimEnd
    packetList.add(MpaPacket(start: start, stop: stop, pts: nextTs,
      dur: dur, trimStart: trimStart, trimEnd: trimEnd))
    nextTs += int64(dur + trimStart + trimEnd)
    pos = stop
  if packetList.len == 0:
    raise decodeError("mpa: no audio frames found")
  MpaScan(track: track, packets: packetList, firstPacketPos: firstStart,
    delay: delay.int64)

proc openMpa*(data: seq[uint8]): MpaReader =
  if data.len < 4 or probeMpa(data) == 0:
    raise unsupportedError("mpa: missing mpeg frame sync")
  let s = scanMpa(data)
  result = MpaReader(r: newReader(data), tracks: @[s.track],
    packets: s.packets, posIdx: 0, metadata: MetadataLog(),
    firstPacketPos: s.firstPacketPos, delay: s.delay)

proc trackCount*(w: MpaReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: MpaReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: MpaReader): Option[uint64] = w.tracks[0].numFrames

proc packetBytes*(w: MpaReader; p: MpaPacket): seq[uint8] =
  w.r.data[p.start ..< p.stop]

proc nextPacket*(w: MpaReader): Option[Packet] =
  if w.posIdx >= w.packets.len:
    return none(Packet)
  let p = w.packets[w.posIdx]
  inc w.posIdx
  var pkt = newPacket(0, newTimestamp(p.pts), newDuration(p.dur),
    w.packetBytes(p))
  pkt.trimStart = newDuration(p.trimStart)
  pkt.trimEnd = newDuration(p.trimEnd)
  some(pkt)

proc mainDataBeginAt*(data: openArray[uint8]; start: int;
    header: FrameHeader): int =
  ## Side-info main_data_begin for seek backtrack (Layer 3 layout; for
  ## Layers 1/2 the value is meaningless but harmless, as in Symphonia).
  var p = start + MpegHeaderLen
  if header.hasCrc:
    p += 2
  if p + 2 > data.len:
    return 0
  if header.isMpeg1():
    ((data[p].int shl 8) or data[p + 1].int) shr 7
  else:
    data[p].int

proc mpaSeekFound*(packets: seq[MpaPacket]; track: Track; delay: int64;
    to: SeekTo): tuple[req: Timestamp, found: int] =
  ## Request validation + binary search over the packet index. Shared by
  ## both seeks; data access (header re-parse, reservoir backtrack) stays
  ## per-reader below.
  if to.byTime and to.timeTrackId.isSome and to.timeTrackId.get != 0:
    raise seekError(skInvalidTrack)
  if not to.byTime and to.tsTrackId != 0:
    raise seekError(skInvalidTrack)
  var req: Timestamp
  if to.byTime:
    if track.timeBase.isNone:
      raise seekError(skUnseekable)
    let ts = track.timeBase.get.calcTimestamp(to.time)
    if ts.isNone:
      raise seekError(skUnseekable)
    req = ts.get
  else:
    req = to.ts
  let minTs = newTimestamp(-delay)
  var maxTs = minTs
  if track.numFrames.isSome:
    maxTs = newTimestamp(minTs.get + track.numFrames.get.int64)
  if req.get < minTs.get:
    raise seekError(skOutOfRange)
  if track.numFrames.isSome and req.get > maxTs.get:
    raise seekError(skOutOfRange)
  var lo = 0
  var hi = packets.len - 1
  var found = 0
  while lo <= hi:
    let mid = (lo + hi) div 2
    let p = packets[mid]
    let spanEnd = p.pts + int64(p.dur + p.trimStart + p.trimEnd)
    if p.pts <= req.get and req.get < spanEnd:
      found = mid
      break
    elif p.pts > req.get:
      hi = mid - 1
    else:
      found = mid
      lo = mid + 1
  (req, found)

proc mpaSeekBacktrack*(packets: seq[MpaPacket]; found: int; start,
    mdb: int): int =
  ## Reservoir backtrack: at most 4 packets back covering `mdb` bytes.
  result = found
  if mdb > 0:
    var need = mdb
    var k = found
    var steps = 0
    while k > 0 and steps < 4:
      let prev = packets[k - 1]
      let cover = start - prev.start
      if cover >= need:
        result = k - 1
        break
      result = k - 1
      need -= cover
      dec k
      inc steps

proc seek*(w: MpaReader; to: SeekTo): SeekedTo =
  let (req, found) = mpaSeekFound(w.packets, w.tracks[0], w.delay, to)
  let tp = w.packets[found]
  var hdr: FrameHeader
  try:
    var r = newReader(w.r.data.toOpenArray(tp.start, tp.stop - 1))
    hdr = parseFrameHeader(r.readU32Be())
  except AudioError:
    raise decodeError("mpa: invalid frame at seek target")
  let mdb = mainDataBeginAt(w.r.data, tp.start, hdr)
  let target = mpaSeekBacktrack(w.packets, found, tp.start, mdb)
  w.posIdx = target
  w.r.pos = w.packets[target].start
  SeekedTo(trackId: 0, requiredTs: req,
    actualTs: newTimestamp(w.packets[target].pts))

# -------------------------------------------------- mapped demuxer ---

type
  MpaMappedReader* = ref object
    ## Streaming MP3 demuxer over a memory-mapped file. The eager packet
    ## index stores offsets only; packets are windows into the mapping
    ## (`PacketView`), so no file-sized heap copy exists. Keep the reader
    ## open while any view is in use; `close` unmaps.
    src*: MappedSource
    tracks*: seq[Track]
    packets*: seq[MpaPacket]
    posIdx*: int
    metadata*: MetadataLog
    firstPacketPos*: int
    delay*: int64

proc openMpaMapped*(path: string): MpaMappedReader =
  ## Maps `path` and runs the shared resync scan. Packet windows stay
  ## zero-copy (the scan slices views, never copies).
  let src = openMappedSource(path)
  try:
    if src.mappedLen < 4 or
        probeMpa(src.packetBytes(0, src.mappedLen)) == 0:
      raise unsupportedError("mpa: missing mpeg frame sync")
    let s = scanMpa(src.packetBytes(0, src.mappedLen))
    result = MpaMappedReader(src: src, tracks: @[s.track],
      packets: s.packets, posIdx: 0, metadata: MetadataLog(),
      firstPacketPos: s.firstPacketPos, delay: s.delay)
  except AudioError:
    src.close()
    raise

proc close*(w: MpaMappedReader) =
  ## Unmaps the file. Outstanding views become invalid.
  if w != nil and w.src != nil:
    w.src.close()

proc trackCount*(w: MpaMappedReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: MpaMappedReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: MpaMappedReader): Option[uint64] = w.tracks[0].numFrames

proc nextPacketView*(w: MpaMappedReader): Option[PacketView] =
  ## Next frame as a mapping window. No bytes are copied; decode with
  ## `decodePacketView` (MPA) or `packetSeq` for compat.
  if w.posIdx >= w.packets.len:
    return none(PacketView)
  let p = w.packets[w.posIdx]
  inc w.posIdx
  some(PacketView(trackId: 0, pts: newTimestamp(p.pts),
    dts: newTimestamp(p.pts), dur: newDuration(p.dur),
    trimStart: newDuration(p.trimStart), trimEnd: newDuration(p.trimEnd),
    src: w.src, off: p.start, len: p.stop - p.start))

proc nextPacket*(w: MpaMappedReader): Option[Packet] =
  ## Owning-copy packets (same timing as `nextPacketView`, bounded copy).
  let v = w.nextPacketView()
  if v.isNone:
    return none(Packet)
  let pv = v.get
  var pkt = newPacket(pv.trackId, pv.pts, pv.dur, pv.packetSeq())
  pkt.trimStart = pv.trimStart
  pkt.trimEnd = pv.trimEnd
  some(pkt)

proc seek*(w: MpaMappedReader; to: SeekTo): SeekedTo =
  let (req, found) = mpaSeekFound(w.packets, w.tracks[0], w.delay, to)
  let tp = w.packets[found]
  var hdr: FrameHeader
  try:
    # Header + side-info prefix only (main_data_begin lives at +4..+7).
    let winLen = min(8, tp.stop - tp.start)
    if winLen < 4:
      raise decodeError("mpa: invalid frame at seek target")
    var vr = viewReader(w.src, tp.start, winLen)
    hdr = parseFrameHeader(vr.readU32Be())
  except AudioError:
    raise decodeError("mpa: invalid frame at seek target")
  let mdb = mainDataBeginAt(w.src.packetBytes(tp.start,
    min(8, tp.stop - tp.start)), 0, hdr)
  let target = mpaSeekBacktrack(w.packets, found, tp.start, mdb)
  w.posIdx = target
  SeekedTo(trackId: 0, requiredTs: req,
    actualTs: newTimestamp(w.packets[target].pts))
