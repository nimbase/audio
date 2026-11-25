## AAC-LC decoder (no encoder — encoders for AAC are out of scope;
## Symphonia ships decode-only too).
##
## Ports `symphonia-codec-aac` (aac/common, mod, cpe, dsp, window,
## ics/*, codebooks; ASC from `symphonia-common` mpeg/audio):
## AudioSpecificConfig parse, SCE/CPE/LFE/DSE/FIL raw_data_block,
## ICS (sections, scalefactors, Huffman spectral, PNS, pulse, TNS),
## mid/side + intensity joint stereo, KBD/sine-windowed IMDCT
## filterbank. AAC-LC only (`samples == 1024`, `<= 2` channels);
## SBR/PS, PCE, CCE, prediction and gain-control all raise
## `ekUnsupported`/`ekDecode` as in the reference. Output is planar
## `sfF32`; bitstream is MSB-first (`LtrBitReader`).

import std/math
import std/options
import ./../audio
import ./../codecs
import ./../dsp
import ./../errors
import ./../io
import ./../packet
import ./../units
import ./aac_tables

# ------------------------------------------------- audio object types ---

type
  AacObjectType* = enum
    AotNone
    AotMain
    AotLc
    AotSsr
    AotLtp
    AotSbr
    AotScalable
    AotTwinVq
    AotCelp
    AotHvxc
    AotReserved10
    AotReserved11
    AotTtsi
    AotMainSynth
    AotWavetableSynth
    AotGeneralMidi
    AotAlgorithmic
    AotErAacLc
    AotReserved18
    AotErAacLtp
    AotErAacScalable
    AotErTwinVq
    AotErBsac
    AotErAacLd
    AotErCelp
    AotErHvxc
    AotErHiln
    AotErParametric
    AotSsc
    AotPs
    AotMpegSurround
    AotReservedEscape
    AotLayer1
    AotLayer2
    AotLayer3
    AotDst
    AotAls
    AotSls
    AotSlsNonCore
    AotErAacEld
    AotSmrSimple
    AotSmrMain
    AotUnknown

const
  Mpeg4SampleRates*: array[13, uint32] = [96000'u32, 88200, 64000,
    48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

type
  AudioSpecificConfig* = object
    objectType*: AacObjectType
    sampleRate*: uint32
    channels*: Option[Channels]
    samples*: int
    sbrPsInfo*: bool
    sbrPresent*: bool
    psPresent*: bool

proc readAacObjectType*(bs: var LtrBitReader): AacObjectType =
  let idx =
    try:
      let v = bs.readLtrBits(5)
      if v < 31: v.int
      else: (bs.readLtrBits(6) + 32).int
    except EndOfStream:
      raise decodeError("aac: truncated audio specific config")
  if idx <= ord(AotSmrMain):
    AacObjectType(idx)
  else:
    AotUnknown

proc readAacSampleRate*(bs: var LtrBitReader): uint32 =
  let idx =
    try:
      bs.readLtrBits(4).int
    except EndOfStream:
      raise decodeError("aac: truncated audio specific config")
  case idx
  of 0 .. 12:
    Mpeg4SampleRates[idx]
  of 15:
    try:
      bs.readLtrBits(24)
    except EndOfStream:
      raise decodeError("aac: truncated audio specific config")
  else:
    raise decodeError("common (mp4a): invalid sample rate")

proc aacChannelsByConfig*(idx: int): Option[Channels] =
  ## MPEG-4 channel configuration index to channel layout.
  case idx
  of 0:
    none(Channels)
  of 1:
    some(ChMono)
  of 2:
    some(ChStereo)
  of 3:
    some(Ch3)
  of 4:
    some(ChQuad)
  of 5:
    some(Ch5)
  of 6:
    some(Ch51)
  of 7:
    some(Ch71)
  else:
    raise decodeError("common (mp4a): invalid channel configuration")

proc readAudioSpecificConfig*(data: openArray[uint8]): AudioSpecificConfig =
  ## Parses an AudioSpecificConfig (ISO 14496-3) from `extra_data`.
  var bs = newLtrBitReader(data)
  var asc = AudioSpecificConfig(samples: 1024)
  asc.objectType = readAacObjectType(bs)
  asc.sampleRate = readAacSampleRate(bs)
  if asc.sampleRate == 0:
    raise decodeError("common (mp4a): a sample rate of 0 is invalid")
  try:
    let cfg = bs.readLtrBits(4).int
    asc.channels = aacChannelsByConfig(cfg)
  except EndOfStream:
    raise decodeError("aac: truncated audio specific config")
  if asc.objectType == AotSbr or asc.objectType == AotPs:
    asc.sbrPresent = true
    if asc.objectType == AotPs:
      asc.psPresent = true
    let _ = readAacSampleRate(bs)
    asc.objectType = readAacObjectType(bs)
    if asc.objectType == AotErBsac:
      try:
        discard bs.readLtrBits(4)
      except EndOfStream:
        raise decodeError("aac: truncated audio specific config")
    asc.sbrPsInfo = true
  case asc.objectType
  of AotMain, AotLc, AotSsr, AotScalable, AotTwinVq, AotErAacLc,
      AotErAacLtp, AotErAacScalable, AotErTwinVq, AotErBsac, AotErAacLd:
    try:
      let shortFrame = bs.readLtrBool()
      asc.samples = if shortFrame: 960 else: 1024
      let depends = bs.readLtrBool()
      if depends:
        discard bs.readLtrBits(14)
      let extFlag = bs.readLtrBool()
      if asc.channels.isNone:
        raise unsupportedError("common (mp4a): program config element")
      if asc.objectType == AotScalable or
          asc.objectType == AotErAacScalable:
        discard bs.readLtrBits(3)
      if extFlag:
        if asc.objectType == AotErBsac:
          discard bs.readLtrBits(5)
          discard bs.readLtrBits(11)
        if asc.objectType in {AotErAacLc, AotErAacLtp, AotErAacScalable,
            AotErAacLd}:
          discard bs.readLtrBool()
          discard bs.readLtrBool()
          discard bs.readLtrBool()
        if bs.readLtrBool():
          raise unsupportedError("common (mp4a): version3 extensions")
    except EndOfStream:
      raise decodeError("aac: truncated audio specific config")
  of AotCelp:
    raise unsupportedError("common (mp4a): CELP config")
  of AotHvxc:
    raise unsupportedError("common (mp4a): HVXC config")
  of AotTtsi:
    raise unsupportedError("common (mp4a): TTS config")
  of AotMainSynth, AotWavetableSynth, AotGeneralMidi, AotAlgorithmic:
    raise unsupportedError("common (mp4a): structured audio config")
  of AotErCelp:
    raise unsupportedError("common (mp4a): ER CELP config")
  of AotErHvxc:
    raise unsupportedError("common (mp4a): ER HVXC config")
  of AotErHiln, AotErParametric:
    raise unsupportedError("common (mp4a): parametric config")
  of AotSsc:
    raise unsupportedError("common (mp4a): SSC config")
  of AotMpegSurround:
    raise unsupportedError("common (mp4a): MPEG Surround config")
  of AotLayer1, AotLayer2, AotLayer3:
    raise unsupportedError("common (mp4a): MPEG Layer 1/2/3 config")
  of AotDst:
    raise unsupportedError("common (mp4a): DST config")
  of AotAls:
    raise unsupportedError("common (mp4a): ALS config")
  of AotSls, AotSlsNonCore:
    raise unsupportedError("common (mp4a): SLS config")
  of AotErAacEld:
    raise unsupportedError("common (mp4a): ELD config")
  of AotSmrSimple, AotSmrMain:
    raise unsupportedError("common (mp4a): symbolic music config")
  else:
    discard
  case asc.objectType
  of AotErAacLc, AotErAacLtp, AotErAacScalable, AotErTwinVq, AotErBsac,
      AotErAacLd, AotErCelp, AotErHvxc, AotErHiln, AotErParametric,
      AotErAacEld:
    try:
      let ep = bs.readLtrBits(2)
      if ep == 2 or ep == 3:
        raise unsupportedError("common (mp4a): error protection config")
    except EndOfStream:
      raise decodeError("aac: truncated audio specific config")
  else:
    discard
  if asc.sbrPsInfo and bs.bitsLeft() >= 16:
    try:
      if bs.readLtrBits(11) == 0x2b7:
        let ext = readAacObjectType(bs)
        if ext == AotSbr:
          asc.sbrPresent = bs.readLtrBool()
          if asc.sbrPresent:
            discard readAacSampleRate(bs)
            if bs.bitsLeft() >= 12:
              if bs.readLtrBits(11) == 0x548:
                asc.psPresent = bs.readLtrBool()
        if ext == AotPs:
          asc.sbrPresent = bs.readLtrBool()
          if asc.sbrPresent:
            discard readAacSampleRate(bs)
          discard bs.readLtrBits(4)
    except EndOfStream:
      raise decodeError("aac: truncated audio specific config")
  asc

proc aacProfileOf*(asc: AudioSpecificConfig): string =
  ## Profile label for metadata (LC/HE/HEv2/Main/SSR/LTP).
  case asc.objectType
  of AotMain:
    "aac-main"
  of AotSsr:
    "aac-ssr"
  of AotLtp:
    "aac-ltp"
  of AotLc:
    if asc.psPresent: "aac-he-v2"
    elif asc.sbrPresent: "aac-he"
    else: "aac-lc"
  else:
    "aac-unknown"

# ------------------------------------------------------- tables/dsp ---

const
  OnlyLongSeq* = 0
  LongStartSeq* = 1
  EightShortSeq* = 2
  LongStopSeq* = 3
  MaxWindows* = 8
  MaxSfbs* = 64
  ZeroHcb* = 0
  ReservedHcb* = 12
  NoiseHcb* = 13
  IntensityHcb2* = 14
  IntensityHcb* = 15
  TnsMaxLongBands*: array[12, int] = [31, 31, 34, 40, 42, 51, 46, 46,
    42, 42, 42, 39]
  TnsMaxShortBands*: array[12, int] = [9, 9, 10, 14, 14, 14, 14, 14,
    14, 14, 14, 14]

proc longBands*(row: int): seq[int] =
  ## Scalefactor band offsets (long) for subband row `row`.
  case AacSubbandLongSel[row]
  of 0:
    @(SwbOffset96kLong)
  of 1:
    @(SwbOffset64kLong)
  of 2:
    @(SwbOffset48kLong)
  of 3:
    @(SwbOffset32kLong)
  of 4:
    @(SwbOffset24kLong)
  of 5:
    @(SwbOffset16kLong)
  else:
    @(SwbOffset8kLong)

proc shortBands*(row: int): seq[int] =
  ## Scalefactor band offsets (short) for subband row `row`.
  case AacSubbandShortSel[row]
  of 0:
    @(SwbOffset64kShort)
  of 1:
    @(SwbOffset48kShort)
  of 2:
    @(SwbOffset24kShort)
  of 3:
    @(SwbOffset16kShort)
  else:
    @(SwbOffset8kShort)

proc subbandRow*(sampleRate: uint32): int =
  ## First row with `sampleRate >= min_srate`.
  for i in 0 ..< 12:
    if sampleRate.int >= AacSubbandMinRate[i]:
      return i
  11

var
  aacPow43: array[8192, float32]
  aacNormalScf: array[256, float32]
  aacIntensityScf: array[256, float32]
  aacQuadsVlc: array[4, VlcTable]
  aacPairsVlc: array[6, VlcTable]
  aacPairsVal: array[6, seq[array[2, float32]]]
  aacEscVlc: VlcTable
  aacEscVal: seq[array[2, uint16]]
  aacScfVlc: VlcTable
  aacTablesReady = false

proc aacIquant(v: int): float32 {.inline.} =
  pow(v.float32, 4.0 / 3.0)

proc initAacTables*() =
  if aacTablesReady:
    return
  aacTablesReady = true
  for i in 0 ..< 8192:
    aacPow43[i] = pow(i.float32, 4.0 / 3.0)
  for i in 0 ..< 256:
    aacNormalScf[i] = pow(2.0, 0.25 * (i - 156).float64).float32
    aacIntensityScf[i] = pow(0.5, 0.25 * (i - 155).float64).float32
  template grab(codes, lens: untyped): tuple[c: seq[uint32], l: seq[uint32]] =
    var cc = newSeq[uint32](codes.len)
    var ll = newSeq[uint32](lens.len)
    for i in 0 ..< codes.len:
      cc[i] = codes[i]
      ll[i] = lens[i].uint32
    (cc, ll)
  template idxVals(n: int): seq[uint32] =
    var vv = newSeq[uint32](n)
    for i in 0 ..< n:
      vv[i] = i.uint32
    vv
  for t in 0 ..< 4:
    let (cc, ll) =
      case t
      of 0: grab(AacSpectrumCodes1, AacSpectrumLens1)
      of 1: grab(AacSpectrumCodes2, AacSpectrumLens2)
      of 2: grab(AacSpectrumCodes3, AacSpectrumLens3)
      else: grab(AacSpectrumCodes4, AacSpectrumLens4)
    aacQuadsVlc[t] = buildVlcTable(cc, ll, idxVals(cc.len), 8, false)
  for t in 0 ..< 6:
    let (cc, ll) =
      case t
      of 0: grab(AacSpectrumCodes5, AacSpectrumLens5)
      of 1: grab(AacSpectrumCodes6, AacSpectrumLens6)
      of 2: grab(AacSpectrumCodes7, AacSpectrumLens7)
      of 3: grab(AacSpectrumCodes8, AacSpectrumLens8)
      of 4: grab(AacSpectrumCodes9, AacSpectrumLens9)
      else: grab(AacSpectrumCodes10, AacSpectrumLens10)
    aacPairsVlc[t] = buildVlcTable(cc, ll, idxVals(cc.len), 8, false)
    let modulus = [9, 9, 8, 8, 13, 13][t]
    var vals = newSeq[array[2, float32]](cc.len)
    for i in 0 ..< cc.len:
      let a = i div modulus
      let b = i mod modulus
      if t < 2:
        let m = modulus shr 1
        let x = if m > a: -aacIquant(m - a) else: aacIquant(a - m)
        let y = if m > b: -aacIquant(m - b) else: aacIquant(b - m)
        vals[i] = [x, y]
      else:
        vals[i] = [aacIquant(a), aacIquant(b)]
    aacPairsVal[t] = vals
  block esc:
    let (cc, ll) = grab(AacSpectrumCodes11, AacSpectrumLens11)
    aacEscVlc = buildVlcTable(cc, ll, idxVals(cc.len), 8, false)
    aacEscVal = newSeq[array[2, uint16]](cc.len)
    for i in 0 ..< cc.len:
      aacEscVal[i] = [(i div 17).uint16, (i mod 17).uint16]
  block scf:
    let (cc, ll) = grab(AacScfCodes, AacScfLens)
    aacScfVlc = buildVlcTable(cc, ll, idxVals(cc.len), 8, false)

# ------------------------------------------------------------- window ---

proc besselI0*(x: float64): float64 =
  var v = 1.0
  for n in countdown(63, 1):
    v = v * x / (n * n).float64 + 1.0
  v

proc aacWindow*(kbdAlpha: float64; size: int; dst: var openArray[float32]) =
  ## First half of a Kaiser-Bessel derived window (`half == true`).
  let dlen = size.float64
  let a2 = (kbdAlpha * PI / dlen) * (kbdAlpha * PI / dlen)
  var sum = 0.0
  for n in 0 ..< size:
    sum += besselI0((n * (size - n)).float64 * a2)
    dst[n] = sum.float32 # cumulative; normalized below
  sum += 1.0
  for n in 0 ..< size:
    dst[n] = sqrt(dst[n].float64 / sum).float32

proc sineWindow*(size: int; dst: var openArray[float32]) =
  for n in 0 ..< size:
    dst[n] = sin((n.float64 + 0.5) * PI / (2 * size).float64).float32

# ---------------------------------------------------------------- ics ---

type
  AacLcg* = object
    state*: uint32

proc lcgNext*(g: var AacLcg): int32 {.inline.} =
  g.state = g.state * 1664525'u32 + 1013904223'u32
  cast[int32](g.state)

type
  IcsInfo* = object
    windowSeq*: int
    prevWindowSeq*: int
    windowShape*: bool
    prevWindowShape*: bool
    grouping*: array[8, bool]
    groupStart*: array[8, int]
    windowGroups*: int
    numWindows*: int
    maxSfb*: int
    longWin*: bool

  TnsCoeffs* = object
    length*: int
    order*: int
    direction*: bool
    coef*: array[21, float32]

  Tns* = object
    present*: bool
    nFilt*: array[8, int]
    filt*: array[8, array[4, TnsCoeffs]]

  Pulse* = object
    present*: bool
    number*: int
    startSfb*: int
    offset*: array[4, int]
    amp*: array[4, int]

  Ics* = object
    globalGain*: int
    info*: IcsInfo
    pulse*: Pulse
    tns*: Tns
    sectCb*: array[8, array[64, int]]
    sfbCb*: array[8, array[64, int]]
    scales*: array[8, array[64, float32]]
    coeffs*: array[1024, float32]
    delay*: array[1024, float32]

proc defaultIcsInfo*(): IcsInfo =
  IcsInfo(windowSeq: 0, prevWindowSeq: 0, windowShape: false,
    prevWindowShape: false, grouping: default(array[8, bool]),
    groupStart: default(array[8, int]), windowGroups: 0, numWindows: 0,
    maxSfb: 0, longWin: true)

proc resetIcs*(c: var Ics) =
  c.info = defaultIcsInfo()
  for i in 0 ..< 1024:
    c.delay[i] = 0.0

proc decodeIcsInfo*(bs: var LtrBitReader; info: var IcsInfo) =
  info.prevWindowSeq = info.windowSeq
  info.prevWindowShape = info.windowShape
  try:
    if bs.readLtrBool():
      raise decodeError("aac: ics reserved bit set")
    info.windowSeq = bs.readLtrBits(2).int
    info.windowShape = bs.readLtrBool()
  except EndOfStream:
    raise decodeError("aac: truncated ics info")
  info.windowGroups = 1
  if info.windowSeq == EightShortSeq:
    info.longWin = false
    info.numWindows = 8
    try:
      info.maxSfb = bs.readLtrBits(4).int
      for i in 0 ..< MaxWindows - 1:
        info.grouping[i] = bs.readLtrBool()
        if not info.grouping[i]:
          info.groupStart[info.windowGroups] = i + 1
          inc info.windowGroups
    except EndOfStream:
      raise decodeError("aac: truncated ics info")
  else:
    info.longWin = true
    info.numWindows = 1
    try:
      info.maxSfb = bs.readLtrBits(6).int
      # LTP / predictor data: AAC-LC streams must have 0 here.
      if bs.readLtrBool():
        raise unsupportedError("aac: predictor data")
    except EndOfStream:
      raise decodeError("aac: truncated ics info")
    except AudioError:
      raise

proc groupStartOf*(info: IcsInfo; g: int): int =
  if g == 0:
    0
  elif g >= info.windowGroups:
    if info.longWin: 1 else: 8
  else:
    info.groupStart[g]

proc decodeIcsInfoChecked(bs: var LtrBitReader; bands: openArray[int];
    info: var IcsInfo) =
  decodeIcsInfo(bs, info)
  if info.maxSfb + 1 > bands.len:
    raise decodeError("aac: ics info max_sfb is too big for the bands size")

proc decodeSectionData*(bs: var LtrBitReader; c: var Ics) =
  let sectBits = if c.info.longWin: 5 else: 3
  let escVal = (1 shl sectBits) - 1
  for g in 0 ..< c.info.windowGroups:
    var k = 0
    var l = 0
    while k < c.info.maxSfb:
      if l >= MaxSfbs:
        raise decodeError("aac: invalid data")
      var cb = 0
      try:
        cb = bs.readLtrBits(4).int
      except EndOfStream:
        raise decodeError("aac: truncated section data")
      if cb == ReservedHcb:
        raise decodeError("aac: invalid band type")
      var secLen = 0
      while true:
        var incr = 0
        try:
          incr = bs.readLtrBits(sectBits).int
        except EndOfStream:
          raise decodeError("aac: truncated section data")
        secLen += incr
        if incr < escVal:
          break
      if k + secLen > c.info.maxSfb:
        raise decodeError("aac: invalid data")
      c.sectCb[g][l] = cb
      for sfb in k ..< k + secLen:
        c.sfbCb[g][sfb] = cb
      k += secLen
      inc l

proc decodeScaleFactorData*(bs: var LtrBitReader; c: var Ics) =
  var noisePcm = true
  var scfIntensity = 155
  var scfNoise = c.globalGain - 90 + 100
  var scfNormal = c.globalGain
  for g in 0 ..< c.info.windowGroups:
    for sfb in 0 ..< c.info.maxSfb:
      let cb = c.sfbCb[g][sfb]
      if cb == ZeroHcb:
        c.scales[g][sfb] = 0.0
      elif cb == IntensityHcb or cb == IntensityHcb2:
        try:
          scfIntensity += bs.readLtrVlc(aacScfVlc).value.int - 60
        except EndOfStream:
          raise decodeError("aac: truncated scalefactors")
        if scfIntensity < 0 or scfIntensity >= 256:
          raise decodeError("aac: invalid data")
        c.scales[g][sfb] = aacIntensityScf[scfIntensity]
      elif cb == NoiseHcb:
        if noisePcm:
          noisePcm = false
          try:
            scfNoise += bs.readLtrBits(9).int - 256
          except EndOfStream:
            raise decodeError("aac: truncated scalefactors")
        else:
          try:
            scfNoise += bs.readLtrVlc(aacScfVlc).value.int - 60
          except EndOfStream:
            raise decodeError("aac: truncated scalefactors")
        if scfNoise < 0 or scfNoise >= 256:
          raise decodeError("aac: invalid data")
        c.scales[g][sfb] = aacNormalScf[scfNoise]
      else:
        try:
          scfNormal += bs.readLtrVlc(aacScfVlc).value.int - 60
        except EndOfStream:
          raise decodeError("aac: truncated scalefactors")
        if scfNormal < 0 or scfNormal >= 256:
          raise decodeError("aac: invalid data")
        c.scales[g][sfb] = aacNormalScf[scfNormal]

# ------------------------------------------------------- spectrum ---

proc aacDecodeSign(v: uint32): float32 {.inline.} =
  1.0 - 2.0 * v.float32

proc decodeNoise*(g: var AacLcg; scale: float32;
    dst: var openArray[float32]) =
  var energy = 0.0'f32
  for i in 0 ..< dst.len:
    dst[i] = lcgNext(g).float32
    energy += dst[i] * dst[i]
  let k = scale / sqrt(energy)
  for i in 0 ..< dst.len:
    dst[i] *= k

proc readAacEscape*(bs: var LtrBitReader): int =
  var n = 0
  try:
    n = bs.readLtrUnaryOnes()
  except EndOfStream:
    raise decodeError("aac: truncated escape")
  if n >= 9:
    raise decodeError("aac: invalid data")
  try:
    (1 shl (n + 4)) + bs.readLtrBits(n + 4).int
  except EndOfStream:
    raise decodeError("aac: truncated escape")

proc decodeQuadsSigned*(bs: var LtrBitReader; cb: VlcTable; scale: float32;
    dst: var openArray[float32]) =
  let lut = [-scale, 0.0'f32, scale]
  var i = 0
  while i < dst.len:
    var q = 0
    try:
      q = bs.readLtrVlc(cb).value.int
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    dst[i + 0] = lut[q div 27]
    dst[i + 1] = lut[(q div 9) mod 3]
    dst[i + 2] = lut[(q div 3) mod 3]
    dst[i + 3] = lut[q mod 3]
    i += 4

proc decodeQuadsUnsigned*(bs: var LtrBitReader; cb: VlcTable;
    scale: float32; dst: var openArray[float32]) =
  let lut = [0.0'f32, scale, 2.51984209978974632953'f32 * scale]
  var i = 0
  while i < dst.len:
    var q = 0
    try:
      q = bs.readLtrVlc(cb).value.int
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    let a = q div 27
    let b = (q div 9) mod 3
    let c = (q div 3) mod 3
    let d = q mod 3
    try:
      if a != 0:
        dst[i + 0] = aacDecodeSign(bs.readLtrBits(1)) * lut[a]
      if b != 0:
        dst[i + 1] = aacDecodeSign(bs.readLtrBits(1)) * lut[b]
      if c != 0:
        dst[i + 2] = aacDecodeSign(bs.readLtrBits(1)) * lut[c]
      if d != 0:
        dst[i + 3] = aacDecodeSign(bs.readLtrBits(1)) * lut[d]
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    i += 4

proc decodePairsSigned*(bs: var LtrBitReader; t: int; scale: float32;
    dst: var openArray[float32]) =
  var i = 0
  while i < dst.len:
    var q = 0
    try:
      q = bs.readLtrVlc(aacPairsVlc[t]).value.int
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    dst[i + 0] = aacPairsVal[t][q][0] * scale
    dst[i + 1] = aacPairsVal[t][q][1] * scale
    i += 2

proc decodePairsUnsigned*(bs: var LtrBitReader; t: int; scale: float32;
    dst: var openArray[float32]) =
  var i = 0
  while i < dst.len:
    var q = 0
    try:
      q = bs.readLtrVlc(aacPairsVlc[t]).value.int
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    let (x, y) = (aacPairsVal[t][q][0], aacPairsVal[t][q][1])
    try:
      let sx = if x != 0.0: aacDecodeSign(bs.readLtrBits(1)) else: 1.0
      let sy = if y != 0.0: aacDecodeSign(bs.readLtrBits(1)) else: 1.0
      dst[i + 0] = sx * x * scale
      dst[i + 1] = sy * y * scale
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    i += 2

proc decodePairsEscape*(bs: var LtrBitReader; scale: float32;
    dst: var openArray[float32]) =
  var i = 0
  while i < dst.len:
    var q = 0
    try:
      q = bs.readLtrVlc(aacEscVlc).value.int
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    var a = aacEscVal[q][0].int
    var b = aacEscVal[q][1].int
    try:
      let sx = if a != 0: aacDecodeSign(bs.readLtrBits(1)) else: 1.0
      let sy = if b != 0: aacDecodeSign(bs.readLtrBits(1)) else: 1.0
      if a == 16:
        a = readAacEscape(bs)
      if b == 16:
        b = readAacEscape(bs)
      dst[i + 0] = sx * aacPow43[a] * scale
      dst[i + 1] = sy * aacPow43[b] * scale
    except EndOfStream:
      raise decodeError("aac: truncated spectrum")
    i += 2

proc decodeSpectrum*(bs: var LtrBitReader; g: var AacLcg; c: var Ics;
    bands: openArray[int]) =
  for i in 0 ..< 1024:
    c.coeffs[i] = 0.0
  for gr in 0 ..< c.info.windowGroups:
    let curW = groupStartOf(c.info, gr)
    let nextW = groupStartOf(c.info, gr + 1)
    for sfb in 0 ..< c.info.maxSfb:
      let s = bands[sfb]
      let e = bands[sfb + 1]
      let cb = c.sfbCb[gr][sfb]
      let scale = c.scales[gr][sfb]
      for w in curW ..< nextW:
        let base = s + w * 128
        let width = e - s
        case cb
        of ZeroHcb, ReservedHcb, IntensityHcb2, IntensityHcb:
          discard
        of NoiseHcb:
          decodeNoise(g, scale, c.coeffs.toOpenArray(base, base + width - 1))
        of 1, 2:
          decodeQuadsSigned(bs, aacQuadsVlc[cb - 1], scale,
            c.coeffs.toOpenArray(base, base + width - 1))
        of 3, 4:
          decodeQuadsUnsigned(bs, aacQuadsVlc[cb - 1], scale,
            c.coeffs.toOpenArray(base, base + width - 1))
        of 5, 6:
          decodePairsSigned(bs, cb - 5, scale,
            c.coeffs.toOpenArray(base, base + width - 1))
        of 7, 8, 9, 10:
          decodePairsUnsigned(bs, cb - 5, scale,
            c.coeffs.toOpenArray(base, base + width - 1))
        of 11:
          decodePairsEscape(bs, scale,
            c.coeffs.toOpenArray(base, base + width - 1))
        else:
          raise decodeError("aac: invalid data")

# ------------------------------------------------------------ tns ---

proc decodeTnsData(bs: var LtrBitReader; c: var Ics) =
  c.tns.present = false
  for w in 0 ..< 8:
    c.tns.nFilt[w] = 0
  try:
    if not bs.readLtrBool():
      return
  except EndOfStream:
    raise decodeError("aac: truncated tns data")
  c.tns.present = true
  let maxOrder = if not c.info.longWin: 7 else: 12
  try:
    for w in 0 ..< c.info.numWindows:
      c.tns.nFilt[w] =
        bs.readLtrBits(if c.info.longWin: 2 else: 1).int
      let coefRes = c.tns.nFilt[w] != 0 and bs.readLtrBool()
      for f in 0 ..< c.tns.nFilt[w]:
        var tc = TnsCoeffs()
        tc.length = bs.readLtrBits(if c.info.longWin: 6 else: 4).int
        tc.order = bs.readLtrBits(if c.info.longWin: 5 else: 3).int
        if tc.order > maxOrder:
          raise decodeError("aac: invalid data")
        if tc.order > 0:
          tc.direction = bs.readLtrBool()
          let compress = bs.readLtrBool()
          var resBits = (if coefRes: 4 else: 3) - (if compress: 1 else: 0)
          let signMask = 1 shl (resBits - 1)
          let negMask = not ((1 shl resBits) - 1)
          let facBase = if coefRes: 8.0 else: 4.0
          let iqfac = (facBase - 0.5) / (PI / 2.0)
          let iqfacM = (facBase + 0.5) / (PI / 2.0)
          var tmp: array[20, float32]
          for i in 0 ..< tc.order:
            let v = bs.readLtrBits(resBits).int
            let sv =
              if (v and signMask) != 0: (v or negMask)
              else: v
            # Sign-extend through int8 range (resBits <= 4).
            let cv =
              if sv >= 128: (sv - 256).float32
              else: sv.float32
            tmp[i] =
              if cv >= 0.0: sin(cv / iqfac).float32
              else: sin(cv / iqfacM).float32
          var b: array[21, float32]
          for m in 1 .. tc.order:
            for i in 1 ..< m:
              b[i] = tc.coef[i - 1] + tmp[m - 1] * tc.coef[m - i - 1]
            for i in 0 ..< m - 1:
              tc.coef[i] = b[i + 1]
            tc.coef[m - 1] = tmp[m - 1]
        c.tns.filt[w][f] = tc
  except EndOfStream:
    raise decodeError("aac: truncated tns data")

proc tnsSynth*(c: Ics; bands: openArray[int]; rateIdx: int;
    coeffs: var openArray[float32]) =
  if not c.tns.present:
    return
  let maxBands =
    min(if c.info.longWin: TnsMaxLongBands[rateIdx]
      else: TnsMaxShortBands[rateIdx], c.info.maxSfb)
  for w in 0 ..< c.info.numWindows:
    var bottom = bands.len - 1
    for f in 0 ..< c.tns.nFilt[w]:
      let top = bottom
      bottom = max(0, top - c.tns.filt[w][f].length)
      let order = c.tns.filt[w][f].order
      if order == 0:
        continue
      let s = w * 128 + bands[min(bottom, maxBands)]
      let e = w * 128 + bands[min(top, maxBands)]
      let lpc = c.tns.filt[w][f].coef
      if not c.tns.filt[w][f].direction:
        var m = 0
        for i in s ..< e:
          for j in 0 ..< min(order, m):
            coeffs[i] -= coeffs[i - j - 1] * lpc[j]
          inc m
      else:
        var m = 0
        for i in countdown(e - 1, s):
          for j in 0 ..< min(order, m):
            coeffs[i] -= coeffs[i + j + 1] * lpc[j]
          inc m

proc decodeIcs*(bs: var LtrBitReader; g: var AacLcg; c: var Ics;
    row: int; commonWindow: bool) =
  let longB = longBands(row)
  let shortB = shortBands(row)
  try:
    c.globalGain = bs.readLtrBits(8).int
  except EndOfStream:
    raise decodeError("aac: truncated ics")
  if not commonWindow:
    # NOTE: decode_info() alone skips the max_sfb validation; it is
    # checked against the *new* window type below (as in the reference).
    decodeIcsInfo(bs, c.info)
    let postBands = if c.info.longWin: longB else: shortB
    if c.info.maxSfb + 1 > postBands.len:
      raise decodeError("aac: ics info max_sfb is too big for the bands size")
  decodeSectionData(bs, c)
  decodeScaleFactorData(bs, c)
  try:
    c.pulse.present = bs.readLtrBool()
    if c.pulse.present:
      c.pulse.number = bs.readLtrBits(2).int + 1
      c.pulse.startSfb = bs.readLtrBits(6).int
      for i in 0 ..< c.pulse.number:
        c.pulse.offset[i] = bs.readLtrBits(5).int
        c.pulse.amp[i] = bs.readLtrBits(4).int
  except EndOfStream:
    raise decodeError("aac: truncated pulse data")
  if c.pulse.present and not c.info.longWin:
    raise decodeError("aac: invalid data")
  decodeTnsData(bs, c)
  try:
    if bs.readLtrBool():
      raise unsupportedError("aac: gain control data")
  except EndOfStream:
    raise decodeError("aac: truncated ics")
  let specBands = if c.info.longWin: longB else: shortB
  decodeSpectrum(bs, g, c, specBands)

# ---------------------------------------------------------- pulse ---

proc pulseIquant(v: float32): float32 {.inline.} =
  if v < 0.0: -pow(-v.float64, 4.0 / 3.0).float32
  else: pow(v.float64, 4.0 / 3.0).float32

proc pulseRequant(v, scale: float32): float32 {.inline.} =
  if scale == 0.0:
    return 0.0
  let b = v / scale
  if b >= 0.0: pow(v.float64, 3.0 / 4.0).float32
  else: -pow(-v.float64, 3.0 / 4.0).float32

proc pulseSynth*(p: Pulse; bands: openArray[int];
    scales: array[8, array[64, float32]]; coeffs: var openArray[float32]) =
  if not p.present:
    return
  if p.startSfb >= bands.len - 1:
    return
  var k = bands[p.startSfb]
  var band = p.startSfb
  for n in 0 ..< p.number:
    k += p.offset[n]
    if k >= 1024:
      return
    while bands[band + 1] <= k:
      inc band
    let scale = scales[0][band]
    var base = coeffs[k]
    if base != 0.0:
      base = pulseRequant(coeffs[k], scale)
    if base > 0.0:
      base += p.amp[n].float32
    else:
      base -= p.amp[n].float32
    coeffs[k] = pulseIquant(base) * scale

# ------------------------------------------------------ filterbank ---

type
  AacDsp* = object
    kbdLong*: array[1024, float32]
    kbdShort*: array[128, float32]
    sineLong*: array[1024, float32]
    sineShort*: array[128, float32]
    imdctLong*: Imdct
    imdctShort*: Imdct

proc newAacDsp*(): AacDsp =
  result.imdctLong = newImdct(1024, 1.0 / 2048.0)
  result.imdctShort = newImdct(128, 1.0 / 256.0)
  aacWindow(4.0, 1024, result.kbdLong)
  aacWindow(6.0, 128, result.kbdShort)
  sineWindow(1024, result.sineLong)
  sineWindow(128, result.sineShort)

proc dspSynth*(d: var AacDsp; coeffs: array[1024, float32];
    delay: var array[1024, float32]; seq: int; shape, prevShape: bool;
    dst: var openArray[float32]) =
  ## Overlap-add IMDCT filterbank: 1024 coeffs in, 1024 samples out.
  const P0 = 512 - 64
  const P1 = 512 + 64
  let longWin: array[1024, float32] =
    if shape: d.kbdLong
    else: d.sineLong
  let shortWin: array[128, float32] =
    if shape: d.kbdShort
    else: d.sineShort
  let prevLong: array[1024, float32] =
    if prevShape: d.kbdLong
    else: d.sineLong
  let prevShort: array[128, float32] =
    if prevShape: d.kbdShort
    else: d.sineShort
  var pcmLong = newSeq[float32](2048)
  var pcmShort = newSeq[float32](1152)
  if seq != EightShortSeq:
    d.imdctLong.imdct(coeffs, pcmLong)
  else:
    for w in 0 ..< 8:
      var segOut = newSeq[float32](256)
      d.imdctShort.imdct(coeffs.toOpenArray(w * 128, w * 128 + 127),
        segOut)
      for i in 0 ..< 256:
        pcmLong[w * 256 + i] = segOut[i]
    for i in 0 ..< 1152:
      pcmShort[i] = 0.0
    for w in 0 ..< 8:
      if w > 0:
        for i in 0 ..< 128:
          pcmShort[w * 128 + i] += pcmLong[w * 256 + i] * shortWin[i]
          pcmShort[w * 128 + i + 128] +=
            pcmLong[w * 256 + i + 128] * shortWin[127 - i]
      else:
        for i in 0 ..< 128:
          pcmShort[i] = pcmLong[i] * prevShort[i]
          pcmShort[i + 128] = pcmLong[i + 128] * shortWin[127 - i]
  case seq
  of OnlyLongSeq, LongStartSeq:
    for i in 0 ..< 1024:
      dst[i] = delay[i] + pcmLong[i] * prevLong[i]
  of EightShortSeq:
    for i in 0 ..< P0:
      dst[i] = delay[i]
    for i in P0 ..< 1024:
      dst[i] = delay[i] + pcmShort[i - P0]
  of LongStopSeq:
    for i in 0 ..< P0:
      dst[i] = delay[i]
    for i in P0 ..< P1:
      dst[i] = delay[i] + pcmLong[i] * prevShort[i - P0]
    for i in P1 ..< 1024:
      dst[i] = delay[i] + pcmLong[i]
  else:
    raise decodeError("aac: invalid window sequence")
  case seq
  of OnlyLongSeq, LongStopSeq:
    for i in 0 ..< 1024:
      delay[i] = pcmLong[i + 1024] * longWin[1023 - i]
  of EightShortSeq:
    for i in 0 ..< P1:
      delay[i] = pcmShort[i + P1]
    for i in P1 ..< 1024:
      delay[i] = 0.0
  of LongStartSeq:
    for i in 0 ..< P0:
      delay[i] = pcmLong[1024 + i]
    for i in P0 ..< P1:
      delay[i] = pcmLong[i + 1024] * shortWin[127 - (i - P0)]
    for i in P1 ..< 1024:
      delay[i] = 0.0
  else:
    raise decodeError("aac: invalid window sequence")

# --------------------------------------------------- channel pair ---

type
  ChannelPair* = object
    isPair*: bool
    channel*: int
    msMask*: int
    msUsed*: array[8, array[64, bool]]
    ics0*: Ics
    ics1*: Ics
    lcg*: AacLcg

proc newChannelPair*(isPair: bool; channel: int): ChannelPair =
  ChannelPair(isPair: isPair, channel: channel, msMask: 0,
    msUsed: default(array[8, array[64, bool]]),
    lcg: AacLcg(state: 0x1f2e3d4c))

proc resetPair*(p: var ChannelPair) =
  resetIcs(p.ics0)
  resetIcs(p.ics1)

proc decodeSce*(bs: var LtrBitReader; p: var ChannelPair; row: int) =
  decodeIcs(bs, p.lcg, p.ics0, row, false)

proc decodeCpe*(bs: var LtrBitReader; p: var ChannelPair; row: int) =
  let longB = longBands(row)
  let shortB = shortBands(row)
  var commonWindow = false
  try:
    commonWindow = bs.readLtrBool()
  except EndOfStream:
    raise decodeError("aac: truncated cpe")
  if commonWindow:
    decodeIcsInfo(bs, p.ics0.info)
    let postBands = if p.ics0.info.longWin: longB else: shortB
    if p.ics0.info.maxSfb + 1 > postBands.len:
      raise decodeError("aac: ics info max_sfb is too big for the bands size")
    try:
      p.msMask = bs.readLtrBits(2).int
    except EndOfStream:
      raise decodeError("aac: truncated cpe")
    case p.msMask
    of 0, 2:
      let used = p.msMask == 2
      for g in 0 ..< p.ics0.info.windowGroups:
        for sfb in 0 ..< p.ics0.info.maxSfb:
          p.msUsed[g][sfb] = used
    of 1:
      for g in 0 ..< p.ics0.info.windowGroups:
        for sfb in 0 ..< p.ics0.info.maxSfb:
          try:
            p.msUsed[g][sfb] = bs.readLtrBool()
          except EndOfStream:
            raise decodeError("aac: truncated cpe")
    else:
      raise decodeError("aac: invalid mid-side mask")
    let prevSeq = p.ics1.info.windowSeq
    let prevShape = p.ics1.info.windowShape
    p.ics1.info = p.ics0.info
    p.ics1.info.prevWindowSeq = prevSeq
    p.ics1.info.prevWindowShape = prevShape
  decodeIcs(bs, p.lcg, p.ics0, row, commonWindow)
  decodeIcs(bs, p.lcg, p.ics1, row, commonWindow)
  if commonWindow:
    let jb = if p.ics0.info.longWin: longB else: shortB
    var g = 0
    for w in 0 ..< p.ics0.info.numWindows:
      if w > 0 and not p.ics0.info.grouping[w - 1]:
        inc g
      for sfb in 0 ..< p.ics0.info.maxSfb:
        let s = w * 128 + jb[sfb]
        let e = w * 128 + jb[sfb + 1]
        if p.ics1.sfbCb[g][sfb] == IntensityHcb or
            p.ics1.sfbCb[g][sfb] == IntensityHcb2:
          let invert = p.msMask == 1 and p.msUsed[g][sfb]
          let dir =
            if p.ics1.sfbCb[g][sfb] == IntensityHcb: 1.0 else: -1.0
          let scale = dir * (if invert: -1.0 else: 1.0) *
            p.ics1.scales[g][sfb]
          for i in s ..< e:
            p.ics1.coeffs[i] = scale * p.ics0.coeffs[i]
        elif p.ics0.sfbCb[g][sfb] == NoiseHcb or
            p.ics1.sfbCb[g][sfb] == NoiseHcb:
          discard
        elif p.msUsed[g][sfb]:
          for i in s ..< e:
            let m = p.ics0.coeffs[i]
            let sd = p.ics1.coeffs[i]
            p.ics0.coeffs[i] = m + sd
            p.ics1.coeffs[i] = m - sd

# ------------------------------------------------------- decoder ---

type
  AacDecoder* = ref object of AudioDecoder
    opts*: AudioDecoderOptions
    params*: AudioCodecParameters
    asc*: AudioSpecificConfig
    pairs*: seq[ChannelPair]
    dsp*: AacDsp
    row*: int
    spec*: AudioSpec
    buf*: AudioSamples

proc setPair(d: AacDecoder; pairNo, channel: int; isPair: bool) =
  if d.pairs.len <= pairNo:
    d.pairs.add(newChannelPair(isPair, channel))
  else:
    if d.pairs[pairNo].channel != channel or
        d.pairs[pairNo].isPair != isPair:
      raise decodeError("aac: invalid data")
  let maxCh = d.asc.channels.get.channelCount()
  if (if isPair: channel + 1 else: channel) >= maxCh:
    raise decodeError("aac: invalid data")

proc newAacDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): AacDecoder =
  if params.codec != CodecAac:
    raise unsupportedError("aac: invalid codec")
  if params.extraData.len < 2:
    raise unsupportedError("aac: extra data is required")
  initAacTables()
  let asc = readAudioSpecificConfig(params.extraData)
  let channels =
    if asc.channels.isSome: asc.channels.get
    else: raise unsupportedError("aac: channels or channel layout is required")
  if asc.objectType != AotLc or asc.sbrPresent or
      channels.channelCount() > 2 or asc.samples != 1024:
    raise unsupportedError("aac: aac too complex")
  var fixed = params
  fixed.sampleRate = some(asc.sampleRate)
  fixed.channels = some(channels)
  let spec = newAudioSpec(asc.sampleRate, channels)
  AacDecoder(opts: opts, params: fixed, asc: asc, pairs: @[],
    dsp: newAacDsp(), row: subbandRow(asc.sampleRate), spec: spec,
    buf: newAudioSamples(sfF32, spec, 1024))

proc synthPairAudio(p: var ChannelPair; dsp: var AacDsp; rateIdx: int;
    longB, shortB: seq[int]; planes: var openArray[seq[float32]]) =
  let b0 = if p.ics0.info.longWin: longB else: shortB
  pulseSynth(p.ics0.pulse, b0, p.ics0.scales, p.ics0.coeffs)
  tnsSynth(p.ics0, b0, rateIdx, p.ics0.coeffs)
  dspSynth(dsp, p.ics0.coeffs, p.ics0.delay, p.ics0.info.windowSeq,
    p.ics0.info.windowShape, p.ics0.info.prevWindowShape,
    planes[p.channel].toOpenArray(0, 1023))
  if p.isPair:
    let b1 = if p.ics1.info.longWin: longB else: shortB
    pulseSynth(p.ics1.pulse, b1, p.ics1.scales, p.ics1.coeffs)
    tnsSynth(p.ics1, b1, rateIdx, p.ics1.coeffs)
    dspSynth(dsp, p.ics1.coeffs, p.ics1.delay, p.ics1.info.windowSeq,
      p.ics1.info.windowShape, p.ics1.info.prevWindowShape,
      planes[p.channel + 1].toOpenArray(0, 1023))

proc decodeRawDataBlock(d: AacDecoder; data: seq[uint8]) =
  var bs = newLtrBitReader(data)
  var curPair = 0
  var curCh = 0
  try:
    while bs.bitsLeft() > 3:
      let id = bs.readLtrBits(3).int
      case id
      of 0: # ID_SCE
        discard bs.readLtrBits(4)
        d.setPair(curPair, curCh, false)
        decodeSce(bs, d.pairs[curPair], d.row)
        inc curPair
        inc curCh
      of 1: # ID_CPE
        discard bs.readLtrBits(4)
        d.setPair(curPair, curCh, true)
        decodeCpe(bs, d.pairs[curPair], d.row)
        inc curPair
        curCh += 2
      of 2: # ID_CCE
        raise unsupportedError("aac: coupling channel element")
      of 3: # ID_LFE
        discard bs.readLtrBits(4)
        d.setPair(curPair, curCh, false)
        decodeSce(bs, d.pairs[curPair], d.row)
        inc curPair
        inc curCh
      of 4: # ID_DSE
        discard bs.readLtrBits(4)
        let align = bs.readLtrBool()
        var count = bs.readLtrBits(8).int
        if count == 255:
          count += bs.readLtrBits(8).int
        if align:
          bs.realignLtr()
        bs.ignoreLtrBits(count * 8)
      of 5: # ID_PCE
        raise unsupportedError("aac: program config")
      of 6: # ID_FIL
        var count = bs.readLtrBits(4).int
        if count == 15:
          count += bs.readLtrBits(8).int
          dec count
        if count > 0:
          let ext = bs.readLtrBits(4)
          if ext == 0xd or ext == 0xe:
            d.asc.sbrPresent = true
          bs.ignoreLtrBits(4)
          for i in 0 ..< count - 1:
            bs.ignoreLtrBits(8)
      of 7: # ID_END
        break
      else:
        raise decodeError("aac: invalid data")
  except EndOfStream:
    raise decodeError("aac: truncated raw data block")
  let useBands = longBands(d.row)
  let useShort = shortBands(d.row)
  for p in 0 ..< curPair:
    synthPairAudio(d.pairs[p], d.dsp, d.row, useBands, useShort,
      d.buf.f32.planes)

method codecParams*(d: AacDecoder): AudioCodecParameters = d.params

method reset*(d: AacDecoder) =
  for p in d.pairs.mitems:
    resetPair(p)

method decodePacket*(d: AacDecoder; pkt: Packet): AudioSamples =
  d.buf.f32.clear()
  try:
    d.buf.f32.renderWith(1024, i):
      discard i
    d.decodeRawDataBlock(pkt.data)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  except EndOfStream:
    d.buf.clearSamples()
    raise decodeError("aac: truncated raw data block")
  except IndexDefect, RangeDefect:
    d.buf.clearSamples()
    raise decodeError("aac: invalid bitstream")
  if d.opts.gapless and d.buf.framesOf() > 0:
    let total = d.buf.framesOf()
    let dropFirst = min(pkt.trimStart.get.int, total)
    let keep = total - dropFirst
    let dropLast = min(pkt.trimEnd.get.int, keep)
    if dropFirst > 0 or dropLast > 0:
      d.buf.f32.shift(dropFirst)
      d.buf.f32.truncate(d.buf.f32.numFrames - dropLast)
  d.buf

method lastDecoded*(d: AacDecoder): AudioSamples = d.buf

proc aacDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newAacDecoder(params, opts)

proc registerAac*() =
  registerAudioDecoder(CodecAac, aacDecoderFactory)
