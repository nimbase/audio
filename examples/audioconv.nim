## Audio converter CLI: decode WAV/MP3/FLAC, re-encode to WAV/MP3/FLAC.
##
## Build (release recommended; MP3 encode is compute-heavy):
##   clue build examples/audioconv.nim --out:/tmp/audioconv --release
##
## Usage:
##   audioconv <input> <output> [--bitrate=N] [--vbr]
##
## Format is inferred from the file extension. MP3 defaults to 128k
## CBR stereo/mono matching the input; --bitrate sets CBR, --vbr
## (32..192k window) enables VBR. WAV/FLAC are lossless.

import std/options
import std/math
import std/parseopt
import std/strutils
import audio/audio
import audio/checksum
import audio/codecs
import audio/codecs/flac
import audio/codecs/mpa
import audio/codecs/mpaenc
import audio/codecs/pcm
import audio/errors
import audio/formats
import audio/formats/flac as flacfmt
import audio/formats/mpa as mpafmt
import audio/formats/wav
import audio/io
import audio/packet
import audio/source
import audio/units

proc die(msg: string) =
  stderr.writeLine("audioconv: " & msg)
  quit(1)

proc extOf(path: string): string =
  let dot = path.rfind('.')
  if dot < 0:
    die("no extension in " & path)
  path[dot + 1 .. ^1].toLowerAscii()

proc decodeAllSamples(path: string): AudioSamples =
  ## Decodes the whole file into one buffer (native sample format).
  let data = readFile(path)
  var raw = newSeq[uint8](data.len)
  for i, c in data:
    raw[i] = cast[uint8](c)
  case extOf(path)
  of "wav":
    let w = openWav(raw)
    let dec = newPcmDecoder(w.params)
    var total = 0
    var first = true
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      if first:
        result = newAudioSamples(s.format, s.specOf(), 0)
        first = false
      total += s.framesOf()
    # Second pass fills (reader is cheap to reopen; keeps code simple).
    let w2 = openWav(raw)
    let dec2 = newPcmDecoder(w2.params)
    var off = 0
    while true:
      let pkt = w2.nextPacket()
      if pkt.isNone:
        break
      let s = dec2.decodePacket(pkt.get)
      case s.format
      of sfS16:
        result.s16.growCapacity(off + s.framesOf())
        for p in 0 ..< s.s16.planes.len:
          for i in 0 ..< s.framesOf():
            result.s16.planes[p][off + i] = s.s16.planes[p][i]
        result.s16.numFrames = off + s.framesOf()
      of sfS24:
        result.s24.growCapacity(off + s.framesOf())
        for p in 0 ..< s.s24.planes.len:
          for i in 0 ..< s.framesOf():
            result.s24.planes[p][off + i] = s.s24.planes[p][i]
        result.s24.numFrames = off + s.framesOf()
      of sfS32:
        result.s32.growCapacity(off + s.framesOf())
        for p in 0 ..< s.s32.planes.len:
          for i in 0 ..< s.framesOf():
            result.s32.planes[p][off + i] = s.s32.planes[p][i]
        result.s32.numFrames = off + s.framesOf()
      of sfF32:
        result.f32.growCapacity(off + s.framesOf())
        for p in 0 ..< s.f32.planes.len:
          for i in 0 ..< s.framesOf():
            result.f32.planes[p][off + i] = s.f32.planes[p][i]
        result.f32.numFrames = off + s.framesOf()
      else:
        die("unsupported wav sample format " & $s.format)
      off += s.framesOf()
  of "mp3":
    let w = mpafmt.openMpa(raw)
    let dec = newMpaDecoder(w.tracks[0].codec,
      AudioDecoderOptions(gapless: true, verify: false))
    let nch = w.tracks[0].codec.channels.get.channelCount()
    let rate = w.tracks[0].codec.sampleRate.get
    var planes = newSeq[seq[float32]](nch)
    for p in 0 ..< nch:
      planes[p] = @[]
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      for p in 0 ..< nch:
        for i in 0 ..< s.framesOf():
          planes[p].add(s.f32.planes[p][i])
    result = newAudioSamples(sfF32, newAudioSpec(rate,
      if nch == 1: positioned(PosFrontCenter) else: ChStereo),
      planes[0].len)
    for p in 0 ..< nch:
      for i in 0 ..< planes[p].len:
        result.f32.planes[p][i] = planes[p][i]
    result.f32.numFrames = planes[0].len
  of "flac":
    let w = openFlac(raw)
    let dec = newFlacDecoder(w.params,
      AudioDecoderOptions(gapless: true, verify: false))
    var planes = newSeq[seq[int32]]()
    var rate = 44_100'u32
    var nch = 0
    while true:
      let pkt = w.nextPacket()
      if pkt.isNone:
        break
      let s = dec.decodePacket(pkt.get)
      if nch == 0:
        nch = s.s32.planes.len
        rate = s.specOf().rate
        planes = newSeq[seq[int32]](nch)
        for p in 0 ..< nch:
          planes[p] = @[]
      for p in 0 ..< nch:
        for i in 0 ..< s.framesOf():
          planes[p].add(s.s32.planes[p][i])
    let spec = newAudioSpec(rate,
      if nch == 1: positioned(PosFrontCenter) else: ChStereo)
    result = newAudioSamples(sfS32, spec, planes[0].len)
    for p in 0 ..< nch:
      for i in 0 ..< planes[p].len:
        result.s32.planes[p][i] = planes[p][i]
    result.s32.numFrames = planes[0].len
  else:
    die("unsupported input format (want .wav/.mp3/.flac)")

proc toS16Copy(src: AudioSamples): AudioSamples =
  ## s24/s32/f32/f64 -> s16 (mp3/adpcm encoder input). s16 passes through.
  if src.format == sfS16:
    return src
  let n = src.framesOf()
  result = newAudioSamples(sfS16, src.specOf(), n)
  for p in 0 ..< src.specOf().channels.channelCount():
    for i in 0 ..< n:
      let v =
        case src.format
        of sfS24: src.s24.planes[p][i].float / 256.0
        of sfS32: (src.s32.planes[p][i] shr 16).float
        of sfF32: src.f32.planes[p][i] * 32768.0
        of sfF64: src.f64.planes[p][i] * 32768.0
        else: 0.0
      result.s16.planes[p][i] = clamp(round(v), -32768.0, 32767.0).int16
  result.s16.numFrames = n

proc main() =
  var input = ""
  var output = ""
  var bitrate = 128
  var vbr = false
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "bitrate", "b":
        try:
          bitrate = parseInt(p.val)
        except ValueError:
          die("bad --bitrate " & p.val)
      of "vbr":
        vbr = true
      of "h", "help":
        echo "usage: audioconv <input> <output> [--bitrate=N] [--vbr]"
        quit(0)
      else:
        die("unknown option --" & p.key)
    of cmdArgument:
      if input == "":
        input = p.key
      elif output == "":
        output = p.key
      else:
        die("too many arguments")
  if input == "" or output == "":
    die("usage: audioconv <input> <output> [--bitrate=N] [--vbr]")
  var src: AudioSamples
  try:
    src = decodeAllSamples(input)
  except AudioError as e:
    die("decode failed: " & e.msg)
  let nch = src.specOf().channels.channelCount()
  let rate = src.specOf().rate
  var outBytes: seq[uint8]
  try:
    case extOf(output)
    of "wav":
      outBytes = encodeWav(src, rate)
    of "flac":
      outBytes = encodeFlacStream(src, rate)
    of "mp3":
      let mode =
        if nch == 1: MpaMode(kind: mmMono)
        else: MpaMode(kind: mmStereo)
      var o = defaultMp3EncoderOptions(bitrate, rate, mode)
      o.xing = true
      o.gapless = true
      o.vbr = vbr
      if vbr:
        o.vbrMinKbps = 32
        o.vbrMaxKbps = 192
      outBytes = encodeMp3Stream(toS16Copy(src), o)
    else:
      die("unsupported output format (want .wav/.mp3/.flac)")
  except AudioError as e:
    die("encode failed: " & e.msg)
  writeFile(output, cast[string](outBytes))
  echo src.framesOf(), " frames ", rate, " Hz ", nch, "ch -> ",
    output, " (", outBytes.len, " bytes)"

when isMainModule:
  main()
