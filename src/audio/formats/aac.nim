## ADTS demuxer (`AacReader`) + mux helpers.
##
## Ports the ISO/IEC 13818-7 §1.A.2 ADTS framing (fixed + variable
## header, optional CRC skip) from `oxideav-aac` `adts.rs`
## (references/oxideav-aac): byte-wise sync, profile/rate/channel
## parse, raw_data_block slicing. Payloads feed the existing AAC-LC
## decoder (`decodeRawDataBlock`); the reader synthesizes the 2-byte
## ASC the decoder requires from the ADTS header (LC only).
## Multi-raw-block frames are rejected cleanly (uncuttable without
## side info); CRC bytes are skipped, not verified.

import std/options
import ./../audio
import ./../codecs
import ./../codecs/aac
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../source
import ./../units

const
  AacFormatInfo* = FormatInfo(id: FormatIsoMp4, shortName: "aac",
    longName: "ADTS AAC")

type
  AdtsHeader* = object
    ## Resolved ADTS fixed + variable header.
    profile*: uint8 ## 2-bit field: 0 Main, 1 LC, 2 SSR (`audioObjectType - 1`).
    rateIdx*: uint8 ## 4-bit sampling-frequency index (0..12).
    channels*: uint8 ## 3-bit channel configuration (Table 1.19).
    frameLen*: int ## Total frame bytes incl. header (+CRC if present).
    hasCrc*: bool ## `protection_absent == 0`: 2 CRC bytes after the header.
    numBlocks*: int ## Raw-data-block count (wire field + 1).

  AacPacket* = object
    start*: int ## Byte offset of the raw_data_block payload.
    stop*: int ## One past the payload end.
    pts*: int64
    dur*: uint64

  AacReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    packets*: seq[AacPacket]
    posIdx*: int
    metadata*: MetadataLog

proc adtsRate*(idx: uint8): uint32 =
  ## Table 1.18 rate for an ADTS index; index 15 is illegal in ADTS.
  if idx > 12:
    raise decodeError("aac: invalid ADTS sample rate index")
  Mpeg4SampleRates[idx]

proc parseAdtsHeader*(data: openArray[uint8]; at: int): AdtsHeader =
  ## Parses the header at `at` (must hold 7 bytes). Raises `AudioError`
  ## on malformed input, `EndOfStream` on truncation.
  if data.len - at < 7:
    raise newException(EndOfStream, "aac: truncated ADTS header")
  if data[at] != 0xFF'u8 or (data[at + 1] and 0xF0'u8) != 0xF0'u8:
    raise decodeError("aac: missing ADTS sync")
  if (data[at + 1] and 0x06'u8) != 0:
    raise decodeError("aac: invalid ADTS layer")
  let protectionAbsent = (data[at + 1] and 0x01'u8) != 0
  let profile = (data[at + 2] shr 6) and 0x03'u8
  let rateIdx = (data[at + 2] shr 2) and 0x0F'u8
  if rateIdx > 12:
    raise decodeError("aac: invalid ADTS sample rate index")
  let channels = ((data[at + 2] and 0x01'u8) shl 2) or
    ((data[at + 3] shr 6) and 0x03'u8)
  let frameLen = ((data[at + 3] and 0x03'u8).int shl 11) or
    (data[at + 4].int shl 3) or ((data[at + 5] shr 5).int)
  let hdrLen = if protectionAbsent: 7 else: 9
  if frameLen < hdrLen:
    raise decodeError("aac: ADTS frame shorter than its header")
  if data.len - at < frameLen:
    raise newException(EndOfStream, "aac: truncated ADTS frame")
  let numBlocks = (data[at + 6] and 0x03'u8).int + 1
  AdtsHeader(profile: profile, rateIdx: rateIdx, channels: channels,
    frameLen: frameLen, hasCrc: not protectionAbsent,
    numBlocks: numBlocks)

proc syncAdtsFrame*(data: openArray[uint8]; pos: var int): tuple[
    header: AdtsHeader; start: int] =
  ## Byte-wise sync; on success `pos` is past the frame end.
  while true:
    if pos + 7 > data.len:
      raise newException(EndOfStream, "aac: end of stream")
    var h: AdtsHeader
    try:
      h = parseAdtsHeader(data, pos)
    except AudioError:
      inc pos
      continue
    except EndOfStream:
      # Header parses but the frame is cut: no further complete frame.
      raise newException(EndOfStream, "aac: end of stream")
    let start = pos + (if h.hasCrc: 9 else: 7)
    pos += h.frameLen
    return (h, start)

proc adtsAsc*(h: AdtsHeader): seq[uint8] =
  ## Minimal 2-byte ASC (AOT + rate index + channel config) for an
  ## LC header. Only LC is encodable in 2 bytes without extensions.
  if h.profile != 1:
    raise unsupportedError("aac: only AAC-LC ADTS supported")
  if h.channels == 0:
    raise unsupportedError("aac: PCE-defined channels unsupported")
  let b0 = (2'u8 shl 3) or (h.rateIdx shr 1)
  let b1 = ((h.rateIdx and 1'u8) shl 7) or (h.channels shl 3)
  @[b0, b1]

proc writeAdtsHeader*(h: AdtsHeader): array[7, uint8] =
  ## Assembles a 7-byte CRC-less header (`protection_absent = 1`,
  ## VBR fullness sentinel). `h.frameLen` must include the header.
  if h.frameLen < 7 or h.frameLen > 8191:
    raise unsupportedError("aac: ADTS frame length out of range")
  if h.numBlocks < 1 or h.numBlocks > 4:
    raise unsupportedError("aac: ADTS block count out of range")
  let fullness = 0x7FF
  result[0] = 0xFF'u8
  result[1] = 0xF1'u8 # sync + ID 0 (MPEG-4) + layer 00 + no CRC
  result[2] = ((h.profile and 0x03'u8) shl 6) or
    ((h.rateIdx and 0x0F'u8) shl 2) or ((h.channels shr 2) and 0x01'u8)
  result[3] = ((h.channels and 0x03'u8) shl 6) or
    ((h.frameLen shr 11) and 0x03).uint8
  result[4] = ((h.frameLen shr 3) and 0xFF).uint8
  result[5] = (((h.frameLen and 0x07) shl 5) or (fullness shr 6)).uint8
  result[6] = (((fullness and 0x3F) shl 2) or
    ((h.numBlocks - 1) and 0x03)).uint8

proc encodeAdtsFrame*(payload: openArray[uint8]; rateIdx, channels: uint8;
    profile = 1'u8): seq[uint8] =
  ## Wraps one raw_data_block in a single-block ADTS frame.
  let h = AdtsHeader(profile: profile, rateIdx: rateIdx,
    channels: channels, frameLen: payload.len + 7, hasCrc: false,
    numBlocks: 1)
  result = newSeq[uint8](h.frameLen)
  let hb = writeAdtsHeader(h)
  for i in 0 ..< 7:
    result[i] = hb[i]
  for i in 0 ..< payload.len:
    result[7 + i] = payload[i]

proc probeAac*(data: openArray[uint8]): int =
  if data.len < 7:
    return 0
  var h: AdtsHeader
  try:
    h = parseAdtsHeader(data, 0)
  except AudioError:
    return 0
  except EndOfStream:
    return 127
  if h.profile != 1 or h.rateIdx > 12:
    return 0
  let next = h.frameLen
  if data.len - next < 7:
    return 127
  try:
    let h2 = parseAdtsHeader(data, next)
    if h2.profile != h.profile or h2.rateIdx != h.rateIdx or
        h2.channels != h.channels:
      return 0
  except AudioError:
    return 0
  except EndOfStream:
    return 127
  255

proc openAac*(data: seq[uint8]): AacReader =
  if data.len < 7 or probeAac(data) == 0:
    raise unsupportedError("aac: missing ADTS frame sync")
  var pos = 0
  let first =
    try:
      syncAdtsFrame(data, pos)
    except EndOfStream:
      raise decodeError("aac: no frames found")
  if first.header.profile != 1:
    raise unsupportedError("aac: only AAC-LC ADTS supported")
  if first.header.numBlocks != 1:
    raise unsupportedError("aac: multi-raw-block ADTS frames unsupported")
  var params = forCodec(CodecAac)
  params.sampleRate = some(adtsRate(first.header.rateIdx))
  let ch = aacChannelsByConfig(first.header.channels.int)
  if ch.isSome:
    params.channels = ch
  params.extraData = adtsAsc(first.header)
  var track = newTrack(0, params)
  var packetList: seq[AacPacket] = @[]
  # Re-scan from the top so the first frame is included.
  pos = 0
  var nextTs = 0'i64
  while true:
    var fr: tuple[header: AdtsHeader; start: int]
    try:
      fr = syncAdtsFrame(data, pos)
    except EndOfStream:
      break
    let h = fr.header
    if h.profile != first.header.profile or h.rateIdx != first.header.rateIdx or
        h.channels != first.header.channels:
      raise decodeError("aac: ADTS stream config changed mid-stream")
    if h.numBlocks != 1:
      raise unsupportedError("aac: multi-raw-block ADTS frames unsupported")
    # `pos` is past the frame end; the payload runs to it.
    packetList.add(AacPacket(start: fr.start, stop: pos,
      pts: nextTs, dur: 1024))
    nextTs += 1024
  if packetList.len == 0:
    raise decodeError("aac: no audio frames found")
  track.numFrames = some(packetList.len.uint64 * 1024'u64)
  track.duration = some(newDuration(packetList.len.uint64 * 1024'u64))
  result = AacReader(r: newReader(data), tracks: @[track],
    packets: packetList, posIdx: 0, metadata: MetadataLog())

proc packetBytes*(w: AacReader; p: AacPacket): seq[uint8] =
  w.r.data[p.start ..< p.stop]

proc nextPacket*(w: AacReader): Option[Packet] =
  if w.posIdx >= w.packets.len:
    return none(Packet)
  let p = w.packets[w.posIdx]
  inc w.posIdx
  some(newPacket(0, newTimestamp(p.pts), newDuration(p.dur),
    w.packetBytes(p)))
