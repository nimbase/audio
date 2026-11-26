## MP3 encode/decode throughput benchmark (deterministic fixtures).
##
## Build (release, reproducible):
##   clue build benchmarks/bmp3.nim --out:/tmp/bmp3 --release
## Run:
##   /tmp/bmp3
##
## Reports best-of-3 (encode) / best-of-10 (decode) wall time per cell
## as audio-seconds per wall-second (x realtime) plus output size.
## (fixed tones / seeded noise) so numbers are comparable across runs
## on the same machine.

import std/math
import std/monotimes
import std/options
import std/strformat
import std/times

import audio/audio
import audio/codecs
import audio/codecs/mpa
import audio/codecs/mpaenc
import audio/formats/mpa as mpafmt
import audio/io

proc sineStereo(n: int; fL, fR, amp: float; rate = 44_100): AudioSamples =
  let spec = newAudioSpec(rate.uint32, ChStereo)
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    result.s16.planes[0][i] = (amp * 32767.0 *
      sin(2.0 * PI * fL * i.float / rate.float)).int16
    result.s16.planes[1][i] = (amp * 32767.0 *
      sin(2.0 * PI * fR * i.float / rate.float)).int16

proc sineMono(n: int; f, amp: float; rate = 44_100): AudioSamples =
  let spec = newAudioSpec(rate.uint32, positioned(PosFrontCenter))
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    result.s16.planes[0][i] = (amp * 32767.0 *
      sin(2.0 * PI * f * i.float / rate.float)).int16

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

proc median3(a, b, c: float64): float64 =
  if a < b:
    if b < c: b elif a < c: c else: a
  else:
    if a < c: a elif b < c: c else: b

proc benchCell(name: string; mk: proc(): Mp3Encoder; src: AudioSamples) =
  let audioSec = src.framesOf().float64 / src.specOf().rate.float64
  let pcm = toS16Interleaved(src)
  var encBest = 0.0
  var bytes: seq[uint8] = @[]
  for rep in 0 ..< 3:
    let e = mk()
    let t0 = getMonoTime()
    e.pushSamplesI16(pcm)
    bytes = e.finishEncoder()
    let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
    let x = audioSec / max(dt, 1e-9)
    if rep == 0 or x > encBest:
      encBest = x
  let outBytes = bytes.len
  var decBest = 0.0
  for rep in 0 ..< 10:
    let t0 = getMonoTime()
    let w = mpafmt.openMpa(bytes)
    let dec = newMpaDecoder(w.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var got = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      got += dec.decodePacket(pkt.get).framesOf()
    let dt = (getMonoTime() - t0).inNanoseconds.float64 / 1e9
    let x = audioSec / max(dt, 1e-9)
    if rep == 0 or x > decBest:
      decBest = x
    doAssert got > 0
  echo fmt"{name:<22} enc {encBest:7.1f}x  dec {decBest:7.1f}x  {outBytes:>8} B"

initMpaTables()
echo fmt"nim {NimVersion}  hostOS={hostOS}  cpu={hostCPU}"
let sine44 = sineStereo(220_500, 440.0, 660.0, 0.4)
let noise44 = noiseStereo(44_100, 0.4)
let mono44 = sineMono(220_500, 440.0, 0.5)
let sine22 = sineStereo(110_250, 440.0, 660.0, 0.4, 22_050)
echo "--- sine stereo 44.1k ---"
benchCell("cbr128", proc(): Mp3Encoder =
  newMp3EncoderCbr(128, 44_100, MpaMode(kind: mmStereo)), sine44)
benchCell("outer", proc(): Mp3Encoder =
  newMp3EncoderOuterLoop(128, 44_100, MpaMode(kind: mmStereo)), sine44)
benchCell("ltq", proc(): Mp3Encoder =
  newMp3EncoderLtq(128, 44_100, MpaMode(kind: mmStereo)), sine44)
benchCell("qhigh(model2)", proc(): Mp3Encoder =
  newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo), qpHigh),
  sine44)
benchCell("qfast", proc(): Mp3Encoder =
  newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo), qpFast),
  sine44)
benchCell("jointauto", proc(): Mp3Encoder =
  newMp3EncoderJointAuto(128, 44_100), sine44)
benchCell("joint-is", proc(): Mp3Encoder =
  newMp3EncoderJointIs(128, 44_100, 8), sine44)
echo "--- noise stereo 44.1k ---"
benchCell("cbr128", proc(): Mp3Encoder =
  newMp3EncoderCbr(128, 44_100, MpaMode(kind: mmStereo)), noise44)
benchCell("qhigh(model2)", proc(): Mp3Encoder =
  newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo), qpHigh),
  noise44)
echo "--- mono 44.1k / lsf 22.05k ---"
benchCell("mono64", proc(): Mp3Encoder =
  newMp3EncoderCbr(64, 44_100, MpaMode(kind: mmMono)), mono44)
benchCell("lsf64", proc(): Mp3Encoder =
  newMp3EncoderCbr(64, 22_050, MpaMode(kind: mmStereo)), sine22)
