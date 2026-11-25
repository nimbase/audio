## DSP: complex FFT and inverse MDCT (Vorbis synthesis).
##
## Ports `symphonia-core/src/dsp/{complex,fft/no_simd,mdct}.rs` (scalar
## path; SIMD later via nimsimd). The FFT uses the unrolled 2/4/8/16/32
## kernels plus the breadth-first generic merge with generated twiddles.

import std/math

type
  Complex32* = object
    re*, im*: float32

proc `+`*(a, b: Complex32): Complex32 {.inline.} =
  Complex32(re: a.re + b.re, im: a.im + b.im)

proc `-`*(a, b: Complex32): Complex32 {.inline.} =
  Complex32(re: a.re - b.re, im: a.im - b.im)

proc `*`*(a, b: Complex32): Complex32 {.inline.} =
  Complex32(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)

proc conj*(a: Complex32): Complex32 {.inline.} =
  Complex32(re: a.re, im: -a.im)

const FftMaxSize* = 1 shl 16

var fftTwiddles: seq[seq[Complex32]]
var fftTwiddlesReady = false

proc initFftTwiddles() =
  fftTwiddles = newSeq[seq[Complex32]](11) # sizes 64..65536
  for ti in 0 ..< 11:
    let n = 64 shl ti
    let half = n div 2
    let theta = PI / half.float64
    var t = newSeq[Complex32](half)
    for k in 0 ..< half:
      let a = theta * k.float64
      t[k] = Complex32(re: cos(a).float32, im: (-sin(a)).float32)
    fftTwiddles[ti] = t
  fftTwiddlesReady = true

proc fftTwiddle(n: int): seq[Complex32] {.inline.} =
  if not fftTwiddlesReady:
    initFftTwiddles()
  var k = 0
  var s = 64
  while s < n:
    s = s shl 1
    inc k
  fftTwiddles[k]

proc bitRevTable(n: int): seq[int] =
  ## Bit-reversal permutation for power-of-two `n` (u16 indices).
  result = newSeq[int](n)
  var bits = 0
  var m = n
  while m > 1:
    inc bits
    m = m shr 1
  for i in 0 ..< n:
    var r = 0
    for b in 0 ..< bits:
      if (i and (1 shl b)) != 0:
        r = r or (1 shl (bits - 1 - b))
    result[i] = r

type
  Fft* = object
    perm*: seq[int]

proc newFft*(n: int): Fft =
  assert (n and (n - 1)) == 0 and n <= FftMaxSize
  Fft(perm: bitRevTable(n))

proc size*(f: Fft): int {.inline.} = f.perm.len

proc fft2(x: var openArray[Complex32]) {.inline.} =
  let t = x[0]
  x[0] = t + x[1]
  x[1] = t - x[1]

proc fft4(x: var openArray[Complex32]) {.inline.} =
  let a0 = x[0] + x[1]
  let a1 = x[0] - x[1]
  let d0 = x[2] + x[3]
  let d1 = x[2] - x[3]
  let d1t = Complex32(re: d1.im, im: -d1.re)
  x[0] = a0 + d0
  x[1] = a1 + d1t
  x[2] = a0 - d0
  x[3] = a1 - d1t

proc fftKernel8(x: var openArray[Complex32]; o: int) =
  var x0 = [x[o], x[o+1], x[o+2], x[o+3]]
  var x1 = [x[o+4], x[o+5], x[o+6], x[o+7]]
  fft4(x0)
  fft4(x1)
  let s = 0.7071067811865476'f32 # 1/sqrt(2)
  let a1 = s * x1[1].re
  let b1 = s * x1[1].im
  let a3 = -s * x1[3].re
  let b3 = -s * x1[3].im
  let p = [
    x1[0],
    Complex32(re: a1 + b1, im: b1 - a1),
    Complex32(re: x1[2].im, im: -x1[2].re),
    Complex32(re: a3 - b3, im: a3 + b3),
  ]
  for i in 0 ..< 4:
    x[o+i] = x0[i] + p[i]
    x[o+4+i] = x0[i] - p[i]

proc fftKernel16(x: var openArray[Complex32]; o: int) =
  template mul(a, b, c, d: untyped): Complex32 =
    Complex32(re: a * c - b * d, im: b * c + a * d)
  fftKernel8(x, o)
  fftKernel8(x, o + 8)
  let s = 0.7071067811865476'f32
  let a2 = s * x[o+10].re
  let b2 = s * x[o+10].im
  let a6 = -s * x[o+14].re
  let b6 = -s * x[o+14].im
  var p: array[8, Complex32]
  # Constants carry the reference's exact signs.
  const k1r = 0.9238795325112867'f32
  const k1i = -0.3826834323650898'f32
  const k3r = 0.3826834323650898'f32
  const k3i = -0.9238795325112867'f32
  p[0] = x[o+8]
  p[1] = mul(x[o+9].re, x[o+9].im, k1r, k1i)
  p[2] = Complex32(re: a2 + b2, im: b2 - a2)
  p[3] = mul(x[o+11].re, x[o+11].im, k3r, k3i)
  p[4] = Complex32(re: x[o+12].im, im: -x[o+12].re)
  p[5] = mul(x[o+13].re, x[o+13].im, -k3r, k3i)
  p[6] = Complex32(re: a6 - b6, im: a6 + b6)
  p[7] = mul(x[o+15].re, x[o+15].im, -k1r, k1i)
  for i in 0 ..< 8:
    let a = x[o+i]
    x[o+i] = a + p[i]
    x[o+8+i] = a - p[i]

proc fftKernel32(x: var openArray[Complex32]; o: int) =
  fftKernel16(x, o)
  fftKernel16(x, o + 16)
  let s = 0.7071067811865476'f32
  let a4 = s * x[o+20].re
  let b4 = s * x[o+20].im
  let a12 = -s * x[o+28].re
  let b12 = -s * x[o+28].im
  const c0 = 0.9807852804032304'f32
  const s0 = -0.19509032201612825'f32
  const c1 = 0.9238795325112867'f32
  const s1 = -0.3826834323650898'f32
  const c2 = 0.8314696123025452'f32
  const s2 = -0.5555702330196022'f32
  const c3 = 0.5555702330196022'f32
  const s3 = -0.8314696123025452'f32
  const c5 = 0.3826834323650898'f32
  const s5 = -0.9238795325112867'f32
  const c6 = 0.19509032201612825'f32
  const s6 = -0.9807852804032304'f32
  template cmul(a, b, c, d: untyped): Complex32 =
    Complex32(re: a * c - b * d, im: b * c + a * d)
  var p: array[16, Complex32]
  p[0] = x[o+16]
  p[1] = cmul(x[o+17].re, x[o+17].im, c0, s0)
  p[2] = cmul(x[o+18].re, x[o+18].im, c1, s1)
  p[3] = cmul(x[o+19].re, x[o+19].im, c2, s2)
  p[4] = Complex32(re: a4 + b4, im: b4 - a4)
  p[5] = cmul(x[o+21].re, x[o+21].im, c3, s3)
  p[6] = cmul(x[o+22].re, x[o+22].im, c5, s5)
  p[7] = cmul(x[o+23].re, x[o+23].im, c6, s6)
  p[8] = Complex32(re: x[o+24].im, im: -x[o+24].re)
  p[9] = cmul(x[o+25].re, x[o+25].im, -c6, s6)
  p[10] = cmul(x[o+26].re, x[o+26].im, -c5, s5)
  p[11] = cmul(x[o+27].re, x[o+27].im, -c3, s3)
  p[12] = Complex32(re: a12 - b12, im: a12 + b12)
  p[13] = cmul(x[o+29].re, x[o+29].im, -c2, s2)
  p[14] = cmul(x[o+30].re, x[o+30].im, -c1, s1)
  p[15] = cmul(x[o+31].re, x[o+31].im, -c0, s0)
  for i in 0 ..< 16:
    let a = x[o+i]
    x[o+i] = a + p[i]
    x[o+16+i] = a - p[i]

proc fftMerge(even, odd: var openArray[Complex32];
    twiddles: openArray[Complex32]) =
  var ti = 0
  var i = 0
  while i < even.len:
    for k in 0 ..< 2:
      let p0 = even[i + k]
      let q0 = odd[i + k] * twiddles[ti]
      even[i + k] = p0 + q0
      odd[i + k] = p0 - q0
      inc ti
    i += 2

proc fftTransform(x: var openArray[Complex32]; n: int) =
  if n == 32:
    fftKernel32(x, 0)
    return
  var step = 32
  # First pass over 64-point chunks with 32-point halves.
  var tw = fftTwiddle(step shl 1)
  var pos = 0
  while pos < n:
    fftKernel32(x.toOpenArray(pos, pos + step - 1), 0)
    fftKernel32(x.toOpenArray(pos + step, pos + 2 * step - 1), 0)
    fftMerge(x.toOpenArray(pos, pos + step - 1),
      x.toOpenArray(pos + step, pos + 2 * step - 1), tw)
    pos += step shl 1
  step = step shl 1
  while step < n:
    tw = fftTwiddle(step shl 1)
    pos = 0
    while pos < n:
      fftMerge(x.toOpenArray(pos, pos + step - 1),
        x.toOpenArray(pos + step, pos + 2 * step - 1), tw)
      pos += step shl 1
    step = step shl 1

proc fftInplace*(f: var Fft; x: var openArray[Complex32]) =
  ## In-place forward FFT (bit-reversing + unrolled kernels).
  let n = x.len
  assert n == f.perm.len
  for i in 0 ..< n:
    let j = f.perm[i]
    if i < j:
      let t = x[i]
      x[i] = x[j]
      x[j] = t
  case n
  of 1: discard
  of 2: fft2(x)
  of 4: fft4(x)
  of 8:
    fftKernel8(x, 0)
  of 16:
    fftKernel16(x, 0)
  else:
    fftTransform(x, n)

# --------------------------------------------------------------- IMDCT ---

type
  Imdct* = object
    fft*: Fft
    scratch*: seq[Complex32]
    twiddle*: seq[Complex32]

proc newImdct*(n: int; scale = 1.0): Imdct =
  ## N-point IMDCT (n power of two). Output length is 2N.
  assert (n and (n - 1)) == 0
  assert n <= 2 * FftMaxSize
  let n2 = n div 2
  let alpha = 1.0 / 8.0
  let piN = PI / n.float64
  let sq = sqrt(abs(scale))
  var tw = newSeq[Complex32](n2)
  for k in 0 ..< n2:
    let theta = piN * (alpha + k.float64)
    tw[k] = Complex32(re: (sq * cos(theta)).float32,
      im: (sq * sin(theta)).float32)
  Imdct(fft: newFft(n2), scratch: newSeq[Complex32](n2), twiddle: tw)

proc imdct*(m: var Imdct; spec: openArray[float32]; output: var openArray[float32]) =
  ## N spectral samples -> 2N time samples.
  let n = m.fft.size() shl 1
  let n2 = n shr 1
  let n4 = n shr 2
  assert spec.len == n
  assert output.len == 2 * n
  if not fftTwiddlesReady:
    initFftTwiddles()
  for i in 0 ..< n2:
    let even = spec[i * 2]
    let odd = -spec[n - 1 - i * 2]
    let w = m.twiddle[i]
    let re = odd * w.im - even * w.re
    let im = odd * w.re + even * w.im
    m.scratch[i] = Complex32(re: re, im: im)
  m.fft.fftInplace(m.scratch)
  for i in 0 ..< n4:
    let w = m.twiddle[i]
    let x = m.scratch[i]
    let val = Complex32(re: w.re * x.re + w.im * x.im,
      im: w.im * x.re - w.re * x.im) # w * conj(x)
    let fi = 2 * i
    let ri = n2 - 1 - 2 * i
    output[ri] = -val.im
    output[n2 + fi] = val.im
    output[n2 + n2 + ri] = val.re
    output[n2 + n2 + n2 + fi] = val.re
  for i in n4 ..< n2:
    let w = m.twiddle[i]
    let x = m.scratch[i]
    let val = Complex32(re: w.re * x.re + w.im * x.im,
      im: w.im * x.re - w.re * x.im)
    let fi = 2 * (i - n4)
    let ri = n2 - 1 - 2 * (i - n4)
    output[fi] = -val.re
    output[n2 + ri] = val.re
    output[n2 + n2 + fi] = val.im
    output[n2 + n2 + n2 + ri] = val.im
