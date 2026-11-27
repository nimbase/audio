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

# Multi-format benchmark + ffmpeg comparison

Reproducible commands (run from the package root; needs `ffmpeg`
with libmp3lame on PATH for the `ff` columns, else those read `n/a`):

```sh
clue build benchmarks/bcodecs.nim --out:/tmp/bcodecs --release
/tmp/bcodecs
```

`bcodecs.nim` encodes shared deterministic fixtures (2 s stereo
sine at 44.1 kHz, 1 s seeded stereo noise, 1 s sine for AAC) with
every encoder, then decodes the bytes plus repo fixtures for the
decode-only formats. Encode cells report best-of-3 ours vs best-of-3
ffmpeg at the same setting, output size, and a quality metric with
each stream decoded by our decoder (exact / worst+mean s16 LSB /
PSNR past the AAC priming frame). Decode cells report best-of-10
ours vs best-of-3 `ffmpeg -f null -`. MP3 preset detail stays in
`bmp3.nim`; this file compares formats.

Method notes: ours is timed in-process on warm bytes, ffmpeg
end-to-end through the shell (spawn, startup, file I/O), so the `ff`
columns understate the ffmpeg codec itself, especially on small
files. The closure-timing hazard noted for this box does not fire
here: closure-param vs direct-call timing agrees (wav 1.7 vs
1.2 ms, AAC 1.157 vs 1.154 s on the same work).

## Baseline — 2026-11-27

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
```

Encode, 44.1 kHz stereo:

| Format    | Fixture  | Ours  | ffmpeg | Faster  | Ours size | ff size | Ours quality       | ff quality         |
|-----------|----------|-------|--------|---------|-----------|---------|--------------------|--------------------|
| WAV16     | sine 2 s | 1431x | 27x    | ours*   | 352844    | 352878  | exact              | exact              |
| ADPCM-MS  | sine 2 s | 22x   | 24x    | tie     | 92762     | 90236   | worst 43, mean 5   | worst 2569, mean 54 |
| ADPCM-IMA | sine 2 s | 27x   | 26x    | tie     | 90940     | 89182   | worst 424, mean 47 | worst 5841, mean 49 |
| FLAC      | sine 2 s | 2.9x  | 26x    | ff 9x   | 52857     | 63940   | exact              | exact              |
| FLAC      | noise 1 s| 2.0x  | 14x    | ff 7x   | 165796    | 175244  | exact              | exact              |
| MP3 128k  | sine 2 s | 1.6x  | 20x    | ff 13x  | 33017     | 33062   | 78.5 dB            | 37.0 dB            |
| MP3 128k  | noise 1 s| 0.1x  | 13x    | ff 131x | 17135     | 17180   | 14.6 dB            | 15.7 dB            |
| AAC 128k  | sine 1 s | 0.9x  | 10x    | ff 11x  | 5432      | 16062   | 47.6 dB            | 38.0 dB            |
| AAC 128k  | noise 1 s| 0.9x  | 10x    | ff 11x  | 85218     | 16303   | 47.0 dB            | 13.2 dB            |

\* WAV is memcpy-bound on both sides; the 53x gap is process-spawn
overhead, not codec speed.

Decode:

| Source          | Ours  | ffmpeg | Faster   |
|-----------------|-------|--------|----------|
| wav16           | 1260x | 26x    | ours 49x |
| adpcm-ms        | 1181x | 32x    | ours 37x |
| adpcm-ima       | 1228x | 32x    | ours 39x |
| flac sine       | 275x  | 35x    | ours 8x  |
| flac noise      | 505x  | 17x    | ours 30x |
| mp3 sine        | 182x  | 32x    | ours 6x  |
| mp3 noise       | 355x  | 17x    | ours 21x |
| aac sine        | 876x  | 18x    | ours 48x |
| aac noise       | 348x  | 17x    | ours 20x |
| vorbis fixture  | 176x  | 18x    | ours 10x |
| alac fixture    | 290x  | 17x    | ours 17x |
| aac-mp4 fixture | 657x  | 18x    | ours 36x |
| aiff fixture    | 4559x | 9x     | ours*    |
| caf fixture     | 4535x | 9x     | ours*    |

\* Tiny files (0.5 s audio); the ffmpeg side is almost entirely
process spawn.

Conclusion:

- Encode speed goes to ffmpeg everywhere that matters: FLAC 7–9x,
  MP3 13–131x, AAC 11x. WAV/ADPCM tie. Our hotspots explain it:
  Huffman table-select rebuilds (MP3 noise), direct-form MDCT
  (AAC), scalar single-thread FLAC.
- Encode quality is ours to keep: better on tones (MP3 78.5 dB,
  AAC 47.6 dB at a third of the bytes) and ADPCM (worst-case LSB
  error an order of magnitude under ffmpeg), on par on MP3 noise.
  The one red cell is AAC noise: transparent (47 dB) at 5x the
  128k budget — no rate loop yet, which is Step D work.
- Decode speed goes to us on every cell (6–500x in-process), with
  the stated spawn caveat on the ffmpeg side.
