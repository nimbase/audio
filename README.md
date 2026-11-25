<p align="center">
  Pure-Nim audio encoders and decoders, no C bindings.<br>
  Decode <i>and</i> encode WAV/PCM/ADPCM today; FLAC, Vorbis, MP3, AAC, ALAC on the way.
</p>

<p align="center">
  <code>nimble install audio</code> / <code>clue install audio</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/audio/">API reference</a><br>
  <img src="https://github.com/nimbase/audio/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/audio/workflows/docs/badge.svg" alt="Github Actions">
</p>

> [!NOTE]
> This is an LLM-accelerated Nim package, a pure-Nim port of
> [Symphonia](https://github.com/pdeljanov/Symphonia). Decoder semantics
> mirror the reference; encoders are new work (Symphonia is decode-only).
> Zero C bindings, MPL-2.0 like the original.

## Features

- One `import audio` covers everything: errors, time units, planar
  buffers, codecs, WAV mux/demux
- Errors as exceptions with kinds (`ekDecode`, `ekUnsupported`,
  `ekLimit`, `ekSeek`) instead of `Result` plumbing
- Planar `AudioBuffer[S]` for all 10 sample formats, LSB-aligned 24-bit,
  `FromSample`-style conversion, gapless `trimStart`/`trimEnd` packets
- Decoder registry: `registerPcm()`, `registerAdpcm()`, `registerVorbis()`,
  then `makeAudioDecoder(params)`

Codec support (`o` = decode, `w` = encode):

- PCM: o+w — S8/S16/S24/S32, U8/U16/U24/U32, F32/F64, LE/BE, A-law/mu-law
- WAV: o+w — RIFF parser (plain + EXTENSIBLE, fact, LIST/INFO, seek) and writer
- ADPCM: o+w — MS, IMA-WAV, IMA-QT; encoders search all candidates per
  nibble (MS also tries all 7 predictors per block)
- FLAC: o+w — subset encoder (fixed predictors + verbatim, order-0 Rice,
  independent channels); MD5 stream verification
- Ogg: o — OggS demuxer (MPEG-2 CRC, packet assembly, granule seek)
  with Vorbis comment metadata
- Vorbis: o — decoder (codebooks, floor 0/1, residues, IMDCT); matches
  ffmpeg within 2 LSB on sine fixtures
- Checksums: CRC-8/CCITT, CRC-16/ANSI, CRC-32, MD5

## Examples

### WAV roundtrip (mux → demux → decode)

```nim
import std/options
import audio

let spec = newAudioSpec(44_100, ChStereo)
var buf = newAudioSamples(sfS16, spec, 8)
buf.s16.renderWith(8, i):
  buf.s16.planes[0][i] = cast[int16](i * 1000)
  buf.s16.planes[1][i] = cast[int16](-i * 1000)

let bytes = encodeWav(buf, 44_100)     # mux
let reader = openWav(bytes)            # demux (probeWav == 255)
let dec = newPcmDecoder(reader.params) # decode

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get)
  echo samples.framesOf(), " frames"
```

### ADPCM compression via the registry

```nim
import std/options
import audio

registerAdpcm()

let bytes = encodeWav(buf, 44_100, CodecAdpcmMs)
let reader = openWav(bytes)
echo reader.params.codec          # CodecAdpcmMs
echo reader.numFrames().get       # >= real frames (tail block padded)

let dec = makeAudioDecoder(reader.params)
while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  echo dec.decodePacket(pkt.get).framesOf(), " frames"
```

### Ogg Vorbis decode

```nim
import std/options
import audio

registerVorbis()

let bytes = readFile("fix_stereo.ogg").toBytes()
let reader = openOgg(bytes)              # probeOgg == 255
let dec = newVorbisDecoder(reader.tracks[0].codec,
  AudioDecoderOptions(gapless: true, verify: false))

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get) # sfF32 planar
  echo samples.framesOf(), " frames"
```

### Probe + seek

```nim
import audio

if probeWav(bytes) == 255:
  let reader = openWav(bytes)
  let to = seekToTimestamp(newTimestamp(1_152), 0)
  let at = reader.seek(to)        # aligned down to packet boundary
  echo reader.nextPacket().get.pts.get == at.actualTs.get
```

## Roadmap

- [x] Repo, MPL-2.0 license, core (`errors`, `units`, `audio`, `io`, `packet`, `codecs`, `formats`, `metadata`)
- [x] PCM (20 variants + A-law/mu-law) and WAV (demuxer + muxer)
- [x] ADPCM (MS, IMA-WAV, IMA-QT) decoders + encoders
- [x] FLAC decoder + encoder (CRC/MD5 verify)
- [x] Ogg demuxer + Vorbis decoder
- [ ] MP1/MP2/MP3 decoders
- [ ] AAC-LC decoder + ISOMP4 demuxer
- [ ] ALAC decoder + AIFF/CAF demuxers
- [ ] Later: WavPack, pure-Nim Opus + HE-AAC ports, MKV/WebM, streaming
  I/O, fuzz corpus, benchmarks

### ❤ Credits

- [Symphonia](https://github.com/pdeljanov/Symphonia) developers
  (Philip Deljanov and contributors, incl. Kostya Shishkov's AAC work):
  decoder semantics, tables, and test vectors ported from their code.
- Sun Microsystems `g711.c` (unrestricted use): A-law/mu-law transfer
  functions adapted from it.

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/audio/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/audio/fork)

### 🎩 License
MPL-2.0, matching Symphonia. See [LICENSE](LICENSE).
