## Media packets: one decodable unit of audio with timing.
##
## Ports `symphonia-core/src/packet.rs`. `dur` counts presentable frames;
## `blockDur = dur + trimStart + trimEnd` counts decoded frames, so gapless
## decoders trim delay/padding when the packet carries them.

import ./units

type
  Packet* = object
    trackId*: uint32
    pts*: Timestamp
    dts*: Timestamp
    dur*: Duration
    trimStart*: Duration ## Leading delay frames to discard (gapless).
    trimEnd*: Duration   ## Trailing padding frames to discard.
    data*: seq[uint8]

proc newPacket*(trackId: uint32; pts: Timestamp; dur: Duration;
    data: seq[uint8]): Packet =
  Packet(trackId: trackId, pts: pts, dts: pts, dur: dur,
    trimStart: ZeroDuration, trimEnd: ZeroDuration, data: data)

proc blockDur*(p: Packet): Duration =
  ## Total decoded frames including trims.
  p.dur.saturatingAdd(p.trimStart).saturatingAdd(p.trimEnd)
