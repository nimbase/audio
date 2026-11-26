## MPEG-1/2/2.5 Layer 1/2/3 decoder (Layer 3 encoder lives in
## `codecs/mpaenc`; layers 1/2 have no encoder — Symphonia ships
## decode-only too).
##
## Ports `symphonia-bundle-mp3` (header, common, decoder, layer12,
## layer1, layer2, synthesis, layer3/*): frame header parse, Layer 1/2
## subband decoders, 32-subband polyphase synthesis filterbank (Lee DCT),
## Layer 3 Huffman/reservoir/requant/stereo/hybrid-IMDCT path. MSB-first
## throughout (`LtrBitReader`); output is planar `sfF32`.

import std/math
import ./../audio
import ./../codecs
import ./../errors
import ./../io
import ./../packet
import ./../source
import ./../units
import ./../vec
import ./mpa_tables

# ------------------------------------------------------------------ header ---

type
  MpegVersion* = enum
    Mpeg2p5
    Mpeg2
    Mpeg1

  MpegLayer* = enum
    Layer1
    Layer2
    Layer3

  MpaModeKind* = enum
    mmStereo
    mmDualMono
    mmMono
    mmJoint

  MpaMode* = object
    case kind*: MpaModeKind
    of mmJoint:
      midSide*: bool
      intensity*: bool
      bound*: int
    else:
      discard

  FrameHeader* = object
    version*: MpegVersion
    layer*: MpegLayer
    bitrate*: uint32
    sampleRate*: uint32
    sampleRateIdx*: int
    channelMode*: MpaMode
    hasCrc*: bool
    frameSize*: int ## Body length after the 4-byte header (incl. CRC).

const
  MpegHeaderLen* = 4
  MaxMpegFrameSize* = 2881

  BitRatesMpeg1L1*: array[15, int] = [0, 32000, 64000, 96000, 128000,
    160000, 192000, 224000, 256000, 288000, 320000, 352000, 384000,
    416000, 448000]
  BitRatesMpeg1L2*: array[15, int] = [0, 32000, 48000, 56000, 64000,
    80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000,
    320000, 384000]
  BitRatesMpeg1L3*: array[15, int] = [0, 32000, 40000, 48000, 56000,
    64000, 80000, 96000, 112000, 128000, 160000, 192000, 224000,
    256000, 320000]
  BitRatesMpeg2L1*: array[15, int] = [0, 32000, 48000, 56000, 64000,
    80000, 96000, 112000, 128000, 144000, 160000, 176000, 192000,
    224000, 256000]
  BitRatesMpeg2L23*: array[15, int] = [0, 8000, 16000, 24000, 32000,
    40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000,
    160000]

proc isFrameSynced*(w: uint32): bool {.inline.} =
  (w and 0xffe0_0000'u32) == 0xffe0_0000'u32

proc checkHeader*(h: uint32): bool {.inline.} =
  ## Cheap pre-check used while scanning for frames.
  if ((h shr 19) and 0x3'u32) == 0x1:
    return false
  if ((h shr 17) and 0x3'u32) == 0x0:
    return false
  if ((h shr 12) and 0xf'u32) == 0xf:
    return false
  if ((h shr 10) and 0x3'u32) == 0x3:
    return false
  true

proc isMono*(m: MpaMode): bool {.inline.} = m.kind == mmMono

proc numChannels*(m: MpaMode): int {.inline.} =
  if m.kind == mmMono: 1 else: 2

proc channelsOf*(m: MpaMode): Channels =
  if m.kind == mmMono: positioned(PosFrontLeft)
  else: ChStereo

proc isMpeg1*(h: FrameHeader): bool {.inline.} = h.version == Mpeg1

proc isMpeg2p5*(h: FrameHeader): bool {.inline.} = h.version == Mpeg2p5

proc nGranules*(h: FrameHeader): int {.inline.} =
  if h.version == Mpeg1: 2 else: 1

proc nChannels*(h: FrameHeader): int {.inline.} = h.channelMode.numChannels()

proc numFrames*(h: FrameHeader): int {.inline.} =
  case h.layer
  of Layer1: 384
  of Layer2: 1152
  of Layer3: 576 * h.nGranules()

proc headerSize*(h: FrameHeader): int {.inline.} =
  MpegHeaderLen + (if h.hasCrc: 2 else: 0)

proc sideInfoLen*(h: FrameHeader): int {.inline.} =
  if h.version == Mpeg1:
    if h.channelMode.kind == mmMono: 17 else: 32
  else:
    if h.channelMode.kind == mmMono: 9 else: 17

proc codecOfLayer*(l: MpegLayer): AudioCodecId {.inline.} =
  case l
  of Layer1: CodecMp1
  of Layer2: CodecMp2
  of Layer3: CodecMp3

proc specOfHeader*(h: FrameHeader): AudioSpec =
  newAudioSpec(h.sampleRate, h.channelMode.channelsOf())

proc parseFrameHeader*(word: uint32): FrameHeader =
  let version =
    case (word and 0x18_0000'u32) shr 19
    of 0b00: Mpeg2p5
    of 0b10: Mpeg2
    of 0b11: Mpeg1
    else: raise decodeError("mpa: invalid MPEG version")
  let layer =
    case (word and 0x6_0000'u32) shr 17
    of 0b01: Layer3
    of 0b10: Layer2
    of 0b11: Layer1
    else: raise decodeError("mpa: invalid MPEG layer")
  let bitrateIdx = ((word and 0xf000'u32) shr 12).int
  if bitrateIdx == 0:
    raise unsupportedError("mpa: free bit-rate is not supported")
  if bitrateIdx == 15:
    raise decodeError("mpa: invalid bit-rate")
  let bitrate =
    if version == Mpeg1:
      case layer
      of Layer1: BitRatesMpeg1L1[bitrateIdx]
      of Layer2: BitRatesMpeg1L2[bitrateIdx]
      of Layer3: BitRatesMpeg1L3[bitrateIdx]
    else:
      case layer
      of Layer1: BitRatesMpeg2L1[bitrateIdx]
      else: BitRatesMpeg2L23[bitrateIdx]
  let srBits = ((word and 0xc00'u32) shr 10).int
  var sampleRate = 0'u32
  var sampleRateIdx = 0
  if version == Mpeg1:
    case srBits
    of 0b00:
      sampleRate = 44_100'u32
      sampleRateIdx = 0
    of 0b01:
      sampleRate = 48_000'u32
      sampleRateIdx = 1
    of 0b10:
      sampleRate = 32_000'u32
      sampleRateIdx = 2
    else:
      raise decodeError("mpa: invalid sample rate")
  elif version == Mpeg2:
    case srBits
    of 0b00:
      sampleRate = 22_050'u32
      sampleRateIdx = 3
    of 0b01:
      sampleRate = 24_000'u32
      sampleRateIdx = 4
    of 0b10:
      sampleRate = 16_000'u32
      sampleRateIdx = 5
    else:
      raise decodeError("mpa: invalid sample rate")
  else:
    case srBits
    of 0b00:
      sampleRate = 11_025'u32
      sampleRateIdx = 6
    of 0b01:
      sampleRate = 12_000'u32
      sampleRateIdx = 7
    of 0b10:
      sampleRate = 8_000'u32
      sampleRateIdx = 8
    else:
      raise decodeError("mpa: invalid sample rate")
  let modeBits = ((word and 0xc0'u32) shr 6).int
  var channelMode: MpaMode
  if modeBits == 0b00:
    channelMode = MpaMode(kind: mmStereo)
  elif modeBits == 0b10:
    channelMode = MpaMode(kind: mmDualMono)
  elif modeBits == 0b11:
    channelMode = MpaMode(kind: mmMono)
  elif layer == Layer3:
    channelMode = MpaMode(kind: mmJoint,
      midSide: (word and 0x20'u32) != 0,
      intensity: (word and 0x10'u32) != 0, bound: 0)
  else:
    channelMode = MpaMode(kind: mmJoint, midSide: false, intensity: true,
      bound: (1 + ((word and 0x30'u32) shr 4).int) * 4)
  if layer == Layer2:
    if channelMode.kind == mmMono:
      if bitrate in [224000, 256000, 320000, 384000]:
        raise decodeError("mpa: invalid Layer 2 bitrate for mono channel mode")
    elif bitrate in [32000, 48000, 56000, 80000]:
      raise decodeError("mpa: invalid Layer 2 bitrate for non-mono channel mode")
  let hasCrc = (word and 0x1_0000'u32) == 0
  let hasPadding = (word and 0x200'u32) != 0
  let factor =
    case layer
    of Layer1: 12
    of Layer2: 144
    of Layer3:
      if version == Mpeg1: 144 else: 72
  let slotSize = if layer == Layer1: 4 else: 1
  let slots = (factor * bitrate) div sampleRate.int + (if hasPadding: 1 else: 0)
  let frameSize = (slots * slotSize).int - MpegHeaderLen
  FrameHeader(version: version, layer: layer, bitrate: bitrate.uint32,
    sampleRate: sampleRate, sampleRateIdx: sampleRateIdx,
    channelMode: channelMode, hasCrc: hasCrc, frameSize: frameSize)

proc isSimilar*(a: FrameHeader; word: uint32): bool =
  ## Strict-sync gate: next frame must parse and match version, layer,
  ## sample rate and channel count.
  if not isFrameSynced(word) or not checkHeader(word):
    return false
  var b: FrameHeader
  try:
    b = parseFrameHeader(word)
  except AudioError:
    return false
  a.version == b.version and a.layer == b.layer and
    a.sampleRate == b.sampleRate and
    a.channelMode.numChannels() == b.channelMode.numChannels()

# ------------------------------------------------------------ synthesis ---

type
  SynthState* = object
    vVec*: array[16, array[64, float32]]
    vFront*: int
proc dct32*(x: openArray[float32]; y: var openArray[float32]) =

  var t0 = [
  (x[0] + x[32 - 1]),
  (x[1] + x[32 - 2]),
  (x[2] + x[32 - 3]),
  (x[3] + x[32 - 4]),
  (x[4] + x[32 - 5]),
  (x[5] + x[32 - 6]),
  (x[6] + x[32 - 7]),
  (x[7] + x[32 - 8]),
  (x[8] + x[32 - 9]),
  (x[9] + x[32 - 10]),
  (x[10] + x[32 - 11]),
  (x[11] + x[32 - 12]),
  (x[12] + x[32 - 13]),
  (x[13] + x[32 - 14]),
  (x[14] + x[32 - 15]),
  (x[15] + x[32 - 16]),
  (x[0] - x[32 - 1]) * DctCos16[0],
  (x[1] - x[32 - 2]) * DctCos16[1],
  (x[2] - x[32 - 3]) * DctCos16[2],
  (x[3] - x[32 - 4]) * DctCos16[3],
  (x[4] - x[32 - 5]) * DctCos16[4],
  (x[5] - x[32 - 6]) * DctCos16[5],
  (x[6] - x[32 - 7]) * DctCos16[6],
  (x[7] - x[32 - 8]) * DctCos16[7],
  (x[8] - x[32 - 9]) * DctCos16[8],
  (x[9] - x[32 - 10]) * DctCos16[9],
  (x[10] - x[32 - 11]) * DctCos16[10],
  (x[11] - x[32 - 12]) * DctCos16[11],
  (x[12] - x[32 - 13]) * DctCos16[12],
  (x[13] - x[32 - 14]) * DctCos16[13],
  (x[14] - x[32 - 15]) * DctCos16[14],
  (x[15] - x[32 - 16]) * DctCos16[15],
  ]

  # 16-point DCT decomposition of t0[0..16]
  block:
    var t1 = [
    (t0[0] + t0[16 - 1]),
    (t0[1] + t0[16 - 2]),
    (t0[2] + t0[16 - 3]),
    (t0[3] + t0[16 - 4]),
    (t0[4] + t0[16 - 5]),
    (t0[5] + t0[16 - 6]),
    (t0[6] + t0[16 - 7]),
    (t0[7] + t0[16 - 8]),
    (t0[0] - t0[16 - 1]) * DctCos8[0],
    (t0[1] - t0[16 - 2]) * DctCos8[1],
    (t0[2] - t0[16 - 3]) * DctCos8[2],
    (t0[3] - t0[16 - 4]) * DctCos8[3],
    (t0[4] - t0[16 - 5]) * DctCos8[4],
    (t0[5] - t0[16 - 6]) * DctCos8[5],
    (t0[6] - t0[16 - 7]) * DctCos8[6],
    (t0[7] - t0[16 - 8]) * DctCos8[7],
    ]

    # 8-point DCT decomposition of t1[0..8]
    block:
      var t2 = [
      (t1[0] + t1[8 - 1]),
      (t1[1] + t1[8 - 2]),
      (t1[2] + t1[8 - 3]),
      (t1[3] + t1[8 - 4]),
      (t1[0] - t1[8 - 1]) * DctCos4[0],
      (t1[1] - t1[8 - 2]) * DctCos4[1],
      (t1[2] - t1[8 - 3]) * DctCos4[2],
      (t1[3] - t1[8 - 4]) * DctCos4[3],
      ]

      # 4-point DCT decomposition of t2[0..4]
      block:
        var t3 = [
        (t2[0] + t2[4 - 1]),
        (t2[1] + t2[4 - 2]),
        (t2[0] - t2[4 - 1]) * DctCos2[0],
        (t2[1] - t2[4 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[0 + 0] = t3[0]
        t2[0 + 1] = t3[2] + t3[3]
        t2[0 + 2] = t3[1]
        t2[0 + 3] = t3[3]

      # 4-point DCT decomposition of t2[4..8]
      block:
        var t3 = [
        (t2[4] + t2[8 - 1]),
        (t2[5] + t2[8 - 2]),
        (t2[4] - t2[8 - 1]) * DctCos2[0],
        (t2[5] - t2[8 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[4 + 0] = t3[0]
        t2[4 + 1] = t3[2] + t3[3]
        t2[4 + 2] = t3[1]
        t2[4 + 3] = t3[3]

      # Recombine t2[0..4] and t2[4..8], overwriting t1[0..8].
      for i in 0 ..< 3:
        t1[(i shl 1) + 0] = t2[i]
        t1[(i shl 1) + 1] = t2[4 + i] + t2[4 + i + 1]

      t1[8 - 2] = t2[4 - 1]
      t1[8 - 1] = t2[8 - 1]

    # 8-point DCT decomposition of t1[8..16]
    block:
      var t2 = [
      (t1[8] + t1[16 - 1]),
      (t1[9] + t1[16 - 2]),
      (t1[10] + t1[16 - 3]),
      (t1[11] + t1[16 - 4]),
      (t1[8] - t1[16 - 1]) * DctCos4[0],
      (t1[9] - t1[16 - 2]) * DctCos4[1],
      (t1[10] - t1[16 - 3]) * DctCos4[2],
      (t1[11] - t1[16 - 4]) * DctCos4[3],
      ]

      # 4-point DCT decomposition of t2[0..4]
      block:
        var t3 = [
        (t2[0] + t2[4 - 1]),
        (t2[1] + t2[4 - 2]),
        (t2[0] - t2[4 - 1]) * DctCos2[0],
        (t2[1] - t2[4 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[0 + 0] = t3[0]
        t2[0 + 1] = t3[2] + t3[3]
        t2[0 + 2] = t3[1]
        t2[0 + 3] = t3[3]

      # 4-point DCT decomposition of t2[4..8]
      block:
        var t3 = [
        (t2[4] + t2[8 - 1]),
        (t2[5] + t2[8 - 2]),
        (t2[4] - t2[8 - 1]) * DctCos2[0],
        (t2[5] - t2[8 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[4 + 0] = t3[0]
        t2[4 + 1] = t3[2] + t3[3]
        t2[4 + 2] = t3[1]
        t2[4 + 3] = t3[3]

      # Recombine t2[0..4] and t2[4..8], overwriting t1[8..16].
      for i in 0 ..< 3:
        t1[8 + (i shl 1) + 0] = t2[i]
        t1[8 + (i shl 1) + 1] = t2[4 + i] + t2[4 + i + 1]

      t1[16 - 2] = t2[4 - 1]
      t1[16 - 1] = t2[8 - 1]

    # Recombine t1[0..8] and t1[8..16], overwriting t0[0..16].
    for i in 0 ..< 7:
      t0[(i shl 1) + 0] = t1[i]
      t0[(i shl 1) + 1] = t1[8 + i] + t1[8 + i + 1]

    t0[16 - 2] = t1[8 - 1]
    t0[16 - 1] = t1[16 - 1]

  # 16-point DCT decomposition of t0[16..32]
  block:
    var t1 = [
    (t0[16] + t0[32 - 1]),
    (t0[17] + t0[32 - 2]),
    (t0[18] + t0[32 - 3]),
    (t0[19] + t0[32 - 4]),
    (t0[20] + t0[32 - 5]),
    (t0[21] + t0[32 - 6]),
    (t0[22] + t0[32 - 7]),
    (t0[23] + t0[32 - 8]),
    (t0[16] - t0[32 - 1]) * DctCos8[0],
    (t0[17] - t0[32 - 2]) * DctCos8[1],
    (t0[18] - t0[32 - 3]) * DctCos8[2],
    (t0[19] - t0[32 - 4]) * DctCos8[3],
    (t0[20] - t0[32 - 5]) * DctCos8[4],
    (t0[21] - t0[32 - 6]) * DctCos8[5],
    (t0[22] - t0[32 - 7]) * DctCos8[6],
    (t0[23] - t0[32 - 8]) * DctCos8[7],
    ]

    # 8-point DCT decomposition of t1[0..8]
    block:
      var t2 = [
      (t1[0] + t1[8 - 1]),
      (t1[1] + t1[8 - 2]),
      (t1[2] + t1[8 - 3]),
      (t1[3] + t1[8 - 4]),
      (t1[0] - t1[8 - 1]) * DctCos4[0],
      (t1[1] - t1[8 - 2]) * DctCos4[1],
      (t1[2] - t1[8 - 3]) * DctCos4[2],
      (t1[3] - t1[8 - 4]) * DctCos4[3],
      ]

      # 4-point DCT decomposition of t2[0..4]
      block:
        var t3 = [
        (t2[0] + t2[4 - 1]),
        (t2[1] + t2[4 - 2]),
        (t2[0] - t2[4 - 1]) * DctCos2[0],
        (t2[1] - t2[4 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[0 + 0] = t3[0]
        t2[0 + 1] = t3[2] + t3[3]
        t2[0 + 2] = t3[1]
        t2[0 + 3] = t3[3]

      # 4-point DCT decomposition of t2[4..8]
      block:
        var t3 = [
        (t2[4] + t2[8 - 1]),
        (t2[5] + t2[8 - 2]),
        (t2[4] - t2[8 - 1]) * DctCos2[0],
        (t2[5] - t2[8 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[4 + 0] = t3[0]
        t2[4 + 1] = t3[2] + t3[3]
        t2[4 + 2] = t3[1]
        t2[4 + 3] = t3[3]

      # Recombine t2[0..4] and t2[4..8], overwriting t1[0..8].
      for i in 0 ..< 3:
        t1[(i shl 1) + 0] = t2[i]
        t1[(i shl 1) + 1] = t2[4 + i] + t2[4 + i + 1]

      t1[8 - 2] = t2[4 - 1]
      t1[8 - 1] = t2[8 - 1]

    # 8-point DCT decomposition of t1[8..16]
    block:
      var t2 = [
      (t1[8] + t1[16 - 1]),
      (t1[9] + t1[16 - 2]),
      (t1[10] + t1[16 - 3]),
      (t1[11] + t1[16 - 4]),
      (t1[8] - t1[16 - 1]) * DctCos4[0],
      (t1[9] - t1[16 - 2]) * DctCos4[1],
      (t1[10] - t1[16 - 3]) * DctCos4[2],
      (t1[11] - t1[16 - 4]) * DctCos4[3],
      ]

      # 4-point DCT decomposition of t2[0..4]
      block:
        var t3 = [
        (t2[0] + t2[4 - 1]),
        (t2[1] + t2[4 - 2]),
        (t2[0] - t2[4 - 1]) * DctCos2[0],
        (t2[1] - t2[4 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[0 + 0] = t3[0]
        t2[0 + 1] = t3[2] + t3[3]
        t2[0 + 2] = t3[1]
        t2[0 + 3] = t3[3]

      # 4-point DCT decomposition of t2[4..8]
      block:
        var t3 = [
        (t2[4] + t2[8 - 1]),
        (t2[5] + t2[8 - 2]),
        (t2[4] - t2[8 - 1]) * DctCos2[0],
        (t2[5] - t2[8 - 2]) * DctCos2[1],
        ]

        # 2-point DCT decomposition of t3[0..2]
        block:
          let t4 = [(t3[0] + t3[2 - 1]), (t3[0] - t3[2 - 1]) * DctCos1]

          t3[0] = t4[0]
          t3[1] = t4[1]

        # 2-point DCT decomposition of t3[2..4]
        block:
          let t4 = [(t3[2] + t3[4 - 1]), (t3[2] - t3[4 - 1]) * DctCos1]

          t3[2 + 0] = t4[0]
          t3[2 + 1] = t4[1]

        t2[4 + 0] = t3[0]
        t2[4 + 1] = t3[2] + t3[3]
        t2[4 + 2] = t3[1]
        t2[4 + 3] = t3[3]

      # Recombine t2[0..4] and t2[4..8], overwriting t1[8..16].
      for i in 0 ..< 3:
        t1[8 + (i shl 1) + 0] = t2[i]
        t1[8 + (i shl 1) + 1] = t2[4 + i] + t2[4 + i + 1]

      t1[16 - 2] = t2[4 - 1]
      t1[16 - 1] = t2[8 - 1]

    # Recombine t1[0..8] and t1[8..16], overwriting t0[0..16].
    for i in 0 ..< 7:
      t0[16 + (i shl 1) + 0] = t1[i]
      t0[16 + (i shl 1) + 1] = t1[8 + i] + t1[8 + i + 1]

    t0[32 - 2] = t1[8 - 1]
    t0[32 - 1] = t1[16 - 1]

  # Recombine t1[0..16] and t1[16..32] into y.
  for i in 0 ..< 15:
    y[(i shl 1) + 0] = t0[i]
    y[(i shl 1) + 1] = t0[16 + i] + t0[16 + i + 1]

  y[32 - 2] = t0[16 - 1]
  y[32 - 1] = t0[32 - 1]

proc synthesis*(state: var SynthState; nFrames: int;
    samples: openArray[float32]; output: var openArray[float32]) =
  ## 32-subband polyphase synthesis: `32*nFrames` subband samples in,
  ## `32*nFrames` PCM samples out. Input is subband-major.
  assert samples.len == 32 * nFrames
  var sVec: array[32, float32]
  var dVec: array[32, float32]
  for b in 0 ..< nFrames:
    for i in 0 ..< 32:
      sVec[i] = samples[nFrames * i + b]
    let v = state.vVec[state.vFront].addr
    dct32(sVec, dVec)
    for i in 0 ..< 15:
      v[][33 + i] = -dVec[15 - i]
    for i in 0 ..< 15:
      v[][49 + i] = -dVec[1 + i]
    for i in 0 ..< 15:
      v[][17 + i] = -dVec[31 - i]
    for i in 0 ..< 15:
      v[][1 + i] = dVec[17 + i]
    v[][0] = dVec[16]
    v[][32] = -dVec[16]
    v[][48] = -dVec[0]
    v[][16] = 0.0
    for i in 0 ..< 32:
      output[b * 32 + i] = 0.0
    for j in 0 ..< 8:
      let vStart = state.vFront + (j shl 1)
      let k = j shl 6
      synthWindowAccum32Vec(output.toOpenArray(b * 32, b * 32 + 31),
        state.vVec[(vStart + 0) and 0xf].toOpenArray(0, 31),
        state.vVec[(vStart + 1) and 0xf].toOpenArray(32, 63),
        SynthesisD.toOpenArray(k, k + 31),
        SynthesisD.toOpenArray(k + 32, k + 63))
    state.vFront = (state.vFront + 15) and 0xf
# ------------------------------------------------------------- layer 1 ---

const Layer1FactorTable: array[16, float32] = block:
  var t = [0'f32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  for i in 2 ..< 16:
    let a = 1 shl i
    let b = 1 shl (i - 1)
    t[i] = (a.float32 / (a - 1).float32) / b.float32
  t

proc layer1Dequant(bits: int; factor, raw: float32; rawU: uint32): float32 =
  let inv = rawU xor (1'u32 shl (bits - 1))
  let a = signExtend(inv, bits)
  factor * (a + 1).float32

proc decodeLayer1Data[L](header: FrameHeader; bs: var L;
    synth: var array[2, SynthState]; buf: var AudioSamples) =
  ## Layer 1 core over any MSB-first bit cursor (owning or view).
  if header.hasCrc:
    discard bs.readLtrBits(16)
  var alloc = default(array[2, array[32, int]])
  var scalefacs: array[2, array[32, float32]]
  let nch = header.nChannels()
  var bound = 32
  case header.channelMode.kind
  of mmJoint:
    if header.channelMode.intensity:
      bound = header.channelMode.bound
    else:
      raise decodeError("mp1: invalid mode extension for layer 1 stereo decoding")
  else:
    discard
  for sb in 0 ..< bound:
    for ch in 0 ..< nch:
      let bits = bs.readLtrBits(4).int
      if bits > 0xe:
        raise decodeError("mp1: invalid bit allocation")
      alloc[ch][sb] = if bits != 0: bits + 1 else: 0
  for sb in bound ..< 32:
    let bits = bs.readLtrBits(4).int
    if bits > 0xe:
      raise decodeError("mp1: invalid bit allocation")
    let ba = if bits != 0: bits + 1 else: 0
    alloc[0][sb] = ba
    alloc[1][sb] = ba
  for sb in 0 ..< 32:
    for ch in 0 ..< nch:
      if alloc[ch][sb] != 0:
        let idx = bs.readLtrBits(6).int
        if idx > 63:
          raise decodeError("mp1: invalid scalefactor index")
        scalefacs[ch][sb] = Layer12Scalefactors[idx]
  var samples: array[2, array[384, float32]]
  for s in 0 ..< 12:
    for sb in 0 ..< bound:
      for ch in 0 ..< nch:
        let bits = alloc[ch][sb]
        if bits != 0:
          let raw = bs.readLtrBits(bits)
          samples[ch][12 * sb + s] = scalefacs[ch][sb] *
            layer1Dequant(bits, Layer1FactorTable[bits], 0.0, raw)
    for sb in bound ..< 32:
      let bits = alloc[0][sb]
      if bits != 0:
        let raw = bs.readLtrBits(bits)
        let v = layer1Dequant(bits, Layer1FactorTable[bits], 0.0, raw)
        for ch in 0 ..< nch:
          samples[ch][12 * sb + s] = scalefacs[ch][sb] * v
  buf.f32.renderWith(384, i):
    discard i
  for ch in 0 ..< nch:
    if ch >= buf.f32.planes.len:
      raise decodeError("mp1: missing audio plane")
    synthesis(synth[ch], 12, samples[ch],
      buf.f32.planes[ch].toOpenArray(0, 383))

proc decodeLayer1Frame*(header: FrameHeader; body: openArray[uint8];
    synth: var array[2, SynthState]; buf: var AudioSamples) =
  ## Owning entry: copies `body` into a cached reader (as before).
  var bs = newLtrBitReader(body)
  decodeLayer1Data(header, bs, synth, buf)

# ------------------------------------------------------------- layer 2 ---

type
  QuantClass* = object
    c*, d*: float32
    grouping*: bool
    bits*: int
    nlevels*: int

const
  QuantClasses*: array[17, QuantClass] = [
    QuantClass(c: 1.33333333333'f32, d: 0.50000000000'f32, grouping: true, bits: 5, nlevels: 3),
    QuantClass(c: 1.60000000000'f32, d: 0.50000000000'f32, grouping: true, bits: 7, nlevels: 5),
    QuantClass(c: 1.14285714286'f32, d: 0.25000000000'f32, grouping: false, bits: 3, nlevels: 7),
    QuantClass(c: 1.77777777777'f32, d: 0.50000000000'f32, grouping: true, bits: 10, nlevels: 9),
    QuantClass(c: 1.06666666666'f32, d: 0.12500000000'f32, grouping: false, bits: 4, nlevels: 15),
    QuantClass(c: 1.03225806452'f32, d: 0.06250000000'f32, grouping: false, bits: 5, nlevels: 31),
    QuantClass(c: 1.01587301587'f32, d: 0.03125000000'f32, grouping: false, bits: 6, nlevels: 63),
    QuantClass(c: 1.00787401575'f32, d: 0.01562500000'f32, grouping: false, bits: 7, nlevels: 127),
    QuantClass(c: 1.00392156863'f32, d: 0.00781250000'f32, grouping: false, bits: 8, nlevels: 255),
    QuantClass(c: 1.00195694716'f32, d: 0.00390625000'f32, grouping: false, bits: 9, nlevels: 511),
    QuantClass(c: 1.00097751711'f32, d: 0.00195312500'f32, grouping: false, bits: 10, nlevels: 1023),
    QuantClass(c: 1.00048851979'f32, d: 0.00097656250'f32, grouping: false, bits: 11, nlevels: 2047),
    QuantClass(c: 1.00024420024'f32, d: 0.00048828125'f32, grouping: false, bits: 12, nlevels: 4095),
    QuantClass(c: 1.00012208522'f32, d: 0.00024414063'f32, grouping: false, bits: 13, nlevels: 8191),
    QuantClass(c: 1.00006103888'f32, d: 0.00012207031'f32, grouping: false, bits: 14, nlevels: 16383),
    QuantClass(c: 1.00003051851'f32, d: 0.00006103516'f32, grouping: false, bits: 15, nlevels: 32767),
    QuantClass(c: 1.00001525902'f32, d: 0.00003051758'f32, grouping: false, bits: 16, nlevels: 65535),
  ]

const
  SbQuantClasses0*: array[16, uint8] = [0, 0, 1, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  SbQuantClasses1*: array[16, uint8] = [0, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  SbQuantClasses2*: array[16, uint8] = [0, 0, 1, 3, 4, 5, 6, 7, 0, 0, 0, 0, 0, 0, 0, 0]
  SbQuantClasses3*: array[16, uint8] = [0, 0, 1, 2, 3, 4, 5, 16, 0, 0, 0, 0, 0, 0, 0, 0]
  SbQuantClasses4*: array[16, uint8] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  SbQuantClasses5*: array[16, uint8] = [0, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  SbQuantClasses6*: array[16, uint8] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16]
  SbQuantClasses7*: array[16, uint8] = [0, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  SbInfoSblimit*: array[5, int] = [27, 30, 8, 12, 30]
  SbInfoBands0*: array[32, uint8] = [7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  SbInfoBands1*: array[32, uint8] = [7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  SbInfoBands2*: array[32, uint8] = [5, 5, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  SbInfoBands3*: array[32, uint8] = [5, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  SbInfoBands4*: array[32, uint8] = [4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0]

proc sbQuantClasses(idx: int): array[16, uint8] =
  case idx
  of 0: SbQuantClasses0
  of 1: SbQuantClasses1
  of 2: SbQuantClasses2
  of 3: SbQuantClasses3
  of 4: SbQuantClasses4
  of 5: SbQuantClasses5
  of 6: SbQuantClasses6
  else: SbQuantClasses7

proc sbInfoBands(idx: int): array[32, uint8] =
  case idx
  of 0: SbInfoBands0
  of 1: SbInfoBands1
  of 2: SbInfoBands2
  of 3: SbInfoBands3
  else: SbInfoBands4

proc layer2SbInfoIdx(header: FrameHeader): int =
  if header.isMpeg1():
    let nch = header.nChannels()
    let brPerCh = header.bitrate.int div nch
    if brPerCh <= 48_000:
      if header.sampleRate == 32_000: 3 else: 2
    elif brPerCh <= 80_000:
      0
    else:
      if header.sampleRate != 48_000: 0 else: 1
  else:
    4

proc layer2Dequant[L](bs: var L; class: QuantClass): array[3, float32] =
  var raw = [0'u32, 0, 0]
  var bits = 0
  if class.grouping:
    var c = bs.readLtrBits(class.bits)
    let nl = class.nlevels.uint32
    for item in raw.mitems:
      item = c mod nl
      c = c div nl
    var p = 1'u32
    while p < nl:
      p = p shl 1
      inc bits
  else:
    bits = class.bits
    for item in raw.mitems:
      item = bs.readLtrBits(bits)
  let divisor = (1 shl (bits - 1)).float32
  for i in 0 ..< 3:
    let inv = raw[i] xor (1'u32 shl (bits - 1))
    let a = signExtend(inv, bits)
    let s = a.float32 / divisor
    result[i] = class.c * (s + class.d)

proc decodeLayer2Data[L](header: FrameHeader; bs: var L;
    synth: var array[2, SynthState]; buf: var AudioSamples) =
  ## Layer 2 core over any MSB-first bit cursor (owning or view).
  if header.hasCrc:
    discard bs.readLtrBits(16)
  var alloc: array[2, array[32, int]]
  var scfsi: array[2, array[32, int]]
  var scalefacs: array[2, array[3, array[32, int]]]
  let nch = header.nChannels()
  let sbIdx = layer2SbInfoIdx(header)
  let sblimit = SbInfoSblimit[sbIdx]
  let bands = sbInfoBands(sbIdx)
  var bound = 32
  case header.channelMode.kind
  of mmJoint:
    if header.channelMode.intensity:
      bound = header.channelMode.bound
    else:
      raise decodeError("mp2: invalid mode extension for layer 2 stereo decoding")
  else:
    discard
  bound = min(bound, sblimit)
  for sb in 0 ..< bound:
    let nbal = [2, 2, 3, 3, 4, 4, 4, 4][bands[sb].int]
    for ch in 0 ..< nch:
      alloc[ch][sb] = bs.readLtrBits(nbal).int
  for sb in bound ..< sblimit:
    let nbal = [2, 2, 3, 3, 4, 4, 4, 4][bands[sb].int]
    let v = bs.readLtrBits(nbal).int
    alloc[0][sb] = v
    alloc[1][sb] = v
  for sb in 0 ..< sblimit:
    for ch in 0 ..< nch:
      if alloc[ch][sb] != 0:
        scfsi[ch][sb] = bs.readLtrBits(2).int
  for sb in 0 ..< sblimit:
    for ch in 0 ..< nch:
      if alloc[ch][sb] != 0:
        let first = bs.readLtrBits(6).int
        var idx = [first, first, first]
        case scfsi[ch][sb]
        of 0:
          idx[1] = bs.readLtrBits(6).int
          idx[2] = bs.readLtrBits(6).int
        of 1:
          idx[2] = bs.readLtrBits(6).int
        of 2:
          discard
        of 3:
          idx[1] = bs.readLtrBits(6).int
          idx[2] = idx[1]
        else:
          raise decodeError("mp2: invalid scfsi")
        scalefacs[ch][0][sb] = idx[0]
        scalefacs[ch][1][sb] = idx[1]
        scalefacs[ch][2][sb] = idx[2]
  var samples: array[2, array[1152, float32]]
  for gr in 0 ..< 12:
    for sb in 0 ..< bound:
      for ch in 0 ..< nch:
        let classIdx = alloc[ch][sb]
        if classIdx != 0:
          let triplet = layer2Dequant(bs, QuantClasses[sbQuantClasses(bands[sb].int)[classIdx].int])
          let sc = Layer12Scalefactors[scalefacs[ch][gr div 4][sb]]
          samples[ch][36 * sb + 3 * gr + 0] = sc * triplet[0]
          samples[ch][36 * sb + 3 * gr + 1] = sc * triplet[1]
          samples[ch][36 * sb + 3 * gr + 2] = sc * triplet[2]
    for sb in bound ..< sblimit:
      let classIdx = alloc[0][sb]
      if classIdx != 0:
        let triplet = layer2Dequant(bs, QuantClasses[sbQuantClasses(bands[sb].int)[classIdx].int])
        for ch in 0 ..< nch:
          let sc = Layer12Scalefactors[scalefacs[ch][gr div 4][sb]]
          samples[ch][36 * sb + 3 * gr + 0] = sc * triplet[0]
          samples[ch][36 * sb + 3 * gr + 1] = sc * triplet[1]
          samples[ch][36 * sb + 3 * gr + 2] = sc * triplet[2]
  buf.f32.renderWith(1152, i):
    discard i
  for ch in 0 ..< nch:
    if ch >= buf.f32.planes.len:
      raise decodeError("mp2: missing audio plane")
    synthesis(synth[ch], 36, samples[ch],
      buf.f32.planes[ch].toOpenArray(0, 1151))

proc decodeLayer2Frame*(header: FrameHeader; body: openArray[uint8];
    synth: var array[2, SynthState]; buf: var AudioSamples) =
  ## Owning entry: copies `body` into a cached reader (as before).
  var bs = newLtrBitReader(body)
  decodeLayer2Data(header, bs, synth, buf)


# ------------------------------------------------------------- layer 3 ---

type
  BlockTypeKind* = enum
    btLong
    btStart
    btShort
    btEnd

  BlockType* = object
    case kind*: BlockTypeKind
    of btShort:
      mixed*: bool
    else:
      discard

  GranuleChannel* = object
    part23Len*: int
    bigValues*: int
    globalGain*: int
    scalefacCompress*: int
    blockType*: BlockType
    subblockGain*: array[3, int]
    tableSelect*: array[3, int]
    region1Start*: int
    region2Start*: int
    preflag*: bool
    scalefacScale*: bool
    count1Select*: int
    scalefacs*: array[39, int]
    rzero*: int

  MpaReservoir* = object
    buf*: array[2048, uint8]
    len*: int
    consumed*: int

  Layer3State* = object
    samples*: array[2, array[2, array[576, float32]]]
    overlap*: array[2, array[32, array[18, float32]]]
    synth*: array[2, SynthState]
    reservoir*: MpaReservoir

const
  ScaleFactorSlen*: array[16, array[2, int]] = [
    [0, 0], [0, 1], [0, 2], [0, 3], [3, 0], [1, 1], [1, 2], [1, 3],
    [2, 1], [2, 2], [2, 3], [3, 1], [3, 2], [3, 3], [4, 2], [4, 3],
  ]
  ScaleFactorMpeg2Nsfb*: array[6, array[3, array[4, int]]] = [
    [[7, 7, 7, 0], [12, 12, 12, 0], [6, 15, 12, 0]],
    [[6, 6, 6, 3], [12, 9, 9, 6], [6, 12, 9, 6]],
    [[8, 8, 5, 0], [15, 12, 9, 0], [6, 18, 9, 0]],
    [[6, 5, 5, 5], [9, 9, 9, 9], [6, 9, 9, 9]],
    [[6, 5, 7, 3], [9, 9, 12, 6], [6, 9, 12, 6]],
    [[11, 10, 0, 0], [18, 18, 0, 0], [15, 18, 0, 0]],
  ]
  PreEmphasis*: array[22, int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    1, 1, 1, 2, 2, 3, 3, 3, 2, 0]
  ImdctScale36*: array[18, float32] = [
    1.9980964431637156'f32, 1.9828897227476208, 1.9525920142398667,
    1.9074339014964539, 1.8477590650225735, 1.7740216663564434,
    1.6867828916257714, 1.5867066805824706, 1.4745546736202479,
    1.3511804152313207, 1.2175228580174413, 1.0745992166936478,
    0.9234972264700677, 0.7653668647301797, 0.6014115990085461,
    0.4328792278762058, 0.261052384440103, 0.087238774730672,
  ]
  SdctScale9*: array[9, float32] = [
    1.9923893961834911'f32, 1.9318516525781366, 1.8126155740732999,
    1.6383040885779836, 1.4142135623730951, 1.1471528727020923,
    0.8452365234813989, 0.5176380902050419, 0.1743114854953163,
  ]
  SdctD9*: array[7, float32] = [
    -1.7320508075688772'f32, 1.8793852415718166, -0.3472963553338608,
    -1.532088886237956, -0.6840402866513378, -1.969615506024416,
    -1.2855752193730785,
  ]

var
  mpaPow43*: array[8207, float32]
  mpaPow43Ready = false
  mpaVlcTables*: array[18, VlcTable]
  mpaVlcQuads*: array[2, VlcTable]
  mpaVlcReady = false
  mpaRatioMpeg1*: array[7, array[2, float32]]
  mpaRatioMpeg2*: array[2, array[32, array[2, float32]]]
  mpaImdctWin*: array[4, array[36, float32]]
  mpaCos12*: array[6, array[6, float32]]
  mpaAntialiasCs*: array[8, float32]
  mpaAntialiasCa*: array[8, float32]
  mpaTablesReady = false

proc mpegGenValue(i, wrap: int): uint32 {.inline.} =
  cast[uint32](((i div wrap) shl 4) or (i mod wrap))

proc initMpaTables*() =
  if mpaTablesReady:
    return
  mpaTablesReady = true
  if not mpaPow43Ready:
    mpaPow43Ready = true
    for i in 0 ..< 8207:
      mpaPow43[i] = pow(i.float32, 4.0 / 3.0)
  # Huffman VLC tables (Verbatim, 8 bits per read).
  if not mpaVlcReady:
    mpaVlcReady = true
    for t in 0 ..< 18:
      let src = MpegTableCodes[t]
      let wrap = MpegTableWrap[t]
      if wrap == 0:
        mpaVlcTables[t] = VlcTable()
        continue
      var codes = newSeq[uint32]()
      var lens = newSeq[uint32]()
      template grab(c, l: untyped) =
        codes.setLen(c.len)
        lens.setLen(l.len)
        for i in 0 ..< c.len:
          codes[i] = c[i]
          lens[i] = l[i].uint32
      case src
      of 1: grab(MpegCodes1, MpegBits1)
      of 2: grab(MpegCodes2, MpegBits2)
      of 3: grab(MpegCodes3, MpegBits3)
      of 5: grab(MpegCodes5, MpegBits5)
      of 6: grab(MpegCodes6, MpegBits6)
      of 7: grab(MpegCodes7, MpegBits7)
      of 8: grab(MpegCodes8, MpegBits8)
      of 9: grab(MpegCodes9, MpegBits9)
      of 10: grab(MpegCodes10, MpegBits10)
      of 11: grab(MpegCodes11, MpegBits11)
      of 12: grab(MpegCodes12, MpegBits12)
      of 13: grab(MpegCodes13, MpegBits13)
      of 15: grab(MpegCodes15, MpegBits15)
      of 16: grab(MpegCodes16, MpegBits16)
      else: grab(MpegCodes24, MpegBits24)
      var vals = newSeq[uint32](codes.len)
      for i in 0 ..< codes.len:
        vals[i] = mpegGenValue(i, wrap)
      mpaVlcTables[t] = buildVlcTable(codes, lens, vals, 8, false)
    for q in 0 ..< 2:
      var codes = newSeq[uint32](16)
      var lens = newSeq[uint32](16)
      var vals = newSeq[uint32](16)
      for i in 0 ..< 16:
        if q == 0:
          codes[i] = MpegQuadsCodesA[i]
          lens[i] = MpegQuadsBitsA[i].uint32
        else:
          codes[i] = MpegQuadsCodesB[i]
          lens[i] = MpegQuadsBitsB[i].uint32
        vals[i] = mpegGenValue(i, 16)
      mpaVlcQuads[q] = buildVlcTable(codes, lens, vals, 8, false)
  # Intensity stereo ratios.
  for i in 0 ..< 7:
    if i == 6:
      mpaRatioMpeg1[i] = [1.0'f32, 0.0]
    else:
      let r = tan(PI / 12.0 * i.float64)
      mpaRatioMpeg1[i] = [(r / (1 + r)).float32, (1 / (1 + r)).float32]
  for s in 0 ..< 2:
    let i0 =
      if s == 0: 1.0 / sqrt(sqrt(2.0)) else: 1.0 / sqrt(2.0)
    for pos in 0 ..< 32:
      if pos == 0:
        mpaRatioMpeg2[s][pos] = [1.0'f32, 1.0]
      elif (pos and 1) != 0:
        mpaRatioMpeg2[s][pos] = [pow(i0, ((pos + 1) div 2).float64).float32, 1.0]
      else:
        mpaRatioMpeg2[s][pos] = [1.0'f32, pow(i0, (pos div 2).float64).float32]
  # Hybrid IMDCT windows.
  for i in 0 ..< 36:
    mpaImdctWin[0][i] = sin(PI / 36.0 * (i.float64 + 0.5)).float32
  for i in 0 ..< 18:
    mpaImdctWin[1][i] = sin(PI / 36.0 * (i.float64 + 0.5)).float32
  for i in 18 ..< 24:
    mpaImdctWin[1][i] = 1.0
  for i in 24 ..< 30:
    mpaImdctWin[1][i] = sin(PI / 12.0 * ((i - 18).float64 + 0.5)).float32
  for i in 0 ..< 12:
    mpaImdctWin[2][i] = sin(PI / 12.0 * (i.float64 + 0.5)).float32
  for i in 6 ..< 12:
    mpaImdctWin[3][i] = sin(PI / 12.0 * ((i - 6).float64 + 0.5)).float32
  for i in 12 ..< 18:
    mpaImdctWin[3][i] = 1.0
  for i in 18 ..< 36:
    mpaImdctWin[3][i] = sin(PI / 36.0 * (i.float64 + 0.5)).float32
  for i in 0 ..< 6:
    for k in 0 ..< 6:
      let n = (2 * (i + 3) + 6 + 1) * (2 * k + 1)
      mpaCos12[i][k] = cos(PI / 24.0 * n.float64).float32
  const antiC = [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142,
    -0.0037]
  for i in 0 ..< 8:
    let sq = sqrt(1.0 + antiC[i] * antiC[i])
    mpaAntialiasCs[i] = (1.0 / sq).float32
    mpaAntialiasCa[i] = (antiC[i] / sq).float32

# ------------------------------------------------- layer 3 side info ---

type
  FrameData* = object
    mainDataBegin*: int
    scfsi*: array[2, array[4, bool]]
    granules*: array[2, array[2, GranuleChannel]]

proc defaultGranuleChannel*(): GranuleChannel =
  GranuleChannel(part23Len: 0, bigValues: 0, globalGain: 0,
    scalefacCompress: 0, blockType: BlockType(kind: btLong),
    subblockGain: [0, 0, 0], tableSelect: [0, 0, 0], region1Start: 0,
    region2Start: 0, preflag: false, scalefacScale: false,
    count1Select: 0, scalefacs: default(array[39, int]), rzero: 0)

proc readGranuleChannelSideInfo*[L](bs: var L; ch: var GranuleChannel;
    header: FrameHeader) =
  ch.part23Len = bs.readLtrBits(12).int
  ch.bigValues = bs.readLtrBits(9).int
  if ch.bigValues > 288:
    raise decodeError("mpa: granule big_values > 288")
  ch.globalGain = bs.readLtrBits(8).int
  ch.scalefacCompress =
    if header.isMpeg1(): bs.readLtrBits(4).int
    else: bs.readLtrBits(9).int
  let windowSwitching = bs.readLtrBool()
  if windowSwitching:
    let enc = bs.readLtrBits(2).int
    let mixed = bs.readLtrBool()
    case enc
    of 0b00:
      raise decodeError("mpa: invalid block_type")
    of 0b01:
      ch.blockType = BlockType(kind: btStart)
    of 0b10:
      ch.blockType = BlockType(kind: btShort, mixed: mixed)
    else:
      ch.blockType = BlockType(kind: btEnd)
    for i in 0 ..< 2:
      ch.tableSelect[i] = bs.readLtrBits(5).int
    for i in 0 ..< 3:
      ch.subblockGain[i] = bs.readLtrBits(3).int
    if header.isMpeg2p5():
      let count =
        if ch.blockType.kind == btShort and not ch.blockType.mixed: 5 + 1
        else: 7 + 1
      ch.region1Start = SfbLongBands[header.sampleRateIdx][count]
    elif header.isMpeg1() or enc == 0b10:
      ch.region1Start = 36
    else:
      ch.region1Start = 54
    ch.region2Start = 576
  else:
    ch.blockType = BlockType(kind: btLong)
    for i in 0 ..< 3:
      ch.tableSelect[i] = bs.readLtrBits(5).int
    let region0Count = bs.readLtrBits(4).int + 1
    let region01Count = bs.readLtrBits(3).int + region0Count + 1
    ch.region1Start = SfbLongBands[header.sampleRateIdx][region0Count]
    ch.region2Start =
      if region01Count <= 22:
        SfbLongBands[header.sampleRateIdx][region01Count]
      else:
        576
  ch.preflag = if header.isMpeg1(): bs.readLtrBool() else: false
  ch.scalefacScale = bs.readLtrBool()
  ch.count1Select = bs.readLtrBits(1).int

proc readSideInfo*[L](bs: var L; header: FrameHeader;
    frame: var FrameData): int =
  frame.granules[0][0] = defaultGranuleChannel()
  frame.granules[0][1] = defaultGranuleChannel()
  frame.granules[1][0] = defaultGranuleChannel()
  frame.granules[1][1] = defaultGranuleChannel()
  if header.isMpeg1():
    frame.mainDataBegin = bs.readLtrBits(9).int
    if header.channelMode.kind == mmMono:
      bs.ignoreLtrBits(5)
    else:
      bs.ignoreLtrBits(3)
    for ch in 0 ..< header.nChannels():
      for b in 0 ..< 4:
        frame.scfsi[ch][b] = bs.readLtrBool()
  else:
    frame.mainDataBegin = bs.readLtrBits(8).int
    if header.channelMode.kind == mmMono:
      bs.ignoreLtrBits(1)
    else:
      bs.ignoreLtrBits(2)
  let ngr = header.nGranules()
  for gr in 0 ..< ngr:
    for ch in 0 ..< header.nChannels():
      readGranuleChannelSideInfo(bs, frame.granules[gr][ch], header)
  header.sideInfoLen()

proc readScaleFactorsMpeg1*[L](bs: var L; gr, ch: int;
    frame: var FrameData): int =
  var bitsRead = 0
  let (slen1, slen2) = (ScaleFactorSlen[frame.granules[gr][ch].scalefacCompress][0],
    ScaleFactorSlen[frame.granules[gr][ch].scalefacCompress][1])
  let bt = frame.granules[gr][ch].blockType
  if bt.kind == btShort:
    let nSfb = if bt.mixed: 8 + 3 * 3 else: 6 * 3
    if slen1 > 0:
      for i in 0 ..< nSfb:
        frame.granules[gr][ch].scalefacs[i] = bs.readLtrBits(slen1).int
      bitsRead += nSfb * slen1
    if slen2 > 0:
      for i in 0 ..< 6 * 3:
        frame.granules[gr][ch].scalefacs[nSfb + i] = bs.readLtrBits(slen2).int
      bitsRead += 6 * 3 * slen2
  else:
    const bands = [(0, 6), (6, 11), (11, 16), (16, 21)]
    for bi, (s, e) in bands.pairs:
      let slen = if bi < 2: slen1 else: slen2
      if gr > 0 and frame.scfsi[ch][bi]:
        let src0 = frame.granules[0][ch].scalefacs
        for i in s ..< e:
          frame.granules[gr][ch].scalefacs[i] = src0[i]
      elif slen > 0:
        for i in s ..< e:
          frame.granules[gr][ch].scalefacs[i] = bs.readLtrBits(slen).int
        bitsRead += slen * (e - s)
  bitsRead

proc readScaleFactorsMpeg2*[L](bs: var L; isIntensity: bool;
    ch: var GranuleChannel): int =
  var bitsRead = 0
  let blockIdx =
    case ch.blockType.kind
    of btShort:
      if ch.blockType.mixed: 2 else: 1
    else: 0
  var slen = [0, 0, 0, 0]
  var nsfb = [0, 0, 0, 0]
  if isIntensity:
    let sfc = ch.scalefacCompress shr 1
    var row = 0
    if sfc <= 179:
      slen = [(sfc div 36), ((sfc mod 36) div 6), ((sfc mod 36) mod 6), 0]
      row = 0
    elif sfc <= 243:
      slen = [((sfc - 180) mod 64) shr 4, ((sfc - 180) mod 16) shr 2,
        ((sfc - 180) mod 4), 0]
      row = 1
    else:
      slen = [(sfc - 244) div 3, (sfc - 244) mod 3, 0, 0]
      row = 2
    nsfb = ScaleFactorMpeg2Nsfb[row][blockIdx]
  else:
    let sfc = ch.scalefacCompress
    ch.preflag = sfc >= 500
    var row = 3
    if sfc <= 399:
      slen = [(sfc shr 4) div 5, (sfc shr 4) mod 5, (sfc mod 16) shr 2,
        sfc mod 4]
      row = 3
    elif sfc <= 499:
      slen = [((sfc - 400) shr 2) div 5, ((sfc - 400) shr 2) mod 5,
        (sfc - 400) mod 4, 0]
      row = 4
    else:
      slen = [(sfc - 500) div 3, (sfc - 500) mod 3, 0, 0]
      row = 5
    nsfb = ScaleFactorMpeg2Nsfb[row][blockIdx]
  var start = 0
  for i in 0 ..< 4:
    if slen[i] > 0:
      for k in 0 ..< nsfb[i]:
        ch.scalefacs[start + k] = bs.readLtrBits(slen[i]).int
      bitsRead += slen[i] * nsfb[i]
    start += nsfb[i]
  bitsRead

# ------------------------------------------------- layer 3 huffman ---

proc readHuffmanSamples*[L](bs: var L; ch: GranuleChannel;
    part3bits: int; buf: var openArray[float32]): int =
  if part3bits == 0:
    for i in 0 ..< 576:
      buf[i] = 0.0
    return 0
  var bitsRead = 0
  var i = 0
  let bigLen = 2 * ch.bigValues
  let ends = [min(ch.region1Start, bigLen), min(ch.region2Start, bigLen),
    min(576, bigLen)]
  for regionIdx in 0 ..< 3:
    let regionEnd = ends[regionIdx]
    let sel = ch.tableSelect[regionIdx]
    if sel > 31:
      raise decodeError("mpa: invalid huffman table select")
    let codebook =
      if sel <= 15: mpaVlcTables[sel]
      elif sel <= 23: mpaVlcTables[16]
      else: mpaVlcTables[17]
    let linbits = CodebookLinbits[sel]
    if codebook.maxCodeLen == 0:
      while i < regionEnd:
        buf[i] = 0.0
        inc i
        buf[i] = 0.0
        inc i
      continue
    while i < regionEnd and bitsRead < part3bits:
      var value, codeLen: int
      try:
        let r = bs.readLtrVlc(codebook)
        value = r.value.int
        codeLen = r.codeLen
      except EndOfStream:
        raise decodeError("mpa: huffman decode overrun")
      bitsRead += codeLen
      var x = (value shr 4).int
      var y = (value and 0xf).int
      if x > 0:
        if x == 15 and linbits > 0:
          try:
            x += bs.readLtrBits(linbits).int
          except EndOfStream:
            raise decodeError("mpa: huffman decode overrun")
          bitsRead += linbits
        var sign = 0'u32
        try:
          sign = bs.readLtrBits(1)
        except EndOfStream:
          raise decodeError("mpa: huffman decode overrun")
        bitsRead += 1
        buf[i] = (1.0 - 2.0 * sign.float32) * mpaPow43[x]
      else:
        buf[i] = 0.0
      inc i
      if y > 0:
        if y == 15 and linbits > 0:
          try:
            y += bs.readLtrBits(linbits).int
          except EndOfStream:
            raise decodeError("mpa: huffman decode overrun")
          bitsRead += linbits
        var sign = 0'u32
        try:
          sign = bs.readLtrBits(1)
        except EndOfStream:
          raise decodeError("mpa: huffman decode overrun")
        bitsRead += 1
        buf[i] = (1.0 - 2.0 * sign.float32) * mpaPow43[y]
      else:
        buf[i] = 0.0
      inc i
  let quads = mpaVlcQuads[ch.count1Select]
  while i <= 572 and bitsRead < part3bits:
    var value, codeLen: int
    try:
      let r = bs.readLtrVlc(quads)
      value = r.value.int
      codeLen = r.codeLen
    except EndOfStream:
      raise decodeError("mpa: huffman decode overrun")
    bitsRead += codeLen
    var numOnes = 0
    var v4 = value and 0xf
    while v4 != 0:
      numOnes += v4 and 1
      v4 = v4 shr 1
    var signs = 0'u32
    if numOnes > 0:
      try:
        signs = bs.readLtrBits(numOnes)
      except EndOfStream:
        raise decodeError("mpa: huffman decode overrun")
      bitsRead += numOnes
    if (value and 0x1) != 0:
      buf[i + 3] = 1.0 - 2.0 * (signs and 1).float32
      signs = signs shr 1
    else:
      buf[i + 3] = 0.0
    if (value and 0x2) != 0:
      buf[i + 2] = 1.0 - 2.0 * (signs and 1).float32
      signs = signs shr 1
    else:
      buf[i + 2] = 0.0
    if (value and 0x4) != 0:
      buf[i + 1] = 1.0 - 2.0 * (signs and 1).float32
      signs = signs shr 1
    else:
      buf[i + 1] = 0.0
    if (value and 0x8) != 0:
      buf[i + 0] = 1.0 - 2.0 * (signs and 1).float32
    else:
      buf[i + 0] = 0.0
    i += 4
  if bitsRead < part3bits:
    bs.ignoreLtrBits(part3bits - bitsRead)
  elif bitsRead > part3bits and i > bigLen:
    i -= 4
  for k in i ..< 576:
    buf[k] = 0.0
  i

# ---------------------------------------------- layer 3 requantize ---

proc requantizeLong*(ch: GranuleChannel; bands: openArray[int];
    buf: var openArray[float32]) =
  let a = ch.globalGain - 210
  let shift = if ch.scalefacScale: 2 else: 1
  var bi = 0
  while bi + 1 < bands.len:
    let s = bands[bi]
    let e = bands[bi + 1]
    if s >= ch.rzero:
      break
    var pre = 0
    if ch.preflag and bi < 22:
      pre = PreEmphasis[bi]
    let b = (ch.scalefacs[bi] + pre) shl shift
    let p2 = pow(2.0, 0.25 * (a - b).float64).float32
    let bandEnd = min(e, ch.rzero)
    for k in s ..< bandEnd:
      buf[k] = buf[k] * p2
    inc bi

proc requantizeShort*(ch: GranuleChannel; bands: openArray[int]; switch: int;
    buf: var openArray[float32]) =
  let gain = ch.globalGain - 210
  let aa = [gain - 8 * ch.subblockGain[0], gain - 8 * ch.subblockGain[1],
    gain - 8 * ch.subblockGain[2]]
  let shift = if ch.scalefacScale: 2 else: 1
  var bi = 0
  while bi + 1 < bands.len:
    let s = bands[bi]
    let e = bands[bi + 1]
    if s >= ch.rzero:
      break
    let b = ch.scalefacs[switch + bi] shl shift
    let p2 = pow(2.0, 0.25 * (aa[bi mod 3] - b).float64).float32
    let winEnd = min(e, ch.rzero)
    for k in s ..< winEnd:
      buf[k] = buf[k] * p2
    inc bi

proc requantize*(header: FrameHeader; ch: GranuleChannel;
    buf: var openArray[float32]) =
  case ch.blockType.kind
  of btShort:
    if not ch.blockType.mixed:
      requantizeShort(ch, SfbShortBands[header.sampleRateIdx], 0, buf)
    else:
      let bands = SfbMixedBands[header.sampleRateIdx]
      let switch = SfbMixedSwitchPoint[header.sampleRateIdx]
      requantizeLong(ch, bands.toOpenArray(0, switch), buf)
      requantizeShort(ch, bands.toOpenArray(switch, bands.len - 1), switch,
        buf)
  else:
    requantizeLong(ch, SfbLongBands[header.sampleRateIdx], buf)

proc zeroSamples*(buf: var openArray[float32]) =
  for i in 0 ..< buf.len:
    buf[i] = 0.0

# -------------------------------------------------- layer 3 stereo ---

proc processMidSide*(m, s: var openArray[float32]) =
  assert m.len == s.len
  for i in 0 ..< m.len:
    let l = (m[i] + s[i]) * 0.7071067811865476'f32
    let r = (m[i] - s[i]) * 0.7071067811865476'f32
    m[i] = l
    s[i] = r

proc processIntensity*(pos: int; mpeg1: bool; sfcBit: int;
    maxPos: int; midSide: bool; ch0, ch1: var openArray[float32]) =
  assert ch0.len == ch1.len
  if pos < maxPos:
    let kl =
      if mpeg1: mpaRatioMpeg1[pos][0]
      else: mpaRatioMpeg2[sfcBit][pos][0]
    let kr =
      if mpeg1: mpaRatioMpeg1[pos][1]
      else: mpaRatioMpeg2[sfcBit][pos][1]
    for i in 0 ..< ch0.len:
      let v = ch0[i]
      ch0[i] = kl * v
      ch1[i] = kr * v
  elif midSide:
    processMidSide(ch0, ch1)

proc isZeroBand*(band: openArray[float32]): bool =
  for v in band:
    if v != 0.0:
      return false
  true

proc processIntensityLong*(header: FrameHeader; granule: array[2, GranuleChannel];
    midSide: bool; maxBound: int; ch0, ch1: var openArray[float32]): int =
  let mpeg1 = header.isMpeg1()
  let sfcBit = granule[1].scalefacCompress and 1
  let invPos = if mpeg1: 7 else: 31
  let bands = SfbLongBands[header.sampleRateIdx]
  var isPos: array[22, int]
  for i in 0 ..< 22:
    isPos[i] = granule[1].scalefacs[i]
  isPos[21] = isPos[20]
  result = maxBound
  for bi in countdown(21, 0):
    let s = bands[bi]
    let e = bands[bi + 1]
    let zero = s >= granule[1].rzero or isZeroBand(ch1.toOpenArray(s, e - 1))
    if zero:
      processIntensity(isPos[bi], mpeg1, sfcBit, invPos, midSide,
        ch0.toOpenArray(s, e - 1), ch1.toOpenArray(s, e - 1))
    else:
      break
    result = s

proc processIntensityShort*(header: FrameHeader;
    granule: array[2, GranuleChannel]; mixed, midSide: bool; maxBound: int;
    ch0, ch1: var openArray[float32]): int =
  let idx = header.sampleRateIdx
  var shortBands: seq[int]
  var longBands: seq[int] = @[]
  var sfi: int
  if mixed:
    let bands = SfbMixedBands[idx]
    let switch = SfbMixedSwitchPoint[idx]
    shortBands = bands[switch .. ^1]
    longBands = bands[0 .. switch]
    sfi = bands.len - 1
  else:
    shortBands = @(SfbShortBands[idx])
    sfi = 39
  let mpeg1 = header.isMpeg1()
  let sfcBit = granule[1].scalefacCompress and 1
  let invPos = if mpeg1: 7 else: 31
  var isPos = newSeq[int](39)
  for i in 0 ..< 36:
    isPos[i] = granule[1].scalefacs[i]
  for i in 36 ..< 39:
    isPos[i] = granule[1].scalefacs[33 + (i - 36)]
  var winZero = [true, true, true]
  result = maxBound
  var found = false
  var g = shortBands.len - 4
  while g >= 0:
    let s0 = shortBands[g]
    let s1 = shortBands[g + 1]
    let s2 = shortBands[g + 2]
    let s3 = shortBands[g + 3]
    winZero[2] = winZero[2] and isZeroBand(ch1.toOpenArray(s2, s3 - 1))
    if winZero[2]:
      processIntensity(isPos[sfi - 1], mpeg1, sfcBit, invPos, midSide,
        ch0.toOpenArray(s2, s3 - 1), ch1.toOpenArray(s2, s3 - 1))
    elif midSide:
      processMidSide(ch0.toOpenArray(s2, s3 - 1),
        ch1.toOpenArray(s2, s3 - 1))
    dec sfi
    winZero[1] = winZero[1] and isZeroBand(ch1.toOpenArray(s1, s2 - 1))
    if winZero[1]:
      processIntensity(isPos[sfi - 1], mpeg1, sfcBit, invPos, midSide,
        ch0.toOpenArray(s1, s2 - 1), ch1.toOpenArray(s1, s2 - 1))
    elif midSide:
      processMidSide(ch0.toOpenArray(s1, s2 - 1),
        ch1.toOpenArray(s1, s2 - 1))
    dec sfi
    winZero[0] = winZero[0] and isZeroBand(ch1.toOpenArray(s0, s1 - 1))
    if winZero[0]:
      processIntensity(isPos[sfi - 1], mpeg1, sfcBit, invPos, midSide,
        ch0.toOpenArray(s0, s1 - 1), ch1.toOpenArray(s0, s1 - 1))
    elif midSide:
      processMidSide(ch0.toOpenArray(s0, s1 - 1),
        ch1.toOpenArray(s0, s1 - 1))
    dec sfi
    result = s0
    found = not winZero[0] and not winZero[1] and not winZero[2]
    if found:
      break
    dec g, 3
  if not found and longBands.len > 0:
    var li = longBands.len - 2
    while li >= 0:
      let s = longBands[li]
      let e = longBands[li + 1]
      if isZeroBand(ch1.toOpenArray(s, e - 1)):
        processIntensity(isPos[sfi - 1], mpeg1, sfcBit, invPos, midSide,
          ch0.toOpenArray(s, e - 1), ch1.toOpenArray(s, e - 1))
      else:
        break
      dec sfi
      result = s
      dec li

proc stereoDecode*(header: FrameHeader; granule: var array[2, GranuleChannel];
    ch: var array[2, array[576, float32]]) =
  let (midSide, intensity) =
    case header.channelMode.kind
    of mmJoint:
      (header.channelMode.midSide, header.channelMode.intensity)
    else:
      return
  let boundEnd = max(granule[0].rzero, granule[1].rzero)
  var isBound = boundEnd
  if intensity:
    if granule[1].blockType.kind == btShort:
      isBound = processIntensityShort(header, granule,
        granule[1].blockType.mixed, midSide, boundEnd,
        ch[0].toOpenArray(0, 575), ch[1].toOpenArray(0, 575))
    else:
      isBound = processIntensityLong(header, granule, midSide, boundEnd,
        ch[0].toOpenArray(0, 575), ch[1].toOpenArray(0, 575))
  if midSide and isBound > 0:
    processMidSide(ch[0].toOpenArray(0, isBound - 1),
      ch[1].toOpenArray(0, isBound - 1))
  if intensity or midSide:
    granule[0].rzero = boundEnd
    granule[1].rzero = boundEnd

# ----------------------------------------------- hybrid synthesis ---

proc reorderSamples*(header: FrameHeader; ch: var GranuleChannel;
    buf: var openArray[float32]) =
  if ch.blockType.kind != btShort:
    return
  let bands: seq[int] =
    if ch.blockType.mixed:
      let switch = SfbMixedSwitchPoint[header.sampleRateIdx]
      SfbMixedBands[header.sampleRateIdx][switch .. ^1]
    else:
      @(SfbShortBands[header.sampleRateIdx])
  var reorder = newSeq[float32](576)
  let start = bands[0]
  var i = start
  var g = 0
  while g + 3 < bands.len:
    let s0 = bands[g]
    let s1 = bands[g + 1]
    let s2 = bands[g + 2]
    let s3 = bands[g + 3]
    if s0 >= ch.rzero:
      break
    var a = s0
    var b = s1
    var c = s2
    while a < s1:
      reorder[i + 0] = buf[a]
      reorder[i + 1] = buf[b]
      reorder[i + 2] = buf[c]
      i += 3
      inc a
      inc b
      inc c
    g += 3
  for k in start ..< i:
    buf[k] = reorder[k]
  ch.rzero = max(ch.rzero, i)

proc antialiasSamples*(ch: var GranuleChannel; samples: var openArray[float32]) =
  let sbLimit =
    case ch.blockType.kind
    of btShort:
      if ch.blockType.mixed: 2 else: return
    else: 32
  let sbRzero = ch.rzero div 18
  ch.rzero = 18 * min(min(sbLimit, sbRzero + 2), 32)
  var sb = 18
  while sb < ch.rzero:
    for k in 0 ..< 8:
      let li = sb - 1 - k
      let ui = sb + k
      let lower = samples[li]
      let upper = samples[ui]
      samples[li] = lower * mpaAntialiasCs[k] - upper * mpaAntialiasCa[k]
      samples[ui] = upper * mpaAntialiasCs[k] + lower * mpaAntialiasCa[k]
    sb += 18

proc sdct9*(x: openArray[float32]; y: var openArray[float32]) =
  let a01 = x[3] + x[5]
  let a02 = x[3] - x[5]
  let a03 = x[6] + x[2]
  let a04 = x[6] - x[2]
  let a05 = x[1] + x[7]
  let a06 = x[1] - x[7]
  let a07 = x[8] + x[0]
  let a08 = x[8] - x[0]
  let a09 = x[4] + a05
  let a10 = a01 + a03
  let a11 = a10 + a07
  let a12 = a03 - a07
  let a13 = a01 - a07
  let a14 = a01 - a03
  let a15 = a02 - a04
  let a16 = a15 + a08
  let a17 = a04 + a08
  let a18 = a02 - a08
  let a19 = a02 + a04
  let a20 = 2.0'f32 * x[4] - a05
  let m1 = SdctD9[0] * a06
  let m2 = SdctD9[1] * a12
  let m3 = SdctD9[2] * a13
  let m4 = SdctD9[3] * a14
  let m5 = SdctD9[0] * a16
  let m6 = SdctD9[4] * a17
  let m7 = SdctD9[5] * a18
  let m8 = SdctD9[6] * a19
  let a21 = a20 + m2
  let a22 = a20 - m2
  let a23 = a20 + m3
  let a24 = m1 + m6
  let a25 = m1 - m6
  let a26 = m1 + m7
  y[0] = a09 + a11
  y[2] = m8 - a26
  y[4] = m4 - a21
  y[6] = m5
  y[8] = a22 - m3
  y[10] = a25 - m7
  y[12] = a11 - 2.0'f32 * a09
  y[14] = a24 + m8
  y[16] = a23 + m4

proc sdct18*(x: openArray[float32]; y: var openArray[float32]) =
  var even = newSeq[float32](9)
  for i in 0 ..< 9:
    even[i] = x[i] + x[17 - i]
  var yEven = newSeq[float32](18)
  sdct9(even, yEven)
  for i in 0 ..< 9:
    y[2 * i] = yEven[2 * i]
  var odd = newSeq[float32](9)
  for i in 0 ..< 9:
    odd[i] = SdctScale9[i] * (x[i] - x[17 - i])
  var yOdd = newSeq[float32](18)
  sdct9(odd, yOdd)
  for i in 0 ..< 9:
    y[2 * i + 1] = yOdd[2 * i]
  y[3] -= y[1]
  y[5] -= y[3]
  y[7] -= y[5]
  y[9] -= y[7]
  y[11] -= y[9]
  y[13] -= y[11]
  y[15] -= y[13]
  y[17] -= y[15]

proc dctIv18*(x: openArray[float32]; y: var openArray[float32]) =
  var s = newSeq[float32](18)
  for i in 0 ..< 18:
    s[i] = ImdctScale36[i] * x[i]
  sdct18(s, y)
  y[0] /= 2.0
  for i in 1 ..< 17:
    y[i] = y[i] / 2.0 - y[i - 1]
  y[17] = y[17] / 2.0 - y[16]

proc imdct36*(x: var openArray[float32]; window: openArray[float32];
    overlap: var openArray[float32]) =
  var dct = newSeq[float32](18)
  var xin = newSeq[float32](18)
  for i in 0 ..< 18:
    xin[i] = x[i]
  dctIv18(xin, dct)
  for i in 0 ..< 9:
    x[i] = overlap[i] + dct[9 + i] * window[i]
  for i in 9 ..< 18:
    x[i] = overlap[i] - dct[27 - i - 1] * window[i]
  for i in 18 ..< 27:
    overlap[i - 18] = -dct[27 - i - 1] * window[i]
  for i in 27 ..< 36:
    overlap[i - 18] = -dct[i - 27] * window[i]

proc imdct12win*(x: var openArray[float32]; window: openArray[float32];
    overlap: var openArray[float32]) =
  var tmp = newSeq[float32](36)
  for w in 0 ..< 3:
    for i in 0 ..< 3:
      var yl = 0.0'f32
      var yr = 0.0'f32
      for k in 0 ..< 6:
        yl += x[3 * k + w] * mpaCos12[i][k]
        yr += x[3 * k + w] * mpaCos12[i + 3][k]
      tmp[6 + 6 * w + 3 - i - 1] += -yl * window[3 - i - 1]
      tmp[6 + 6 * w + i + 3] += yl * window[i + 3]
      tmp[6 + 6 * w + i + 6] += yr * window[i + 6]
      tmp[6 + 6 * w + 12 - i - 1] += yr * window[12 - i - 1]
  for i in 0 ..< 18:
    x[i] = tmp[i] + overlap[i]
    overlap[i] = tmp[i + 18]

proc hybridSynthesis*(ch: GranuleChannel;
    overlap: var array[32, array[18, float32]];
    samples: var openArray[float32]) =
  let sbLimit = (ch.rzero + 17) div 18
  let sbSplit =
    case ch.blockType.kind
    of btShort:
      if ch.blockType.mixed: 2 else: 0
    else: 32
  if sbSplit > 0:
    let window =
      case ch.blockType.kind
      of btStart: mpaImdctWin[1]
      of btEnd: mpaImdctWin[3]
      else: mpaImdctWin[0]
    let longEnd = min(sbSplit, sbLimit)
    for sb in 0 ..< longEnd:
      let s = 18 * sb
      var sub = newSeq[float32](18)
      for i in 0 ..< 18:
        sub[i] = samples[s + i]
      imdct36(sub, window, overlap[sb])
      for i in 0 ..< 18:
        samples[s + i] = sub[i]
  if sbSplit < 32:
    let window = mpaImdctWin[2]
    let shortBegin = min(sbSplit, sbLimit)
    for sb in shortBegin ..< sbLimit:
      let s = 18 * sb
      var sub = newSeq[float32](18)
      for i in 0 ..< 18:
        sub[i] = samples[s + i]
      imdct12win(sub, window, overlap[sb])
      for i in 0 ..< 18:
        samples[s + i] = sub[i]
  for sb in sbLimit ..< 32:
    let s = 18 * sb
    for i in 0 ..< 18:
      samples[s + i] = overlap[sb][i]
      overlap[sb][i] = 0.0

proc frequencyInversion*(samples: var openArray[float32]) =
  var i = 18
  while i < 576:
    var j = i
    while j < i + 16:
      samples[j + 1] = -samples[j + 1]
      samples[j + 3] = -samples[j + 3]
      samples[j + 5] = -samples[j + 5]
      samples[j + 7] = -samples[j + 7]
      j += 8
    samples[i + 18 - 1] = -samples[i + 18 - 1]
    i += 36

# ------------------------------------------------ layer 3 decode ---

proc reservoirFill*(rsv: var MpaReservoir; mainData: openArray[uint8];
    mainDataBegin: int): int =
  let mainLen = mainData.len
  let mainEnd = mainDataBegin + mainLen
  if mainEnd > 2048:
    raise decodeError("mpa: invalid main_data length, will exceed resevoir buffer")
  let unread = rsv.len - rsv.consumed
  var underflow = 0
  if mainDataBegin <= unread:
    for i in 0 ..< mainDataBegin:
      rsv.buf[i] = rsv.buf[rsv.len - mainDataBegin + i]
    for i in 0 ..< mainLen:
      rsv.buf[mainDataBegin + i] = mainData[i]
    rsv.len = mainEnd
  else:
    for i in 0 ..< unread:
      rsv.buf[i] = rsv.buf[rsv.len - unread + i]
    for i in 0 ..< mainLen:
      rsv.buf[unread + i] = mainData[i]
    rsv.len = unread + mainLen
    underflow = mainDataBegin - unread
  rsv.consumed = 0
  underflow

proc reservoirBytes*(rsv: MpaReservoir): seq[uint8] =
  result = newSeq[uint8](rsv.len - rsv.consumed)
  for i in 0 ..< result.len:
    result[i] = rsv.buf[rsv.consumed + i]

proc reservoirConsume*(rsv: var MpaReservoir; n: int) =
  rsv.consumed = min(rsv.len, rsv.consumed + n)

proc reservoirClear*(rsv: var MpaReservoir) =
  rsv.len = 0
  rsv.consumed = 0

proc readMainData*(state: var Layer3State; header: FrameHeader;
    underflowBytes: int; frame: var FrameData): int =
  let mainData = reservoirBytes(state.reservoir)
  var part23Begin = 0
  var part23Skipped = 0
  let underflowBits = underflowBytes * 8
  for gr in 0 ..< header.nGranules():
    if part23Skipped < underflowBits:
      for ch in 0 ..< header.nChannels():
        zeroSamples(state.samples[gr][ch].toOpenArray(0, 575))
        part23Skipped += frame.granules[gr][ch].part23Len
      if part23Skipped > underflowBits:
        part23Begin = part23Skipped - underflowBits
      continue
    for ch in 0 ..< header.nChannels():
      let byteIdx = part23Begin shr 3
      if byteIdx > mainData.len:
        raise decodeError("mpa: invalid main_data offset")
      var bs = newLtrBitReader(mainData.toOpenArray(byteIdx, mainData.len - 1))
      let bitIdx = part23Begin and 0x7
      if bitIdx > 0:
        try:
          bs.ignoreLtrBits(bitIdx)
        except EndOfStream:
          raise decodeError("mpa: invalid main_data offset")
      let part2len =
        if header.isMpeg1():
          readScaleFactorsMpeg1(bs, gr, ch, frame)
        else:
          let isco =
            ch > 0 and header.channelMode.kind == mmJoint and
            header.channelMode.intensity
          readScaleFactorsMpeg2(bs, isco, frame.granules[gr][ch])
      let part23len = frame.granules[gr][ch].part23Len
      if part2len > part23len:
        raise decodeError("mpa: part2_3_length is not valid")
      let part3len = part23len - part2len
      let rzero =
        try:
          readHuffmanSamples(bs, frame.granules[gr][ch], part3len,
            state.samples[gr][ch].toOpenArray(0, 575))
        except EndOfStream:
          raise decodeError("mpa: huffman decode overrun")
      frame.granules[gr][ch].rzero = rzero
      part23Begin += part23len
  (part23Begin + 7) shr 3

proc decodeLayer3Data[L](header: FrameHeader; bs: var L;
    main: openArray[uint8]; state: var Layer3State; buf: var AudioSamples) =
  ## Layer 3 core over any MSB-first bit cursor. `main` is the frame body
  ## for reservoir fill (a zero-copy view on the mapped path).
  if header.hasCrc:
    discard bs.readLtrBits(16)
  var frame = FrameData()
  try:
    discard readSideInfo(bs, header, frame)
  except EndOfStream as e:
    reservoirClear(state.reservoir)
    raise decodeError("mpa: truncated side info")
  except AudioError:
    reservoirClear(state.reservoir)
    raise
  let sideLen = header.sideInfoLen()
  # `main` starts after the 4-byte header; skip the 2 CRC bytes when the
  # protection bit is set so the reservoir sees side info + main data.
  let bodyOff = if header.hasCrc: 2 else: 0
  if sideLen + bodyOff > main.len:
    reservoirClear(state.reservoir)
    raise decodeError("mpa: truncated side info")
  let underflow =
    try:
      reservoirFill(state.reservoir,
        main.toOpenArray(sideLen + bodyOff, main.len - 1),
        frame.mainDataBegin)
    except AudioError:
      reservoirClear(state.reservoir)
      raise
  try:
    let used = readMainData(state, header, underflow, frame)
    reservoirConsume(state.reservoir, used)
  except AudioError:
    reservoirClear(state.reservoir)
    raise
  let ngr = header.nGranules()
  buf.f32.renderWith(576 * ngr, i):
    discard i
  for gr in 0 ..< ngr:
    requantize(header, frame.granules[gr][0],
      state.samples[gr][0].toOpenArray(0, 575))
    if header.channelMode.kind != mmMono:
      requantize(header, frame.granules[gr][1],
        state.samples[gr][1].toOpenArray(0, 575))
      stereoDecode(header, frame.granules[gr], state.samples[gr])
    for ch in 0 ..< header.nChannels():
      if ch >= buf.f32.planes.len:
        raise decodeError("mp3: missing audio plane")
      reorderSamples(header, frame.granules[gr][ch],
        state.samples[gr][ch].toOpenArray(0, 575))
      antialiasSamples(frame.granules[gr][ch],
        state.samples[gr][ch].toOpenArray(0, 575))
      hybridSynthesis(frame.granules[gr][ch], state.overlap[ch],
        state.samples[gr][ch].toOpenArray(0, 575))
      frequencyInversion(state.samples[gr][ch].toOpenArray(0, 575))
      synthesis(state.synth[ch], 18, state.samples[gr][ch],
        buf.f32.planes[ch].toOpenArray(gr * 576, gr * 576 + 575))

proc decodeLayer3Frame*(header: FrameHeader; body: openArray[uint8];
    state: var Layer3State; buf: var AudioSamples) =
  ## Owning entry: copies `body` into a cached reader (as before).
  var bs = newLtrBitReader(body)
  decodeLayer3Data(header, bs, body, state, buf)

# ------------------------------------------------------------- decoder ---

type
  MpaLayerState* = object
    l1synth*: array[2, SynthState]
    l2synth*: array[2, SynthState]
    l3*: Layer3State

  MpaDecoder* = ref object of AudioDecoder
    opts*: AudioDecoderOptions
    params*: AudioCodecParameters
    state*: MpaLayerState
    spec*: AudioSpec
    hasSpec*: bool
    buf*: AudioSamples # sfF32

proc newMpaLayerState(codec: AudioCodecId): MpaLayerState =
  if codec != CodecMp1 and codec != CodecMp2 and codec != CodecMp3:
    raise unsupportedError("mpa: invalid codec")
  MpaLayerState()

proc newMpaDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): MpaDecoder =
  if params.codec != CodecMp1 and params.codec != CodecMp2 and
      params.codec != CodecMp3:
    raise unsupportedError("mpa: invalid codec")
  initMpaTables()
  MpaDecoder(opts: opts, params: params, state: newMpaLayerState(params.codec),
    spec: newAudioSpec(44_100, ChStereo), hasSpec: false,
    buf: newAudioSamples(sfF32, newAudioSpec(44_100, ChStereo), 1152))

proc decodeMpaHead(d: MpaDecoder; header: FrameHeader) =
  ## Spec setup + buffer clear, shared by the owning and zero-copy paths.
  let spec = specOfHeader(header)
  if not d.hasSpec:
    d.spec = spec
    d.hasSpec = true
    d.buf = newAudioSamples(sfF32, spec, 1152)
  elif d.spec.rate != spec.rate or
      d.spec.channels != spec.channels:
    raise decodeError("mpa: invalid audio buffer signal spec for packet")
  d.buf.f32.clear()

proc decodeMpaFrame(d: MpaDecoder; data: seq[uint8]) =
  var r = newReader(data)
  if r.remaining() < 4:
    raise decodeError("mpa: truncated frame")
  let header = parseFrameHeader(r.readU32Be())
  if header.frameSize != r.remaining():
    raise decodeError("mpa: invalid packet length")
  d.decodeMpaHead(header)
  let body = r.readBytes(r.remaining())
  case d.params.codec
  of CodecMp1:
    if header.layer != Layer1:
      raise decodeError("mpa: invalid mpeg audio layer")
    decodeLayer1Frame(header, body, d.state.l1synth, d.buf)
  of CodecMp2:
    if header.layer != Layer2:
      raise decodeError("mpa: invalid mpeg audio layer")
    decodeLayer2Frame(header, body, d.state.l2synth, d.buf)
  of CodecMp3:
    if header.layer != Layer3:
      raise decodeError("mpa: invalid mpeg audio layer")
    decodeLayer3Frame(header, body, d.state.l3, d.buf)
  else:
    raise decodeError("mpa: invalid mpeg audio layer")

proc decodeMpaWin*(d: MpaDecoder; win: ByteWindow) =
  ## Zero-copy decode straight from a byte window (mapping or pool).
  ## No packet copy; reservoir bytes still copy into owned state (bounded).
  var vr = viewReaderOf(win)
  if vr.remaining() < MpegHeaderLen:
    raise decodeError("mpa: truncated frame")
  let header = parseFrameHeader(vr.readU32Be())
  if header.frameSize != vr.remaining():
    raise decodeError("mpa: invalid packet length")
  d.decodeMpaHead(header)
  var vbs = vr.restLtr()
  try:
    case d.params.codec
    of CodecMp1:
      if header.layer != Layer1:
        raise decodeError("mpa: invalid mpeg audio layer")
      decodeLayer1Data(header, vbs, d.state.l1synth, d.buf)
    of CodecMp2:
      if header.layer != Layer2:
        raise decodeError("mpa: invalid mpeg audio layer")
      decodeLayer2Data(header, vbs, d.state.l2synth, d.buf)
    of CodecMp3:
      if header.layer != Layer3:
        raise decodeError("mpa: invalid mpeg audio layer")
      let main = subWindow(win, MpegHeaderLen, header.frameSize)
      decodeLayer3Data(header, vbs,
        toOpenArray(main.base, 0, main.len - 1),
        d.state.l3, d.buf)
    else:
      raise decodeError("mpa: invalid mpeg audio layer")
  except AudioError:
    d.buf.clearSamples()
    raise

proc decodeMpaView*(d: MpaDecoder; src: MappedSource; off, len: int) =
  ## Zero-copy decode straight from a mapping window.
  d.decodeMpaWin(byteWindow(src, off, len))

proc applyGaplessTrims(d: MpaDecoder; trimStart, trimEnd: Duration) =
  if d.opts.gapless and d.buf.framesOf() > 0:
    let total = d.buf.framesOf()
    let dropFirst = min(trimStart.get.int, total)
    let keep = total - dropFirst
    let dropLast = min(trimEnd.get.int, keep)
    if dropFirst > 0 or dropLast > 0:
      d.buf.f32.shift(dropFirst)
      d.buf.f32.truncate(d.buf.f32.numFrames - dropLast)

method codecParams*(d: MpaDecoder): AudioCodecParameters = d.params

method reset*(d: MpaDecoder) =
  d.state = newMpaLayerState(d.params.codec)

method decodePacket*(d: MpaDecoder; pkt: Packet): AudioSamples =
  try:
    d.decodeMpaFrame(pkt.data)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  except IndexDefect, RangeDefect:
    d.buf.clearSamples()
    raise decodeError("mpa: invalid bitstream")
  d.applyGaplessTrims(pkt.trimStart, pkt.trimEnd)
  d.buf

proc decodePacketView*(d: MpaDecoder; v: PacketView): AudioSamples =
  ## View-based `decodePacket`: identical output (incl. gapless trims),
  ## no packet copy.
  try:
    d.decodeMpaWin(v.win)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  except IndexDefect, RangeDefect:
    d.buf.clearSamples()
    raise decodeError("mpa: invalid bitstream")
  d.applyGaplessTrims(v.trimStart, v.trimEnd)
  d.buf

method lastDecoded*(d: MpaDecoder): AudioSamples = d.buf

proc mpaDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newMpaDecoder(params, opts)

proc registerMpa*() =
  registerAudioDecoder(CodecMp1, mpaDecoderFactory)
  registerAudioDecoder(CodecMp2, mpaDecoderFactory)
  registerAudioDecoder(CodecMp3, mpaDecoderFactory)
