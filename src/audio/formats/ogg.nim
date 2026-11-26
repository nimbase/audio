## Ogg demuxer (`OggReader`) for Vorbis streams.
##
## Ports `symphonia-format-ogg` (page/physical/logical layers, Vorbis
## mapping): OggS pages with MPEG-2 CRC-32 verification, segment tables,
## packet assembly across pages (continued packets), serial
## demultiplexing, Vorbis ident/comment/setup handling, per-packet
## duration/discard computation, granule chaining, binary-search seek.
## Deviations: in-memory with an eager packet index (no streaming or
## seekback buffers); chained Ogg bitstreams are rejected; non-Vorbis
## serials are skipped (Opus/FLAC/Theora named if they are the only
## streams).

import std/options
import std/sequtils
import std/tables
import ./../audio
import ./../checksum
import ./../codecs
import ./../codecs/vorbis
import ./../errors
import ./../formats
import ./../formats/flac as flacfmt
import ./../io
import ./../metadata
import ./../packet
import ./../source
import ./../units

const
  OggFormatInfo* = FormatInfo(id: FormatOgg, shortName: "ogg",
    longName: "Ogg Container Format")
  OggMaxPacketLen = 16 * 1024 * 1024
  VorbisIdentSize = 30

type
  OggPage* = object
    offset*: int
    serial*: uint32
    seq*: uint32
    flags*: uint8
    granule*: uint64
    segLens*: seq[int]
    bodyStart*: int
    bodyEnd*: int

  OggPacket* = object
    trackSerial*: uint32
    start*: int
    stop*: int
    stored*: bool
    storeStart*: int
    storeStop*: int
    pts*: int64
    dur*: uint64
    trimStart*: uint64
    trimEnd*: uint64

  VorbisDurParser* = object
    bs0exp*: int
    bs1exp*: int
    numModes*: int
    blockFlags*: uint64
    prevBsExp*: int
    hasPrev*: bool

  OggStreamState = object
    serial*: uint32
    isVorbis*: bool
    unsupportedName*: string
    params*: AudioCodecParameters
    hasParams*: bool
    bs0exp*: int
    bs1exp*: int
    parser*: VorbisDurParser
    hasParser*: bool
    partBuf*: seq[uint8]
    hasPart*: bool
    lastSeq*: uint32
    hasLastSeq*: bool
    lastGranule*: uint64
    hasGranule*: bool
    seenEos*: bool
    nextPts*: int64

  OggReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    serials*: seq[uint32]
    packets*: seq[OggPacket]
    trackPackets*: Table[uint32, seq[int]]
    store*: seq[uint8]
    posIdx*: int
    metadata*: MetadataLog

proc isBos(f: uint8): bool {.inline.} = (f and 0x02'u8) != 0
proc isEos(f: uint8): bool {.inline.} = (f and 0x04'u8) != 0
proc isContinued(f: uint8): bool {.inline.} = (f and 0x01'u8) != 0

proc probeOgg*(data: openArray[uint8]): int =
  if data.len >= 4 and data[0] == 0x4f'u8 and data[1] == 0x67'u8 and
      data[2] == 0x67'u8 and data[3] == 0x53'u8: 255
  else: 0

proc parseOggPage(base: ptr UncheckedArray[uint8]; len: int;
    at: int): Option[OggPage] =
  ## Parses + CRC-verifies one page. None on any failure (caller skips).
  ## Pointer-based so the owning and mapped opens share it; the CRC copy
  ## is page-sized (bounded), not file-sized.
  if at + 27 > len:
    return none(OggPage)
  if base[at] != 0x4f'u8 or base[at + 1] != 0x67'u8 or
      base[at + 2] != 0x67'u8 or base[at + 3] != 0x53'u8:
    return none(OggPage)
  var r = ViewReader(base: cast[ptr UncheckedArray[uint8]](
    cast[int](base) +% at), len: len - at, pos: 0)
  discard r.readFourCc()
  if r.readByte() != 0:
    return none(OggPage)
  let flags = r.readByte()
  if (flags and 0xf8'u8) != 0:
    return none(OggPage)
  let granule = r.readU64Le()
  let serial = r.readU32Le()
  let seq = r.readU32Le()
  let crc = r.readU32Le()
  let nSegs = r.readByte().int
  if at + 27 + nSegs > len:
    return none(OggPage)
  let segTable = r.readBytesExact(nSegs)
  var bodyLen = 0
  var segLens: seq[int] = @[]
  for s in segTable:
    segLens.add(s.int)
    bodyLen += s.int
  if at + 27 + nSegs + bodyLen > len:
    return none(OggPage)
  var all = newSeq[uint8](27 + nSegs + bodyLen)
  copyMem(all[0].addr, base[at].addr, all.len)
  all[22] = 0
  all[23] = 0
  all[24] = 0
  all[25] = 0
  if crc32Mpeg2(all) != crc:
    return none(OggPage)
  some(OggPage(offset: at, serial: serial, seq: seq, flags: flags,
    granule: granule, segLens: segLens,
    bodyStart: at + 27 + nSegs,
    bodyEnd: at + 27 + nSegs + bodyLen))

proc splitPackets(segLens: openArray[int]): tuple[complete: seq[int],
    partial: int] =
  ## Splits segment lengths into complete packet sizes + trailing partial.
  var lens: seq[int] = @[]
  var cur = 0
  for s in segLens:
    cur += s
    if s < 255:
      lens.add(cur)
      cur = 0
  (lens, cur)

proc packetDur(p: var VorbisDurParser;
    data: openArray[uint8]): tuple[dur, drop: uint64] =
  ## Vorbis audio packet duration (port of the Ogg mapping parser).
  if data.len == 0 or (data[0] and 1) != 0:
    return (0, 0)
  var bs = newRtlBitReader(data)
  discard bs.readRtlBits(1)
  let modeBits = ilog(cast[uint32](max(p.numModes - 1, 0)))
  let modeNum =
    try: bs.readRtlBits(modeBits.int).int
    except EndOfStream: return (0, 0)
  if modeNum >= p.numModes:
    return (0, 0)
  let curExp =
    if ((p.blockFlags shr modeNum) and 1) == 1: p.bs1exp else: p.bs0exp
  let cur = 1'u64 shl curExp
  if not p.hasPrev:
    p.prevBsExp = curExp
    p.hasPrev = true
    (cur shr 1, cur shr 1)
  else:
    let prev = 1'u64 shl p.prevBsExp
    p.prevBsExp = curExp
    ((prev shr 2) + (cur shr 2), 0)

proc detectVorbis(data: openArray[uint8]): bool =
  data.len == VorbisIdentSize and data[0] == 0x01 and
    data[1] == 0x76'u8 and data[2] == 0x6f'u8 and data[3] == 0x72'u8 and
    data[4] == 0x62'u8 and data[5] == 0x69'u8 and data[6] == 0x73'u8

proc detectOpus(data: openArray[uint8]): bool =
  data.len >= 8 and data[0] == 0x4f'u8 and data[1] == 0x70'u8 and
    data[2] == 0x75'u8 and data[3] == 0x73'u8 and data[4] == 0x48'u8 and
    data[5] == 0x65'u8 and data[6] == 0x61'u8 and data[7] == 0x64'u8

proc detectFlac(data: openArray[uint8]): bool =
  data.len >= 5 and data[0] == 0x7f'u8 and data[1] == 0x46'u8 and
    data[2] == 0x4c'u8 and data[3] == 0x41'u8 and data[4] == 0x43'u8

proc detectTheora(data: openArray[uint8]): bool =
  data.len >= 7 and data[0] == 0x80'u8 and data[1] == 0x74'u8 and
    data[2] == 0x68'u8 and data[3] == 0x65'u8 and data[4] == 0x6fu8 and
    data[5] == 0x72'u8 and data[6] == 0x61'u8

proc scanOggPages(base: ptr UncheckedArray[uint8];
    len: int): seq[OggPage] =
  ## Pass 1: pages with CRC verification + resync. Shared by both opens;
  ## the index stores offsets, never bytes.
  var pages: seq[OggPage] = @[]
  var pos = 0
  var firstPage = true
  while pos + 27 <= len:
    if base[pos] != 0x4f'u8:
      inc pos
      continue
    let pg = parseOggPage(base, len, pos)
    if pg.isNone:
      inc pos
      continue
    let page = pg.get
    if firstPage and not page.flags.isBos():
      raise unsupportedError("ogg: first page is not a beginning")
    firstPage = false
    if page.flags.isBos() and page.offset != 0:
      raise unsupportedError("ogg: chained streams are not supported")
    pages.add(page)
    pos = page.bodyEnd
  if pages.len == 0:
    raise decodeError("ogg: no pages found")
  pages

proc openOgg*(data: seq[uint8]): OggReader =
  ## Opens a complete Ogg stream held in memory.
  if data.len < 27 or probeOgg(data) == 0:
    raise unsupportedError("ogg: missing ogg stream marker")
  let base =
    if data.len > 0: cast[ptr UncheckedArray[uint8]](unsafeAddr data[0])
    else: nil
  let pages = scanOggPages(base, data.len)
  # Pass 2: per-serial assembly in file order.
  result = OggReader(r: newReader(data))
  var streams = initTable[uint32, OggStreamState]()
  var order: seq[uint32] = @[]
  var metaLog = MetadataLog()
  var packetList: seq[OggPacket] = @[]
  for pg in pages:
    if not streams.hasKey(pg.serial):
      streams[pg.serial] = OggStreamState(serial: pg.serial)
      order.add(pg.serial)
    var st = streams[pg.serial]
    # Sequence gap/regression drops partial data.
    if st.hasLastSeq and pg.seq != st.lastSeq + 1:
      st.partBuf = @[]
      st.hasPart = false
    st.lastSeq = pg.seq
    st.hasLastSeq = true
    if pg.granule != high(uint64):
      st.lastGranule = pg.granule
      st.hasGranule = true
    if pg.flags.isEos():
      st.seenEos = true
    let (complete, partial) = splitPackets(pg.segLens)
    var pkts: seq[tuple[start, stop: int]] = @[]
    var off = pg.bodyStart
    for len in complete:
      if len > OggMaxPacketLen:
        raise decodeError("ogg: packet exceeds maximum size")
      pkts.add((off, off + len))
      off += len
    if not pg.flags.isContinued() and st.hasPart:
      st.partBuf = @[]
      st.hasPart = false
    if pg.flags.isContinued() and not st.hasPart:
      if pkts.len > 0:
        pkts.delete(0)
      else:
        streams[pg.serial] = st
        continue
    for (ps, pe) in pkts:
      if pe == ps:
        continue # Zero-length packets are skipped.
      # Assemble (copy only cross-page packets).
      var isStored = false
      var a = ps
      var b = pe
      var body: seq[uint8]
      if st.hasPart:
        a = result.store.len
        result.store.add(st.partBuf)
        result.store.add(data.toOpenArray(ps, pe - 1))
        b = result.store.len
        isStored = true
        st.partBuf = @[]
        st.hasPart = false
        body = result.store[a ..< b]
      else:
        body = data.toOpenArray(ps, pe - 1).toSeq()
      if not st.hasParams:
        if detectVorbis(body):
          var r = newReader(body)
          let ident = readIdentHeader(r)
          var params = forCodec(CodecVorbis)
          params.sampleRate = some(ident.sampleRate)
          params.channels = some(vorbisChannelsToChannels(ident.nChannels))
          params.extraData = body
          st.params = params
          st.hasParams = true
          st.isVorbis = true
          st.bs0exp = ident.bs0exp
          st.bs1exp = ident.bs1exp
        elif detectOpus(body):
          st.unsupportedName = "opus"
        elif detectFlac(body):
          st.unsupportedName = "flac"
        elif detectTheora(body):
          st.unsupportedName = "theora"
        continue
      if not st.isVorbis:
        continue
      let pktType = if body.len > 0: body[0] else: 0'u8
      if (pktType and 1) == 0:
        if not st.hasParser:
          continue # Audio before setup: drop.
        let (dur, drop) = st.parser.packetDur(body)
        packetList.add(OggPacket(trackSerial: pg.serial, start: a,
          stop: b, stored: isStored, storeStart: a, storeStop: b,
          pts: st.nextPts, dur: dur, trimStart: drop, trimEnd: 0))
        st.nextPts += cast[int64](dur)
      else:
        if body.len >= 7 and body[0] == 0x03 and body[1] == 0x76'u8 and
            body[2] == 0x6f'u8 and body[3] == 0x72'u8 and
            body[4] == 0x62'u8 and body[5] == 0x69'u8 and
            body[6] == 0x73'u8:
          var br = newReader(body.toOpenArray(7, body.len - 1))
          metaLog.push(flacfmt.parseVorbisComment(br, body.len - 7))
        elif body.len >= 7 and body[0] == 0x05 and body[1] == 0x76'u8 and
            body[2] == 0x6f'u8 and body[3] == 0x72'u8 and
            body[4] == 0x62'u8 and body[5] == 0x69'u8 and
            body[6] == 0x73'u8:
          st.params.extraData.add(body)
          let (numModes, flags) = skipVorbisSetupModes(body,
            st.params.channels.get.channelCount())
          st.parser = VorbisDurParser(bs0exp: st.bs0exp,
            bs1exp: st.bs1exp, numModes: numModes, blockFlags: flags,
            prevBsExp: 0, hasPrev: false)
          st.hasParser = true
        # Unknown header types ignored.
    # Partial tail.
    if partial > 0:
      if st.hasPart:
        st.partBuf.add(data.toOpenArray(off, off + partial - 1))
      else:
        st.partBuf = @(data.toOpenArray(off, off + partial - 1).toSeq())
        st.hasPart = true
    streams[pg.serial] = st
  # Truncation: partial data or missing EOS is an error.
  for serial in order:
    let st = streams[serial]
    if st.isVorbis and (st.hasPart or not st.seenEos):
      raise decodeError("ogg: truncated stream")
  # Build tracks + trim tails.
  var tracks: seq[Track] = @[]
  var serials: seq[uint32] = @[]
  for serial in order:
    let st = streams[serial]
    if not st.isVorbis or not st.hasParams:
      continue
    var params = st.params
    var track = newTrack(serial, params)
    if st.hasGranule:
      let total = st.lastGranule
      var chainedEnd = 0'u64
      for p in packetList:
        if p.trackSerial == serial:
          chainedEnd = cast[uint64](p.pts) + p.dur
      if chainedEnd > total:
        for i in countdown(packetList.len - 1, 0):
          if packetList[i].trackSerial == serial:
            let cut = min(chainedEnd - total, packetList[i].dur)
            packetList[i].dur -= cut
            packetList[i].trimEnd += cut
            break
      track.numFrames = some(total)
      track.duration = some(newDuration(total))
    tracks.add(track)
    serials.add(serial)
  if tracks.len == 0:
    for serial in order:
      if streams[serial].unsupportedName.len > 0:
        raise unsupportedError("ogg: " & streams[serial].unsupportedName &
          " not supported")
    raise decodeError("ogg: no vorbis stream")
  result.tracks = tracks
  result.serials = serials
  result.packets = packetList
  result.metadata = metaLog
  result.posIdx = 0
  var tp = initTable[uint32, seq[int]]()
  for i, p in packetList:
    tp.mgetOrPut(p.trackSerial, @[]).add(i)
  result.trackPackets = tp

proc trackCount*(w: OggReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: OggReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: OggReader): Option[uint64] = w.tracks[0].numFrames

proc packetBytes*(w: OggReader; p: OggPacket): seq[uint8] =
  if p.stored:
    w.store[p.storeStart ..< p.storeStop]
  else:
    w.r.data[p.start ..< p.stop]

proc nextPacket*(w: OggReader): Option[Packet] =
  while w.posIdx < w.packets.len:
    let p = w.packets[w.posIdx]
    inc w.posIdx
    var known = false
    for s in w.serials:
      if s == p.trackSerial:
        known = true
        break
    if not known:
      continue
    var pkt = newPacket(p.trackSerial, newTimestamp(p.pts),
      newDuration(p.dur), w.packetBytes(p))
    pkt.trimStart = newDuration(p.trimStart)
    pkt.trimEnd = newDuration(p.trimEnd)
    return some(pkt)
  none(Packet)

proc oggSeekPos[P](serials: seq[uint32]; tracks: seq[Track];
    trackPackets: Table[uint32, seq[int]]; packets: seq[P];
    to: SeekTo): tuple[posIdx: int, seeked: SeekedTo] =
  ## Serial selection + validation + containing-packet search. Shared by
  ## both seeks; packet types only need pts/dur/trim fields.
  var serial = serials[0]
  if not to.byTime:
    if to.tsTrackId != 0:
      var found = false
      for s in serials:
        if s == to.tsTrackId:
          found = true
          break
      if not found:
        raise seekError(skInvalidTrack)
      serial = to.tsTrackId
  else:
    if to.timeTrackId.isSome:
      var found = false
      for s in serials:
        if s == to.timeTrackId.get:
          found = true
          break
      if not found:
        raise seekError(skInvalidTrack)
      serial = to.timeTrackId.get
  let track =
    block:
      var t = tracks[0]
      for tr in tracks:
        if tr.id == serial:
          t = tr
          break
      t
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
  if req.isNegative:
    raise seekError(skOutOfRange)
  if track.numFrames.isSome and
      cast[uint64](req.get) > track.numFrames.get:
    raise seekError(skOutOfRange)
  let idxs = trackPackets[serial]
  var lo = 0
  var hi = idxs.len - 1
  var found = idxs[0]
  while lo <= hi:
    let mid = (lo + hi) div 2
    let p = packets[idxs[mid]]
    if p.pts <= req.get and req.get < p.pts + cast[int64](p.dur):
      found = idxs[mid]
      break
    elif p.pts > req.get:
      hi = mid - 1
    else:
      found = idxs[mid]
      lo = mid + 1
  (found, SeekedTo(trackId: serial, requiredTs: req,
    actualTs: newTimestamp(packets[found].pts)))

proc seek*(w: OggReader; to: SeekTo): SeekedTo =
  let (posIdx, seeked) = oggSeekPos(w.serials, w.tracks, w.trackPackets,
    w.packets, to)
  w.posIdx = posIdx
  w.r.pos = w.packets[posIdx].start
  seeked

# -------------------------------------------------- mapped demuxer ---

type
  OggSegPacket* = object
    ## Packet as span list: single-span packets decode straight from the
    ## mapping; multi-span (cross-page) packets assemble into the pool.
    trackSerial*: uint32
    segs*: seq[(int, int)] ## Absolute (start, stop) spans, file order.
    pts*: int64
    dur*: uint64
    trimStart*: uint64
    trimEnd*: uint64

  OggMappedState = object
    serial*: uint32
    isVorbis*: bool
    unsupportedName*: string
    params*: AudioCodecParameters
    hasParams*: bool
    bs0exp*: int
    bs1exp*: int
    parser*: VorbisDurParser
    hasParser*: bool
    partSegs*: seq[(int, int)]
    lastSeq*: uint32
    hasLastSeq*: bool
    lastGranule*: uint64
    hasGranule*: bool
    seenEos*: bool
    nextPts*: int64

  OggMappedReader* = ref object
    ## Streaming Ogg demuxer over a memory-mapped file. The eager index
    ## stores span offsets only; no file-sized heap copy exists. Packets
    ## decode from mapping views, or from the 1 MiB pool when they span
    ## pages (pool windows expire on the next multi-span packet). Keep
    ## the reader open while any view is in use; `close` unmaps.
    src*: MappedSource
    tracks*: seq[Track]
    serials*: seq[uint32]
    packets*: seq[OggSegPacket]
    trackPackets*: Table[uint32, seq[int]]
    posIdx*: int
    metadata*: MetadataLog
    host*: PooledHost


proc scanOggMapped*(src: MappedSource): tuple[tracks: seq[Track],
    serials: seq[uint32], packets: seq[OggSegPacket],
    trackPackets: Table[uint32, seq[int]], meta: MetadataLog] =
  ## Pass 2 over the mapping: per-serial assembly in file order, with
  ## span lists instead of copied bytes. Complete packets assemble
  ## transiently into reusable scratch for header probing and duration;
  ## only offsets survive into the index. Single-span audio packets decode
  ## straight from the mapping; multi-span packets assemble into the pool
  ## at emission time.
  let (base, len) = src.mappedBase()
  if len < 27 or probeOgg(src.packetBytes(0, min(len, 4096))) == 0:
    raise unsupportedError("ogg: missing ogg stream marker")
  let pages = scanOggPages(base, len)
  var streams = initTable[uint32, OggMappedState]()
  var order: seq[uint32] = @[]
  var metaLog = MetadataLog()
  var packetList: seq[OggSegPacket] = @[]
  var scratch = initStreamPool()
  for pg in pages:
    if not streams.hasKey(pg.serial):
      streams[pg.serial] = OggMappedState(serial: pg.serial)
      order.add(pg.serial)
    var st = streams[pg.serial]
    # Sequence gap/regression drops partial data.
    if st.hasLastSeq and pg.seq != st.lastSeq + 1:
      st.partSegs = @[]
    st.lastSeq = pg.seq
    st.hasLastSeq = true
    if pg.granule != high(uint64):
      st.lastGranule = pg.granule
      st.hasGranule = true
    if pg.flags.isEos():
      st.seenEos = true
    let (complete, partial) = splitPackets(pg.segLens)
    var pkts: seq[(int, int)] = @[]
    var off = pg.bodyStart
    for ln in complete:
      if ln > OggMaxPacketLen:
        raise decodeError("ogg: packet exceeds maximum size")
      pkts.add((off, off + ln))
      off += ln
    if not pg.flags.isContinued() and st.partSegs.len > 0:
      st.partSegs = @[]
    if pg.flags.isContinued() and st.partSegs.len == 0:
      if pkts.len > 0:
        pkts.delete(0)
      else:
        streams[pg.serial] = st
        continue
    for (ps, pe) in pkts:
      if pe == ps:
        continue # Zero-length packets are skipped.
      # Assemble transiently (reused scratch, freed after open).
      scratch.clear()
      for (a, b) in st.partSegs:
        scratch.appendMany(src.packetBytes(a, b - a))
      scratch.appendMany(src.packetBytes(ps, pe - ps))
      let segs = st.partSegs & @[(ps, pe)]
      if not st.hasParams:
        if detectVorbis(scratch.toOpenArray()):
          var r = newReader(scratch.toSeq())
          let ident = readIdentHeader(r)
          var params = forCodec(CodecVorbis)
          params.sampleRate = some(ident.sampleRate)
          params.channels = some(vorbisChannelsToChannels(ident.nChannels))
          params.extraData = scratch.toSeq()
          st.params = params
          st.hasParams = true
          st.isVorbis = true
          st.bs0exp = ident.bs0exp
          st.bs1exp = ident.bs1exp
        elif detectOpus(scratch.toOpenArray()):
          st.unsupportedName = "opus"
        elif detectFlac(scratch.toOpenArray()):
          st.unsupportedName = "flac"
        elif detectTheora(scratch.toOpenArray()):
          st.unsupportedName = "theora"
        st.partSegs = @[]
        streams[pg.serial] = st
        continue
      if not st.isVorbis:
        st.partSegs = @[]
        streams[pg.serial] = st
        continue
      let pktType = if scratch.len > 0: scratch[0] else: 0'u8
      if (pktType and 1) == 0:
        if not st.hasParser:
          st.partSegs = @[] # Audio before setup: drop.
          streams[pg.serial] = st
          continue
        let (dur, drop) = st.parser.packetDur(scratch.toOpenArray())
        packetList.add(OggSegPacket(trackSerial: pg.serial, segs: segs,
          pts: st.nextPts, dur: dur, trimStart: drop, trimEnd: 0))
        st.nextPts += cast[int64](dur)
      else:
        if scratch.len >= 7 and scratch[0] == 0x03 and
            scratch[1] == 0x76'u8 and scratch[2] == 0x6f'u8 and
            scratch[3] == 0x72'u8 and scratch[4] == 0x62'u8 and
            scratch[5] == 0x69'u8 and scratch[6] == 0x73'u8:
          var br = newReader(scratch.toSeq().toOpenArray(7,
            scratch.len - 1))
          metaLog.push(flacfmt.parseVorbisComment(br, scratch.len - 7))
        elif scratch.len >= 7 and scratch[0] == 0x05 and
            scratch[1] == 0x76'u8 and scratch[2] == 0x6f'u8 and
            scratch[3] == 0x72'u8 and scratch[4] == 0x62'u8 and
            scratch[5] == 0x69'u8 and scratch[6] == 0x73'u8:
          st.params.extraData.add(scratch.toSeq())
          let (numModes, flags) = skipVorbisSetupModes(
            scratch.toOpenArray(),
            st.params.channels.get.channelCount())
          st.parser = VorbisDurParser(bs0exp: st.bs0exp,
            bs1exp: st.bs1exp, numModes: numModes, blockFlags: flags,
            prevBsExp: 0, hasPrev: false)
          st.hasParser = true
        # Unknown header types ignored.
      st.partSegs = @[]
    # Partial tail: offsets only, no copy.
    if partial > 0:
      st.partSegs.add((off, off + partial))
    streams[pg.serial] = st
  # Truncation: partial data or missing EOS is an error.
  for serial in order:
    let st = streams[serial]
    if st.isVorbis and (st.partSegs.len > 0 or not st.seenEos):
      raise decodeError("ogg: truncated stream")
  # Build tracks + trim tails.
  var tracks: seq[Track] = @[]
  var serials: seq[uint32] = @[]
  for serial in order:
    let st = streams[serial]
    if not st.isVorbis or not st.hasParams:
      continue
    var params = st.params
    var track = newTrack(serial, params)
    if st.hasGranule:
      let total = st.lastGranule
      var chainedEnd = 0'u64
      for p in packetList:
        if p.trackSerial == serial:
          chainedEnd = cast[uint64](p.pts) + p.dur
      if chainedEnd > total:
        for i in countdown(packetList.len - 1, 0):
          if packetList[i].trackSerial == serial:
            let cut = min(chainedEnd - total, packetList[i].dur)
            packetList[i].dur -= cut
            packetList[i].trimEnd += cut
            break
      track.numFrames = some(total)
      track.duration = some(newDuration(total))
    tracks.add(track)
    serials.add(serial)
  if tracks.len == 0:
    for serial in order:
      if streams[serial].unsupportedName.len > 0:
        raise unsupportedError("ogg: " & streams[serial].unsupportedName &
          " not supported")
    raise decodeError("ogg: no vorbis stream")
  var tp = initTable[uint32, seq[int]]()
  for i, p in packetList:
    tp.mgetOrPut(p.trackSerial, @[]).add(i)
  (tracks, serials, packetList, tp, metaLog)

proc openOggMapped*(path: string): OggMappedReader =
  ## Maps `path` and builds the verified page index. Single-span packets
  ## decode from mapping views; cross-page packets assemble into the pool.
  let src = openMappedSource(path)
  try:
    let s = scanOggMapped(src)
    result = OggMappedReader(src: src, tracks: s.tracks,
      serials: s.serials, packets: s.packets, trackPackets: s.trackPackets,
      posIdx: 0, metadata: s.meta, host: initPooledHost())
  except AudioError:
    src.close()
    raise

proc close*(w: OggMappedReader) =
  ## Unmaps the file. Outstanding views become invalid.
  if w != nil and w.src != nil:
    w.src.close()

proc trackCount*(w: OggMappedReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: OggMappedReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: OggMappedReader): Option[uint64] = w.tracks[0].numFrames

proc nextPacketView*(w: OggMappedReader): Option[PacketView] =
  ## Next packet as a window. Single-span packets borrow the mapping;
  ## cross-page packets assemble into the pool (valid until the next
  ## multi-span packet, seek, or close). Decode with `decodePacketView`.
  while w.posIdx < w.packets.len:
    let p = w.packets[w.posIdx]
    inc w.posIdx
    var known = false
    for s in w.serials:
      if s == p.trackSerial:
        known = true
        break
    if not known:
      continue
    var win: ByteWindow
    var owner: ByteOwner
    if p.segs.len == 1:
      win = byteWindow(w.src, p.segs[0][0], p.segs[0][1] - p.segs[0][0])
      owner = w.src
    else:
      w.host.clearHost()
      for (a, b) in p.segs:
        w.host.appendHost(w.src.packetBytes(a, b - a))
      win = w.host.hostWindow()
      owner = w.host
    return some(PacketView(trackId: p.trackSerial,
      pts: newTimestamp(p.pts), dts: newTimestamp(p.pts),
      dur: newDuration(p.dur), trimStart: newDuration(p.trimStart),
      trimEnd: newDuration(p.trimEnd), win: win, owner: owner))
  none(PacketView)

proc nextPacket*(w: OggMappedReader): Option[Packet] =
  ## Owning-copy packets (same timing as `nextPacketView`, bounded copy).
  let v = w.nextPacketView()
  if v.isNone:
    return none(Packet)
  let pv = v.get
  var pkt = newPacket(pv.trackId, pv.pts, pv.dur, pv.packetSeq())
  pkt.trimStart = pv.trimStart
  pkt.trimEnd = pv.trimEnd
  some(pkt)

proc seek*(w: OggMappedReader; to: SeekTo): SeekedTo =
  let (posIdx, seeked) = oggSeekPos(w.serials, w.tracks, w.trackPackets,
    w.packets, to)
  w.posIdx = posIdx
  seeked
