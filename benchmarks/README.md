# MP3 benchmarks

Reproducible commands (run from the package root):

```sh
clue build benchmarks/bmp3.nim --out:/tmp/bmp3 --release
/tmp/bmp3
```
`bmp3.nim` encodes + decodes deterministic fixtures (5 s stereo tones
at 44.1 kHz, 1 s seeded stereo white noise, 5 s mono tone, 5 s stereo
tone at 22.05 kHz) and prints best-of-3 (encode) / best-of-10 (decode)
wall time as audio-seconds per wall-second (× realtime) plus output
size. Best-of-N keeps scheduling jitter out of the comparison; use the
same binary and fixtures when re-measuring.

## Baseline — 2026-11-26

Machine: macOS (amd64 build), Nim 2.4.0,
`clue build --release`, measured 2026-11-26 on the pre-SIMD tree
(scalar synthesis/overlap-add). Decode figures below therefore
predate the SSE2 window kernels in `src/audio/vec.nim`, which add
about 1.1x end-to-end on MP3 decode (170x → 189x on the 128k
stereo cell); use `-d:vecScalar` to reproduce scalar numbers.

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
--- sine stereo 44.1k ---
cbr128                 enc     1.9x  dec   178.2x     80666 B
outer                  enc     1.8x  dec   175.2x     80666 B
ltq                    enc     1.8x  dec   173.5x     80666 B
qhigh(model2)          enc     1.8x  dec   157.5x     80666 B
qfast                  enc     1.8x  dec   176.4x     80666 B
jointauto              enc     2.1x  dec   176.1x     80666 B
joint-is               enc     0.9x  dec   189.2x     80666 B
--- noise stereo 44.1k ---
cbr128                 enc     0.1x  dec   332.3x     16718 B
qhigh(model2)          enc     0.1x  dec   334.6x     16718 B
--- mono 44.1k / lsf 22.05k ---
mono64                 enc     1.2x  dec   354.8x     40333 B
lsf64                  enc     2.6x  dec   380.1x     40542 B
```

Notes:

- Identical byte sizes across the sine-stereo encoder variants mean the
  outer loop (uniform / LTq / Model-2) does not engage on these
  fixtures at 128 kbit/s: the first inner-loop gain already satisfies
  every threshold, so all variants emit the same bits. The loop is a
  safety net that only steers on tight budgets / difficult spectra
  (covered by `outerLoopSearchLong` unit tests in `tests/tmp3enc.nim`).
- Noise encodes at ~0.1× realtime: the inner-loop gain scan evaluates
  `chooseBestTableForRegion` per region per gain, and each pair-cost
  query rebuilds its Huffman code vectors from the const tables
  (`huffCodes` allocates per call). Known hotspot; no behavior change
  attempted here — this baseline pins the pre-optimization numbers.
- Decode runs at 130–380× realtime across configs; decode cost is
  dominated by the hybrid synthesis + bitstream reading, independent
  of which encoder preset produced the stream.

# Multi-format benchmark (in-binary only)

Reproducible commands (run from the package root):

```sh
clue build benchmarks/bcodecs.nim --out:/tmp/bcodecs --release
/tmp/bcodecs
```

`bcodecs.nim` encodes shared deterministic fixtures (2 s stereo
sine at 44.1 kHz, 1 s seeded stereo noise, 1 s sine for AAC) with
every encoder, then decodes the bytes plus repo fixtures for the
decode-only formats. Deliberately no ffmpeg/process comparison:
everything is timed in-process (best-of-3 encode, best-of-10
decode, audio-seconds per wall-second), so the numbers describe our
code, not shell spawn and file I/O. Each row also reports output
size, a quality metric (exact / worst+mean s16 LSB / PSNR past the
AAC priming frame), and process Max RSS. RSS is the `getrusage`
high-water mark, cumulative across the run in cell order, so later
rows include earlier peaks. The closure-timing hazard noted for
this box does not fire here: closure-param vs direct-call timing
agrees (wav 1.7 vs 1.2 ms, AAC 1.157 vs 1.154 s on the same work).
MP3 preset detail stays in `bmp3.nim`; this file compares formats.

## Baseline — 2026-11-27

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
```

Encode, 44.1 kHz stereo:

| Format    | Fixture  | Speed | Size   | Quality            | Max RSS |
|-----------|----------|-------|--------|--------------------|---------|
| WAV16     | sine 2 s | 1626x | 352844 | exact              | 3.2MiB  |
| ADPCM-MS  | sine 2 s | 21x   | 92762  | worst 43, mean 5   | 3.3MiB  |
| ADPCM-IMA | sine 2 s | 25x   | 90940  | worst 424, mean 47 | 3.3MiB  |
| FLAC      | sine 2 s | 2.7x  | 52857  | exact-frames       | 5.3MiB  |
| FLAC      | noise 1 s| 1.9x  | 165796 | exact-frames       | 5.6MiB  |
| MP3 128k  | sine 2 s | 1.3x  | 33017  | 78.5 dB            | 8.3MiB  |
| MP3 128k  | noise 1 s| 0.1x  | 17135  | 14.6 dB            | 8.4MiB  |
| AAC 128k  | sine 1 s | 0.9x  | 5432   | 47.6 dB            | 8.4MiB  |
| AAC 128k  | noise 1 s| 0.8x  | 85218  | 47.0 dB            | 8.8MiB  |

Decode:

| Source          | Speed | Max RSS |
|-----------------|-------|---------|
| wav16           | 1089x | 3.3MiB  |
| adpcm-ms        | 1152x | 3.3MiB  |
| adpcm-ima       | 1230x | 3.3MiB  |
| flac sine       | 277x  | 5.4MiB  |
| flac noise      | 474x  | 5.6MiB  |
| mp3 sine        | 193x  | 8.4MiB  |
| mp3 noise       | 384x  | 8.4MiB  |
| aac sine        | 910x  | 8.5MiB  |
| aac noise       | 348x  | 8.8MiB  |
| vorbis fixture  | 171x  | 11.8MiB |
| alac fixture    | 278x  | 11.8MiB |
| aac-mp4 fixture | 695x  | 11.8MiB |
| aiff fixture    | 4301x | 11.8MiB |
| caf fixture     | 4277x | 11.9MiB |

Conclusion:

- Every encoder runs realtime except MP3 on noise (0.1x, Huffman
  table-select hotspot) and AAC (0.8–0.9x, direct-form MDCT): the
  two pinned optimization targets.
- Quality is near-transparent on tones (MP3 78.5 dB, AAC 47.6 dB)
  and solid on noise (MP3 14.6 dB on budget; AAC 47 dB at 5x the
  128k budget — no rate loop yet, Step D work).
- Decoders run 170–4300x realtime in-process.
- Memory is flat: the whole suite peaks at 11.9 MiB, encoders add
  low single-digit MB each (FLAC ~2, MP3 ~3 over the running mark).
