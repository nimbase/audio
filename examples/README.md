# Examples

Runnable tools built on the `audio` package. Build from the package root:

```sh
clue build examples/audioconv.nim --out:/tmp/audioconv --release
```

## audioconv — audio converter CLI

Decodes WAV/MP3/FLAC and re-encodes to WAV/MP3/FLAC (format inferred
from the file extension):

```sh
/tmp/audioconv in.wav out.mp3 --bitrate=192
/tmp/audioconv in.mp3 out.flac
/tmp/audioconv in.flac out.wav --vbr
```

MP3 defaults to 128k CBR in the input's channel layout;
`--bitrate=N` sets CBR, `--vbr` selects the 32–192k VBR window.
WAV/FLAC are lossless. 24-bit input is down-converted to S16 for MP3.
