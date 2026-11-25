## Checksums: CRC-8/CCITT, CRC-16/ANSI (+LE), CRC-32, MD5.
##
## Ports `symphonia-core/src/checksum/{crc8,crc16,crc32,md5}.rs`. Tables
## are generated at startup from the same polynomials rather than
## transcribed, and verified against the reference vectors in tests.
## CRC-8/16 cover FLAC frame headers/footers; CRC-32 covers Ogg pages;
## MD5 covers FLAC stream validation.

var crc8Table: array[256, uint8]
var crc8Ready = false

proc initCrc8() =
  for i in 0 ..< 256:
    var crc = i
    for _ in 0 ..< 8:
      if (crc and 0x80) != 0:
        crc = ((crc shl 1) xor 0x07) and 0xff
      else:
        crc = (crc shl 1) and 0xff
    crc8Table[i] = cast[uint8](crc)
  crc8Ready = true

proc crc8*(data: openArray[uint8]; init = 0'u8): uint8 =
  ## CRC-8/CCITT (poly 0x07, init 0). Standard check: "123456789" -> 0xF4.
  if not crc8Ready:
    initCrc8()
  var state = init
  for b in data:
    state = crc8Table[state xor b]
  state

var crc16Table: array[256, uint16]
var crc16Ready = false

proc initCrc16() =
  for i in 0 ..< 256:
    var crc = i shl 8
    for _ in 0 ..< 8:
      if (crc and 0x8000) != 0:
        crc = ((crc shl 1) xor 0x8005) and 0xffff
      else:
        crc = (crc shl 1) and 0xffff
    crc16Table[i] = cast[uint16](crc)
  crc16Ready = true

proc crc16Ansi*(data: openArray[uint8]; init = 0'u16): uint16 =
  ## CRC-16/ANSI, big-endian order (poly 0x8005, init 0). FLAC frame
  ## footers. Standard check ("BUYPASS" params): "123456789" -> 0xFEE8.
  if not crc16Ready:
    initCrc16()
  var state = init
  for b in data:
    state = (state shl 8) xor crc16Table[(state shr 8) xor b.uint16]
  state

# Note: the little-endian twin (MP3 frame CRCs) arrives with Phase 6.

var crc16LeTable: array[256, uint16]
var crc16LeReady = false

proc initCrc16Le() =
  for i in 0 ..< 256:
    var crc = i.uint16
    for _ in 0 ..< 8:
      if (crc and 1) != 0:
        crc = (crc shr 1) xor 0xa001'u16 # Reflected 0x8005.
      else:
        crc = crc shr 1
    crc16LeTable[i] = crc
  crc16LeReady = true

proc crc16AnsiLe*(data: openArray[uint8]; init = 0'u16): uint16 =
  ## CRC-16/ANSI reflected (poly 0x8005, init 0). MP3 LAME-tag check.
  ## Check ("BUYPASS" params): "123456789" -> 0xBB3D.
  if not crc16LeReady:
    initCrc16Le()
  var state = init
  for b in data:
    state = (state shr 8) xor crc16LeTable[(state and 0xff'u16) xor b.uint16]
  state

var crc32Table: array[256, uint32]
var crc32Ready = false

proc initCrc32() =
  for i in 0 ..< 256:
    var crc = i.uint32
    for _ in 0 ..< 8:
      if (crc and 1) != 0:
        crc = (crc shr 1) xor 0xedb88320'u32
      else:
        crc = crc shr 1
    crc32Table[i] = crc
  crc32Ready = true

var crc32Mpeg2Table: array[256, uint32]
var crc32Mpeg2Ready = false

proc initCrc32Mpeg2() =
  for i in 0 ..< 256:
    var crc = i.uint32 shl 24
    for _ in 0 ..< 8:
      if (crc and 0x8000_0000'u32) != 0:
        crc = (crc shl 1) xor 0x04c11db7'u32
      else:
        crc = crc shl 1
    crc32Mpeg2Table[i] = crc
  crc32Mpeg2Ready = true

proc crc32Mpeg2*(data: openArray[uint8]): uint32 =
  ## CRC-32/MPEG-2 (poly 0x04C11DB7, init 0, no xorout). Ogg pages.
  ## Check: "123456789" -> 0x0376E6E7.
  if not crc32Mpeg2Ready:
    initCrc32Mpeg2()
  var state = 0'u32
  for b in data:
    state = (state shl 8) xor crc32Mpeg2Table[(state shr 24) xor b.uint32]
  state

proc crc32*(data: openArray[uint8]): uint32 =
  ## Standard CRC-32 (init 0xFFFFFFFF, xorout 0xFFFFFFFF). Ogg pages.
  ## Check: "123456789" -> 0xCBF43926.
  if not crc32Ready:
    initCrc32()
  var state = 0xffff_ffff'u32
  for b in data:
    state = (state shr 8) xor crc32Table[(state xor b.uint32) and 0xff'u32]
  state xor 0xffff_ffff'u32

# ------------------------------------------------------------------ MD5 ---

type
  Md5* = object
    ## Standard MD5. Port of Symphonia's `checksum::Md5`.
    state: array[4, uint32]
    blk: array[64, uint8]
    len: uint64

proc initMd5*(m: var Md5) =
  m.state = [0x67452301'u32, 0xefcdab89'u32, 0x98badcfe'u32, 0x10325476'u32]
  m.blk = default(array[64, uint8])
  m.len = 0

proc newMd5*(): Md5 =
  result.initMd5()

proc rotl(v: uint32; s: int): uint32 {.inline.} =
  (v shl s) or (v shr (32 - s))

proc md5Round(a: var uint32; b, f: uint32; m, k: uint32; s: int) {.inline.} =
  # Plain + wraps mod 2^32 for uint32 (verified), matching MD5 semantics.
  a = f + a + k + m
  a = b + rotl(a, s)

proc md5Transform(state: var array[4, uint32]; buf: openArray[uint8]) =
  assert buf.len == 64
  var input: array[16, uint32]
  for i in 0 ..< 16:
    input[i] = buf[i * 4].uint32 or (buf[i * 4 + 1].uint32 shl 8) or
      (buf[i * 4 + 2].uint32 shl 16) or (buf[i * 4 + 3].uint32 shl 24)
  var a = state[0]
  var b = state[1]
  var c = state[2]
  var d = state[3]

  template step(ra, rb, rc, rd, f, m, s, k: untyped) =
    md5Round(ra, rb, f, input[m], k, s)

  # Round 1: F = D ^ (B & (C ^ D)).
  step(a, b, c, d, d xor (b and (c xor d)), 0, 7, 0xd76aa478'u32)
  step(d, a, b, c, c xor (a and (b xor c)), 1, 12, 0xe8c7b756'u32)
  step(c, d, a, b, b xor (d and (a xor b)), 2, 17, 0x242070db'u32)
  step(b, c, d, a, a xor (c and (d xor a)), 3, 22, 0xc1bdceee'u32)
  step(a, b, c, d, d xor (b and (c xor d)), 4, 7, 0xf57c0faf'u32)
  step(d, a, b, c, c xor (a and (b xor c)), 5, 12, 0x4787c62a'u32)
  step(c, d, a, b, b xor (d and (a xor b)), 6, 17, 0xa8304613'u32)
  step(b, c, d, a, a xor (c and (d xor a)), 7, 22, 0xfd469501'u32)
  step(a, b, c, d, d xor (b and (c xor d)), 8, 7, 0x698098d8'u32)
  step(d, a, b, c, c xor (a and (b xor c)), 9, 12, 0x8b44f7af'u32)
  step(c, d, a, b, b xor (d and (a xor b)), 10, 17, 0xffff5bb1'u32)
  step(b, c, d, a, a xor (c and (d xor a)), 11, 22, 0x895cd7be'u32)
  step(a, b, c, d, d xor (b and (c xor d)), 12, 7, 0x6b901122'u32)
  step(d, a, b, c, c xor (a and (b xor c)), 13, 12, 0xfd987193'u32)
  step(c, d, a, b, b xor (d and (a xor b)), 14, 17, 0xa679438e'u32)
  step(b, c, d, a, a xor (c and (d xor a)), 15, 22, 0x49b40821'u32)

  # Round 2: G = C ^ (D & (B ^ C)).
  step(a, b, c, d, c xor (d and (b xor c)), 1, 5, 0xf61e2562'u32)
  step(d, a, b, c, b xor (c and (a xor b)), 6, 9, 0xc040b340'u32)
  step(c, d, a, b, a xor (b and (d xor a)), 11, 14, 0x265e5a51'u32)
  step(b, c, d, a, d xor (a and (c xor d)), 0, 20, 0xe9b6c7aa'u32)
  step(a, b, c, d, c xor (d and (b xor c)), 5, 5, 0xd62f105d'u32)
  step(d, a, b, c, b xor (c and (a xor b)), 10, 9, 0x02441453'u32)
  step(c, d, a, b, a xor (b and (d xor a)), 15, 14, 0xd8a1e681'u32)
  step(b, c, d, a, d xor (a and (c xor d)), 4, 20, 0xe7d3fbc8'u32)
  step(a, b, c, d, c xor (d and (b xor c)), 9, 5, 0x21e1cde6'u32)
  step(d, a, b, c, b xor (c and (a xor b)), 14, 9, 0xc33707d6'u32)
  step(c, d, a, b, a xor (b and (d xor a)), 3, 14, 0xf4d50d87'u32)
  step(b, c, d, a, d xor (a and (c xor d)), 8, 20, 0x455a14ed'u32)
  step(a, b, c, d, c xor (d and (b xor c)), 13, 5, 0xa9e3e905'u32)
  step(d, a, b, c, b xor (c and (a xor b)), 2, 9, 0xfcefa3f8'u32)
  step(c, d, a, b, a xor (b and (d xor a)), 7, 14, 0x676f02d9'u32)
  step(b, c, d, a, d xor (a and (c xor d)), 12, 20, 0x8d2a4c8a'u32)

  # Round 3: H = B ^ C ^ D.
  step(a, b, c, d, b xor c xor d, 5, 4, 0xfffa3942'u32)
  step(d, a, b, c, a xor b xor c, 8, 11, 0x8771f681'u32)
  step(c, d, a, b, d xor a xor b, 11, 16, 0x6d9d6122'u32)
  step(b, c, d, a, c xor d xor a, 14, 23, 0xfde5380c'u32)
  step(a, b, c, d, b xor c xor d, 1, 4, 0xa4beea44'u32)
  step(d, a, b, c, a xor b xor c, 4, 11, 0x4bdecfa9'u32)
  step(c, d, a, b, d xor a xor b, 7, 16, 0xf6bb4b60'u32)
  step(b, c, d, a, c xor d xor a, 10, 23, 0xbebfbc70'u32)
  step(a, b, c, d, b xor c xor d, 13, 4, 0x289b7ec6'u32)
  step(d, a, b, c, a xor b xor c, 0, 11, 0xeaa127fa'u32)
  step(c, d, a, b, d xor a xor b, 3, 16, 0xd4ef3085'u32)
  step(b, c, d, a, c xor d xor a, 6, 23, 0x04881d05'u32)
  step(a, b, c, d, b xor c xor d, 9, 4, 0xd9d4d039'u32)
  step(d, a, b, c, a xor b xor c, 12, 11, 0xe6db99e5'u32)
  step(c, d, a, b, d xor a xor b, 15, 16, 0x1fa27cf8'u32)
  step(b, c, d, a, c xor d xor a, 2, 23, 0xc4ac5665'u32)

  # Round 4: I = C ^ (B | ~D).
  step(a, b, c, d, c xor (b or (not d)), 0, 6, 0xf4292244'u32)
  step(d, a, b, c, b xor (a or (not c)), 7, 10, 0x432aff97'u32)
  step(c, d, a, b, a xor (d or (not b)), 14, 15, 0xab9423a7'u32)
  step(b, c, d, a, d xor (c or (not a)), 5, 21, 0xfc93a039'u32)
  step(a, b, c, d, c xor (b or (not d)), 12, 6, 0x655b59c3'u32)
  step(d, a, b, c, b xor (a or (not c)), 3, 10, 0x8f0ccc92'u32)
  step(c, d, a, b, a xor (d or (not b)), 10, 15, 0xffeff47d'u32)
  step(b, c, d, a, d xor (c or (not a)), 1, 21, 0x85845dd1'u32)
  step(a, b, c, d, c xor (b or (not d)), 8, 6, 0x6fa87e4f'u32)
  step(d, a, b, c, b xor (a or (not c)), 15, 10, 0xfe2ce6e0'u32)
  step(c, d, a, b, a xor (d or (not b)), 6, 15, 0xa3014314'u32)
  step(b, c, d, a, d xor (c or (not a)), 13, 21, 0x4e0811a1'u32)
  step(a, b, c, d, c xor (b or (not d)), 4, 6, 0xf7537e82'u32)
  step(d, a, b, c, b xor (a or (not c)), 11, 10, 0xbd3af235'u32)
  step(c, d, a, b, a xor (d or (not b)), 2, 15, 0x2ad7d2bb'u32)
  step(b, c, d, a, d xor (c or (not a)), 9, 21, 0xeb86d391'u32)

  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d

proc update*(m: var Md5; data: openArray[uint8]) =
  var pos = 0
  while pos < data.len:
    let blockLen = (m.len and 0x3f).int
    let copyLen = min(data.len - pos, 64 - blockLen)
    m.len += copyLen.uint64
    if copyLen == 64:
      var tmp: array[64, uint8]
      for i in 0 ..< 64:
        tmp[i] = data[pos + i]
      md5Transform(m.state, tmp)
    else:
      for i in 0 ..< copyLen:
        m.blk[blockLen + i] = data[pos + i]
      if (m.len and 0x3f) == 0:
        md5Transform(m.state, m.blk)
    pos += copyLen

proc digest*(m: Md5): array[16, uint8] =
  ## Finalizes a copy and returns the hash.
  var blk: array[64, uint8]
  var state = m.state
  let blockLen = (m.len and 0x3f).int
  for i in 0 ..< blockLen:
    blk[i] = m.blk[i]
  blk[blockLen] = 0x80
  if 64 - blockLen - 1 < 8:
    md5Transform(state, blk)
    blk = default(array[64, uint8])
  let bitLen = m.len shl 3
  for i in 0 ..< 8:
    blk[56 + i] = (bitLen shr (8 * i)).uint8
  md5Transform(state, blk)
  for i in 0 ..< 4:
    let w = state[i]
    result[i * 4] = w.uint8
    result[i * 4 + 1] = (w shr 8).uint8
    result[i * 4 + 2] = (w shr 16).uint8
    result[i * 4 + 3] = (w shr 24).uint8
