import std/options
import unittest

import audio/codecs
import audio/codecs/pcm
import audio/audio
import audio/formats
import audio/formats/wav
import audio/packet
import audio/units
import audio/errors
import audio/io
import audio/metadata

proc rampS16(n: int; ch = ChStereo; rate = 44_100'u32): AudioSamples =
  let spec = newAudioSpec(rate, ch)
  result = newAudioSamples(sfS16, spec, n)
  let nch = ch.channelCount()
  result.s16.renderWith(n, i):
    for p in 0 ..< nch:
      result.s16.planes[p][i] = cast[int16]((i * 257 + p * 7919) mod 65536 -
        32768)

proc collectAll(w: WavReader; dec: PcmDecoder): AudioSamples =
  ## Decodes every packet and concatenates frames.
  var frames = 0
  var first = true
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    if first:
      result = newAudioSamples(s.format, s.specOf(), 0)
      first = false
    case s.format
    of sfS16:
      result.s16.growCapacity(frames + s.framesOf())
      for p in 0 ..< s.s16.planes.len:
        for i in 0 ..< s.framesOf():
          result.s16.planes[p][frames + i] = s.s16.planes[p][i]
      result.s16.numFrames = frames + s.framesOf()
    else:
      raise unsupportedError("test helper only handles s16")
    frames += s.framesOf()

suite "wav roundtrip":
  test "s16 stereo container roundtrip is sample-exact":
    let src = rampS16(5_000)
    let bytes = encodeWav(src, 44_100)
    check probeWav(bytes) == 255
    let w = openWav(bytes)
    check w.trackCount() == 1
    check w.params.codec == CodecPcmS16Le
    check w.params.sampleRate.get == 44_100
    check w.params.channels.get.channelCount() == 2
    check w.numFrames().get == 5_000
    let dec = newPcmDecoder(w.params)
    let back = collectAll(w, dec)
    check back.framesOf() == 5_000
    for i in 0 ..< 5_000:
      check back.s16.planes[0][i] == src.s16.planes[0][i]
      check back.s16.planes[1][i] == src.s16.planes[1][i]

  test "f32 mono and u8 mono roundtrip":
    let spec = newAudioSpec(48_000, discrete(1))
    var f = newAudioSamples(sfF32, spec, 64)
    f.f32.renderWith(64, i):
      f.f32.planes[0][i] = i.float32 / 64.0 - 0.5
    let fb = encodeWav(f, 48_000)
    let wf = openWav(fb)
    check wf.params.codec == CodecPcmF32Le
    check wf.numFrames().get == 64
    var pkt = wf.nextPacket().get
    let fdec = newPcmDecoder(wf.params)
    let fs = fdec.decodePacket(pkt)
    for i in 0 ..< 64:
      check fs.f32.planes[0][i] == f.f32.planes[0][i]
    var u = newAudioSamples(sfU8, spec, 64)
    u.u8.renderWith(64, i):
      u.u8.planes[0][i] = cast[uint8](i * 4)
    let ub = encodeWav(u, 48_000)
    let wu = openWav(ub)
    check wu.params.codec == CodecPcmU8
    let udec = newPcmDecoder(wu.params)
    let us = udec.decodePacket(wu.nextPacket().get)
    for i in 0 ..< 64:
      check us.u8.planes[0][i] == u.u8.planes[0][i]

  test "six channels use extensible":
    let spec = newAudioSpec(48_000, discrete(6))
    var buf = newAudioSamples(sfS16, spec, 16)
    buf.s16.renderWith(16, i):
      for p in 0 ..< 6:
        buf.s16.planes[p][i] = cast[int16](i + p * 100)
    let bytes = encodeWav(buf, 48_000)
    let w = openWav(bytes)
    check w.params.codec == CodecPcmS16Le
    check w.params.channels.get.channelCount() == 6
    check w.numFrames().get == 16
    let dec = newPcmDecoder(w.params)
    var got = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for i in 0 ..< s.framesOf():
        for p in 0 ..< 6:
          check s.s16.planes[p][i] == buf.s16.planes[p][got + i]
      got += s.framesOf()
    check got == 16

  test "alaw and mulaw containers roundtrip all representatives":
    for codec in [CodecPcmALaw, CodecPcmMuLaw]:
      let toLin =
        if codec == CodecPcmALaw: alawToLinear else: mulawToLinear
      let spec = newAudioSpec(8_000, discrete(1))
      var src = newAudioSamples(sfS16, spec, 256)
      src.s16.renderWith(256, i):
        src.s16.planes[0][i] = toLin(cast[uint8](i))
      let bytes = encodeWav(src, 8_000, codec)
      let w = openWav(bytes)
      check w.params.codec == codec
      check w.numFrames().get == 256
      let dec = newPcmDecoder(w.params)
      let back = collectAll(w, dec)
      check back.framesOf() == 256
      for i in 0 ..< 256:
        check back.s16.planes[0][i] == src.s16.planes[0][i]

  test "fact chunk and media info":
    let src = rampS16(100, discrete(1))
    let bytes = encodeWav(src, 22_050, CodecPcmMuLaw)
    let w = openWav(bytes)
    check w.numFrames().get == 100
    check w.params.codec == CodecPcmMuLaw
    let mi = w.mediaInfo()
    check mi.timeBase.get.denom == 22_050
    check mi.duration.get.ticks == 100

suite "wav packets and seek":
  test "packet pts advance by 1152":
    let src = rampS16(3_000)
    let w = openWav(encodeWav(src, 44_100))
    var pts: seq[int64] = @[]
    var total = 0'u64
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      pts.add(pkt.get.pts.get)
      total += pkt.get.dur.get
    check pts == @[0'i64, 1152, 2304]
    check total == 3_000
    check w.nextPacket().isNone

  test "seek aligns to packet boundary":
    let src = rampS16(5_000)
    let w = openWav(encodeWav(src, 44_100))
    let s = w.seek(seekToTimestamp(newTimestamp(2_000), 0))
    check s.requiredTs.get == 2_000
    check s.actualTs.get == 1_152
    let pkt = w.nextPacket().get
    check pkt.pts.get == 1_152
    # Seek to time: 100ms at 44100Hz = 4410 ticks -> 3456 aligned.
    discard w.seek(seekToTime(fromMillis(100)))
    check w.nextPacket().get.pts.get == 3_456
    try:
      discard w.seek(seekToTimestamp(newTimestamp(-5), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek
    try:
      discard w.seek(seekToTimestamp(newTimestamp(9_999_999), 0))
      check false
    except AudioError as e:
      check e.kind == ekSeek
      check e.seekKind == skOutOfRange

suite "wav malformed":
  test "bad markers and truncation":
    # RIFF with a non-WAVE form is unsupported (not malformed).
    try:
      discard openWav(@[0x52'u8, 0x49, 0x46, 0x46, 0x04, 0x00, 0x00, 0x00,
        0x58, 0x58, 0x58, 0x58])
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    # A riff length below the 4-byte form tag is malformed.
    try:
      discard openWav(@[0x52'u8, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45])
      check false
    except AudioError as e:
      check e.kind == ekDecode
    let good = encodeWav(rampS16(64, discrete(1)), 44_100)
    try:
      discard openWav(good[0 ..< 20])
      check false
    except AudioError:
      check true
    # Missing data chunk.
    var w = newWriter()
    w.writeFourCc([0x52'u8, 0x49, 0x46, 0x46])
    w.writeU32Le(4 + 8 + 16)
    w.writeFourCc([0x57'u8, 0x41, 0x56, 0x45])
    w.writeFourCc([0x66'u8, 0x6d, 0x74, 0x20])
    w.writeU32Le(16)
    w.writeU16Le(1)
    w.writeU16Le(1)
    w.writeU32Le(44_100)
    w.writeU32Le(88_200)
    w.writeU16Le(2)
    w.writeU16Le(16)
    try:
      discard openWav(w.toBytes())
      check false
    except AudioError as e:
      check e.kind == ekUnsupported or e.kind == ekDecode

  test "info chunk parses":
    var w = newWriter()
    w.writeFourCc([0x52'u8, 0x49, 0x46, 0x46])
    let sizeAt = w.len
    w.writeU32Le(0)
    w.writeFourCc([0x57'u8, 0x41, 0x56, 0x45])
    w.writeFourCc([0x66'u8, 0x6d, 0x74, 0x20])
    w.writeU32Le(16)
    w.writeU16Le(1)
    w.writeU16Le(1)
    w.writeU32Le(8_000)
    w.writeU32Le(16_000)
    w.writeU16Le(2)
    w.writeU16Le(16)
    # LIST INFO with INAM "hi" + IART "me".
    w.writeFourCc([0x4c'u8, 0x49, 0x53, 0x54])
    w.writeU32Le(4 + 10 + 10)
    w.writeFourCc([0x49'u8, 0x4e, 0x46, 0x4f])
    w.writeFourCc([0x49'u8, 0x4e, 0x41, 0x4d])
    w.writeU32Le(2)
    w.writeBytes([0x68'u8, 0x69])
    w.writeFourCc([0x49'u8, 0x41, 0x52, 0x54])
    w.writeU32Le(2)
    w.writeBytes([0x6d'u8, 0x65])
    w.writeFourCc([0x64'u8, 0x61, 0x74, 0x61])
    w.writeU32Le(4)
    w.writeBytes([0x00'u8, 0x00, 0x00, 0x00])
    w.patchU32Le(sizeAt, (w.len - 8).uint32)
    let r = openWav(w.toBytes())
    check r.metadata.revisions.len == 1
    let tags = r.metadata.revisions[0].tags
    check tags.len == 2
    check tags[0].key == "INAM"
    check tags[0].stdKey.get == "track_title"
    check tags[0].value.str == "hi"
    check tags[1].value.str == "me"
    check r.numFrames().get == 2
