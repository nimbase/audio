## Float32 vector kernels: SIMD fast paths with scalar fallbacks.
##
## `amd64` runs the 4-wide SSE2 path (SSE2 is x86-64 baseline, so no C
## compiler flags and no runtime dispatch are needed); every other CPU
## uses the scalar loop. Paths are bit-identical by construction (same
## per-lane operation order), pinned by `tests/tvorbis.nim`.
## Wider ISAs (AVX2/FMA) stay out until a kernel proves SSE2-bound.

when defined(amd64):
  import nimsimd/sse2

proc overlapAddVec*(outp: var openArray[float32]; left, right,
    win: openArray[float32]) =
  ## `outp[i] = left[i]*win[n-1-i] + right[i]*win[i]`.
  assert outp.len == left.len and left.len == right.len and
    right.len == win.len
  let n = outp.len
  when defined(amd64):
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
