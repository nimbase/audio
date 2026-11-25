import std/options
import unittest

import audio/codecs
import audio/codecs/pcm
import audio/audio
import audio/packet
import audio/units
import audio/errors

proc paramsFor(codec: AudioCodecId; rate = 44_100'u32;
    ch = ChStereo): AudioCodecParameters =
  result = forCodec(codec)
  result.sampleRate = some(rate)
  result.channels = some(ch)

# ---------------------------------------------------------------- helpers ---

proc fillTestPattern(buf: var AudioSamples) =
  ## Deterministic full-range-ish pattern per format.
  case buf.format
  of sfS8:
    buf.s8.renderWith(4, i):
      buf.s8.planes[0][i] = cast[int8]([0, 127, -128, 42][i])
  of sfU8:
    buf.u8.renderWith(4, i):
      buf.u8.planes[0][i] = cast[uint8]([0, 255, 128, 42][i])
  of sfS16:
    buf.s16.renderWith(4, i):
      buf.s16.planes[0][i] = cast[int16]([0, 32_767, -32_768, 12_345][i])
  of sfU16:
    buf.u16.renderWith(4, i):
      buf.u16.planes[0][i] = cast[uint16]([0, 65_535, 32_768, 12_345][i])
  of sfS24:
    buf.s24.renderWith(4, i):
      buf.s24.planes[0][i] = cast[int32]([0, 8_388_607, -8_388_608,
        1_234_567][i])
  of sfU24:
    buf.u24.renderWith(4, i):
      buf.u24.planes[0][i] = cast[uint32]([0, 16_777_215, 8_388_608,
        1_234_567][i])
  of sfS32:
    buf.s32.renderWith(4, i):
      buf.s32.planes[0][i] = [0'i32, high(int32), low(int32), 1_234_567][i]
  of sfU32:
    buf.u32.renderWith(4, i):
      buf.u32.planes[0][i] = [0'u32, high(uint32), 2_147_483_648'u32,
        1_234_567][i]
  of sfF32:
    buf.f32.renderWith(4, i):
      buf.f32.planes[0][i] = [0.0'f32, 1.0, -1.0, 0.1234567][i]
  of sfF64:
    buf.f64.renderWith(4, i):
      buf.f64.planes[0][i] = [0.0, 1.0, -1.0, 0.123456789012345][i]

proc checkSamplesEqual(a, b: AudioSamples) =
  check a.format == b.format
  check a.framesOf() == b.framesOf()
  case a.format
  of sfS8:
    for i in 0 ..< a.framesOf(): check a.s8.planes[0][i] == b.s8.planes[0][i]
  of sfU8:
    for i in 0 ..< a.framesOf(): check a.u8.planes[0][i] == b.u8.planes[0][i]
  of sfS16:
    for i in 0 ..< a.framesOf():
      check a.s16.planes[0][i] == b.s16.planes[0][i]
  of sfU16:
    for i in 0 ..< a.framesOf():
      check a.u16.planes[0][i] == b.u16.planes[0][i]
  of sfS24:
    for i in 0 ..< a.framesOf():
      check a.s24.planes[0][i] == b.s24.planes[0][i]
  of sfU24:
    for i in 0 ..< a.framesOf():
      check a.u24.planes[0][i] == b.u24.planes[0][i]
  of sfS32:
    for i in 0 ..< a.framesOf():
      check a.s32.planes[0][i] == b.s32.planes[0][i]
  of sfU32:
    for i in 0 ..< a.framesOf():
      check a.u32.planes[0][i] == b.u32.planes[0][i]
  of sfF32:
    for i in 0 ..< a.framesOf():
      check a.f32.planes[0][i] == b.f32.planes[0][i]
  of sfF64:
    for i in 0 ..< a.framesOf():
      check a.f64.planes[0][i] == b.f64.planes[0][i]

suite "pcm validation":
  test "requires rate and channels":
    var p = forCodec(CodecPcmS16Le)
    try:
      discard newPcmDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    p.sampleRate = some(44_100'u32)
    try:
      discard newPcmDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

  test "rejects planar and bogus widths":
    var p = paramsFor(CodecPcmS16LePlanar)
    try:
      discard newPcmDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    var q = paramsFor(CodecPcmS16Le)
    q.bitsPerSample = some(17'u32)
    try:
      discard newPcmDecoder(q)
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "shifted decode scales coded width":
    var p = paramsFor(CodecPcmS16Le)
    p.bitsPerSample = some(16'u32)
    p.bitsPerCodedSample = some(8'u32)
    let dec = newPcmDecoder(p)
    check dec.shift == 8
    let pkt = newPacket(0, ZeroTimestamp, newDuration(2),
      @[0x40'u8, 0x00, 0xc0'u8, 0x00, 0x01'u8, 0x00, 0xff'u8, 0x7f])
    let s = dec.decodePacket(pkt)
    # 0x0040 << 8 = 0x4000 on both channels of frame 0.
    check s.s16.planes[0][0] == 0x4000'i16
    check s.s16.planes[1][0] == cast[int16](0x00c0'u16 shl 8)
    check s.s16.planes[0][1] == 0x0100'i16
    check s.s16.planes[1][1] == cast[int16](0xff00'u16) # 0x7FFF << 8 wraps.

suite "pcm decode vectors":
  test "s16le stereo":
    let dec = newPcmDecoder(paramsFor(CodecPcmS16Le))
    let pkt = newPacket(0, ZeroTimestamp, newDuration(2),
      @[0x01'u8, 0x00, 0xff, 0xff, 0x00, 0x80, 0xff, 0x7f])
    let s = dec.decodePacket(pkt)
    check s.format == sfS16
    check s.framesOf() == 2
    check s.s16.planes[0][0] == 1
    check s.s16.planes[1][0] == -1
    check s.s16.planes[0][1] == low(int16)
    check s.s16.planes[1][1] == high(int16)

  test "s16be and u8":
    let be = newPcmDecoder(paramsFor(CodecPcmS16Be))
    let pkt = newPacket(0, ZeroTimestamp, newDuration(1),
      @[0x12'u8, 0x34, 0x56'u8, 0x78])
    let s = be.decodePacket(pkt)
    check s.s16.planes[0][0] == 0x1234'i16
    check s.s16.planes[1][0] == 0x5678'i16
    let u8 = newPcmDecoder(paramsFor(CodecPcmU8))
    let pkt2 = newPacket(0, ZeroTimestamp, newDuration(1),
      @[0x00'u8, 0x80, 0xff])
    # 3 bytes, stereo: 1 frame + 1 trailing byte dropped.
    let s2 = u8.decodePacket(pkt2)
    check s2.framesOf() == 1
    check s2.u8.planes[0][0] == 0
    check s2.u8.planes[1][0] == 128

  test "s24le sign extension":
    let dec = newPcmDecoder(paramsFor(CodecPcmS24Le))
    let pkt = newPacket(0, ZeroTimestamp, newDuration(2),
      @[0x00'u8, 0x00, 0x80, 0x00, 0x00, 0x00, 0xff, 0xff, 0x7f, 0x00, 0x00,
        0x00])
    let s = dec.decodePacket(pkt)
    check s.s24.planes[0][0] == -8_388_608
    check s.s24.planes[1][0] == 0
    check s.s24.planes[0][1] == 8_388_607
    check s.s24.planes[1][1] == 0

  test "f32le and f64le":
    let fdec = newPcmDecoder(paramsFor(CodecPcmF32Le))
    let pkt = newPacket(0, ZeroTimestamp, newDuration(1),
      @[0x00'u8, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0xbf])
    let s = fdec.decodePacket(pkt)
    check s.f32.planes[0][0] == 1.0'f32
    check s.f32.planes[1][0] == -1.0'f32
    let ddec = newPcmDecoder(paramsFor(CodecPcmF64Le))
    var data: seq[uint8] = @[]
    for b in [0x00'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f,
        0x00'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0xbf]:
      data.add(b)
    let pkt2 = newPacket(0, ZeroTimestamp, newDuration(1), data)
    let s2 = ddec.decodePacket(pkt2)
    check s2.f64.planes[0][0] == 1.0
    check s2.f64.planes[1][0] == -1.0

  test "law roundtrip is exact over all codes":
    for b in 0 ..< 256:
      let code = cast[uint8](b)
      check linearToALaw(alawToLinear(code)) == code
      if code == 0x7f'u8:
        # Mu-law -0 collapses onto the conventional +0 encoding.
        check linearToMuLaw(mulawToLinear(code)) == 0xff'u8
      else:
        check linearToMuLaw(mulawToLinear(code)) == code
    # Known vectors: A-law 0xD5 decodes to 8, mu-law 0xFF to 0.
    check alawToLinear(0xd5'u8) == 8
    check mulawToLinear(0xff'u8) == 0

suite "pcm encode":
  test "s16 stereo roundtrip":
    let spec = newAudioSpec(44_100, ChStereo)
    var buf = newAudioSamples(sfS16, spec, 8)
    buf.s16.renderWith(8, i):
      buf.s16.planes[0][i] = cast[int16](i * 1000 - 4000)
      buf.s16.planes[1][i] = cast[int16](4000 - i * 1000)
    let bytes = encodePcm(buf, CodecPcmS16Le)
    check bytes.len == 8 * 2 * 2
    let dec = newPcmDecoder(paramsFor(CodecPcmS16Le))
    let back = dec.decodePacket(newPacket(0, ZeroTimestamp, newDuration(8),
      bytes))
    for i in 0 ..< 8:
      check back.s16.planes[0][i] == buf.s16.planes[0][i]
      check back.s16.planes[1][i] == buf.s16.planes[1][i]

  test "all integer widths roundtrip":
    for (fmt, codec) in [(sfS8, CodecPcmS8), (sfU8, CodecPcmU8),
        (sfS16, CodecPcmS16Le), (sfU16, CodecPcmU16Be),
        (sfS24, CodecPcmS24Le), (sfU24, CodecPcmU24Be),
        (sfS32, CodecPcmS32Le), (sfU32, CodecPcmU32Be)]:
      let spec = newAudioSpec(48_000, discrete(1))
      var buf = newAudioSamples(fmt, spec, 4)
      fillTestPattern(buf)
      let bytes = encodePcm(buf, codec)
      var qp = paramsFor(codec, 48_000'u32, discrete(1))
      qp.bitsPerSample = some(sampleWidthBits(fmt).uint32)
      qp.bitsPerCodedSample = some(sampleWidthBits(fmt).uint32)
      let dec = newPcmDecoder(qp)
      let back = dec.decodePacket(newPacket(0, ZeroTimestamp,
        newDuration(4), bytes))
      checkSamplesEqual(buf, back)

  test "float roundtrip is bit-exact":
    for (fmt, codec) in [(sfF32, CodecPcmF32Be), (sfF64, CodecPcmF64Le)]:
      let spec = newAudioSpec(48_000, discrete(1))
      var buf = newAudioSamples(fmt, spec, 4)
      fillTestPattern(buf)
      let bytes = encodePcm(buf, codec)
      let dec = newPcmDecoder(paramsFor(codec, 48_000'u32, discrete(1)))
      let back = dec.decodePacket(newPacket(0, ZeroTimestamp,
        newDuration(4), bytes))
      checkSamplesEqual(buf, back)

  test "law encode matches decode domain":
    let spec = newAudioSpec(8_000, discrete(1))
    var buf = newAudioSamples(sfS16, spec, 4)
    buf.s16.renderWith(4, i):
      buf.s16.planes[0][i] = cast[int16]([0, 8, -8, 10_000][i])
    for codec in [CodecPcmALaw, CodecPcmMuLaw]:
      let bytes = encodePcm(buf, codec)
      check bytes.len == 4
      let dec = newPcmDecoder(paramsFor(codec, 8_000'u32, discrete(1)))
      let back = dec.decodePacket(newPacket(0, ZeroTimestamp,
        newDuration(4), bytes))
      # Each decoded sample must be a fixed point of encode o decode.
      let re = encodePcm(back, codec)
      check re == bytes

  test "registry make":
    registerPcm()
    let dec = makeAudioDecoder(paramsFor(CodecPcmF32Le))
    check dec != nil
    try:
      discard makeAudioDecoder(paramsFor(CodecFlac))
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
