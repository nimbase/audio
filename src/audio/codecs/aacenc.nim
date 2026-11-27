## AAC-LC encoder skeleton (Step B): valid silent frames.
##
## Ports the raw_data_block wire order of `oxideav-aac`
## (references/oxideav-aac) only as far as digital silence needs:
## SCE/CPE long-only ICS with `max_sfb = 0` (no sections, no
## scalefactors, no spectral data), no pulse/TNS/gain-control.
## Every 1024-sample frame encodes to the same byte-identical block;
## input content is IGNORED (the signal path — MDCT, quantizer,
## codebooks — arrives in Step C). The output self-decodes to exact
## zeros through `decodeRawDataBlock` and is `ffmpeg`-clean.
##
## Layering: this module assembles raw_data_blocks only; ADTS framing
## lives in `formats/aac.nim` (`encodeAacStream`).

import ./../audio
import ./../codecs/aac
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
  ## Appends interleaved input (content ignored until Step C).
  if samples.len mod e.opts.channels != 0:
    raise decodeError("aacenc: ragged input for channel count")
  for s in samples:
    e.buf.add(s)

proc writeSilentIcs(w: var BitWriter) =
  w.writeBits(0, 8) # global_gain (irrelevant: no coded bands)
  w.writeBit(false) # ics reserved
  w.writeBits(OnlyLongSeq.uint32, 2)
  w.writeBit(false) # window shape: sine
  w.writeBits(0, 6) # max_sfb: no coded bands
  w.writeBit(false) # no predictor data
  # section_data / scalefactor_data: empty (max_sfb = 0).
  w.writeBit(false) # no pulse
  w.writeBit(false) # no TNS
  w.writeBit(false) # no gain control

proc aacSilentRawBlock*(channels: int): seq[uint8] =
  ## One silent raw_data_block: 4 bytes mono (SCE), 7 bytes stereo.
  if channels notin [1, 2]:
    raise unsupportedError("aacenc: only mono/stereo supported")
  var w = newBitWriter()
  if channels == 1:
    w.writeBits(0, 3) # ID_SCE
    w.writeBits(0, 4) # instance tag
    w.writeSilentIcs()
  else:
    w.writeBits(1, 3) # ID_CPE
    w.writeBits(0, 4) # instance tag
    w.writeBit(false) # independent ICS pair (no M/S)
    w.writeSilentIcs()
    w.writeSilentIcs()
  w.writeBits(7, 3) # ID_END
  w.flush() # zero-pads to the byte
  w.toBytes()

proc finishEncoder*(e: AacEncoder): seq[seq[uint8]] =
  ## Zero-pads the tail to 1024 and emits one silent block per frame.
  ## Empty input yields no blocks.
  let frameSamples = 1024 * e.opts.channels
  if e.buf.len == 0:
    return @[]
  var n = e.buf.len div frameSamples
  if e.buf.len mod frameSamples != 0:
    inc n
  result = newSeq[seq[uint8]](n)
  for i in 0 ..< n:
    result[i] = aacSilentRawBlock(e.opts.channels)
