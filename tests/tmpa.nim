import std/math
import std/options
import unittest

import audio/audio
import audio/codecs
import audio/codecs/mpa
import audio/codecs/mpa_tables
import audio/errors
import audio/formats
import audio/formats/mpa as mpafmt
import audio/io
import audio/packet
import audio/units

const FixDir = "tests/fixtures/"

proc readFileBytes(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  for i, c in raw:
    result[i] = cast[uint8](c)

proc readRefS16(path: string; nch: int): seq[seq[int16]] =
  let data = readFileBytes(path)
  var at = 0
  while not (data[at] == 0x64'u8 and data[at + 1] == 0x61'u8 and
      data[at + 2] == 0x74'u8 and data[at + 3] == 0x61'u8):
    inc at
  var r = newReader(data.toOpenArray(at + 8, data.len - 1))
  let total = (data.len - at - 8) div (2 * nch)
  result = newSeq[seq[int16]](nch)
  for p in 0 ..< nch:
    result[p] = newSeq[int16](total)
  for i in 0 ..< total:
    for p in 0 ..< nch:
      result[p][i] = r.readI16Le()

proc decodeAllMpa(path: string): tuple[got: seq[seq[float32]],
    w: MpaReader] =
  let w = openMpa(readFileBytes(path))
  let dec = newMpaDecoder(w.tracks[0].codec,
    AudioDecoderOptions(gapless: true, verify: false))
  let nch = w.tracks[0].codec.channels.get.channelCount()
  var got = newSeq[seq[float32]](nch)
  for p in 0 ..< nch:
    got[p] = @[]
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        got[p].add(s.f32.planes[p][i])
  (got, w)

suite "mpa frame header":
  test "stereo layer3 header parses":
    # 0xfffb9000: MPEG1, Layer III, 128 kbit/s, 44100 Hz, stereo.
    let h = parseFrameHeader(0xfffb9000'u32)
    check h.version == Mpeg1
    check h.layer == Layer3
    check h.bitrate == 128000
    check h.sampleRate == 44_100
    check h.sampleRateIdx == 0
    check h.channelMode.kind == mmStereo
    check h.nChannels() == 2
    check not h.hasCrc
    check h.frameSize == 413
    check h.numFrames() == 1152
    check codecOfLayer(h.layer) == CodecMp3

  test "mono layer2 header parses":
    # 0xfffd8004 with mode forced mono: MPEG1, Layer II, 128 kbit/s,
    # 44100 Hz, mono. (mode bits 0b11.)
    let h = parseFrameHeader(0xfffd80c4'u32)
    check h.version == Mpeg1
    check h.layer == Layer2
    check h.bitrate == 128000
    check h.sampleRate == 44_100
    check h.channelMode.kind == mmMono
    check h.nChannels() == 1
    check h.numFrames() == 1152
    check codecOfLayer(h.layer) == CodecMp2

  test "mpeg2 layer3 mono header parses":
    # version 0b10, layer 0b01, 64 kbit/s (idx 8), 22050 Hz, mono.
    var word = 0xffe00000'u32
    word = word or (0b10'u32 shl 19) or (0b01'u32 shl 17) or
      (1'u32 shl 16) or (8'u32 shl 12) or (0b11'u32 shl 6)
    let h = parseFrameHeader(word)
    check h.version == Mpeg2
    check h.layer == Layer3
    check h.bitrate == 64000
    check h.sampleRate == 22_050
    check h.channelMode.kind == mmMono
    check h.frameSize == 204
    check h.numFrames() == 576
    check codecOfLayer(h.layer) == CodecMp3

  test "reserved fields are rejected":
    check not checkHeader(0xffe80000'u32) # version 01 reserved
    check not checkHeader(0xfff9ffff'u32 and 0xffff1fff'u32) # layer 00
    check not checkHeader(0xfffbf000'u32) # bitrate 15
    check not checkHeader(0xfffb0c00'u32) # sample rate 3
    try:
      discard parseFrameHeader(0xffe80000'u32)
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard parseFrameHeader(0xfffb0000'u32) # free bitrate
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "mpa dsp units":
  test "dct32 matches naive dft":
    var x = newSeq[float32](32)
    for i in 0 ..< 32:
      x[i] = (i.float64 * 0.37 + 0.11).float32
    var y = newSeq[float32](32)
    dct32(x, y)
    for i in 0 ..< 32:
      var acc = 0.0
      for j in 0 ..< 32:
        acc += x[j].float64 * cos(PI / 32.0 * i.float64 * (j.float64 + 0.5))
      check abs(y[i].float64 - acc) < 1e-5

  test "imdct36 matches analytical":
    const TV = [0.0976'f32, 0.9321, 0.6138, 0.0857, 0.0433, 0.4855,
      0.2144, 0.8488, 0.6889, 0.2983, 0.1957, 0.7037, 0.0052, 0.0197,
      0.3188, 0.5123, 0.2994, 0.7157]
    initMpaTables()
    var x = newSeq[float32](18)
    for i in 0 ..< 18:
      x[i] = TV[i]
    var ov = newSeq[float32](18)
    var unity: array[36, float32]
    for i in 0 ..< 36:
      unity[i] = 1.0
    imdct36(x, unity, ov)
    # Full check: x holds outputs [0..18), overlap holds [18..36).
    for i in 0 ..< 36:
      var acc = 0.0
      for j in 0 ..< 18:
        acc += TV[j].float64 *
          cos(PI / 72.0 * ((2 * i) + 1 + 18).float64 * ((2 * j) + 1).float64)
      let got = if i < 18: x[i].float64 else: ov[i - 18].float64
      check abs(got - acc) < 1e-4

  test "imdct12 matches analytical":
    initMpaTables()
    var x = newSeq[float32](18)
    for i in 0 ..< 18:
      x[i] = (i.float64 * 0.23 + 0.31).float32
    var ov = newSeq[float32](18)
    imdct12win(x, mpaImdctWin[2], ov)
    # Reference assembly: 3 windowed analytical IMDCTs overlapped.
    var expected = newSeq[float32](36)
    for w in 0 ..< 3:
      var xw = newSeq[float32](6)
      for k in 0 ..< 6:
        xw[k] = (3 * k + w).float32 * 0.23 + 0.31
      for i in 0 ..< 12:
        var acc = 0.0
        for k in 0 ..< 6:
          acc += xw[k].float64 *
            cos(PI / 24.0 * (2 * i + 7).float64 * (2 * k + 1).float64)
        if w == 0:
          expected[6 + i] += acc.float32 * mpaImdctWin[2][i]
        elif w == 1:
          expected[12 + i] += acc.float32 * mpaImdctWin[2][i]
        else:
          expected[18 + i] += acc.float32 * mpaImdctWin[2][i]
    for i in 0 ..< 18:
      check abs(x[i].float64 - expected[i].float64) < 1e-4
      check abs(ov[i].float64 - expected[i + 18].float64) < 1e-4

suite "mpa huffman tables":
  test "all codebooks roundtrip":
    initMpaTables()
    for t in 0 ..< 18:
      let wrap = MpegTableWrap[t]
      if wrap == 0:
        continue
      let src = MpegTableCodes[t]
      var codes = newSeq[uint32]()
      var lens = newSeq[uint32]()
      case src
      of 1:
        for i in 0 ..< MpegCodes1.len:
          codes.add(MpegCodes1[i])
          lens.add(MpegBits1[i].uint32)
      of 2:
        for i in 0 ..< MpegCodes2.len:
          codes.add(MpegCodes2[i])
          lens.add(MpegBits2[i].uint32)
      of 3:
        for i in 0 ..< MpegCodes3.len:
          codes.add(MpegCodes3[i])
          lens.add(MpegBits3[i].uint32)
      of 5:
        for i in 0 ..< MpegCodes5.len:
          codes.add(MpegCodes5[i])
          lens.add(MpegBits5[i].uint32)
      of 6:
        for i in 0 ..< MpegCodes6.len:
          codes.add(MpegCodes6[i])
          lens.add(MpegBits6[i].uint32)
      of 7:
        for i in 0 ..< MpegCodes7.len:
          codes.add(MpegCodes7[i])
          lens.add(MpegBits7[i].uint32)
      of 8:
        for i in 0 ..< MpegCodes8.len:
          codes.add(MpegCodes8[i])
          lens.add(MpegBits8[i].uint32)
      of 9:
        for i in 0 ..< MpegCodes9.len:
          codes.add(MpegCodes9[i])
          lens.add(MpegBits9[i].uint32)
      of 10:
        for i in 0 ..< MpegCodes10.len:
          codes.add(MpegCodes10[i])
          lens.add(MpegBits10[i].uint32)
      of 11:
        for i in 0 ..< MpegCodes11.len:
          codes.add(MpegCodes11[i])
          lens.add(MpegBits11[i].uint32)
      of 12:
        for i in 0 ..< MpegCodes12.len:
          codes.add(MpegCodes12[i])
          lens.add(MpegBits12[i].uint32)
      of 13:
        for i in 0 ..< MpegCodes13.len:
          codes.add(MpegCodes13[i])
          lens.add(MpegBits13[i].uint32)
      of 15:
        for i in 0 ..< MpegCodes15.len:
          codes.add(MpegCodes15[i])
          lens.add(MpegBits15[i].uint32)
      of 16:
        for i in 0 ..< MpegCodes16.len:
          codes.add(MpegCodes16[i])
          lens.add(MpegBits16[i].uint32)
      else:
        for i in 0 ..< MpegCodes24.len:
          codes.add(MpegCodes24[i])
          lens.add(MpegBits24[i].uint32)
      var vals = newSeq[uint32](codes.len)
      for i in 0 ..< codes.len:
        vals[i] = cast[uint32]((i div wrap) shl 4 or (i mod wrap))
      let tb = buildVlcTable(codes, lens, vals, 8, false)
      check tb.maxCodeLen > 0
      for i in 0 ..< codes.len:
        var bits = newSeq[bool]()
        for k in countdown(lens[i].int - 1, 0):
          bits.add(((codes[i] shr k) and 1) == 1)
        while bits.len mod 8 != 0:
          bits.add(false)
        var bytes = newSeq[uint8](bits.len div 8)
        for k in 0 ..< bits.len:
          if bits[k]:
            bytes[k div 8] = bytes[k div 8] or (0x80'u8 shr (k mod 8))
        var bs = newLtrBitReader(bytes)
        let (v, cl) = bs.readLtrVlc(tb)
        check v == vals[i]
        check cl == lens[i].int

suite "mpa demuxer":
  test "probe accepts mp3/mp2, rejects garbage":
    check probeMpa(readFileBytes(FixDir & "fix_mp3stereo.mp3")) == 255
    check probeMpa(readFileBytes(FixDir & "fix_mp2stereo.mp2")) == 255
    check probeMpa(@[0x52'u8, 0x49, 0x46, 0x46]) == 0
    check probeMpa(@[0x00'u8, 0x01]) == 0

  test "stereo mp3 tracks, params and packet timing":
    let w = openMpa(readFileBytes(FixDir & "fix_mp3stereo.mp3"))
    check w.trackCount() == 1
    check w.tracks[0].codec.codec == CodecMp3
    check w.tracks[0].codec.sampleRate.get == 44_100
    check w.tracks[0].codec.channels.get.channelCount() == 2
    check w.numFrames().get == 44_100
    check w.packets.len == 40
    var total = 0'u64
    var prevEnd = -1105'i64
    for p in w.packets:
      check p.pts == prevEnd
      prevEnd = p.pts + cast[int64](p.dur + p.trimStart + p.trimEnd)
      total += p.dur
    check total == 44_100
    check w.packets[0].trimStart == 1105
    check w.packets[^1].trimEnd == 875

  test "mono mp3 gapless trims":
    let w = openMpa(readFileBytes(FixDir & "fix_mp3mono.mp3"))
    check w.tracks[0].codec.sampleRate.get == 22_050
    check w.tracks[0].codec.channels.get.channelCount() == 1
    check w.numFrames().get == 11_025
    check w.packets.len == 22
    var total = 0'u64
    for p in w.packets:
      total += p.dur
    check total == 11_025

  test "mp2 estimates duration without xing":
    let w = openMpa(readFileBytes(FixDir & "fix_mp2stereo.mp2"))
    check w.tracks[0].codec.codec == CodecMp2
    check w.numFrames().get == 44_928
    check w.packets.len == 39

  test "seek lands on containing packet":
    let w = openMpa(readFileBytes(FixDir & "fix_mp3stereo.mp3"))
    let s = w.seek(seekToTimestamp(newTimestamp(20_000), 0))
    check s.actualTs.get <= 20_000
    check w.nextPacket().get.pts.get == s.actualTs.get
    discard w.seek(seekToTime(fromMillis(100)))
    try:
      discard w.seek(seekToTimestamp(newTimestamp(-9_999), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999_999), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek
      check e.seekKind == skOutOfRange
    try:
      discard w.seek(seekToTimestamp(newTimestamp(0), 0xdeadbeef'u32))
      check false
    except AudioError as e:
      check e.kind == ekSeek

  test "missing marker and truncation fail":
    try:
      discard openMpa(@[0x52'u8, 0x49, 0x46, 0x46])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    let good = readFileBytes(FixDir & "fix_mp3mono.mp3")
    try:
      discard openMpa(good[0 ..< 60])
      check false
    except AudioError:
      check true

suite "mpa decode fixtures":
  test "stereo mp3 matches ffmpeg within 2 LSB":
    let (got, w) = decodeAllMpa(FixDir & "fix_mp3stereo.mp3")
    check got[0].len == 44_100
    check got[1].len == 44_100
    let refs = readRefS16(FixDir & "ref_mp3stereo_dec.wav", 2)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      for p in 0 ..< 2:
        worst = max(worst,
          abs(got[p][i].float64 * 32768.0 - refs[p][i].float64))
    check worst <= 2.0

  test "mono mp3 matches ffmpeg within 2 LSB":
    let (got, w) = decodeAllMpa(FixDir & "fix_mp3mono.mp3")
    check got[0].len == 11_025
    discard w
    let refs = readRefS16(FixDir & "ref_mp3mono_dec.wav", 1)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      worst = max(worst,
        abs(got[0][i].float64 * 32768.0 - refs[0][i].float64))
    check worst <= 2.0

  test "stereo mp2 matches ffmpeg within 2 LSB":
    let (got, w) = decodeAllMpa(FixDir & "fix_mp2stereo.mp2")
    check got[0].len == 44_928
    discard w
    let refs = readRefS16(FixDir & "ref_mp2stereo_dec.wav", 2)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      for p in 0 ..< 2:
        worst = max(worst,
          abs(got[p][i].float64 * 32768.0 - refs[p][i].float64))
    check worst <= 2.0
