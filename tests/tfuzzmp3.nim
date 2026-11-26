## MP3 encoder/decoder fuzz harness (deterministic corpus, fixed seed).
##
## Covers the enlarged encoder surface: frame headers, side info,
## Huffman emit/count agreement, reservoir scheduling, hostile encoder
## configs (bitrate/mode/block/intensity/VBR/Xing/CRC/model-2), hostile
## PCM (NaN/Inf/huge/DC/empty), and hostile demuxer bytes.
##
## Gate: only `AudioError` may escape; any other exception (Defect,
## IndexError, assertion, ...) fails the test. Encoder success paths
## must additionally frame-walk and self-decode.

import std/math
import std/options
import unittest

import audio/audio
import audio/codecs
import audio/codecs/mpa
import audio/codecs/mpa_tables
import audio/codecs/mpaenc
import audio/errors
import audio/formats
import audio/formats/mpa as mpafmt
import audio/io
import audio/packet
import audio/units

var fuzzSeed = 0x9E3779B9'u32

proc frnd(): uint32 =
  fuzzSeed = fuzzSeed * 1664525'u32 + 1013904223'u32
  fuzzSeed

proc frange(n: int): int =
  ## Uniform in 0..<n (n > 0).
  if n <= 1:
    return 0
  ((frnd() shr 16) mod n.uint32).int

template expectAudioOnly(ctx: string; body: untyped) =
  ## Runs body; AudioError is the only acceptable escape.
  try:
    body
  except AudioError:
    discard
  except Exception as ex:
    checkpoint(ctx & " :: unexpected " & $ex.name & ": " & ex.msg)
    fail()

proc fuzzModes(): seq[MpaMode] =
  @[MpaMode(kind: mmStereo), MpaMode(kind: mmDualMono),
    MpaMode(kind: mmMono),
    MpaMode(kind: mmJoint, midSide: false, intensity: false, bound: 0),
    MpaMode(kind: mmJoint, midSide: true, intensity: false, bound: 0),
    MpaMode(kind: mmJoint, midSide: false, intensity: true, bound: 0),
    MpaMode(kind: mmJoint, midSide: true, intensity: true, bound: 0)]

suite "fuzz mp3 headers":
  test "hostile header words never panic, valid ones roundtrip":
    initMpaTables()
    for i in 0 ..< 400:
      let word =
        if i < 64:
          # Targeted edges: sync + version/layer/mode corners.
          let v = [0xFFE00000'u32, 0xFFF00000'u32, 0xFFE20000'u32,
            0xFFFB9000'u32, 0xFFF3C000'u32][i mod 5]
          v or (frnd() and 0x0000FFFF'u32)
        else:
          frnd()
      var h: FrameHeader
      var ok = false
      expectAudioOnly("parseFrameHeader word=" & $word):
        h = parseFrameHeader(word)
        ok = true
      if ok:
        expectAudioOnly("reparse header word=" & $word):
          let hb = writeMp3Header(h)
          let w2 = (hb[0].uint32 shl 24) or (hb[1].uint32 shl 16) or
            (hb[2].uint32 shl 8) or hb[3].uint32
          let p = parseFrameHeader(w2)
          check p.version == h.version
          check p.layer == Layer3 # writer is Layer-III-only by design
          check p.sampleRate == h.sampleRate
          check p.channelMode.kind == h.channelMode.kind
          check p.hasCrc == h.hasCrc
          # Bitrate survives iff it sits on the Layer III ladder.
          let ladder =
            if h.version == Mpeg1: MpaEncV1L3Ladder
            else: MpaEncV2L23Ladder
          var onLadder = false
          for i in 1 ..< 15:
            if ladder[i].uint32 == h.bitrate:
              onLadder = true
              break
          if onLadder:
            check p.bitrate == h.bitrate
  test "ladder headers roundtrip, off-ladder raises cleanly":
    initMpaTables()
    const rates = [44_100'u32, 48_000, 32_000, 22_050, 24_000, 16_000,
      11_025, 12_000, 8_000]
    for rate in rates:
      for bi in 1 ..< 15:
        let ladder =
          if rate in [44_100'u32, 48_000, 32_000]: MpaEncV1L3Ladder
          else: MpaEncV2L23Ladder
        let kbps = (ladder[bi] div 1000).uint32
        for mode in fuzzModes():
          expectAudioOnly("ladder roundtrip"):
            let h = makeSilentHeader(kbps, rate, mode)
            let hb = writeMp3Header(h)
            let w = (hb[0].uint32 shl 24) or (hb[1].uint32 shl 16) or
              (hb[2].uint32 shl 8) or hb[3].uint32
            let p = parseFrameHeader(w)
            check p.bitrate == h.bitrate
            check p.sampleRate == rate
            check p.channelMode.kind == mode.kind
    for (kbps, rate) in [(0'u32, 44_100'u32), (123'u32, 44_100'u32),
        (1000'u32, 44_100'u32), (128'u32, 44_101'u32),
        (128'u32, 0'u32)]:
      var raised = false
      try:
        discard makeSilentHeader(kbps, rate, MpaMode(kind: mmStereo))
      except AudioError:
        raised = true
      except Exception as ex:
        checkpoint("off-ladder raised " & $ex.name)
        fail()
      check raised

suite "fuzz mp3 side info":
  test "hostile granule channels never panic, parse accepts own output":
    initMpaTables()
    const rates = [44_100'u32, 22_050, 8_000]
    for i in 0 ..< 300:
      let rate = rates[i mod 3]
      let lsf = rate != 44_100'u32
      let mode = fuzzModes()[frange(fuzzModes().len)]
      let h = FrameHeader(version: (if lsf: Mpeg2 else: Mpeg1),
        layer: Layer3, bitrate: 128000, sampleRate: rate,
        sampleRateIdx: sampleRateIdxOf(rate), channelMode: mode,
        hasCrc: false, frameSize: 417)
      var si = FrameData(mainDataBegin: frange(1024))
      for ch in 0 ..< 2:
        for b in 0 ..< 4:
          si.scfsi[ch][b] = frange(2) == 1
      for gr in 0 ..< 2:
        for ch in 0 ..< 2:
          var g = defaultGranuleChannel()
          g.part23Len = frange(8192)
          g.bigValues = frange(512)
          g.globalGain = frange(256)
          g.scalefacCompress = frange(1024)
          let bt = frange(4)
          case bt
          of 0: g.blockType = BlockType(kind: btLong)
          of 1: g.blockType = BlockType(kind: btStart)
          of 2:
            g.blockType = BlockType(kind: btShort,
              mixed: frange(2) == 1)
          else: g.blockType = BlockType(kind: btEnd)
          for t in 0 ..< 3:
            g.tableSelect[t] = frange(32)
            g.subblockGain[t] = frange(8)
          g.region1Start = frange(577)
          g.region2Start = frange(577)
          g.preflag = frange(2) == 1
          g.scalefacScale = frange(2) == 1
          g.count1Select = frange(2)
          for s in 0 ..< 39:
            g.scalefacs[s] = frange(256)
          g.rzero = frange(577)
          si.granules[gr][ch] = g
      var bytes: seq[uint8] = @[]
      var wrote = false
      expectAudioOnly("writeSideInfo"):
        bytes = writeSideInfo(si, h)
        wrote = true
      if wrote:
        expectAudioOnly("readSideInfo own output"):
          var bs = newLtrBitReader(bytes)
          var back = FrameData()
          discard readSideInfo(bs, h, back)

suite "fuzz huffman emit/count":
  test "emit length always equals counted length on hostile spectra":
    initMpaTables()
    const alphabet = [0'i32, 0, 0, 0, 1, -1, 1, -1, 2, -2, 3, -3, 14,
      -14, 15, -15, 16, -16, 100, -100, 1000, -1000, 8191, -8191]
    for i in 0 ..< 250:
      var q: array[576, int32]
      let kind = i mod 6
      case kind
      of 0:
        for k in 0 ..< 576:
          q[k] = alphabet[frange(alphabet.len)]
      of 1:
        discard # all zeros
      of 2:
        for k in 0 ..< 576:
          q[k] = if frange(2) == 0: 1 else: -1
      of 3:
        for k in frange(576) ..< 576:
          q[k] = alphabet[frange(alphabet.len)]
      of 4:
        for k in 0 ..< frange(577):
          q[k] = if frange(3) == 0: 8191'i32 else: 1
      else:
        for k in 0 ..< 576:
          q[k] = if k mod 7 == 0: -8191'i32 else: 0
      var bt = BlockType(kind: btLong)
      var mixed = false
      case i mod 5
      of 1:
        bt = BlockType(kind: btShort, mixed: false)
      of 2:
        bt = BlockType(kind: btShort, mixed: true)
        mixed = true
      of 3: bt = BlockType(kind: btStart)
      of 4: bt = BlockType(kind: btEnd)
      else: discard
      expectAudioOnly("huffman case " & $i):
        var ch = defaultGranuleChannel()
        ch.blockType = bt
        let (bigPairs, quads) = partitionSplit(q)
        let (r0, r1) = regionEndsFor(ch, bigPairs, 44_100, Mpeg1)
        var tabs = [0, 0, 0]
        let ends = [r0, r1, bigPairs * 2]
        var s = 0
        for ri in 0 ..< 3:
          var sel = 23
          let t = chooseBestTableForRegion(q, s, ends[ri])
          if t.isSome:
            sel = t.get.sel
          elif s < ends[ri]:
            # Uncodable region (beyond table reach): skip emit check.
            s = ends[ri]
            tabs[ri] = -1
            continue
          tabs[ri] = sel
          s = ends[ri]
        if tabs[0] >= 0 and tabs[1] >= 0 and tabs[2] >= 0:
          let (useB, _) = chooseBestCount1Table(q, bigPairs * 2,
            bigPairs * 2 + quads * 4)
          let counted = countHuffmanBits(q, bigPairs, r0, r1,
            [tabs[0], tabs[1], tabs[2]], quads, useB)
          check counted.isSome
          var w = newBitWriter()
          emitHuffman(w, q, bigPairs, r0, r1,
            [tabs[0], tabs[1], tabs[2]], quads, useB)
          # Exact bit count BEFORE pad-flush (flush adds up to 7 pad bits).
          let emitted = w.buf.len * 8 + w.nbits
          check emitted == counted.get
        discard mixed

suite "fuzz reservoir":
  test "hostile levels raise cleanly or schedule within bounds":
    initMpaTables()
    for i in 0 ..< 300:
      let n = 1 + frange(5)
      var frames = newSeq[Mp3ReservoirFrame](n)
      var slots = newSeq[int](n)
      let maxR = [0, 1, 512, 2040, 4088, 1 shl 20][i mod 6]
      for f in 0 ..< n:
        let pick = frange(8)
        let need =
          case pick
          of 0: 0
          of 1: 1
          of 2: 63
          of 3: 4096
          of 4: 1 shl 20
          of 5: frange(9000)
          of 6: frange(100)
          else: maxR + frange(100)
        frames[f] = Mp3ReservoirFrame(mainData: @[], bitLen: need)
        slots[f] = frange(9000)
      var sched: seq[Mp3ScheduledFrame] = @[]
      var ok = false
      expectAudioOnly("scheduleReservoirSlots"):
        sched = scheduleReservoirSlots(frames, slots, maxR)
        ok = true
      if ok:
        check sched.len == n
        var r = 0
        for f in 0 ..< n:
          # The scheduler checks the carry at each frame entry (frame 0
          # starts at zero); the trailing carry out of the last frame is
          # unchecked by design (it drains at stream end).
          check r >= 0
          check r <= maxR
          check sched[f].mainDataBegin == r div 8
          check sched[f].mainDataBegin * 8 <= maxR
          r = r + slots[f] - frames[f].bitLen

suite "fuzz encoder configs":
  test "hostile configs raise cleanly or emit walkable self-decodable audio":
    initMpaTables()
    var pcs: seq[seq[float32]] = @[]
    pcs.add(newSeq[float32](1152)) # silence
    var dc = newSeq[float32](1152)
    for i in 0 ..< 1152:
      dc[i] = if i mod 2 == 0: 32767.0 / 32768.0 else: -1.0
    pcs.add(dc)
    var alt = newSeq[float32](1152)
    for i in 0 ..< 1152:
      alt[i] = if i mod 2 == 0: 1.0 else: -1.0
    pcs.add(alt)
    var nz = newSeq[float32](1152)
    var s = 0x12345678'u32
    for i in 0 ..< 1152:
      s = s * 1664525'u32 + 1013904223'u32
      nz[i] = (((s shr 16) and 0xFFFF'u32).int32 - 32768).float / 32768.0
    pcs.add(nz)
    pcs.add(newSeq[float32](17))
    pcs.add(newSeq[float32](576))
    pcs.add(newSeq[float32](0))
    const bitrates = [0, 8, 16, 32, 40, 64, 96, 123, 128, 192, 320,
      1000]
    const rates = [44_100'u32, 48_000, 32_000, 22_050, 24_000, 16_000,
      11_025, 12_000, 8_000, 44_101, 11_024, 0]
    var combos = 0
    for bi in 0 ..< bitrates.len:
      for ri in 0 ..< rates.len:
        for mi in 0 ..< fuzzModes().len:
          if (bi * 131 + ri * 17 + mi * 7) mod 11 != 0:
            continue # deterministic sparse sample of the cross product
          inc combos
          if combos > 120:
            break
          var o = Mp3EncoderOptions(bitrateKbps: bitrates[bi],
            sampleRateHz: rates[ri], mode: fuzzModes()[mi],
            outerXmin: 1.0e6, ltqOffsetDb: NaN, attackThreshold: 10.0,
            jointAutoThreshold: 0.5)
          o.useOuterLoop = (bi + mi) mod 3 == 0
          if o.useOuterLoop and (mi mod 2 == 0):
            o.ltqOffsetDb = [-12.0, 0.0, 6.0][(bi + ri) mod 3]
          if (bi + ri + mi) mod 5 == 0:
            o.useModel2 = true
            o.useOuterLoop = true
          o.forceShort = (ri + mi) mod 7 == 0
          o.forceMixed = (ri + mi) mod 11 == 0
          o.autoBlock = (bi + mi) mod 9 == 0
          if o.autoBlock and (bi mod 2 == 0):
            o.autoMixed = true
          o.jointMs = o.mode.kind == mmJoint and (mi mod 2 == 0)
          o.jointAuto = o.mode.kind == mmJoint and not o.jointMs and
            (mi mod 2 == 1)
          o.intensityStart = [0, 0, 1, 8, 20, 21][(bi + ri + mi) mod 6]
          o.vbr = (bi + ri) mod 8 == 0
          if o.vbr:
            o.vbrMinKbps = [8, 96, 192][(bi + mi) mod 3]
            o.vbrMaxKbps = [96, 192, 64][(ri + mi) mod 3]
          o.crc = (bi + mi) mod 4 == 0
          o.xing = (ri + mi) mod 3 == 0
          o.gapless = o.xing and (bi mod 2 == 0)
          let pcm = pcs[(bi + ri + mi) mod pcs.len]
          var enc: Mp3Encoder = nil
          var encOk = false
          expectAudioOnly("newMp3Encoder bi=" & $bi & " ri=" & $ri &
              " mi=" & $mi):
            enc = newMp3Encoder(o)
            encOk = true
          if not encOk or enc.isNil:
            continue
          var bytes: seq[uint8] = @[]
          var finOk = false
          if (bi + ri + mi) mod 2 == 0:
            var s16 = newSeq[int16](pcm.len)
            for i, v in pcm:
              s16[i] = clamp(v * 32768.0, -32768.0, 32767.0).int16
            expectAudioOnly("encodeI16 bi=" & $bi & " ri=" & $ri &
                " mi=" & $mi):
              enc.pushSamplesI16(s16)
              bytes = enc.finishEncoder()
              finOk = true
          else:
            expectAudioOnly("encodeF32 bi=" & $bi & " ri=" & $ri &
                " mi=" & $mi):
              enc.pushSamplesF32(pcm)
              bytes = enc.finishEncoder()
              finOk = true
          if not finOk:
            continue
          var walked = false
          var walkStage = "open"
          expectAudioOnly("walk+decode bi=" & $bi & " ri=" & $ri &
              " mi=" & $mi):
            let w = mpafmt.openMpa(bytes)
            if w.tracks.len == 0:
              walkStage = "zero-tracks"
              raise decodeError("fuzz: encoder emitted zero tracks")
            walkStage = "decode"
            var n = 0
            let dec = newMpaDecoder(w.tracks[0].codec,
              AudioDecoderOptions(gapless: true, verify: false))
            while true:
              let pkt = w.nextPacket()
              if pkt.isNone:
                break
              inc n
              discard dec.decodePacket(pkt.get)
            if n == 0:
              walkStage = "zero-packets"
              raise decodeError("fuzz: encoder emitted zero packets")
            walked = true
          if not walked:
            checkpoint("decode stage: " & walkStage & " bi=" & $bi &
              " ri=" & $ri & " mi=" & $mi)
          check walked
    check combos > 0
  test "hostile f32 pcm (nan/inf/huge) encodes without panic":
    initMpaTables()
    for vals in [@[0.0'f32, NaN, 0.0, Inf, 0.0, NegInf],
        @[1e30'f32, -1e30, 0.0, 0.0], @[2.0'f32, -2.0, 0.5, -0.5]]:
      var pcm = newSeq[float32]()
      for i in 0 ..< 1152:
        for v in vals:
          pcm.add(v)
      expectAudioOnly("f32 hostile"):
        let e = newMp3EncoderOuterLoop(128, 44_100,
          MpaMode(kind: mmStereo))
        e.pushSamplesF32(pcm)
        let b = e.finishEncoder()
        let w = mpafmt.openMpa(b)
        check w.packets.len > 0

suite "fuzz demuxer bytes":
  test "hostile byte streams never panic, valid frames survive":
    initMpaTables()
    let spec = newAudioSpec(44_100, ChStereo)
    var src = newAudioSamples(sfS16, spec, 2304)
    src.s16.renderWith(2304, i):
      src.s16.planes[0][i] = (0.4 * 32767.0 *
        sin(2.0 * PI * 440.0 * i.float / 44100.0)).int16
      src.s16.planes[1][i] = (0.4 * 32767.0 *
        sin(2.0 * PI * 660.0 * i.float / 44100.0)).int16
    var seeds: seq[seq[uint8]] = @[]
    for (kbps, rate, mode, jms) in [(128, 44_100'u32,
        MpaMode(kind: mmStereo), false),
        (128, 44_100'u32, MpaMode(kind: mmJoint, midSide: true,
          intensity: false, bound: 0), true),
        (64, 22_050'u32, MpaMode(kind: mmStereo), false)]:
      var o = Mp3EncoderOptions(bitrateKbps: kbps, sampleRateHz: rate,
        mode: mode, outerXmin: 1.0e6, ltqOffsetDb: NaN,
        attackThreshold: 10.0, jointAutoThreshold: 0.5, jointMs: jms)
      seeds.add(encodeMp3Stream(src, o))
    check seeds.len == 3
    var cases: seq[seq[uint8]] = @[]
    cases.add(@[])
    cases.add(@[0xFF'u8])
    cases.add(@[0xFF'u8, 0xFB'u8])
    for L in [1, 2, 3, 4, 5, 100, 260, 1000]:
      var g = newSeq[uint8](L)
      for i in 0 ..< L:
        g[i] = (frnd() and 0xFF'u32).uint8
      cases.add(g)
    for sd in seeds:
      for f in [0, 1, 2, 3, 4, 5, 6, 7, 100]:
        if f <= sd.len:
          cases.add(sd[0 ..< f])
      for f in countup(0, sd.len - 1, max(sd.len div 40, 1)):
        cases.add(sd[0 ..< f])
      for r in 0 ..< 12:
        var m = sd
        for b in 0 ..< 4:
          let at = frange(m.len)
          m[at] = m[at] xor (1'u8 shl frange(8))
        cases.add(m)
        discard r
      cases.add(sd & seeds[0])
      cases.add(seeds[1] & sd)
      cases.add(sd[0 ..< sd.len div 2] & seeds[2][seeds[2].len div 2 .. ^1])
    var decoded = 0
    for ci, c in cases:
      var w: MpaReader
      var opened = false
      expectAudioOnly("demux case " & $ci & " len=" & $c.len):
        w = mpafmt.openMpa(c)
        opened = true
      if not opened or w.tracks.len == 0:
        continue
      expectAudioOnly("decode case " & $ci & " len=" & $c.len):
        let dec = newMpaDecoder(w.tracks[0].codec,
          AudioDecoderOptions(gapless: ci mod 2 == 0, verify: ci mod 3 == 0))
        while true:
          let pkt = w.nextPacket()
          if pkt.isNone:
            break
          discard dec.decodePacket(pkt.get)
          inc decoded
    check decoded > 0
