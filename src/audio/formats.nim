## Container format types: tracks, seek model, probe helpers.
##
## Ports `symphonia-core/src/formats/mod.rs` (audio subset). Video tracks,
## attachments, and chapters arrive with the MP4/MKV phases.

import std/hashes
import std/options
import ./units
import ./codecs

type
  FormatId* = distinct uint32

proc `==`*(a, b: FormatId): bool {.inline.} = a.uint32 == b.uint32
proc hash*(id: FormatId): Hash {.inline.} = hash(id.uint32)

const
  FormatNull* = FormatId(0x0)
  FormatWave* = FormatId(0x100)
  FormatAiff* = FormatId(0x101)
  FormatCaf* = FormatId(0x103)
  FormatOgg* = FormatId(0x108)
  FormatFlac* = FormatId(0x109)
  FormatWavPack* = FormatId(0x10a)
  FormatIsoMp4* = FormatId(0x10b)
  FormatMkv* = FormatId(0x10c)
  FormatMp3* = FormatId(0x106)

type
  SeekMode* = enum
    smCoarse   ## Best-effort seek before or after the target.
    smAccurate ## Seek at or before the target.

  SeekTo* = object
    case byTime*: bool
    of true:
      time*: Time
      timeTrackId*: Option[uint32]
    of false:
      ts*: Timestamp
      tsTrackId*: uint32

  SeekedTo* = object
    trackId*: uint32
    requiredTs*: Timestamp
    actualTs*: Timestamp

  Track* = object
    id*: uint32
    codec*: AudioCodecParameters
    timeBase*: Option[TimeBase]
    numFrames*: Option[uint64]
    duration*: Option[Duration]
    startTs*: Timestamp

  MediaInfo* = object
    timeBase*: Option[TimeBase]
    duration*: Option[Duration]
    startTs*: Timestamp

  FormatInfo* = object
    id*: FormatId
    shortName*: string
    longName*: string

  FormatOptions* = object
    prebuildSeekIndex*: bool
    seekIndexFillPeriodMs*: uint16

proc defaultFormatOptions*(): FormatOptions {.inline.} =
  FormatOptions(prebuildSeekIndex: false, seekIndexFillPeriodMs: 1000)

proc newTrack*(id: uint32; codec: AudioCodecParameters): Track =
  ## Derives `timeBase` from the sample rate when present.
  result.id = id
  result.codec = codec
  result.startTs = ZeroTimestamp
  if codec.sampleRate.isSome:
    let rate = codec.sampleRate.get
    if rate != 0:
      result.timeBase = tryFromRecip(rate)

proc seekToTimestamp*(ts: Timestamp; trackId: uint32): SeekTo {.inline.} =
  SeekTo(byTime: false, ts: ts, tsTrackId: trackId)

proc seekToTime*(t: Time; trackId = none(uint32)): SeekTo {.inline.} =
  SeekTo(byTime: true, time: t, timeTrackId: trackId)
