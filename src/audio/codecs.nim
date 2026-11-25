## Codec identifiers, parameters, decoder trait, and registry.
##
## Ports `symphonia-core/src/codecs/{mod,audio,registry}.rs`. Codec ID
## values are identical to Symphonia's `well_known` IDs. Video/subtitle
## parameter variants arrive with the MP4/MKV phases; until then tracks
## carry audio parameters directly.

import std/hashes
import std/options
import std/strutils
import std/tables
import ./audio
import ./errors
import ./packet

type
  AudioCodecId* = distinct uint32

proc `==`*(a, b: AudioCodecId): bool {.inline.} = a.uint32 == b.uint32
proc hash*(id: AudioCodecId): Hash {.inline.} = hash(id.uint32)
proc `$`*(id: AudioCodecId): string = "0x" & id.uint32.toHex(4)

const
  CodecNull* = AudioCodecId(0x0)
  # Signed integer PCM, interleaved.
  CodecPcmS32Le* = AudioCodecId(0x100)
  CodecPcmS32Be* = AudioCodecId(0x102)
  CodecPcmS24Le* = AudioCodecId(0x104)
  CodecPcmS24Be* = AudioCodecId(0x106)
  CodecPcmS16Le* = AudioCodecId(0x108)
  CodecPcmS16Be* = AudioCodecId(0x10a)
  CodecPcmS8* = AudioCodecId(0x10c)
  # Unsigned integer PCM, interleaved.
  CodecPcmU32Le* = AudioCodecId(0x10e)
  CodecPcmU32Be* = AudioCodecId(0x110)
  CodecPcmU24Le* = AudioCodecId(0x112)
  CodecPcmU24Be* = AudioCodecId(0x114)
  CodecPcmU16Le* = AudioCodecId(0x116)
  CodecPcmU16Be* = AudioCodecId(0x118)
  CodecPcmU8* = AudioCodecId(0x11a)
  # Floating point PCM, interleaved.
  CodecPcmF32Le* = AudioCodecId(0x11c)
  CodecPcmF32Be* = AudioCodecId(0x11e)
  CodecPcmF64Le* = AudioCodecId(0x120)
  CodecPcmF64Be* = AudioCodecId(0x122)
  # Log PCM.
  CodecPcmALaw* = AudioCodecId(0x124)
  CodecPcmMuLaw* = AudioCodecId(0x125)
  # Planar PCM (parsed, decode support lands with the filter phase).
  CodecPcmS32LePlanar* = AudioCodecId(0x101)
  CodecPcmS32BePlanar* = AudioCodecId(0x103)
  CodecPcmS24LePlanar* = AudioCodecId(0x105)
  CodecPcmS24BePlanar* = AudioCodecId(0x107)
  CodecPcmS16LePlanar* = AudioCodecId(0x109)
  CodecPcmS16BePlanar* = AudioCodecId(0x10b)
  CodecPcmS8Planar* = AudioCodecId(0x10d)
  CodecPcmU32LePlanar* = AudioCodecId(0x10f)
  CodecPcmU32BePlanar* = AudioCodecId(0x111)
  CodecPcmU24LePlanar* = AudioCodecId(0x113)
  CodecPcmU24BePlanar* = AudioCodecId(0x115)
  CodecPcmU16LePlanar* = AudioCodecId(0x117)
  CodecPcmU16BePlanar* = AudioCodecId(0x119)
  CodecPcmU8Planar* = AudioCodecId(0x11b)
  CodecPcmF32LePlanar* = AudioCodecId(0x11d)
  CodecPcmF32BePlanar* = AudioCodecId(0x11f)
  CodecPcmF64LePlanar* = AudioCodecId(0x121)
  CodecPcmF64BePlanar* = AudioCodecId(0x123)
  # ADPCM.
  CodecAdpcmG722* = AudioCodecId(0x200)
  CodecAdpcmG726* = AudioCodecId(0x201)
  CodecAdpcmG726Le* = AudioCodecId(0x202)
  CodecAdpcmMs* = AudioCodecId(0x203)
  CodecAdpcmImaWav* = AudioCodecId(0x204)
  CodecAdpcmImaQt* = AudioCodecId(0x205)
  # Lossy.
  CodecVorbis* = AudioCodecId(0x1000)
  CodecOpus* = AudioCodecId(0x1001)
  CodecMp1* = AudioCodecId(0x1004)
  CodecMp2* = AudioCodecId(0x1005)
  CodecMp3* = AudioCodecId(0x1006)
  CodecAac* = AudioCodecId(0x1007)
  # Lossless.
  CodecFlac* = AudioCodecId(0x2000)
  CodecWavPack* = AudioCodecId(0x2001)
  CodecAlac* = AudioCodecId(0x2003)

type
  AudioCodecParameters* = object
    codec*: AudioCodecId
    sampleRate*: Option[uint32]
    sampleFormat*: Option[SampleFormat]
    bitsPerSample*: Option[uint32]       ## Decoded width.
    bitsPerCodedSample*: Option[uint32]  ## Coded width, defaults to decoded.
    channels*: Option[Channels]
    maxFramesPerPacket*: Option[uint64]
    framesPerBlock*: Option[uint64]
    verificationMd5*: Option[array[16, uint8]]
    extraData*: seq[uint8]

  AudioDecoderOptions* = object
    gapless*: bool ## Trim delay/padding (default true).
    verify*: bool  ## Verify checksums (default false).

  FinalizeResult* = object
    verifyOk*: Option[bool]

proc defaultDecoderOptions*(): AudioDecoderOptions {.inline.} =
  AudioDecoderOptions(gapless: true, verify: false)

proc forCodec*(codec: AudioCodecId): AudioCodecParameters {.inline.} =
  AudioCodecParameters(codec: codec)

type
  AudioDecoder* = ref object of RootObj
    ## Base decoder. Concrete decoders override `decodePacket`.

method reset*(d: AudioDecoder) {.base.} =
  ## Resets state after a discontinuity or seek. Default: stateless.
  discard

method codecParams*(d: AudioDecoder): AudioCodecParameters {.base.} =
  raise unsupportedError("codecParams not implemented")

method decodePacket*(d: AudioDecoder; pkt: Packet): AudioSamples {.base.} =
  raise unsupportedError("decodePacket not implemented")

method finalize*(d: AudioDecoder): FinalizeResult {.base.} =
  FinalizeResult(verifyOk: none(bool))

method lastDecoded*(d: AudioDecoder): AudioSamples {.base.} =
  raise unsupportedError("lastDecoded not implemented")

type
  DecoderFactory* = proc(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder {.closure.}

var audioRegistry* {.global.}: Table[AudioCodecId, DecoderFactory]

proc registerAudioDecoder*(id: AudioCodecId; factory: DecoderFactory) =
  ## Registers (or replaces) the decoder factory for `id`.
  audioRegistry[id] = factory

proc makeAudioDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): AudioDecoder =
  if not audioRegistry.hasKey(params.codec):
    raise unsupportedError("no decoder registered for codec " & $params.codec)
  audioRegistry[params.codec](params, opts)

proc isDecoderRegistered*(id: AudioCodecId): bool =
  audioRegistry.hasKey(id)
