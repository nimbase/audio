import std/math
import unittest

import audio/dsp

proc dftNaive(x: openArray[Complex32]): seq[Complex32] =
  result = newSeq[Complex32](x.len)
  let n = x.len
  for i in 0 ..< n:
    var re = 0.0
    var im = 0.0
    for j in 0 ..< n:
      let a = 2 * PI * i.float64 * j.float64 / n.float64
      re += x[j].re.float64 * cos(a) + x[j].im.float64 * sin(a)
      im += x[j].im.float64 * cos(a) - x[j].re.float64 * sin(a)
    # Note: forward DFT sign convention matches the reference test
    # (wre = cos, wim = -sin with re += xre*wre - xim*wim).
    result[i] = Complex32(re: re.float32, im: im.float32)

proc dftFwd(x: openArray[Complex32]): seq[Complex32] =
  ## Reference forward DFT: X[k] = sum x[j] * (cos - i sin).
  result = newSeq[Complex32](x.len)
  let n = x.len
  for i in 0 ..< n:
    var re = 0.0
    var im = 0.0
    for j in 0 ..< n:
      let a = 2 * PI * i.float64 * j.float64 / n.float64
      let wre = cos(a)
      let wim = -sin(a)
      re += x[j].re.float64 * wre - x[j].im.float64 * wim
      im += x[j].re.float64 * wim + x[j].im.float64 * wre
    result[i] = Complex32(re: re.float32, im: im.float32)

suite "fft":
  test "matches naive dft":
    var k = 0x12345
    proc rnd(): float32 =
      k = (k * 1103515245 + 12345) and 0x7fffffff
      cast[float32](k mod 2000) / 1000.0 - 1.0
    for n in [2, 4, 8, 16, 32, 64, 128, 256]:
      var x = newSeq[Complex32](n)
      for i in 0 ..< n:
        x[i] = Complex32(re: rnd(), im: rnd())
      let expected = dftFwd(x)
      var f = newFft(n)
      var got = x
      f.fftInplace(got)
      for i in 0 ..< n:
        check abs(got[i].re - expected[i].re) < 1e-3
        check abs(got[i].im - expected[i].im) < 1e-3
    doAssert dftNaive(@[Complex32(re: 1, im: 0)])[0].re == 1.0

  test "imdct matches analytical":
    var input: array[32, float32]
    for i in 0 ..< 32:
      input[i] = (i + 1).float32
    var actual = newSeq[float32](64)
    var imdct = newImdct(32, sqrt(2.0 / 64.0))
    imdct.imdct(input, actual.toOpenArray(0, 63))
    let pi128 = PI / 128.0
    for i in 0 ..< 64:
      var acc = 0.0
      for j in 0 ..< 32:
        acc += input[j].float64 *
          cos(pi128 * (2 * i + 1 + 32).float64 * (2 * j + 1).float64)
      let expected = sqrt(2.0 / 64.0) * acc
      check abs(actual[i].float64 - expected) < 0.00001
