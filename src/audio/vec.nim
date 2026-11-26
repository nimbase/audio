## Float32 vector kernels: SIMD fast paths with scalar fallbacks.
##
## `amd64` runs the 4-wide SSE2 path (SSE2 is x86-64 baseline, so no C
## compiler flags and no runtime dispatch are needed); every other CPU
## uses the scalar loop. Paths are bit-identical by construction (same
## per-lane operation order), pinned by `tests/tvorbis.nim` and
## `tests/tmpa.nim`.
## Wider ISAs (AVX2/FMA) stay out until a kernel proves SSE2-bound.

when defined(amd64) and not defined(vecScalar):
  import nimsimd/sse2

proc overlapAddVec*(outp: var openArray[float32]; left, right,
    win: openArray[float32]) =
  ## `outp[i] = left[i]*win[n-1-i] + right[i]*win[i]`.
  assert outp.len == left.len and left.len == right.len and
    right.len == win.len
  let n = outp.len
  when defined(amd64) and not defined(vecScalar):
    var i = 0
    let n4 = n and (not 3)
    while i < n4:
      let l = mm_loadu_ps(left[i].unsafeAddr)
      let r = mm_loadu_ps(right[i].unsafeAddr)
      let w = mm_loadu_ps(win[i].unsafeAddr)
      # Reversed window segment win[n-1-i .. n-4-i]: load forward, reverse.
      let w0 = mm_loadu_ps(win[n - 4 - i].unsafeAddr)
      let wr = mm_shuffle_ps(w0, w0, MM_SHUFFLE(0, 1, 2, 3))
      mm_storeu_ps(outp[i].addr, mm_add_ps(mm_mul_ps(l, wr),
        mm_mul_ps(r, w)))
      i += 4
    while i < n:
      outp[i] = left[i] * win[n - 1 - i] + right[i] * win[i]
      inc i
  else:
    for i in 0 ..< n:
      outp[i] = left[i] * win[n - 1 - i] + right[i] * win[i]

proc synthWindowAccum32Vec*(outp: var openArray[float32]; vA, vB, dA,
    dB: openArray[float32]) =
  ## `outp[i] += vA[i]*dA[i] + vB[i]*dB[i]` for exactly 32 elements
  ## (MP3 polyphase windowing row; 32 needs no tail loop).
  assert outp.len == 32 and vA.len == 32 and vB.len == 32 and
    dA.len == 32 and dB.len == 32
  when defined(amd64) and not defined(vecScalar):
    var i = 0
    while i < 32:
      let a = mm_loadu_ps(vA[i].unsafeAddr)
      let b = mm_loadu_ps(vB[i].unsafeAddr)
      let c = mm_loadu_ps(dA[i].unsafeAddr)
      let d = mm_loadu_ps(dB[i].unsafeAddr)
      let o = mm_loadu_ps(outp[i].unsafeAddr)
      mm_storeu_ps(outp[i].addr,
        mm_add_ps(o, mm_add_ps(mm_mul_ps(a, c), mm_mul_ps(b, d))))
      i += 4
  else:
    for i in 0 ..< 32:
      outp[i] += vA[i] * dA[i] + vB[i] * dB[i]
