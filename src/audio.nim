## audio: pure-Nim audio encoders/decoders.
##
## MPL-2.0. Decoder semantics ported from Symphonia
## (https://github.com/pdeljanov/Symphonia); encoders are new work.

import ./audio/errors
import ./audio/units
import ./audio/audio
import ./audio/io
import ./audio/checksum
import ./audio/packet
import ./audio/codecs
import ./audio/metadata
import ./audio/formats
import ./audio/codecs/pcm
import ./audio/codecs/adpcm
import ./audio/codecs/flac
import ./audio/codecs/vorbis
import ./audio/codecs/mpa
import ./audio/codecs/aac
import ./audio/codecs/alac
import ./audio/dsp
import ./audio/formats/wav
import ./audio/formats/flac as flacfmt
import ./audio/formats/ogg as oggfmt
import ./audio/formats/mpa as mpafmt
import ./audio/formats/mp4 as mp4fmt
import ./audio/formats/aiff as aifffmt
import ./audio/formats/caf as caffmt
import ./audio/formats/mkv as mkvfmt

export errors
export units
export audio
export io
export checksum
export packet
export codecs
export metadata
export formats
export pcm
export adpcm
export flac
export vorbis
export mpa
export aac
export alac
export dsp
export wav
export flacfmt
export oggfmt
export mpafmt
export mp4fmt
export aifffmt
export caffmt
export mkvfmt
