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

## Baseline — 2026-11-27

```text
nim 2.4.0  hostOS=macosx  cpu=amd64
--- encode: wav/adpcm (sine2) ---
wav16   ours  1431.1x   352844B exact | ff    27.2x   352878B exact
adpcm-ms   ours    22.4x    92762B worst=43 mean=5 | ff    24.0x    90236B worst=2569 mean=54
adpcm-ima  ours    26.8x    90940B worst=424 mean=47 | ff    26.0x    89182B worst=5841 mean=49
--- encode: flac (sine2, noise1) ---
flac-sine2  ours     2.9x    52857B exact-frames | ff    26.1x    63940B exact-frames
flac-noise1 ours     2.0x   165796B exact-frames | ff    14.0x   175244B exact-frames
--- encode: mp3 128k gapless (sine2, noise1) ---
mp3-sine2  ours     1.6x    33017B psnr  78.5dB | ff    20.1x    33062B psnr  37.0dB
mp3-noise1 ours     0.1x    17135B psnr  14.6dB | ff    13.1x    17180B psnr  15.7dB
--- encode: aac 128k (sine1, noise1) ---
aac-sine1  ours     0.9x     5432B psnr  47.6dB | ff    10.2x    16062B psnr  38.0dB
aac-noise1 ours     0.9x    85218B psnr  47.0dB | ff     9.9x    16303B psnr  13.2dB
--- decode ours vs ff ---
dec wav16            ours  1260.3x | ff    25.7x
dec adpcm-ms         ours  1181.3x | ff    32.3x
dec adpcm-ima        ours  1227.9x | ff    31.5x
dec flac-sine2       ours   274.9x | ff    34.9x
dec flac-noise1      ours   505.4x | ff    17.1x
dec mp3-sine2        ours   181.8x | ff    31.7x
dec mp3-noise1       ours   354.5x | ff    17.0x
dec aac-sine1        ours   875.5x | ff    18.3x
dec aac-noise1       ours   347.6x | ff    17.3x
dec vorbis           ours   175.8x | ff    17.8x
dec alac             ours   289.7x | ff    17.4x
dec aac-mp4          ours   656.8x | ff    18.4x
dec aiff             ours  4559.3x | ff     9.0x
dec caf              ours  4535.3x | ff     9.0x
```

Notes:

- Tones flatter our encoders: MP3/AAC sine PSNR clears ffmpeg's at
  the same or smaller size (our tone path is near-transparent).
- Noise tells the rate-control story: MP3 lands on budget and within
  1 dB of lame (14.6 vs 15.7 dB), while AAC Step C has no rate loop
  yet — transparent (47 dB) at 5x the 128k budget (85 kB for 1 s).
  The loop is Step D work.
- ADPCM: our encoders search all candidates per nibble (MS tries all
  7 predictors), so worst-case error stays far below ffmpeg's fast
  predictors at the same speed.
- FLAC is lossless both sides; ours packs tones tighter (LPC-32).
- `ff` decode columns on small files are process-spawn dominated;
  ours decodes fixtures at 175–4800× realtime.
