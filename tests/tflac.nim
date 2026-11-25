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
