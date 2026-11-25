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

proc parseOggPage(data: seq[uint8]; at: int): Option[OggPage] =
  ## Parses + CRC-verifies one page. None on any failure (caller skips).
  if at + 27 > data.len:
    return none(OggPage)
  if data[at] != 0x4f'u8 or data[at + 1] != 0x67'u8 or
      data[at + 2] != 0x67'u8 or data[at + 3] != 0x53'u8:
    return none(OggPage)
  var r = newReader(data.toOpenArray(at, data.len - 1))
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
  if at + 27 + nSegs > data.len:
    return none(OggPage)
  let segTable = r.readBytesExact(nSegs)
  var bodyLen = 0
  var segLens: seq[int] = @[]
  for s in segTable:
    segLens.add(s.int)
    bodyLen += s.int
  if at + 27 + nSegs + bodyLen > data.len:
    return none(OggPage)
  var all = newSeq[uint8](27 + nSegs + bodyLen)
  for i in 0 ..< 27 + nSegs + bodyLen:
    all[i] = data[at + i]
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

proc openOgg*(data: seq[uint8]): OggReader =
  ## Opens a complete Ogg stream held in memory.
  if data.len < 27 or probeOgg(data) == 0:
    raise unsupportedError("ogg: missing ogg stream marker")
  # Pass 1: pages with CRC verification + resync.
  var pages: seq[OggPage] = @[]
  var pos = 0
  var firstPage = true
  while pos + 27 <= data.len:
    if data[pos] != 0x4f'u8:
      inc pos
      continue
    let pg = parseOggPage(data, pos)
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

proc seek*(w: OggReader; to: SeekTo): SeekedTo =
  var serial = w.serials[0]
  if not to.byTime:
    if to.tsTrackId != 0:
      var found = false
      for s in w.serials:
        if s == to.tsTrackId:
          found = true
          break
      if not found:
        raise seekError(skInvalidTrack)
      serial = to.tsTrackId
  else:
    if to.timeTrackId.isSome:
      var found = false
      for s in w.serials:
        if s == to.timeTrackId.get:
          found = true
          break
      if not found:
        raise seekError(skInvalidTrack)
      serial = to.timeTrackId.get
  let track =
    block:
      var t = w.tracks[0]
      for tr in w.tracks:
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
  # Binary search this track's packets for the containing packet.
  let idxs = w.trackPackets[serial]
  var lo = 0
  var hi = idxs.len - 1
  var found = idxs[0]
  while lo <= hi:
    let mid = (lo + hi) div 2
    let p = w.packets[idxs[mid]]
    if p.pts <= req.get and req.get < p.pts + cast[int64](p.dur):
      found = idxs[mid]
      break
    elif p.pts > req.get:
      hi = mid - 1
    else:
      found = idxs[mid]
      lo = mid + 1
  w.posIdx = found
  w.r.pos = w.packets[found].start
  SeekedTo(trackId: serial, requiredTs: req,
    actualTs: newTimestamp(w.packets[found].pts))
