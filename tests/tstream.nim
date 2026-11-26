import std/options
import std/os
import unittest

import audio/audio
import audio/codecs
import audio/codecs/flac
import audio/codecs/pcm
import audio/formats
import audio/formats/flac as flacfmt
import audio/formats/wav
import audio/io
import audio/packet
import audio/source
import audio/units
import audio/errors

proc rampS16(n: int; ch = ChStereo; rate = 44_100'u32): AudioSamples =
  let spec = newAudioSpec(rate, ch)
  result = newAudioSamples(sfS16, spec, n)
  let nch = ch.channelCount()
  result.s16.renderWith(n, i):
    for p in 0 ..< nch:
      result.s16.planes[p][i] = cast[int16]((i * 257 + p * 7919) mod 65536 -
        32768)

proc collectMapped(w: WavMappedReader; dec: PcmDecoder): AudioSamples =
  ## Decodes every packet window with zero packet copies.
  var frames = 0
  var first = true
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    if first:
      result = newAudioSamples(s.format, s.specOf(), 0)
      first = false
    result.s16.growCapacity(frames + s.framesOf())
    for p in 0 ..< s.s16.planes.len:
      for i in 0 ..< s.framesOf():
        result.s16.planes[p][frames + i] = s.s16.planes[p][i]
    result.s16.numFrames = frames + s.framesOf()
    frames += s.framesOf()

proc collectFlacMapped(w: FlacMappedReader;
    dec: FlacDecoder): AudioSamples =
  ## Decodes every frame window with zero packet copies.
  var frames = 0
  var first = true
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    if first:
      result = newAudioSamples(s.format, s.specOf(), 0)
      first = false
    result.s32.growCapacity(frames + s.framesOf())
    for p in 0 ..< s.s32.planes.len:
      for i in 0 ..< s.framesOf():
        result.s32.planes[p][frames + i] = s.s32.planes[p][i]
    result.s32.numFrames = frames + s.framesOf()
    frames += s.framesOf()

proc collectFlacMem(w: FlacReader; dec: FlacDecoder): AudioSamples =
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
    result.s32.growCapacity(frames + s.framesOf())
    for p in 0 ..< s.s32.planes.len:
      for i in 0 ..< s.framesOf():
        result.s32.planes[p][frames + i] = s.s32.planes[p][i]
    result.s32.numFrames = frames + s.framesOf()
    frames += s.framesOf()

suite "streaming wav":
  test "mapped open matches in-memory header":
    let src = rampS16(5_000)
    let path = getTempDir() / "audio_stream_hdr.wav"
    writeFile(path, cast[string](encodeWav(src, 44_100)))
    try:
      let mem = openWav(encodeWav(src, 44_100))
      let w = openWavMapped(path)
      try:
        check w.trackCount() == mem.trackCount()
        check w.params.codec == mem.params.codec
        check w.params.sampleRate.get == 44_100
        check w.numFrames().get == 5_000
        check w.mediaInfo().duration.get == mem.mediaInfo().duration.get
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped view decode is sample-exact, zero packet copies":
    let src = rampS16(50_000)
    let bytes = encodeWav(src, 44_100)
    let path = getTempDir() / "audio_stream_exact.wav"
    writeFile(path, cast[string](bytes))
    try:
      # Reference: in-memory path.
      let mem = openWav(bytes)
      let mdec = newPcmDecoder(mem.params)
      var want: seq[seq[int16]] = @[]
      var total = 0
      while true:
        let pkt = mem.nextPacket()
        if pkt.isNone:
          break
        let s = mdec.decodePacket(pkt.get)
        if total == 0:
          want = newSeq[seq[int16]](s.s16.planes.len)
        for p in 0 ..< s.s16.planes.len:
          for i in 0 ..< s.framesOf():
            want[p].add(s.s16.planes[p][i])
        total += s.framesOf()
      # Streaming path: views straight from the mapping.
      let w = openWavMapped(path)
      try:
        let dec = newPcmDecoder(w.params)
        let back = collectMapped(w, dec)
        check back.framesOf() == total
        for p in 0 ..< want.len:
          for i in 0 ..< total:
            check back.s16.planes[p][i] == want[p][i]
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped owning packets match views":
    let src = rampS16(9_000)
    let path = getTempDir() / "audio_stream_own.wav"
    writeFile(path, cast[string](encodeWav(src, 44_100)))
    try:
      let w = openWavMapped(path)
      try:
        var fromViews: seq[uint8] = @[]
        var fromOwn: seq[uint8] = @[]
        while true:
          let v = w.nextPacketView()
          if v.isNone:
            break
          fromViews.add(v.get.packetSeq())
        discard w.seek(seekToTimestamp(newTimestamp(0), 0))
        while true:
          let pkt = w.nextPacket()
          if pkt.isNone:
            break
          fromOwn.add(pkt.get.data)
        check fromOwn == fromViews
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped seek lands on packet boundary":
    let src = rampS16(9_000)
    let path = getTempDir() / "audio_stream_seek.wav"
    writeFile(path, cast[string](encodeWav(src, 44_100)))
    try:
      let w = openWavMapped(path)
      try:
        let s = w.seek(seekToTimestamp(newTimestamp(5_000), 0))
        check s.actualTs.get == 4_608 # 1152-frame packet grid.
        check w.nextPacketView().get.pts.get == 4_608
      finally:
        w.close()
    finally:
      removeFile(path)

  test "byte pool stays flat across packets":
    let src = rampS16(50_000)
    let path = getTempDir() / "audio_stream_pool.wav"
    writeFile(path, cast[string](encodeWav(src, 44_100)))
    try:
      var pool = initStreamPool()
      let cap0 = pool.cap
      check cap0 == DefaultStreamPoolBytes
      let w = openWavMapped(path)
      try:
        var n = 0
        while true:
          let v = w.nextPacketView()
          if v.isNone:
            break
          loadPacketInto(pool, v.get)
          check pool.cap == cap0
          # Pool contents equal the mapping window.
          let win = v.get.packetSeq()
          check pool.toSeq() == win
          inc n
        check n > 1
        check pool.cap == cap0
      finally:
        w.close()
    finally:
      removeFile(path)

  test "view reader matches reader primitives":
    var data = newSeq[uint8](256)
    for i in 0 ..< 256:
      data[i] = i.uint8
    var r = newReader(data)
    var base = cast[ptr UncheckedArray[uint8]](data[0].addr)
    var v = ViewReader(base: base, len: data.len, pos: 0)
    check v.readU16Le() == r.readU16Le()
    check v.readU16Be() == r.readU16Be()
    check v.readU24Le() == r.readU24Le()
    check v.readU32Be() == r.readU32Be()
    check v.readI16Le() == r.readI16Le()
    check v.readF32Le() == r.readF32Le()
    check v.readFourCc() == r.readFourCc()
    check v.peekU32Le() == r.peekU32Le()
    check v.remaining() == r.remaining()
    v.ignoreBytes(3)
    r.ignoreBytes(3)
    check v.readByte() == r.readByte()
    check v.getPos() == r.getPos()

suite "streaming flac":
  test "mapped open matches in-memory header":
    let src = rampS16(5_000)
    let bytes = encodeFlacStream(src, 44_100)
    let path = getTempDir() / "audio_stream_flac_hdr.flac"
    writeFile(path, cast[string](bytes))
    try:
      let mem = openFlac(bytes)
      let w = openFlacMapped(path)
      try:
        check w.trackCount() == mem.trackCount()
        check w.params.sampleRate.get == 44_100
        check w.params.bitsPerSample.get == 16
        check w.numFrames().get == mem.numFrames().get
        check w.mediaInfo().duration.get == mem.mediaInfo().duration.get
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped view decode is sample-exact, zero packet copies":
    let src = rampS16(20_000)
    let bytes = encodeFlacStream(src, 44_100)
    let path = getTempDir() / "audio_stream_flac.flac"
    writeFile(path, cast[string](bytes))
    try:
      let mem = openFlac(bytes)
      let mdec = newFlacDecoder(mem.params,
        AudioDecoderOptions(gapless: true, verify: true))
      let want = collectFlacMem(mem, mdec)
      check mdec.finalize().verifyOk.get == true
      let w = openFlacMapped(path)
      try:
        let dec = newFlacDecoder(w.params,
          AudioDecoderOptions(gapless: true, verify: true))
        let back = collectFlacMapped(w, dec)
        check dec.finalize().verifyOk.get == true
        check back.framesOf() == want.framesOf()
        for p in 0 ..< want.s32.planes.len:
          for i in 0 ..< want.framesOf():
            check back.s32.planes[p][i] == want.s32.planes[p][i]
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped owning packets match views":
    let src = rampS16(9_000)
    let path = getTempDir() / "audio_stream_flac_own.flac"
    writeFile(path, cast[string](encodeFlacStream(src, 44_100)))
    try:
      let w = openFlacMapped(path)
      try:
        var fromViews: seq[uint8] = @[]
        var fromOwn: seq[uint8] = @[]
        while true:
          let v = w.nextPacketView()
          if v.isNone:
            break
          fromViews.add(v.get.packetSeq())
        discard w.seek(seekToTimestamp(newTimestamp(0), 0))
        while true:
          let pkt = w.nextPacket()
          if pkt.isNone:
            break
          fromOwn.add(pkt.get.data)
        check fromOwn == fromViews
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped seek lands on frame boundary":
    let src = rampS16(20_000)
    let path = getTempDir() / "audio_stream_flac_seek.flac"
    writeFile(path, cast[string](encodeFlacStream(src, 44_100)))
    try:
      let w = openFlacMapped(path)
      try:
        let s = w.seek(seekToTimestamp(newTimestamp(5_000), 0))
        check s.actualTs.get <= 5_000
        check w.nextPacketView().get.pts.get == s.actualTs.get
      finally:
        w.close()
    finally:
      removeFile(path)
