<p align="center">
  Pure-Nim audio encoders and decoders, no C bindings.<br>
  Decode <i>and</i> encode WAV/PCM/ADPCM today; FLAC, Vorbis, MP3, AAC, ALAC, AIFF, CAF, MKV/WebM decode.
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
  `registerMpa()`, `registerAac()`, `registerAlac()`,
  then `makeAudioDecoder(params)`
- Streaming: mmap file source + 1 MiB reusable byte pool, zero-copy
  packet views (`openWavMapped`, `decodePacketView`)
- SIMD fast paths (`src/audio/vec.nim` via `nimsimd`): 4-wide SSE2 on
  x86-64 with scalar fallback elsewhere (ARM stays portable);
  Vorbis overlap-add and MP3 polyphase windowing run bit-identical
  at ~3.6x kernel speed (~1.1x end-to-end MP3 decode).
  `-d:vecScalar` forces the scalar fallback

Codec support (`o` = decode, `w` = encode):

- PCM: o+w — S8/S16/S24/S32, U8/U16/U24/U32, F32/F64, LE/BE, A-law/mu-law
- WAV: o+w — RIFF parser (plain + EXTENSIBLE, fact, LIST/INFO, seek) and writer
- ADPCM: o+w — MS, IMA-WAV, IMA-QT; encoders search all candidates per
  nibble (MS also tries all 7 predictors per block)
- FLAC: o+w — full RFC 9639 encoder (constant/fixed/LPC-32 with
  apodized Levinson-Durbin, mid-side/left-side/right-side, partitioned
  Rice + Rice2, variable blocks, seek table); MD5 stream verification
- Ogg: o — OggS demuxer (MPEG-2 CRC, packet assembly, granule seek)
  with Vorbis comment metadata
- Vorbis: o — decoder (codebooks, floor 0/1, residues, IMDCT); matches
  ffmpeg within 2 LSB on sine fixtures
- MP3: o+w — MPEG-1/2/2.5 Layer 1/2/3 decoder (reservoir, Huffman,
  hybrid synthesis) + raw-stream demuxer (Xing/Info/LAME gapless,
  VBRI, CBR estimate, seek); matches ffmpeg/mpg123 within 2 LSB.
  Layer III encoder: analysis filterbank, forward MDCT, quantizer,
  inner-loop gain search, outer distortion loop, Huffman emit,
  reservoir scheduler, stereo/MS-joint (incl. auto picker),
  intensity-stereo (is-only, MS+IS, auto+IS; long/short/mixed,
  MPEG-1/LSF), short/mixed blocks (forced + signal-driven auto),
  threshold-in-quiet + signal-dependent Model-2 masking (Annex D
  spreading, TMN/NMT, flatness tonality) + quality presets, CBR/VBR, Xing/Info + LAME gapless tag, CRC-16,
  all nine sample rates; decoded output verified sample-exact
  (gapless) and within black-box tolerance on fixtures
- AAC: o — AAC-LC decoder (Huffman, TNS, KBD/sine IMDCT filterbank)
  + ISOMP4 demuxer (stbl sample tables, esds ASC, seek); matches
  ffmpeg within 2 LSB past the 1024-sample priming
- ALAC: o — Apple Lossless decoder (Rice history/zero-run, LPC with
  adaptive coefficients, mid-side, tail bits; sfS32 planar output);
  bit-exact on fixtures
- AIFF: o — AIFF/AIFC demuxer (BE chunks, COMM/SSND, 80-bit rate,
  NAME/AUTH/`(c) `/ANNO tags, 1152-frame seek); bit-exact PCM
- CAF: o — Core Audio demuxer (desc/data/chan/pakt/kuki, fixed and
  packet-table audio, nominal channel layouts); bit-exact PCM,
  ALAC prefix-exact over valid frames
- MKV/WebM: o — Matroska demuxer (EBML, lacing incl. EBML/Xiph, cues,
  Vorbis/FLAC/MP3/AAC/ALAC/PCM/Opus mapping); lossless bit-exact,
  lossy within 2 LSB at codec-delay alignment
- Checksums: CRC-8/CCITT, CRC-16/ANSI (+LE), CRC-32 (+MPEG-2), MD5

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

### MP3 decode

```nim
import std/options
import audio

let bytes = readFile("fix_mp3stereo.mp3").toBytes()
let reader = openMpa(bytes)              # probeMpa == 255
let dec = newMpaDecoder(reader.tracks[0].codec,
  AudioDecoderOptions(gapless: true, verify: false))

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get) # sfF32 planar
  echo samples.framesOf(), " frames"
```

### MP3 encode

```nim
import std/options
import audio

var opts = defaultMp3EncoderOptions(128, 44_100,
  MpaMode(kind: mmStereo))
opts.xing = true
opts.gapless = true              # Xing/Info + LAME delay/padding tag
let mp3bytes = encodeMp3Stream(buf, opts)  # complete .mp3 stream

# Joint stereo variants:
let e = newMp3EncoderJointAuto(128, 44_100) # per-frame MS/LR picker
e.enableXingInfo()
e.pushSamplesI16(toS16Interleaved(buf))
let msbytes = e.finishEncoder()
```

### AAC decode (MP4)

```nim
import std/options
import audio

let bytes = readFile("fix_aacstereo.m4a").toBytes()
let reader = openMp4(bytes)              # probeMp4 == 255
let dec = newAacDecoder(reader.tracks[0].codec,
  AudioDecoderOptions(gapless: true, verify: false))

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get) # sfF32 planar, 1024 frames
  echo samples.framesOf(), " frames"
```
Note: like Symphonia, edit lists are parsed but not applied, so the
first 1024 decoded samples are encoder priming (dark silence to
discard for gapless playback).

### ALAC decode (MP4 or CAF)

```nim
import std/options
import audio

let bytes = readFile("fix_alacstereo.m4a").toBytes()
let reader = openMp4(bytes)              # alac sample entry + cookie
# let reader = openCaf(readFile("fix_alacstereo.caf").toBytes())
let dec = newAlacDecoder(reader.tracks[0].codec,
  AudioDecoderOptions(gapless: true, verify: false))

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get) # sfS32 planar, left-justified
  echo samples.framesOf(), " frames"
```

### AIFF decode

```nim
import std/options
import audio

let bytes = readFile("fix_aiffmono.aiff").toBytes()
let reader = openAiff(bytes)             # probeAiff == 255
let dec = newPcmDecoder(reader.tracks[0].codec,
  AudioDecoderOptions(gapless: true, verify: false))

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get) # sfS16 planar
  echo samples.framesOf(), " frames"
```

### MKV/WebM decode

```nim
import std/options
import audio

registerVorbis()

let bytes = readFile("fix_vorbis_stereo.mka").toBytes()
let reader = openMkv(bytes)              # probeMkv == 255
let dec = makeAudioDecoder(reader.tracks[0].codec,
  AudioDecoderOptions(gapless: true, verify: false))

while true:
  let pkt = reader.nextPacket()
  if pkt.isNone: break
  let samples = dec.decodePacket(pkt.get) # sfF32 planar
  echo samples.framesOf(), " frames"
```

### Streaming WAV (mmap + 1 MiB pool)

```nim
import audio

let reader = openWavMapped("big.wav") # zero-copy file mapping
let dec = newPcmDecoder(reader.params)
var pool = initStreamPool()            # 1 MiB reusable packet scratch

while true:
  let view = reader.nextPacketView()
  if view.isNone: break
  # No packet copy: decode straight from the mapping.
  echo dec.decodePacketView(view.get).framesOf(), " frames"
  # Or copy the window into the pool for compat paths:
  loadPacketInto(pool, view.get)

reader.close()
```

FLAC mirrors it: `openFlacMapped` + `newFlacDecoder` +
`decodePacketView`, with MD5 verification intact. MP3 mirrors it too:
`openMpaMapped` + `newMpaDecoder` + `decodePacketView` (gapless trims
and reservoir-backtrack seek included). AAC mirrors it too:
`openMp4Mapped` + `newAacDecoder` + `decodePacketView`
(ffmpeg parity past the 1024-sample priming). ALAC in MP4 mirrors it
too via `openMp4Mapped` + `decodePacketView` (bit-exact). Vorbis in Ogg
mirrors it too: `openOggMapped` + `newVorbisDecoder` + `decodePacketView`
(ffmpeg parity; cross-page packets assemble into the pool). MKV/WebM
mirrors it too: `openMkvMapped` plus the per-codec `decodePacketView`
(lace frames are contiguous, so every packet is a mapping view).

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
- [x] MP1/MP2/MP3 decoders
- [x] MP3 (Layer III) encoder: framing, analysis filterbank, MDCT,
  quantizer, inner/outer loops, Huffman emit, reservoir, MS-joint,
  intensity-stereo (is-only/MS+IS/auto+IS, long/short/mixed,
  MPEG-1/LSF), short/mixed blocks, VBR, Xing/Info, CRC, all MPEG rates
- [x] AAC-LC decoder + ISOMP4 demuxer
- [x] ALAC decoder + AIFF/CAF demuxers
- [x] MKV/WebM demuxer (Vorbis/FLAC/MP3/AAC/ALAC/PCM decode, Opus demux-only)
- [x] Streaming WAV: mmap source + 1 MiB byte pool, zero-copy views
- [x] MP3 encoder/decoder fuzz harness (`tests/tfuzzmp3.nim`):
  hostile headers/side-info/Huffman-count/reservoir/configs/bytes,
  AudioError-only gate, success paths frame-walk and self-decode
- [x] Benchmarks (`benchmarks/bmp3.nim` + recorded baselines) and
  SIMD window kernels (SSE2 via `nimsimd`, scalar fallback,
  `-d:vecScalar`)
- [ ] Later: WavPack, pure-Nim Opus + HE-AAC ports, streaming
  I/O for the remaining formats

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
