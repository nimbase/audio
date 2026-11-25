import std/options
import unittest

import audio/errors
import audio/units
import audio/audio
import audio/io

suite "errors":
  test "kinds and messages":
    let e = decodeError("x")
    check e.kind == ekDecode
    try:
      raise unsupportedError("nope")
      check false
    except AudioError as err:
      check err.kind == ekUnsupported
    try:
      raise seekError(skOutOfRange)
      check false
    except AudioError as err:
      check err.kind == ekSeek
      check err.seekKind == skOutOfRange

suite "timestamp/duration":
  test "checked and saturating arithmetic":
    let t = newTimestamp(100)
    check t.checkedAdd(newDuration(50)).get.ticks == 150
    check t.checkedSub(newDuration(200)).get.ticks == -100
    check newTimestamp(high(int64)).checkedAdd(newDuration(1)).isNone
    check newTimestamp(high(int64)).saturatingAdd(newDuration(1)).ticks ==
      high(int64)
    check newTimestamp(low(int64)).saturatingSub(newDuration(1)).ticks ==
      low(int64)
    check newTimestamp(10).checkedDelta(newTimestamp(4)).get.ticks == 6
    check newTimestamp(4).absDelta(newTimestamp(10)).ticks == 6
    check newTimestamp(10).durationFrom(newTimestamp(4)).get.ticks == 6
    check newTimestamp(4).durationFrom(newTimestamp(10)).isNone
    check newTimestamp(12345).alignTowardsZero(newDuration(1152)).get.ticks ==
      11520
    check newTimestamp(-1).alignDown(newDuration(1152)).get.ticks == -1152
    let d = newDuration(7)
    check d.checkedMul(6).get.ticks == 42
    check newDuration(high(uint64)).checkedMul(2).isNone
    check d.timestampFrom(newTimestamp(3)).get.ticks == 10

  test "timebase calc":
    let tb = tryFromRecip(44_100'u32).get
    check tb.calcTime(newTimestamp(44_100)).get.asSecs() == 1
    check tb.calcTimestamp(fromMillis(1_000)).get.ticks == 44_100
    check tb.calcDuration(newDuration(44_100)).get.asSecs() == 1
    check defaultTimeBase().calcTime(newTimestamp(5)).get.asSecs() == 5
    check tryNewTimeBase(0, 1).isNone
    check tryNewTimeBase(1, 0).isNone
    check tb.reduce() == tb

  test "time parts":
    let t = tryNewTime(-2, 750_000_000).get
    check t.parts() == (-1'i64, 250_000_000'u32)
    check fromMillis(-250).asMillis() == -250
    check fromNanos(1_500_000_000).asSecs() == 1
    check tryNewTime(0, 1_000_000_000).isNone
    check fromSs(59, 0).isSome
    check fromSs(60, 0).isNone

suite "audio buffer":
  test "planar storage and silence":
    let spec = newAudioSpec(48_000, ChStereo)
    var buf = newAudioBuffer[int16](spec, 4)
    check buf.numPlanes == 2
    check buf.planes[0][0] == 0
    var ubuf = newAudioBuffer[uint8](spec, 2)
    check ubuf.planes[1][1] == 128'u8
    buf.renderWith(4, i):
      buf.planes[0][i] = cast[int16](i)
      buf.planes[1][i] = cast[int16](-i)
    check buf.frames == 4
    check buf.planes[1][3] == -3
    buf.shift(1)
    check buf.frames == 3
    check buf.planes[0][0] == 1
    var dst = newSeq[int16](6)
    buf.copyInterleavedTo(dst.toOpenArray(0, 5))
    check dst == @[1'i16, -1, 2, -2, 3, -3]

  test "channels":
    check ChStereo.channelCount() == 2
    check discrete(6).channelCount() == 6
    check positionFromCount(0).isNone
    check positionFromCount(33).isNone
    check positionFromCount(2).get == (PosFrontLeft or PosFrontRight)

  test "sample conversion":
    check toI16(cast[int8](-128)) == low(int16)
    check toI16(127'i8) == 32_512
    check toI8(32_512'i16) == 127'i8
    check toU8(0'u8) == 0'u8
    check toU16(0x80'u8) == 32_768'u16
    check clampI24(1_000_000_000) == 8_388_607
    check clampU24(1'u32 shl 30) == 16_777_215'u32
    check abs(toF32(high(int16)) - 0.9999695'f32) < 1e-6
    check fromF32ToI16(1.0'f32) == 32_767
    check fromF32ToI16(-2.0'f32) == low(int16)

suite "io":
  test "le/be primitives and 24-bit sign extension":
    var r = newReader(@[0x01'u8, 0x02, 0x03, 0x04, 0xff, 0xff, 0xff])
    check r.readU16Le() == 0x0201'u16
    check r.readU16Be() == 0x0304'u16
    check r.readI24Le() == -1
    var r2 = newReader(@[0x00'u8, 0x00, 0x80])
    check r2.readI24Le() == -8_388_608
    var r3 = newReader(@[0xff'u8, 0xff, 0x7f])
    check r3.readI24Le() == 8_388_607
    var r4 = newReader(@[0x00'u8, 0x00, 0x80, 0xc0])
    check r4.readI24Be() == 0x000080
    check r4.readByte() == 0xc0'u8
    var w = newWriter()
    w.writeU24Le(0x123456'u32)
    w.writeU24Be(0x123456'u32)
    w.writeF32Le(1.5'f32)
    var rr = newReader(w.toBytes())
    check rr.readU24Le() == 0x123456'u32
    check rr.readU24Be() == 0x123456'u32
    check rr.readF32Le() == 1.5'f32

  test "underrun raises decode error":
    var r = newReader(@[0x01'u8])
    try:
      discard r.readU32Le()
      check false
    except AudioError as e:
      check e.kind == ekDecode
