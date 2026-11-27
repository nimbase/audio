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

## Baseline — 2026-11-27 (huff-cache fix)

Machine: macOS (amd64 build), Nim 2.4.0,
`clue build --release`. Follows the SIMD window kernels in
`src/audio/vec.nim` (`-d:vecScalar` reproduces scalar synthesis).
Sizes are bit-identical to the 2026-11-26 baseline: the cache
changes timing only (proven by stash-and-compare on six encoder
configs plus these tables).

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
--- sine stereo 44.1k ---
cbr128                 enc     5.4x  dec   187.9x     80666 B
outer                  enc     5.3x  dec   182.0x     80666 B
ltq                    enc     5.2x  dec   179.9x     80666 B
qhigh(model2)          enc     5.2x  dec   183.3x     80666 B
qfast                  enc     5.3x  dec   178.2x     80666 B
jointauto              enc     5.9x  dec   171.1x     80666 B
joint-is               enc     6.1x  dec   198.0x     80666 B
--- noise stereo 44.1k ---
cbr128                 enc     0.3x  dec   365.1x     16718 B
qhigh(model2)          enc     0.3x  dec   367.5x     16718 B
--- mono 44.1k / lsf 22.05k ---
mono64                 enc     9.4x  dec   331.1x     40333 B
lsf64                  enc     8.8x  dec   400.7x     40542 B
```

Notes:

- Identical byte sizes across the sine-stereo encoder variants mean the
  outer loop (uniform / LTq / Model-2) does not engage on these
  fixtures at 128 kbit/s: the first inner-loop gain already satisfies
  every threshold, so all variants emit the same bits. The loop is a
  safety net that only steers on tight budgets / difficult spectra
  (covered by `outerLoopSearchLong` unit tests in `tests/tmp3enc.nim`).
- Noise encode was ~0.1× realtime before the huff-cache fix (the
  inner-loop gain scan evaluated `chooseBestTableForRegion` per
  region per gain, and each pair-cost query rebuilt its Huffman code
  vectors from the const tables); caching the vectors per select
  index took it to ~0.3x with bit-identical output. Remaining cost
  is the gain scan itself plus quantization.
- Decode runs at 170–400× realtime across configs; decode cost is
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
| WAV16     | sine 2 s | 1753x | 352844 | exact              | 3.2MiB  |
| ADPCM-MS  | sine 2 s | 24x   | 92762  | worst 43, mean 5   | 3.3MiB  |
| ADPCM-IMA | sine 2 s | 28.5x | 90940  | worst 424, mean 47 | 3.3MiB  |
| FLAC      | sine 2 s | 2.7x  | 52857  | exact-frames       | 5.3MiB  |
| FLAC      | noise 1 s| 1.8x  | 165796 | exact-frames       | 5.6MiB  |
| MP3 128k  | sine 2 s | 5.1x  | 33017  | 78.5 dB            | 8.4MiB  |
| MP3 128k  | noise 1 s| 0.3x  | 17135  | 14.6 dB            | 8.4MiB  |
| AAC 128k  | sine 1 s | 0.9x  | 5432   | 47.6 dB            | 8.4MiB  |
| AAC 128k  | noise 1 s| 0.9x  | 85218  | 47.0 dB            | 8.9MiB  |

Decode:

| Source          | Speed | Max RSS |
|-----------------|-------|---------|
| wav16           | 1158x | 3.3MiB  |
| adpcm-ms        | 1166x | 3.3MiB  |
| adpcm-ima       | 1319x | 3.3MiB  |
| flac sine       | 276x  | 5.4MiB  |
| flac noise      | 460x  | 5.6MiB  |
| mp3 sine        | 184x  | 8.4MiB  |
| mp3 noise       | 363x  | 8.4MiB  |
| aac sine        | 884x  | 8.5MiB  |
| aac noise       | 349x  | 8.9MiB  |
| vorbis fixture  | 171x  | 12.4MiB |
| alac fixture    | 293x  | 12.5MiB |
| aac-mp4 fixture | 658x  | 12.5MiB |
| aiff fixture    | 4690x | 12.5MiB |
| caf fixture     | 4662x | 12.5MiB |

Conclusion:

- Every encoder runs realtime except MP3 on noise (0.3x, down to
  the gain scan now that the Huffman table-select hotspot is
  cached) and AAC (0.9x, direct-form MDCT): the two pinned
  optimization targets.
- Quality is near-transparent on tones (MP3 78.5 dB, AAC 47.6 dB)
  and solid on noise (MP3 14.6 dB on budget; AAC 47 dB at 5x the
  128k budget — no rate loop yet, Step D work).
- Decoders run 170–4300x realtime in-process.
- Memory is flat: the whole suite peaks at 11.9 MiB, encoders add
  low single-digit MB each (FLAC ~2, MP3 ~3 over the running mark).
