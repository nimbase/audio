## WAV-fixture conversion coverage, streaming style: haus_105bpm.wav
## (24-bit stereo music) through every encoder — WAV/FLAC bit-exact,
## ADPCM/MP3 within measured tolerance, AAC structural until Step C.
##
## No `readFile`: the fixture stays mapped (`openWavMapped`), packets
## decode from views (`decodePacketView`, zero copies), samples land in
## single preallocated buffers, and MP3 is fed by chunked pushes
## through one reused staging buffer. A `BytePool` rides along the
## assembly loop proving flat reuse; contiguous WAV packets decode
## straight from the mapping per `source.nim` guidance.
##
## The lossy gates use a 0.5 s window (23040 frames = 20 MP3 frames);
## lossless paths convert the full 9.1 s file.

import std/math
import std/options
import unittest

import audio/audio
import audio/checksum
import audio/codecs
import audio/codecs/aac
import audio/codecs/aacenc
import audio/codecs/adpcm
import audio/codecs/flac
import audio/codecs/mpa
import audio/codecs/mpaenc
import audio/codecs/pcm
import audio/errors
import audio/formats
import audio/formats/aac as aacfmt
import audio/formats/flac as flacfmt
import audio/formats/mpa as mpafmt
import audio/formats/wav
import audio/io
import audio/packet
import audio/source
import audio/units

const HausPath = "tests/fixtures/haus_105bpm.wav"
const WinFrames = 23_040
const Mp3Chunk = 11_520

proc decodeRefMapped(): AudioSamples =
  ## Full fixture into one preallocated s24 buffer, no file copy.
  let w = openWavMapped(HausPath)
  try:
    check w.params.codec == CodecPcmS24Le
    check w.params.sampleRate.get == 44_100
    let total = w.numFrames().get.int
    check total == 403_200
    result = newAudioSamples(sfS24, newAudioSpec(44_100, ChStereo), total)
    let dec = newPcmDecoder(w.params)
    var pool = initStreamPool()
    let cap0 = pool.cap
    var off = 0
    while true:
      let v = w.nextPacketView()
      if v.isNone:
        break
      loadPacketInto(pool, v.get) # bounded scratch, stays flat
      let s = dec.decodePacketView(v.get) # zero-copy from mapping
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          result.s24.planes[p][off + i] = s.s24.planes[p][i]
      off += s.framesOf()
    result.s24.numFrames = off
    check pool.cap == cap0
    check off == total
  finally:
    w.close()

proc windowS16Mapped(): AudioSamples =
  ## First 0.5 s as s16 in one preallocated buffer, mapped source.
  let w = openWavMapped(HausPath)
  try:
    result = newAudioSamples(sfS16, newAudioSpec(44_100, ChStereo),
      WinFrames)
    let dec = newPcmDecoder(w.params)
    var off = 0
    while off < WinFrames:
      let v = w.nextPacketView()
      if v.isNone:
        break
      let s = dec.decodePacketView(v.get)
      let take = min(s.framesOf(), WinFrames - off)
      for p in 0 ..< 2:
        for i in 0 ..< take:
          let sv = round(s.s24.planes[p][i].float / 256.0)
          result.s16.planes[p][off + i] =
            clamp(sv, -32768.0, 32767.0).int16
      off += take
    result.s16.numFrames = off
    check off == WinFrames
  finally:
    w.close()

proc decodeAllAdpcm(bytes: seq[uint8]; n: int;
    src: AudioSamples): tuple[worst: int32; mean: float] =
  let w = openWav(bytes)
  let dec = newAdpcmDecoder(w.params)
  var worst = 0'i32
  var sum = 0'i64
  var cnt = 0'i64
  var got = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    for i in 0 ..< s.framesOf():
      if got + i < n:
        for p in 0 ..< 2:
          let e = abs((s.s32.planes[p][i] shr 16) -
            src.s16.planes[p][got + i].int32)
          worst = max(worst, e)
          sum += e
          inc cnt
    got += s.framesOf()
  (worst, sum.float / max(cnt, 1).float)

proc encodeMp3Streamed(src: AudioSamples; o: Mp3EncoderOptions): seq[uint8] =
  ## Chunked pushes through one reused staging buffer (bounded memory).
  let enc = newMp3Encoder(o)
  var staging = newSeq[int16](Mp3Chunk * 2)
  var off = 0
  let n = src.framesOf()
  while off < n:
    let take = min(Mp3Chunk, n - off)
    for i in 0 ..< take:
      staging[i * 2] = src.s16.planes[0][off + i]
      staging[i * 2 + 1] = src.s16.planes[1][off + i]
    enc.pushSamplesI16(staging.toOpenArray(0, take * 2 - 1))
    off += take
  enc.finishEncoder()

proc decodeAllMp3F32(bytes: seq[uint8]): seq[seq[float32]] =
  let w = mpafmt.openMpa(bytes)
  let dec = newMpaDecoder(w.tracks[0].codec,
    AudioDecoderOptions(gapless: true, verify: false))
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc psnrS16(src: AudioSamples; got: seq[seq[float32]]): float64 =
  let n = src.framesOf()
  var se = 0.0
  for p in 0 ..< 2:
    for i in 0 ..< min(n, got[p].len):
      let a = src.s16.planes[p][i].float / 32768.0
      let d = got[p][i].float - a
      se += d * d
  10.0 * log10(1.0 / max(se / (n * 2).float, 1e-18))

suite "haus wav conversion":
  test "fixture loads mapped as 24-bit stereo":
    let w = openWavMapped(HausPath)
    try:
      check w.params.codec == CodecPcmS24Le
      check w.numFrames().get == 403_200
    finally:
      w.close()

  test "wav roundtrip is sample-exact":
    let reff = decodeRefMapped()
    check reff.format == sfS24
    check reff.framesOf() == 403_200
    let bytes = encodeWav(reff, 44_100)
    check probeWav(bytes) == 255
    check bytes.len == 2_419_244
    let w = openWav(bytes)
    let dec = newPcmDecoder(w.params)
    var off = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          check s.s24.planes[p][i] == reff.s24.planes[p][off + i]
      off += s.framesOf()
    check off == 403_200

  test "flac roundtrip is sample-exact":
    let reff = decodeRefMapped()
    let bytes = encodeFlacStream(reff, 44_100)
    check bytes.len < reff.framesOf() * 2 * 3
    let w = openFlac(bytes)
    let dec = newFlacDecoder(w.params,
      AudioDecoderOptions(gapless: true, verify: false))
    var total = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        for p in 0 ..< 2:
          check (s.s32.planes[p][i] shr 8) == reff.s24.planes[p][total + i]
      total += s.framesOf()
    check total == reff.framesOf()

  test "adpcm ms music within tolerance":
    let src = windowS16Mapped()
    let bytes = encodeWav(src, 44_100, CodecAdpcmMs)
    check probeWav(bytes) == 255
    let (worst, mean) = decodeAllAdpcm(bytes, WinFrames, src)
    echo "haus ms maxerr=", worst, " mean=", mean
    check worst <= 12_000
    check mean <= 100.0

  test "adpcm ima music within tolerance":
    let src = windowS16Mapped()
    let bytes = encodeWav(src, 44_100, CodecAdpcmImaWav)
    check probeWav(bytes) == 255
    let (worst, mean) = decodeAllAdpcm(bytes, WinFrames, src)
    echo "haus ima maxerr=", worst, " mean=", mean
    check worst <= 12_000
    check mean <= 100.0

  test "mp3 music gapless length-exact with sane psnr":
    let src = windowS16Mapped()
    var o = defaultMp3EncoderOptions(128, 44_100,
      MpaMode(kind: mmStereo))
    o.xing = true
    o.gapless = true
    let bytes = encodeMp3Streamed(src, o)
    check probeMpa(bytes) == 255
    let got = decodeAllMp3F32(bytes)
    check got[0].len == WinFrames
    check got[1].len == WinFrames
    let psnr = psnrS16(src, got)
    echo "haus mp3 psnr=", psnr
    check psnr > 25.0

  test "aac converts structurally until step C":
    # Skeleton emits silence; the content gate arrives with the
    # Step C signal path. Structural gates only here.
    let src = windowS16Mapped()
    let bytes = encodeAacStream(src,
      defaultAacEncoderOptions(44_100, 2))
    check probeAac(bytes) == 255
    let w = openAac(bytes)
    let dec = newAacDecoder(w.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var frames = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      frames += dec.decodePacket(pkt.get).framesOf()
    check frames == ((WinFrames + 1023) div 1024) * 1024
