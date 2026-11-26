import std/options
import std/os
import unittest

import audio/audio
import audio/codecs
import audio/codecs/flac
import audio/codecs/aac
import audio/codecs/adpcm
import audio/codecs/alac
import audio/codecs/mpa
import audio/codecs/pcm
import audio/codecs/vorbis
import audio/formats
import audio/formats/flac as flacfmt
import audio/formats/mp4 as mp4fmt
import audio/formats/mpa as mpafmt
import audio/formats/mkv as mkvfmt
import audio/formats/ogg as oggfmt
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

proc readRefS16Mpa(path: string; nch: int): seq[seq[int16]] =
  let raw = readFile(path)
  var data = newSeq[uint8](raw.len)
  for i, c in raw:
    data[i] = cast[uint8](c)
  var at = 0
  while not (data[at] == 0x64'u8 and data[at + 1] == 0x61'u8 and
      data[at + 2] == 0x74'u8 and data[at + 3] == 0x61'u8):
    inc at
  var r = newReader(data.toOpenArray(at + 8, data.len - 1))
  let total = (data.len - at - 8) div (2 * nch)
  result = newSeq[seq[int16]](nch)
  for p in 0 ..< nch:
    result[p] = newSeq[int16](total)
  for i in 0 ..< total:
    for p in 0 ..< nch:
      result[p][i] = r.readI16Le()

proc collectMpaMapped(w: MpaMappedReader; dec: MpaDecoder): seq[seq[float32]] =
  ## Decodes every frame window with zero packet copies.
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  for p in 0 ..< nch:
    result[p] = @[]
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc collectAacMapped(w: Mp4MappedReader; dec: AacDecoder): seq[seq[float32]] =
  ## Decodes every sample window with zero packet copies.
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  for p in 0 ..< nch:
    result[p] = @[]
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc collectAdpcmMapped(w: WavMappedReader;
    dec: AdpcmDecoder): AudioSamples =
  ## Decodes every block window with zero packet copies.
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

proc collectAlacMapped(w: Mp4MappedReader; dec: AlacDecoder): seq[seq[int32]] =
  ## Decodes every ALAC sample window with zero packet copies.
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[int32]](nch)
  for p in 0 ..< nch:
    result[p] = @[]
  doAssert w.tracks[0].codec.codec == CodecAlac
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.s32.planes[p][i])

proc collectVorbisMapped(w: OggMappedReader;
    dec: VorbisDecoder): seq[seq[float32]] =
  ## Decodes every packet window (mapping views and pool assemblies).
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  for p in 0 ..< nch:
    result[p] = @[]
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

proc collectVorbisMkvMapped(w: MkvMappedReader;
    dec: VorbisDecoder): seq[seq[float32]] =
  ## Decodes every mapped frame window (all contiguous lace spans).
  let nch = w.tracks[0].codec.channels.get.channelCount()
  result = newSeq[seq[float32]](nch)
  for p in 0 ..< nch:
    result[p] = @[]
  while true:
    let v = w.nextPacketView()
    if v.isNone:
      break
    let s = dec.decodePacketView(v.get)
    for p in 0 ..< nch:
      for i in 0 ..< s.framesOf():
        result[p].add(s.f32.planes[p][i])

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

suite "streaming adpcm":
  test "mapped ms decode matches owning decode":
    let src = rampS16(3_000)
    let bytes = encodeWav(src, 44_100, CodecAdpcmMs)
    let path = getTempDir() / "audio_stream_ms.wav"
    writeFile(path, cast[string](bytes))
    try:
      let mem = openWav(bytes)
      let mdec = newAdpcmDecoder(mem.params)
      var want: seq[seq[int32]] = @[]
      var total = 0
      while true:
        let pkt = mem.nextPacket()
        if pkt.isNone:
          break
        let s = mdec.decodePacket(pkt.get)
        if total == 0:
          want = newSeq[seq[int32]](s.s32.planes.len)
        for p in 0 ..< s.s32.planes.len:
          for i in 0 ..< s.framesOf():
            want[p].add(s.s32.planes[p][i])
        total += s.framesOf()
      let w = openWavMapped(path)
      try:
        check w.params.codec == CodecAdpcmMs
        let dec = newAdpcmDecoder(w.params)
        let back = collectAdpcmMapped(w, dec)
        check back.framesOf() == total
        for p in 0 ..< want.len:
          for i in 0 ..< total:
            check back.s32.planes[p][i] == want[p][i]
      finally:
        w.close()
    finally:
      removeFile(path)

  test "mapped ima decode matches owning decode":
    let spec = newAudioSpec(44_100, discrete(1))
    var src = newAudioSamples(sfS16, spec, 2_000)
    src.s16.renderWith(2_000, i):
      src.s16.planes[0][i] = cast[int16]((i * 257) mod 65536 - 32768)
    let bytes = encodeWav(src, 44_100, CodecAdpcmImaWav)
    let path = getTempDir() / "audio_stream_ima.wav"
    writeFile(path, cast[string](bytes))
    try:
      let mem = openWav(bytes)
      let mdec = newAdpcmDecoder(mem.params)
      var want = newSeq[int32]()
      while true:
        let pkt = mem.nextPacket()
        if pkt.isNone:
          break
        let s = mdec.decodePacket(pkt.get)
        for i in 0 ..< s.framesOf():
          want.add(s.s32.planes[0][i])
      let w = openWavMapped(path)
      try:
        check w.params.codec == CodecAdpcmImaWav
        let dec = newAdpcmDecoder(w.params)
        let back = collectAdpcmMapped(w, dec)
        check back.framesOf() == want.len
        for i in 0 ..< want.len:
          check back.s32.planes[0][i] == want[i]
      finally:
        w.close()
    finally:
      removeFile(path)

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

suite "streaming mp3":
  const Mp3Fix = "tests/fixtures/fix_mp3stereo.mp3"
  const Mp3Ref = "tests/fixtures/ref_mp3stereo_dec.wav"

  test "mapped open matches in-memory scan":
    let raw = readFile(Mp3Fix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMpa(bytes)
    let w = openMpaMapped(Mp3Fix)
    try:
      check w.trackCount() == mem.trackCount()
      check w.tracks[0].codec.codec == CodecMp3
      check w.tracks[0].codec.sampleRate.get ==
        mem.tracks[0].codec.sampleRate.get
      check w.numFrames().get == mem.numFrames().get
      check w.packets.len == mem.packets.len
      check w.firstPacketPos == mem.firstPacketPos
      check w.delay == mem.delay
    finally:
      w.close()

  test "mapped view decode matches owning decode, ffmpeg within 2 LSB":
    let raw = readFile(Mp3Fix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMpa(bytes)
    let mdec = newMpaDecoder(mem.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var want = newSeq[seq[float32]](2)
    want[0] = @[]
    want[1] = @[]
    while true:
      let pkt = mem.nextPacket()
      if pkt.isNone:
        break
      let s = mdec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          want[p].add(s.f32.planes[p][i])
    let w = openMpaMapped(Mp3Fix)
    try:
      let dec = newMpaDecoder(w.tracks[0].codec,
        AudioDecoderOptions(gapless: true, verify: false))
      let back = collectMpaMapped(w, dec)
      check back[0].len == want[0].len
      check back[1].len == want[1].len
      for i in 0 ..< want[0].len:
        check back[0][i] == want[0][i]
        check back[1][i] == want[1][i]
      let refs = readRefS16Mpa(Mp3Ref, 2)
      check back[0].len == refs[0].len
      var worst = 0.0
      for i in 0 ..< refs[0].len:
        for p in 0 ..< 2:
          worst = max(worst,
            abs(back[p][i].float64 * 32768.0 - refs[p][i].float64))
      check worst <= 2.0
    finally:
      w.close()

  test "mapped seek matches owning seek with reservoir backtrack":
    let raw = readFile(Mp3Fix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMpa(bytes)
    let w = openMpaMapped(Mp3Fix)
    try:
      let a = mem.seek(seekToTimestamp(newTimestamp(20_000), 0))
      let b = w.seek(seekToTimestamp(newTimestamp(20_000), 0))
      check b.actualTs == a.actualTs
      check w.nextPacketView().get.pts == mem.nextPacket().get.pts
    finally:
      w.close()

suite "streaming aac":
  const AacFix = "tests/fixtures/fix_aacstereo.m4a"
  const AacRef = "tests/fixtures/ref_aacstereo_dec.wav"

  test "mapped open matches in-memory scan":
    let raw = readFile(AacFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMp4(bytes)
    let w = openMp4Mapped(AacFix)
    try:
      check w.trackCount() == mem.trackCount()
      check w.tracks[0].codec.codec == CodecAac
      check w.tracks[0].codec.sampleRate.get ==
        mem.tracks[0].codec.sampleRate.get
      check w.numFrames().get == mem.numFrames().get
      check w.packets.len == mem.packets.len
    finally:
      w.close()

  test "mapped view decode matches owning decode, ffmpeg within 2 LSB":
    let raw = readFile(AacFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMp4(bytes)
    let mdec = newAacDecoder(mem.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var want = newSeq[seq[float32]](2)
    want[0] = @[]
    want[1] = @[]
    while true:
      let pkt = mem.nextPacket()
      if pkt.isNone:
        break
      let s = mdec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          want[p].add(s.f32.planes[p][i])
    let w = openMp4Mapped(AacFix)
    try:
      let dec = newAacDecoder(w.tracks[0].codec,
        AudioDecoderOptions(gapless: true, verify: false))
      let back = collectAacMapped(w, dec)
      check back[0].len == want[0].len
      check back[1].len == want[1].len
      for i in 0 ..< want[0].len:
        check back[0][i] == want[0][i]
        check back[1][i] == want[1][i]
      let refs = readRefS16Mpa(AacRef, 2)
      check back[0].len == refs[0].len + 1024
      var worst = 0.0
      for i in 0 ..< refs[0].len:
        for p in 0 ..< 2:
          worst = max(worst,
            abs(back[p][i + 1024].float64 * 32768.0 - refs[p][i].float64))
      check worst <= 2.0
    finally:
      w.close()

  test "mapped seek matches owning seek":
    let raw = readFile(AacFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMp4(bytes)
    let w = openMp4Mapped(AacFix)
    try:
      let tid = mem.tracks[0].id
      let a = mem.seek(seekToTimestamp(newTimestamp(20_000), tid))
      let b = w.seek(seekToTimestamp(newTimestamp(20_000), tid))
      check b.actualTs == a.actualTs
      check w.nextPacketView().get.pts == mem.nextPacket().get.pts
    finally:
      w.close()

suite "streaming alac":
  const AlacFix = "tests/fixtures/fix_alacstereo.m4a"

  test "mapped view decode is bit-exact":
    let raw = readFile(AlacFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMp4(bytes)
    let mdec = newAlacDecoder(mem.tracks[0].codec)
    var want = newSeq[seq[int32]](2)
    want[0] = @[]
    want[1] = @[]
    while true:
      let pkt = mem.nextPacket()
      if pkt.isNone:
        break
      let s = mdec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          want[p].add(s.s32.planes[p][i])
    let w = openMp4Mapped(AlacFix)
    try:
      check w.tracks[0].codec.codec == CodecAlac
      let dec = newAlacDecoder(w.tracks[0].codec)
      let back = collectAlacMapped(w, dec)
      check back[0].len == want[0].len
      check back[1].len == want[1].len
      for i in 0 ..< want[0].len:
        check back[0][i] == want[0][i]
        check back[1][i] == want[1][i]
    finally:
      w.close()

suite "streaming vorbis":
  const VorbisFix = "tests/fixtures/fix_stereo.ogg"
  const VorbisRef = "tests/fixtures/ref_stereo_dec.wav"

  test "mapped open matches in-memory scan":
    let raw = readFile(VorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openOgg(bytes)
    let w = openOggMapped(VorbisFix)
    try:
      check w.trackCount() == mem.trackCount()
      check w.tracks[0].codec.sampleRate.get ==
        mem.tracks[0].codec.sampleRate.get
      check w.numFrames().get == mem.numFrames().get
      check w.packets.len == mem.packets.len
    finally:
      w.close()

  test "mapped view decode matches owning decode, ffmpeg within 2 LSB":
    let raw = readFile(VorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openOgg(bytes)
    let mdec = newVorbisDecoder(mem.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var want = newSeq[seq[float32]](2)
    want[0] = @[]
    want[1] = @[]
    while true:
      let pkt = mem.nextPacket()
      if pkt.isNone:
        break
      let s = mdec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          want[p].add(s.f32.planes[p][i])
    let w = openOggMapped(VorbisFix)
    try:
      let dec = newVorbisDecoder(w.tracks[0].codec,
        AudioDecoderOptions(gapless: true, verify: false))
      let back = collectVorbisMapped(w, dec)
      check back[0].len == want[0].len
      check back[1].len == want[1].len
      for i in 0 ..< want[0].len:
        check back[0][i] == want[0][i]
        check back[1][i] == want[1][i]
      let refs = readRefS16Mpa(VorbisRef, 2)
      check back[0].len == refs[0].len
      var worst = 0.0
      for i in 0 ..< refs[0].len:
        for p in 0 ..< 2:
          worst = max(worst,
            abs(back[p][i].float64 * 32768.0 - refs[p][i].float64))
      check worst <= 2.0
    finally:
      w.close()

  test "pool-assembled windows decode identically":
    # The fixtures pack packets into single pages; force multi-span
    # windows by splitting every span, exercising pool assembly end to
    # end on real data.
    let raw = readFile(VorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openOgg(bytes)
    let mdec = newVorbisDecoder(mem.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var want = newSeq[seq[float32]](2)
    want[0] = @[]
    want[1] = @[]
    while true:
      let pkt = mem.nextPacket()
      if pkt.isNone:
        break
      let s = mdec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          want[p].add(s.f32.planes[p][i])
    let w = openOggMapped(VorbisFix)
    try:
      var split = 0
      for i in 0 ..< w.packets.len:
        let s = w.packets[i].segs
        if s.len == 1 and s[0][1] - s[0][0] > 2:
          let mid = (s[0][0] + s[0][1]) div 2
          w.packets[i].segs = @[(s[0][0], mid), (mid, s[0][1])]
          inc split
      check split > 0
      check w.host.buf.cap == DefaultStreamPoolBytes
      let dec = newVorbisDecoder(w.tracks[0].codec,
        AudioDecoderOptions(gapless: true, verify: false))
      let back = collectVorbisMapped(w, dec)
      check back[0].len == want[0].len
      for i in 0 ..< want[0].len:
        check back[0][i] == want[0][i]
        check back[1][i] == want[1][i]
      check w.host.buf.cap >= DefaultStreamPoolBytes
    finally:
      w.close()

  test "mapped seek matches owning seek":
    let raw = readFile(VorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openOgg(bytes)
    let w = openOggMapped(VorbisFix)
    try:
      let a = mem.seek(seekToTimestamp(newTimestamp(20_000), 0))
      let b = w.seek(seekToTimestamp(newTimestamp(20_000), 0))
      check b.actualTs == a.actualTs
      check w.nextPacketView().get.pts == mem.nextPacket().get.pts
    finally:
      w.close()

suite "streaming mkv":
  const MkvVorbisFix = "tests/fixtures/fix_vorbis_stereo.mka"
  const MkvVorbisRef = "tests/fixtures/ref_vorbis_stereo_mkv_dec.wav"

  test "mapped open matches in-memory scan":
    let raw = readFile(MkvVorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMkv(bytes)
    let w = openMkvMapped(MkvVorbisFix)
    try:
      check w.trackCount() == mem.trackCount()
      check w.tracks[0].codec.codec == CodecVorbis
      check w.tracks[0].codec.sampleRate.get ==
        mem.tracks[0].codec.sampleRate.get
      check w.packets.len == mem.packets.len
      check w.cues.len == mem.cues.len
      check w.segmentStart == mem.segmentStart
      for i in 0 ..< w.packets.len:
        check w.packets[i].stop - w.packets[i].start ==
          mem.packets[i].data.len
    finally:
      w.close()

  test "mapped view decode matches owning decode, ffmpeg within 2 LSB":
    let raw = readFile(MkvVorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    registerVorbis()
    let mem = openMkv(bytes)
    let mdec = newVorbisDecoder(mem.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    var want = newSeq[seq[float32]](2)
    want[0] = @[]
    want[1] = @[]
    while true:
      let pkt = mem.nextPacket()
      if pkt.isNone:
        break
      let s = mdec.decodePacket(pkt.get)
      for p in 0 ..< 2:
        for i in 0 ..< s.framesOf():
          want[p].add(s.f32.planes[p][i])
    let w = openMkvMapped(MkvVorbisFix)
    try:
      let dec = newVorbisDecoder(w.tracks[0].codec,
        AudioDecoderOptions(gapless: true, verify: false))
      let back = collectVorbisMkvMapped(w, dec)
      check back[0].len == want[0].len
      for i in 0 ..< want[0].len:
        check back[0][i] == want[0][i]
        check back[1][i] == want[1][i]
      let refs = readRefS16Mpa(MkvVorbisRef, 2)
      var worst = 0.0
      for i in 0 ..< refs[0].len:
        for p in 0 ..< 2:
          worst = max(worst,
            abs(back[p][i].float64 * 32768.0 - refs[p][i].float64))
      check worst <= 2.0
    finally:
      w.close()

  test "mapped owning packets match across all codecs":
    registerVorbis()
    registerMpa()
    registerAac()
    registerAlac()
    registerFlac()
    registerPcm()
    for fix in ["fix_vorbis_stereo.mka", "fix_mp3_stereo.mkv",
        "fix_aac_stereo.mkv", "fix_flac_stereo.mka", "fix_pcm_stereo.mkv",
        "fix_alac_stereo.mka"]:
      let raw = readFile("tests/fixtures/" & fix)
      var bytes = newSeq[uint8](raw.len)
      for i, c in raw:
        bytes[i] = cast[uint8](c)
      let mem = openMkv(bytes)
      let mdec = makeAudioDecoder(mem.tracks[0].codec)
      var wantData: seq[uint8] = @[]
      var wantPts: seq[int64] = @[]
      while true:
        let pkt = mem.nextPacket()
        if pkt.isNone:
          break
        discard mdec.decodePacket(pkt.get)
        wantData.add(pkt.get.data)
        wantPts.add(pkt.get.pts.get)
      let w = openMkvMapped("tests/fixtures/" & fix)
      try:
        check w.tracks[0].codec.codec == mem.tracks[0].codec.codec
        let dec = makeAudioDecoder(w.tracks[0].codec)
        var gotData: seq[uint8] = @[]
        var gotPts: seq[int64] = @[]
        while true:
          let pkt = w.nextPacket()
          if pkt.isNone:
            break
          discard dec.decodePacket(pkt.get)
          gotData.add(pkt.get.data)
          gotPts.add(pkt.get.pts.get)
        check gotData == wantData
        check gotPts == wantPts
      finally:
        w.close()

  test "mapped seek matches owning seek":
    let raw = readFile(MkvVorbisFix)
    var bytes = newSeq[uint8](raw.len)
    for i, c in raw:
      bytes[i] = cast[uint8](c)
    let mem = openMkv(bytes)
    let w = openMkvMapped(MkvVorbisFix)
    try:
      let tid = mem.tracks[0].id
      let a = mem.seek(seekToTimestamp(newTimestamp(60), tid))
      let b = w.seek(seekToTimestamp(newTimestamp(60), tid))
      check b.actualTs == a.actualTs
      check w.nextPacketView().get.pts == mem.nextPacket().get.pts
    finally:
      w.close()
