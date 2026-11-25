import std/options
import unittest

import audio

suite "audio smoke":
  test "registry roundtrip through public api":
    registerPcm()
    check isDecoderRegistered(CodecPcmS16Le)
    var params = forCodec(CodecPcmS16Le)
    params.sampleRate = some(44_100'u32)
    params.channels = some(ChStereo)
    let dec = makeAudioDecoder(params)
    check dec != nil

  test "wav probe rejects garbage":
    check probeWav(@[0x52'u8, 0x49, 0x46, 0x46]) == 0
    check probeWav(@[0x00'u8, 0x01, 0x02]) == 0
