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
