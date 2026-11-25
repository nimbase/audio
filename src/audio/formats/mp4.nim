## ISO Base Media File Format demuxer (`Mp4Reader`), AAC audio only.
##
## Ports `symphonia-format-isomp4` demuxer/stream/atoms for the AAC-in-MP4
## subset: top-level scan (ftyp/moov required, mdat break), box walk with
## 32-deep nesting cap, mvhd/tkhd/mdhd/hdlr, edit lists (parsed, not
## applied), stbl sample tables (stsd/stts/stsc/stsz/stco|co64; ctts/stss
## skipped), esds descriptor chain (OTI + AudioSpecificConfig) with
## `mp4a` sample entries, timescale timing, eager packet index with
## timestamp interleave, floor binary-search seek.
## Deviations: in-memory with an eager packet index; fragmented streams
## (`mvex`/moof) are rejected as unsupported; edit lists are parsed but
## not applied (as in the reference, which ignores them for duration);
## only AAC audio tracks are exposed (video/MP3-in-MP4 tracks skipped);
## metadata (`udta`/`meta`/`ilst`) is skipped; `wave`-nested esds is not
## searched (ffmpeg writes plain `esds`).

import std/algorithm
import std/options
import ./../audio
import ./../codecs
import ./../codecs/aac
import ./../codecs/alac
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../units

const
  Mp4FormatInfo* = FormatInfo(id: FormatIsoMp4, shortName: "mp4",
    longName: "ISO Base Media File Format")
  MaxBoxDepth* = 32

type
  Mp4Box* = object
    typ*: array[4, uint8]
    pos*: int
    dataPos*: int
    stop*: int ## One past the box end; -1 when size extends to EOF.

  Mp4Sample* = object
    pos*: int
    size*: int
    ts*: int64
    dur*: uint64

  Mp4TrackData* = object
    track*: Track
    timescale*: uint32
    sampleRate*: uint32
    samples*: seq[Mp4Sample]

  Mp4Packet* = object
    trackIdx*: int
    sampleIdx*: int
    pts*: int64
    dur*: uint64

  Mp4Reader* = ref object
    r*: Reader
    movieRate*: uint32
    movieDur*: uint64
    tracks*: seq[Track]
    data*: seq[Mp4TrackData]
    packets*: seq[Mp4Packet]
    posIdx*: int
    metadata*: MetadataLog

proc boxName*(b: Mp4Box): string =
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = cast[char](b.typ[i])

proc `==`*(a: Mp4Box; name: string): bool {.inline.} =
  name.len == 4 and a.typ[0] == name[0].uint8 and
    a.typ[1] == name[1].uint8 and a.typ[2] == name[2].uint8 and
    a.typ[3] == name[3].uint8

proc readBoxHeader(r: var Reader; stop: int): Mp4Box =
  ## Reads `size + fourcc` (+ largesize) at the cursor.
  let pos = r.pos
  if r.remaining() < 8:
    raise newException(EndOfStream, "mp4: end of stream")
  let size32 = r.readU32Be().int
  var typ: array[4, uint8]
  for i in 0 ..< 4:
    typ[i] = r.readByte()
  var hdrLen = 8
  var stopPos = -1
  if size32 == 0:
    # Extends to the end of the parent (or file at top level).
    stopPos = stop
  elif size32 == 1:
    if r.remaining() < 8:
      raise newException(EndOfStream, "mp4: end of stream")
    let big = r.readU64Be()
    if big < 16:
      raise decodeError("mp4: invalid atom size")
    hdrLen = 16
    stopPos = pos + big.int
  else:
    if size32 < 8:
      raise decodeError("mp4: invalid atom size")
    stopPos = pos + size32
  if stop >= 0 and stopPos > stop:
    raise decodeError("mp4: atom overruns parent")
  Mp4Box(typ: typ, pos: pos, dataPos: pos + hdrLen, stop: stopPos)

proc probeMp4*(data: openArray[uint8]): int =
  if data.len < 8:
    return 0
  if not (data[4] == 0x66'u8 and data[5] == 0x74'u8 and
      data[6] == 0x79'u8 and data[7] == 0x70'u8):
    return 0
  let size = (data[0].int shl 24) or (data[1].int shl 16) or
    (data[2].int shl 8) or data[3].int
  if size < 8 or (size != 1 and size > data.len):
    return 127
  255

proc skipBox(r: var Reader; b: Mp4Box) =
  if b.stop < 0:
    r.pos = r.data.len
  else:
    if r.pos > b.stop:
      raise decodeError("mp4: atom overrun")
    r.pos = b.stop

proc readExtended(r: var Reader): tuple[version: int, flags: int] =
  let v = r.readByte().int
  let f = (r.readByte().int shl 16) or (r.readByte().int shl 8) or r.readByte().int
  (v, f)

proc parseElst(r: var Reader; stop: int) =
  ## Parses (and ignores) an edit list.
  let (ver, _) = r.readExtended()
  if ver > 1:
    raise decodeError("mp4: invalid elst version")
  let n = r.readU32Be().int
  if ver == 0:
    for _ in 0 ..< n:
      discard r.readU32Be()
      discard r.readU32Be()
      discard r.readU16Be()
      discard r.readU16Be()
  else:
    for _ in 0 ..< n:
      discard r.readU64Be()
      discard r.readU64Be()
      discard r.readU16Be()
      discard r.readU16Be()

proc readDescriptorHeader(r: var Reader): tuple[tag: int, size: int] =
  let tag = r.readByte().int
  if tag == 0x00 or tag == 0xff:
    raise decodeError("mp4: forbidden object descriptor tag")
  var size = 0
  for _ in 0 ..< 4:
    let b = r.readByte().int
    size = (size shl 7) or (b and 0x7f)
    if (b and 0x80) == 0:
      break
  (tag, size)

proc parseEsdsPayload(data: seq[uint8]): tuple[oti: int,
    extra: seq[uint8]] =
  ## Parses an esds payload; returns OTI + DecoderSpecificInfo bytes.
  var r = newReader(data)
  let (esTag, esLen) = r.readDescriptorHeader()
  if esTag != 0x03:
    raise decodeError("mp4: missing es descriptor in esds")
  let esEnd = r.pos + esLen
  if r.remaining() < 3 or esEnd > data.len:
    raise decodeError("mp4: truncated es descriptor")
  discard r.readU16Be()
  let flags = r.readByte().int
  if (flags and 0x80) != 0:
    discard r.readU16Be()
  if (flags and 0x40) != 0:
    let n = r.readByte().int
    r.ignoreBytes(n)
  if (flags and 0x20) != 0:
    discard r.readU16Be()
  var oti = -1
  var extra: seq[uint8] = @[]
  while r.pos + 2 <= esEnd:
    let (tag, len) = r.readDescriptorHeader()
    if r.pos + len > esEnd:
      raise decodeError("mp4: truncated esds descriptor")
    if tag == 0x04:
      let dcEnd = r.pos + len
      oti = r.readByte().int
      let st = r.readByte().int
      if (st and 1) != 1:
        discard 0 # reserved bit debug-only in reference
      discard r.readU24Be()
      discard r.readU32Be()
      discard r.readU32Be()
      while r.pos + 2 <= dcEnd:
        let (t2, l2) = r.readDescriptorHeader()
        if r.pos + l2 > dcEnd:
          raise decodeError("mp4: truncated decoder config")
        if t2 == 0x05:
          extra = r.readBytes(l2)
        else:
          r.ignoreBytes(l2)
      r.pos = dcEnd
    elif tag == 0x06:
      if len < 1:
        raise decodeError("mp4: truncated sl config")
      let pre = r.readByte().int
      if pre != 0 and pre != 1 and pre != 2:
        raise unsupportedError("mp4: invalid sl config descriptor")
      if len > 1:
        r.ignoreBytes(len - 1)
    else:
      r.ignoreBytes(len)
  if oti < 0:
    raise decodeError("mp4: missing decoder config descriptor")
  (oti, extra)

proc parseMp4aEntry(r: var Reader; stop: int): tuple[rate: uint32,
    nch: int, extra: seq[uint8], oti: int] =
  ## Parses an `mp4a` sample entry (v0/v1/v2) + nested `esds`.
  if r.pos + 8 > stop:
    raise decodeError("mp4: truncated mp4a entry")
  r.ignoreBytes(6)
  discard r.readU16Be()
  let ver = r.readU16Be().int
  r.ignoreBytes(6)
  let nch = r.readU16Be().int
  let bps = r.readU16Be()
  discard bps
  r.ignoreBytes(4)
  let rateRaw = r.readU32Be()
  var rate = (rateRaw shr 16) + (if (rateRaw and 0xffff) >= 0x8000: 1'u32 else: 0'u32)
  if ver == 1:
    if r.pos + 16 > stop:
      raise decodeError("mp4: truncated mp4a entry")
    discard r.readU32Be()
    discard r.readU32Be()
    discard r.readU32Be()
    discard r.readU32Be()
  elif ver == 2:
    if r.pos + 28 > stop:
      raise decodeError("mp4: truncated mp4a entry")
    r.ignoreBytes(4)
    rate = r.readF64Be().uint32
    discard r.readU32Be()
    discard r.readU32Be()
    discard r.readU32Be()
    discard r.readU32Be()
    discard r.readU32Be()
  elif ver != 0:
    raise unsupportedError("mp4: unknown audio sample version")
  var oti = -1
  var extra: seq[uint8] = @[]
  while r.pos + 8 <= stop:
    let child = r.readBoxHeader(stop)
    if child == "esds":
      r.pos = child.dataPos
      discard r.readExtended()
      let endPos =
        if child.stop < 0: r.data.len
        else: child.stop
      let payload = r.readBytes(endPos - r.pos)
      let (o, e) = parseEsdsPayload(payload)
      oti = o
      extra = e
      r.pos = child.stop
    else:
      r.skipBox(child)
  (rate, nch, extra, oti)

proc readStbl(r: var Reader; stop: int): tuple[
    rate: uint32, nch: int, extra: seq[uint8], oti: int, isAlac: bool,
    stts: seq[array[2, uint64]], sttsTotal: uint64,
    stsc: seq[array[2, uint32]], stscFirst: seq[uint64],
    stszConst: int, stsz: seq[uint32],
    sampleCount: int, offsets: seq[uint64]] =
  var rate = 0'u32
  var nch = 0
  var extra: seq[uint8] = @[]
  var isAlac = false
  var oti = -1
  var stts: seq[array[2, uint64]] = @[]
  var sttsTotal = 0'u64
  var stsc: seq[array[2, uint32]] = @[]
  var stscFirst: seq[uint64] = @[]
  var stszConst = -1
  var stsz: seq[uint32] = @[]
  var sampleCount = -1
  var offsets: seq[uint64] = @[]
  var haveStsd, haveStts, haveStsc, haveStsz = false
  var depth = 0
  while r.pos + 8 <= stop:
    let b = r.readBoxHeader(stop)
    if b == "stsd":
      r.pos = b.dataPos
      discard r.readExtended()
      let n = r.readU32Be().int
      if n == 0:
        raise decodeError("mp4: missing sample entry")
      if n > 1:
        raise unsupportedError("mp4: more than 1 sample entry")
      if r.pos + 8 > stop:
        raise decodeError("mp4: missing expected sample entry")
      let entry = r.readBoxHeader(stop)
      if entry == "mp4a":
        r.pos = entry.dataPos
        let (rt, nc, ex, o) = parseMp4aEntry(r, entry.stop)
        rate = rt
        nch = nc
        extra = ex
        oti = o
      elif entry == "alac":
        r.pos = entry.dataPos
        if r.pos + 28 > entry.stop:
          raise decodeError("mp4: truncated alac entry")
        r.ignoreBytes(6)
        discard r.readU16Be()
        discard r.readU16Be() # version
        r.ignoreBytes(6)
        nch = r.readU16Be().int
        discard r.readU16Be()
        r.ignoreBytes(4)
        let rateRaw = r.readU32Be()
        rate = (rateRaw shr 16) + (if (rateRaw and 0xffff) >= 0x8000: 1'u32 else: 0'u32)
        while r.pos + 8 <= entry.stop:
          let child = r.readBoxHeader(entry.stop)
          if child == "alac":
            r.pos = child.dataPos
            let (ver, flags) = r.readExtended()
            if ver != 0:
              raise unsupportedError("mp4: unsupported alac version")
            if flags != 0:
              raise decodeError("mp4: alac flags not zero")
            let left = child.stop - r.pos
            if left != 24 and left != 48:
              raise decodeError("mp4: invalid alac magic cookie length")
            extra = r.readBytes(left)
            isAlac = true
            r.pos = child.stop
          else:
            r.skipBox(child)
        r.pos = entry.stop
      else:
        r.skipBox(entry)
      r.pos = b.stop
      haveStsd = true
    elif b == "stts":
      r.pos = b.dataPos
      discard r.readExtended()
      let n = r.readU32Be().int
      for _ in 0 ..< n:
        let c = r.readU32Be().uint64
        let d = r.readU32Be().uint64
        let next = sttsTotal + c * d
        if next < sttsTotal:
          raise decodeError("mp4: stts total duration overflow")
        sttsTotal = next
        stts.add([c, d])
      r.pos = b.stop
      haveStts = true
    elif b == "stsc":
      r.pos = b.dataPos
      discard r.readExtended()
      let n = r.readU32Be().int
      for _ in 0 ..< n:
        let fc = r.readU32Be()
        let pc = r.readU32Be()
        discard r.readU32Be() # sample description index
        if fc == 0:
          raise decodeError("mp4: stsc first_chunk must be >= 1")
        if pc == 0:
          raise decodeError("mp4: stsc entry has 0 samples per chunk")
        if stsc.len > 0 and fc - 1 < stsc[^1][0]:
          raise decodeError("mp4: stsc entry first chunk not monotonic")
        stsc.add([fc - 1, pc])
      stscFirst = newSeq[uint64](stsc.len)
      for i in 1 ..< stsc.len:
        let add = (stsc[i][0] - stsc[i - 1][0]).uint64 *
          stsc[i - 1][1].uint64
        if stscFirst[i - 1] + add < stscFirst[i - 1]:
          raise decodeError("mp4: stsc sample count overflow")
        stscFirst[i] = stscFirst[i - 1] + add
      r.pos = b.stop
      haveStsc = true
    elif b == "stsz":
      r.pos = b.dataPos
      discard r.readExtended()
      let size = r.readU32Be().int
      let count = r.readU32Be().int
      if size == 0:
        stszConst = -1
        stsz = newSeq[uint32](count)
        for i in 0 ..< count:
          stsz[i] = r.readU32Be()
      else:
        stszConst = size
      sampleCount = count
      r.pos = b.stop
      haveStsz = true
    elif b == "stco":
      r.pos = b.dataPos
      discard r.readExtended()
      let n = r.readU32Be().int
      for _ in 0 ..< n:
        offsets.add(r.readU32Be().uint64)
      r.pos = b.stop
    elif b == "co64":
      r.pos = b.dataPos
      discard r.readExtended()
      let n = r.readU32Be().int
      for _ in 0 ..< n:
        offsets.add(r.readU64Be())
      r.pos = b.stop
    elif b == "ctts" or b == "stss" or b == "sgpd" or b == "sbgp" or
        b == "stz2":
      r.skipBox(b) # video-only / grouping / compact sizes (unsupported)
    else:
      r.skipBox(b)
    inc depth
    if depth > 4096:
      raise decodeError("mp4: too many stbl boxes")
  if not haveStsd:
    raise decodeError("mp4: missing stsd atom")
  if not haveStts:
    raise decodeError("mp4: missing stts atom")
  if not haveStsc:
    raise decodeError("mp4: missing stsc atom")
  if not haveStsz:
    raise decodeError("mp4: missing stsz atom")
  if offsets.len == 0:
    raise decodeError("mp4: missing stco or co64 atom")
  (rate, nch, extra, oti, isAlac, stts, sttsTotal, stsc, stscFirst,
    stszConst, stsz, sampleCount, offsets)

proc stscEntryFor(stsc: seq[array[2, uint32]];
    first: seq[uint64]; sample: int): int =
  ## Binary search: last entry with firstSample <= sample.
  var lo = 1
  var hi = stsc.len
  while lo < hi:
    let mid = lo + (hi - lo) div 2
    if first[mid] < sample.uint64:
      lo = mid + 1
    else:
      hi = mid
  lo - 1

proc buildTrackSamples(stts: seq[array[2, uint64]];
    stsc: seq[array[2, uint32]]; stscFirst: seq[uint64];
    stszConst: int; stsz: seq[uint32]; sampleCount: int;
    offsets: seq[uint64]; dataLen: int): seq[Mp4Sample] =
  ## Eager per-sample index: timing from stts, positions from stsc+stco.
  result = newSeq[Mp4Sample](sampleCount)
  var entryIdx = 0
  var entryLeft = if stts.len > 0: stts[0][0] else: 0'u64
  var ts = 0'u64
  var chunk = -1
  var chunkOff = 0
  for i in 0 ..< sampleCount:
    while entryLeft == 0:
      inc entryIdx
      if entryIdx >= stts.len:
        raise decodeError("mp4: stts sample count mismatch")
      entryLeft = stts[entryIdx][0]
    let dur = stts[entryIdx][1]
    dec entryLeft
    let g = stscEntryFor(stsc, stscFirst, i)
    if g < 0 or g >= stsc.len:
      raise decodeError("mp4: invalid sample index")
    let perChunk = stsc[g][1].int
    let inGroup = i - stscFirst[g].int
    let chunkInStream = stsc[g][0].int + inGroup div perChunk
    if chunkInStream >= offsets.len:
      raise decodeError("mp4: missing stco entry")
    let size =
      if stszConst >= 0: stszConst
      else:
        if i >= stsz.len:
          raise decodeError("mp4: missing stsz entry")
        stsz[i].int
    var pos: int
    if chunkInStream != chunk:
      chunk = chunkInStream
      chunkOff = 0
      pos = offsets[chunkInStream].int
    else:
      pos = offsets[chunkInStream].int + chunkOff
    if pos < 0 or size < 0 or pos + size > dataLen:
      raise decodeError("mp4: sample out of range")
    result[i] = Mp4Sample(pos: pos, size: size, ts: ts.int64,
      dur: dur)
    chunkOff += size
    ts += dur

proc readTrak(r: var Reader; stop: int): tuple[id: int, handler: string,
    timescale: uint32, mdhdDur: uint64, rate: uint32, nch: int,
    extra: seq[uint8], oti: int, isAlac: bool, samples: seq[Mp4Sample],
    sttsTotal: uint64] =
  var id = 0
  var handler = ""
  var timescale = 0'u32
  var mdhdDur = 0'u64
  var rate = 0'u32
  var nch = 0
  var extra: seq[uint8] = @[]
  var isAlac = false
  var oti = -1
  var samples: seq[Mp4Sample] = @[]
  var sttsTotal = 0'u64
  var haveTkhd, haveMdhd, haveHdlr, haveStbl = false
  while r.pos + 8 <= stop:
    let b = r.readBoxHeader(stop)
    if b == "tkhd":
      r.pos = b.dataPos
      let (ver, _) = r.readExtended()
      if ver == 0:
        discard r.readU32Be()
        discard r.readU32Be()
        id = r.readU32Be().int
      elif ver == 1:
        discard r.readU64Be()
        discard r.readU64Be()
        id = r.readU32Be().int
      else:
        raise decodeError("mp4: invalid tkhd version")
      r.pos = b.stop
      haveTkhd = true
    elif b == "edts":
      r.pos = b.dataPos
      while r.pos + 8 <= b.stop:
        let c = r.readBoxHeader(b.stop)
        if c == "elst":
          r.pos = c.dataPos
          parseElst(r, c.stop)
          r.pos = c.stop
        else:
          r.skipBox(c)
      r.pos = b.stop
    elif b == "mdia":
      r.pos = b.dataPos
      while r.pos + 8 <= b.stop:
        let c = r.readBoxHeader(b.stop)
        if c == "mdhd":
          r.pos = c.dataPos
          let (ver, _) = r.readExtended()
          if ver == 0:
            discard r.readU32Be()
            discard r.readU32Be()
            timescale = r.readU32Be()
            if timescale == 0:
              raise decodeError("mp4: mdhd timescale is zero")
            let d = r.readU32Be()
            mdhdDur =
              if d == 0xffffffff'u32: uint64.high
              else: d.uint64
          elif ver == 1:
            discard r.readU64Be()
            discard r.readU64Be()
            timescale = r.readU32Be()
            if timescale == 0:
              raise decodeError("mp4: mdhd timescale is zero")
            mdhdDur = r.readU64Be()
          else:
            raise decodeError("mp4: invalid mdhd version")
          r.pos = c.stop
          haveMdhd = true
        elif c == "hdlr":
          r.pos = c.dataPos
          discard r.readExtended()
          discard r.readU32Be()
          var h: array[4, uint8]
          for i in 0 ..< 4:
            h[i] = r.readByte()
          handler = "" & cast[char](h[0]) & cast[char](h[1]) &
            cast[char](h[2]) & cast[char](h[3])
          r.pos = c.stop
          haveHdlr = true
        elif c == "minf":
          r.pos = c.dataPos
          while r.pos + 8 <= c.stop:
            let d = r.readBoxHeader(c.stop)
            if d == "stbl":
              r.pos = d.dataPos
              let t = r.readStbl(d.stop)
              rate = t.rate
              nch = t.nch
              extra = t.extra
              isAlac = t.isAlac
              oti = t.oti
              samples = buildTrackSamples(t.stts, t.stsc, t.stscFirst,
                t.stszConst, t.stsz, t.sampleCount, t.offsets,
                r.data.len)
              sttsTotal = t.sttsTotal
              r.pos = d.stop
              haveStbl = true
            else:
              r.skipBox(d) # smhd, dinf
          r.pos = c.stop
        else:
          r.skipBox(c)
      r.pos = b.stop
    else:
      r.skipBox(b)
  if not haveTkhd:
    raise decodeError("mp4: missing tkhd atom")
  if not haveMdhd:
    raise decodeError("mp4: missing mdhd atom")
  if not haveHdlr:
    raise decodeError("mp4: missing hdlr atom")
  if not haveStbl:
    raise decodeError("mp4: missing stbl atom")
  (id, handler, timescale, mdhdDur, rate, nch, extra, oti, isAlac,
    samples, sttsTotal)

proc openMp4*(data: seq[uint8]): Mp4Reader =
  if probeMp4(data) == 0:
    raise unsupportedError("mp4: missing ftyp header")
  result = Mp4Reader(r: newReader(data))
  var r = newReader(data)
  var haveFtyp = false
  var mvhdRate = 0'u32
  var mvhdDur = 0'u64
  var trackData: seq[Mp4TrackData] = @[]
  var fragmented = false
  while r.pos + 8 <= data.len:
    let b = r.readBoxHeader(data.len)
    if b == "ftyp":
      # Minimal sanity: at least major+minor (8 bytes).
      if b.stop - b.dataPos < 8:
        raise decodeError("mp4: invalid ftyp length")
      haveFtyp = true
      r.skipBox(b)
    elif b == "moov":
      r.pos = b.dataPos
      while r.pos + 8 <= b.stop:
        let c = r.readBoxHeader(b.stop)
        if c == "mvhd":
          r.pos = c.dataPos
          let (ver, _) = r.readExtended()
          if ver == 0:
            discard r.readU32Be()
            discard r.readU32Be()
            mvhdRate = r.readU32Be()
            if mvhdRate == 0:
              raise decodeError("mp4: mvhd timescale is zero")
            let d = r.readU32Be()
            mvhdDur =
              if d == 0xffffffff'u32: uint64.high
              else: d.uint64
          elif ver == 1:
            discard r.readU64Be()
            discard r.readU64Be()
            mvhdRate = r.readU32Be()
            if mvhdRate == 0:
              raise decodeError("mp4: mvhd timescale is zero")
            mvhdDur = r.readU64Be()
          else:
            raise decodeError("mp4: invalid mvhd version")
          r.pos = c.stop
        elif c == "trak":
          r.pos = c.dataPos
          let t = r.readTrak(c.stop)
          r.pos = c.stop
          if t.handler == "soun" and
              (t.oti in [0x40, 0x66, 0x67] or t.isAlac):
            var params =
              if t.isAlac: forCodec(CodecAlac)
              else: forCodec(CodecAac)
            params.sampleRate = some(t.rate)
            if t.nch == 1:
              params.channels = some(ChMono)
            elif t.nch == 2:
              params.channels = some(ChStereo)
            if t.isAlac:
              try:
                let ck = readAlacCookie(t.extra)
                params.channels = some(ck.channels)
                params.sampleRate = some(ck.sampleRate)
              except AudioError:
                discard
            elif t.extra.len >= 2:
              try:
                let asc = readAudioSpecificConfig(t.extra)
                if asc.channels.isSome:
                  params.channels = some(asc.channels.get)
                params.sampleRate = some(asc.sampleRate)
              except AudioError:
                discard
            params.extraData = t.extra
            var track = newTrack(t.id.uint32, params)
            let tb = tryFromRecip(t.timescale)
            if tb.isSome:
              track.timeBase = tb
            track.duration = some(newDuration(t.sttsTotal))
            if params.sampleRate.get == t.timescale:
              track.numFrames = some(t.sttsTotal)
            trackData.add(Mp4TrackData(track: track,
              timescale: t.timescale, sampleRate: params.sampleRate.get,
              samples: t.samples))
        elif c == "mvex":
          fragmented = true
          r.skipBox(c)
        elif c == "udta" or c == "meta":
          r.skipBox(c)
        else:
          r.skipBox(c)
      r.pos = b.stop
    elif b == "mdat" or b == "moof" or b == "free" or b == "skip" or
        b == "wide" or b == "uuid":
      r.skipBox(b)
    else:
      r.skipBox(b)
  if not haveFtyp:
    raise unsupportedError("mp4: missing ftyp atom")
  if fragmented:
    raise unsupportedError("mp4: fragmented streams are not supported")
  if trackData.len == 0:
    raise unsupportedError("mp4: no AAC track found")
  result.tracks = @[]
  result.data = trackData
  for t in trackData:
    result.tracks.add(t.track)
  # Merge packets across tracks by presentation time (seconds).
  var order: seq[array[3, int64]] = @[] # (secNum, trackIdx, sampleIdx)
  for ti in 0 ..< trackData.len:
    let ts = trackData[ti].timescale.int64
    for si in 0 ..< trackData[ti].samples.len:
      let pts = trackData[ti].samples[si].ts
      order.add([pts div ts, ti.int64, si.int64])
  order.sort(proc(a, b: array[3, int64]): int =
    if a[0] != b[0]: cmp(a[0], b[0])
    elif a[1] != b[1]: cmp(a[1], b[1])
    else: cmp(a[2], b[2]))
  result.packets = @[]
  for o in order:
    let ti = o[1].int
    let si = o[2].int
    let s = trackData[ti].samples[si]
    result.packets.add(Mp4Packet(trackIdx: ti, sampleIdx: si, pts: s.ts,
      dur: s.dur))
  result.posIdx = 0
  result.metadata = MetadataLog()
  result.r = newReader(data)
  result.movieRate = mvhdRate
  result.movieDur = mvhdDur

proc trackCount*(w: Mp4Reader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: Mp4Reader): MediaInfo =
  let tb = tryFromRecip(w.movieRate)
  var m = MediaInfo(timeBase: tb, startTs: ZeroTimestamp)
  if tb.isSome:
    m.duration = some(newDuration(w.movieDur))
  m

proc numFrames*(w: Mp4Reader): Option[uint64] = w.tracks[0].numFrames

proc packetBytes*(w: Mp4Reader; p: Mp4Packet): seq[uint8] =
  let s = w.data[p.trackIdx].samples[p.sampleIdx]
  w.r.data[s.pos ..< s.pos + s.size]

proc nextPacket*(w: Mp4Reader): Option[Packet] =
  if w.posIdx >= w.packets.len:
    return none(Packet)
  let p = w.packets[w.posIdx]
  inc w.posIdx
  let t = w.data[p.trackIdx]
  var pkt = newPacket(t.track.id, newTimestamp(p.pts),
    newDuration(p.dur), w.packetBytes(p))
  pkt.trimStart = newDuration(0)
  pkt.trimEnd = newDuration(0)
  some(pkt)

proc seek*(w: Mp4Reader; to: SeekTo): SeekedTo =
  let tid = w.tracks[0].id
  if to.byTime and to.timeTrackId.isSome and to.timeTrackId.get != tid:
    raise seekError(skInvalidTrack)
  if not to.byTime and to.tsTrackId != tid:
    raise seekError(skInvalidTrack)
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
    req = to.ts
  if req.get < 0:
    raise seekError(skOutOfRange)
  if track.numFrames.isSome and req.get > track.numFrames.get.int64:
    raise seekError(skOutOfRange)
  # Floor search over track 0's samples, then map to merged index.
  let td = w.data[0]
  var lo = 0
  var hi = td.samples.len - 1
  var found = 0
  while lo <= hi:
    let mid = (lo + hi) div 2
    let s = td.samples[mid]
    if s.ts <= req.get and req.get < s.ts + s.dur.int64:
      found = mid
      break
    elif s.ts > req.get:
      hi = mid - 1
    else:
      found = mid
      lo = mid + 1
  var merged = 0
  for i, p in w.packets.pairs:
    if p.trackIdx == 0 and p.sampleIdx == found:
      merged = i
      break
  w.posIdx = merged
  SeekedTo(trackId: 0, requiredTs: req,
    actualTs: newTimestamp(td.samples[found].ts))
