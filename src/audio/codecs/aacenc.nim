## AAC-LC encoder (Step C): long-only content-coding signal path.
##
## Ports the analysis choices of `oxideav-aac` (references/oxideav-aac,
## `encoder.rs`) in reduced form: sine-window forward MDCT over
## `[history | cur]`, the exact inverse §4.6.2 quantizer
## `q = round((|x| / 2^(0.25*(sf-100)))^(3/4))`, the masking-spread
## scalefactor rule (frame-peak anchored, square-root spread, cull
## below audibility), cheapest-covering Table 4.95 books 1-11 with
## greedy same-book section merging, DPCM scalefactors on the Table
## 4.A.1 Huffman book, and §4.6.3.3 escape sequences for book 11.
##
## Deliberately deferred to later steps (see plans/next-steps.md):
## rate loop (fixed sf offset 0 here), M/S + common_window joint coding
## (a CPE carries `common_window = 0`, an independent ICS pair), TNS,
## pulse, PNS, intensity, bandwidth cull, block switching (long-only
## always). Every frame self-decodes through `decodeRawDataBlock` and
## is `ffmpeg`-clean; digital silence still codes to exact zeros.
##
## Layering: this module assembles raw_data_blocks only; ADTS framing
## lives in `formats/aac.nim` (`encodeAacStream`).

import std/math
import std/options

import ./aac
import ./aac_tables
import ./../errors
import ./../io

type
  AacEncoderOptions* = object
    sampleRateHz*: uint32
    channels*: int ## 1 (SCE) or 2 (CPE, independent ICS pair).
    bitrateKbps*: int ## Reserved for the Step D rate loop; must be > 0.

  AacEncoder* = ref object
    opts*: AacEncoderOptions
    buf*: seq[int16] ## Buffered interleaved input.

const
  AacEncFrameLen* = 1024
  AacEncSfBase = 100
  AacEncTargetPeak = 42.0
  AacEncSpread = 0.5
  AacEncMinTarget = 0.7
  AacEncMaxQuant = 8191
  AacEncMaxSf = 255
  AacEncMaxSfDelta = 60

proc defaultAacEncoderOptions*(sampleRateHz: uint32; channels: int;
    bitrateKbps = 128): AacEncoderOptions =
  AacEncoderOptions(sampleRateHz: sampleRateHz, channels: channels,
    bitrateKbps: bitrateKbps)

proc newAacEncoder*(opts: AacEncoderOptions): AacEncoder =
  if opts.channels notin [1, 2]:
    raise unsupportedError("aacenc: only mono/stereo supported")
  var rateOk = false
  for r in Mpeg4SampleRates:
    if r == opts.sampleRateHz:
      rateOk = true
      break
  if not rateOk:
    raise unsupportedError("aacenc: sample rate not ADTS-signallable")
  if opts.bitrateKbps <= 0:
    raise unsupportedError("aacenc: bitrate must be positive")
  AacEncoder(opts: opts, buf: @[])

proc pushSamplesI16*(e: AacEncoder; samples: openArray[int16]) =
  ## Appends interleaved input for the next `finishEncoder` run.
  if samples.len mod e.opts.channels != 0:
    raise decodeError("aacenc: ragged input for channel count")
  for s in samples:
    e.buf.add(s)

# ---------------------------------------------------------- quantizer ---

proc encBookLav(cb: int): int =
  case cb
  of 1, 2: 1
  of 3, 4: 2
  of 5, 6: 4
  of 7, 8: 7
  of 9, 10: 12
  else: 16 # book 11 in-band LAV; escapes reach AacEncMaxQuant

proc encBookDim(cb: int): int =
  if cb <= 4: 4 else: 2

proc encBookUnsigned(cb: int): bool =
  cb in [3, 4, 7, 8, 9, 10, 11]

proc encCodeLen(cb, idx: int): int =
  ## Huffman codeword length for a Table 4.95 book + codeword index.
  case cb
  of 1: AacSpectrumLens1[idx].int
  of 2: AacSpectrumLens2[idx].int
  of 3: AacSpectrumLens3[idx].int
  of 4: AacSpectrumLens4[idx].int
  of 5: AacSpectrumLens5[idx].int
  of 6: AacSpectrumLens6[idx].int
  of 7: AacSpectrumLens7[idx].int
  of 8: AacSpectrumLens8[idx].int
  of 9: AacSpectrumLens9[idx].int
  of 10: AacSpectrumLens10[idx].int
  else: AacSpectrumLens11[idx].int

proc encCode(cb, idx: int): uint32 =
  ## Huffman codeword (MSB-first pattern, as the decoder tables hold).
  case cb
  of 1: AacSpectrumCodes1[idx]
  of 2: AacSpectrumCodes2[idx]
  of 3: AacSpectrumCodes3[idx]
  of 4: AacSpectrumCodes4[idx]
  of 5: AacSpectrumCodes5[idx]
  of 6: AacSpectrumCodes6[idx]
  of 7: AacSpectrumCodes7[idx]
  of 8: AacSpectrumCodes8[idx]
  of 9: AacSpectrumCodes9[idx]
  of 10: AacSpectrumCodes10[idx]
  else: AacSpectrumCodes11[idx]

proc encQuantize(x: float64; sf: int): int =
  ## Exact inverse of the §4.6.2 dequantizer (NINT rounding).
  let gain = pow(2.0, 0.25 * (sf - AacEncSfBase).float64)
  let m = min(pow(abs(x) / gain, 0.75), AacEncMaxQuant.float64)
  let q = floor(m + 0.5).int
  if x < 0.0: -q else: q

proc encBandSf(peak, framePeak: float64; sfOffset: int): Option[int] =
  ## Masking-spread scalefactor for one band; none when the band culls
  ## to silence (mirrors `band_scalefactor` in the reference).
  if peak <= 0.0 or framePeak <= 0.0:
    return none(int)
  let target = AacEncTargetPeak * pow(peak / framePeak, AacEncSpread)
  if target < AacEncMinTarget:
    return none(int)
  let sf = round(AacEncSfBase.float64 + 4.0 * log2(peak) -
    (16.0 / 3.0) * log2(target)).int + sfOffset
  some(clamp(sf, 0, AacEncMaxSf))

proc encEscParts(v: int): tuple[prefix, word: int] =
  ## `encode_esc_value`: `prefix = floor(log2(v)) - 4`,
  ## `word = v - 2^(prefix + 4)`. Caller guarantees 16..=8191.
  var log = 0
  var t = v
  while t > 1:
    t = t shr 1
    inc log
  let prefix = log - 4
  (prefix, v - (1 shl (prefix + 4)))

proc encTupleIndex(cb, dim: int; q: openArray[int]): int =
  ## §4.6.3.3 codeword index for an in-band tuple (ESC magnitudes
  ## pre-clamped to ±16, unsigned tuples pre-absed by the caller).
  let lav = encBookLav(cb)
  let modulus =
    if encBookUnsigned(cb): lav + 1
    else: 2 * lav + 1
  let offset =
    if encBookUnsigned(cb): 0
    else: lav
  var acc = 0
  for i in 0 ..< dim:
    acc = acc * modulus + (q[i] + offset)
  acc

proc encTupleBits(cb, dim: int; q: openArray[int]): Option[uint32] =
  ## Exact wire cost of one tuple; none when the book cannot carry it.
  for i in 0 ..< dim:
    let a = abs(q[i])
    if cb == 11:
      if a > AacEncMaxQuant:
        return none(uint32)
    elif a > encBookLav(cb):
      return none(uint32)
  var tv = newSeq[int](dim)
  for i in 0 ..< dim:
    var v = q[i]
    if cb == 11 and abs(v) >= 16:
      v = if v < 0: -16 else: 16
    if encBookUnsigned(cb):
      v = abs(v)
    tv[i] = v
  let idx = encTupleIndex(cb, dim, tv)
  var bits = encCodeLen(cb, idx).uint32
  if encBookUnsigned(cb):
    for i in 0 ..< dim:
      var v = q[i]
      if cb == 11 and abs(v) >= 16:
        v = if v < 0: -16 else: 16
      if v != 0:
        bits += 1
  if cb == 11:
    for i in 0 ..< dim:
      let a = abs(q[i])
      if a >= 16:
        let (prefix, _) = encEscParts(a)
        bits += (2 * prefix + 5).uint32
  some(bits)

proc encBandBits(cb: int; q: openArray[int]): Option[uint32] =
  let dim = encBookDim(cb)
  if q.len mod dim != 0:
    return none(uint32)
  var sum = 0'u32
  var i = 0
  while i < q.len:
    let b = encTupleBits(cb, dim, q.toOpenArray(i, i + dim - 1))
    if b.isNone:
      return none(uint32)
    sum += b.get
    i += dim
  some(sum)

proc emitTuple(w: var BitWriter; cb, dim: int; q: openArray[int]) =
  var tv = newSeq[int](dim)
  for i in 0 ..< dim:
    var v = q[i]
    if cb == 11 and abs(v) >= 16:
      v = if v < 0: -16 else: 16
    if encBookUnsigned(cb):
      v = abs(v)
    tv[i] = v
  let idx = encTupleIndex(cb, dim, tv)
  w.writeBits(encCode(cb, idx), encCodeLen(cb, idx))
  if encBookUnsigned(cb):
    for i in 0 ..< dim:
      var v = q[i]
      if cb == 11 and abs(v) >= 16:
        v = if v < 0: -16 else: 16
      if v != 0:
        w.writeBit(v < 0)
  if cb == 11:
    for i in 0 ..< dim:
      let a = abs(q[i])
      if a >= 16:
        let (prefix, word) = encEscParts(a)
        for _ in 0 ..< prefix:
          w.writeBit(true)
        w.writeBit(false)
        w.writeBits(word.uint32, prefix + 4)

# ------------------------------------------------------------ MDCT ---

proc encForwardMdct*(time: openArray[float64]): seq[float64] =
  ## §4.6.11.3.1 forward (analysis) MDCT: `N` windowed samples in,
  ## `N/2` coefficients out. Direct O(N^2) form (the reference
  ## `forward_mdct_direct` oracle); speed is a later step.
  let n = time.len
  let m = n div 2
  let n0 = (m.float64 + 1.0) / 2.0
  let step = 2.0 * PI / n.float64
  result = newSeq[float64](m)
  for k in 0 ..< m:
    let f = (k.float64 + 0.5) * step
    var acc = 0.0
    for nn in 0 ..< n:
      acc += time[nn] * cos((nn.float64 + n0) * f)
    result[k] = 2.0 * acc

# ------------------------------------------------------ channel body ---

proc encChannelBody(w: var BitWriter; spec: seq[float64];
    bands: seq[int]; numSwb: int; framePeak: float64; sfOffset: int) =
  ## Quantizes one 1024-line long spectrum and emits a complete
  ## `individual_channel_stream(0)` (global_gain, inline ics_info,
  ## section + scalefactor data, no tools, spectral data).
  let n = spec.len
  var xq = newSeq[int](n)
  var sfbCb = newSeq[int](numSwb) # 0 = ZERO_HCB: silent band
  var sfs = newSeq[int](numSwb)
  var hasSf = newSeq[bool](numSwb)
  var prevSf: Option[int] = none(int)
  for sfb in 0 ..< numSwb:
    let s = bands[sfb]
    let e = min(bands[sfb + 1], n)
    if s >= e:
      continue
    var peak = 0.0
    for k in s ..< e:
      peak = max(peak, abs(spec[k]))
    let sfOpt = encBandSf(peak, framePeak, sfOffset)
    if sfOpt.isNone:
      continue
    var sf = sfOpt.get
    if prevSf.isSome:
      sf = clamp(sf, prevSf.get - AacEncMaxSfDelta,
        prevSf.get + AacEncMaxSfDelta)
      sf = clamp(sf, 0, AacEncMaxSf)
    # Raise sf until the band peak fits the ESC ceiling.
    var qmax = abs(encQuantize(peak, sf))
    while qmax >= AacEncMaxQuant and sf < AacEncMaxSf:
      sf = min(sf + 4, AacEncMaxSf)
      qmax = abs(encQuantize(peak, sf))
    if qmax == 0:
      continue
    var bandMax = 0
    for k in s ..< e:
      let q = encQuantize(spec[k], sf)
      xq[k] = q
      bandMax = max(bandMax, abs(q))
    if bandMax == 0:
      for k in s ..< e:
        xq[k] = 0
      continue
    var bestCb = -1
    var bestBits = high(uint32)
    for cb in 1 .. 11:
      if (e - s) mod encBookDim(cb) != 0:
        continue
      let b = encBandBits(cb, xq.toOpenArray(s, e - 1))
      if b.isSome and b.get < bestBits:
        bestBits = b.get
        bestCb = cb
    if bestCb < 0:
      raise decodeError("aacenc: no codebook covers band")
    sfbCb[sfb] = bestCb
    sfs[sfb] = sf
    hasSf[sfb] = true
    prevSf = some(sf)
  # Greedy sectioning: merge runs of the same book (ZERO runs merge).
  type AacSection = tuple[start, stop, cb: int]
  var sections: seq[AacSection] = @[]
  var b = 0
  while b < numSwb:
    var e = b + 1
    while e < numSwb and sfbCb[e] == sfbCb[b]:
      inc e
    sections.add((b, e, sfbCb[b]))
    b = e
  var globalGain = AacEncSfBase
  for sfb in 0 ..< numSwb:
    if hasSf[sfb]:
      globalGain = sfs[sfb]
      break
  w.writeBits(globalGain.uint32, 8)
  w.writeBit(false) # ics reserved
  w.writeBits(0, 2) # ONLY_LONG_SEQUENCE
  w.writeBit(false) # sine window
  w.writeBits(numSwb.uint32, 6) # max_sfb: full long table
  w.writeBit(false) # no predictor data
  for sec in sections: # section_data, long runs (esc 31, 5-bit fields)
    w.writeBits(sec.cb.uint32, 4)
    var len = sec.stop - sec.start
    while len >= 31:
      w.writeBits(31, 5)
      len -= 31
    w.writeBits(len.uint32, 5)
  var prev = globalGain # scale_factor_data: Table 4.A.1 DPCM
  for sfb in 0 ..< numSwb:
    if sfbCb[sfb] == 0:
      continue
    let d = sfs[sfb] - prev
    prev = sfs[sfb]
    let idx = d + 60
    if idx < 0 or idx > 120:
      raise decodeError("aacenc: scalefactor delta out of range")
    w.writeBits(AacScfCodes[idx], AacScfLens[idx].int)
  w.writeBit(false) # no pulse data
  w.writeBit(false) # no TNS data
  w.writeBit(false) # no gain control data
  for sec in sections: # spectral_data
    if sec.cb == 0:
      continue
    let dim = encBookDim(sec.cb)
    let s = bands[sec.start]
    let e = bands[sec.stop]
    var k = s
    while k < e:
      emitTuple(w, sec.cb, dim, xq.toOpenArray(k, k + dim - 1))
      k += dim

# -------------------------------------------------------------- driver ---

proc finishEncoder*(e: AacEncoder): seq[seq[uint8]] =
  ## Runs the buffered input through the analysis overlap (zero-primed
  ## history plus a zero-flush tail hop) and emits one raw_data_block
  ## per hop plus the flush frame. Empty input yields no blocks.
  let ch = e.opts.channels
  let frameSamples = AacEncFrameLen * ch
  if e.buf.len == 0:
    return @[]
  var nHops = e.buf.len div frameSamples
  if e.buf.len mod frameSamples != 0:
    inc nHops
  var pcm = newSeq[seq[float64]](ch)
  for c in 0 ..< ch:
    pcm[c] = newSeq[float64](nHops * AacEncFrameLen)
  for i in 0 ..< nHops * AacEncFrameLen:
    for c in 0 ..< ch:
      let si = i * ch + c
      pcm[c][i] =
        if si < e.buf.len: e.buf[si].float64
        else: 0.0
  let bands = longBands(subbandRow(e.opts.sampleRateHz))
  let numSwb = bands.len - 1
  if numSwb <= 0 or numSwb > 64:
    raise unsupportedError("aacenc: no scalefactor band table for rate")
  var win: array[2048, float64]
  for i in 0 ..< 2048:
    win[i] = sin(PI * (i.float64 + 0.5) / 2048.0)
  var hist = newSeq[seq[float64]](ch)
  for c in 0 ..< ch:
    hist[c] = newSeq[float64](AacEncFrameLen)
  result = @[]
  for h in 0 .. nHops:
    var specs = newSeq[seq[float64]](ch)
    for c in 0 ..< ch:
      var t = newSeq[float64](2048)
      for i in 0 ..< 1024:
        t[i] = hist[c][i] * win[i]
      for i in 0 ..< 1024:
        let v =
          if h < nHops: pcm[c][h * 1024 + i]
          else: 0.0
        t[1024 + i] = v * win[1024 + i]
      specs[c] = encForwardMdct(t)
    var peak = 0.0 # pair peak anchors both channels' spread
    for c in 0 ..< ch:
      for v in specs[c]:
        peak = max(peak, abs(v))
    var w = newBitWriter()
    if ch == 1:
      w.writeBits(0, 3) # ID_SCE
      w.writeBits(0, 4) # instance tag
      encChannelBody(w, specs[0], bands, numSwb, peak, 0)
    else:
      w.writeBits(1, 3) # ID_CPE
      w.writeBits(0, 4) # instance tag
      w.writeBit(false) # common_window = 0: independent ICS pair
      encChannelBody(w, specs[0], bands, numSwb, peak, 0)
      encChannelBody(w, specs[1], bands, numSwb, peak, 0)
    w.writeBits(7, 3) # ID_END
    w.flush() # zero-pads to the byte
    result.add(w.toBytes())
    if h < nHops:
      for c in 0 ..< ch:
        for i in 0 ..< 1024:
          hist[c][i] = pcm[c][h * 1024 + i]
