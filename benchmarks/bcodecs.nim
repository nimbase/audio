## Multi-format encode/decode benchmark (in-binary only).
##
## Build (release, reproducible):
##   clue build benchmarks/bcodecs.nim --out:/tmp/bcodecs --release
## Run (from the package root):
##   /tmp/bcodecs
##
## Deliberately no ffmpeg/process comparison: this measures our code
## in-process (best-of-N wall time as audio-seconds per wall-second,
## plus output size, a quality metric, and process Max RSS). External
## tool numbers would mix in spawn/startup/file I/O and say nothing
## about the codec itself.

import std/math
import std/monotimes
import std/options
import std/strformat
import std/times

when defined(posix):
  import std/posix

import audio/audio
import audio/checksum
import audio/codecs
import audio/codecs/aac
import audio/codecs/aacenc
import audio/codecs/adpcm
import audio/codecs/alac
import audio/codecs/flac
import audio/codecs/mpa
import audio/codecs/mpaenc
import audio/codecs/pcm
import audio/codecs/vorbis
import audio/errors
import audio/formats
import audio/formats/aac as aacfmt
import audio/formats/aiff
import audio/formats/caf
import audio/formats/flac as flacfmt
import audio/formats/mp4 as mp4fmt
import audio/formats/mpa as mpafmt
import audio/formats/ogg as oggfmt
import audio/formats/wav
import audio/io
import audio/packet
import audio/source
import audio/units

proc peakRssMiB(): float64 =
  ## Process Max RSS high-water mark in MiB. Cumulative across the run:
  ## each cell reports the mark after its reps, so later cells include
  ## earlier peaks (run order effects apply).
  when defined(posix):
    var u: Rusage
    if getrusage(RUSAGE_SELF, u.addr) == 0:
      when defined(macosx):
        return u.ru_maxrss.float64 / (1024.0 * 1024.0)
      else:
        return u.ru_maxrss.float64 / 1024.0
    return 0.0
  else:
    return 0.0

proc readFileBytes(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  for i, c in raw:
    result[i] = cast[uint8](c)

proc sineStereo(n: int; fL, fR, amp: float; rate = 44_100): AudioSamples =
  let spec = newAudioSpec(rate.uint32, ChStereo)
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    result.s16.planes[0][i] = (amp * 32767.0 *
      sin(2.0 * PI * fL * i.float / rate.float)).int16
    result.s16.planes[1][i] = (amp * 32767.0 *
      sin(2.0 * PI * fR * i.float / rate.float)).int16
  result.s16.numFrames = n

proc noiseStereo(n: int; amp: float; rate = 44_100;
    seed = 0x12345678'u32): AudioSamples =
  let spec = newAudioSpec(rate.uint32, ChStereo)
  result = newAudioSamples(sfS16, spec, n)
  var s = seed
  result.s16.renderWith(n, i):
    s = s * 1664525'u32 + 1013904223'u32
    result.s16.planes[0][i] =
      ((((s shr 16) and 0xFFFF'u32).int32 - 32768).float * amp).int16
    s = s * 1664525'u32 + 1013904223'u32
    result.s16.planes[1][i] =
      ((((s shr 16) and 0xFFFF'u32).int32 - 32768).float * amp).int16
  result.s16.numFrames = n

const GaplessOpts = AudioDecoderOptions(gapless: true, verify: false)

# ------------------------------------------------------------ decoders ---

proc decWav(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openWav(b)
  let dec = newPcmDecoder(w.params)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.params.sampleRate.get)

proc decAdpcm(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openWav(b)
  let dec = newAdpcmDecoder(w.params)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.params.sampleRate.get)

proc decFlac(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openFlac(b)
  let dec = newFlacDecoder(w.params, GaplessOpts)
  var f = 0
  var rate = 44_100'u32
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    let s = dec.decodePacket(pkt.get)
    f += s.framesOf()
    rate = s.specOf().rate
  (f, rate)

proc decMp3(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = mpafmt.openMpa(b)
  let dec = newMpaDecoder(w.tracks[0].codec, GaplessOpts)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.tracks[0].codec.sampleRate.get)

proc decAacAdts(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openAac(b)
  let dec = newAacDecoder(w.tracks[0].codec, GaplessOpts)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.tracks[0].codec.sampleRate.get)

proc decOggVorbis(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openOgg(b)
  let dec = newVorbisDecoder(w.tracks[0].codec, GaplessOpts)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.tracks[0].codec.sampleRate.get)

proc decMp4Aac(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openMp4(b)
  let dec = newAacDecoder(w.tracks[0].codec, GaplessOpts)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.tracks[0].codec.sampleRate.get)

proc decMp4Alac(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openMp4(b)
  let dec = newAlacDecoder(w.tracks[0].codec)
  var f = 0
  var rate = 44_100'u32
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    let s = dec.decodePacket(pkt.get)
    f += s.framesOf()
    rate = s.specOf().rate
  (f, rate)

proc decAiff(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openAiff(b)
  let dec = newPcmDecoder(w.tracks[0].codec)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.tracks[0].codec.sampleRate.get)

proc decCaf(b: seq[uint8]): tuple[frames: int; rate: uint32] =
  let w = openCaf(b)
  let dec = newPcmDecoder(w.tracks[0].codec)
  var f = 0
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    f += dec.decodePacket(pkt.get).framesOf()
  (f, w.tracks[0].codec.sampleRate.get)

# ------------------------------------------------------------ quality ---

proc psnrVsS16(src: AudioSamples;
    got: seq[seq[float32]]; drop = 0): float64 =
  ## PSNR of `got` vs `src`, skipping the first `drop` decoded frames
  ## (AAC carries a 1024-sample priming frame; MP3 arrives gapless
  ## trimmed so drop stays 0 there).
  let n = src.framesOf()
  let nch = src.specOf().channels.channelCount()
  var se = 0.0
  var cnt = 0
  for p in 0 ..< min(nch, got.len):
    for i in 0 ..< min(n, got[p].len - drop):
      let a = src.s16.planes[p][i].float64 / 32768.0
      let d = got[p][drop + i].float64 - a
      se += d * d
      inc cnt
  10.0 * log10(1.0 / max(se / max(cnt, 1).float64, 1e-18))

proc decodeF32Mp3(b: seq[uint8]): seq[seq[float32]] =
  let w = mpafmt.openMpa(b)
  let dec = newMpaDecoder(w.tracks[0].codec, GaplessOpts)
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc decodeF32Aac(b: seq[uint8]): seq[seq[float32]] =
  let w = openAac(b)
  let dec = newAacDecoder(w.tracks[0].codec, GaplessOpts)
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc maxErrAdpcm(src: AudioSamples; b: seq[uint8]): tuple[w, m: int] =
  let w = openWav(b)
  let dec = newAdpcmDecoder(w.params)
  var worst = 0
  var sum = 0'i64
  var cnt = 0'i64
  var got = 0
  let n = src.framesOf()
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
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
  (worst, (sum div max(cnt, 1)).int)

proc exactWav(src: AudioSamples; b: seq[uint8]): bool =
  let w = openWav(b)
  let dec = newPcmDecoder(w.params)
  var got = 0
  let n = src.framesOf()
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone: break
    let s = dec.decodePacket(pkt.get)
    for i in 0 ..< s.framesOf():
      if got + i >= n: return false
      for p in 0 ..< 2:
        if s.s16.planes[p][i] != src.s16.planes[p][got + i]:
          return false
    got += s.framesOf()
  got == n

# ------------------------------------------------------------ cells ---

proc benchEncode(audioSec: float64;
    encode: proc(): seq[uint8]): tuple[b: seq[uint8]; x, rss: float64] =
  var ob: seq[uint8] = @[]
  var best = 0.0
  for rep in 0 ..< 3:
    let t0 = getMonoTime()
    ob = encode()
    let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
    let x = audioSec / max(dt, 1e-9)
    if rep == 0 or x > best:
      best = x
  (ob, best, peakRssMiB())

proc benchDecode(b: seq[uint8];
    decode: proc(b: seq[uint8]): tuple[frames: int; rate: uint32]):
    tuple[x, rss: float64; frames: int] =
  let (frames, rate) = decode(b)
  doAssert frames > 0
  let audioSec = frames.float64 / rate.float64
  var best = 0.0
  for rep in 0 ..< 10:
    let t0 = getMonoTime()
    let (f, _) = decode(b)
    doAssert f == frames
    let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
    let x = audioSec / max(dt, 1e-9)
    if rep == 0 or x > best:
      best = x
  (best, peakRssMiB(), frames)

proc main() =
  echo fmt"nim {NimVersion}  hostOS={hostOS}  cpu={hostCPU}"
  let sine2 = sineStereo(88_200, 440.0, 660.0, 0.4)
  let noise1 = noiseStereo(44_100, 0.4)
  let sine1 = sineStereo(44_100, 440.0, 660.0, 0.4)

  echo "--- encode: wav/adpcm ---"
  block:
    let audioSec = sine2.framesOf().float64 / 44100.0
    let (b, x, rss) = benchEncode(audioSec,
      proc(): seq[uint8] = encodeWav(sine2, 44_100))
    let q = if exactWav(sine2, b): "exact" else: "MISMATCH"
    echo fmt"wav16   {x:7.1f}x {b.len:>8}B {q} rss {rss:6.1f}MiB"
    let (dx, drss, _) = benchDecode(b, decWav)
    echo fmt"dec wav16        {dx:7.1f}x rss {drss:6.1f}MiB"
  for (nm, codec) in [("ms", CodecAdpcmMs), ("ima", CodecAdpcmImaWav)]:
    block:
      let audioSec = sine2.framesOf().float64 / 44100.0
      let c = codec
      let (b, x, rss) = benchEncode(audioSec,
        proc(): seq[uint8] = encodeWav(sine2, 44_100, c))
      let (w, m) = maxErrAdpcm(sine2, b)
      echo fmt"adpcm-{nm:<4} {x:7.1f}x {b.len:>8}B worst={w} mean={m} rss {rss:6.1f}MiB"
      let (dx, drss, _) = benchDecode(b, decAdpcm)
      echo fmt"dec adpcm-{nm:<4}     {dx:7.1f}x rss {drss:6.1f}MiB"

  echo "--- encode: flac ---"
  for (nm, src) in [("sine2", sine2), ("noise1", noise1)]:
    block:
      let audioSec = src.framesOf().float64 / 44100.0
      let s = src
      let (b, x, rss) = benchEncode(audioSec,
        proc(): seq[uint8] = encodeFlacStream(s, 44_100))
      let (f, _) = decFlac(b)
      let q = if f == src.framesOf(): "exact-frames" else: "MISMATCH"
      echo fmt"flac-{nm:<6} {x:7.1f}x {b.len:>8}B {q} rss {rss:6.1f}MiB"
      let (dx, drss, _) = benchDecode(b, decFlac)
      echo fmt"dec flac-{nm:<6}     {dx:7.1f}x rss {drss:6.1f}MiB"

  echo "--- encode: mp3 128k gapless ---"
  for (nm, src) in [("sine2", sine2), ("noise1", noise1)]:
    block:
      let audioSec = src.framesOf().float64 / 44100.0
      let s = src
      let (b, x, rss) = benchEncode(audioSec,
        proc(): seq[uint8] =
          var o = defaultMp3EncoderOptions(128, 44_100,
            MpaMode(kind: mmStereo))
          o.xing = true
          o.gapless = true
          encodeMp3Stream(s, o))
      let q = psnrVsS16(src, decodeF32Mp3(b))
      echo fmt"mp3-{nm:<6} {x:7.1f}x {b.len:>8}B psnr {q:5.1f}dB rss {rss:6.1f}MiB"
      let (dx, drss, _) = benchDecode(b, decMp3)
      echo fmt"dec mp3-{nm:<6}     {dx:7.1f}x rss {drss:6.1f}MiB"

  echo "--- encode: aac 128k ---"
  for (nm, src) in [("sine1", sine1), ("noise1", noise1)]:
    block:
      let audioSec = src.framesOf().float64 / 44100.0
      let s = src
      let (b, x, rss) = benchEncode(audioSec,
        proc(): seq[uint8] =
          encodeAacStream(s, defaultAacEncoderOptions(44_100, 2)))
      let q = psnrVsS16(src, decodeF32Aac(b), 1024)
      echo fmt"aac-{nm:<6} {x:7.1f}x {b.len:>8}B psnr {q:5.1f}dB rss {rss:6.1f}MiB"
      let (dx, drss, _) = benchDecode(b, decAacAdts)
      echo fmt"dec aac-{nm:<6}     {dx:7.1f}x rss {drss:6.1f}MiB"

  echo "--- decode: repo fixtures (decode-only formats) ---"
  for (nm, path, decode) in
      [("vorbis", "tests/fixtures/fix_stereo.ogg", decOggVorbis),
       ("alac", "tests/fixtures/fix_alacstereo.m4a", decMp4Alac),
       ("aac-mp4", "tests/fixtures/fix_aacstereo.m4a", decMp4Aac),
       ("aiff", "tests/fixtures/fix_aiffmono.aiff", decAiff),
       ("caf", "tests/fixtures/fix_cafmono.caf", decCaf)]:
    let (dx, drss, _) = benchDecode(readFileBytes(path), decode)
    echo fmt"dec {nm:<7}        {dx:7.1f}x rss {drss:6.1f}MiB"

when isMainModule:
  main()
