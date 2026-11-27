## Multi-format encode/decode benchmark + ffmpeg comparison.
##
## Build (release, reproducible):
##   clue build benchmarks/bcodecs.nim --out:/tmp/bcodecs --release
## Run (from the package root; needs `ffmpeg` with libmp3lame on PATH
## for the `ff` columns, else those cells report n/a):
##   /tmp/bcodecs
##
## Encode cells: best-of-3 ours + best-of-3 ffmpeg at the same setting,
## output size, and a quality metric (exact / maxErr / PSNR, each stream
## decoded with our decoder). Decode cells: best-of-10 ours + best-of-3
## `ffmpeg -f null -` on our encoded bytes and on repo fixtures for the
## decode-only formats. MP3 preset detail lives in `bmp3.nim`; this file
## compares formats, not presets.

import std/math
import std/monotimes
import std/options
import std/os
import std/osproc
import std/strformat
import std/times

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

proc readFileBytes(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  for i, c in raw:
    result[i] = cast[uint8](c)

proc writeBytes(path: string; b: seq[uint8]) =
  writeFile(path, cast[string](b))

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

proc ffBin(): string =
  findExe("ffmpeg")

proc ffEncode(wavPath, outPath, codecArgs: string): bool =
  let code = execCmd(ffBin() & " -y -v error -i " & wavPath & " " &
    codecArgs & " " & outPath)
  code == 0 and fileExists(outPath)

proc ffDecodeSecs(path: string): float64 =
  let t0 = getMonoTime()
  let code = execCmd(ffBin() & " -v error -i " & path & " -f null -")
  let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
  if code != 0: -1.0 else: dt

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
  ## Decodes an ADPCM wav with our decoder; returns worst/mean s16 LSB
  ## error, or (-1, -1) when the stream does not decode.
  try:
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
  except AudioError:
    (-1, -1)

proc exactWav(src: AudioSamples; b: seq[uint8]): bool =
  try:
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
  except AudioError:
    false

# ------------------------------------------------------------ cells ---

proc benchDecodeOur(name: string; b: seq[uint8]; ext: string;
    decode: proc(b: seq[uint8]): tuple[frames: int; rate: uint32]) =
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
  var ffX = 0.0
  var ffNote = ""
  if ffBin() != "":
    let path = "/tmp/bcodecs_dec" & ext
    writeBytes(path, b)
    var ok = true
    for rep in 0 ..< 3:
      let dt = ffDecodeSecs(path)
      if dt < 0.0:
        ok = false
        break
      let x = audioSec / max(dt, 1e-9)
      if rep == 0 or x > ffX:
        ffX = x
    if not ok:
      ffNote = " (ff failed)"
    try: removeFile(path)
    except OSError: discard
  else:
    ffNote = " (no ffmpeg)"
  echo fmt"{name:<20} ours {best:7.1f}x | ff {ffX:7.1f}x{ffNote}"

proc benchEncode(name, wavPath, outPath, ffArgs: string;
    audioSec: float64;
    encode: proc(): seq[uint8]): tuple[ours, ff: seq[uint8];
    ox, fx: float64] =
  var ob: seq[uint8] = @[]
  var best = 0.0
  for rep in 0 ..< 3:
    let t0 = getMonoTime()
    ob = encode()
    let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
    let x = audioSec / max(dt, 1e-9)
    if rep == 0 or x > best:
      best = x
  var fb: seq[uint8] = @[]
  var fbest = 0.0
  if ffBin() != "" and ffEncode(wavPath, outPath, ffArgs):
    let raw = readFile(outPath)
    fb = newSeq[uint8](raw.len)
    for i, c in raw:
      fb[i] = cast[uint8](c)
    for rep in 0 ..< 3:
      let t0 = getMonoTime()
      if not ffEncode(wavPath, outPath, ffArgs):
        break
      let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
      let x = audioSec / max(dt, 1e-9)
      if rep == 0 or x > fbest:
        fbest = x
  result = (ob, fb, best, fbest)

proc dumpWav(name: string; src: AudioSamples): string =
  result = "/tmp/bcodecs_" & name & ".wav"
  writeBytes(result, encodeWav(src, src.specOf().rate))

proc main() =
  echo fmt"nim {NimVersion}  hostOS={hostOS}  cpu={hostCPU}"
  let sine2 = sineStereo(88_200, 440.0, 660.0, 0.4)
  let noise1 = noiseStereo(44_100, 0.4)
  let sine1 = sineStereo(44_100, 440.0, 660.0, 0.4)
  let haveFf = ffBin() != ""
  if not haveFf:
    echo "ffmpeg not found: ff columns report n/a"

  echo "--- encode: wav/adpcm (sine2) ---"
  block:
    let w = dumpWav("sine2", sine2)
    let audioSec = sine2.framesOf().float64 / 44100.0
    let r = benchEncode("wav16", w, "/tmp/bcodecs_wav.wav",
      "-codec:a pcm_s16le", audioSec,
      proc(): seq[uint8] = encodeWav(sine2, 44_100))
    let qOurs = if exactWav(sine2, r.ours): "exact" else: "MISMATCH"
    let qFf =
      if r.ff.len == 0: "n/a"
      elif exactWav(sine2, r.ff): "exact"
      else: "MISMATCH"
    echo fmt"wav16   ours {r.ox:7.1f}x {r.ours.len:>8}B {qOurs} | ff {r.fx:7.1f}x {r.ff.len:>8}B {qFf}"
    for f in [w, "/tmp/bcodecs_wav.wav"]:
      try: removeFile(f)
      except OSError: discard
    benchDecodeOur("dec wav16", r.ours, ".wav", decWav)
  for (nm, codec, ffCodec) in
      [("ms", CodecAdpcmMs, "adpcm_ms"),
       ("ima", CodecAdpcmImaWav, "adpcm_ima_wav")]:
    block:
      let w = dumpWav("sine2", sine2)
      let audioSec = sine2.framesOf().float64 / 44100.0
      let outPath = "/tmp/bcodecs_adpcm_" & nm & ".wav"
      let c = codec
      let r = benchEncode("adpcm-" & nm, w, outPath,
        "-codec:a " & ffCodec, audioSec,
        proc(): seq[uint8] = encodeWav(sine2, 44_100, c))
      let (wO, mO) = maxErrAdpcm(sine2, r.ours)
      let qFf =
        if r.ff.len == 0: "n/a"
        else:
          let (wF, mF) = maxErrAdpcm(sine2, r.ff)
          if wF < 0: "n/a" else: "worst=" & $wF & " mean=" & $mF
      echo fmt"adpcm-{nm:<4} ours {r.ox:7.1f}x {r.ours.len:>8}B worst={wO} mean={mO} | ff {r.fx:7.1f}x {r.ff.len:>8}B {qFf}"
      for f in [w, outPath]:
        try: removeFile(f)
        except OSError: discard
      benchDecodeOur("dec adpcm-" & nm, r.ours, ".wav", decAdpcm)

  echo "--- encode: flac (sine2, noise1) ---"
  for (nm, src) in [("sine2", sine2), ("noise1", noise1)]:
    block:
      let w = dumpWav(nm, src)
      let audioSec = src.framesOf().float64 / 44100.0
      let outPath = "/tmp/bcodecs_flac_" & nm & ".flac"
      let s = src
      let r = benchEncode("flac-" & nm, w, outPath, "-codec:a flac",
        audioSec, proc(): seq[uint8] = encodeFlacStream(s, 44_100))
      let (fO, _) = decFlac(r.ours)
      let qOurs = if fO == src.framesOf(): "exact-frames" else: "MISMATCH"
      var qFf = "n/a"
      if r.ff.len > 0:
        try:
          let (fF, _) = decFlac(r.ff)
          qFf = if fF == src.framesOf(): "exact-frames" else: "MISMATCH"
        except AudioError:
          qFf = "n/a"
      echo fmt"flac-{nm:<6} ours {r.ox:7.1f}x {r.ours.len:>8}B {qOurs} | ff {r.fx:7.1f}x {r.ff.len:>8}B {qFf}"
      for f in [w, outPath]:
        try: removeFile(f)
        except OSError: discard
      benchDecodeOur("dec flac-" & nm, r.ours, ".flac", decFlac)

  echo "--- encode: mp3 128k gapless (sine2, noise1) ---"
  for (nm, src) in [("sine2", sine2), ("noise1", noise1)]:
    block:
      let w = dumpWav(nm, src)
      let audioSec = src.framesOf().float64 / 44100.0
      let outPath = "/tmp/bcodecs_mp3_" & nm & ".mp3"
      let s = src
      let r = benchEncode("mp3-" & nm, w, outPath,
        "-codec:a libmp3lame -b:a 128k", audioSec,
        proc(): seq[uint8] =
          var o = defaultMp3EncoderOptions(128, 44_100,
            MpaMode(kind: mmStereo))
          o.xing = true
          o.gapless = true
          encodeMp3Stream(s, o))
      let qOurs = psnrVsS16(src, decodeF32Mp3(r.ours))
      var qFf = "n/a"
      if r.ff.len > 0:
        try:
          let p = psnrVsS16(src, decodeF32Mp3(r.ff))
          qFf = fmt"psnr {p:5.1f}dB"
        except AudioError:
          qFf = "n/a"
      echo fmt"mp3-{nm:<6} ours {r.ox:7.1f}x {r.ours.len:>8}B psnr {qOurs:5.1f}dB | ff {r.fx:7.1f}x {r.ff.len:>8}B {qFf}"
      for f in [w, outPath]:
        try: removeFile(f)
        except OSError: discard
      benchDecodeOur("dec mp3-" & nm, r.ours, ".mp3", decMp3)

  echo "--- encode: aac 128k (sine1, noise1) ---"
  for (nm, src) in [("sine1", sine1), ("noise1", noise1)]:
    block:
      let w = dumpWav(nm, src)
      let audioSec = src.framesOf().float64 / 44100.0
      let outPath = "/tmp/bcodecs_aac_" & nm & ".aac"
      let s = src
      let r = benchEncode("aac-" & nm, w, outPath,
        "-codec:a aac -b:a 128k", audioSec,
        proc(): seq[uint8] =
          encodeAacStream(s, defaultAacEncoderOptions(44_100, 2)))
      let qOurs = psnrVsS16(src, decodeF32Aac(r.ours), 1024)
      var qFf = "n/a"
      if r.ff.len > 0:
        try:
          let p = psnrVsS16(src, decodeF32Aac(r.ff), 1024)
          qFf = fmt"psnr {p:5.1f}dB"
        except AudioError:
          qFf = "n/a"
      echo fmt"aac-{nm:<6} ours {r.ox:7.1f}x {r.ours.len:>8}B psnr {qOurs:5.1f}dB | ff {r.fx:7.1f}x {r.ff.len:>8}B {qFf}"
      for f in [w, outPath]:
        try: removeFile(f)
        except OSError: discard
      benchDecodeOur("dec aac-" & nm, r.ours, ".aac", decAacAdts)

  echo "--- decode: repo fixtures (decode-only formats) ---"
  for (nm, path, ext, decode) in
      [("vorbis", "tests/fixtures/fix_stereo.ogg", ".ogg", decOggVorbis),
       ("alac", "tests/fixtures/fix_alacstereo.m4a", ".m4a", decMp4Alac),
       ("aac-mp4", "tests/fixtures/fix_aacstereo.m4a", ".m4a", decMp4Aac),
       ("aiff", "tests/fixtures/fix_aiffmono.aiff", ".aiff", decAiff),
       ("caf", "tests/fixtures/fix_cafmono.caf", ".caf", decCaf)]:
    benchDecodeOur("dec " & nm, readFileBytes(path), ext, decode)

when isMainModule:
  main()
