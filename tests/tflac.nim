import std/math
import std/options
import unittest

import audio/checksum
import audio/codecs
import audio/codecs/flac
import audio/formats
import audio/formats/flac as flacfmt
import audio/audio
import audio/packet
import audio/units
import audio/errors
import audio/io

proc hexBytes(s: string): seq[uint8] =
  ## Even-length hex string to bytes.
  result = newSeq[uint8](s.len div 2)
  for i in 0 ..< result.len:
    let hi = s[2 * i]
    let lo = s[2 * i + 1]
    proc nyb(c: char): uint8 =
      if c >= '0' and c <= '9': cast[uint8](ord(c) - ord('0'))
      elif c >= 'a' and c <= 'f': cast[uint8](ord(c) - ord('a') + 10)
      else: cast[uint8](ord(c) - ord('A') + 10)
    result[i] = (nyb(hi) shl 4) or nyb(lo)

suite "checksum vectors":
  test "crc reference checks":
    check crc8("123456789".toBytes()) == 0xF4'u8
    check crc8(@[1'u8]) == 0x07'u8
    check crc8(@[2'u8]) == 0x0e'u8
    check crc8(@[3'u8]) == 0x09'u8
    check crc16Ansi("123456789".toBytes()) == 0xFEE8'u16
    check crc16Ansi(@[0'u8, 1]) == 0x8005'u16
    check crc32("123456789".toBytes()) == 0xCBF43926'u32
    check crc32(@[]) == 0x00000000'u32

  test "md5 reference vectors":
    const strings = ["", "a", "abc",
      "The quick brown fox jumps over the lazy dog",
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!",
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!?",
      ".s)cyIl?XKs}wDnLEUeZj'72=A/0!w;B[e*QUh)0{&XcGvf'xMx5Chhx_'ahg{GP|_R(0=Xe`lXQN_@MK9::"]
    const hashes = ["d41d8cd98f00b204e9800998ecf8427e",
      "0cc175b9c0f1b6a831c399e269772661",
      "900150983cd24fb0d6963f7d28e17f72",
      "9e107d9d372bb6826bd81d3542a419d6",
      "d174ab98d277d9f5a5611c2c9f419d9f",
      "641ba60288c17a2da5090077eb8958ad",
      "0a71db4df350927362423a42dcf81457",
      "0b76747efdcdb93367fe2da3211b5d41"]
    for i in 0 ..< strings.len:
      check hashes[i].len == 32 # Guard against transcription slips.
      for chunk in [0, 7, 21]:
        var m = newMd5()
        let data = strings[i].toBytes()
        if chunk == 0:
          m.update(data)
        else:
          var p = 0
          while p < data.len:
            let n = min(chunk, data.len - p)
            m.update(data.toOpenArray(p, p + n - 1))
            p += n
        check m.digest() == hexBytes(hashes[i])

  test "rice signed mapping":
    check riceSignedToI32(0) == 0
    check riceSignedToI32(1) == -1
    check riceSignedToI32(2) == 1
    check riceSignedToI32(3) == -2
    check riceSignedToI32(9) == -5
    check riceSignedToI32(10) == 5
    check riceSignedToI32(high(uint32)) == low(int32)

suite "streaminfo":
  test "parse and write roundtrip":
    var w = newWriter()
    w.writeU16Be(4096)
    w.writeU16Be(4096)
    w.writeU24Be(0)
    w.writeU24Be(0)
    # 44100 Hz, 2ch, 16bps, 1000 samples + zero md5.
    var bw = newBitWriter()
    bw.writeBits(44_100, 20)
    bw.writeBits(1, 3)
    bw.writeBits(15, 5)
    bw.writeBits(0, 4)
    bw.writeBits(1000, 32)
    bw.flush()
    doAssert bw.toBytes().len == 8
    w.writeBytes(bw.toBytes())
    w.writeBytes(newSeq[uint8](16))
    let info = parseStreamInfo(w.toBytes())
    check info.blockLenMin == 4096
    check info.blockLenMax == 4096
    check info.sampleRate == 44_100
    check info.channels.channelCount() == 2
    check info.bitsPerSample == 16
    check info.nSamples.get == 1000
    check info.md5.isNone
    let rt = parseStreamInfo(writeStreamInfo(info))
    check rt.blockLenMin == info.blockLenMin
    check rt.blockLenMax == info.blockLenMax
    check rt.sampleRate == info.sampleRate
    check rt.channels.channelCount() == 2
    check rt.bitsPerSample == info.bitsPerSample
    check rt.nSamples.get == 1000
    check rt.md5.isNone

  test "rejects bad blocks":
    try:
      discard parseStreamInfo(newSeq[uint8](33))
      check false
    except AudioError as e:
      check e.kind == ekDecode
    var bad = writeStreamInfo(StreamInfo(blockLenMin: 4096,
      blockLenMax: 4096, frameByteLenMin: 0, frameByteLenMax: 0,
      sampleRate: 44_100, channels: ChStereo, bitsPerSample: 16,
      nSamples: some(10'u64), md5: none(array[16, uint8])))
    bad[10] = 0 # Zero the 20-bit sample rate.
    bad[11] = 0
    bad[12] = bad[12] and 0x0f'u8
    try:
      discard parseStreamInfo(bad)
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "channel layouts":
    check flacChannels(1).channelCount() == 1
    check flacChannels(8).channelCount() == 8
    check flacChannels(6) == Ch51
    try:
      discard flacChannels(9)
      check false
    except AudioError:
      check true

proc readFileBytes(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  for i, c in raw:
    result[i] = cast[uint8](c)

# ---------------------------------------------------------------- helpers ---

proc streamInfoBytes(rate: uint32; ch: Channels; bps: uint32;
    n: uint64; blk: uint16): seq[uint8] =
  writeStreamInfo(StreamInfo(blockLenMin: blk, blockLenMax: blk,
    frameByteLenMin: 0, frameByteLenMax: 0, sampleRate: rate,
    channels: ch, bitsPerSample: bps, nSamples: some(n),
    md5: none(array[16, uint8])))

proc flacParams(extra: seq[uint8]; fpb, maxf: uint64;
    ch = ChStereo): AudioCodecParameters =
  result = forCodec(CodecFlac)
  result.extraData = extra
  result.sampleRate = some(44_100'u32)
  result.channels = some(ch)
  result.maxFramesPerPacket = some(maxf)
  result.framesPerBlock = some(fpb)

proc decodeOneFlac(extra: seq[uint8]; frame: seq[uint8]; dur: uint64;
    ch = ChStereo): AudioSamples =
  let params = flacParams(extra, dur, dur, ch)
  let dec = newFlacDecoder(params)
  dec.decodePacket(newPacket(0, ZeroTimestamp, newDuration(dur), frame))

suite "flac decode vectors":
  test "constant stereo subframes":
    # Header: sync FFF8, desc (block enc 6, rate 0, ch 1, bps 16), seq 0,
    # block count 15 (16 samples).
    let hdr = @[0xff'u8, 0xf8, 0x69, 0x18, 0x00, 0x0f]
    let body = @[0x00'u8, 0x12, 0x34, 0x00, 0xff, 0xff]
    var frame = hdr
    frame.add(crc8(hdr))
    frame.add(body)
    var fw = newWriter()
    fw.writeBytes(frame)
    fw.writeU16Be(crc16Ansi(frame))
    frame = fw.toBytes()
    let extra = streamInfoBytes(44_100, ChStereo, 16, 16, 4096)
    let s = decodeOneFlac(extra, frame, 16)
    check s.format == sfS32
    check s.framesOf() == 16
    for i in 0 ..< 16:
      check s.s32.planes[0][i] == 0x1234'i32 shl 16
      check s.s32.planes[1][i] == -1'i32 shl 16

  test "fixed order-1 with rice residuals":
    # Subframe bytes hand-computed: 0x12, warm-up 1000, rice k=2,
    # residuals 5,5 -> [1000, 1005, 1010].
    let hdr = @[0xff'u8, 0xf8, 0x60, 0x08, 0x00, 0x02]
    let body = @[0x12'u8, 0x03, 0xe8, 0x00, 0x8c, 0x60]
    var frame = hdr
    frame.add(crc8(hdr))
    frame.add(body)
    var fw = newWriter()
    fw.writeBytes(frame)
    fw.writeU16Be(crc16Ansi(frame))
    frame = fw.toBytes()
    let extra = streamInfoBytes(44_100, discrete(1), 16, 3, 4096)
    let s = decodeOneFlac(extra, frame, 3, discrete(1))
    check s.s32.planes[0][0 .. 2] == @[1000'i32 shl 16, 1005'i32 shl 16,
      1010'i32 shl 16]

  test "escape-coded binary partition":
    # Order-0 fixed, escape: resbits 5, values [1,-2,3] at 8 bps.
    let hdr = @[0xff'u8, 0xf8, 0x60, 0x02, 0x00, 0x02]
    let body = @[0x10'u8, 0x03, 0xca, 0x1f, 0x0c]
    var frame = hdr
    frame.add(crc8(hdr))
    frame.add(body)
    var fw = newWriter()
    fw.writeBytes(frame)
    fw.writeU16Be(crc16Ansi(frame))
    frame = fw.toBytes()
    let extra = streamInfoBytes(44_100, discrete(1), 8, 3, 4096)
    let s = decodeOneFlac(extra, frame, 3, discrete(1))
    check s.s32.planes[0][0 .. 2] == @[1'i32 shl 24, -2'i32 shl 24,
      3'i32 shl 24]

  test "midside odd-difference rounding":
    # Mid const 100, side const 7 (17 bits) -> L 104, R 97.
    let hdr = @[0xff'u8, 0xf8, 0x60, 0xa8, 0x00, 0x03]
    let body = @[0x00'u8, 0x00, 0x64, 0x00, 0x00, 0x03, 0x80]
    var frame = hdr
    frame.add(crc8(hdr))
    frame.add(body)
    var fw = newWriter()
    fw.writeBytes(frame)
    fw.writeU16Be(crc16Ansi(frame))
    frame = fw.toBytes()
    let extra = streamInfoBytes(44_100, ChStereo, 16, 4, 4096)
    let s = decodeOneFlac(extra, frame, 4)
    for i in 0 ..< 4:
      check s.s32.planes[0][i] == 104'i32 shl 16
      check s.s32.planes[1][i] == 97'i32 shl 16

  test "leftside and rightside":
    # LeftSide: L const 1000, D const 7 -> R 993.
    let hdrL = @[0xff'u8, 0xf8, 0x60, 0x88, 0x00, 0x01]
    let bodyL = @[0x00'u8, 0x03, 0xe8, 0x00, 0x00, 0x03, 0x80]
    var frameL = hdrL
    frameL.add(crc8(hdrL))
    frameL.add(bodyL)
    var fw = newWriter()
    fw.writeBytes(frameL)
    fw.writeU16Be(crc16Ansi(frameL))
    frameL = fw.toBytes()
    let extra = streamInfoBytes(44_100, ChStereo, 16, 2, 4096)
    let sL = decodeOneFlac(extra, frameL, 2)
    check sL.s32.planes[0][0] == 1000'i32 shl 16
    check sL.s32.planes[1][0] == 993'i32 shl 16
    # RightSide: D const 7, R const 1000 -> L 1007.
    let hdrR = @[0xff'u8, 0xf8, 0x60, 0x98, 0x00, 0x01]
    let bodyR = @[0x00'u8, 0x00, 0x03, 0x80, 0x01, 0xf4, 0x00]
    var frameR = hdrR
    frameR.add(crc8(hdrR))
    frameR.add(bodyR)
    var fw2 = newWriter()
    fw2.writeBytes(frameR)
    fw2.writeU16Be(crc16Ansi(frameR))
    frameR = fw2.toBytes()
    let sR = decodeOneFlac(extra, frameR, 2)
    check sR.s32.planes[0][0] == 1007'i32 shl 16
    check sR.s32.planes[1][0] == 1000'i32 shl 16

  test "bad header crc fails":
    let hdr = @[0xff'u8, 0xf8, 0x69, 0x18, 0x00, 0x0f]
    let body = @[0x00'u8, 0x12, 0x34, 0x00, 0xff, 0xff]
    var frame = hdr
    frame.add(crc8(hdr) xor 0xff'u8) # Corrupt.
    frame.add(body)
    var fw = newWriter()
    fw.writeBytes(frame)
    fw.writeU16Be(crc16Ansi(frame))
    frame = fw.toBytes()
    let extra = streamInfoBytes(44_100, ChStereo, 16, 16, 4096)
    try:
      discard decodeOneFlac(extra, frame, 16)
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "flac validator":
  test "md5 over interleaved le bytes":
    let spec = newAudioSpec(44_100, ChStereo)
    var buf = newAudioBuffer[int32](spec, 2)
    buf.renderWith(2, i):
      buf.planes[0][i] = [0x1234'i32, -1][i]
      buf.planes[1][i] = [0x5678'i32, 0][i]
    var v: FlacValidator
    v.initValidator()
    v.updateValidator(buf, 16)
    check v.validatorDigest() ==
      hexBytes("3ce9520f37a2fe36e5d2218953e3f861")
    var buf24 = newAudioBuffer[int32](
      newAudioSpec(44_100, discrete(1)), 2)
    buf24.renderWith(2, i):
      buf24.planes[0][i] = [0x123456'i32, -1][i]
    var v2: FlacValidator
    v2.initValidator()
    v2.updateValidator(buf24, 24)
    check v2.validatorDigest() ==
      hexBytes("4feb4f0c1eb7040e38e1c542015ec0d3")

# ---------------------------------------------------------------- helpers ---

proc sineS16Flac(n: int; amp = 25_000.0; ch = ChStereo): AudioSamples =
  let spec = newAudioSpec(44_100, ch)
  result = newAudioSamples(sfS16, spec, n)
  let nch = ch.channelCount()
  result.s16.renderWith(n, i):
    for p in 0 ..< nch:
      result.s16.planes[p][i] =
        cast[int16]((sin(i.float64 * 0.05 + p.float64) * amp).cint)

proc decodeAllFlac(data: seq[uint8]; verify = false): tuple[samples: AudioSamples,
    verifyOk: Option[bool]] =
  let w = openFlac(data)
  var params = w.params
  var dec = newFlacDecoder(params,
    AudioDecoderOptions(gapless: true, verify: verify))
  var first = true
  var outBuf = newAudioSamples(sfS32, newAudioSpec(44_100, ChStereo), 0)
  var total = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    if first:
      outBuf = newAudioSamples(sfS32, s.specOf(), 0)
      first = false
    outBuf.s32.growCapacity(total + s.framesOf())
    for p in 0 ..< s.s32.planes.len:
      for i in 0 ..< s.framesOf():
        outBuf.s32.planes[p][total + i] = s.s32.planes[p][i]
    outBuf.s32.numFrames = total + s.framesOf()
    total += s.framesOf()
  (outBuf, dec.finalize().verifyOk)

suite "flac encode":
  test "sine roundtrip is lossless":
    let src = sineS16Flac(5_000)
    let bytes = encodeFlacStream(src, 44_100)
    # Lossless and smaller than raw PCM (5000*2*2 = 20000 bytes).
    check bytes.len < 20_000
    let back = decodeAllFlac(bytes).samples
    check back.framesOf() == 5_000
    for i in 0 ..< 5_000:
      check back.s32.planes[0][i] == src.s16.planes[0][i].int32 shl 16
      check back.s32.planes[1][i] == src.s16.planes[1][i].int32 shl 16
    check encodeFlacStream(src, 44_100) == bytes # Deterministic.

  test "silence and constant are tiny":
    let spec = newAudioSpec(44_100, ChStereo)
    var silent = newAudioSamples(sfS16, spec, 4096)
    silent.s16.renderWith(4096, i):
      silent.s16.planes[0][i] = 0
      silent.s16.planes[1][i] = 0
    let sb = encodeFlacStream(silent, 44_100)
    check sb.len < 200
    check decodeAllFlac(sb).samples.framesOf() == 4096

  test "s24 roundtrip":
    let spec = newAudioSpec(48_000, discrete(1))
    var src = newAudioSamples(sfS24, spec, 1_000)
    src.s24.renderWith(1_000, i):
      src.s24.planes[0][i] = cast[int32]((i * 7919) mod 8_388_608 - 4_194_304)
    let bytes = encodeFlacStream(src, 48_000)
    let back = decodeAllFlac(bytes).samples
    check back.framesOf() == 1_000
    check back.s32.planes[0][0] == (src.s24.planes[0][0] shl 8)
    check back.s32.planes[0][999] == (src.s24.planes[0][999] shl 8)

  test "msb s32 input path":
    # Decoder output (MSB-aligned S32) re-encodes with explicit width.
    let src = sineS16Flac(1_000, 20_000.0, discrete(1))
    let bytes = encodeFlacStream(src, 44_100)
    let mid = decodeAllFlac(bytes).samples # sfS32 MSB
    check mid.format == sfS32
    let re = encodeFlacStream(mid, 44_100, 16)
    let back = decodeAllFlac(re).samples
    check back.framesOf() == 1_000
    for i in 0 ..< 1_000:
      check back.s32.planes[0][i] == mid.s32.planes[0][i]

suite "flac container":
  test "muxer demuxer roundtrip with md5 verify":
    let src = sineS16Flac(5_000)
    let bytes = encodeFlacStream(src, 44_100)
    check probeFlac(bytes) == 255
    let w = openFlac(bytes)
    check w.trackCount() == 1
    check w.params.codec == CodecFlac
    check w.params.sampleRate.get == 44_100
    check w.numFrames().get == 5_000
    check w.params.bitsPerSample.get == 16
    check w.metadata.revisions.len == 1 # Minimal VorbisComment.
    let (back, ok) = decodeAllFlac(bytes, true)
    check back.framesOf() == 5_000
    for i in countup(0, 4_999, 997):
      check back.s32.planes[0][i] == src.s16.planes[0][i].int32 shl 16
      check back.s32.planes[1][i] == src.s16.planes[1][i].int32 shl 16
    check ok.get == true

  test "wrong md5 fails verification":
    let src = sineS16Flac(500, 20_000.0, discrete(1))
    let bytes = encodeFlacStream(src, 44_100)
    let w = openFlac(bytes)
    var params = w.params
    var dec = newFlacDecoder(params,
      AudioDecoderOptions(gapless: true, verify: true))
    # Tamper with the expected checksum after construction (try_new
    # amends it from StreamInfo, so pre-seeding params cannot work).
    var bogus: array[16, uint8]
    for i in 0 ..< 16:
      bogus[i] = 0xaa'u8
    dec.params.verificationMd5 = some(bogus)
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      discard dec.decodePacket(pkt.get)
    check dec.finalize().verifyOk.get == false

  test "tampered footer fails at open":
    let src = sineS16Flac(500, 20_000.0, discrete(1))
    var bytes = encodeFlacStream(src, 44_100)
    bytes[bytes.len - 3] = bytes[bytes.len - 3] xor 0xff'u8
    try:
      discard openFlac(bytes)
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "seek and packet timing":
    let src = sineS16Flac(9_000)
    let bytes = encodeFlacStream(src, 44_100)
    let w = openFlac(bytes)
    var total = 0'u64
    var pts: seq[int64] = @[]
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      pts.add(pkt.get.pts.get)
      total += pkt.get.dur.get
    check total == 9_000
    check pts == @[0'i64, 4096, 8192]
    let s = w.seek(seekToTimestamp(newTimestamp(5_000), 0))
    check s.actualTs.get == 4096
    check w.nextPacket().get.pts.get == 4096
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek

  test "non-flac rejected":
    try:
      discard openFlac(@[0x52'u8, 0x49, 0x46, 0x46])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

# ------------------------------------------------- helpers (phase 10) ---

proc chirpS16(n: int; rate = 44_100; amp = 12_000.0): AudioSamples =
  let spec = newAudioSpec(rate.uint32, ChMono)
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    let t = i.float64 / rate.float64
    let f = 100.0 + 4900.0 * i.float64 / n.float64
    let ph = 2 * PI * (100.0 * t + 4900.0 * t * t / (2.0 * n.float64 /
      rate.float64))
    result.s16.planes[0][i] = (amp * sin(ph)).int16
    discard f

proc corrStereoS16(n: int; anti = false): AudioSamples =
  let spec = newAudioSpec(44_100, ChStereo)
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    let v = (15_000.0 * sin(2 * PI * 330.0 * i.float64 / 44100.0)).int16
    result.s16.planes[0][i] = v
    result.s16.planes[1][i] = if anti: (-v.int32).int16 else: v

proc encodeLevel(src: AudioSamples; rate: uint32; level: int;
    bps = 0'u32): seq[uint8] =
  var opts = defaultFlacEncoderOptions()
  opts.level = level
  encodeFlacStream(src, rate, bps, opts)

proc firstHeader(data: seq[uint8]): FrameHeader =
  ## Walks file metadata to the first frame and parses its header.
  var r = newReader(data)
  check r.readBytesExact(4) == @[0x66'u8, 0x4c, 0x61, 0x43]
  while true:
    let hb = r.readByte()
    let isLast = (hb and 0x80'u8) != 0
    let ln = r.readU24Be().int
    r.ignoreBytes(ln)
    if isLast:
      break
  let sync = syncFrame(r)
  readFrameHeader(r, sync)

proc readStreamInfo(data: seq[uint8]): StreamInfo =
  var r = newReader(data)
  discard r.readBytesExact(4)
  while true:
    let hb = r.readByte()
    let isLast = (hb and 0x80'u8) != 0
    let typ = hb and 0x7f'u8
    let ln = r.readU24Be().int
    let body = r.readBytesExact(ln)
    if typ == 0:
      return parseStreamInfo(body)
    if isLast:
      break
  raise newException(AssertionDefect, "no streaminfo")

proc readRefS16Flac(path: string; nch: int): seq[seq[int16]] =
  let raw = readFile(path)
  var data = newSeq[uint8](raw.len)
  for i, c in raw:
    data[i] = cast[uint8](c)
  var at = 0
  while not (data[at] == 0x64'u8 and data[at+1] == 0x61'u8 and
      data[at+2] == 0x74'u8 and data[at+3] == 0x61'u8):
    inc at
  var r = newReader(data.toOpenArray(at + 8, data.len - 1))
  let total = (data.len - at - 8) div (2 * nch)
  result = newSeq[seq[int16]](nch)
  for p in 0 ..< nch:
    result[p] = newSeq[int16](total)
  for i in 0 ..< total:
    for p in 0 ..< nch:
      result[p][i] = r.readI16Le()

proc readRefS32Flac(path: string; nch: int): seq[seq[int32]] =
  let raw = readFile(path)
  var data = newSeq[uint8](raw.len)
  for i, c in raw:
    data[i] = cast[uint8](c)
  var at = 0
  while not (data[at] == 0x64'u8 and data[at+1] == 0x61'u8 and
      data[at+2] == 0x74'u8 and data[at+3] == 0x61'u8):
    inc at
  var r = newReader(data.toOpenArray(at + 8, data.len - 1))
  let total = (data.len - at - 8) div (4 * nch)
  result = newSeq[seq[int32]](nch)
  for p in 0 ..< nch:
    result[p] = newSeq[int32](total)
  for i in 0 ..< total:
    for p in 0 ..< nch:
      result[p][i] = r.readI32Le()

proc decodeAllS32(data: seq[uint8]; verify = false): tuple[samples:
    seq[seq[int32]], verifyOk: Option[bool]] =
  let w = openFlac(data)
  var dec = newFlacDecoder(w.params,
    AudioDecoderOptions(gapless: true, verify: verify))
  let nch = w.params.channels.get.channelCount()
  var got = newSeq[seq[int32]](nch)
  for p in 0 ..< nch:
    got[p] = @[]
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        got[p].add(s.s32.planes[p][i])
  (got, dec.finalize().verifyOk)

suite "flac encoder options":
  test "defaults and level tables":
    let o = defaultFlacEncoderOptions()
    check o.level == 5
    check o.blockSize == 0
    check o.variableBlock == false
    check o.writeSeekTable == true
    check encoderBlockSize(o) == 4096
    check maxLpcOrder(o) == 12
    check maxPartitionOrder(o) == 4
    check doDecorrelate(o) == true
    var z = defaultFlacEncoderOptions()
    z.level = 0
    check maxLpcOrder(z) == 0
    check maxPartitionOrder(z) == 0
    check doDecorrelate(z) == false
    z.level = 8
    check maxLpcOrder(z) == 32
    check maxPartitionOrder(z) == 8

  test "block size validation":
    var o = defaultFlacEncoderOptions()
    o.blockSize = 15
    try:
      discard encodeFlacStream(sineS16Flac(100), 44_100, 0, o)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    o.blockSize = 70_000
    try:
      discard encodeFlacStream(sineS16Flac(100), 44_100, 0, o)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    o.blockSize = 1152
    let bytes = encodeFlacStream(sineS16Flac(3_000), 44_100, 0, o)
    let w = openFlac(bytes)
    var pts: seq[int64] = @[]
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      pts.add(pkt.get.pts.get)
    check pts == @[0'i64, 1152, 2304]

  test "empty input rejected":
    let spec = newAudioSpec(44_100, ChStereo)
    let empty = newAudioSamples(sfS16, spec, 0)
    try:
      discard encodeFlacStream(empty, 44_100)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

  test "ladder improves on structured signals":
    let chirp = chirpS16(8192)
    let c0 = encodeLevel(chirp, 44_100, 0)
    let c5 = encodeLevel(chirp, 44_100, 5)
    check c5.len < c0.len
    let corr = corrStereoS16(8192)
    let k0 = encodeLevel(corr, 44_100, 0)
    let k1 = encodeLevel(corr, 44_100, 1)
    check k1.len < k0.len div 2 + k0.len div 4 # ~half via mid/side

suite "flac lpc estimation":
  test "levinson-durbin on AR(1) autocorrelation":
    let (a1, e1) = levinsonDurbin([1.0, 0.5, 0.25], 1)
    check abs(a1[0] - 0.5) < 1e-12
    check abs(e1 - 0.75) < 1e-12
    let (a2, e2) = levinsonDurbin([1.0, 0.5, 0.25], 2)
    check abs(a2[0] - 0.5) < 1e-12
    check abs(a2[1]) < 1e-12
    check abs(e2 - 0.75) < 1e-12
    let (a0, e0) = levinsonDurbin([0.0, 0.0], 0)
    check a0.len == 0
    check e0 == 0.0

  test "quantize rejects unrepresentable precision":
    check quantizeLpc([0.0, 0.0], 12).ok == true
    check quantizeLpc([0.0], 12).shift == 0
    check quantizeLpc([1.5], 0).ok == false
    check quantizeLpc([1.5], 16).ok == false
    check quantizeLpc([100.0], 6).ok == false
    let (ok, shift, qc) = quantizeLpc([1.5], 6)
    check ok == true
    check shift == 4
    check qc == @[24'i32]

  test "apodization windows":
    var x = newSeq[int32](8)
    for i in 0 ..< 8:
      x[i] = 100
    var wrect = newSeq[float64]()
    apodize(x, akRectangular, wrect)
    for v in wrect:
      check v == 100.0
    var wt = newSeq[float64]()
    apodize(x, akTukey, wt)
    check wt[0] == 0.0
    check wt[4] == 100.0
    var ww = newSeq[float64]()
    apodize(x, akWelch, ww)
    check abs(ww[4] - 100.0) < 1e-9
    check ww[0] < ww[4]

  test "lpc winner reconstructs exactly":
    var s = newSeq[int32](1024)
    for i in 0 ..< 1024:
      s[i] = (20000.0 * sin(2 * PI * 440.0 * i.float64 /
        44100.0)).int32
    let (ok, order, _, shift, coeffs, res, _) = tryLpcSubframe(
      s.toOpenArray(0, 1023), 16, 12, true, lpcWindows(5))
    check ok == true
    check order >= 1 and order <= 12
    for i in order ..< order + 16:
      var p = 0'i64
      for j in 0 ..< order:
        p = p +% coeffs[j].int64 * s[i - 1 - j].int64
      check s[i] -% cast[int32](p shr shift) == res[i]

  test "subframe roundtrips at levels 0, 5 and 8":
    var s = newSeq[int32](512)
    for i in 0 ..< 512:
      s[i] = (20000.0 * sin(2 * PI * 440.0 * i.float64 /
        44100.0)).int32
    for level in [0, 5, 8]:
      var opts = defaultFlacEncoderOptions()
      opts.level = level
      var bw = newBitWriter()
      bw.encodeSubframeEx(s.toOpenArray(0, 511), 16, opts)
      bw.flush()
      var bs = newBitReader(bw.toBytes())
      var back = newSeq[int32](512)
      bs.decodeSubframe(16, back.toOpenArray(0, 511))
      check back == s
    # White-noise-ish block exercises Rice2/escape selection paths.
    var nz = newSeq[int32](256)
    var seed = 0x12345678'u32
    for i in 0 ..< 256:
      seed = seed * 1664525'u32 + 1013904223'u32
      nz[i] = cast[int32]((seed shr 8) and 0xffff'u32) - 32768
    for level in [3, 5]:
      var opts = defaultFlacEncoderOptions()
      opts.level = level
      var bw = newBitWriter()
      bw.encodeSubframeEx(nz.toOpenArray(0, 255), 16, opts)
      bw.flush()
      var bs = newBitReader(bw.toBytes())
      var back = newSeq[int32](256)
      bs.decodeSubframe(16, back.toOpenArray(0, 255))
      check back == nz

suite "flac rice coding":
  test "chooseRice picks optimal parameter":
    var zeros = newSeq[int32](64)
    let z = chooseRice(zeros.toOpenArray(0, 63), true)
    check z.escape == false
    check z.k == 0
    var big = newSeq[int32](64)
    for i in 0 ..< 64:
      big[i] = 30000
    # Constant large residuals: the 4-bit escape (1033 bits) beats Rice
    # k=15 (1092 bits), so escape is selected with either Rice width.
    let re1 = chooseRice(big.toOpenArray(0, 63), true)
    check re1.escape == true
    check re1.width == 16
    let re0 = chooseRice(big.toOpenArray(0, 63), false)
    check re0.escape == true
    check re0.width == 16
    # Spread residuals need k > 14: Rice2 (5-bit params) is selected.
    var spread = newSeq[int32](64)
    for i in 0 ..< 64:
      spread[i] = ((i + 1) * 10000).int32
    let r5 = choosePartitions(spread.toOpenArray(0, 63), 0, 0, true)
    check r5.method5 == true
    check r5.choices[0].k > 14
    let r4 = choosePartitions(spread.toOpenArray(0, 63), 0, 0, false)
    check r4.method5 == false
    # Extreme residuals must never select an unrepresentable escape width.
    let x = chooseRice([high(int32), low(int32)].toOpenArray(0, 1), true)
    check x.escape == false
    check x.k <= 30
    check escapeWidth(zeros.toOpenArray(0, 63)) == 1
    check escapeWidth([100'i32].toOpenArray(0, 0)) == 8

  test "ramp forces Rice2 and roundtrips":
    # Slope-10000 fixed-1 residuals need k > 14: Rice2 must be selected.
    var ramp = newSeq[int32](64)
    for i in 0 ..< 64:
      ramp[i] = (i * 10000).int32
    let rp = choosePartitions(ramp.toOpenArray(1, 63), 1, 0, true)
    check rp.method5 == true
    var opts = defaultFlacEncoderOptions()
    opts.level = 5
    var bw = newBitWriter()
    bw.encodeSubframeEx(ramp.toOpenArray(0, 63), 32, opts)
    bw.flush()
    var bs = newBitReader(bw.toBytes())
    var back = newSeq[int32](64)
    bs.decodeSubframe(32, back.toOpenArray(0, 63))
    check back == ramp

suite "flac stereo decorrelation":
  test "identical channels pick left-side":
    let src = corrStereoS16(4096)
    var opts = defaultFlacEncoderOptions()
    opts.level = 5
    let bytes = encodeFlacStream(src, 44_100, 0, opts)
    check firstHeader(bytes).assignment.kind == caLeftSide
    let (got, ok) = decodeAllS32(bytes, true)
    check got[0].len == 4096
    for i in countup(0, 4095, 509):
      check got[0][i] == src.s16.planes[0][i].int32 shl 16
      check got[1][i] == src.s16.planes[1][i].int32 shl 16
    check ok.get == true

  test "anti-correlated channels pick mid-side":
    let src = corrStereoS16(4096, true)
    var opts = defaultFlacEncoderOptions()
    opts.level = 5
    let bytes = encodeFlacStream(src, 44_100, 0, opts)
    check firstHeader(bytes).assignment.kind == caMidSide
    let (got, ok) = decodeAllS32(bytes, true)
    for i in countup(0, 4095, 509):
      check got[0][i] == src.s16.planes[0][i].int32 shl 16
      check got[1][i] == src.s16.planes[1][i].int32 shl 16
    check ok.get == true

suite "flac full headers":
  test "explicit rate and depth codings":
    let src = sineS16Flac(3000)
    check firstHeader(encodeFlacStream(src, 44_100)).sampleRate.get ==
      44_100
    check firstHeader(encodeFlacStream(src, 44_100)).bitsPerSample.get ==
      16
    var o32 = defaultFlacEncoderOptions()
    o32.level = 1
    let spec32 = newAudioSpec(48_000, ChMono)
    var s32 = newAudioSamples(sfS32, spec32, 2000)
    s32.s32.renderWith(2000, i):
      s32.s32.planes[0][i] = (1_000_000_000.0 *
        sin(2 * PI * 440.0 * i.float64 / 48000.0)).int32
    let b32 = encodeFlacStream(s32, 48_000, 32, o32)
    check firstHeader(b32).bitsPerSample.get == 32
    let back32 = decodeAllS32(b32)
    check back32.samples[0].len == 2000
    for i in countup(0, 1999, 401):
      check back32.samples[0][i] == s32.s32.planes[0][i]

  test "32-bit stereo stays independent":
    # The side channel would need 33 bits (unrepresentable), so 32-bit
    # stereo must encode independent channels (used to crash the writer).
    let spec = newAudioSpec(96_000, ChStereo)
    var s32 = newAudioSamples(sfS32, spec, 1024)
    s32.s32.renderWith(1024, i):
      s32.s32.planes[0][i] = (1_000_000_000.0 *
        sin(2 * PI * 440.0 * i.float64 / 96000.0)).int32
      s32.s32.planes[1][i] = (1_000_000_000.0 *
        sin(2 * PI * 880.0 * i.float64 / 96000.0)).int32
    var o = defaultFlacEncoderOptions()
    o.level = 5
    let bytes = encodeFlacStream(s32, 96_000, 32, o)
    check firstHeader(bytes).assignment.kind == caIndependent
    let (got, ok) = decodeAllS32(bytes, true)
    check got[0].len == 1024
    for i in countup(0, 1023, 257):
      check got[0][i] == s32.s32.planes[0][i]
      check got[1][i] == s32.s32.planes[1][i]
    check ok.get == true

  test "uncommon sample rate":
    let src = chirpS16(3000, 12_000)
    var o = defaultFlacEncoderOptions()
    o.level = 1
    let bytes = encodeFlacStream(src, 12_000, 0, o)
    check firstHeader(bytes).sampleRate.get == 12_000
    let (got, ok) = decodeAllS32(bytes, true)
    check got[0].len == 3000
    for i in countup(0, 2999, 601):
      check got[0][i] == src.s16.planes[0][i].int32 shl 16
    check ok.get == true

  test "odd bit depth":
    let spec = newAudioSpec(44_100, ChMono)
    var s32 = newAudioSamples(sfS32, spec, 1500)
    s32.s32.renderWith(1500, i):
      s32.s32.planes[0][i] = (400_000.0 *
        sin(2 * PI * 440.0 * i.float64 / 44100.0)).int32
    var o = defaultFlacEncoderOptions()
    o.level = 1
    let bytes = encodeFlacStream(s32, 44_100, 20, o)
    check firstHeader(bytes).bitsPerSample.get == 20
    let (got, ok) = decodeAllS32(bytes, true)
    check got[0].len == 1500
    for i in countup(0, 1499, 401):
      # Decoder output is MSB-aligned; low 12 bits are not stored.
      check got[0][i] == (s32.s32.planes[0][i] shr 12) shl 12
    check ok.get == true

  test "variable block size roundtrip with seek":
    var o = defaultFlacEncoderOptions()
    o.level = 2
    o.variableBlock = true
    let src = sineS16Flac(5_000)
    let bytes = encodeFlacStream(src, 44_100, 0, o)
    let w = openFlac(bytes)
    check w.numFrames().get == 5_000
    var total = 0'u64
    var pts: seq[int64] = @[]
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      pts.add(pkt.get.pts.get)
      total += pkt.get.dur.get
    check total == 5_000
    check pts == @[0'i64, 4096]
    let s = w.seek(seekToTimestamp(newTimestamp(4096), 0))
    check s.actualTs.get == 4096
    let (got, ok) = decodeAllS32(bytes, true)
    for i in countup(0, 4999, 997):
      check got[0][i] == src.s16.planes[0][i].int32 shl 16
      check got[1][i] == src.s16.planes[1][i].int32 shl 16
    check ok.get == true

  test "tiny input and short tail":
    var o = defaultFlacEncoderOptions()
    o.level = 1
    let src = sineS16Flac(100)
    let bytes = encodeFlacStream(src, 44_100, 0, o)
    let (got, ok) = decodeAllS32(bytes, true)
    check got[0].len == 100
    for i in 0 ..< 100:
      check got[0][i] == src.s16.planes[0][i].int32 shl 16
    check ok.get == true

  test "streaminfo carries real sizes and md5":
    let src = sineS16Flac(9_000)
    var o = defaultFlacEncoderOptions()
    o.level = 1
    let info = readStreamInfo(encodeFlacStream(src, 44_100, 0, o))
    check info.blockLenMin == 4096
    check info.blockLenMax == 4096
    check info.frameByteLenMin > 0
    check info.frameByteLenMax >= info.frameByteLenMin
    check info.nSamples.get == 9_000
    check info.md5.isSome

  test "frame sequence 0xfe is rejected, not hung":
    var r = newReader(@[0x69'u8, 0x08, 0xfe])
    try:
      discard readFrameHeader(r, 0xfff8'u16)
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "flac encoder ratios":
  test "lpc beats fixed on mixed tones":
    let src = sineS16Flac(11_025)
    let b0 = encodeLevel(src, 44_100, 0)
    let b5 = encodeLevel(src, 44_100, 5)
    check b5.len < b0.len
    check b5.len <= (b0.len * 9) div 10

  test "level 8 tiny vector is lossless":
    var s = newSeq[int32](512)
    for i in 0 ..< 512:
      s[i] = (20000.0 * sin(2 * PI * 440.0 * i.float64 /
        44100.0)).int32
    var opts = defaultFlacEncoderOptions()
    opts.level = 8
    var bw = newBitWriter()
    bw.encodeSubframeEx(s.toOpenArray(0, 511), 16, opts)
    bw.flush()
    var bs = newBitReader(bw.toBytes())
    var back = newSeq[int32](512)
    bs.decodeSubframe(16, back.toOpenArray(0, 511))
    check back == s

suite "flac cli interop":
  test "reference -5 file decodes bit-exact":
    let data = readFileBytes("tests/fixtures/fix_flac_cli5.flac")
    let (got, ok) = decodeAllS32(data, true)
    check got[0].len == 44_100
    let refs = readRefS16Flac(
      "tests/fixtures/ref_flac_cli5_dec.wav", 2)
    for i in countup(0, 44_099, 997):
      check got[0][i] == refs[0][i].int32 shl 16
      check got[1][i] == refs[1][i].int32 shl 16
    check ok.get == true

  test "reference --lax file decodes bit-exact":
    let data = readFileBytes("tests/fixtures/fix_flac_lax.flac")
    let (got, ok) = decodeAllS32(data, true)
    check got[0].len == 44_100
    let refs = readRefS16Flac(
      "tests/fixtures/ref_flac_lax_dec.wav", 2)
    for i in countup(0, 44_099, 997):
      check got[0][i] == refs[0][i].int32 shl 16
      check got[1][i] == refs[1][i].int32 shl 16
    check ok.get == true

  test "reference noise file decodes bit-exact":
    let data = readFileBytes("tests/fixtures/fix_flac_noise.flac")
    let (got, ok) = decodeAllS32(data, true)
    check got[0].len == 22_050
    let refs = readRefS16Flac(
      "tests/fixtures/ref_flac_noise_dec.wav", 1)
    for i in countup(0, 22_049, 997):
      check got[0][i] == refs[0][i].int32 shl 16
    check ok.get == true

  test "reference 96k 32-bit -8 file decodes bit-exact":
    let data = readFileBytes("tests/fixtures/fix_flac_cli8_96k32.flac")
    let w = openFlac(data)
    check w.params.sampleRate.get == 96_000
    check w.params.bitsPerSample.get == 32
    check w.params.channels.get.channelCount() == 2
    let (got, ok) = decodeAllS32(data, true)
    check got[0].len == 48_000
    let refs = readRefS32Flac(
      "tests/fixtures/ref_flac_cli8_96k32_dec.wav", 2)
    for i in countup(0, 47_999, 1201):
      check got[0][i] == refs[0][i]
      check got[1][i] == refs[1][i]
    check ok.get == true
