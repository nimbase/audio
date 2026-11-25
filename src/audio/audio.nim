## Audio primitives: sample formats, channel layouts, planar buffers.
##
## Ports `symphonia-core/src/audio/{mod,sample,channels,buf,conv}.rs` and
## `generic.rs`. Storage is always planar (one `seq` per channel, frame `i`
## is `planes[p][i]`); interleaved data exists only at packet boundaries.
## 24-bit samples are LSB-aligned integers in 32-bit storage, exactly like
## Symphonia's `u24`/`i24` semantics (`i32 -> i24` is `s >> 8`).

import std/options
import ./errors

type
  SampleFormat* = enum
    ## Order matches Symphonia for stable ordinals.
    sfU8
    sfU16
    sfU24
    sfU32
    sfS8
    sfS16
    sfS24
    sfS32
    sfF32
    sfF64

  Position* = uint64
    ## Bitmask of speaker positions. Low 18 bits equal the
    ## WAVEFORMATEXTENSIBLE channel mask.

const
  PosFrontLeft*: Position = 1'u64 shl 0
  PosFrontRight*: Position = 1'u64 shl 1
  PosFrontCenter*: Position = 1'u64 shl 2
  PosLfe1*: Position = 1'u64 shl 3
  PosRearLeft*: Position = 1'u64 shl 4
  PosRearRight*: Position = 1'u64 shl 5
  PosFrontLeftCenter*: Position = 1'u64 shl 6
  PosFrontRightCenter*: Position = 1'u64 shl 7
  PosRearCenter*: Position = 1'u64 shl 8
  PosSideLeft*: Position = 1'u64 shl 9
  PosSideRight*: Position = 1'u64 shl 10
  PosTopCenter*: Position = 1'u64 shl 11
  PosTopFrontLeft*: Position = 1'u64 shl 12
  PosTopFrontCenter*: Position = 1'u64 shl 13
  PosTopFrontRight*: Position = 1'u64 shl 14
  PosTopRearLeft*: Position = 1'u64 shl 15
  PosTopRearCenter*: Position = 1'u64 shl 16
  PosTopRearRight*: Position = 1'u64 shl 17
  PosLfe2*: Position = 1'u64 shl 18

type
  ChannelKind* = enum
    ckNone
    ckPositioned
    ckDiscrete

  Channels* = object
    ## Channel assignment. Ambisonic/custom layouts (Symphonia's
    ## `Ambisonic`/`Custom`) arrive with the ALAC/AIFF phase; until then
    ## such streams decode to `ckDiscrete`.
    case kind*: ChannelKind
    of ckPositioned:
      mask*: Position
    of ckDiscrete:
      count*: int
    of ckNone:
      discard

const
  ChMono* = Channels(kind: ckPositioned, mask: PosFrontCenter)
  ChStereo* = Channels(
    kind: ckPositioned, mask: PosFrontLeft or PosFrontRight
  )
  ChQuad* = Channels(
    kind: ckPositioned,
    mask: PosFrontLeft or PosFrontRight or PosRearLeft or PosRearRight,
  )
  # FLAC channel masks (symphonia-common flac_channels_to_channels).
  Ch3* = Channels(kind: ckPositioned,
    mask: PosFrontLeft or PosFrontRight or PosFrontCenter)
  Ch5* = Channels(kind: ckPositioned,
    mask: PosFrontLeft or PosFrontRight or PosFrontCenter or PosRearLeft or
      PosRearRight)
  Ch51* = Channels(kind: ckPositioned,
    mask: PosFrontLeft or PosFrontRight or PosFrontCenter or PosLfe1 or
      PosRearLeft or PosRearRight)
  Ch7* = Channels(kind: ckPositioned,
    mask: PosFrontLeft or PosFrontRight or PosFrontCenter or PosLfe1 or
      PosRearCenter or PosSideLeft or PosSideRight)
  Ch71* = Channels(kind: ckPositioned,
    mask: PosFrontLeft or PosFrontRight or PosFrontCenter or PosLfe1 or
      PosRearLeft or PosRearRight or PosSideLeft or PosSideRight)

proc positioned*(mask: Position): Channels {.inline.} =
  Channels(kind: ckPositioned, mask: mask)

proc flacChannels*(n: int): Channels =
  ## FLAC 1..8 channel assignment to positioned layouts.
  case n
  of 1: positioned(PosFrontLeft)
  of 2: ChStereo
  of 3: Ch3
  of 4: ChQuad
  of 5: Ch5
  of 6: Ch51
  of 7: Ch7
  of 8: Ch71
  else: raise decodeError("flac: stream channels are out of bounds")

proc discrete*(n: int): Channels {.inline.} =
  Channels(kind: ckDiscrete, count: n)

proc channelCount*(c: Channels): int =
  case c.kind
  of ckPositioned:
    var m = c.mask
    while m != 0:
      result += (m and 1).int
      m = m shr 1
  of ckDiscrete:
    result = c.count
  of ckNone:
    result = 0

proc `==`*(a, b: Channels): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of ckPositioned: a.mask == b.mask
  of ckDiscrete: a.count == b.count
  of ckNone: true

proc positionFromCount*(n: int): Option[Position] =
  ## Lowest `n` bits set (Symphonia `Position::from_count`), `none` for
  ## `n` outside 1..32.
  if n < 1 or n > 32:
    none(Position)
  elif n == 32:
    some(high(Position))
  else:
    some((1'u64 shl n) - 1)

# ------------------------------------------------------------ Samples ---

proc sampleWidthBits*(fmt: SampleFormat): int =
  case fmt
  of sfU8, sfS8: 8
  of sfU16, sfS16: 16
  of sfU24, sfS24: 24
  of sfU32, sfS32: 32
  of sfF32: 32
  of sfF64: 64

proc packedWidthBytes*(fmt: SampleFormat): int =
  ## Bytes per sample in interleaved packets (24-bit packs to 3).
  case fmt
  of sfU8, sfS8: 1
  of sfU16, sfS16: 2
  of sfU24, sfS24: 3
  of sfU32, sfS32, sfF32: 4
  of sfF64: 8

proc storageWidthBytes*(fmt: SampleFormat): int =
  ## Bytes per sample in planar storage (24-bit widens to 4).
  case fmt
  of sfU8, sfS8: 1
  of sfU16, sfS16: 2
  of sfU24, sfS24, sfU32, sfS32, sfF32: 4
  of sfF64: 8

proc silenceU8*: uint8 {.inline.} = 128'u8
proc silenceU16*: uint16 {.inline.} = 32_768'u16
proc silenceU24*: uint32 {.inline.} = 8_388_608'u32
proc silenceU32*: uint32 {.inline.} = 2_147_483_648'u32

proc silence*[S](T: typedesc[S]): S =
  ## Digital silence for a sample type (unsigned bias, else zero).
  when S is uint8: silenceU8()
  elif S is uint16: silenceU16()
  elif S is uint32: 0'u32 # Caller selects u24/u32 bias explicitly.
  elif S is int8: 0'i8
  elif S is int16: 0'i16
  elif S is int32: 0'i32
  elif S is float32: 0'f32
  elif S is float64: 0'f64
  else: {.error: "unsupported sample type".}

# ------------------------------------------------- Sample conversion ---

proc clampU24*(v: uint32): uint32 {.inline.} =
  if v > 16_777_215'u32: 16_777_215'u32 else: v

proc clampI16*(v: int32): int32 {.inline.} =
  if v > 32_767: 32_767'i32
  elif v < -32_768: -32_768'i32
  else: v

proc clampI24*(v: int32): int32 {.inline.} =
  if v > 8_388_607'i32: 8_388_607'i32
  elif v < -8_388_608'i32: -8_388_608'i32
  else: v

# Integer -> integer: shift up, arithmetic shift down. Signed <-> unsigned
# via bias. Mirrors conv.rs direction and width rules.

proc toI8*(s: int8): int8 {.inline.} = s
proc toI8*(s: int16): int8 {.inline.} = cast[int8](s shr 8)
proc toI8*(s: int32): int8 {.inline.} = cast[int8](s shr 24)
proc toI8*(s: uint8): int8 {.inline.} = cast[int8](s - 128'u8)

proc toI16*(s: int8): int16 {.inline.} = s.int16 shl 8
proc toI16*(s: int16): int16 {.inline.} = s
proc toI16*(s: int32): int16 {.inline.} = cast[int16](s shr 16)
proc toI16*(s: uint16): int16 {.inline.} = cast[int16](s - 32_768'u16)

proc toI24*(s: int8): int32 {.inline.} = clampI24(s.int32 shl 16)
proc toI24*(s: int16): int32 {.inline.} = clampI24(s.int32 shl 8)
proc toI24*(s: int32): int32 {.inline.} = clampI24(s shr 8)
proc toI24*(s: uint32): int32 {.inline.} = clampI24(cast[int32](s - 2_147_483_648'u32) shr 8)

proc toI32*(s: int8): int32 {.inline.} = s.int32 shl 24
proc toI32*(s: int16): int32 {.inline.} = s.int32 shl 16
proc toI32*(s: int32): int32 {.inline.} = s
proc toI32*(s: uint32): int32 {.inline.} = cast[int32](s - 2_147_483_648'u32)

proc toU8*(s: uint8): uint8 {.inline.} = s
proc toU8*(s: uint16): uint8 {.inline.} = cast[uint8](s shr 8)
proc toU8*(s: uint32): uint8 {.inline.} = cast[uint8](s shr 24)
proc toU8*(s: int8): uint8 {.inline.} = cast[uint8](s) + 128'u8

proc toU16*(s: uint8): uint16 {.inline.} = s.uint16 shl 8
proc toU16*(s: uint16): uint16 {.inline.} = s
proc toU16*(s: uint32): uint16 {.inline.} = cast[uint16](s shr 16)
proc toU16*(s: int16): uint16 {.inline.} = cast[uint16](s) + 32_768'u16

proc toU24*(s: uint8): uint32 {.inline.} = clampU24(s.uint32 shl 16)
proc toU24*(s: uint16): uint32 {.inline.} = clampU24(s.uint32 shl 8)
proc toU24*(s: uint32): uint32 {.inline.} = clampU24(s shr 8)
proc toU24*(s: int32): uint32 {.inline.} =
  clampU24((cast[uint32](s) + 2_147_483_648'u32) shr 8)

proc toU32*(s: uint8): uint32 {.inline.} = s.uint32 shl 24
proc toU32*(s: uint16): uint32 {.inline.} = s.uint32 shl 16
proc toU32*(s: uint32): uint32 {.inline.} = s
proc toU32*(s: int32): uint32 {.inline.} = cast[uint32](s) + 2_147_483_648'u32

# Integer <-> float: divide/multiply by 2^(bits-1), matching conv.rs.

proc toF32*(s: int8): float32 {.inline.} = s.float32 / 128.0'f32
proc toF32*(s: int16): float32 {.inline.} = s.float32 / 32_768.0'f32
proc toF32*(s: int32): float32 {.inline.} = s.float32 / 2_147_483_648.0'f32
proc toF32*(s: uint8): float32 {.inline.} = (cast[int8](s - 128'u8)).float32 / 128.0'f32
proc toF32*(s: uint32): float32 {.inline.} =
  cast[int32](s - 2_147_483_648'u32).float32 / 2_147_483_648.0'f32

proc toF64*(s: int16): float64 {.inline.} = s.float64 / 32_768.0
proc toF64*(s: int32): float64 {.inline.} = s.float64 / 2_147_483_648.0
proc toF64*(s: float32): float64 {.inline.} = s.float64

proc fromF32ToI16*(s: float32): int16 =
  let v = s.float64 * 32_768.0
  if v >= 32_767.0: 32_767'i16
  elif v <= -32_768.0: -32_768'i16
  else: cast[int16](v.int32)

proc fromF32ToI32*(s: float32): int32 =
  let v = s.float64 * 2_147_483_648.0
  if v >= 2_147_483_647.0: high(int32)
  elif v <= -2_147_483_648.0: low(int32)
  else: cast[int32](v.int64)

# ---------------------------------------------------------- AudioSpec ---

type
  AudioSpec* = object
    rate*: uint32
    channels*: Channels

proc newAudioSpec*(rate: uint32; channels: Channels): AudioSpec {.inline.} =
  AudioSpec(rate: rate, channels: channels)

# -------------------------------------------------------- AudioBuffer ---

type
  AudioBuffer*[S] = object
    ## Planar buffer: `planes[p][i]` is channel `p`, frame `i`.
    spec*: AudioSpec
    planes*: seq[seq[S]]
    numFrames*: int
    capacity*: int

proc newAudioBuffer*[S](spec: AudioSpec; capacity: int): AudioBuffer[S] =
  result.spec = spec
  result.capacity = capacity
  result.numFrames = 0
  let n = spec.channels.channelCount()
  result.planes = newSeq[seq[S]](n)
  for p in 0 ..< n:
    result.planes[p] = newSeq[S](capacity)
    for i in 0 ..< capacity:
      result.planes[p][i] = silence(S)

proc isUnused*[S](b: AudioBuffer[S]): bool {.inline.} =
  b.capacity == 0 or b.spec.channels.channelCount() == 0

proc frames*[S](b: AudioBuffer[S]): int {.inline.} = b.numFrames
proc numPlanes*[S](b: AudioBuffer[S]): int {.inline.} = b.planes.len

proc clear*[S](b: var AudioBuffer[S]) {.inline.} = b.numFrames = 0

proc growCapacity*[S](b: var AudioBuffer[S]; capacity: int) =
  ## Raises capacity to at least `capacity`, preserving decoded frames.
  if capacity <= b.capacity:
    return
  for p in 0 ..< b.planes.len:
    b.planes[p].setLen(capacity)
    for i in b.capacity ..< capacity:
      b.planes[p][i] = silence(S)
  b.capacity = capacity

proc resizeWithSilence*[S](b: var AudioBuffer[S]; n: int) =
  b.growCapacity(n)
  for p in 0 ..< b.planes.len:
    for i in b.numFrames ..< n:
      b.planes[p][i] = silence(S)
  b.numFrames = n

template renderWith*[S](b: var AudioBuffer[S]; n: int; frameIdx: untyped;
    body: untyped) =
  ## Makes room for `n` frames then runs `body` per frame index with
  ## `b.planes[p][frameIdx]` writable. Commits all `n` frames.
  block:
    b.growCapacity(n)
    b.numFrames = n
    for frameIdx in 0 ..< n:
      body

proc shift*[S](b: var AudioBuffer[S]; n: int) =
  ## Drops the first `n` frames, moving the rest down.
  let keep = max(0, b.numFrames - n)
  for p in 0 ..< b.planes.len:
    if keep > 0:
      copyMem(b.planes[p][0].addr, b.planes[p][n].addr, keep * sizeof(S))
    b.planes[p].setLen(b.capacity)
    for i in keep ..< b.capacity:
      b.planes[p][i] = silence(S)
  b.numFrames = keep

proc truncate*[S](b: var AudioBuffer[S]; n: int) {.inline.} =
  b.numFrames = min(n, b.numFrames)

proc copyInterleavedFrom*[S](b: var AudioBuffer[S]; src: openArray[S]) =
  ## Copies a frame-interleaved slice into planar storage.
  let nPlanes = b.planes.len
  if nPlanes == 0:
    return
  let nFrames = src.len div nPlanes
  b.growCapacity(nFrames)
  for i in 0 ..< nFrames:
    for p in 0 ..< nPlanes:
      b.planes[p][i] = src[i * nPlanes + p]
  b.numFrames = nFrames

proc copyInterleavedTo*[S](b: AudioBuffer[S]; dst: var openArray[S]) =
  ## Copies planar frames out as frame-interleaved samples.
  let nPlanes = b.planes.len
  let need = b.numFrames * nPlanes
  assert dst.len >= need
  for i in 0 ..< b.numFrames:
    for p in 0 ..< nPlanes:
      dst[i * nPlanes + p] = b.planes[p][i]

# ------------------------------------------------------ AudioSamples ---

type
  AudioSamples* = object
    ## Runtime-typed planar audio (Symphonia's `GenericAudioBuffer`).
    case format*: SampleFormat
    of sfU8: u8*: AudioBuffer[uint8]
    of sfU16: u16*: AudioBuffer[uint16]
    of sfU24: u24*: AudioBuffer[uint32]
    of sfU32: u32*: AudioBuffer[uint32]
    of sfS8: s8*: AudioBuffer[int8]
    of sfS16: s16*: AudioBuffer[int16]
    of sfS24: s24*: AudioBuffer[int32]
    of sfS32: s32*: AudioBuffer[int32]
    of sfF32: f32*: AudioBuffer[float32]
    of sfF64: f64*: AudioBuffer[float64]

proc newAudioSamples*(format: SampleFormat; spec: AudioSpec;
    capacity: int): AudioSamples =
  case format
  of sfU8: AudioSamples(format: sfU8, u8: newAudioBuffer[uint8](spec, capacity))
  of sfU16: AudioSamples(format: sfU16, u16: newAudioBuffer[uint16](spec, capacity))
  of sfU24: AudioSamples(format: sfU24, u24: newAudioBuffer[uint32](spec, capacity))
  of sfU32: AudioSamples(format: sfU32, u32: newAudioBuffer[uint32](spec, capacity))
  of sfS8: AudioSamples(format: sfS8, s8: newAudioBuffer[int8](spec, capacity))
  of sfS16: AudioSamples(format: sfS16, s16: newAudioBuffer[int16](spec, capacity))
  of sfS24: AudioSamples(format: sfS24, s24: newAudioBuffer[int32](spec, capacity))
  of sfS32: AudioSamples(format: sfS32, s32: newAudioBuffer[int32](spec, capacity))
  of sfF32: AudioSamples(format: sfF32, f32: newAudioBuffer[float32](spec, capacity))
  of sfF64: AudioSamples(format: sfF64, f64: newAudioBuffer[float64](spec, capacity))

proc specOf*(s: AudioSamples): AudioSpec =
  case s.format
  of sfU8: s.u8.spec
  of sfU16: s.u16.spec
  of sfU24: s.u24.spec
  of sfU32: s.u32.spec
  of sfS8: s.s8.spec
  of sfS16: s.s16.spec
  of sfS24: s.s24.spec
  of sfS32: s.s32.spec
  of sfF32: s.f32.spec
  of sfF64: s.f64.spec

proc framesOf*(s: AudioSamples): int =
  case s.format
  of sfU8: s.u8.numFrames
  of sfU16: s.u16.numFrames
  of sfU24: s.u24.numFrames
  of sfU32: s.u32.numFrames
  of sfS8: s.s8.numFrames
  of sfS16: s.s16.numFrames
  of sfS24: s.s24.numFrames
  of sfS32: s.s32.numFrames
  of sfF32: s.f32.numFrames
  of sfF64: s.f64.numFrames

proc clearSamples*(s: var AudioSamples) =
  case s.format
  of sfU8: s.u8.clear()
  of sfU16: s.u16.clear()
  of sfU24: s.u24.clear()
  of sfU32: s.u32.clear()
  of sfS8: s.s8.clear()
  of sfS16: s.s16.clear()
  of sfS24: s.s24.clear()
  of sfS32: s.s32.clear()
  of sfF32: s.f32.clear()
  of sfF64: s.f64.clear()

proc growSamples*(s: var AudioSamples; capacity: int) =
  case s.format
  of sfU8: s.u8.growCapacity(capacity)
  of sfU16: s.u16.growCapacity(capacity)
  of sfU24: s.u24.growCapacity(capacity)
  of sfU32: s.u32.growCapacity(capacity)
  of sfS8: s.s8.growCapacity(capacity)
  of sfS16: s.s16.growCapacity(capacity)
  of sfS24: s.s24.growCapacity(capacity)
  of sfS32: s.s32.growCapacity(capacity)
  of sfF32: s.f32.growCapacity(capacity)
  of sfF64: s.f64.growCapacity(capacity)
