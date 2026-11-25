import std/math
import std/options
import unittest

import audio/audio
import audio/codecs
import audio/codecs/aac
import audio/codecs/aac_tables
import audio/dsp
import audio/errors
import audio/formats
import audio/formats/mp4 as mp4fmt
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

proc decodeAllAac(path: string): tuple[got: seq[seq[float32]],
    w: Mp4Reader] =
  let w = openMp4(readFileBytes(path))
  let dec = newAacDecoder(w.tracks[0].codec)
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

suite "aac audio specific config":
  test "stereo 44100 lc parses":
    let asc = readAudioSpecificConfig(@[0x12'u8, 0x10, 0x56, 0xe5, 0x00])
    check asc.objectType == AotLc
    check asc.sampleRate == 44_100
    check asc.channels.get.channelCount() == 2
    check asc.samples == 1024
    check not asc.sbrPresent
    check aacProfileOf(asc) == "aac-lc"

  test "mono 22050 lc parses":
    let asc = readAudioSpecificConfig(@[0x13'u8, 0x88, 0x56, 0xe5, 0x00])
    check asc.objectType == AotLc
    check asc.sampleRate == 22_050
    check asc.channels.get == ChMono
    check asc.samples == 1024

  test "explicit sample rate escape parses":
    # AOT LC, escape rate 44100, stereo.
    let bits: seq[uint8] = @[0x17'u8, 0x80, 0x56, 0x22, 0x10]
    let asc = readAudioSpecificConfig(bits)
    check asc.sampleRate == 44_100
    check asc.channels.get.channelCount() == 2

  test "reserved rate and bad channel config fail":
    try:
      discard readAudioSpecificConfig(@[0x12'u8, 0x68])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard readAudioSpecificConfig(@[0x12'u8, 0x1e])
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "sbr signaling is detected":
    # AOT SBR(5), output rate 44100 stereo, core LC 22050.
    let asc = readAudioSpecificConfig(
      @[0x2a'u8, 0x13, 0x88, 0x00])
    check asc.objectType == AotLc
    check asc.sbrPresent
    check asc.sampleRate == 44_100

  test "decoder rejects non-lc complexity":
    var p = forCodec(CodecAac)
    p.extraData = @[0x12'u8, 0x10, 0x56, 0xe5, 0x00]
    # 4 channels via channel config 4.
    p.extraData = @[0x12'u8, 0x20]
    try:
      discard newAacDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    # 960-sample frames (short_frame = 1).
    p.extraData = @[0x12'u8, 0x14]
    try:
      discard newAacDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    # Missing extra data.
    p.extraData = @[]
    try:
      discard newAacDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "aac tables and dsp":
  test "subband rows select sample-rate tables":
    check subbandRow(44_100) == 4
    check subbandRow(22_050) == 7
    check subbandRow(8_000) == 11
    check longBands(4).len == 50
    check shortBands(4).len == 15
    check longBands(4)[^1] == 1024
    check shortBands(4)[^1] == 128

  test "sine window matches sin((n+0.5)pi/2N)":
    var w = newSeq[float32](128)
    sineWindow(128, w)
    for n in 0 ..< 128:
      check abs(w[n].float64 - sin((n.float64 + 0.5) * PI / 256.0)) < 1e-7

  test "kbd window is deterministic and bounded":
    var a = newSeq[float32](1024)
    var b = newSeq[float32](1024)
    aacWindow(4.0, 1024, a)
    aacWindow(4.0, 1024, b)
    for n in 0 ..< 1024:
      check a[n] == b[n]
      check a[n] >= 0.0 and a[n] <= 1.0

  test "imdct matches analytical definition":
    # Port of symphonia-core mdct::verify_imdct.
    const N = 32
    var spec = newSeq[float32](N)
    for i in 0 ..< N:
      spec[i] = (i + 1).float32
    var m = newImdct(N, sqrt(2.0 / 64.0))
    var actual = newSeq[float32](2 * N)
    m.imdct(spec, actual)
    let pi2n = PI / (2 * (2 * N)).float64
    for i in 0 ..< 2 * N:
      var acc = 0.0
      for j in 0 ..< N:
        acc += spec[j].float64 *
          cos(pi2n * ((2 * i + 1 + N) * (2 * j + 1)).float64)
      check abs(actual[i].float64 - sqrt(2.0 / 64.0) * acc) < 1e-4

  test "aac imdct scales match analytical":
    for (n, sc) in [(128, 1.0 / 256.0), (1024, 1.0 / 2048.0)]:
      var spec = newSeq[float32](n)
      for i in 0 ..< n:
        spec[i] = ((i * 37 + 11) mod 101).float32 / 50.0 - 1.0
      var m = newImdct(n, sc)
      var actual = newSeq[float32](2 * n)
      m.imdct(spec, actual)
      let pi2n = PI / (4 * n).float64
      for i in [0, 1, n div 2, n, 2 * n - 1]:
        var acc = 0.0
        for j in 0 ..< n:
          acc += spec[j].float64 *
            cos(pi2n * ((2 * i + 1 + n) * (2 * j + 1)).float64)
        check abs(actual[i].float64 - sc * acc) < 1e-3

suite "aac huffman tables":
  test "all spectrum codebooks roundtrip":
    initAacTables()
    for t in 0 ..< 11:
      var cc = newSeq[uint32]()
      var ll = newSeq[uint32]()
      template grab(c, l: untyped) =
        cc.setLen(c.len)
        ll.setLen(l.len)
        for i in 0 ..< c.len:
          cc[i] = c[i]
          ll[i] = l[i].uint32
      case t
      of 0: grab(AacSpectrumCodes1, AacSpectrumLens1)
      of 1: grab(AacSpectrumCodes2, AacSpectrumLens2)
      of 2: grab(AacSpectrumCodes3, AacSpectrumLens3)
      of 3: grab(AacSpectrumCodes4, AacSpectrumLens4)
      of 4: grab(AacSpectrumCodes5, AacSpectrumLens5)
      of 5: grab(AacSpectrumCodes6, AacSpectrumLens6)
      of 6: grab(AacSpectrumCodes7, AacSpectrumLens7)
      of 7: grab(AacSpectrumCodes8, AacSpectrumLens8)
      of 8: grab(AacSpectrumCodes9, AacSpectrumLens9)
      of 9: grab(AacSpectrumCodes10, AacSpectrumLens10)
      else: grab(AacSpectrumCodes11, AacSpectrumLens11)
      var vv = newSeq[uint32](cc.len)
      for i in 0 ..< cc.len:
        vv[i] = i.uint32
      let tb = buildVlcTable(cc, ll, vv, 8, false)
      check tb.maxCodeLen > 0
      for i in 0 ..< cc.len:
        var bits = newSeq[bool]()
        for k in countdown(ll[i].int - 1, 0):
          bits.add(((cc[i] shr k) and 1) == 1)
        while bits.len mod 8 != 0:
          bits.add(false)
        var bytes = newSeq[uint8](bits.len div 8)
        for k in 0 ..< bits.len:
          if bits[k]:
            bytes[k div 8] = bytes[k div 8] or (0x80'u8 shr (k mod 8))
        var bs = newLtrBitReader(bytes)
        let (v, cl) = bs.readLtrVlc(tb)
        check v == i.uint32
        check cl == ll[i].int
    # Scalefactor codebook.
    var cc = newSeq[uint32](AacScfCodes.len)
    var ll = newSeq[uint32](AacScfLens.len)
    var vv = newSeq[uint32](AacScfCodes.len)
    for i in 0 ..< AacScfCodes.len:
      cc[i] = AacScfCodes[i]
      ll[i] = AacScfLens[i].uint32
      vv[i] = i.uint32
    let tb = buildVlcTable(cc, ll, vv, 8, false)
    for i in [0, 60, 120]:
      var bits = newSeq[bool]()
      for k in countdown(AacScfLens[i].int - 1, 0):
        bits.add(((AacScfCodes[i] shr k) and 1) == 1)
      while bits.len mod 8 != 0:
        bits.add(false)
      var bytes = newSeq[uint8](bits.len div 8)
      for k in 0 ..< bits.len:
        if bits[k]:
          bytes[k div 8] = bytes[k div 8] or (0x80'u8 shr (k mod 8))
      var bs = newLtrBitReader(bytes)
      check bs.readLtrVlc(tb).value == i.uint32

suite "mp4 demuxer":
  test "probe accepts ftyp, rejects garbage":
    check probeMp4(readFileBytes(FixDir & "fix_aacstereo.m4a")) == 255
    check probeMp4(readFileBytes(FixDir & "fix_aacmono.m4a")) == 255
    check probeMp4(@[0x52'u8, 0x49, 0x46, 0x46]) == 0
    check probeMp4(@[0x00'u8, 0x01]) == 0

  test "stereo tracks, params and packet timing":
    let w = openMp4(readFileBytes(FixDir & "fix_aacstereo.m4a"))
    check w.trackCount() == 1
    check w.tracks[0].id == 1
    check w.tracks[0].codec.codec == CodecAac
    check w.tracks[0].codec.sampleRate.get == 44_100
    check w.tracks[0].codec.channels.get.channelCount() == 2
    check w.tracks[0].codec.extraData ==
      @[0x12'u8, 0x10, 0x56, 0xe5, 0x00]
    check w.numFrames().get == 45_124
    check w.packets.len == 45
    var total = 0'u64
    var prevEnd = 0'i64
    for p in w.packets:
      check p.pts == prevEnd
      prevEnd = p.pts + p.dur.int64
      total += p.dur
    check total == 45_124
    check w.packets[^1].dur == 68

  test "mono timing without priming trims":
    let w = openMp4(readFileBytes(FixDir & "fix_aacmono.m4a"))
    check w.tracks[0].codec.sampleRate.get == 22_050
    check w.tracks[0].codec.channels.get.channelCount() == 1
    check w.numFrames().get == 12_049
    check w.packets.len == 12
    var total = 0'u64
    for p in w.packets:
      total += p.dur
    check total == 12_049

  test "seek lands on containing packet":
    let w = openMp4(readFileBytes(FixDir & "fix_aacstereo.m4a"))
    let s = w.seek(seekToTimestamp(newTimestamp(20_000), 1))
    check s.actualTs.get <= 20_000
    check w.nextPacket().get.pts.get == s.actualTs.get
    discard w.seek(seekToTime(fromMillis(500)))
    try:
      discard w.seek(seekToTimestamp(newTimestamp(-5), 1))
      check false
    except AudioError as e:
      check e.kind == ekSeek
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999_999), 1))
      check false
    except AudioError as e:
      check e.kind == ekSeek
      check e.seekKind == skOutOfRange
    try:
      discard w.seek(seekToTimestamp(newTimestamp(0), 0xdeadbeef'u32))
      check false
    except AudioError as e:
      check e.kind == ekSeek

  test "missing boxes fail":
    try:
      discard openMp4(@[0x52'u8, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    let good = readFileBytes(FixDir & "fix_aacmono.m4a")
    try:
      discard openMp4(good[0 ..< 120])
      check false
    except AudioError:
      check true

suite "aac decode fixtures":
  test "stereo aac matches ffmpeg within 2 LSB":
    let (got, w) = decodeAllAac(FixDir & "fix_aacstereo.m4a")
    check got[0].len == 46_080
    check got[1].len == 46_080
    discard w
    let refs = readRefS16(FixDir & "ref_aacstereo_dec.wav", 2)
    # 1024-sample encoder priming precedes the ffmpeg reference.
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      for p in 0 ..< 2:
        worst = max(worst,
          abs(got[p][i + 1024].float64 * 32768.0 - refs[p][i].float64))
    check worst <= 2.0

  test "mono aac matches ffmpeg within 2 LSB":
    let (got, w) = decodeAllAac(FixDir & "fix_aacmono.m4a")
    check got[0].len == 12_288
    discard w
    let refs = readRefS16(FixDir & "ref_aacmono_dec.wav", 1)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      worst = max(worst,
        abs(got[0][i + 1024].float64 * 32768.0 - refs[0][i].float64))
    check worst <= 2.0
