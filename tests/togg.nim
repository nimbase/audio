import std/options
import std/strutils
import unittest

import audio/audio
import audio/codecs
import audio/codecs/vorbis
import audio/errors
import audio/formats
import audio/formats/ogg as oggfmt
import audio/io
import audio/packet
import audio/units

const
  FixDir = "tests/fixtures/"

proc readFileBytes(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  for i, c in raw:
    result[i] = cast[uint8](c)

proc readRefS16(path: string; nch: int): seq[seq[int16]] =
  ## Reads the `data` chunk of a 16-bit WAV fixture.
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

proc decodeAllOgg(path: string): tuple[got: seq[seq[float32]],
    w: OggReader, dec: VorbisDecoder] =
  let bytes = readFileBytes(path)
  let w = openOgg(bytes)
  let dec = newVorbisDecoder(w.tracks[0].codec,
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
  (got, w, dec)

suite "ogg demuxer":
  test "probe accepts ogg, rejects garbage":
    check probeOgg(readFileBytes(FixDir & "fix_stereo.ogg")) == 255
    check probeOgg(@[0x52'u8, 0x49, 0x46, 0x46]) == 0
    check probeOgg(@[0x00'u8, 0x01]) == 0

  test "open tracks, params and packet timing":
    let bytes = readFileBytes(FixDir & "fix_stereo.ogg")
    let w = openOgg(bytes)
    check w.trackCount() == 1
    check w.tracks[0].codec.codec == CodecVorbis
    check w.tracks[0].codec.sampleRate.get == 44_100
    check w.tracks[0].codec.channels.get.channelCount() == 2
    # Granule total is the full 44100 frames; 128 leading delay frames
    # are marked as trimStart, leaving 43972 valid frames.
    check w.numFrames().get == 44_100'u64
    # Packet durations sum to the granule total (44100); the 128-frame
    # start delay is carried as trimStart on the first packet.
    var total = 0'u64
    var trims = 0'u64
    var prevEnd = 0'i64
    var n = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let p = pkt.get
      check p.pts.get == prevEnd
      prevEnd = p.pts.get + cast[int64](p.dur.get)
      total += p.dur.get
      trims += p.trimStart.get
      inc n
    check n == 45
    check total == 43_972'u64 + 128'u64
    check trims == 128'u64
    check total - trims == 43_972'u64
    check w.nextPacket().isNone

  test "vorbis comment propagates":
    let bytes = readFileBytes(FixDir & "fix_stereo.ogg")
    let w = openOgg(bytes)
    check w.metadata.revisions.len == 1
    var seenTitle = false
    var seenArtist = false
    for t in w.metadata.revisions[0].tags:
      if t.key.toUpperAscii() == "TITLE" and t.value.str == "SineTest":
        seenTitle = true
      if t.key.toUpperAscii() == "ARTIST" and t.value.str == "openAudio":
        seenArtist = true
    check seenTitle
    check seenArtist

  test "seek lands on containing packet":
    let bytes = readFileBytes(FixDir & "fix_stereo.ogg")
    let w = openOgg(bytes)
    let id = w.tracks[0].id
    let s = w.seek(seekToTimestamp(newTimestamp(20_000), id))
    check s.actualTs.get <= 20_000
    check w.nextPacket().get.pts.get == s.actualTs.get
    discard w.seek(seekToTime(fromMillis(100)))
    try:
      discard w.seek(seekToTimestamp(newTimestamp(-5), id))
      check false
    except AudioError as e:
      check e.kind == ekSeek
    try:
      discard w.seek(seekToTimestamp(newTimestamp(99_999_999), id))
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
      discard openOgg(@[0x52'u8, 0x49, 0x46, 0x46])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    let good = readFileBytes(FixDir & "fix_mono.ogg")
    try:
      discard openOgg(good[0 ..< 20])
      check false
    except AudioError:
      check true

suite "vorbis decode fixtures":
  test "mono matches ffmpeg within 2 LSB":
    let (got, w, dec) = decodeAllOgg(FixDir & "fix_mono.ogg")
    check dec.ident.nChannels == 1
    check w.numFrames().get == 11_025
    let bound = w.tracks[0].numFrames.get
    # Gapless trims the 256-frame start delay; valid span is 10769.
    check got[0].len == 10_769
    check bound - got[0].len.uint64 == 256
    let refs = readRefS16(FixDir & "ref_mono_dec.wav", 1)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      worst = max(worst,
        abs(got[0][i].float64 * 32768.0 - refs[0][i].float64))
    check worst <= 2.0

  test "stereo matches ffmpeg within 2 LSB":
    let (got, w, dec) = decodeAllOgg(FixDir & "fix_stereo.ogg")
    check dec.ident.nChannels == 2
    check got[0].len == 43_972
    check got[1].len == 43_972
    check w.numFrames().get == 44_100
    let refs = readRefS16(FixDir & "ref_stereo_dec.wav", 2)
    var worst = 0.0
    for i in 0 ..< refs[0].len:
      for p in 0 ..< 2:
        worst = max(worst,
          abs(got[p][i].float64 * 32768.0 - refs[p][i].float64))
    check worst <= 2.0
