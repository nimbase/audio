## WAV demuxer (`WavReader`) and muxer (`encodeWav`).
##
## Demuxer ports `symphonia-format-riff` (`wave/*`, `common.rs`): RIFF/WAVE
## probe, `fmt ` parsing (PCM, ADPCM-MS/IMA, IEEE float, A-law, mu-law,
## WAVEFORMATEXTENSIBLE with GUID + channel-mask fixup), `fact`, LIST/INFO
## metadata, `data` packetization, and timestamp seek. ADPCM params parse
## so the Phase-3 decoder drops in; only PCM/float/law decode today.
##
## The muxer (`encodeWav`) is new work: Symphonia has no encoders. Plain
## `fmt ` (16) for <= 2 channels, EXTENSIBLE (40) above, `fact` for
## float/law/extensible, sizes patched on finish.

import std/options
import ./../audio
import ./../codecs
import ./../errors
import ./../formats
import ./../io
import ./../metadata
import ./../packet
import ./../units
import ../codecs/adpcm
import ../codecs/pcm

const
  WaveFormatInfo* = FormatInfo(id: FormatWave, shortName: "wave",
    longName: "Waveform Audio File Format")
  WaveExtensions* = ["wav", "wave"]
  WaveMimeTypes* = ["audio/vnd.wave", "audio/x-wav", "audio/wav", "audio/wave"]
  MaxFramesPerPacket* = 1152'u64

  TagRiff: array[4, uint8] = [0x52'u8, 0x49, 0x46, 0x46] # "RIFF"
  TagWave: array[4, uint8] = [0x57'u8, 0x41, 0x56, 0x45] # "WAVE"
  TagFmt: array[4, uint8] = [0x66'u8, 0x6d, 0x74, 0x20] # "fmt "
  TagList: array[4, uint8] = [0x4c'u8, 0x49, 0x53, 0x54] # "LIST"
  TagFact: array[4, uint8] = [0x66'u8, 0x61, 0x63, 0x74] # "fact"
  TagData: array[4, uint8] = [0x64'u8, 0x61, 0x74, 0x61] # "data"
  TagInfo: array[4, uint8] = [0x49'u8, 0x4e, 0x46, 0x4f] # "INFO"

  WavePcm = 0x0001'u16
  WaveAdpcmMs = 0x0002'u16
  WaveIeeeFloat = 0x0003'u16
  WaveALaw = 0x0006'u16
  WaveMuLaw = 0x0007'u16
  WaveAdpcmIma = 0x0011'u16
  WaveExtensible = 0xfffe'u16

  GuidPcm: array[16, uint8] = [0x01'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
  GuidIeeeFloat: array[16, uint8] = [0x03'u8, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
  GuidALaw: array[16, uint8] = [0x06'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
  GuidMuLaw: array[16, uint8] = [0x04'u8, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
  GuidAmbisonicPcm: array[16, uint8] = [0x01'u8, 0x00, 0x00, 0x00, 0x21,
    0x07, 0xd3, 0x11, 0x86, 0x44, 0xc8, 0xc1, 0xca, 0x00, 0x00, 0x00]
  GuidAmbisonicIeee: array[16, uint8] = [0x03'u8, 0x00, 0x00, 0x00, 0x21,
    0x07, 0xd3, 0x11, 0x86, 0x44, 0xc8, 0xc1, 0xca, 0x00, 0x00, 0x00]

type
  PacketInfo* = object
    blockSize*: uint64
    framesPerBlock*: uint64
    maxBlocksPerPacket*: uint64
    maxFramesPerPacket*: uint64

  WavReader* = ref object
    r*: Reader
    tracks*: seq[Track]
    params*: AudioCodecParameters
    packetInfo*: PacketInfo
    dataStart*: int
    dataEnd*: Option[int]
    metadata*: MetadataLog

proc withoutBlocks*(frameLen: uint32): PacketInfo =
  PacketInfo(blockSize: frameLen.uint64, framesPerBlock: 1,
    maxBlocksPerPacket: MaxFramesPerPacket,
    maxFramesPerPacket: MaxFramesPerPacket)

proc withBlocks*(blockSize: uint16; framesPerBlock: uint64): PacketInfo =
  checkDecode(framesPerBlock > 0, "wav: frames per block is zero")
  let maxBlocks = max(MaxFramesPerPacket, framesPerBlock) div framesPerBlock
  PacketInfo(blockSize: blockSize.uint64, framesPerBlock: framesPerBlock,
    maxBlocksPerPacket: maxBlocks,
    maxFramesPerPacket: maxBlocks * framesPerBlock)

proc getNumFramesAt*(info: PacketInfo; pos: uint64): uint64 {.inline.} =
  (pos div info.blockSize) * info.framesPerBlock

proc getActualTs*(info: PacketInfo; ts: Timestamp): Timestamp =
  let aligned = ts.alignTowardsZero(newDuration(info.maxFramesPerPacket))
  if aligned.isSome: aligned.get else: ts

# ------------------------------------------------------ channel mapping ---

proc mapWaveChannelCount*(n: int): Channels =
  if n < 1:
    raise decodeError("riff: invalid channel count")
  let pos = positionFromCount(n)
  if pos.isNone:
    raise decodeError("riff: invalid channel count")
  positioned(pos.get)

proc popcount64(x: uint64): int =
  var v = x
  while v != 0:
    result += (v and 1).int
    v = v shr 1

proc fixWaveChannelMask*(mask: uint32; channels: int): uint64 =
  ## Normalizes `mask` to exactly `channels` set bits: sets the lowest
  ## clear bits when short, clears the highest set bits when over.
  var m = mask.uint64
  while popcount64(m) < channels:
    var bit = 0
    while ((m shr bit) and 1) != 0:
      inc bit
      if bit > 63:
        raise decodeError("riff: invalid channel mask")
    m = m or (1'u64 shl bit)
  while popcount64(m) > channels:
    var bit = 63
    while ((m shr bit) and 1) == 0:
      dec bit
    m = m and not (1'u64 shl bit)
  m

# ------------------------------------------------------------ probing ---

proc matchTag(data: openArray[uint8]; at: int; tag: array[4, uint8]): bool =
  data.len >= at + 4 and data[at] == tag[0] and data[at + 1] == tag[1] and
    data[at + 2] == tag[2] and data[at + 3] == tag[3]

proc probeWav*(data: openArray[uint8]): int =
  ## 255 if `data` opens with `RIFF....WAVE`, else 0.
  if matchTag(data, 0, TagRiff) and matchTag(data, 8, TagWave): 255 else: 0

# ------------------------------------------------------------ fmt chunk ---

type
  ParsedFmt = object
    params*: AudioCodecParameters
    blockSize*: uint32
    framesPerBlock*: uint64

proc parsePcmFmt(r: var Reader; chunkLen: uint32; numChannels: int;
    sampleRate: uint32; bitsPerSample: uint16): ParsedFmt =
  if chunkLen == 18:
    # Quirk carried from the reference: the extension length is read
    # big-endian here and must be zero.
    if r.readU16Be() != 0:
      raise decodeError("wav: malformed fmt chunk")
  elif chunkLen == 40:
    discard r.readU16Le()
    r.ignoreBytes(22)
  elif chunkLen != 16:
    raise decodeError("wav: malformed fmt chunk")
  let codec =
    case bitsPerSample
    of 8: CodecPcmU8
    of 16: CodecPcmS16Le
    of 24: CodecPcmS24Le
    of 32: CodecPcmS32Le
    else: raise decodeError("wav: unsupported bits per sample")
  var params = forCodec(codec)
  params.sampleRate = some(sampleRate)
  params.bitsPerSample = some(bitsPerSample.uint32)
  params.bitsPerCodedSample = some(bitsPerSample.uint32)
  params.channels = some(mapWaveChannelCount(numChannels))
  let frameLen = (bitsPerSample.uint32 div 8) * numChannels.uint32
  ParsedFmt(params: params, blockSize: frameLen, framesPerBlock: 1)

proc parseIeeeFmt(r: var Reader; chunkLen: uint32; numChannels: int;
    sampleRate: uint32; bitsPerSample: uint16): ParsedFmt =
  if chunkLen == 18:
    if r.readU16Le() != 0:
      raise decodeError("wav: malformed fmt chunk")
  elif chunkLen == 40:
    r.ignoreBytes(24)
  elif chunkLen != 16:
    raise decodeError("wav: malformed fmt chunk")
  let codec =
    case bitsPerSample
    of 32: CodecPcmF32Le
    of 64: CodecPcmF64Le
    else: raise decodeError("wav: unsupported bits per sample")
  var params = forCodec(codec)
  params.sampleRate = some(sampleRate)
  params.channels = some(mapWaveChannelCount(numChannels))
  let frameLen = (bitsPerSample.uint32 div 8) * numChannels.uint32
  ParsedFmt(params: params, blockSize: frameLen, framesPerBlock: 1)

proc parseAdpcmFmt(r: var Reader; chunkLen: uint32; waveFormat: uint16;
    numChannels: int; sampleRate: uint32; blockAlign: uint16): ParsedFmt =
  if chunkLen < 20:
    raise decodeError("wav: malformed fmt chunk")
  let extraSize = r.readU16Le()
  if waveFormat == WaveAdpcmMs:
    if extraSize < 32:
      raise decodeError("wav: malformed fmt chunk")
  elif extraSize != 2:
    raise decodeError("wav: malformed fmt chunk")
  r.ignoreBytes(extraSize.int)
  var params =
    forCodec(if waveFormat == WaveAdpcmMs: CodecAdpcmMs else: CodecAdpcmImaWav)
  params.sampleRate = some(sampleRate)
  params.channels = some(mapWaveChannelCount(numChannels))
  let nch = numChannels.uint64
  let frames =
    if waveFormat == WaveAdpcmMs:
      if 7 * nch > blockAlign.uint64:
        raise decodeError("wav: invalid block alignment")
      (8 * (blockAlign.uint64 - 7 * nch)) div (4 * nch) + 2
    else:
      if 4 * nch > blockAlign.uint64:
        raise decodeError("wav: invalid block alignment")
      (8 * (blockAlign.uint64 - 4 * nch)) div (4 * nch) + 1
  params.framesPerBlock = some(frames)
  ParsedFmt(params: params, blockSize: blockAlign.uint32,
    framesPerBlock: frames)

proc parseExtensibleFmt(r: var Reader; chunkLen: uint32; numChannels: int;
    sampleRate: uint32; bitsPerSample: uint16): ParsedFmt =
  if chunkLen < 40:
    raise decodeError("wav: malformed fmt chunk")
  if r.readU16Le() != 22:
    raise decodeError("wav: malformed fmt chunk")
  let validBits = r.readU16Le()
  if (bitsPerSample and 0x7) != 0:
    raise decodeError("wav: unsupported bits per sample")
  let channelMask = r.readU32Le()
  var guid: array[16, uint8]
  for i in 0 ..< 16:
    guid[i] = r.readByte()
  let ambisonic = guid == GuidAmbisonicPcm or guid == GuidAmbisonicIeee
  var channels: Channels
  if ambisonic:
    # Ambisonic/custom layouts arrive with the ALAC/AIFF phase.
    channels = discrete(numChannels)
  else:
    channels = positioned(fixWaveChannelMask(channelMask, numChannels))
  var params: AudioCodecParameters
  if guid == GuidPcm or guid == GuidAmbisonicPcm:
    if bitsPerSample == 0 or bitsPerSample > 32:
      raise decodeError("wav: unsupported bits per sample")
    if validBits > bitsPerSample:
      raise decodeError("wav: invalid valid bits per sample")
    params = forCodec(
      case bitsPerSample
      of 8: CodecPcmU8
      of 16: CodecPcmS16Le
      of 24: CodecPcmS24Le
      of 32: CodecPcmS32Le
      else: raise decodeError("wav: unsupported bits per sample"))
    params.bitsPerSample = some(validBits.uint32)
    params.bitsPerCodedSample = some(validBits.uint32)
  elif guid == GuidIeeeFloat or guid == GuidAmbisonicIeee:
    if validBits != bitsPerSample:
      raise decodeError("wav: invalid valid bits per sample")
    params = forCodec(
      case bitsPerSample
      of 32: CodecPcmF32Le
      of 64: CodecPcmF64Le
      else: raise decodeError("wav: unsupported bits per sample"))
  elif guid == GuidALaw:
    if bitsPerSample != 8:
      raise decodeError("wav: unsupported bits per sample")
    params = forCodec(CodecPcmALaw)
  elif guid == GuidMuLaw:
    if bitsPerSample != 8:
      raise decodeError("wav: unsupported bits per sample")
    params = forCodec(CodecPcmMuLaw)
  else:
    raise unsupportedError("wav: unsupported extensible sub-format")
  params.sampleRate = some(sampleRate)
  params.channels = some(channels)
  let frameLen = (bitsPerSample.uint32 div 8) * numChannels.uint32
  ParsedFmt(params: params, blockSize: frameLen, framesPerBlock: 1)

proc parseXLawFmt(r: var Reader; chunkLen: uint32; waveFormat: uint16;
    numChannels: int; sampleRate: uint32): ParsedFmt =
  if chunkLen != 18:
    raise decodeError("wav: malformed fmt chunk")
  let extraSize = r.readU16Le()
  if extraSize > 0:
    r.ignoreBytes(extraSize.int)
  var params = forCodec(if waveFormat == WaveALaw: CodecPcmALaw
    else: CodecPcmMuLaw)
  params.sampleRate = some(sampleRate)
  params.channels = some(mapWaveChannelCount(numChannels))
  ParsedFmt(params: params, blockSize: numChannels.uint32,
    framesPerBlock: 1)

proc parseFmtChunk(r: var Reader; chunkLen: uint32): ParsedFmt =
  if chunkLen < 16:
    raise decodeError("wav: malformed fmt chunk")
  let waveFormat = r.readU16Le()
  let numChannels = r.readU16Le().int
  let sampleRate = r.readU32Le()
  discard r.readU32Le() # avgBytesPerSec, advisory only.
  let blockAlign = r.readU16Le()
  let bitsPerSample = r.readU16Le()
  if waveFormat == WavePcm:
    parsePcmFmt(r, chunkLen, numChannels, sampleRate, bitsPerSample)
  elif waveFormat == WaveIeeeFloat:
    parseIeeeFmt(r, chunkLen, numChannels, sampleRate, bitsPerSample)
  elif waveFormat == WaveAdpcmMs or waveFormat == WaveAdpcmIma:
    if bitsPerSample != 4:
      raise decodeError("wav: unsupported bits per sample")
    parseAdpcmFmt(r, chunkLen, waveFormat, numChannels, sampleRate, blockAlign)
  elif waveFormat == WaveExtensible:
    parseExtensibleFmt(r, chunkLen, numChannels, sampleRate, bitsPerSample)
  elif waveFormat == WaveALaw or waveFormat == WaveMuLaw:
    parseXLawFmt(r, chunkLen, waveFormat, numChannels, sampleRate)
  else:
    raise unsupportedError("wav: unsupported wave format")

# ------------------------------------------------------------ chunks ---

proc readInfoChunk(r: var Reader; listLen: int): MetadataRevision =
  ## Parses a LIST/INFO body into tags. Unknown keys are kept verbatim;
  ## truncated tails stop parsing instead of erroring.
  const keyMap = [
    ("INAM", "track_title"), ("IART", "artist"), ("IPRD", "album"),
    ("IGNR", "genre"), ("ICMT", "comment"), ("ICOP", "copyright"),
    ("ICRD", "date"), ("ISFT", "encoder"),
  ]
  var pos = 0
  while pos + 8 <= listLen:
    if r.remaining() < 8:
      break
    var tag: array[4, uint8]
    for i in 0 ..< 4:
      tag[i] = r.data[r.pos + i]
    let n = (r.data[r.pos + 4].uint32) or (r.data[r.pos + 5].uint32 shl 8) or
      (r.data[r.pos + 6].uint32 shl 16) or (r.data[r.pos + 7].uint32 shl 24)
    if n.uint64 > (listLen - pos - 8).uint64 or n.int > r.remaining() - 8:
      break
    r.pos += 8
    pos += 8
    var bytes = r.readBytesExact(n.int)
    pos += n.int
    if (pos and 1) == 1 and pos < listLen:
      r.ignoreBytes(1)
      inc pos
    while bytes.len > 0 and bytes[^1] == 0:
      bytes.setLen(bytes.len - 1)
    let key = fourCcToStr(tag)
    var stdKey = none(string)
    for (raw, std) in keyMap:
      if key == raw:
        stdKey = some(std)
        break
    var text = newString(bytes.len)
    for i, b in bytes:
      text[i] = b.char
    result.addTag(newTag(key, strValue(text), stdKey))

# ------------------------------------------------------------ demuxer ---

proc openWav*(data: seq[uint8]): WavReader =
  ## Opens a complete RIFF/WAVE stream held in memory.
  var r = newReader(data)
  if r.remaining() < 12 or r.readFourCc() != TagRiff:
    raise unsupportedError("wav: missing wave riff stream marker")
  let riffLen = r.readU32Le()
  if riffLen < 4:
    raise decodeError("wav: invalid riff length")
  if r.readFourCc() != TagWave:
    raise unsupportedError("wav: riff form is not wave")
  # 0xFFFFFFFF means "unknown length" (ffmpeg stdout quirk).
  let bounded = riffLen != high(uint32)
  let riffEnd =
    if bounded: 8 + riffLen.int else: data.len
  var parsed: Option[ParsedFmt] = none(ParsedFmt)
  var packetInfo = withoutBlocks(1)
  var factFrames: Option[uint64] = none(uint64)
  var metaLog = MetadataLog()
  var dataStart = -1
  var dataEndOpt: Option[int] = none(int)
  # Chunks are word-aligned: a pad byte follows odd-length bodies. The pad
  # state is derived from the cursor, like ChunksReader's `consumed`.
  let bodyStart = r.pos
  while r.pos < riffEnd:
    if ((r.pos - bodyStart) and 1) == 1:
      r.ignoreBytes(1)
      continue
    if riffEnd - r.pos < 8:
      break
    let tag = r.readFourCc()
    let chunkLen = r.readU32Le()
    let bodyEnd = r.pos + chunkLen.int
    if bounded and bodyEnd > riffEnd:
      raise decodeError("wav: chunk length exceeds parent chunk length")
    let bodyClamp = min(bodyEnd, data.len)
    if tag == TagFmt:
      if parsed.isSome:
        raise decodeError("wav: duplicate fmt chunk")
      let fmt = parseFmtChunk(r, chunkLen)
      if r.pos > bodyEnd:
        raise decodeError("wav: malformed fmt chunk")
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
      let pi =
        if fmt.framesPerBlock == 1: withoutBlocks(fmt.blockSize)
        else: withBlocks(cast[uint16](fmt.blockSize), fmt.framesPerBlock)
      packetInfo = pi
      var params = fmt.params
      params.maxFramesPerPacket = some(pi.maxFramesPerPacket)
      params.framesPerBlock = some(fmt.framesPerBlock)
      parsed = some(ParsedFmt(params: params, blockSize: fmt.blockSize,
        framesPerBlock: fmt.framesPerBlock))
    elif tag == TagFact:
      if chunkLen != 4:
        raise decodeError("wav: malformed fact chunk")
      factFrames = some(r.readU32Le().uint64)
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
    elif tag == TagList:
      if chunkLen < 4:
        raise decodeError("wav: malformed list chunk")
      if r.readFourCc() == TagInfo:
        metaLog.push(readInfoChunk(r, chunkLen.int - 4))
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
    elif tag == TagData:
      if parsed.isNone:
        raise decodeError("wav: missing format chunk")
      dataStart = r.pos
      dataEndOpt =
        if chunkLen == high(uint32): none(int)
        else: some(bodyClamp)
      break # Data is last; packetization starts here.
    else:
      # Unknown chunk: skip.
      if r.pos < bodyClamp:
        r.ignoreBytes(bodyClamp - r.pos)
    if r.pos < bodyClamp:
      r.ignoreBytes(bodyClamp - r.pos)
  if dataStart < 0:
    if parsed.isNone:
      raise decodeError("wav: missing format chunk")
    raise unsupportedError("wav: missing data chunk")
  let fmt = parsed.get
  var track = newTrack(0, fmt.params)
  if factFrames.isSome:
    track.numFrames = factFrames
  if dataEndOpt.isSome:
    let nFrames =
      packetInfo.getNumFramesAt(cast[uint64](dataEndOpt.get - dataStart))
    track.numFrames = some(nFrames)
    track.duration = some(newDuration(nFrames))
  result = WavReader(r: r, tracks: @[track], params: fmt.params,
    packetInfo: packetInfo, dataStart: dataStart, dataEnd: dataEndOpt,
    metadata: metaLog)
  result.r.pos = dataStart

proc trackCount*(w: WavReader): int {.inline.} = w.tracks.len

proc mediaInfo*(w: WavReader): MediaInfo =
  let t = w.tracks[0]
  MediaInfo(timeBase: t.timeBase, duration: t.duration, startTs: t.startTs)

proc numFrames*(w: WavReader): Option[uint64] = w.tracks[0].numFrames

proc nextPacket*(w: WavReader): Option[Packet] =
  let info = w.packetInfo
  let stop = if w.dataEnd.isSome: w.dataEnd.get else: w.r.data.len
  if w.r.pos >= stop:
    return none(Packet)
  let blocksLeft = (stop - w.r.pos).uint64 div info.blockSize
  if blocksLeft == 0:
    return none(Packet)
  let blocks = min(blocksLeft, info.maxBlocksPerPacket)
  let dur = blocks * info.framesPerBlock
  let nBytes = (blocks * info.blockSize).int
  let rel = cast[uint64](w.r.pos - w.dataStart)
  let pts = newTimestamp(cast[int64](info.getNumFramesAt(rel)))
  let buf = w.r.readBytesExact(nBytes)
  some(newPacket(0, pts, newDuration(dur), buf))

proc seek*(w: WavReader; to: SeekTo): SeekedTo =
  ## Seeks to a sample timestamp or wall-clock time.
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
  let actual = w.packetInfo.getActualTs(req)
  w.r.pos = w.dataStart + (actual.get.uint64 * w.packetInfo.blockSize).int
  SeekedTo(trackId: 0, requiredTs: req, actualTs: actual)

# ------------------------------------------------------------- muxer ---

proc adpcmFramesPerBlock*(codec: AudioCodecId; blockAlign,
    nch: int): int =
  ## Frames per ADPCM block, mirroring the demuxer's block formulas.
  if codec == CodecAdpcmMs:
    if nch == 1: 2 * blockAlign - 12
    else: blockAlign - 12
  else:
    if nch == 1: 2 * blockAlign - 7
    else: blockAlign - 7

proc encodeAdpcmData*(samples: AudioSamples; codec: AudioCodecId;
    blockAlign: int): seq[uint8] =
  ## Frames planar input into ADPCM blocks, padding the tail block by
  ## repeating the final sample (standard practice).
  let (spec, planes) = toS16Samples(samples)
  let nch = spec.channels.channelCount()
  checkDecode(nch == planes.len, "wav: adpcm channel mismatch")
  let fpb = adpcmFramesPerBlock(codec, blockAlign, nch)
  checkDecode(fpb > 0, "wav: invalid adpcm block")
  let nFrames = samples.framesOf()
  let nBlocks = (nFrames + fpb - 1) div fpb
  var padded = newSeq[seq[int16]](nch)
  for p in 0 ..< nch:
    padded[p] = newSeq[int16](nBlocks * fpb)
    for i in 0 ..< nBlocks * fpb:
      padded[p][i] = planes[p][min(i, nFrames - 1)]
  var w = newWriter()
  for b in 0 ..< nBlocks:
    let off = b * fpb
    if codec == CodecAdpcmMs:
      if nch == 1:
        w.writeBytes(encodeMsMonoBlock(padded[0].toOpenArray(off,
          off + fpb - 1)))
      else:
        w.writeBytes(encodeMsStereoBlock(
          padded[0].toOpenArray(off, off + fpb - 1),
          padded[1].toOpenArray(off, off + fpb - 1)))
    else:
      if nch == 1:
        w.writeBytes(encodeImaWavMonoBlock(padded[0].toOpenArray(off,
          off + fpb - 1)))
      else:
        w.writeBytes(encodeImaWavStereoBlock(
          padded[0].toOpenArray(off, off + fpb - 1),
          padded[1].toOpenArray(off, off + fpb - 1)))
  w.toBytes()

proc codecForFormat*(format: SampleFormat): AudioCodecId =
  case format
  of sfS8: CodecPcmS8
  of sfS16: CodecPcmS16Le
  of sfS24: CodecPcmS24Le
  of sfS32: CodecPcmS32Le
  of sfU8: CodecPcmU8
  of sfU16: CodecPcmU16Le
  of sfU24: CodecPcmU24Le
  of sfU32: CodecPcmU32Le
  of sfF32: CodecPcmF32Le
  of sfF64: CodecPcmF64Le

proc encodeWav*(samples: AudioSamples; sampleRate: uint32;
    codec = CodecNull): seq[uint8] =
  ## Muxes planar samples into a complete RIFF/WAVE stream (new work).
  ## ADPCM input is `sfS16`, or `sfS32` holding MSB-aligned S16 (the
  ## decoder's output format). The tail block is padded by repeating the
  ## final sample; `fact` carries the real frame count.
  let useCodec =
    if codec == CodecNull: codecForFormat(samples.format) else: codec
  let isAdpcm = useCodec == CodecAdpcmMs or useCodec == CodecAdpcmImaWav
  if not isAdpcm:
    if sampleFormatOf(useCodec) != samples.format and
        useCodec != CodecPcmALaw and useCodec != CodecPcmMuLaw:
      raise unsupportedError("wav: buffer format does not match codec")
  if sampleRate == 0:
    raise unsupportedError("wav: sample rate is required")
  let nch = samples.specOf().channels.channelCount()
  if nch < 1 or nch > 18:
    raise unsupportedError("wav: invalid channel count")
  if isAdpcm and nch > 2:
    raise unsupportedError("wav: adpcm supports up to two channels")
  let fmt = if isAdpcm: sfS16 else: sampleFormatOf(useCodec)
  let bitsPerSample =
    if isAdpcm: 4'u16 else: sampleWidthBits(fmt).uint16
  let extensible = nch > 2
  let isFloat = fmt == sfF32 or fmt == sfF64
  let isLaw = useCodec == CodecPcmALaw or useCodec == CodecPcmMuLaw
  let waveTag =
    if isAdpcm:
      if useCodec == CodecAdpcmMs: WaveAdpcmMs else: WaveAdpcmIma
    elif extensible: WaveExtensible
    elif isFloat: WaveIeeeFloat
    elif isLaw:
      if useCodec == CodecPcmALaw: WaveALaw else: WaveMuLaw
    else: WavePcm
  const AdpcmBlockAlign = 256
  let frameLen =
    if isAdpcm: AdpcmBlockAlign else: nch * packedWidthBytes(fmt)
  if frameLen > high(uint16).int:
    raise unsupportedError("wav: block alignment overflow")
  let blockAlign = frameLen.uint16
  let audio =
    if isAdpcm: encodeAdpcmData(samples, useCodec, AdpcmBlockAlign)
    else: encodePcm(samples, useCodec)
  let nFrames = samples.framesOf().uint32
  var w = newWriter()
  w.writeFourCc(TagRiff)
  let riffSizeAt = w.len
  w.writeU32Le(0) # Patched on finish.
  w.writeFourCc(TagWave)
  w.writeFourCc(TagFmt)
  if extensible:
    w.writeU32Le(40)
    w.writeU16Le(waveTag)
    w.writeU16Le(cast[uint16](nch))
    w.writeU32Le(sampleRate)
    w.writeU32Le(sampleRate * blockAlign.uint32)
    w.writeU16Le(blockAlign)
    w.writeU16Le(bitsPerSample)
    w.writeU16Le(22)
    w.writeU16Le(bitsPerSample)
    var mask: uint32 = 0
    for i in 0 ..< nch:
      mask = mask or (1'u32 shl i)
    w.writeU32Le(mask)
    let guid =
      if isFloat: GuidIeeeFloat
      elif isLaw:
        if useCodec == CodecPcmALaw: GuidALaw else: GuidMuLaw
      else: GuidPcm
    w.writeBytes(guid)
  else:
    let fmtLen: uint32 =
      if isFloat or isLaw: 18
      elif isAdpcm:
        if useCodec == CodecAdpcmMs: 50 else: 20
      else: 16
    w.writeU32Le(fmtLen)
    w.writeU16Le(waveTag)
    w.writeU16Le(cast[uint16](nch))
    w.writeU32Le(sampleRate)
    w.writeU32Le(sampleRate * blockAlign.uint32)
    w.writeU16Le(blockAlign)
    w.writeU16Le(bitsPerSample)
    if fmtLen == 18:
      w.writeU16Le(0)
    elif isAdpcm:
      if useCodec == CodecAdpcmMs:
        # 7 coefficient pairs from the fixed standard tables, then pad
        # to the conventional 32 extra bytes.
        w.writeU16Le(32)
        w.writeU16Le(7)
        for i in 0 ..< 7:
          w.writeU16Le(cast[uint16](MsCoeffs1[i].int16))
          w.writeU16Le(cast[uint16](MsCoeffs2[i].int16))
        w.writeU16Le(0)
      else:
        w.writeU16Le(2)
        w.writeU16Le(cast[uint16](adpcmFramesPerBlock(useCodec,
          AdpcmBlockAlign, nch)))
  if isFloat or isLaw or extensible or isAdpcm:
    w.writeFourCc(TagFact)
    w.writeU32Le(4)
    w.writeU32Le(nFrames)
  w.writeFourCc(TagData)
  w.writeU32Le(audio.len.uint32)
  w.writeBytes(audio)
  if (audio.len and 1) == 1:
    w.writeByte(0)
  w.patchU32Le(riffSizeAt, (w.len - 8).uint32)
  w.toBytes()
