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

proc noiseStereo(n: int; amp: float; rate = 44_100;
    seed = 0x12345678'u32): AudioSamples =
  ## Deterministic white-noise stereo fixture (LCG, fixed seed): same
  ## samples on every run, independent L/R channels.
  let spec = newAudioSpec(rate.uint32, ChStereo)
  result = newAudioSamples(sfS16, spec, n)
  var s = seed
  result.s16.renderWith(n, i):
    s = s * 1664525'u32 + 1013904223'u32
    let v0 = ((s shr 16) and 0xFFFF'u32).int32 - 32768
    s = s * 1664525'u32 + 1013904223'u32
    let v1 = ((s shr 16) and 0xFFFF'u32).int32 - 32768
    result.s16.planes[0][i] = (v0.float * amp).int16
    result.s16.planes[1][i] = (v1.float * amp).int16

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
    # Infeasible slots fail cleanly at finish time, never as corrupt frames.
    try:
      let e = newMp3EncoderCbr(8, 24_000, MpaMode(kind: mmStereo))
      e.pushSamplesI16(toS16Interleaved(
        sineStereo(1152, 440.0, 660.0, 0.4, 22050)))
      discard e.finishEncoder()
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

suite "mp3 encoder model2":
  test "spreading kernel and tonality units":
    initMpaTables()
    check abs(model2Spread(5.0, 5.0) - 1.0) < 1e-6
    check model2Spread(0.0, 20.0) == 0.0
    check model2Spread(20.0, 0.0) == 0.0
    check model2SpreadTmpyDb(model2SpreadTmpx(4.0, 4.0)) ==
      model2SpreadTmpyDb(0.0)
    check barkOfHz(100.0) < barkOfHz(1000.0)
    check barkOfHz(1000.0) < barkOfHz(10000.0)
    check bandTonality([0.0'f32, 0.0, 0.0, 0.0]) == 0.0
    check bandTonality([1.0'f32, 1.0, 1.0, 1.0]) < 0.1
    check bandTonality([100.0'f32, 0.0, 0.0, 0.0]) > 0.9
  test "model2 thresholds follow signal, silence matches ltq shape":
    initMpaTables()
    var silent: array[576, float32]
    let mSil = model2LongThresholds(silent, 44_100, Mpeg1, -12.0)
    let lt = ltqThresholds(44_100, Mpeg1, 64, -12.0)
    # Silence: no maskers, every band rides the LTq floor, so the
    # normalized Model-2 vector keeps the exact LTq shape.
    for i in 1 ..< 21:
      check abs(mSil[i] / mSil[0] - lt[i] / lt[0]) < 1e-9
    # Loud low masker (sfb 2 = lines 8..12 at 44.1 kHz): the masker
    # band must dramatically exceed its LTq-relative level, proving the
    # thresholds are signal-dependent rather than a rescaled LTq bowl.
    var xr: array[576, float32]
    for k in 8 ..< 12:
      xr[k] = 200.0 + k.float32 * 13.7
    let mM = model2LongThresholds(xr, 44_100, Mpeg1, -12.0)
    check mM[2] / mM[15] > 100.0 * (lt[2] / lt[15])
    var differs = false
    for i in 0 ..< 21:
      if abs(mM[i] / mM[0] - lt[i] / lt[0]) > 1e-6:
        differs = true
    check differs
  test "outer loop steers amplification to the over-threshold band":
    initMpaTables()
    # Synthetic spectrum with energy in bands 2 and 5; only band 2 sees
    # a tight threshold, so only it may be amplified.
    var xr: array[576, float32]
    for k in 8 ..< 12:
      xr[k] = 200.0 + k.float32 * 13.7
    for k in 24 ..< 30:
      xr[k] = 150.0 + k.float32 * 7.3
    var xmin: array[21, float64]
    for i in 0 ..< 21:
      xmin[i] = 1.0e30
    xmin[2] = 0.0
    var ch = defaultGranuleChannel()
    let r = outerLoopSearchLong(xr, ch, 44_100, Mpeg1, 400, xmin)
    check r.ok
    check ch.scalefacs[2] > 0
    for i in 0 ..< 21:
      if i != 2:
        check ch.scalefacs[i] == 0
  test "presets arm model2 except fast":
    initMpaTables()
    check newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo),
      qpTransparent).opts.useModel2
    check newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo),
      qpHigh).opts.useModel2
    check newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo),
      qpStandard).opts.useModel2
    check not newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo),
      qpFast).opts.useModel2
  test "model2 tone fixtures gapless exact, no regression vs ltq":
    initMpaTables()
    for (rate, kbps) in [(44100, 128), (48000, 128), (32000, 128)]:
      for stereo in [false, true]:
        let src =
          if stereo: sineStereo(22_050, 440.0, 660.0, 0.4, rate)
          else: sineMono(22_050, 440.0, 0.5, rate)
        let mode =
          if stereo: MpaMode(kind: mmStereo) else: MpaMode(kind: mmMono)
        let m2 = newMp3EncoderQuality(kbps, rate.uint32, mode, qpHigh)
        m2.enableXingInfo()
        m2.pushSamplesI16(toS16Interleaved(src))
        let gm2 = decodeAll(m2.finishEncoder())
        check gm2[0].len == 22_050
        let pm2 = psnrOf(src, gm2)
        check pm2 > 20.0
        let lt = newMp3EncoderLtq(kbps, rate.uint32, mode, -12.0)
        lt.enableXingInfo()
        lt.pushSamplesI16(toS16Interleaved(src))
        let glt = decodeAll(lt.finishEncoder())
        check glt[0].len == 22_050
        check pm2 >= psnrOf(src, glt) - 3.0
  test "model2 noise fixture within tolerance":
    initMpaTables()
    let src = noiseStereo(22_050, 0.4)
    let m2 = newMp3EncoderQuality(128, 44_100, MpaMode(kind: mmStereo),
      qpHigh)
    m2.enableXingInfo()
    m2.pushSamplesI16(toS16Interleaved(src))
    let gm2 = decodeAll(m2.finishEncoder())
    check gm2[0].len == 22_050
    let pm2 = psnrOf(src, gm2)
    check pm2 > 8.0
    let lt = newMp3EncoderLtq(128, 44_100, MpaMode(kind: mmStereo), -12.0)
    lt.enableXingInfo()
    lt.pushSamplesI16(toS16Interleaved(src))
    let plt = psnrOf(src, decodeAll(lt.finishEncoder()))
    check pm2 >= plt - 4.0
  test "model2 lsf, short blocks and manual arming":
    initMpaTables()
    let e = newMp3EncoderOuterLoop(128, 44_100, MpaMode(kind: mmStereo))
    check not e.opts.useModel2
    e.enableModel2()
    check e.opts.useModel2
    check e.opts.useOuterLoop
    e.enableXingInfo()
    let src = sineStereo(22_050, 440.0, 660.0, 0.4)
    e.pushSamplesI16(toS16Interleaved(src))
    let got = decodeAll(e.finishEncoder())
    check got[0].len == 22_050
    check psnrOf(src, got) > 20.0
    var os = gaplessOpts(128, 44_100, MpaMode(kind: mmStereo))
    os.useOuterLoop = true
    os.useModel2 = true
    os.forceShort = true
    let gs = decodeAll(encodeMp3Stream(src, os))
    check gs[0].len == 22_050
    check psnrOf(src, gs) > 15.0
    let srcLsf = sineStereo(11_025, 440.0, 660.0, 0.4, 22050)
    let m2lsf = newMp3EncoderQuality(64, 22_050, MpaMode(kind: mmStereo),
      qpHigh)
    m2lsf.enableXingInfo()
    m2lsf.pushSamplesI16(toS16Interleaved(srcLsf))
    let glsf = decodeAll(m2lsf.finishEncoder())
    check glsf[0].len == 11_025
    check psnrOf(srcLsf, glsf) > 15.0
