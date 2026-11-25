import std/options
import std/math
import unittest

import audio/codecs
import audio/codecs/adpcm
import audio/audio
import audio/formats/wav
import audio/packet
import audio/units
import audio/errors

proc adpcmParams(codec: AudioCodecId; fpb: uint64; maxf: uint64;
    rate = 44_100'u32; ch = ChStereo): AudioCodecParameters =
  result = forCodec(codec)
  result.sampleRate = some(rate)
  result.channels = some(ch)
  result.framesPerBlock = some(fpb)
  result.maxFramesPerPacket = some(maxf)

proc decodeOne(codec: AudioCodecId; fpb: int; data: seq[uint8];
    ch = ChStereo): AudioSamples =
  let params = adpcmParams(codec, fpb.uint64, (fpb * 2).uint64,
    44_100'u32, ch)
  let dec = newAdpcmDecoder(params)
  let pkt = newPacket(0, ZeroTimestamp, newDuration(fpb.uint64), data)
  dec.decodePacket(pkt)

suite "adpcm tables":
  test "table shapes match the standard":
    check ImaStepTable.len == 89
    check ImaStepTable[0] == 7
    check ImaStepTable[88] == 32_767
    check ImaIndexTable == [-1'i32, -1, -1, -1, 2, 4, 6, 8,
      -1, -1, -1, -1, 2, 4, 6, 8]
    check MsAdaptTable.len == 16
    check MsAdaptTable[8] == 768
    check MsCoeffs1 == [256'i32, 512, 0, 192, 240, 460, 392]
    check MsCoeffs2 == [0'i32, -256, 0, 64, 0, -208, -232]

suite "adpcm validation":
  test "requires max frames, block size, rate, <= 2 channels":
    var p = forCodec(CodecAdpcmMs)
    p.sampleRate = some(44_100'u32)
    p.channels = some(ChStereo)
    p.framesPerBlock = some(500'u64)
    try:
      discard newAdpcmDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    p.maxFramesPerPacket = some(500'u64)
    p.framesPerBlock = some(0'u64)
    try:
      discard newAdpcmDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    p.framesPerBlock = some(500'u64)
    p.channels = some(discrete(3))
    try:
      discard newAdpcmDecoder(p)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    try:
      discard newAdpcmDecoder(adpcmParams(CodecPcmS16Le, 1152, 1152))
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "ms decode":
  test "mono zero nibbles hold the preamble":
    # pred 0, delta 0x0100, s1 0x1000, s2 0x0800, one zero data byte.
    let s = decodeOne(CodecAdpcmMs, 4,
      @[0x00'u8, 0x00, 0x01, 0x00, 0x10, 0x00, 0x08, 0x00],
      discrete(1))
    check s.format == sfS32
    check s.framesOf() == 4
    check s.s32.planes[0][0 .. 3] == @[2048'i32 shl 16, 4096'i32 shl 16,
      4096'i32 shl 16, 4096'i32 shl 16]

  test "predictor index above 6 is unsupported":
    try:
      discard decodeOne(CodecAdpcmMs, 4,
        @[0x07'u8, 0x00, 0x01, 0x00, 0x10, 0x00, 0x08, 0x00],
        discrete(1))
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

  test "stereo keeps channels independent":
    let s = decodeOne(CodecAdpcmMs, 4, @[
      0x00'u8, 0x01, # L pred 0, R pred 1
      0x00'u8, 0x01, # L delta 0x0100
      0x00'u8, 0x02, # R delta 0x0200
      0x00'u8, 0x10, # L s1 0x1000
      0x00'u8, 0x20, # R s1 0x2000
      0x00'u8, 0x08, # L s2 0x0800
      0x00'u8, 0x10, # R s2 0x1000
      0x00'u8, 0x00'u8, # frames 2,3: zero nibbles
    ])
    check s.s32.planes[0][0 .. 3] == @[2048'i32 shl 16, 4096'i32 shl 16,
      4096'i32 shl 16, 4096'i32 shl 16]
    check s.s32.planes[1][0 .. 3] == @[4096'i32 shl 16, 8192'i32 shl 16,
      12_288'i32 shl 16, 16_384'i32 shl 16]

  test "odd mono frame count is rejected":
    try:
      discard decodeOne(CodecAdpcmMs, 3,
        @[0x00'u8, 0x00, 0x01, 0x00, 0x10, 0x00, 0x08, 0x00],
        discrete(1))
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "ima-wav decode":
  test "mono nibble math":
    # pred 0, step 0; byte 0x07: lower nibble 7 first.
    # frame1: ((2*7+1)*7)>>3 = 13; frame2: step 16, ((1)*16)>>3 = 2 -> 15.
    let s = decodeOne(CodecAdpcmImaWav, 3,
      @[0x00'u8, 0x00, 0x00, 0x00, 0x07'u8], discrete(1))
    check s.s32.planes[0][0 .. 2] == @[0'i32, 13'i32 shl 16, 15'i32 shl 16]

  test "step index above 88 is a decode error":
    try:
      discard decodeOne(CodecAdpcmImaWav, 3,
        @[0x00'u8, 0x00, 0x59, 0x00, 0x07'u8], discrete(1))
      check false
    except AudioError as e:
      check e.kind == ekDecode

  test "stereo deinterleaves in 8-frame groups":
    var data = @[0x00'u8, 0x10, 0x00, 0x00, # L pred 0x1000, step 0
      0x00'u8, 0x20, 0x00, 0x00] # R pred 0x2000, step 0
    data.add([0x70'u8, 0x00, 0x00, 0x00, 0x70'u8, 0x00, 0x00, 0x00])
    let s = decodeOne(CodecAdpcmImaWav, 9, data)
    check s.framesOf() == 9
    check s.s32.planes[0][0] == 4096'i32 shl 16
    check s.s32.planes[1][0] == 8192'i32 shl 16
    # Byte 0 (L): lower nibble 0 holds the predictor, upper nibble 7
    # steps to +13. Same for R with byte 4. This also proves the
    # lower-first nibble order.
    check s.s32.planes[0][1] == 4096'i32 shl 16
    check s.s32.planes[0][2] == 4109'i32 shl 16
    check s.s32.planes[1][1] == 8192'i32 shl 16
    check s.s32.planes[1][2] == 8205'i32 shl 16
    # Adaptation continues independently per channel.
    check s.s32.planes[0][5] == 4113'i32 shl 16
    check s.s32.planes[1][5] == 8209'i32 shl 16

  test "stereo requires (frames-1) multiple of 8":
    try:
      discard decodeOne(CodecAdpcmImaWav, 5,
        newSeq[uint8](4 + 4 + 4))
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "ima-qt decode":
  test "mono block is fixed 64 frames":
    var data = @[0x00'u8, 0x00]
    for _ in 0 ..< 32:
      data.add(0'u8)
    let s = decodeOne(CodecAdpcmImaQt, 64, data, discrete(1))
    check s.framesOf() == 64
    for i in 0 ..< 64:
      check s.s32.planes[0][i] == 0

  test "header carries 9-bit predictor":
    var data = @[0xff'u8, 0x80]
    for _ in 0 ..< 32:
      data.add(0'u8)
    let s = decodeOne(CodecAdpcmImaQt, 64, data, discrete(1))
    # 0xFF80 as i16 = -128; zero nibbles hold it.
    check s.s32.planes[0][0] == -128'i32 shl 16
    check s.s32.planes[0][63] == -128'i32 shl 16

  test "stereo is two mono blocks":
    var data: seq[uint8] = @[0x00'u8, 0x00]
    for _ in 0 ..< 32:
      data.add(0'u8)
    data.add([0xff'u8, 0x80])
    for _ in 0 ..< 32:
      data.add(0'u8)
    check data.len == 68
    let params = adpcmParams(CodecAdpcmImaQt, 64, 128, 44_100'u32, ChStereo)
    let dec = newAdpcmDecoder(params)
    let pkt = newPacket(0, ZeroTimestamp, newDuration(128), data)
    let s = dec.decodePacket(pkt)
    check s.framesOf() == 128
    check s.s32.planes[0][0] == 0
    check s.s32.planes[1][63] == -128'i32 shl 16

# ---------------------------------------------------------------- helpers ---

proc sineS16(n: int; amp = 30_000.0; ch = ChStereo): AudioSamples =
  let spec = newAudioSpec(44_100, ch)
  result = newAudioSamples(sfS16, spec, n)
  let nch = ch.channelCount()
  result.s16.renderWith(n, i):
    for p in 0 ..< nch:
      result.s16.planes[p][i] =
        cast[int16]((sin(i.float64 * 0.05 + p.float64) * amp).cint)

proc maxAbsErr(a: AudioSamples; b: openArray[seq[int16]]): int32 =
  ## Max |a - b| with `a` sfS32 MSB-aligned and `b` planar s16.
  for p in 0 ..< b.len:
    for i in 0 ..< b[p].len:
      let d = abs(a.s32.planes[p][i] shr 16 - b[p][i].int32)
      if d > result:
        result = d

proc planesOf(buf: AudioSamples): seq[seq[int16]] =
  for p in 0 ..< buf.s16.planes.len:
    result.add(buf.s16.planes[p])

suite "adpcm encode":
  test "ms mono roundtrip quality":
    let src = sineS16(1_000, 30_000.0, discrete(1))
    let bytes = encodeMsMonoBlock(src.s16.planes[0].toOpenArray(0, 999))
    # 7-byte preamble + 499 data bytes.
    check bytes.len == 7 + 499
    let back = decodeOne(CodecAdpcmMs, 1_000, bytes, discrete(1))
    let err = maxAbsErr(back, planesOf(src))
    echo "ms mono sine maxerr=", err
    check err <= 200
    # Deterministic.
    check encodeMsMonoBlock(src.s16.planes[0].toOpenArray(0, 999)) == bytes

  test "ms stereo roundtrip":
    let src = sineS16(488, 20_000.0)
    let bytes = encodeMsStereoBlock(src.s16.planes[0].toOpenArray(0, 487),
      src.s16.planes[1].toOpenArray(0, 487))
    check bytes.len == 14 + 486
    let back = decodeOne(CodecAdpcmMs, 488, bytes)
    let err = maxAbsErr(back, planesOf(src))
    echo "ms stereo sine maxerr=", err
    check err <= 200

  test "ima-wav mono roundtrip quality":
    let src = sineS16(505, 30_000.0, discrete(1))
    let bytes = encodeImaWavMonoBlock(src.s16.planes[0].toOpenArray(0, 504))
    check bytes.len == 4 + 252
    let back = decodeOne(CodecAdpcmImaWav, 505, bytes, discrete(1))
    let err = maxAbsErr(back, planesOf(src))
    echo "ima wav mono sine maxerr=", err
    check err <= 800
    check encodeImaWavMonoBlock(src.s16.planes[0].toOpenArray(0,
      504)) == bytes

  test "ima-wav stereo roundtrip":
    let src = sineS16(249, 20_000.0)
    let bytes = encodeImaWavStereoBlock(src.s16.planes[0].toOpenArray(0,
      248), src.s16.planes[1].toOpenArray(0, 248))
    check bytes.len == 8 + 248
    let back = decodeOne(CodecAdpcmImaWav, 249, bytes)
    let err = maxAbsErr(back, planesOf(src))
    echo "ima wav stereo sine maxerr=", err
    check err <= 500

  test "ima-qt mono roundtrip":
    let src = sineS16(64, 20_000.0, discrete(1))
    let bytes = encodeImaQtMonoBlock(src.s16.planes[0].toOpenArray(0, 63))
    check bytes.len == 34
    let back = decodeOne(CodecAdpcmImaQt, 64, bytes, discrete(1))
    let err = maxAbsErr(back, planesOf(src))
    echo "ima qt mono sine maxerr=", err
    check err <= 3_000

  test "encode rejects bad block geometry":
    try:
      discard encodeMsMonoBlock(@[1'i16, 2, 3])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard encodeImaWavStereoBlock(@[1'i16, 2, 3, 4, 5],
        @[1'i16, 2, 3, 4, 5])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    try:
      discard encodeImaQtMonoBlock(@[1'i16, 2])
      check false
    except AudioError as e:
      check e.kind == ekDecode

suite "adpcm in wav":
  test "ms container roundtrip":
    let src = sineS16(3_000, 25_000.0)
    let bytes = encodeWav(src, 44_100, CodecAdpcmMs)
    check probeWav(bytes) == 255
    let w = openWav(bytes)
    check w.params.codec == CodecAdpcmMs
    check w.params.framesPerBlock.get == 244
    check w.numFrames().get >= 3_000
    let dec = newAdpcmDecoder(w.params)
    var got = 0
    var errs: seq[int32] = @[]
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        if got + i < 3_000:
          for p in 0 ..< 2:
            errs.add(abs(s.s32.planes[p][i] shr 16 -
              src.s16.planes[p][got + i].int32))
      got += s.framesOf()
    check got >= 3_000
    var worst = 0'i32
    for e in errs:
      worst = max(worst, e)
    echo "ms wav container maxerr=", worst
    check worst <= 300

  test "ima container roundtrip":
    let src = sineS16(2_000, 25_000.0, discrete(1))
    let bytes = encodeWav(src, 44_100, CodecAdpcmImaWav)
    let w = openWav(bytes)
    check w.params.codec == CodecAdpcmImaWav
    check w.params.framesPerBlock.get == 505
    let dec = newAdpcmDecoder(w.params)
    var got = 0
    var worst = 0'i32
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        if got + i < 2_000:
          worst = max(worst, abs(s.s32.planes[0][i] shr 16 -
            src.s16.planes[0][got + i].int32))
      got += s.framesOf()
    check got >= 2_000
    echo "ima wav container maxerr=", worst
    check worst <= 800

  test "adpcm registry":
    registerAdpcm()
    check isDecoderRegistered(CodecAdpcmMs)
    check isDecoderRegistered(CodecAdpcmImaWav)
    check isDecoderRegistered(CodecAdpcmImaQt)
