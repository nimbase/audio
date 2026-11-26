## PCM codec: decoder for all interleaved PCM variants plus encoder.
##
## Decoder ports `symphonia-codec-pcm/src/lib.rs`: the 20 interleaved
## variants (S8/S16LE/BE/S24LE/BE/S32LE/BE, U8/U16/U24/U32 LE/BE, F32/F64
## LE/BE, A-law, mu-law), A-law/mu-law transfer functions (adapted from
## Sun's g711.c, unrestricted-use license, see below), and the
## bits-per-sample/bits-per-coded-sample shift validation. Planar
## variants parse but decode in the filter phase.
##
## The encoder (`encodePcm`, law encoders) is new work: Symphonia has no
## encoders. Law encoding maps each sample to the code whose decoded
## representative is nearest (precomputed 64 KiB LUT), which guarantees
## `encode(decode(b)) == b` for all 256 codes.
##
## A-law and mu-law decode tables (`alawToLinear`, `mulawToLinear`) are
## adaptations of `alaw2linear` and `ulaw2linear` from g711.c by Sun
## Microsystems, Inc., provided for unrestricted use. Sun source code is
## provided as-is with no warranties of any kind.

import std/options
import ./../audio
import ./../codecs
import ./../errors
import ./../io
import ./../packet
import ./../source

const
  XLawQuantMask = 0x0f'u8
  XLawSegMask = 0x70'u8
  XLawSegShift = 4

proc alawToLinear*(code: uint8): int16 =
  var a = code xor 0x55'u8
  var t = cast[int16]((a and XLawQuantMask) shl 4)
  let seg = (a and XLawSegMask) shr XLawSegShift
  case seg
  of 0: t += 0x8'i16
  of 1: t += 0x108'i16
  else: t = cast[int16]((t + 0x108'i16).int32 shl (seg - 1).int)
  if (a and 0x80'u8) == 0x80'u8: t else: -t

proc mulawToLinear*(code: uint8): int16 =
  const Bias = 0x84'i16
  var mu = not code
  var t = cast[int16]((mu and XLawQuantMask) shl 3) + Bias
  t = cast[int16](t.int32 shl ((mu and XLawSegMask) shr XLawSegShift).int)
  if (mu and 0x80'u8) == 0x80'u8: Bias - t else: t - Bias

var alawEncodeTable: array[65536, uint8]
var alawTableReady = false
var mulawEncodeTable: array[65536, uint8]
var mulawTableReady = false

proc prefers(s, curRep, candRep: int32; curCode, candCode: uint8): bool =
  ## Tie-break among equally near representatives: first the
  ## representative whose sign matches the input (zero counts positive),
  ## then the larger code. The latter maps mu-law +0 to the conventional
  ## 0xFF rather than -0 0x7F (both decode to 0).
  let sPos = s >= 0
  let candPos = candRep >= 0
  let curPos = curRep >= 0
  if candPos == sPos and curPos != sPos:
    return true
  if candPos != sPos and curPos == sPos:
    return false
  candCode > curCode

proc buildLawTables() =
  for i in 0 ..< 65536:
    let s = cast[int16](cast[uint16](i)).int32
    var bestA = 0'u8
    var bestB = 0'u8
    var repA = high(int32)
    var repB = high(int32)
    var distA = high(int32)
    var distB = high(int32)
    for b in 0 ..< 256:
      let code = cast[uint8](b)
      let va = alawToLinear(code).int32
      let da = abs(va - s)
      if da < distA or (da == distA and prefers(s, repA, va, bestA, code)):
        distA = da
        repA = va
        bestA = code
      let vm = mulawToLinear(code).int32
      let dm = abs(vm - s)
      if dm < distB or (dm == distB and prefers(s, repB, vm, bestB, code)):
        distB = dm
        repB = vm
        bestB = code
    alawEncodeTable[i] = bestA
    mulawEncodeTable[i] = bestB
  alawTableReady = true
  mulawTableReady = true

proc linearToALaw*(s: int16): uint8 =
  ## Nearest-code A-law encoding of a 16-bit sample.
  if not alawTableReady:
    buildLawTables()
  alawEncodeTable[cast[uint16](s).int]

proc linearToMuLaw*(s: int16): uint8 =
  ## Nearest-code mu-law encoding of a 16-bit sample.
  if not mulawTableReady:
    buildLawTables()
  mulawEncodeTable[cast[uint16](s).int]

proc isSupportedPcmCodec*(id: AudioCodecId): bool =
  id in [
    CodecPcmS32Le, CodecPcmS32Be, CodecPcmS24Le, CodecPcmS24Be,
    CodecPcmS16Le, CodecPcmS16Be, CodecPcmS8, CodecPcmU32Le,
    CodecPcmU32Be, CodecPcmU24Le, CodecPcmU24Be, CodecPcmU16Le,
    CodecPcmU16Be, CodecPcmU8, CodecPcmF32Le, CodecPcmF32Be,
    CodecPcmF64Le, CodecPcmF64Be, CodecPcmALaw, CodecPcmMuLaw,
  ]

proc isPlanarPcmCodec*(id: AudioCodecId): bool =
  id in [
    CodecPcmS32LePlanar, CodecPcmS32BePlanar, CodecPcmS24LePlanar,
    CodecPcmS24BePlanar, CodecPcmS16LePlanar, CodecPcmS16BePlanar,
    CodecPcmS8Planar, CodecPcmU32LePlanar, CodecPcmU32BePlanar,
    CodecPcmU24LePlanar, CodecPcmU24BePlanar, CodecPcmU16LePlanar,
    CodecPcmU16BePlanar, CodecPcmU8Planar, CodecPcmF32LePlanar,
    CodecPcmF32BePlanar, CodecPcmF64LePlanar, CodecPcmF64BePlanar,
  ]

proc sampleFormatOf*(id: AudioCodecId): SampleFormat =
  if id == CodecPcmS32Le or id == CodecPcmS32Be:
    sfS32
  elif id == CodecPcmS24Le or id == CodecPcmS24Be:
    sfS24
  elif id == CodecPcmS16Le or id == CodecPcmS16Be or id == CodecPcmALaw or
      id == CodecPcmMuLaw:
    sfS16
  elif id == CodecPcmS8:
    sfS8
  elif id == CodecPcmU32Le or id == CodecPcmU32Be:
    sfU32
  elif id == CodecPcmU24Le or id == CodecPcmU24Be:
    sfU24
  elif id == CodecPcmU16Le or id == CodecPcmU16Be:
    sfU16
  elif id == CodecPcmU8:
    sfU8
  elif id == CodecPcmF32Le or id == CodecPcmF32Be:
    sfF32
  elif id == CodecPcmF64Le or id == CodecPcmF64Be:
    sfF64
  else:
    raise unsupportedError("not a PCM codec: " & $id)

proc isBigEndian*(id: AudioCodecId): bool =
  id in [
    CodecPcmS32Be, CodecPcmS24Be, CodecPcmS16Be, CodecPcmU32Be,
    CodecPcmU24Be, CodecPcmU16Be, CodecPcmF32Be, CodecPcmF64Be,
  ]

type
  PcmDecoder* = ref object of AudioDecoder
    params*: AudioCodecParameters
    shift*: int
    bytesPerFrame*: int
    buf*: AudioSamples

proc bytesPerCodedSample(id: AudioCodecId): int =
  ## Coded bytes per sample: A-law/mu-law pack to one byte despite
  ## decoding to 16-bit samples.
  if id == CodecPcmALaw or id == CodecPcmMuLaw:
    1
  else:
    case sampleFormatOf(id)
    of sfS32, sfU32, sfF32: 4
    of sfS24, sfU24: 3
    of sfS16, sfU16: 2
    of sfS8, sfU8: 1
    of sfF64: 8

proc newPcmDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): PcmDecoder =
  ## Validates params exactly like `PcmDecoder::try_new`.
  if not isSupportedPcmCodec(params.codec):
    raise unsupportedError("pcm: invalid codec")
  if params.sampleRate.isNone:
    raise unsupportedError("pcm: sample rate is required")
  if params.channels.isNone:
    raise unsupportedError("pcm: channels or channel_layout is required")
  let nch = params.channels.get.channelCount()
  if nch < 1:
    raise unsupportedError("pcm: number of channels cannot be 0")
  let fmt = sampleFormatOf(params.codec)
  let fmtWidth = sampleWidthBits(fmt).uint32
  if params.bitsPerCodedSample.isSome and
      params.bitsPerCodedSample.get > fmtWidth:
    raise decodeError("pcm: bits per coded sample greater-than sample format")
  if params.bitsPerSample.isSome and params.bitsPerSample.get > fmtWidth:
    raise decodeError("pcm: bits per sample is greater-than sample format")
  if params.bitsPerSample.isSome and params.bitsPerCodedSample.isSome and
      params.bitsPerCodedSample.get > params.bitsPerSample.get:
    raise decodeError("pcm: bits per coded sample greater-than bits per sample")
  let decodedWidth = params.bitsPerSample.get(fmtWidth)
  let codedWidth = params.bitsPerCodedSample.get(decodedWidth)
  if params.codec == CodecPcmF32Le or params.codec == CodecPcmF32Be or
      params.codec == CodecPcmF64Le or params.codec == CodecPcmF64Be or
      params.codec == CodecPcmALaw or params.codec == CodecPcmMuLaw:
    if decodedWidth != fmtWidth:
      raise decodeError("pcm: unexpected bits per sample")
    if codedWidth != fmtWidth:
      raise decodeError("pcm: unexpected bits per coded sample")
  let shift = (decodedWidth - codedWidth).int
  let spec = newAudioSpec(params.sampleRate.get, params.channels.get)
  # Clamp pre-allocation against hostile maxFramesPerPacket (DoS safety).
  let capacity =
    if params.maxFramesPerPacket.isSome:
      min(params.maxFramesPerPacket.get, 4_194_304'u64).int
    else:
      0
  result = PcmDecoder(
    params: params,
    shift: shift,
    bytesPerFrame: bytesPerCodedSample(params.codec) * nch,
    buf: newAudioSamples(fmt, spec, capacity),
  )

proc decodeFramesFrom[R](d: PcmDecoder; r: var R; nFrames: int) =
  ## Decode core shared by the owning (`Reader`) and zero-copy
  ## (`ViewReader`) paths. `R` only needs the `io` primitive set.
  let nch = d.buf.specOf().channels.channelCount()
  let sh = d.shift
  let codec = d.params.codec
  if codec == CodecPcmALaw:
    d.buf.s16.renderWith(nFrames, i):
      for p in 0 ..< nch: d.buf.s16.planes[p][i] = alawToLinear(r.readByte())
  elif codec == CodecPcmMuLaw:
    d.buf.s16.renderWith(nFrames, i):
      for p in 0 ..< nch: d.buf.s16.planes[p][i] = mulawToLinear(r.readByte())
  else:
    let be = isBigEndian(codec)
    case sampleFormatOf(codec)
    of sfS32:
      d.buf.s32.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.s32.planes[p][i] =
            if be: cast[int32](r.readI32Be().int32 shl sh)
            else: cast[int32](r.readI32Le().int32 shl sh)
    of sfS24:
      d.buf.s24.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.s24.planes[p][i] =
            if be: r.readI24Be() shl sh else: r.readI24Le() shl sh
    of sfS16:
      d.buf.s16.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.s16.planes[p][i] =
            if be: cast[int16](r.readI16Be().int32 shl sh)
            else: cast[int16](r.readI16Le().int32 shl sh)
    of sfS8:
      d.buf.s8.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.s8.planes[p][i] = cast[int8](r.readByte().int32 shl sh)
    of sfU32:
      d.buf.u32.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.u32.planes[p][i] =
            if be: r.readU32Be() shl sh else: r.readU32Le() shl sh
    of sfU24:
      d.buf.u24.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.u24.planes[p][i] =
            if be: clampU24(r.readU24Be() shl sh)
            else: clampU24(r.readU24Le() shl sh)
    of sfU16:
      d.buf.u16.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.u16.planes[p][i] =
            if be: cast[uint16](r.readU16Be().uint32 shl sh)
            else: cast[uint16](r.readU16Le().uint32 shl sh)
    of sfU8:
      d.buf.u8.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.u8.planes[p][i] = cast[uint8](r.readByte().uint32 shl sh)
    of sfF32:
      d.buf.f32.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.f32.planes[p][i] = (if be: r.readF32Be() else: r.readF32Le())
    of sfF64:
      d.buf.f64.renderWith(nFrames, i):
        for p in 0 ..< nch:
          d.buf.f64.planes[p][i] = (if be: r.readF64Be() else: r.readF64Le())

method codecParams*(d: PcmDecoder): AudioCodecParameters = d.params

method reset*(d: PcmDecoder) =
  ## No inter-packet state: nothing to do.
  discard

proc decodeFrames(d: PcmDecoder; data: seq[uint8]) =
  ## Owning decode: copies nothing itself, but `data` is an owned packet.
  checkDecode(d.bytesPerFrame > 0, "pcm: invalid frame size")
  var r = newReader(data)
  d.decodeFramesFrom(r, data.len div d.bytesPerFrame)

proc decodePcmView*(d: PcmDecoder; src: MappedSource; off, len: int) =
  ## Zero-copy decode straight from a mapping window. No packet `seq` is
  ## allocated; output still reuses the decoder's internal buffer.
  checkDecode(d.bytesPerFrame > 0, "pcm: invalid frame size")
  var vr = viewReader(src, off, len)
  try:
    d.decodeFramesFrom(vr, len div d.bytesPerFrame)
  except AudioError as e:
    d.buf.clearSamples()
    raise e

method decodePacket*(d: PcmDecoder; pkt: Packet): AudioSamples =
  try:
    d.decodeFrames(pkt.data)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  d.buf

proc decodePacketView*(d: PcmDecoder; v: PacketView): AudioSamples =
  ## View-based `decodePacket`: identical output, no packet copy.
  d.decodePcmView(v.src, v.off, v.len)
  d.buf

method lastDecoded*(d: PcmDecoder): AudioSamples = d.buf

proc pcmDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newPcmDecoder(params, opts)

proc registerPcm*() =
  ## Registers all 20 interleaved PCM variants.
  for id in [
    CodecPcmS32Le, CodecPcmS32Be, CodecPcmS24Le, CodecPcmS24Be,
    CodecPcmS16Le, CodecPcmS16Be, CodecPcmS8, CodecPcmU32Le,
    CodecPcmU32Be, CodecPcmU24Le, CodecPcmU24Be, CodecPcmU16Le,
    CodecPcmU16Be, CodecPcmU8, CodecPcmF32Le, CodecPcmF32Be,
    CodecPcmF64Le, CodecPcmF64Be, CodecPcmALaw, CodecPcmMuLaw,
  ]:
    registerAudioDecoder(id, pcmDecoderFactory)

# ------------------------------------------------------------- Encoder ---

proc encodePcm*(buf: AudioSamples; codec: AudioCodecId): seq[uint8] =
  ## Encodes planar samples to one interleaved packet body (new work, no
  ## Symphonia equivalent). Buffers always hold full-width values, matching
  ## what the decoder produces.
  if sampleFormatOf(codec) != buf.format and
      not (codec == CodecPcmALaw or codec == CodecPcmMuLaw):
    raise unsupportedError("pcm: buffer format does not match codec")
  var w = newWriter()
  let n = buf.framesOf()
  if codec == CodecPcmALaw or codec == CodecPcmMuLaw:
    let toLaw =
      if codec == CodecPcmALaw: linearToALaw else: linearToMuLaw
    for i in 0 ..< n:
      for p in 0 ..< buf.s16.planes.len:
        w.writeByte(toLaw(buf.s16.planes[p][i]))
    return w.toBytes()
  let be = isBigEndian(codec)
  case buf.format
  of sfS16:
    for i in 0 ..< n:
      for p in 0 ..< buf.s16.planes.len:
        let v = buf.s16.planes[p][i]
        if be: w.writeI16Be(v) else: w.writeI16Le(v)
  of sfS8:
    for i in 0 ..< n:
      for p in 0 ..< buf.s8.planes.len:
        w.writeByte(cast[uint8](buf.s8.planes[p][i]))
  of sfU8:
    for i in 0 ..< n:
      for p in 0 ..< buf.u8.planes.len: w.writeByte(buf.u8.planes[p][i])
  of sfS32:
    for i in 0 ..< n:
      for p in 0 ..< buf.s32.planes.len:
        let v = buf.s32.planes[p][i]
        if be: w.writeI32Be(v) else: w.writeI32Le(v)
  of sfS24:
    for i in 0 ..< n:
      for p in 0 ..< buf.s24.planes.len:
        let v = clampI24(buf.s24.planes[p][i]).uint32 and 0xffffff'u32
        if be: w.writeU24Be(v) else: w.writeU24Le(v)
  of sfU16:
    for i in 0 ..< n:
      for p in 0 ..< buf.u16.planes.len:
        let v = buf.u16.planes[p][i]
        if be: w.writeU16Be(v) else: w.writeU16Le(v)
  of sfU24:
    for i in 0 ..< n:
      for p in 0 ..< buf.u24.planes.len:
        let v = clampU24(buf.u24.planes[p][i])
        if be: w.writeU24Be(v) else: w.writeU24Le(v)
  of sfU32:
    for i in 0 ..< n:
      for p in 0 ..< buf.u32.planes.len:
        let v = buf.u32.planes[p][i]
        if be: w.writeU32Be(v) else: w.writeU32Le(v)
  of sfF32:
    for i in 0 ..< n:
      for p in 0 ..< buf.f32.planes.len:
        let v = buf.f32.planes[p][i]
        if be: w.writeF32Be(v) else: w.writeF32Le(v)
  of sfF64:
    for i in 0 ..< n:
      for p in 0 ..< buf.f64.planes.len:
        let v = buf.f64.planes[p][i]
        if be: w.writeF64Be(v) else: w.writeF64Le(v)
  w.toBytes()
