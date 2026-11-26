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
  MappedSource* = ref object
    ## Owns a read-only file mapping. All views borrow from it; closing
    ## invalidates them, so keep the source alive for the whole stream.
    mf*: MemFile
    path*: string
    closed*: bool

  BytePool* = PooledBuffer[byte]
    ## Reusable packet-assembly scratch. Manual lifecycle on purpose:
    ## buffalo's scoped `withBorrow` cannot cross the `nextPacket` return
    ## boundary, so streaming code owns the pool and clears it per packet.

  PacketView* = object
    ## One decodable unit referencing the mapping instead of owning bytes.
    ## Materialize the bytes at the decode call site (`packetReader`,
    ## `decodePacketView`); never store the view past `close`.
    trackId*: uint32
    pts*: Timestamp
    dts*: Timestamp
    dur*: Duration
    trimStart*: Duration
    trimEnd*: Duration
    src*: MappedSource
    off*: int
    len*: int

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

proc packetReader*(v: PacketView): ViewReader {.inline.} =
  ## Cursor over the packet window. Build it inside the decode call so no
  ## borrowed view ever has to cross a return boundary as `openArray`.
  viewReader(v.src, v.off, v.len)

proc blockDur*(v: PacketView): Duration {.inline.} =
  v.dur.saturatingAdd(v.trimStart).saturatingAdd(v.trimEnd)

proc initStreamPool*(cap = DefaultStreamPoolBytes;
    maxCap = 0): BytePool {.inline.} =
  ## One-time pool backing (default 1 MiB). `cap` stays flat in steady
  ## state; optional `maxCap` bounds growth instead of allocating past it.
  initPool(byte, cap, maxCap)

proc loadPacketInto*(pool: var BytePool; v: PacketView) {.inline.} =
  ## Copies the packet window into caller-owned reusable scratch. Bounded
  ## by the max packet size (KBs for PCM frames), never by the file size.
  ## Use the view path (`packetReader` / `decodePacketView`) to skip even
  ## this copy for contiguous packets.
  checkView(v.src, v.off, v.len)
  pool.ensureCap(v.len)
  if v.len > 0:
    copyMem(pool.data[0].addr, v.src.viewBaseAt(v.off)[0].addr, v.len)
  pool.len = v.len

proc packetSeq*(v: PacketView): seq[uint8] =
  ## Owning copy of the window (compat path, e.g. feeding `decodePacket`).
  checkView(v.src, v.off, v.len)
  result = newSeq[uint8](v.len)
  if v.len > 0:
    copyMem(result[0].addr, v.src.viewBaseAt(v.off)[0].addr, v.len)
