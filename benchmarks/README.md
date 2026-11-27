# MP3 benchmarks

Reproducible commands (run from the package root):

```sh
clue build benchmarks/bmp3.nim --out:/tmp/bmp3 --release
/tmp/bmp3
```
`bmp3.nim` encodes + decodes deterministic fixtures (5 s stereo tones
at 44.1 kHz, 1 s seeded stereo white noise, 5 s mono tone, 5 s stereo
tone at 22.05 kHz) and prints best-of-3 (encode) / best-of-10 (decode)
wall time per cell plus output size. Best-of-N keeps scheduling
jitter out of the comparison; use the same binary and fixtures
when re-measuring.

## Baseline — 2026-11-27 (no-dup fix)

Machine: macOS (amd64 build), Nim 2.4.0,
`clue build --release`. Follows the huff-cache fix; the remaining
per-pair cost (seq duplication on the shared cache vectors, found
by reading the generated C) now indexes the cache directly, again
with bit-identical output.

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
--- sine stereo 44.1k (5.0 s audio) ---
cbr128                 enc   0.41 s  dec   27 ms     80666 B
outer                  enc   0.42 s  dec   28 ms     80666 B
ltq                    enc   0.42 s  dec   28 ms     80666 B
qhigh(model2)          enc   0.43 s  dec   27 ms     80666 B
qfast                  enc   0.42 s  dec   27 ms     80666 B
jointauto              enc   0.41 s  dec   27 ms     80666 B
joint-is               enc   0.38 s  dec   25 ms     80666 B
--- noise stereo 44.1k (1.0 s audio) ---
cbr128                 enc   0.34 s  dec    2.8 ms   16718 B
qhigh(model2)          enc   0.34 s  dec    2.7 ms   16718 B
--- mono 44.1k (5.0 s) / lsf 22.05k (5.0 s) ---
mono64                 enc   0.21 s  dec   14 ms     40333 B
lsf64                  enc   0.22 s  dec   13 ms     40542 B
```

Notes:

- Identical byte sizes across the sine-stereo encoder variants mean the
  outer loop (uniform / LTq / Model-2) does not engage on these
  fixtures at 128 kbit/s: the first inner-loop gain already satisfies
  every threshold, so all variants emit the same bits. The loop is a
  safety net that only steers on tight budgets / difficult spectra
  (covered by `outerLoopSearchLong` unit tests in `tests/tmp3enc.nim`).
- Noise encode went 0.1x to 0.3x (huff-cache fix) to 2.9x (no-dup
  fix), all bit-identical: the inner-loop gain scan evaluated
  `chooseBestTableForRegion` per region per gain, and each pair-cost
  query first rebuilt then duplicated its Huffman code vectors.
  Remaining cost is the gain scan itself plus quantization.
- Decode takes 2.7–28 ms per cell; cost is dominated by the hybrid
  synthesis + bitstream reading, independent of which encoder preset
  produced the stream.

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
everything is timed in-process, best-of-3 encode and best-of-10
decode wall time per cell, so the numbers describe our code, not
shell spawn and file I/O. Each row also reports output size, a
quality metric (exact / worst+mean s16 LSB / PSNR past the AAC
priming frame), and process Max RSS. RSS is the `getrusage`
high-water mark, cumulative across the run in cell order, so later
rows include earlier peaks. The closure-timing hazard noted for
this box does not fire here: closure-param vs direct-call timing
agrees (wav 1.7 vs 1.2 ms, AAC 1.157 vs 1.154 s on the same work).
MP3 preset detail stays in `bmp3.nim`; this file compares formats.

## Baseline — 2026-11-27

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
```

Encode, 44.1 kHz stereo (time spent per cell):

| Format    | Fixture  | Audio | Encode time | Size   | Quality            | Max RSS |
|-----------|----------|-------|-------------|--------|--------------------|---------|
| WAV16     | sine 2 s | 2.0 s | 1.3 ms      | 352844 | exact              | 3.2MiB  |
| ADPCM-MS  | sine 2 s | 2.0 s | 83 ms       | 92762  | worst 43, mean 5   | 3.3MiB  |
| ADPCM-IMA | sine 2 s | 2.0 s | 75 ms       | 90940  | worst 424, mean 47 | 3.3MiB  |
| FLAC      | sine 2 s | 2.0 s | 0.69 s      | 52857  | exact-frames       | 5.3MiB  |
| FLAC      | noise 1 s| 1.0 s | 0.50 s      | 165796 | exact-frames       | 5.6MiB  |
| MP3 128k  | sine 2 s | 2.0 s | 0.17 s      | 33017  | 78.5 dB            | 7.7MiB  |
| MP3 128k  | noise 1 s| 1.0 s | 0.34 s      | 17135  | 14.6 dB            | 7.8MiB  |
| AAC 128k  | sine 1 s | 1.0 s | 1.11 s      | 5432   | 47.6 dB            | 7.8MiB  |
| AAC 128k  | noise 1 s| 1.0 s | 1.11 s      | 85218  | 47.0 dB            | 9.0MiB  |

Decode (time spent per cell):

| Source          | Audio | Decode time | Max RSS |
|-----------------|-------|-------------|---------|
| wav16           | 2.0 s | 1.7 ms      | 3.3MiB  |
| adpcm-ms        | 2.0 s | 1.6 ms      | 3.3MiB  |
| adpcm-ima       | 2.0 s | 1.6 ms      | 3.3MiB  |
| flac sine       | 2.0 s | 7.3 ms      | 5.4MiB  |
| flac noise      | 1.0 s | 2.1 ms      | 5.6MiB  |
| mp3 sine        | 2.0 s | 11 ms       | 7.8MiB  |
| mp3 noise       | 1.0 s | 2.7 ms      | 7.8MiB  |
| aac sine        | 1.0 s | 1.1 ms      | 7.9MiB  |
| aac noise       | 1.0 s | 2.8 ms      | 9.0MiB  |
| vorbis fixture  | 1.0 s | 5.7 ms      | 12.4MiB |
| alac fixture    | 1.0 s | 3.4 ms      | 12.5MiB |
| aac-mp4 fixture | 1.0 s | 1.5 ms      | 12.5MiB |
| aiff fixture    | 0.5 s | 0.11 ms     | 12.5MiB |
| caf fixture     | 0.5 s | 0.11 ms     | 12.5MiB |

Conclusion:

- Every encoder finishes faster than the audio it encodes except
  AAC (1.11 s per 1 s, direct-form MDCT): the one remaining
  pinned optimization target. MP3 noise went from 10 s to
  0.34 s across the two fixes.
- Quality is near-transparent on tones (MP3 78.5 dB, AAC 47.6 dB)
  and solid on noise (MP3 14.6 dB on budget; AAC 47 dB at 5x the
  128k budget — no rate loop yet, Step D work).
- Decoders take 0.1–11 ms per file.
- Memory is flat: the whole suite peaks at 12.5 MiB, encoders add
  low single-digit MB each.
