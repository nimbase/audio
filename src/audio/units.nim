## Timestamps, durations, wall-clock time, and timebases.
##
## Ports the semantics of `symphonia-core/src/units.rs`. One timestamp tick
## equals `TimeBase` seconds. `Time` stores seconds plus a non-negative
## nanosecond fraction.
##
## Note: Symphonia falls back to 128-bit arithmetic on overflow; Nim has no
## 128-bit integer, so the fallbacks here use `float64` (exact for the
## magnitudes audio timebases produce) or saturate, and overflow-sensitive
## constructors return `Option`.

import std/math
import std/options

type
  Timestamp* = object
    ## Instant in timebase ticks.
    ticks*: int64

  Duration* = object
    ## Non-negative span in timebase ticks.
    ticks*: uint64

  Delta* = object
    ## Signed difference between timestamps in ticks.
    ticks*: int64

  Time* = object
    ## Wall-clock time: whole seconds plus 0..999_999_999 nanoseconds.
    seconds*: int64
    nanos*: uint32

  TimeBase* = object
    ## Seconds per tick as `numer / denom`. Both are always non-zero.
    numer*: uint32
    denom*: uint32

const
  NsPerSec* = 1_000_000_000'u32
  ZeroTimestamp* = Timestamp(ticks: 0)
  ZeroDuration* = Duration(ticks: 0)
  ZeroTime* = Time(seconds: 0, nanos: 0)

# ------------------------------------------------------------ Timestamp ---

proc newTimestamp*(ts: int64): Timestamp {.inline.} = Timestamp(ticks: ts)
proc get*(t: Timestamp): int64 {.inline.} = t.ticks
proc isZero*(t: Timestamp): bool {.inline.} = t.ticks == 0
proc isNegative*(t: Timestamp): bool {.inline.} = t.ticks < 0
proc isPositive*(t: Timestamp): bool {.inline.} = t.ticks > 0
proc `==`*(a, b: Timestamp): bool {.inline.} = a.ticks == b.ticks
proc `<`*(a, b: Timestamp): bool {.inline.} = a.ticks < b.ticks
proc `$`*(t: Timestamp): string = $t.ticks

proc checkedAddU64(a: int64; b: uint64): Option[int64] =
  ## Exact `a + b` or `none` on overflow.
  if b <= uint64(high(int64)):
    let bb = cast[int64](b)
    if bb >= 0 and a > high(int64) - bb:
      return none(int64)
    some(a + bb)
  else:
    if a >= 0:
      return none(int64)
    # a < 0: result = b - |a| fits iff b <= int64.high + |a|.
    let negA = uint64(-(a + 1)) + 1'u64 # == |a|, exact (a < 0).
    let limit = uint64(high(int64)) + negA # Cannot overflow: negA <= 2^63.
    if b > limit:
      none(int64)
    else:
      some(cast[int64](b - negA))

proc checkedSubU64(a: int64; b: uint64): Option[int64] =
  ## Exact `a - b` or `none` on overflow.
  if b <= uint64(high(int64)):
    let bb = cast[int64](b)
    if bb >= 0 and a < low(int64) + bb:
      return none(int64)
    some(a - bb)
  else:
    if a >= 0:
      return none(int64)
    # a < 0, b > int64.high: a - b <= a - 2^63 <= -1 - 2^63 < low. No fit.
    none(int64)

proc checkedAdd*(t: Timestamp; d: Duration): Option[Timestamp] =
  let r = checkedAddU64(t.ticks, d.ticks)
  if r.isNone: none(Timestamp) else: some(Timestamp(ticks: r.get))

proc checkedSub*(t: Timestamp; d: Duration): Option[Timestamp] =
  let r = checkedSubU64(t.ticks, d.ticks)
  if r.isNone: none(Timestamp) else: some(Timestamp(ticks: r.get))

proc saturatingAddU64(a: int64; b: uint64): int64 =
  let r = checkedAddU64(a, b)
  if r.isSome: r.get
  elif a >= 0 or b > uint64(high(int64)): high(int64)
  else: low(int64)

proc saturatingSubU64(a: int64; b: uint64): int64 =
  let r = checkedSubU64(a, b)
  if r.isSome: r.get
  elif a >= 0: low(int64)
  else: low(int64)

proc saturatingAdd*(t: Timestamp; d: Duration): Timestamp {.inline.} =
  Timestamp(ticks: saturatingAddU64(t.ticks, d.ticks))

proc saturatingSub*(t: Timestamp; d: Duration): Timestamp {.inline.} =
  Timestamp(ticks: saturatingSubU64(t.ticks, d.ticks))

proc checkedDelta*(a, b: Timestamp): Option[Delta] =
  if (a.ticks >= 0 and b.ticks < 0 and a.ticks > high(int64) + b.ticks) or
      (a.ticks < 0 and b.ticks >= 0 and a.ticks < low(int64) + b.ticks):
    none(Delta)
  else:
    some(Delta(ticks: a.ticks - b.ticks))

proc saturatingDelta*(a, b: Timestamp): Delta =
  let r = a.checkedDelta(b)
  if r.isSome: r.get
  elif (a.ticks >= 0) == (b.ticks >= 0): Delta(ticks: 0)
  elif a.ticks > b.ticks: Delta(ticks: high(int64))
  else: Delta(ticks: low(int64))

proc checkedAddDelta*(t: Timestamp; d: Delta): Option[Timestamp] =
  if (d.ticks >= 0 and t.ticks > high(int64) - d.ticks) or
      (d.ticks < 0 and t.ticks < low(int64) - d.ticks):
    none(Timestamp)
  else:
    some(Timestamp(ticks: t.ticks + d.ticks))

proc absDelta*(a, b: Timestamp): Duration =
  # Distance in two's-complement space is exact in u64.
  # Subtraction of same-sign-ordered values cannot overflow; but MIN-MIN
  # style extremes: use unsigned distance to be exact.
  if a.ticks == b.ticks:
    Duration(ticks: 0)
  else:
    let au = cast[uint64](a.ticks)
    let bu = cast[uint64](b.ticks)
    # Distance in two's-complement space is exact in u64.
    Duration(ticks: if au > bu: au - bu else: bu - au)

proc durationFrom*(a, b: Timestamp): Option[Duration] =
  ## Duration from `b` to `a`, or `none` if `a < b`.
  if a.ticks >= b.ticks: some(Duration(ticks: cast[uint64](a.ticks - b.ticks)))
  else: none(Duration)

proc durationTo*(a, b: Timestamp): Option[Duration] = durationFrom(b, a)

proc alignTowardsZero*(t: Timestamp; alignTo: Duration): Option[Timestamp] =
  if alignTo.ticks == 0 or alignTo.ticks > uint64(high(int64)):
    return none(Timestamp)
  let al = cast[int64](alignTo.ticks)
  some(Timestamp(ticks: (t.ticks div al) * al))

proc alignDown*(t: Timestamp; alignTo: Duration): Option[Timestamp] =
  if alignTo.ticks == 0 or alignTo.ticks > uint64(high(int64)):
    return none(Timestamp)
  let al = cast[int64](alignTo.ticks)
  some(Timestamp(ticks: t.ticks.floorDiv(al) * al))

# ------------------------------------------------------------- Duration ---

proc newDuration*(d: uint64): Duration {.inline.} = Duration(ticks: d)
proc get*(d: Duration): uint64 {.inline.} = d.ticks
proc isZero*(d: Duration): bool {.inline.} = d.ticks == 0
proc `==`*(a, b: Duration): bool {.inline.} = a.ticks == b.ticks
proc `<`*(a, b: Duration): bool {.inline.} = a.ticks < b.ticks
proc `$`*(d: Duration): string = $d.ticks

proc checkedAdd*(a, b: Duration): Option[Duration] =
  let s = a.ticks + b.ticks
  if s < a.ticks: none(Duration) else: some(Duration(ticks: s))

proc checkedSub*(a, b: Duration): Option[Duration] =
  if a.ticks < b.ticks: none(Duration) else: some(Duration(ticks: a.ticks - b.ticks))

proc checkedMul*(a: Duration; rhs: uint64): Option[Duration] =
  if rhs != 0 and a.ticks > high(uint64) div rhs: none(Duration)
  else: some(Duration(ticks: a.ticks * rhs))

proc checkedDiv*(a: Duration; rhs: uint64): Option[Duration] =
  if rhs == 0: none(Duration) else: some(Duration(ticks: a.ticks div rhs))

proc saturatingAdd*(a, b: Duration): Duration =
  let r = a.checkedAdd(b)
  if r.isSome: r.get else: Duration(ticks: high(uint64))

proc saturatingSub*(a, b: Duration): Duration =
  let r = a.checkedSub(b)
  if r.isSome: r.get else: Duration(ticks: 0)

proc saturatingMul*(a: Duration; rhs: uint64): Duration =
  let r = a.checkedMul(rhs)
  if r.isSome: r.get else: Duration(ticks: high(uint64))

proc alignTowardsZero*(d, alignTo: Duration): Option[Duration] =
  if alignTo.ticks == 0: none(Duration)
  else: some(Duration(ticks: (d.ticks div alignTo.ticks) * alignTo.ticks))

proc alignDown*(d, alignTo: Duration): Option[Duration] = d.alignTowardsZero(alignTo)

proc timestampFrom*(d: Duration; frm: Timestamp): Option[Timestamp] =
  frm.checkedAdd(d)

# ---------------------------------------------------------------- Delta ---

proc newDelta*(d: int64): Delta {.inline.} = Delta(ticks: d)
proc get*(d: Delta): int64 {.inline.} = d.ticks
proc isZero*(d: Delta): bool {.inline.} = d.ticks == 0
proc isNegative*(d: Delta): bool {.inline.} = d.ticks < 0
proc isPositive*(d: Delta): bool {.inline.} = d.ticks > 0
proc `$`*(d: Delta): string = $d.ticks

# ----------------------------------------------------------------- Time ---

proc tryNewTime*(s: int64; ns: uint32): Option[Time] =
  if ns >= NsPerSec: none(Time) else: some(Time(seconds: s, nanos: ns))

proc newTime*(s: int64; ns: uint32): Time =
  ## Unchecked constructor, `ns` must be < 1e9 (asserted in debug).
  assert ns < NsPerSec
  Time(seconds: s, nanos: ns)

proc fromNanos*(totalNs: int64): Time =
  let s = totalNs.floorDiv(NsPerSec.int64)
  Time(seconds: s, nanos: cast[uint32](totalNs - s * NsPerSec.int64))

proc fromNanosU64*(totalNs: uint64): Time =
  let per = NsPerSec.uint64
  Time(seconds: cast[int64](totalNs div per), nanos: cast[uint32](totalNs mod per))

proc fromMicros*(totalUs: int64): Time =
  let s = totalUs.floorDiv(1_000_000'i64)
  Time(seconds: s, nanos: 1_000 * cast[uint32](totalUs - s * 1_000_000'i64))

proc fromMillis*(totalMs: int64): Time =
  let s = totalMs.floorDiv(1_000'i64)
  Time(seconds: s, nanos: 1_000_000 * cast[uint32](totalMs - s * 1_000'i64))

proc fromSs*(s: uint8; ns: uint32): Option[Time] =
  if s > 59 or ns >= NsPerSec: none(Time)
  else: some(Time(seconds: s.int64, nanos: ns))

proc fromMmss*(m, s: uint8; ns: uint32): Option[Time] =
  if m > 59 or s > 59 or ns >= NsPerSec: none(Time)
  else: some(Time(seconds: 60 * m.int64 + s.int64, nanos: ns))

proc fromHhmmss*(h: uint32; m, s: uint8; ns: uint32): Option[Time] =
  if m > 59 or s > 59 or ns >= NsPerSec: none(Time)
  else: some(Time(seconds: 3600 * h.int64 + 60 * m.int64 + s.int64, nanos: ns))

proc isZero*(t: Time): bool {.inline.} = t.seconds == 0 and t.nanos == 0
proc isPositive*(t: Time): bool {.inline.} = t.seconds > 0
proc isNegative*(t: Time): bool {.inline.} = t.seconds < 0

proc asNanos*(t: Time): int64 =
  ## Total nanoseconds, saturated (Symphonia returns 128-bit here).
  let base =
    if t.seconds > high(int64) div NsPerSec.int64: high(int64)
    elif t.seconds < low(int64) div NsPerSec.int64: low(int64)
    else: t.seconds * NsPerSec.int64
  if base == high(int64) or base == low(int64):
    return base
  if t.nanos.uint64 > uint64(high(int64)) - uint64(base):
    return high(int64)
  base + t.nanos.int64

proc asMicros*(t: Time): int64 = t.asNanos() div 1_000
proc asMillis*(t: Time): int64 = t.asNanos() div 1_000_000

proc asSecs*(t: Time): int64 =
  if t.seconds >= 0 or t.nanos == 0: t.seconds else: t.seconds + 1

proc asSecsF64*(t: Time): float64 = t.seconds.float64 + t.nanos.float64 * 1e-9

proc parts*(t: Time): tuple[seconds: int64, nanos: uint32] =
  ## Splits into whole seconds plus an always-positive fraction.
  if t.seconds >= 0:
    (t.seconds, t.nanos)
  elif t.nanos == 0:
    (t.seconds, 0'u32)
  else:
    (t.seconds + 1, NsPerSec - t.nanos)

proc checkedNeg*(t: Time): Option[Time] =
  if t.nanos == 0:
    if t.seconds == low(int64): none(Time)
    else: some(Time(seconds: -t.seconds, nanos: 0))
  else:
    if t.seconds == low(int64): none(Time)
    else: some(Time(seconds: -t.seconds - 1, nanos: NsPerSec - t.nanos))

proc addParts(t: Time; deltaSecs, deltaNanos: int64): Option[Time] =
  if (deltaSecs >= 0 and t.seconds > high(int64) - deltaSecs) or
      (deltaSecs < 0 and t.seconds < low(int64) - deltaSecs):
    return none(Time)
  let seconds = t.seconds + deltaSecs
  var nanos = t.nanos.int64 + deltaNanos
  if nanos >= NsPerSec.int64:
    if seconds == high(int64): return none(Time)
    some(Time(seconds: seconds + 1, nanos: cast[uint32](nanos - NsPerSec.int64)))
  elif nanos < 0:
    if seconds == low(int64): return none(Time)
    some(Time(seconds: seconds - 1, nanos: cast[uint32](nanos + NsPerSec.int64)))
  else:
    some(Time(seconds: seconds, nanos: cast[uint32](nanos)))

proc checkedAddNanos*(t: Time; ns: int64): Option[Time] =
  t.addParts(ns.floorDiv(NsPerSec.int64), ns mod NsPerSec.int64)

proc checkedSubNanos*(t: Time; ns: int64): Option[Time] =
  # Subtract ns == add (-ns), computed without overflowing on low(int64).
  t.addParts(-(ns.floorDiv(NsPerSec.int64)) - (if (ns mod NsPerSec.int64) > 0: 1 else: 0),
    -(ns mod NsPerSec.int64) +
      (if (ns mod NsPerSec.int64) > 0: NsPerSec.int64 else: 0))

proc checkedAddMillis*(t: Time; ms: int64): Option[Time] =
  t.addParts(ms.floorDiv(1_000'i64), 1_000_000 * (ms mod 1_000'i64))

proc checkedSubMillis*(t: Time; ms: int64): Option[Time] =
  if ms == low(int64): # -ms overflows; split instead.
    let r = t.checkedSubMillis(ms + 1)
    if r.isNone: none(Time) else: r.get.checkedSubMillis(1)
  else:
    t.checkedAddMillis(-ms)

proc checkedAddSecs*(t: Time; s: int64): Option[Time] = t.addParts(s, 0)
proc checkedSubSecs*(t: Time; s: int64): Option[Time] =
  if s == low(int64): none(Time) else: t.addParts(-s, 0)

# ------------------------------------------------------------- TimeBase ---

proc defaultTimeBase*(): TimeBase {.inline.} = TimeBase(numer: 1, denom: 1)

proc tryNewTimeBase*(numer, denom: uint32): Option[TimeBase] =
  if numer == 0 or denom == 0: none(TimeBase)
  else: some(TimeBase(numer: numer, denom: denom))

proc tryFromRecip*(rate: uint32): Option[TimeBase] =
  tryNewTimeBase(1, rate)

proc toFloat64*(tb: TimeBase): float64 {.inline.} =
  tb.numer.float64 / tb.denom.float64

proc `$`*(tb: TimeBase): string = $tb.numer & "/" & $tb.denom

proc checkedMul2(a, b: int64): Option[int64] =
  ## Exact `a * b` or `none`. All four sign combinations handled, and the
  ## guarded `a * b` itself cannot overflow (no reliance on hardware flags).
  if a == 0 or b == 0:
    return some(0'i64)
  if a > 0 and b > 0:
    if a > high(int64) div b: none(int64) else: some(a * b)
  elif a > 0: # b < 0
    if b < low(int64) div a: none(int64) else: some(a * b)
  elif b > 0: # a < 0
    if a < low(int64) div b: none(int64) else: some(a * b)
  else: # a < 0 and b < 0
    if a < high(int64) div b: none(int64) else: some(a * b)

proc checkedMul3(a, b, c: int64): Option[int64] =
  ## Exact `a * b * c` or `none`.
  let ab = checkedMul2(a, b)
  if ab.isNone: none(int64) else: checkedMul2(ab.get, c)

proc calcTime*(tb: TimeBase; ts: Timestamp): Option[Time] =
  ## Tick count -> wall-clock, or `none` on overflow.
  let numer = tb.numer.int64
  let denom = tb.denom.int64
  # Divide first to stay in int64: ts = q*denom + r, so
  # total = q*numer*1e9 + (r*numer*1e9)/denom. Only the small
  # remainder term needs a division.
  let q = ts.ticks div denom
  let r = ts.ticks mod denom
  let whole = checkedMul3(q, numer, NsPerSec.int64)
  let frac = checkedMul3(r, numer, NsPerSec.int64)
  if whole.isSome and frac.isSome:
    let w = whole.get
    let f = frac.get div denom
    if (f >= 0 and w > high(int64) - f) or (f < 0 and w < low(int64) - f):
      # Fall through to float path.
      discard
    else:
      return some(fromNanos(w + f))
  # Float64 fallback (Symphonia uses 128-bit here; exact for audio magnitudes).
  let total = ts.ticks.float64 * numer.float64 * 1e9 / denom.float64
  if total != total or total > high(int64).float64 or total < low(int64).float64:
    return none(Time)
  some(fromNanos(cast[int64](total)))

proc calcTimeSaturating*(tb: TimeBase; ts: Timestamp): Time =
  let r = tb.calcTime(ts)
  if r.isSome: r.get
  elif ts.isNegative: Time(seconds: low(int64), nanos: 0)
  else: Time(seconds: high(int64), nanos: NsPerSec - 1)

proc calcDuration*(tb: TimeBase; d: Duration): Option[Time] =
  # Reuse calcTime on the tick count when it fits in int64.
  if d.ticks > uint64(high(int64)):
    let total = d.ticks.float64 * tb.numer.float64 * 1e9 / tb.denom.float64
    if total != total or total >= high(int64).float64:
      return none(Time)
    return some(fromNanosU64(cast[uint64](total)))
  tb.calcTime(Timestamp(ticks: cast[int64](d.ticks)))

proc calcDurationSaturating*(tb: TimeBase; d: Duration): Time =
  let r = tb.calcDuration(d)
  if r.isSome: r.get else: Time(seconds: high(int64), nanos: NsPerSec - 1)

proc calcTimestamp*(tb: TimeBase; t: Time): Option[Timestamp] =
  let numer = tb.numer.int64
  let denom = tb.denom.int64
  let frac = (t.nanos.int64 * denom) div NsPerSec.int64
  # whole = seconds * denom (+ frac), then / numer.
  if t.seconds != 0 and
      ((denom > 0 and (t.seconds > high(int64) div denom or
        t.seconds < low(int64) div denom))):
    # Float fallback for extreme times.
    let ts = (t.seconds.float64 * denom.float64 + frac.float64) / numer.float64
    if ts != ts or ts > high(int64).float64 or ts < low(int64).float64:
      return none(Timestamp)
    return some(Timestamp(ticks: cast[int64](ts)))
  let whole =
    if t.seconds == 0: frac
    else:
      let p = t.seconds * denom
      if (frac >= 0 and p > high(int64) - frac): return none(Timestamp)
      p + frac
  some(Timestamp(ticks: whole div numer))

proc scale*(tb: TimeBase; factor: float64): Option[TimeBase] =
  if factor == 1.0:
    return some(tb)
  if factor != factor or factor == Inf or factor == NegInf or factor <= 0.0:
    return none(TimeBase)
  let numer = (tb.numer.float64 * factor).round
  if numer > high(uint32).float64:
    return none(TimeBase)
  let n = cast[uint32](numer)
  if n == 0: none(TimeBase) else: some(TimeBase(numer: n, denom: tb.denom))

proc gcd(a, b: uint32): uint32 =
  var x = a
  var y = b
  while y != 0:
    let r = x mod y
    x = y
    y = r
  x

proc reduce*(tb: TimeBase): TimeBase =
  let g = gcd(tb.numer, tb.denom)
  TimeBase(numer: tb.numer div g, denom: tb.denom div g)
