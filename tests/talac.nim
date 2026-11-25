import std/math
import std/options
import unittest

import audio/audio
import audio/codecs
import audio/codecs/pcm
import audio/codecs/alac
import audio/errors
import audio/formats
import audio/formats/aiff as aifffmt
import audio/formats/caf as caffmt
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

proc decodeAllAlacMp4(path: string): tuple[got: seq[seq[int32]],
    w: Mp4Reader] =
  let w = openMp4(readFileBytes(path))
  let dec = newAlacDecoder(w.tracks[0].codec)
  let nch = w.tracks[0].codec.channels.get.channelCount()
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
  (got, w)

proc decodeAllAlacCaf(path: string): tuple[got: seq[seq[int32]],
    w: CafReader] =
  let w = openCaf(readFileBytes(path))
  let dec = newAlacDecoder(w.tracks[0].codec)
  let nch = w.tracks[0].codec.channels.get.channelCount()
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
  (got, w)

proc stbCookie(frameLen = 4096, depth = 16, nch = 2,
    rate = 44_100): seq[uint8] =
  @[byte(frameLen shr 24), byte((frameLen shr 16) and 0xff),
    byte((frameLen shr 8) and 0xff), byte(frameLen and 0xff),
    0x00, byte(depth), 0x28, 0x0a, 0x0e, byte(nch),
    0x00, 0x00, # maxRun
    0x00, 0x00, 0x00, 0x00, # maxFrameBytes
    0x00, 0x00, 0x00, 0x00, # avgBitRate
    byte(rate shr 24), byte((rate shr 16) and 0xff),
    byte((rate shr 8) and 0xff), byte(rate and 0xff)]

suite "alac magic cookie":
  test "stereo 24-byte cookie parses":
    let ck = readAlacCookie(stbCookie())
    check ck.frameLength == 4096
    check ck.bitDepth == 16
    check ck.pb == 40
    check ck.mb == 10
    check ck.kb == 14
    check ck.numChannels == 2
    check ck.sampleRate == 44_100
    check ck.channels == ChStereo

  test "48-byte cookie with chan layout parses":
    var c = stbCookie()
    c.add(@[0x00'u8, 0x00, 0x00, 0x18, 0x63, 0x68, 0x61, 0x6e,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x65, 0x00, 0x02,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    let ck = readAlacCookie(c)
    check ck.channels == ChStereo

  test "frma and alac prefixes are skipped":
    var c = @[0x00'u8, 0x00, 0x00, 0x0c, 0x66, 0x72, 0x6d, 0x61,
      0x61, 0x6c, 0x61, 0x63]
    c.add(stbCookie())
    let ck = readAlacCookie(c)
    check ck.numChannels == 2
    var c2 = @[0x00'u8, 0x00, 0x00, 0x0c, 0x61, 0x6c, 0x61, 0x63,
      0x00, 0x00, 0x00, 0x00]
    c2.add(stbCookie())
    check readAlacCookie(c2).sampleRate == 44_100

  test "malformed cookies fail with the right kind":
    try:
      discard readAlacCookie(stbCookie()[0 ..< 23])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    try:
      discard readAlacCookie(stbCookie() & @[0x00'u8])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    var bad = stbCookie()
    bad[4] = 1 # compatible version
    try:
      discard readAlacCookie(bad)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    bad = stbCookie()
    bad[5] = 33 # bit depth
    try:
      discard readAlacCookie(bad)
      check false
    except AudioError as e:
      check e.kind == ekDecode
    bad = stbCookie()
    bad[9] = 0 # channels
    try:
      discard readAlacCookie(bad)
      check false
    except AudioError as e:
      check e.kind == ekDecode
    # Bogus layout tag in a 48-byte cookie.
    var c = stbCookie()
    c.add(@[0x00'u8, 0x00, 0x00, 0x18, 0x63, 0x68, 0x61, 0x6e,
      0x00, 0x00, 0x00, 0x00, 0xde, 0xad, 0x00, 0x02,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    try:
      discard readAlacCookie(c)
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "decoder gates bad params":
    var p = forCodec(CodecMp3)
    p.extraData = stbCookie()
    try:
      discard newAlacDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    p = forCodec(CodecAlac)
    p.extraData = @[]
    try:
      discard newAlacDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    p.extraData = stbCookie()
    p.extraData[0] = 0x01 # frameLength 0x01001000 > 65536
    try:
      discard newAlacDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "alac bit utilities":
  test "rice code signed mapping":
    check riceToSigned(0) == 0
    check riceToSigned(1) == -1
    check riceToSigned(2) == 1
    check riceToSigned(3) == -2
    check riceToSigned(0xfffffffe'u32) == 0x7fffffff'i32
    check riceToSigned(0xffffffff'u32) == low(int32)
    check lg3a(10) == 1
    check lg3a(0xffff) == 7
    check clipMsbs(0x12345678'i32, 8) == 0x345678'i32
    check clipMsbs(-1'i32, 8) == -1

suite "mp4 alac demuxer":
  test "stereo alac tracks, params and timing":
    let w = openMp4(readFileBytes(FixDir & "fix_alacstereo.m4a"))
    check w.trackCount() == 1
    check w.tracks[0].codec.codec == CodecAlac
    check w.tracks[0].codec.sampleRate.get == 44_100
    check w.tracks[0].codec.channels.get.channelCount() == 2
    check w.tracks[0].codec.extraData.len == 24
    check w.numFrames().get == 44_100
    check w.packets.len == 11
    var total = 0'u64
    for p in w.packets:
      total += p.dur
    check total == 44_100
    check w.packets[^1].dur == 3140

  test "mono alac timing":
    let w = openMp4(readFileBytes(FixDir & "fix_alacmono.m4a"))
    check w.tracks[0].codec.channels.get.channelCount() == 1
    check w.numFrames().get == 5_513
    check w.packets.len == 2

  test "seek lands on containing packet":
    let w = openMp4(readFileBytes(FixDir & "fix_alacstereo.m4a"))
    let s = w.seek(seekToTimestamp(newTimestamp(20_000), 1))
    check s.actualTs.get <= 20_000
    check w.nextPacket().get.pts.get == s.actualTs.get
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999_999), 1))
      check false
    except AudioError as e:
      check e.kind == ekSeek

suite "alac decode fixtures":
  test "stereo alac in mp4 decodes bit-exact":
    let (got, w) = decodeAllAlacMp4(FixDir & "fix_alacstereo.m4a")
    check got[0].len == 44_100
    check got[1].len == 44_100
    discard w
    let refs = readRefS16(FixDir & "ref_alacstereo_dec.wav", 2)
    for i in 0 ..< refs[0].len:
      for p in 0 ..< 2:
        check got[p][i] == refs[p][i].int32 shl 16

  test "mono alac in mp4 decodes bit-exact":
    let (got, w) = decodeAllAlacMp4(FixDir & "fix_alacmono.m4a")
    check got[0].len == 5_513
    discard w
    let refs = readRefS16(FixDir & "ref_alacmono_dec.wav", 1)
    for i in 0 ..< refs[0].len:
      check got[0][i] == refs[0][i].int32 shl 16

  test "stereo alac in caf decodes bit-exact over valid frames":
    let (got, w) = decodeAllAlacCaf(FixDir & "fix_alacstereo.caf")
    check got[0].len == 44_100
    check w.numFrames().get == 44_100
    discard w
    let refs = readRefS16(FixDir & "ref_alacstereo_caf_dec.wav", 2)
    for i in 0 ..< refs[0].len:
      for p in 0 ..< 2:
        check got[p][i] == refs[p][i].int32 shl 16

  test "truncated packet fails cleanly":
    let w = openMp4(readFileBytes(FixDir & "fix_alacmono.m4a"))
    let dec = newAlacDecoder(w.tracks[0].codec)
    let pkt = w.nextPacket().get
    try:
      discard dec.decodePacket(newPacket(0, pkt.pts, pkt.dur,
        pkt.data[0 ..< pkt.data.len div 2]))
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "aiff demuxer":
  test "probe accepts aiff/aifc, rejects garbage":
    check probeAiff(readFileBytes(FixDir & "fix_aiffmono.aiff")) == 255
    check probeAiff(readFileBytes(FixDir & "fix_aiffc_sowt.aiff")) == 255
    check probeAiff(readFileBytes(FixDir & "fix_cafmono.caf")) == 0
    check probeAiff(@[0x00'u8, 0x01]) == 0

  test "mono aiff tracks, params and timing":
    let w = openAiff(readFileBytes(FixDir & "fix_aiffmono.aiff"))
    check w.trackCount() == 1
    check w.tracks[0].id == 0
    check w.tracks[0].codec.codec == CodecPcmS16Be
    check w.tracks[0].codec.sampleRate.get == 22_050
    check w.tracks[0].codec.channels.get.channelCount() == 1
    check w.numFrames().get == 11_025
    var total = 0'u64
    var n = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      total += pkt.get.dur.get
      inc n
    check total == 11_025
    check n == 10 # 9 x 1152 + 657

  test "aifc sowt maps to little-endian codec":
    let w = openAiff(readFileBytes(FixDir & "fix_aiffc_sowt.aiff"))
    check w.tracks[0].codec.codec == CodecPcmS16Le
    check w.numFrames().get == 11_025

  test "seek lands on packet boundary":
    let w = openAiff(readFileBytes(FixDir & "fix_aiffmono.aiff"))
    let s = w.seek(seekToTimestamp(newTimestamp(5_000), 0))
    check s.actualTs.get == 4_608 # aligned down to 1152
    check w.nextPacket().get.pts.get == s.actualTs.get
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999_999), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek
      check e.seekKind == skOutOfRange
    try:
      discard w.seek(seekToTimestamp(newTimestamp(0), 7))
      check false
    except AudioError as e:
      check e.kind == ekSeek

  test "missing common and truncated headers fail":
    try:
      discard openAiff(@[0x46'u8, 0x4f, 0x52, 0x4d, 0, 0, 0, 4,
        0x41, 0x49, 0x46, 0x46])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard openAiff(@[0x52'u8, 0x49, 0x46, 0x46, 0, 0, 0, 4,
        0x57, 0x41, 0x56, 0x45])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "aiff/caf decode fixtures":
  test "mono aiff decodes bit-exact":
    let w = openAiff(readFileBytes(FixDir & "fix_aiffmono.aiff"))
    registerPcm()
    let dec = newPcmDecoder(w.tracks[0].codec)
    var got = newSeq[int16]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got.add(s.s16.planes[0][i])
    let refs = readRefS16(FixDir & "ref_aiffmono_dec.wav", 1)
    check got.len == refs[0].len
    for i in 0 ..< refs[0].len:
      check got[i].int32 == refs[0][i].int32

  test "aifc sowt decodes bit-exact":
    let w = openAiff(readFileBytes(FixDir & "fix_aiffc_sowt.aiff"))
    registerPcm()
    let dec = newPcmDecoder(w.tracks[0].codec)
    var got = newSeq[int16]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got.add(s.s16.planes[0][i])
    let refs = readRefS16(FixDir & "ref_aiffc_sowt_dec.wav", 1)
    check got.len == refs[0].len
    for i in 0 ..< refs[0].len:
      check got[i].int32 == refs[0][i].int32

  test "mono caf pcm decodes bit-exact":
    let w = openCaf(readFileBytes(FixDir & "fix_cafmono.caf"))
    registerPcm()
    let dec = newPcmDecoder(w.tracks[0].codec)
    var got = newSeq[int16]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got.add(s.s16.planes[0][i])
    let refs = readRefS16(FixDir & "ref_cafmono_dec.wav", 1)
    check got.len == refs[0].len
    for i in 0 ..< refs[0].len:
      check got[i].int32 == refs[0][i].int32

suite "caf demuxer":
  test "probe accepts caff, rejects garbage":
    check probeCaf(readFileBytes(FixDir & "fix_cafmono.caf")) == 255
    check probeCaf(readFileBytes(FixDir & "fix_aiffmono.aiff")) == 0
    check probeCaf(@[0x00'u8, 0x01]) == 0

  test "mono caf pcm tracks, params and timing":
    let w = openCaf(readFileBytes(FixDir & "fix_cafmono.caf"))
    check w.trackCount() == 1
    check w.tracks[0].id == 0
    check w.tracks[0].codec.codec == CodecPcmS16Be
    check w.tracks[0].codec.sampleRate.get == 22_050
    check w.tracks[0].codec.channels.get.channelCount() == 1
    check w.numFrames().get == 11_025
    var total = 0'u64
    var n = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      total += pkt.get.dur.get
      inc n
    check total == 11_025
    check n == 10

  test "alac caf packet table timing":
    let w = openCaf(readFileBytes(FixDir & "fix_alacstereo.caf"))
    check w.tracks[0].codec.codec == CodecAlac
    check w.tracks[0].codec.extraData.len == 48
    check w.numFrames().get == 44_100
    check w.packets.len == 11
    check w.packets[0].frames == 4096
    var total = 0'u64
    for p in w.packets:
      total += p.frames.uint64
    check total == 45_056

  test "seek lands on containing packet":
    let w = openCaf(readFileBytes(FixDir & "fix_cafmono.caf"))
    let s = w.seek(seekToTimestamp(newTimestamp(5_000), 0))
    check s.actualTs.get == 4_608
    check w.nextPacket().get.pts.get == s.actualTs.get
    let wv = openCaf(readFileBytes(FixDir & "fix_alacstereo.caf"))
    let sv = wv.seek(seekToTimestamp(newTimestamp(20_000), 0))
    check sv.actualTs.get <= 20_000
    check wv.nextPacket().get.pts.get == sv.actualTs.get
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999_999), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek

  test "missing desc and bad magic fail":
    try:
      discard openCaf(@[0x63'u8, 0x61, 0x66, 0x66, 0, 1, 0, 0,
        0x64, 0x61, 0x74, 0x61, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard openCaf(@[0x52'u8, 0x49, 0x46, 0x46, 0, 0, 0, 4,
        0x57, 0x41, 0x56, 0x45])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
