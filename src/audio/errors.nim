## Error types for audio.
##
## Mirrors `symphonia-core/src/errors.rs`. Symphonia reports errors as
## `Result<T, Error>` values; the idiomatic Nim equivalent is raising a
## `CatchableError` carrying a `kind` discriminator, which is what this
## module provides.

type
  AudioErrorKind* = enum
    ekIo            ## I/O failure reading, writing, or seeking the stream.
    ekDecode        ## Malformed stream data, could not decode or demux.
    ekSeek          ## Seek failed, see `seekKind` for the reason.
    ekUnsupported   ## Unsupported container or codec feature encountered.
    ekLimit         ## A safety limit was reached (DoS protection).
    ekResetRequired ## Demuxer or decoder state changed, reset to continue.

  SeekErrorKind* = enum
    skUnseekable   ## Stream is not seekable at all.
    skForwardOnly  ## Stream can only be seeked forward.
    skOutOfRange   ## Timestamp is out of range for the stream.
    skInvalidTrack ## Track ID is invalid.

  AudioError* = object of CatchableError
    kind*: AudioErrorKind
    seekKind*: SeekErrorKind

  EndOfStream* = object of AudioError
    ## Exhausted input mid-symbol. Floor/residue readers treat this as a
    ## legal early end (like Symphonia's ErrorKind::Other); anything else
    ## propagates it as a failure.

proc newAudioError*(
  kind: AudioErrorKind, msg: string, seekKind = skUnseekable
): ref AudioError =
  ## Builds an `AudioError` without raising it.
  result = newException(AudioError, msg)
  result.kind = kind
  result.seekKind = seekKind

proc ioError*(msg: string): ref AudioError {.inline.} =
  newAudioError(ekIo, "io error: " & msg)

proc decodeError*(msg: string): ref AudioError {.inline.} =
  newAudioError(ekDecode, "malformed stream: " & msg)

proc seekError*(kind: SeekErrorKind): ref AudioError =
  let msg =
    case kind
    of skUnseekable: "stream is not seekable"
    of skForwardOnly: "stream can only be seeked forward"
    of skOutOfRange: "requested seek timestamp is out-of-range for stream"
    of skInvalidTrack: "invalid track id"
  newAudioError(ekSeek, "seek error: " & msg, kind)

proc unsupportedError*(feature: string): ref AudioError {.inline.} =
  newAudioError(ekUnsupported, "unsupported feature: " & feature)

proc limitError*(constraint: string): ref AudioError {.inline.} =
  newAudioError(ekLimit, "limit reached: " & constraint)

proc resetError*(): ref AudioError {.inline.} =
  newAudioError(ekResetRequired, "decoder needs to be reset")

template raiseDecode*(msg: string) =
  ## Raises an `ekDecode` error. `msg` is evaluated once.
  raise decodeError(msg)

template raiseUnsupported*(feature: string) =
  raise unsupportedError(feature)

template raiseLimit*(constraint: string) =
  raise limitError(constraint)

template checkDecode*(cond: bool, msg: string) =
  ## Raises `ekDecode` with `msg` unless `cond` holds.
  block:
    let ok {.inject.} = cond
    if not ok:
      raise decodeError(msg)
