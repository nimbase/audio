## Streaming sources: memory-mapped file input plus reusable byte pools.
##
## `MappedSource` owns a read-only `MemFile` mapping; views into it are
## zero-copy (`ViewReader`, `PacketView`) and stay valid while the source
## is open. `BytePool` (buffalo `PooledBuffer[byte]`, default 1 MiB) is the
## bounded scratch for packet assembly: steady-state decoding performs no
## per-packet heap allocation beyond the pool's one-time backing.
##
## Decoders already reuse their internal `AudioBuffer` across packets
## (`renderWith` grows once, then stays flat), so the pool only needs to
## cover the demuxer side. Sample-planar pooling is therefore out of scope
## here on purpose.

import std/memfiles
import buffalo
import ./errors
import ./io
import ./units

export buffalo

const DefaultStreamPoolBytes* = 1_048_576 ## 1 MiB packet scratch.

type
  ByteOwner* = ref object of RootObj
    ## Keeps view bytes alive. Subtypes: file mappings (`MappedSource`)
    ## and reusable assembly scratch (`PooledHost`). A `PacketView` is
    ## valid while its owner is; pool windows additionally expire on the
    ## next assembly into the same host.

  MappedSource* = ref object of ByteOwner
    ## Owns a read-only file mapping. All views borrow from it; closing
    ## invalidates them, so keep the source alive for the whole stream.
    mf*: MemFile
    path*: string
    closed*: bool

  BytePool* = PooledBuffer[byte]
    ## Reusable packet-assembly scratch. Manual lifecycle on purpose:
    ## buffalo's scoped `withBorrow` cannot cross the `nextPacket` return
    ## boundary, so streaming code owns the pool and clears it per packet.

  PooledHost* = ref object of ByteOwner
    ## Reusable assembly scratch for packets spanning non-contiguous
    ## regions (Ogg cross-page packets). Windows borrow from `buf` and
    ## stay valid until the next assembly into this host. Backing grows
    ## once to the largest packet seen, then stays flat.
    buf*: BytePool

  ByteWindow* = object
    ## Borrowed bytes: a base pointer plus length. Either a mapping
    ## window or a pool window; the `PacketView` owner keeps it alive.
    base*: ptr UncheckedArray[uint8]
    len*: int

  PacketView* = object
    ## One decodable unit referencing bytes instead of owning them.
    ## Materialize cursors at the decode call site (`packetReader`,
    ## `decodePacketView`); never store the view past its owner's
    ## lifetime (close, or the next assembly for pool windows).
    trackId*: uint32
    pts*: Timestamp
    dts*: Timestamp
    dur*: Duration
    trimStart*: Duration
    trimEnd*: Duration
    win*: ByteWindow
    owner*: ByteOwner

proc openMappedSource*(path: string): MappedSource =
  ## Memory-maps `path` read-only. The OS pages data in on demand; no heap
  ## copy of the file is ever made.
  result = MappedSource(path: path)
  try:
    result.mf = memfiles.open(path, fmRead)
  except CatchableError as e:
    raise ioError("stream: cannot map file: " & e.msg)

proc close*(s: MappedSource) =
  ## Unmaps the file. All outstanding views become invalid.
  if s != nil and not s.closed:
    s.closed = true
    s.mf.close()

proc mappedLen*(s: MappedSource): int {.inline.} =
  if s == nil or s.closed: 0 else: s.mf.size

proc mappedBase*(s: MappedSource): tuple[base: ptr UncheckedArray[uint8],
    len: int] =
  ## Raw mapping pointer for index scans. All access must stay within
  ## `len`; bounds-check before dereferencing (helpers below do).
  if s == nil or s.closed or s.mf.size == 0:
    (nil, 0)
  else:
    (cast[ptr UncheckedArray[uint8]](s.mf.mem), s.mf.size)

proc checkView(s: MappedSource; off, n: int) {.inline.} =
  if s == nil or s.closed:
    raise ioError("stream: source is closed")
  if off < 0 or n < 0 or off > s.mf.size or n > s.mf.size - off:
    raise decodeError("stream: packet window out of bounds")

proc viewBaseAt(s: MappedSource; off: int): ptr UncheckedArray[uint8] {.inline.} =
  cast[ptr UncheckedArray[uint8]](cast[int](s.mf.mem) +% off)

template packetBytes*(s: MappedSource; off, n: int): untyped =
  ## Zero-copy `openArray[byte]` over the mapping at the call site.
  ## A template because Nim cannot return `openArray`.
  (checkView(s, off, n);
    toOpenArray(s.viewBaseAt(off), 0, n - 1))

proc viewReader*(s: MappedSource; off, n: int): ViewReader {.inline.} =
  ## Bounds-checked cursor over a mapping window (header parsing, decode).
  checkView(s, off, n)
  ViewReader(base: s.viewBaseAt(off), len: n, pos: 0)

proc byteWindow*(s: MappedSource; off, n: int): ByteWindow {.inline.} =
  ## Bounds-checked window over the mapping (view construction).
  checkView(s, off, n)
  ByteWindow(base: s.viewBaseAt(off), len: n)

proc subWindow*(win: ByteWindow; off, n: int): ByteWindow {.inline.} =
  ## Bounds-checked sub-window (e.g. an MP3 frame body inside a packet).
  if off < 0 or n < 0 or off > win.len or n > win.len - off:
    raise decodeError("stream: window out of bounds")
  ByteWindow(base: cast[ptr UncheckedArray[uint8]](
    cast[int](win.base) +% off), len: n)

proc viewReaderOf*(win: ByteWindow): ViewReader {.inline.} =
  ## Cursor over any window, mapping or pool. Build it inside the decode
  ## call so no borrowed view ever has to cross a return boundary.
  ViewReader(base: win.base, len: win.len, pos: 0)

proc restBitsOf*(win: ByteWindow): ViewBitReader {.inline.} =
  ## Bit cursor over a window (FLAC frames).
  ViewBitReader(base: win.base, len: win.len, bytePos: 0, bitPos: 0)

proc restLtrOf*(win: ByteWindow): ViewLtrBitReader {.inline.} =
  ## Cached bit cursor over a window (MP3/AAC/ALAC frames).
  ViewLtrBitReader(base: win.base, len: win.len, pos: 0, cache: 0,
    left: 0)

proc restRtlOf*(win: ByteWindow): ViewRtlBitReader {.inline.} =
  ## LSB-first bit cursor over a window (Vorbis packets).
  ViewRtlBitReader(base: win.base, len: win.len, pos: 0, cache: 0,
    left: 0)

proc packetReader*(v: PacketView): ViewReader {.inline.} =
  ## Cursor over the packet window (either backing).
  viewReaderOf(v.win)

proc initPooledHost*(cap = DefaultStreamPoolBytes;
    maxCap = 0): PooledHost {.inline.} =
  ## One-time assembly backing (default 1 MiB). Grows once to the largest
  ## packet seen, then stays flat; optional `maxCap` bounds growth.
  PooledHost(buf: initPool(byte, cap, maxCap))

proc clearHost*(h: PooledHost) {.inline.} =
  ## Resets the used prefix; previously returned windows expire.
  h.buf.clear()

proc appendHost*(h: PooledHost; data: openArray[uint8]) {.inline.} =
  ## Appends a span to the assembly scratch (grows the backing if needed).
  h.buf.appendMany(data)

proc hostWindow*(h: PooledHost): ByteWindow {.inline.} =
  ## Window over the assembled prefix. Take it after the final append
  ## (growth may move the backing); valid until the next `clearHost`.
  let base =
    if h.buf.len > 0: cast[ptr UncheckedArray[uint8]](h.buf.data[0].addr)
    else: nil
  ByteWindow(base: base, len: h.buf.len)

proc assembleWindow*(h: PooledHost;
    parts: openArray[ByteWindow]): ByteWindow {.inline.} =
  ## Copies discontiguous spans into the host and returns the window.
  ## Bounded by the packet size, never by the file size.
  h.buf.clear()
  for p in parts:
    if p.len > 0:
      h.buf.ensureCap(h.buf.len + p.len)
      copyMem(h.buf.data[h.buf.len].addr, p.base[0].addr, p.len)
      h.buf.len += p.len
  h.hostWindow()

proc blockDur*(v: PacketView): Duration {.inline.} =
  v.dur.saturatingAdd(v.trimStart).saturatingAdd(v.trimEnd)

proc initStreamPool*(cap = DefaultStreamPoolBytes;
    maxCap = 0): BytePool {.inline.} =
  ## One-time pool backing (default 1 MiB). `cap` stays flat in steady
  ## state; optional `maxCap` bounds growth instead of allocating past it.
  initPool(byte, cap, maxCap)

proc loadPacketInto*(pool: var BytePool; v: PacketView) {.inline.} =
  ## Copies the packet window into caller-owned reusable scratch. Bounded
  ## by the max packet size, never by the file size. Use the view path
  ## (`packetReader` / `decodePacketView`) to skip even this copy for
  ## contiguous packets.
  pool.ensureCap(v.win.len)
  if v.win.len > 0:
    copyMem(pool.data[0].addr, v.win.base[0].addr, v.win.len)
  pool.len = v.win.len

proc packetSeq*(v: PacketView): seq[uint8] =
  ## Owning copy of the window (compat path, e.g. feeding `decodePacket`).
  result = newSeq[uint8](v.win.len)
  if v.win.len > 0:
    copyMem(result[0].addr, v.win.base[0].addr, v.win.len)
