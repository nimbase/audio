import std/math
import std/options
import unittest

import audio/audio
import audio/codecs
import audio/codecs/mpa
import audio/codecs/mpaenc
import audio/errors
import audio/formats
import audio/formats/mpa as mpafmt
import audio/io
import audio/packet
import audio/units

proc sineMono(n: int; f, amp: float; rate: int): AudioSamples =
  let spec = newAudioSpec(rate.uint32, positioned(PosFrontCenter))
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    result.s16.planes[0][i] = (amp * 32767.0 *
      sin(2.0 * PI * f * i.float / rate.float)).int16

proc sineStereo(n: int; fL, fR, amp: float;
    rate = 44_100): AudioSamples =
  let spec = newAudioSpec(rate.uint32, ChStereo)
  result = newAudioSamples(sfS16, spec, n)
  result.s16.renderWith(n, i):
    result.s16.planes[0][i] = (amp * 32767.0 *
      sin(2.0 * PI * fL * i.float / rate.float)).int16
    result.s16.planes[1][i] = (amp * 32767.0 *
      sin(2.0 * PI * fR * i.float / rate.float)).int16

proc decodeAll(bytes: seq[uint8]): seq[seq[float32]] =
  let w = mpafmt.openMpa(bytes)
  let dec = newMpaDecoder(w.tracks[0].codec,
    AudioDecoderOptions(gapless: true, verify: false))
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  while true:
    let pkt = w.nextPacket()
    if pkt.isNone:
      break
    let s = dec.decodePacket(pkt.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc psnrOf(src: AudioSamples; got: seq[seq[float32]]): float64 =
  let n = src.framesOf()
  let nch = src.specOf().channels.channelCount()
  var se = 0.0
  for p in 0 ..< nch:
    for i in 0 ..< min(n, got[p].len):
      let a =
        case src.format
        of sfS16: src.s16.planes[p][i].float / 32768.0
        else: 0.0
      let d = got[p][i].float - a
      se += d * d
  10.0 * log10(1.0 / max(se / (n * nch).float, 1e-18))

proc gaplessOpts(bitrateKbps: int; rate: uint32;
    mode: MpaMode): Mp3EncoderOptions =
  result = defaultMp3EncoderOptions(bitrateKbps, rate, mode)
  result.xing = true
  result.gapless = true

suite "mp3 encoder framing":
  test "header writer is parse inverse":
    let h = makeSilentHeader(128, 44_100, MpaMode(kind: mmStereo))
    let hb = writeMp3Header(h)
    var word = (hb[0].uint32 shl 24) or (hb[1].uint32 shl 16) or
      (hb[2].uint32 shl 8) or hb[3].uint32
    let p = parseFrameHeader(word)
    check p.bitrate == 128000
    check p.sampleRate == 44_100
    check p.layer == Layer3
    check p.channelMode.kind == mmStereo
    check not p.hasCrc
  test "header writer covers lsf and mpeg25":
    for (rate, kbps) in [(22050'u32, 64), (16000'u32, 48),
        (12000'u32, 32), (11025'u32, 32), (8000'u32, 24)]:
      let h = makeSilentHeader(kbps.uint32, rate, MpaMode(kind: mmMono))
      let hb = writeMp3Header(h)
      var word = (hb[0].uint32 shl 24) or (hb[1].uint32 shl 16) or
        (hb[2].uint32 shl 8) or hb[3].uint32
      let p = parseFrameHeader(word)
      check p.sampleRate == rate
      check p.bitrate == kbps.uint32 * 1000
  test "silent frame decodes to silence":
    initMpaTables()
    let h = makeSilentHeader(128, 44_100, MpaMode(kind: mmStereo))
    let fr = encodeSilentFrame(h)
    check fr.len == 4 + h.frameSize
    let w = mpafmt.openMpa(fr)
    check w.packets.len == 1
    let dec = newMpaDecoder(w.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    let s = dec.decodePacket(w.nextPacket().get)
    for p in 0 ..< 2:
      for i in 0 ..< s.framesOf():
        check s.f32.planes[p][i] == 0.0
  test "silent header rejects off-ladder config":
    try:
      discard makeSilentHeader(123, 44_100, MpaMode(kind: mmStereo))
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    try:
      discard makeSilentHeader(128, 44_101, MpaMode(kind: mmStereo))
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "mp3 encoder mpeg1":
  test "mono cbr gapless exact, deterministic":
    initMpaTables()
    let src = sineMono(44_100, 440.0, 0.5, 44_100)
    let o = gaplessOpts(128, 44_100, MpaMode(kind: mmMono))
    let a = encodeMp3Stream(src, o)
    let b = encodeMp3Stream(src, o)
    check a == b
    let got = decodeAll(a)
    check got[0].len == 44_100
    check psnrOf(src, got) > 20.0
  test "stereo cbr gapless exact":
    initMpaTables()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    let o = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    let got = decodeAll(encodeMp3Stream(src, o))
    check got[0].len == 22_050
    check psnrOf(src, got) > 20.0
  test "dual channel encodes":
    initMpaTables()
    let src = sineStereo(11_520, 440.0, 660.0, 0.4)
    let o = gaplessOpts(192, 44_100, MpaMode(kind: mmDualMono))
    let got = decodeAll(encodeMp3Stream(src, o))
    check got[0].len == 11_520
    check psnrOf(src, got) > 15.0
  test "joint ms and auto":
    initMpaTables()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    let e2 = newMp3EncoderJointMs(128, 44_100)
    e2.enableXingInfo()
    e2.pushSamplesI16(toS16Interleaved(src))
    let g2 = decodeAll(e2.finishEncoder())
    check g2[0].len == 22_050
    check psnrOf(src, g2) > 20.0
    let e3 = newMp3EncoderJointAuto(128, 44_100)
    e3.enableXingInfo()
    e3.pushSamplesI16(toS16Interleaved(src))
    let g3 = decodeAll(e3.finishEncoder())
    check g3[0].len == 22_050
    check psnrOf(src, g3) > 20.0
  test "outer loop, ltq and quality preset":
    initMpaTables()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    let eo = newMp3EncoderOuterLoop(128, 44_100,
      MpaMode(kind: mmStereo))
    eo.enableXingInfo()
    eo.pushSamplesI16(toS16Interleaved(src))
    let go = decodeAll(eo.finishEncoder())
    check go[0].len == 22_050
    check psnrOf(src, go) > 15.0
    let el = newMp3EncoderLtq(128, 44_100, MpaMode(kind: mmStereo))
    el.enableXingInfo()
    el.pushSamplesI16(toS16Interleaved(src))
    let gl = decodeAll(el.finishEncoder())
    check gl[0].len == 22_050
    check psnrOf(src, gl) > 15.0
    let eq = newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo),
      qpHigh)
    eq.enableXingInfo()
    eq.pushSamplesI16(toS16Interleaved(src))
    let gq = decodeAll(eq.finishEncoder())
    check gq[0].len == 22_050
    check psnrOf(src, gq) > 15.0
  test "short, mixed and auto block types":
    initMpaTables()
    let src = sineStereo(11_520, 440.0, 660.0, 0.4)
    var o5 = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    o5.forceShort = true
    let g5 = decodeAll(encodeMp3Stream(src, o5))
    check g5[0].len == 11_520
    check psnrOf(src, g5) > 15.0
    var o7 = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    o7.forceMixed = true
    let g7 = decodeAll(encodeMp3Stream(src, o7))
    check g7[0].len == 11_520
    check psnrOf(src, g7) > 15.0
    var o6 = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    let e6 = newMp3Encoder(o6)
    e6.enableAutoBlockType()
    e6.enableXingInfo()
    e6.pushSamplesI16(toS16Interleaved(src))
    let g6 = decodeAll(e6.finishEncoder())
    check g6[0].len == 11_520
    check psnrOf(src, g6) > 15.0
  test "transient triggers short blocks and stays clean":
    initMpaTables()
    let n = 11_520
    let spec = newAudioSpec(44_100, ChStereo)
    var src = newAudioSamples(sfS16, spec, n)
    src.s16.renderWith(n, i):
      let env = if i mod 2880 < 8: 1.0 else: 0.05
      src.s16.planes[0][i] = (env * 20000.0 *
        sin(2.0 * PI * 440.0 * i.float / 44100.0)).int16
      src.s16.planes[1][i] = (env * 20000.0 *
        sin(2.0 * PI * 660.0 * i.float / 44100.0)).int16
    var o = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    let e = newMp3Encoder(o)
    e.enableAutoBlockType()
    e.enableXingInfo()
    e.pushSamplesI16(toS16Interleaved(src))
    let got = decodeAll(e.finishEncoder())
    check got[0].len == n
    check psnrOf(src, got) > 10.0
  test "32k and 48k rates":
    initMpaTables()
    for rate in [32_000, 48_000]:
      let src = sineMono(rate, 440.0, 0.4, rate)
      let o = gaplessOpts(128, rate.uint32, MpaMode(kind: mmMono))
      let got = decodeAll(encodeMp3Stream(src, o))
      check got[0].len == rate
      check psnrOf(src, got) > 20.0

suite "mp3 encoder lsf":
  test "all lsf rates gapless exact":
    initMpaTables()
    for (rate, kbps) in [(22050, 64), (24000, 64), (16000, 48),
        (12000, 32), (11025, 32), (8000, 24)]:
      let src = sineMono(rate, 440.0, 0.4, rate)
      let o = gaplessOpts(kbps, rate.uint32, MpaMode(kind: mmMono))
      let got = decodeAll(encodeMp3Stream(src, o))
      check got[0].len == rate
      check psnrOf(src, got) > 15.0
  test "lsf stereo joint auto":
    initMpaTables()
    let src = sineStereo(11_025, 440.0, 660.0, 0.4, 22050)
    let e = newMp3EncoderJointAuto(64, 22_050)
    e.enableXingInfo()
    e.pushSamplesI16(toS16Interleaved(src))
    let got = decodeAll(e.finishEncoder())
    check got[0].len == 11_025
    check psnrOf(src, got) > 15.0

suite "mp3 encoder vbr/crc/xing":
  test "vbr stereo gapless exact":
    initMpaTables()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    var ov = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    ov.vbr = true
    ov.vbrMinKbps = 96
    ov.vbrMaxKbps = 192
    let got = decodeAll(encodeMp3Stream(src, ov))
    check got[0].len == 22_050
    check psnrOf(src, got) > 20.0
  test "crc protected frames decode":
    initMpaTables()
    let src = sineMono(11_520, 440.0, 0.4, 44_100)
    var o = gaplessOpts(128, 44_100, MpaMode(kind: mmMono))
    o.crc = true
    let got = decodeAll(encodeMp3Stream(src, o))
    check got[0].len == 11_520
    check psnrOf(src, got) > 20.0
  test "no-xing stream decodes untrimmed":
    initMpaTables()
    let src = sineMono(11_520, 440.0, 0.4, 44_100)
    let o = defaultMp3EncoderOptions(128, 44_100,
      MpaMode(kind: mmMono))
    let bytes = encodeMp3Stream(src, o)
    let w = mpafmt.openMpa(bytes)
    check w.packets.len * 1152 >= 11_520
  test "error cases":
    initMpaTables()
    try:
      discard newMp3EncoderJointMs(123, 44_100)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    var bad = defaultMp3EncoderOptions(128, 44_100,
      MpaMode(kind: mmMono))
    bad.vbr = true
    bad.vbrMinKbps = 192
    bad.vbrMaxKbps = 96
    try:
      discard newMp3Encoder(bad)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    var oi = defaultMp3EncoderOptions(128, 44_100,
      MpaMode(kind: mmStereo))
    oi.intensityStart = 5
    try:
      discard newMp3Encoder(oi)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported
    var oi2 = defaultMp3EncoderOptions(128, 44_100,
      MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
    oi2.intensityStart = 21
    try:
      discard newMp3Encoder(oi2)
      check false
    except AudioError as e:
      check e.kind == ekUnsupported

suite "mp3 encoder intensity":
  test "is-only, ms+is and auto+is gapless exact":
    initMpaTables()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    for (name, enc) in [("is", newMp3EncoderJointIs(128, 44_100, 8)),
        ("ms+is", newMp3EncoderJointMsIs(128, 44_100, 8)),
        ("auto+is",
          newMp3EncoderJointAutoIs(128, 44_100, 8))]:
      enc.enableXingInfo()
      enc.pushSamplesI16(toS16Interleaved(src))
      let bytes = enc.finishEncoder()
      let got = decodeAll(bytes)
      check got[0].len == 22_050
      check psnrOf(src, got) > 20.0
      # Mode extension must carry the intensity bit on every audio frame.
      var nInt = 0
      var nTot = 0
      var off = 0
      while off + 4 <= bytes.len:
        if bytes[off] == 0xFF'u8 and (bytes[off + 1] and 0xE0'u8) == 0xE0'u8:
          let word = (bytes[off].uint32 shl 24) or
            (bytes[off + 1].uint32 shl 16) or (bytes[off + 2].uint32 shl 8) or
            bytes[off + 3].uint32
          try:
            let h = parseFrameHeader(word)
            if h.layer == Layer3 and h.frameSize >= 0:
              if h.channelMode.kind == mmJoint:
                inc nTot
                if h.channelMode.intensity:
                  inc nInt
              off += 4 + h.frameSize
              continue
          except AudioError:
            discard
        inc off
      check nTot > 0
      check nInt == nTot
      discard name
  test "intensity all rates gapless exact":
    initMpaTables()
    for (rate, kbps) in [(44100, 128), (48000, 128), (32000, 128),
        (22050, 64), (24000, 64), (16000, 48), (12000, 32),
        (11025, 32), (8000, 24)]:
      let src = sineStereo(11_520, 440.0, 660.0, 0.4, rate)
      var o = gaplessOpts(kbps, rate.uint32,
        MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
      o.intensityStart = 8
      let got = decodeAll(encodeMp3Stream(src, o))
      check got[0].len == 11_520
      check psnrOf(src, got) > 15.0
  test "intensity short and mixed gapless exact":
    initMpaTables()
    let src = sineStereo(11_520, 440.0, 660.0, 0.4)
    var os = gaplessOpts(128, 44_100,
      MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
    os.intensityStart = 8
    os.forceShort = true
    let gs = decodeAll(encodeMp3Stream(src, os))
    check gs[0].len == 11_520
    check psnrOf(src, gs) > 15.0
    var om = gaplessOpts(128, 44_100,
      MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
    om.intensityStart = 8
    om.forceMixed = true
    let gm = decodeAll(encodeMp3Stream(src, om))
    check gm[0].len == 11_520
    check psnrOf(src, gm) > 15.0
  test "intensity lsf, vbr and crc":
    initMpaTables()
    let src = sineStereo(11_025, 440.0, 660.0, 0.4, 22050)
    let e = newMp3EncoderJointIs(64, 22_050, 8)
    e.enableXingInfo()
    e.pushSamplesI16(toS16Interleaved(src))
    let got = decodeAll(e.finishEncoder())
    check got[0].len == 11_025
    check psnrOf(src, got) > 15.0
    let src2 = sineStereo(22_050, 440.0, 660.0, 0.4)
    var ov = gaplessOpts(128, 44_100,
      MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
    ov.intensityStart = 8
    ov.vbr = true
    ov.vbrMinKbps = 96
    ov.vbrMaxKbps = 192
    let gv = decodeAll(encodeMp3Stream(src2, ov))
    check gv[0].len == 22_050
    check psnrOf(src2, gv) > 15.0
    var oc = gaplessOpts(128, 44_100,
      MpaMode(kind: mmJoint, midSide: true, intensity: true, bound: 0))
    oc.intensityStart = 8
    oc.jointMs = true
    oc.crc = true
    let gc = decodeAll(encodeMp3Stream(src2, oc))
    check gc[0].len == 22_050
    check psnrOf(src2, gc) > 15.0
  test "intensity outer loop short/mixed gapless exact":
    initMpaTables()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    for (forceS, forceM) in [(false, false), (true, false), (false, true)]:
      var o = gaplessOpts(128, 44_100,
        MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0))
      o.intensityStart = 8
      o.useOuterLoop = true
      o.forceShort = forceS
      o.forceMixed = forceM
      let got = decodeAll(encodeMp3Stream(src, o))
      check got[0].len == 22_050
      check psnrOf(src, got) > 15.0
