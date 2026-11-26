import std/options
import std/strutils
import unittest

import audio/codecs/vorbis
import audio/errors
import audio/vec

proc naiveLookup1(entries: uint32; dims: int): uint32 =
  ## Brute-force spec definition: greatest x with x^dims <= entries.
  if dims <= 0:
    return 0
  var x = 0'u32
  while true:
    let nxt = x + 1
    var p = 1'u64
    var overflow = false
    for _ in 0 ..< dims:
      p *= nxt.uint64
      if p > entries.uint64:
        overflow = true
        break
    if overflow or p > entries.uint64:
      break
    x = nxt
  x

suite "vorbis unit ports":
  test "ilog matches reference vectors":
    check ilog(0) == 0
    check ilog(1) == 1
    check ilog(2) == 2
    check ilog(3) == 2
    check ilog(4) == 3
    check ilog(7) == 3

  test "lookup1_values matches naive":
    for (entries, dims) in [(0'u32, 0), (1'u32, 0), (0'u32, 1),
        (1'u32, 1), (361'u32, 2), (560'u32, 3), (0xffff'u32, 0xff),
        (0'u32, 8), (1'u32, 8), (128'u32, 3), (841'u32, 2)]:
      check lookup1Values(entries, dims) == naiveLookup1(entries, dims)

  test "synthesize_codewords reference vector":
    let lens = @[2'u8, 4, 4, 4, 4, 2, 3, 3]
    check synthesizeCodewords(lens) ==
      @[0'u32, 0x4, 0x5, 0x6, 0x7, 0x2, 0x6, 0x7]

  test "synthesize_codewords rejects overspecified":
    try:
      discard synthesizeCodewords(@[1'u8, 1, 1])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard synthesizeCodewords(@[1'u8, 1, 32])
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "xiph lacing splits ident and setup":
    var ident = newSeq[uint8](30)
    for i in 0 ..< 30:
      ident[i] = cast[uint8](i)
    var setup = newSeq[uint8](300)
    for i in 0 ..< 300:
      setup[i] = cast[uint8](i and 0xff)
    var comment = newSeq[uint8](10)
    # extra = 0x02, lace(ident=30), lace(comment=10), ident, comment, setup.
    var extra = @[0x02'u8, 30, 10]
    extra.add(ident)
    extra.add(comment)
    extra.add(setup)
    let (gotIdent, gotSetup) = unpackXiphLaced(extra)
    check gotIdent == ident
    check gotSetup == setup

  test "xiph lacing rejects malformed":
    try:
      discard unpackXiphLaced(@[])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard unpackXiphLaced(@[0x01'u8, 0x02])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard unpackXiphLaced(@[0x02'u8, 30])
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "simd vector kernels":
  test "overlapAddVec bit-matches scalar on hostile lengths":
    var s = 0x2B7E1516'u32
    proc rnd(): float32 =
      s = s * 1664525'u32 + 1013904223'u32
      (((s shr 16) and 0xFFFF'u32).int32 - 32768).float32 / 32768.0
    for n in [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63,
        64, 65, 100, 1000, 4096]:
      var left = newSeq[float32](n)
      var right = newSeq[float32](n)
      var win = newSeq[float32](n)
      for i in 0 ..< n:
        left[i] = rnd()
        right[i] = rnd()
        win[i] = rnd()
      var got = newSeq[float32](n)
      var want = newSeq[float32](n)
      overlapAddVec(got, left, right, win)
      for i in 0 ..< n:
        want[i] = left[i] * win[n - 1 - i] + right[i] * win[i]
      check got == want
