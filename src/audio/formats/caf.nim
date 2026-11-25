## Core Audio Format demuxer (`CafReader`).
##
## Ports `symphonia-format-caf` chunks/demuxer: `caff` header, chunk
## walk (`desc`/`data`/`chan`/`pakt`/`kuki`/`free`, unknown skipped),
## `desc` format IDs (lpcm incl. float/endianness, ulaw, alaw, alac
## via `kuki` magic cookie), `chan` layout tags + bitmap, `pakt`
## packet tables (all four CBR/VBR cases, priming/remainder recorded),
## fixed-packet chunking (1152 frames), variable-packet emission,
## floor packet-aligned seek.
## Deviations: in-memory with an eager packet index; `info`/`strings`
## metadata chunks are skipped (as in the reference); `chan` custom
## descriptions beyond L/R/C/LFE/RL/RR are ignored; the variable-seek
## slice-relative index quirk in the reference is implemented with the
## correct absolute index; `strings` chunks are skipped.

import std/options
import std/sequtils
import ./../audio
import ./../checksum
import ./../codecs
import ./../codecs/alac
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../units

const
  CafFormatInfo* = FormatInfo(id: FormatCaf, shortName: "caf",
    longName: "Core Audio Format")
  CafMaxFramesPerPacket* = 1152

type
  CafPacket* = object
    offset*: int64
    start*: int64
    frames*: int64
    size*: int

  CafReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    packets*: seq[CafPacket]
    fixedBpp*: int
    fixedFpp*: int
    isFixed*: bool
    startPts*: int64
    dataStart*: int
    dataLen*: Option[int]
    posIdx*: int
    metadata*: MetadataLog

proc probeCaf*(data: openArray[uint8]): int =
  if data.len < 8:
    return 0
  if not (data[0] == 0x63'u8 and data[1] == 0x61'u8 and
      data[2] == 0x66'u8 and data[3] == 0x66'u8):
    return 0
  if not (data[4] == 0 and data[5] == 1):
    return 127
  255

proc readCafVarint(r: var Reader): uint64 =
  result = 0
  for _ in 0 ..< 9:
    if r.remaining() < 1:
      raise decodeError("caf: truncated variable-length integer")
    let b = r.readByte()
    result = result or (b and 0x7f).uint64
    if (b and 0x80) == 0:
      return
    result = result shl 7
  raise decodeError("caf: unterminated variable-length integer")

proc cafChannelsForCount(n: int): Channels =
  case n
  of 1:
    positioned(PosFrontLeft)
  of 2:
    ChStereo
  else:
    var mask = 0'u64
    var bit = 0
    var left = n
    # First N WAVE-order positions.
    const order = [PosFrontLeft, PosFrontRight, PosFrontCenter, PosLfe1,
      PosRearLeft, PosRearRight, PosFrontLeftCenter, PosFrontRightCenter,
      PosRearCenter, PosSideLeft, PosSideRight]
    for p in order:
      if left == 0:
        break
      mask = mask or p.uint64
      dec left
    if left > 0:
      raise unsupportedError("caf: unsupported channel count")
    positioned(cast[Position](mask))

proc cafLayoutChannels(tag, bitmap: uint32;
    descs: seq[uint32]): Option[Channels] =
  case tag
  of 0:
    var mask = 0'u64
    for label in descs:
      let pos =
        case label
        of 1:
          PosFrontLeft
        of 2:
          PosFrontRight
        of 3:
          PosFrontCenter
        of 4:
          PosLfe1
        of 5:
          PosRearLeft
        of 6:
          PosRearRight
        else:
          return none(Channels)
      mask = mask or pos.uint64
    some(positioned(cast[Position](mask)))
  of 0x10000:
    some(positioned(cast[Position](bitmap.uint64)))
  of 0x640001:
    some(ChMono)
  of 0x650002, 0x660002:
    some(ChStereo)
  of 0x710003:
    some(Ch3)
  of 0x790006:
    some(Ch51)
  of 0x7e0008:
    some(Ch71)
  of 0x880004:
    some(discrete(4))
  else:
    none(Channels)

type
  CafDesc* = object
    rate*: uint32
    codec*: AudioCodecId
    bpp*: int
    fpp*: int
    channels*: Channels
    bits*: int

proc parseCafDesc(r: var Reader): CafDesc =
  let rateF = r.readF64Be()
  if rateF != rateF or rateF <= 0.0 or rateF >= 4_294_967_295.0:
    raise decodeError("caf: sample rate must be not be zero")
  var fid: array[4, uint8]
  for i in 0 ..< 4:
    fid[i] = r.readByte()
  let flags = r.readU32Be()
  let bpp = r.readU32Be().int
  let fpp = r.readU32Be().int
  let nch = r.readU32Be().int
  let bits = r.readU32Be().int
  if nch == 0:
    raise decodeError("caf: channels per frame must be not be zero")
  let f = "" & cast[char](fid[0]) & cast[char](fid[1]) &
    cast[char](fid[2]) & cast[char](fid[3])
  var codec = CodecNull
  case f
  of "lpcm":
    let isFloat = (flags and 1) != 0
    let isLe = (flags and 2) != 0
    if isFloat:
      if bits == 32 and isLe:
        codec = CodecPcmF32Le
      elif bits == 32:
        codec = CodecPcmF32Be
      elif bits == 64 and isLe:
        codec = CodecPcmF64Le
      elif bits == 64:
        codec = CodecPcmF64Be
      else:
        raise unsupportedError("caf: unsupported bits per channel")
    else:
      if bits == 16 and isLe:
        codec = CodecPcmS16Le
      elif bits == 16:
        codec = CodecPcmS16Be
      elif bits == 24 and isLe:
        codec = CodecPcmS24Le
      elif bits == 24:
        codec = CodecPcmS24Be
      elif bits == 32 and isLe:
        codec = CodecPcmS32Le
      elif bits == 32:
        codec = CodecPcmS32Be
      else:
        raise unsupportedError("caf: unsupported bits per channel")
  of "ulaw":
    codec = CodecPcmMuLaw
  of "alaw":
    codec = CodecPcmALaw
  of "alac":
    codec = CodecAlac
  else:
    raise unsupportedError("caf: unsupported format id")
  CafDesc(rate: rateF.uint32, codec: codec, bpp: bpp, fpp: fpp,
    channels: cafChannelsForCount(nch), bits: bits)

proc openCaf*(data: seq[uint8]): CafReader =
  if data.len < 8 or not (data[0] == 0x63'u8 and data[1] == 0x61'u8 and
      data[2] == 0x66'u8 and data[3] == 0x66'u8):
    raise unsupportedError("caf: missing 'caff' stream marker")
  var r = newReader(data)
  discard r.readBytesExact(4)
  if r.readU16Be() != 1:
    raise unsupportedError("caf: unsupported file version")
  discard r.readU16Be()
  result = CafReader(r: r)
  var desc = none(CafDesc)
  var params = forCodec(CodecNull)
  var dataStart = 0
  var dataLen: Option[int] = none(int)
  var packets: seq[CafPacket] = @[]
  var numFrames: Option[uint64] = none(uint64)
  var startPts = 0'i64
  var kuki: seq[uint8] = @[]
  var haveKuki = false
  while r.pos + 12 <= data.len:
    var ctyp: array[4, uint8]
    for i in 0 ..< 4:
      ctyp[i] = r.readByte()
    let size = r.readI64Be()
    let t = "" & cast[char](ctyp[0]) & cast[char](ctyp[1]) &
      cast[char](ctyp[2]) & cast[char](ctyp[3])
    if t != "data" and size >= 0 and r.pos + size.int > data.len:
      raise decodeError("caf: chunk overruns file")
    if t == "desc":
      if desc.isSome:
        raise decodeError("caf: additional Audio Description chunk")
      if size != 32:
        raise decodeError("caf: invalid chunk size")
      let d = r.parseCafDesc()
      desc = some(d)
      params = forCodec(d.codec)
      params.sampleRate = some(d.rate)
      params.channels = some(d.channels)
      params.bitsPerSample = some(d.bits.uint32)
      if d.bpp > 0 and d.channels.channelCount() > 0:
        params.bitsPerCodedSample =
          some((d.bpp * 8 div d.channels.channelCount()).uint32)
      if d.fpp == 1:
        params.maxFramesPerPacket = some(CafMaxFramesPerPacket.uint64)
        params.framesPerBlock = some(CafMaxFramesPerPacket.uint64)
      else:
        params.maxFramesPerPacket = some(max(d.fpp, 0).uint64)
        params.framesPerBlock = some(max(d.fpp, 0).uint64)
    elif t == "data":
      if desc.isNone:
        raise decodeError("caf: missing audio description chunk")
      if size != -1 and size < 4:
        raise decodeError("caf: invalid chunk size")
      discard r.readU32Be() # edit count (ignored)
      dataStart = r.pos
      if size == -1:
        dataLen = none(int)
      else:
        dataLen = some((size - 4).int)
        r.pos = dataStart + dataLen.get
    elif t == "chan":
      if desc.isNone:
        raise decodeError("caf: missing audio description chunk")
      if size < 12:
        raise decodeError("caf: invalid chunk size")
      let stop = r.pos + size.int
      let tag = r.readU32Be()
      let bitmap = r.readU32Be()
      let n = r.readU32Be().int
      var labels: seq[uint32] = @[]
      for _ in 0 ..< n:
        if r.pos + 16 > stop:
          raise decodeError("caf: truncated channel layout")
        labels.add(r.readU32Be())
        discard r.readU32Be()
        discard r.readF32Be()
        discard r.readF32Be()
        discard r.readF32Be()
      r.pos = stop
      let ch = cafLayoutChannels(tag, bitmap, labels)
      if ch.isSome:
        params.channels = ch
    elif t == "kuki":
      if desc.isNone:
        raise decodeError("caf: missing audio description chunk")
      if size < 0:
        raise decodeError("caf: invalid chunk size")
      kuki = r.readBytes(size.int)
      haveKuki = true
    elif t == "pakt":
      if desc.isNone:
        raise decodeError("caf: missing audio description chunk")
      if size < 24:
        raise decodeError("caf: invalid chunk size")
      let stop = r.pos + size.int
      let total = r.readI64Be()
      if total < 0:
        raise decodeError(
          "caf: invalid number of packets in the packet table")
      let valid = r.readI64Be()
      if valid < 0:
        raise decodeError(
          "caf: invalid number of frames in the packet table")
      let priming = r.readI32Be()
      let remainder = r.readI32Be()
      discard remainder
      let d = desc.get
      var cur = - (if priming > 0: priming.int64 else: 0'i64)
      var pktOff = 0'i64
      if d.bpp == 0 and d.fpp == 0:
        for _ in 0 ..< total.int:
          let sz = r.readCafVarint().int
          let fr = r.readCafVarint().int64
          packets.add(CafPacket(offset: pktOff, start: cur, frames: fr,
            size: sz))
          cur += fr
          pktOff += sz.int64
      elif d.bpp == 0:
        for _ in 0 ..< total.int:
          let sz = r.readCafVarint().int
          let fr = d.fpp.int64
          packets.add(CafPacket(offset: pktOff, start: cur, frames: fr,
            size: sz))
          cur += fr
          pktOff += sz.int64
      elif d.fpp == 0:
        for _ in 0 ..< total.int:
          let fr = r.readCafVarint().int64
          packets.add(CafPacket(offset: pktOff, start: cur, frames: fr,
            size: d.bpp.int64))
          cur += fr
          pktOff += d.bpp.int64
      else:
        if total > 0:
          raise decodeError(
            "caf: unexpected packet table for constant bit rate format")
      numFrames = some(valid.uint64)
      if priming > 0 and d.bpp > 0 and d.fpp > 0:
        startPts = -priming.int64
      r.pos = stop
    elif t == "free":
      if size < 0:
        raise decodeError("caf: invalid chunk size")
      r.pos += size.int
    else:
      if size < 0:
        raise decodeError("caf: invalid chunk size")
      r.pos += size.int
    if desc.isNone:
      raise decodeError("caf: missing audio description chunk")
    if r.pos >= data.len:
      break
  if desc.isNone:
    raise decodeError("caf: missing audio description chunk")
  let d = desc.get
  if d.codec == CodecAlac:
    if haveKuki:
      try:
        let ck = readAlacCookie(kuki)
        params.bitsPerSample = some(ck.bitDepth.uint32)
      except AudioError:
        discard
      params.extraData = kuki
    else:
      raise decodeError("caf: missing ALAC magic cookie")
  elif d.codec == CodecPcmMuLaw or d.codec == CodecPcmALaw:
    discard
  if dataLen.isSome and d.bpp > 0 and d.fpp > 0:
    numFrames = some((dataLen.get.uint64 div d.bpp.uint64) *
      d.fpp.uint64)
  var track = newTrack(0, params)
  if numFrames.isSome:
    track.numFrames = numFrames
    track.duration = some(newDuration(numFrames.get))
  result.tracks = @[track]
  result.dataStart = dataStart
  result.dataLen = dataLen
  result.packets = packets
  result.isFixed = d.bpp > 0 and d.fpp > 0
  result.fixedBpp = d.bpp
  result.fixedFpp = d.fpp
  result.startPts = startPts
  result.posIdx = 0
  result.metadata = MetadataLog()
  result.r.pos = dataStart

proc trackCount*(w: CafReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: CafReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: CafReader): Option[uint64] = w.tracks[0].numFrames

proc nextPacket*(w: CafReader): Option[Packet] =
  if w.isFixed:
    let stop =
      if w.dataLen.isSome: w.dataStart + w.dataLen.get
      else: w.r.data.len
    if w.r.pos >= stop:
      return none(Packet)
    let bpp = w.fixedBpp
    let fpp = w.fixedFpp
    let maxBytes =
      if fpp == 1: bpp * CafMaxFramesPerPacket
      else: bpp
    let remain = stop - w.r.pos
    if remain <= 0:
      return none(Packet)
    let nBytes = min(maxBytes, remain)
    let dur = (nBytes div bpp) * fpp
    let pts = w.startPts + ((w.r.pos - w.dataStart) div bpp) * fpp
    let buf = w.r.readBytesExact(nBytes)
    some(newPacket(0, newTimestamp(pts.int64), newDuration(dur.uint64),
      buf))
  else:
    if w.posIdx > w.packets.len:
      raise decodeError("caf: invalid packet index")
    if w.posIdx == w.packets.len:
      return none(Packet)
    let p = w.packets[w.posIdx]
    inc w.posIdx
    if w.dataStart + p.offset.int + p.size > w.r.data.len:
      raise decodeError("caf: packet out of range")
    w.r.pos = w.dataStart + p.offset.int + p.size
    let buf = w.r.data[w.dataStart + p.offset.int ..<
      w.dataStart + p.offset.int + p.size]
    some(newPacket(0, newTimestamp(p.start), newDuration(p.frames.uint64),
      buf))

proc seek*(w: CafReader; to: SeekTo): SeekedTo =
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
  var minTs = newTimestamp(0)
  var maxTs = minTs
  if track.numFrames.isSome:
    maxTs = newTimestamp(track.numFrames.get.int64)
  if w.isFixed and w.startPts < 0:
    minTs = newTimestamp(w.startPts)
  if req.get < minTs.get:
    raise seekError(skOutOfRange)
  if track.numFrames.isSome and req.get > maxTs.get:
    raise seekError(skOutOfRange)
  if w.isFixed:
    let uncompressed = w.fixedFpp == 1
    let effFpp =
      if uncompressed: CafMaxFramesPerPacket
      else: w.fixedFpp
    if req.get < w.startPts:
      raise seekError(skOutOfRange)
    let durFrom = req.get - w.startPts
    let aligned = durFrom - (durFrom mod effFpp.int64)
    let actual = newTimestamp(w.startPts + aligned)
    let seekPos = w.dataStart + (w.fixedBpp.int64 * aligned div
      (if uncompressed: 1'i64 else: effFpp.int64)).int
    w.r.pos = seekPos
    SeekedTo(trackId: 0, requiredTs: req, actualTs: actual)
  else:
    if w.packets.len == 0:
      raise decodeError("caf: missing packet info")
    var cur = 0
    if w.posIdx < w.packets.len:
      cur = w.posIdx
    var base = 0
    var search: seq[CafPacket]
    if w.packets[cur].start < req.get:
      base = cur
      search = w.packets[cur .. ^1]
    else:
      search = w.packets[0 .. cur]
    var after = 0
    while after < search.len and search[after].start < req.get:
      inc after
    let seekIdx = base + max(after - 1, 0)
    let sp = search[max(after - 1, 0)]
    w.r.pos = w.dataStart + sp.offset.int + sp.size
    w.posIdx = seekIdx
    SeekedTo(trackId: 0, requiredTs: req, actualTs: newTimestamp(sp.start))
