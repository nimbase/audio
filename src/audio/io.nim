## In-memory byte cursor (reader) and byte assembler (writer).
##
## Mirrors the subset of `symphonia-core/src/io/{mod,buf_reader}.rs` needed
## for Phase 1/2: exact-width little/big-endian primitive reads with
## underrun errors (`ekDecode`), plus a little-endian writer used by the
## WAV muxer. Buffered/streaming I/O over files arrives with the Ogg/MP4
## demuxers (Phase 5+).

import std/algorithm
import std/sequtils
import ./errors

type
  Reader* = object
    ## Cursor over an immutable byte buffer.
    data*: seq[uint8]
    pos*: int

  Writer* = object
    ## Growable byte buffer with LE/BE primitive writers.
    buf*: seq[uint8]

# ---------------------------------------------------------------- Reader ---

proc newReader*(data: seq[uint8]): Reader {.inline.} =
  Reader(data: data, pos: 0)

proc newReader*(data: openArray[uint8]): Reader {.inline.} =
  Reader(data: data.toSeq(), pos: 0)

proc len*(r: Reader): int {.inline.} = r.data.len
proc remaining*(r: Reader): int {.inline.} = r.data.len - r.pos
proc isEmpty*(r: Reader): bool {.inline.} = r.pos >= r.data.len

proc need(r: Reader; n: int) {.inline.} =
  if r.pos + n > r.data.len:
    raise decodeError("buffer underrun")

proc readByte*(r: var Reader): uint8 {.inline.} =
  r.need(1)
  result = r.data[r.pos]
  inc r.pos

proc readBytes*(r: var Reader; n: int): seq[uint8] =
  ## Reads up to `n` bytes (short read at end of buffer, never an error).
  let avail = min(n, r.remaining())
  result = r.data[r.pos ..< r.pos + avail]
  r.pos += avail

proc readBytesExact*(r: var Reader; n: int): seq[uint8] =
  r.need(n)
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc ignoreBytes*(r: var Reader; n: int) {.inline.} =
  r.need(n)
  r.pos += n

proc readU16Le*(r: var Reader): uint16 {.inline.} =
  r.need(2)
  result = r.data[r.pos].uint16 or (r.data[r.pos + 1].uint16 shl 8)
  r.pos += 2

proc readU16Be*(r: var Reader): uint16 {.inline.} =
  r.need(2)
  result = (r.data[r.pos].uint16 shl 8) or r.data[r.pos + 1].uint16
  r.pos += 2

proc readI16Le*(r: var Reader): int16 {.inline.} = cast[int16](r.readU16Le())
proc readI16Be*(r: var Reader): int16 {.inline.} = cast[int16](r.readU16Be())

proc readU24Le*(r: var Reader): uint32 {.inline.} =
  ## Unsigned 24-bit LE in the low 24 bits of the result.
  r.need(3)
  result =
    r.data[r.pos].uint32 or
    (r.data[r.pos + 1].uint32 shl 8) or
    (r.data[r.pos + 2].uint32 shl 16)
  r.pos += 3

proc readU24Be*(r: var Reader): uint32 {.inline.} =
  r.need(3)
  result =
    (r.data[r.pos].uint32 shl 16) or
    (r.data[r.pos + 1].uint32 shl 8) or
    r.data[r.pos + 2].uint32
  r.pos += 3

proc readI24Le*(r: var Reader): int32 {.inline.} =
  ## Signed 24-bit LE, sign-extended to 32 bits (LSB-aligned).
  let u = r.readU24Le()
  result = cast[int32](u shl 8) shr 8

proc readI24Be*(r: var Reader): int32 {.inline.} =
  let u = r.readU24Be()
  result = cast[int32](u shl 8) shr 8

proc readU32Le*(r: var Reader): uint32 {.inline.} =
  r.need(4)
  result =
    r.data[r.pos].uint32 or
    (r.data[r.pos + 1].uint32 shl 8) or
    (r.data[r.pos + 2].uint32 shl 16) or
    (r.data[r.pos + 3].uint32 shl 24)
  r.pos += 4

proc readU32Be*(r: var Reader): uint32 {.inline.} =
  r.need(4)
  result =
    (r.data[r.pos].uint32 shl 24) or
    (r.data[r.pos + 1].uint32 shl 16) or
    (r.data[r.pos + 2].uint32 shl 8) or
    r.data[r.pos + 3].uint32
  r.pos += 4

proc readI32Le*(r: var Reader): int32 {.inline.} = cast[int32](r.readU32Le())
proc readI32Be*(r: var Reader): int32 {.inline.} = cast[int32](r.readU32Be())

proc readU64Le*(r: var Reader): uint64 =
  r.need(8)
  result = 0
  for i in 0 ..< 8:
    result = result or (r.data[r.pos + i].uint64 shl (8 * i))
  r.pos += 8

proc readU64Be*(r: var Reader): uint64 =
  r.need(8)
  result = 0
  for i in 0 ..< 8:
    result = result or (r.data[r.pos + i].uint64 shl (8 * (7 - i)))
  r.pos += 8

proc readI64Le*(r: var Reader): int64 {.inline.} = cast[int64](r.readU64Le())
proc readI64Be*(r: var Reader): int64 {.inline.} = cast[int64](r.readU64Be())

proc readF32Le*(r: var Reader): float32 {.inline.} = cast[float32](r.readU32Le())
proc readF32Be*(r: var Reader): float32 {.inline.} = cast[float32](r.readU32Be())

proc readF64Le*(r: var Reader): float64 =
  r.need(8)
  var u: uint64 = 0
  for i in 0 ..< 8:
    u = u or (r.data[r.pos + i].uint64 shl (8 * i))
  r.pos += 8
  cast[float64](u)

proc readF64Be*(r: var Reader): float64 =
  r.need(8)
  var u: uint64 = 0
  for i in 0 ..< 8:
    u = u or (r.data[r.pos + i].uint64 shl (8 * (7 - i)))
  r.pos += 8
  cast[float64](u)

proc readFourCc*(r: var Reader): array[4, uint8] =
  r.need(4)
  for i in 0 ..< 4:
    result[i] = r.data[r.pos + i]
  r.pos += 4

proc fourCc*(a, b, c, d: char): array[4, uint8] {.inline.} =
  [a.uint8, b.uint8, c.uint8, d.uint8]

proc fourCcToStr*(tag: array[4, uint8]): string =
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = tag[i].char

# ---------------------------------------------------------- ViewReader ---

type
  ViewReader* = object
    ## Cursor over borrowed bytes (mmap view, packet window). Same primitive
    ## set as `Reader` but zero-copy: never owns or copies the backing.
    ## The backing (e.g. `MappedSource`) must outlive every view.
    base*: ptr UncheckedArray[uint8]
    len*: int
    pos*: int

proc getPos*(r: Reader): int {.inline.} = r.pos
proc setPos*(r: var Reader; p: int) {.inline.} = r.pos = p
proc bufLen*(r: Reader): int {.inline.} = r.data.len

proc getPos*(v: ViewReader): int {.inline.} = v.pos
proc setPos*(v: var ViewReader; p: int) {.inline.} = v.pos = p
proc bufLen*(v: ViewReader): int {.inline.} = v.len

proc len*(v: ViewReader): int {.inline.} = v.len
proc remaining*(v: ViewReader): int {.inline.} = v.len - v.pos
proc isEmpty*(v: ViewReader): bool {.inline.} = v.pos >= v.len

proc need(v: ViewReader; n: int) {.inline.} =
  if v.pos + n > v.len:
    raise decodeError("buffer underrun")

proc readByte*(v: var ViewReader): uint8 {.inline.} =
  v.need(1)
  result = v.base[v.pos]
  inc v.pos

proc peekU32Le*(r: Reader): uint32 {.inline.} =
  ## Four bytes at the cursor as LE u32, without advancing.
  r.need(4)
  r.data[r.pos].uint32 or (r.data[r.pos + 1].uint32 shl 8) or
    (r.data[r.pos + 2].uint32 shl 16) or (r.data[r.pos + 3].uint32 shl 24)

proc peekU32Le*(v: ViewReader): uint32 {.inline.} =
  v.need(4)
  v.base[v.pos].uint32 or (v.base[v.pos + 1].uint32 shl 8) or
    (v.base[v.pos + 2].uint32 shl 16) or (v.base[v.pos + 3].uint32 shl 24)

proc readBytes*(v: var ViewReader; n: int): seq[uint8] =
  let avail = min(n, v.remaining())
  result = newSeq[uint8](avail)
  if avail > 0:
    copyMem(result[0].addr, v.base[v.pos].addr, avail)
  v.pos += avail

proc readBytesExact*(v: var ViewReader; n: int): seq[uint8] =
  v.need(n)
  result = newSeq[uint8](n)
  if n > 0:
    copyMem(result[0].addr, v.base[v.pos].addr, n)
  v.pos += n

proc ignoreBytes*(v: var ViewReader; n: int) {.inline.} =
  v.need(n)
  v.pos += n

proc readU16Le*(v: var ViewReader): uint16 {.inline.} =
  v.need(2)
  result = v.base[v.pos].uint16 or (v.base[v.pos + 1].uint16 shl 8)
  v.pos += 2

proc readU16Be*(v: var ViewReader): uint16 {.inline.} =
  v.need(2)
  result = (v.base[v.pos].uint16 shl 8) or v.base[v.pos + 1].uint16
  v.pos += 2

proc readI16Le*(v: var ViewReader): int16 {.inline.} = cast[int16](v.readU16Le())
proc readI16Be*(v: var ViewReader): int16 {.inline.} = cast[int16](v.readU16Be())

proc readU24Le*(v: var ViewReader): uint32 {.inline.} =
  v.need(3)
  result =
    v.base[v.pos].uint32 or
    (v.base[v.pos + 1].uint32 shl 8) or
    (v.base[v.pos + 2].uint32 shl 16)
  v.pos += 3

proc readU24Be*(v: var ViewReader): uint32 {.inline.} =
  v.need(3)
  result =
    (v.base[v.pos].uint32 shl 16) or
    (v.base[v.pos + 1].uint32 shl 8) or
    v.base[v.pos + 2].uint32
  v.pos += 3

proc readI24Le*(v: var ViewReader): int32 {.inline.} =
  cast[int32](v.readU24Le() shl 8) shr 8

proc readI24Be*(v: var ViewReader): int32 {.inline.} =
  cast[int32](v.readU24Be() shl 8) shr 8

proc readU32Le*(v: var ViewReader): uint32 {.inline.} =
  v.need(4)
  result =
    v.base[v.pos].uint32 or
    (v.base[v.pos + 1].uint32 shl 8) or
    (v.base[v.pos + 2].uint32 shl 16) or
    (v.base[v.pos + 3].uint32 shl 24)
  v.pos += 4

proc readU32Be*(v: var ViewReader): uint32 {.inline.} =
  v.need(4)
  result =
    (v.base[v.pos].uint32 shl 24) or
    (v.base[v.pos + 1].uint32 shl 16) or
    (v.base[v.pos + 2].uint32 shl 8) or
    v.base[v.pos + 3].uint32
  v.pos += 4

proc readI32Le*(v: var ViewReader): int32 {.inline.} = cast[int32](v.readU32Le())
proc readI32Be*(v: var ViewReader): int32 {.inline.} = cast[int32](v.readU32Be())

proc readU64Le*(v: var ViewReader): uint64 =
  v.need(8)
  result = 0
  for i in 0 ..< 8:
    result = result or (v.base[v.pos + i].uint64 shl (8 * i))
  v.pos += 8

proc readU64Be*(v: var ViewReader): uint64 =
  v.need(8)
  result = 0
  for i in 0 ..< 8:
    result = result or (v.base[v.pos + i].uint64 shl (8 * (7 - i)))
  v.pos += 8

proc readI64Le*(v: var ViewReader): int64 {.inline.} = cast[int64](v.readU64Le())
proc readI64Be*(v: var ViewReader): int64 {.inline.} = cast[int64](v.readU64Be())

proc readF32Le*(v: var ViewReader): float32 {.inline.} =
  cast[float32](v.readU32Le())
proc readF32Be*(v: var ViewReader): float32 {.inline.} =
  cast[float32](v.readU32Be())

proc readF64Le*(v: var ViewReader): float64 =
  v.need(8)
  var u: uint64 = 0
  for i in 0 ..< 8:
    u = u or (v.base[v.pos + i].uint64 shl (8 * i))
  v.pos += 8
  cast[float64](u)

proc readF64Be*(v: var ViewReader): float64 =
  v.need(8)
  var u: uint64 = 0
  for i in 0 ..< 8:
    u = u or (v.base[v.pos + i].uint64 shl (8 * (7 - i)))
  v.pos += 8
  cast[float64](u)

proc readFourCc*(v: var ViewReader): array[4, uint8] =
  v.need(4)
  for i in 0 ..< 4:
    result[i] = v.base[v.pos + i]
  v.pos += 4

# ---------------------------------------------------------------- Writer ---

proc newWriter*(): Writer {.inline.} = Writer(buf: @[])

proc len*(w: Writer): int {.inline.} = w.buf.len
proc toBytes*(w: Writer): seq[uint8] {.inline.} = w.buf

proc writeByte*(w: var Writer; v: uint8) {.inline.} = w.buf.add(v)

proc writeBytes*(w: var Writer; data: openArray[uint8]) {.inline.} =
  for b in data:
    w.buf.add(b)

proc writeU16Le*(w: var Writer; v: uint16) {.inline.} =
  w.buf.add(v.uint8)
  w.buf.add((v shr 8).uint8)

proc writeU16Be*(w: var Writer; v: uint16) {.inline.} =
  w.buf.add((v shr 8).uint8)
  w.buf.add(v.uint8)

proc writeI16Le*(w: var Writer; v: int16) {.inline.} = w.writeU16Le(cast[uint16](v))
proc writeI16Be*(w: var Writer; v: int16) {.inline.} = w.writeU16Be(cast[uint16](v))

proc writeU24Le*(w: var Writer; v: uint32) {.inline.} =
  ## Writes the low 24 bits of `v`.
  w.buf.add(v.uint8)
  w.buf.add((v shr 8).uint8)
  w.buf.add((v shr 16).uint8)

proc writeU24Be*(w: var Writer; v: uint32) {.inline.} =
  w.buf.add((v shr 16).uint8)
  w.buf.add((v shr 8).uint8)
  w.buf.add(v.uint8)

proc writeU32Le*(w: var Writer; v: uint32) {.inline.} =
  for i in 0 ..< 4:
    w.buf.add((v shr (8 * i)).uint8)

proc writeU32Be*(w: var Writer; v: uint32) {.inline.} =
  for i in countdown(3, 0):
    w.buf.add((v shr (8 * i)).uint8)

proc writeI32Le*(w: var Writer; v: int32) {.inline.} = w.writeU32Le(cast[uint32](v))
proc writeI32Be*(w: var Writer; v: int32) {.inline.} = w.writeU32Be(cast[uint32](v))

proc writeF32Le*(w: var Writer; v: float32) {.inline.} =
  w.writeU32Le(cast[uint32](v))

proc writeF32Be*(w: var Writer; v: float32) {.inline.} =
  w.writeU32Be(cast[uint32](v))

proc writeF64Le*(w: var Writer; v: float64) =
  let u = cast[uint64](v)
  for i in 0 ..< 8:
    w.buf.add((u shr (8 * i)).uint8)

proc writeF64Be*(w: var Writer; v: float64) =
  let u = cast[uint64](v)
  for i in countdown(7, 0):
    w.buf.add((u shr (8 * i)).uint8)

proc patchU32Le*(w: var Writer; at: int; v: uint32) =
  ## Overwrites 4 bytes at `at` (used to fix RIFF chunk sizes on finish).
  if at < 0 or at + 4 > w.buf.len:
    raise ioError("patch position out of range")
  for i in 0 ..< 4:
    w.buf[at + i] = (v shr (8 * i)).uint8

proc writeFourCc*(w: var Writer; tag: array[4, uint8]) {.inline.} =
  w.writeBytes(tag)

proc toBytes*(s: string): seq[uint8] =
  ## Copies string bytes (ASCII chunk tags in tests).
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(result[0].addr, s[0].unsafeAddr, s.len)

# ------------------------------------------------------------ BitReader ---

type
  BitReader* = object
    ## MSB-first bit cursor over immutable bytes (FLAC subframes).
    data*: seq[uint8]
    bytePos*: int
    bitPos*: int # Bits already consumed in the current byte (0..7).

proc newBitReader*(data: openArray[uint8]): BitReader {.inline.} =
  BitReader(data: data.toSeq(), bytePos: 0, bitPos: 0)

proc bitsLeft*(b: BitReader): int {.inline.} =
  (b.data.len - b.bytePos) * 8 - b.bitPos

proc readBit*(b: var BitReader): bool =
  if b.bytePos >= b.data.len:
    raise decodeError("bit reader underrun")
  result = ((b.data[b.bytePos] shr (7 - b.bitPos)) and 1) == 1
  inc b.bitPos
  if b.bitPos == 8:
    b.bitPos = 0
    inc b.bytePos

proc readBits*(b: var BitReader; n: int): uint32 =
  ## Reads `n <= 32` bits MSB-first. `n == 0` yields 0 without consuming.
  if n == 0:
    return 0
  checkDecode(n > 0 and n <= 32, "bit reader width out of range")
  if b.bitsLeft() < n:
    raise decodeError("bit reader underrun")
  var need = n
  while need > 0:
    let avail = 8 - b.bitPos
    let take = min(need, avail)
    let shift = avail - take
    let chunk = (b.data[b.bytePos] shr shift) and
      cast[uint8]((1'u32 shl take) - 1)
    result = (result shl take) or chunk.uint32
    b.bitPos += take
    if b.bitPos == 8:
      b.bitPos = 0
      inc b.bytePos
    need -= take

proc readBits64*(b: var BitReader; n: int): uint64 =
  checkDecode(n >= 0 and n <= 64, "bit reader width out of range")
  if b.bitsLeft() < n:
    raise decodeError("bit reader underrun")
  var need = n
  while need > 32:
    result = (result shl 32) or b.readBits(32).uint64
    need -= 32
  if need > 0:
    result = (result shl need) or b.readBits(need).uint64

proc readSigned*(b: var BitReader; n: int): int32 =
  ## Reads `n` bits and sign-extends to 32 bits.
  let u = b.readBits(n)
  if n == 0:
    return 0
  if (u and (1'u32 shl (n - 1))) != 0:
    cast[int32](u or (0xffff_ffff'u32 shl n))
  else:
    cast[int32](u)

proc signExtend*(v: uint32; n: int): int32 =
  ## Sign-extends an `n`-bit value (port of `sign_extend_leq32_to_i32`).
  if n == 0 or n >= 32:
    return cast[int32](v)
  if (v and (1'u32 shl (n - 1))) != 0:
    cast[int32](v or (0xffff_ffff'u32 shl n))
  else:
    cast[int32](v)

proc readUnaryZeros*(b: var BitReader): uint32 =
  ## Counts 0 bits up to and including the first 1 bit (Rice quotients).
  while not b.readBit():
    inc result

proc ignoreBits*(b: var BitReader; n: int) =
  if b.bitsLeft() < n:
    raise decodeError("bit reader underrun")
  b.bitPos += n
  b.bytePos += b.bitPos div 8
  b.bitPos = b.bitPos mod 8

# ------------------------------------------------------ ViewBitReader ---

type
  ViewBitReader* = object
    ## MSB-first bit cursor over borrowed bytes (mapped FLAC frames).
    ## Same primitive set as `BitReader` but zero-copy: the backing
    ## (e.g. `MappedSource`) must outlive every view.
    base*: ptr UncheckedArray[uint8]
    len*: int
    bytePos*: int
    bitPos*: int # Bits already consumed in the current byte (0..7).

proc bitsLeft*(b: ViewBitReader): int {.inline.} =
  (b.len - b.bytePos) * 8 - b.bitPos

proc readBit*(b: var ViewBitReader): bool =
  if b.bytePos >= b.len:
    raise decodeError("bit reader underrun")
  result = ((b.base[b.bytePos] shr (7 - b.bitPos)) and 1) == 1
  inc b.bitPos
  if b.bitPos == 8:
    b.bitPos = 0
    inc b.bytePos

proc readBits*(b: var ViewBitReader; n: int): uint32 =
  ## Reads `n <= 32` bits MSB-first. `n == 0` yields 0 without consuming.
  if n == 0:
    return 0
  checkDecode(n > 0 and n <= 32, "bit reader width out of range")
  if b.bitsLeft() < n:
    raise decodeError("bit reader underrun")
  var need = n
  while need > 0:
    let avail = 8 - b.bitPos
    let take = min(need, avail)
    let shift = avail - take
    let chunk = (b.base[b.bytePos] shr shift) and
      cast[uint8]((1'u32 shl take) - 1)
    result = (result shl take) or chunk.uint32
    b.bitPos += take
    if b.bitPos == 8:
      b.bitPos = 0
      inc b.bytePos
    need -= take

proc readUnaryZeros*(b: var ViewBitReader): uint32 =
  ## Counts 0 bits up to and including the first 1 bit (Rice quotients).
  while not b.readBit():
    inc result

proc restBits*(v: ViewReader): ViewBitReader {.inline.} =
  ## Bit cursor over the unread tail. Zero-copy: shares the backing.
  ViewBitReader(
    base: cast[ptr UncheckedArray[uint8]](cast[int](v.base) +% v.pos),
    len: v.len - v.pos, bytePos: 0, bitPos: 0)

type
  VlcEntryKind* = enum
    veJump
    veValue

  VlcEntry* = object
    case kind*: VlcEntryKind
    of veJump:
      target*: int
    of veValue:
      value*: uint32
      codeLen*: int

  VlcTable* = object
    table*: seq[VlcEntry]
    maxCodeLen*: int
    bitsPerBlock*: int

# ------------------------------------------------------ LtrBitReader ---

proc rtlShr(v: uint64; n: int): uint64 {.inline.} =
  if n >= 64: 0'u64
  else: v shr n

type
  LtrBitReader* = object
    ## MSB-first cached bit reader (MPEG layers). Bits are kept
    ## top-aligned in `cache`; `left` counts valid bits from the top.
    data*: seq[uint8]
    pos*: int
    cache*: uint64
    left*: int

proc newLtrBitReader*(data: openArray[uint8]): LtrBitReader {.inline.} =
  LtrBitReader(data: data.toSeq(), pos: 0, cache: 0, left: 0)

proc bitsLeft*(b: LtrBitReader): int {.inline.} =
  (b.data.len - b.pos) * 8 + b.left

proc ltrShl(v: uint64; n: int): uint64 {.inline.} =
  if n >= 64: 0'u64
  else: v shl n

proc ltrRefill(b: var LtrBitReader; maxBytes: int) =
  ## Appends up to `maxBytes` bytes MSB-first (top-aligned), up to 64
  ## cached bits total. Raises only if no bits are available at all.
  let capacity = (64 - b.left) div 8
  var want = min(maxBytes, capacity)
  var n = 0
  while n < want and b.pos < b.data.len:
    b.cache = b.cache or (b.data[b.pos].uint64 shl (56 - b.left))
    inc b.pos
    b.left += 8
    inc n
  if n == 0 and b.left == 0:
    raise newException(EndOfStream, "mpa: end of bitstream")

proc readLtrBits*(b: var LtrBitReader; n: int): uint32 =
  ## Reads `n <= 32` bits MSB-first.
  if n == 0:
    return 0
  checkDecode(n > 0 and n <= 32, "bit reader width out of range")
  var need = n
  var res = 0'u64
  while need > 0:
    if b.left == 0:
      b.ltrRefill(8)
    let take = min(need, b.left)
    res = (res shl take) or rtlShr(b.cache, 64 - take)
    b.cache = ltrShl(b.cache, take)
    b.left -= take
    need -= take
  cast[uint32](res)

proc readLtrBool*(b: var LtrBitReader): bool {.inline.} =
  b.readLtrBits(1) == 1

proc readLtrBit*(b: var LtrBitReader): uint32 {.inline.} =
  b.readLtrBits(1)

proc readLtrSigned*(b: var LtrBitReader; n: int): int32 =
  signExtend(b.readLtrBits(n), n)

proc ignoreLtrBits*(b: var LtrBitReader; n: int) =
  var need = n
  while need > 0:
    if b.left == 0:
      b.ltrRefill(8)
    let take = min(need, b.left)
    b.cache = ltrShl(b.cache, take)
    b.left -= take
    need -= take

proc readLtrVlc*(b: var LtrBitReader; t: VlcTable): tuple[value: uint32,
    codeLen: int] =
  ## Walks a Verbatim (MSB-first) VLC table using the top cache bits.
  if b.left < t.maxCodeLen:
    b.ltrRefill(8)
  var bits = b.cache
  let shift = 64 - t.bitsPerBlock
  var base = 0
  while true:
    let e = t.table[base + cast[int](rtlShr(bits, shift))]
    case e.kind
    of veJump:
      bits = ltrShl(bits, t.bitsPerBlock)
      base = e.target
    of veValue:
      if e.codeLen > b.left:
        raise newException(EndOfStream, "mpa: end of bitstream")
      b.cache = ltrShl(b.cache, e.codeLen)
      b.left -= e.codeLen
      return (e.value, e.codeLen)

proc readLtrUnaryOnes*(b: var LtrBitReader): int =
  ## Counts leading 1 bits until the first 0 (AAC escape prefix).
  while b.readLtrBits(1) == 1:
    inc result

proc realignLtr*(b: var LtrBitReader) =
  ## Discards cached bits up to the next byte boundary (DSE align).
  let d = b.left mod 8
  b.cache = ltrShl(b.cache, d)
  b.left -= d

# ------------------------------------------------------------ BitWriter ---

type
  BitWriter* = object
    ## MSB-first bit assembler (FLAC frame encoder).
    buf*: seq[uint8]
    acc*: uint8 # Partially filled byte, MSB-aligned.
    nbits*: int # Bits currently in `acc` (0..7).

proc newBitWriter*(): BitWriter {.inline.} = BitWriter(buf: @[])

proc writeBit*(w: var BitWriter; bit: bool) =
  w.acc = (w.acc shl 1) or (if bit: 1'u8 else: 0'u8)
  inc w.nbits
  if w.nbits == 8:
    w.buf.add(w.acc)
    w.acc = 0
    w.nbits = 0

proc writeBits*(w: var BitWriter; v: uint32; n: int) =
  ## Writes the low `n` bits of `v`, MSB first.
  checkDecode(n >= 0 and n <= 32, "bit writer width out of range")
  for i in countdown(n - 1, 0):
    w.writeBit(((v shr i) and 1) != 0)

proc writeSigned*(w: var BitWriter; v: int32; n: int) {.inline.} =
  ## Writes the low `n` bits of the two's-complement value.
  w.writeBits(cast[uint32](v), n)

proc writeUnary*(w: var BitWriter; q: uint32) =
  ## Writes `q` zero bits followed by a one bit (Rice quotients).
  for _ in 0 ..< q.int:
    w.writeBit(false)
  w.writeBit(true)

proc flush*(w: var BitWriter) =
  ## Pads with zero bits to the next byte boundary.
  while w.nbits != 0:
    w.writeBit(false)

proc toBytes*(w: BitWriter): seq[uint8] =
  result = w.buf
  if w.nbits != 0:
    result.add((w.acc shl (8 - w.nbits)) and 0xff'u8)

proc len*(w: BitWriter): int {.inline.} =
  w.buf.len + (if w.nbits == 0: 0 else: 1)

# ------------------------------------------------------ RtlBitReader ---

type
  RtlBitReader* = object
    ## LSB-first bit reader (Vorbis): bit 0 read first is the LSB.
    data*: seq[uint8]
    pos*: int
    cache*: uint64
    left*: int

proc newRtlBitReader*(data: openArray[uint8]): RtlBitReader {.inline.} =
  RtlBitReader(data: data.toSeq(), pos: 0, cache: 0, left: 0)

proc bitsLeft*(b: RtlBitReader): int {.inline.} =
  (b.data.len - b.pos) * 8 + b.left

proc rtlRefill(b: var RtlBitReader; maxBytes: int) =
  ## Appends bytes LSB-first, up to `maxBytes` and up to 64 cached bits
  ## total (like Symphonia's `fetch_bits_partial`). Raises only if no bits
  ## are available at all.
  let capacity = (64 - b.left) div 8
  var want = min(maxBytes, capacity)
  var n = 0
  while n < want and b.pos < b.data.len:
    b.cache = b.cache or (b.data[b.pos].uint64 shl b.left)
    inc b.pos
    b.left += 8
    inc n
  if n == 0 and b.left == 0:
    raise newException(EndOfStream, "vorbis: end of bitstream")

proc readRtlBits*(b: var RtlBitReader; n: int): uint32 =
  ## Reads `n <= 32` bits LSB-first.
  if n == 0:
    return 0
  checkDecode(n > 0 and n <= 32, "bit reader width out of range")
  var need = n
  var res = 0'u64
  var shift = 0
  while need > 0:
    if b.left == 0:
      b.rtlRefill(8)
    let take = min(need, b.left)
    res = res or ((b.cache and ((1'u64 shl take) - 1)) shl shift)
    b.cache = rtlShr(b.cache, take)
    b.left -= take
    need -= take
    shift += take
  cast[uint32](res)

proc readRtlBits64*(b: var RtlBitReader; n: int): uint64 =
  if n == 0:
    return 0
  checkDecode(n > 0 and n <= 64, "bit reader width out of range")
  var need = n
  var res = 0'u64
  var shift = 0
  while need > 0:
    if b.left == 0:
      b.rtlRefill(8)
    let take = min(need, b.left)
    let mask =
      if take >= 64: high(uint64)
      else: (1'u64 shl take) - 1
    res = res or ((b.cache and mask) shl shift)
    b.cache = rtlShr(b.cache, take)
    b.left -= take
    need -= take
    shift += take
  res

proc readRtlBool*(b: var RtlBitReader): bool {.inline.} =
  b.readRtlBits(1) == 1

proc readRtlSigned*(b: var RtlBitReader; n: int): int32 =
  signExtend(b.readRtlBits(n), n)

proc ignoreRtlBits*(b: var RtlBitReader; n: int) =
  var need = n
  while need > 0:
    if b.left == 0:
      b.rtlRefill(8)
    let take = min(need, b.left)
    b.cache = rtlShr(b.cache, take)
    b.left -= take
    need -= take

proc bitRev32(v: uint32): uint32 =
  for i in 0 ..< 32:
    if (v and (1'u32 shl i)) != 0:
      result = result or (1'u32 shl (31 - i))

proc revOffset(prefix: uint32; width: int): int =
  ## Reverse the low `width` bits of `prefix` (VLC Reverse order).
  let r = bitRev32(prefix)
  let rot = ((r shl width) or (r shr (32 - width))).int
  rot

proc buildVlcTable*(codes, lens: openArray[uint32]; values: openArray[uint32];
    bitsPerBlock: int; reverse: bool): VlcTable =
  ## Canonical Huffman table builder (port of `CodebookBuilder`).
  ## `codes` are MSB-first canonical codewords.
  checkDecode(codes.len == lens.len and codes.len == values.len,
    "vlc: codebook length mismatch")
  if codes.len == 0:
    return VlcTable()
  checkDecode(bitsPerBlock >= 1 and bitsPerBlock <= 16,
    "vlc: bits per block out of range")
  let mask = (1 shl bitsPerBlock) - 1
  type Block = object
    width: int
    nodes: seq[tuple[prefix: uint16, id: int]]
    values: seq[tuple[prefix: uint16, width: int, codeLen: int, value: uint32]]
  var blocks: seq[Block] = @[Block(width: bitsPerBlock)]
  var maxLen = 0
  for i in 0 ..< codes.len:
    let codeLen = lens[i].int
    if codeLen == 0:
      raise decodeError("vlc: zero length codeword")
    if codeLen > 32:
      raise decodeError("vorbis: codebook codeword length exceeds 32 bits")
    maxLen = max(maxLen, codeLen)
    var parent = 0
    var len = codeLen
    while len > bitsPerBlock:
      len -= bitsPerBlock
      let prefix = cast[uint16]((codes[i] shr len) and mask.uint32)
      var found = -1
      for n in blocks[parent].nodes:
        if n.prefix == prefix:
          found = n.id
          break
      if found < 0:
        found = blocks.len
        blocks[parent].nodes.add((prefix, found))
        blocks.add(Block(width: bitsPerBlock))
      parent = found
    let prefix = cast[uint16](codes[i] and
      (mask shr (bitsPerBlock - len)).uint32)
    blocks[parent].values.add((prefix, len, codeLen, values[i]))
  # Breadth-first LUT generation.
  var table: seq[VlcEntry] = @[]
  var queue: seq[int] = @[]
  var tableEnd = 0
  if blocks.len > 0:
    queue.add(0)
    tableEnd += 1 shl blocks[0].width
  # Sort node keys for deterministic left-to-right jumps.
  for blk in blocks.mitems:
    blk.nodes.sort(proc(a, b: tuple[prefix: uint16, id: int]): int =
      cmp(a.prefix, b.prefix))
  while queue.len > 0:
    let blockId = queue[0]
    queue.delete(0)
    let blk = blocks[blockId]
    let blockLen = 1 shl blk.width
    let base = table.len
    while table.len < base + blockLen:
      table.add(VlcEntry(kind: veJump, target: 0))
    var count = 0
    for n in blk.nodes:
      queue.add(n.id)
      let childWidth = blocks[n.id].width
      if reverse:
        let off = revOffset(n.prefix.uint32, blk.width)
        table[base + off] = VlcEntry(kind: veJump, target: tableEnd)
      else:
        table[base + n.prefix.int] = VlcEntry(kind: veJump, target: tableEnd)
      tableEnd += 1 shl childWidth
      inc count
    for v in blk.values:
      let dnc = blk.width - v.width
      let count2 = 1 shl dnc
      let basePrefix = v.prefix.int shl dnc
      let entry = VlcEntry(kind: veValue, value: v.value,
        codeLen: v.codeLen)
      if reverse:
        for p in basePrefix ..< basePrefix + count2:
          let off = revOffset(p.uint32, blk.width)
          table[base + off] = entry
      else:
        for j in 0 ..< count2:
          table[base + basePrefix + j] = entry
      count += count2
    if count != blockLen:
      raise decodeError("core (io): codebook is incomplete")
  VlcTable(table: table, maxCodeLen: maxLen, bitsPerBlock: bitsPerBlock)

proc readVlc*(b: var RtlBitReader; t: VlcTable): tuple[value: uint32,
    codeLen: int] =
  ## Walks the VLC table LSB-first.
  if b.left < t.maxCodeLen:
    b.rtlRefill(8)
  var bits = b.cache
  let mask = (1 shl t.bitsPerBlock) - 1
  var base = 0
  while true:
    let e = t.table[base + (bits and mask.uint64).int]
    case e.kind
    of veJump:
      bits = bits shr t.bitsPerBlock
      base = e.target
    of veValue:
      if e.codeLen > b.left:
        raise newException(EndOfStream, "vorbis: end of bitstream")
      b.cache = b.cache shr e.codeLen
      b.left -= e.codeLen
      return (e.value, e.codeLen)
