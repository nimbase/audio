import std/math
import std/options
import unittest

import audio/audio
import audio/codecs
import audio/codecs/flac
import audio/codecs/mpa
import audio/codecs/aac
import audio/codecs/alac
import audio/codecs/pcm
import audio/codecs/vorbis
import audio/errors
import audio/formats
import audio/formats/mkv as mkvfmt
import audio/io
import audio/packet
import audio/units

const FixDir = "tests/fixtures/"

proc readFileBytes(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  for i, c in raw:
    result[i] = cast[uint8](c)

proc findSub(data, needle: openArray[uint8]): int =
  if needle.len == 0 or data.len < needle.len:
    return -1
  for i in 0 ..< data.len - needle.len + 1:
    var ok = true
    for j in 0 ..< needle.len:
      if data[i + j] != needle[j]:
        ok = false
        break
    if ok:
      return i
  -1

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

proc decodeF32(path: string): tuple[w: MkvReader, got: seq[seq[float64]]] =
  let w = openMkv(readFileBytes(path))
  let dec = makeAudioDecoder(w.tracks[0].codec)
  var got = @[newSeq[float64](), newSeq[float64]()]
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< 2:
      for i in 0 ..< s.framesOf():
        got[p].add(s.f32.planes[p][i])
  (w, got)

proc worstF32(got: seq[seq[float64]]; refs: seq[seq[int16]];
    off, count: int): float64 =
  for i in 0 ..< count:
    for p in 0 ..< 2:
      result = max(result,
        abs(got[p][off + i].float64 * 32768.0 - refs[p][i].float64))

suite "mkv container":
  test "probe accepts ebml, rejects other containers":
    check probeMkv(readFileBytes(FixDir & "fix_vorbis_stereo.mka")) == 255
    check probeMkv(readFileBytes(FixDir & "fix_mp3_stereo.mkv")) == 255
    check probeMkv(readFileBytes(FixDir & "fix_opus_stereo.webm")) == 255
    check probeMkv(readFileBytes(FixDir & "fix_aacstereo.m4a")) == 0
    check probeMkv(readFileBytes(FixDir & "fix_stereo.ogg")) == 0
    check probeMkv(@[0x52'u8, 0x49, 0x46, 0x46]) == 0
    check probeMkv(@[0x00'u8, 0x01]) == 0

  test "truncated header fails to decode":
    try:
      discard openMkv(readFileBytes(FixDir & "fix_vorbis_stereo.mka")[0 ..< 20])
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "wrong doctype is unsupported":
    var data = readFileBytes(FixDir & "fix_vorbis_stereo.mka")
    let idx = findSub(data, @[0x6d'u8, 0x61, 0x74, 0x72, 0x6f, 0x73, 0x6b, 0x61])
    check idx >= 0
    data[idx] = 0x58'u8 # "matroska" -> "Xatroska"
    try:
      discard openMkv(data)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

  test "unknown audio codec is unsupported":
    var data = readFileBytes(FixDir & "fix_vorbis_stereo.mka")
    let idx = findSub(data, @[0x41'u8, 0x5f, 0x56, 0x4f, 0x52, 0x42, 0x49, 0x53])
    check idx >= 0 # "A_VORBIS"
    data[idx + 2] = 0x58'u8
    data[idx + 3] = 0x59'u8
    data[idx + 4] = 0x5au8
    try:
      discard openMkv(data)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "mkv demuxer":
  test "vorbis stereo tracks, params and timing":
    let w = openMkv(readFileBytes(FixDir & "fix_vorbis_stereo.mka"))
    check w.trackCount() == 1
    check w.tracks[0].id == 1
    check w.tracks[0].codec.codec == CodecVorbis
    check w.tracks[0].codec.sampleRate.get == 44_100
    check w.tracks[0].codec.channels.get.channelCount() == 2
    check w.tracks[0].codec.extraData.len == 3862
    check w.packets.len == 45
    check w.packets[0].pts == -3 # codec-delay preroll is emitted
    check w.cues.len == 1
    check w.tracks[0].timeBase.get.numer == 1_000_000
    var total = 0'u64
    for p in w.packets:
      total += p.dur
    check total == 0 # files carry no block durations; points only

  test "vorbis mono params":
    let w = openMkv(readFileBytes(FixDir & "fix_vorbis_mono.mka"))
    check w.tracks[0].codec.codec == CodecVorbis
    check w.tracks[0].codec.sampleRate.get == 22_050
    check w.tracks[0].codec.channels.get.channelCount() == 1
    check w.packets.len == 23

  test "flac stereo params":
    let w = openMkv(readFileBytes(FixDir & "fix_flac_stereo.mka"))
    check w.tracks[0].codec.codec == CodecFlac
    check w.tracks[0].codec.sampleRate.get == 44_100
    check w.tracks[0].codec.extraData.len == 34
    check w.packets.len == 10

  test "mp3 params and durations":
    let w = openMkv(readFileBytes(FixDir & "fix_mp3_stereo.mkv"))
    check w.tracks[0].codec.codec == CodecMp3
    check w.packets.len == 40
    check w.packets[0].pts == -25
    check w.packets[0].dur == 26
    var total = 0'u64
    for p in w.packets:
      total += p.dur
    check total == 1020
    check w.packets[^1].dur == 6

  test "aac params and priming packet":
    let w = openMkv(readFileBytes(FixDir & "fix_aac_stereo.mkv"))
    check w.tracks[0].codec.codec == CodecAac
    check w.tracks[0].codec.extraData.len == 5
    check w.packets.len == 45
    check w.packets[0].pts == -23

  test "alac params":
    let w = openMkv(readFileBytes(FixDir & "fix_alac_stereo.mka"))
    check w.tracks[0].codec.codec == CodecAlac
    check w.tracks[0].codec.extraData.len == 24
    check w.packets.len == 11

  test "pcm durations are synthesized from byte counts":
    let w = openMkv(readFileBytes(FixDir & "fix_pcm_stereo.mkv"))
    check w.tracks[0].codec.codec == CodecPcmS16Le
    check w.packets.len == 11
    check w.packets[0].dur == 93
    var total = 0'u64
    for p in w.packets:
      total += p.dur
    check total == 1001

  test "opus demuxes without a registered decoder":
    let w = openMkv(readFileBytes(FixDir & "fix_opus_stereo.webm"))
    check w.tracks[0].codec.codec == CodecOpus
    check w.tracks[0].codec.sampleRate.get == 48_000
    check w.packets.len == 51
    try:
      discard makeAudioDecoder(w.tracks[0].codec)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

  test "seek lands on containing packet":
    let w = openMkv(readFileBytes(FixDir & "fix_pcm_stereo.mkv"))
    let s = w.seek(seekToTimestamp(newTimestamp(500), 1))
    check s.actualTs.get == 464 # file timestamps round: .., 372, 464, 557
    check w.nextPacket().get.pts.get == s.actualTs.get
    let wv = openMkv(readFileBytes(FixDir & "fix_vorbis_stereo.mka"))
    let sv = wv.seek(seekToTimestamp(newTimestamp(60), 1))
    check sv.actualTs.get == 60
    check wv.nextPacket().get.pts.get == sv.actualTs.get
    discard w.seek(seekToTime(fromMillis(100)))
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
      check e.seekKind == skInvalidTrack
    try:
      discard w.seek(seekToTimestamp(newTimestamp(-5), 1))
      check false
    except AudioError as e:
      check e.kind == ekSeek

suite "mkv decode fixtures":
  test "vorbis stereo matches ffmpeg within 2 LSB":
    registerVorbis()
    let (w, got) = decodeF32(FixDir & "fix_vorbis_stereo.mka")
    check got[0].len == 44_608
    discard w
    let refs = readRefS16(FixDir & "ref_vorbis_stereo_mkv_dec.wav", 2)
    check worstF32(got, refs, 0, refs[0].len) <= 2.0

  test "vorbis mono matches ffmpeg within 2 LSB":
    registerVorbis()
    let w = openMkv(readFileBytes(FixDir & "fix_vorbis_mono.mka"))
    let dec = makeAudioDecoder(w.tracks[0].codec)
    var got = newSeq[float64]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got.add(s.f32.planes[0][i])
    let refs = readRefS16(FixDir & "ref_vorbis_mono_mkv_dec.wav", 1)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      worst = max(worst, abs(got[i] * 32768.0 - refs[0][i].float64))
    check worst <= 2.0

  test "mp3 matches ffmpeg within 2 LSB past 1105 delay":
    registerMpa()
    let (w, got) = decodeF32(FixDir & "fix_mp3_stereo.mkv")
    check got[0].len == 46_080
    discard w
    let refs = readRefS16(FixDir & "ref_mp3_stereo_mkv_dec.wav", 2)
    check worstF32(got, refs, 1105, refs[0].len) <= 2.0

  test "aac matches ffmpeg within 2 LSB past 1024 priming":
    registerAac()
    let (w, got) = decodeF32(FixDir & "fix_aac_stereo.mkv")
    check got[0].len == 46_080
    discard w
    let refs = readRefS16(FixDir & "ref_aac_stereo_mkv_dec.wav", 2)
    check worstF32(got, refs, 1024, refs[0].len) <= 2.0

  test "flac decodes bit-exact":
    registerFlac()
    let w = openMkv(readFileBytes(FixDir & "fix_flac_stereo.mka"))
    let dec = makeAudioDecoder(w.tracks[0].codec)
    var got0 = newSeq[int32]()
    var got1 = newSeq[int32]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got0.add(s.s32.planes[0][i])
        got1.add(s.s32.planes[1][i])
    check got0.len == 44_100
    let refs = readRefS16(FixDir & "ref_flac_stereo_mkv_dec.wav", 2)
    for i in 0 ..< refs[0].len:
      check got0[i] == refs[0][i].int32 shl 16
      check got1[i] == refs[1][i].int32 shl 16

  test "pcm decodes bit-exact":
    registerPcm()
    let w = openMkv(readFileBytes(FixDir & "fix_pcm_stereo.mkv"))
    let dec = makeAudioDecoder(w.tracks[0].codec)
    var got0 = newSeq[int16]()
    var got1 = newSeq[int16]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got0.add(s.s16.planes[0][i])
        got1.add(s.s16.planes[1][i])
    check got0.len == 44_100
    let refs = readRefS16(FixDir & "ref_pcm_stereo_mkv_dec.wav", 2)
    for i in 0 ..< refs[0].len:
      check got0[i] == refs[0][i]
      check got1[i] == refs[1][i]

  test "alac decodes bit-exact":
    registerAlac()
    let w = openMkv(readFileBytes(FixDir & "fix_alac_stereo.mka"))
    let dec = makeAudioDecoder(w.tracks[0].codec)
    var got0 = newSeq[int32]()
    var got1 = newSeq[int32]()
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        got0.add(s.s32.planes[0][i])
        got1.add(s.s32.planes[1][i])
    check got0.len == 44_100
    let refs = readRefS16(FixDir & "ref_alac_stereo_mkv_dec.wav", 2)
    for i in 0 ..< refs[0].len:
      check got0[i] == refs[0][i].int32 shl 16
      check got1[i] == refs[1][i].int32 shl 16
