## Metadata tags.
##
## Minimal port of `symphonia-core/src/meta.rs` for Phase 2 (WAV INFO).
## Full `StandardTag` vocabulary, visuals, and reader traits arrive with
## the metadata phase.

import std/options

type
  RawValueKind* = enum
    rvString
    rvSignedInt
    rvUnsignedInt
    rvFloat
    rvBoolean
    rvBinary

  RawValue* = object
    case kind*: RawValueKind
    of rvString:
      str*: string
    of rvSignedInt:
      sint*: int64
    of rvUnsignedInt:
      uint*: uint64
    of rvFloat:
      flt*: float64
    of rvBoolean:
      boolean*: bool
    of rvBinary:
      binary*: seq[uint8]

  Tag* = object
    ## `key` is the native key (`INAM`, `TIT2`, ...), `stdKey` the
    ## normalized name when known (`track_title`, `artist`, ...).
    key*: string
    stdKey*: Option[string]
    value*: RawValue

  MetadataRevision* = object
    tags*: seq[Tag]

  MetadataLog* = object
    revisions*: seq[MetadataRevision]

proc strValue*(s: string): RawValue {.inline.} = RawValue(kind: rvString, str: s)

proc newTag*(key: string; value: RawValue; stdKey = none(string)): Tag {.inline.} =
  Tag(key: key, stdKey: stdKey, value: value)

proc addTag*(rev: var MetadataRevision; tag: Tag) {.inline.} =
  rev.tags.add(tag)

proc push*(log: var MetadataLog; rev: MetadataRevision) {.inline.} =
  log.revisions.add(rev)

proc latest*(log: MetadataLog): Option[MetadataRevision] =
  if log.revisions.len == 0: none(MetadataRevision)
  else: some(log.revisions[^1])
