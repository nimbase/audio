## Vorbis decoder (no encoder — see note below).
##
## Ports `symphonia-codec-vorbis` (lib, codebook, floor, residue, dsp,
## window) plus the `BitReaderRtl`/VLC machinery it needs from
## `symphonia-core/src/io/bit.rs`. Least-significant-bit-first
## throughout. An encoder is deliberately out of scope (a quality Vorbis
## encoder is a psychoacoustics project of its own; Symphonia ships none
## either).

import std/algorithm
import std/math
import std/options
import std/sequtils
import ./../audio
import ./../codecs
import ./../dsp
import ./../errors
import ./../io
import ./../packet
import ./../units

# --------------------------------------------------------------- common ---

proc countLeadingZeroBits*(x: uint32): int =
  if x == 0:
    return 32
  var n = 0
  var v = x
  while (v and 0x8000_0000'u32) == 0:
    inc n
    v = v shl 1
  n

proc ilog*(x: uint32): uint32 {.inline.} =
  ## Position (1-based) of the highest set bit, 0 for 0.
  if x == 0: 0
  else: 32 - cast[uint32](countLeadingZeroBits(x))

proc decodeClasses(val: uint32; partsPerClassword, classifications: int;
    output: var openArray[uint8]) =
  var v = val
  # Only the leading (at most partsPerClassword) entries are assigned,
  # in reverse order; excess low-order values are discarded first.
  let n = min(partsPerClassword, output.len)
  for _ in 0 ..< (partsPerClassword - n):
    v = v div classifications.uint32
  for i in countdown(n - 1, 0):
    output[i] = cast[uint8](v mod classifications.uint32)
    v = v div classifications.uint32

# ------------------------------------------------------------- codebook ---

proc float32Unpack*(x: uint32): float32 =
  let mantissa = x and 0x1fffff'u32
  let sign = x and 0x80000000'u32
  let exponent = (x and 0x7fe00000'u32) shr 21
  let value = mantissa.float32 * pow(2.0'f32, exponent.float32 - 788.0)
  if sign == 0: value else: -value

proc lookup1Values*(entries: uint32; dimensions: int): uint32 =
  if dimensions == 0:
    return 0
  let v = pow(entries.float32, 1.0'f32 / dimensions.float32).floor.uint32
  doAssert v.uint64 ^ dimensions.uint64 <= entries.uint64
  v

proc unpackVqType1(multiplicands: openArray[uint16]; minValue, deltaValue: float32;
    sequenceP: bool; codebookEntries: int; dimensions: int;
    lookupValues: uint32): seq[float32] =
  result = newSeq[float32](codebookEntries * dimensions)
  var vi = 0
  for v in 0 ..< codebookEntries:
    var last = 0.0'f32
    var indexDivisor = 1'u32
    for _ in 0 ..< dimensions:
      let mo = ((v.uint32 div indexDivisor) mod lookupValues).int
      result[vi] = multiplicands[mo].float32 * deltaValue + minValue + last
      if sequenceP:
        last = result[vi]
      indexDivisor *= lookupValues
      inc vi

proc unpackVqType2(multiplicands: openArray[uint16]; minValue, deltaValue: float32;
    sequenceP: bool; codebookEntries: int; dimensions: int): seq[float32] =
  result = newSeq[float32](codebookEntries * dimensions)
  var vi = 0
  for lookupOffset in 0 ..< codebookEntries:
    var last = 0.0'f32
    let off = lookupOffset * dimensions
    for i in 0 ..< dimensions:
      result[vi] = multiplicands[off + i].float32 * deltaValue + minValue +
        last
      if sequenceP:
        last = result[vi]
      inc vi

proc synthesizeCodewords*(codeLens: openArray[uint8]): seq[uint32] =
  ## Canonical Huffman codeword assignment (section 2 of the Vorbis spec).
  var codewords: seq[uint32] = @[]
  var nextCodeword = newSeq[uint32](33)
  for len in codeLens:
    if len > 32:
      raise decodeError("vorbis: codebook codeword length exceeds 32 bits")
    if len == 0:
      continue
    let codewordLen = len.int
    let codeword = nextCodeword[codewordLen]
    if codewordLen < 32 and (codeword shr codewordLen) > 0:
      raise decodeError("vorbis: codebook overspecified")
    var i = codewordLen
    while true:
      if (nextCodeword[i] and 1) == 1:
        if i == 1:
          nextCodeword[1] += 1
        else:
          nextCodeword[i] = nextCodeword[i - 1] shl 1
        break
      nextCodeword[i] += 1
      if i == 1:
        break # Like the reference range, never descend below 1.
      dec i
    let branch = nextCodeword[codewordLen]
    var j = 1
    while codewordLen + j < nextCodeword.len:
      if nextCodeword[codewordLen + j] == codeword shl j:
        nextCodeword[codewordLen + j] = branch shl j
      else:
        break
      inc j
    codewords.add(codeword)
  # Underspecified (incomplete) trees are rejected.
  for i in 1 ..< 33:
    if (nextCodeword[i] and (high(uint32) shr (32 - i))) != 0:
      raise decodeError("vorbis: codebook underspecified")
  codewords

type
  VorbisCodebook* = object
    table*: VlcTable
    dimensions*: int
    vq*: seq[float32]
    hasVq*: bool

proc maxCodeLen(lens: openArray[uint8]): int =
  for l in lens:
    result = max(result, l.int)

proc readCodebook*(bs: var RtlBitReader): VorbisCodebook =
  let sync = bs.readRtlBits(24)
  if sync != 0x564342'u32:
    raise decodeError("vorbis: invalid codebook sync")
  let dimensions = bs.readRtlBits(16).int
  let entries = bs.readRtlBits(24).int
  if dimensions == 0:
    raise decodeError("vorbis: codebook dimension cannot be 0")
  if dimensions > 32:
    raise decodeError("vorbis: codebook dimension is too large (report this)")
  if entries > 128 * 1024:
    raise decodeError("vorbis: codebook entries too large (report this)")
  let isLengthOrdered = bs.readRtlBool()
  var codeLens: seq[uint8] = @[]
  var codeValues: seq[uint32] = @[]
  if not isLengthOrdered:
    let isSparse = bs.readRtlBool()
    if isSparse:
      for entry in 0 ..< entries:
        if bs.readRtlBool():
          codeLens.add(cast[uint8](bs.readRtlBits(5) + 1))
          codeValues.add(cast[uint32](entry))
    else:
      for _ in 0 ..< entries:
        codeLens.add(cast[uint8](bs.readRtlBits(5) + 1))
      for e in 0 ..< entries:
        codeValues.add(cast[uint32](e))
  else:
    var curEntry = 0
    var curLen = bs.readRtlBits(5) + 1
    while true:
      if curLen > 32:
        raise decodeError("vorbis: codebook codeword length exceeds 32 bits")
      let numBits =
        if entries > curEntry: ilog(cast[uint32](entries - curEntry))
        else: 0
      let num = bs.readRtlBits(numBits.int).int
      for _ in 0 ..< num:
        codeLens.add(cast[uint8](curLen))
      curLen += 1
      curEntry += num
      if curEntry > entries:
        raise decodeError("vorbis: invalid codebook")
      if curEntry == entries:
        break
    for e in 0 ..< curEntry:
      codeValues.add(cast[uint32](e))
  # Errata 20150226: duplicate lone single-entry codebooks.
  if codeLens.len == 1 and codeLens[0] == 1:
    codeLens.add(codeLens[0])
    codeValues.add(codeValues[0])
  let lookupType = bs.readRtlBits(4)
  var vq: seq[float32] = @[]
  var hasVq = false
  case lookupType and 0xf
  of 0: discard
  of 1, 2:
    let minValue = float32Unpack(bs.readRtlBits(32))
    let deltaValue = float32Unpack(bs.readRtlBits(32))
    let valueBits = bs.readRtlBits(4) + 1
    let sequenceP = bs.readRtlBool()
    let lookupValues =
      if lookupType == 1: lookup1Values(cast[uint32](entries), dimensions)
      else: cast[uint32](entries) * cast[uint32](dimensions)
    var mults = newSeq[uint16](lookupValues.int)
    for i in 0 ..< mults.len:
      mults[i] = cast[uint16](bs.readRtlBits(valueBits.int))
    vq =
      if lookupType == 1:
        unpackVqType1(mults, minValue, deltaValue, sequenceP, entries,
          dimensions, lookupValues)
      else:
        unpackVqType2(mults, minValue, deltaValue, sequenceP, entries,
          dimensions)
    hasVq = true
  else:
    raise decodeError("vorbis: invalid codeword lookup type")
  let codeWords = synthesizeCodewords(codeLens)
  var lens32 = newSeq[uint32](codeLens.len)
  for i, l in codeLens: lens32[i] = l.uint32
  let table = buildVlcTable(codeWords, lens32, codeValues,
    clamp(maxCodeLen(codeLens), 4, 8), true)
  VorbisCodebook(table: table, dimensions: dimensions, vq: vq, hasVq: hasVq)

proc readScalar*(cb: VorbisCodebook; bs: var RtlBitReader): uint32 =
  bs.readVlc(cb.table).value

proc readVq*(cb: VorbisCodebook; bs: var RtlBitReader): seq[float32] =
  if not cb.hasVq:
    raise decodeError("vorbis: not a vq codebook")
  let entry = bs.readVlc(cb.table).value.int
  let start = cb.dimensions * entry
  result = newSeq[float32](cb.dimensions)
  for i in 0 ..< cb.dimensions:
    result[i] = cb.vq[start + i]

# ---------------------------------------------------------------- floor ---

const Floor1InverseDbTable: array[256, float32] = [
  1.0649863e-07'f32, 1.1341951e-07'f32, 1.2079015e-07'f32, 1.2863978e-07'f32,
  1.3699951e-07'f32, 1.4590251e-07'f32, 1.5538408e-07'f32, 1.6548181e-07'f32,
  1.7623575e-07'f32, 1.8768855e-07'f32, 1.9988561e-07'f32, 2.1287530e-07'f32,
  2.2670913e-07'f32, 2.4144197e-07'f32, 2.5713223e-07'f32, 2.7384213e-07'f32,
  2.9163793e-07'f32, 3.1059021e-07'f32, 3.3077411e-07'f32, 3.5226968e-07'f32,
  3.7516214e-07'f32, 3.9954229e-07'f32, 4.2550680e-07'f32, 4.5315863e-07'f32,
  4.8260743e-07'f32, 5.1396998e-07'f32, 5.4737065e-07'f32, 5.8294187e-07'f32,
  6.2082472e-07'f32, 6.6116941e-07'f32, 7.0413592e-07'f32, 7.4989464e-07'f32,
  7.9862701e-07'f32, 8.5052630e-07'f32, 9.0579828e-07'f32, 9.6466216e-07'f32,
  1.0273513e-06'f32, 1.0941144e-06'f32, 1.1652161e-06'f32, 1.2409384e-06'f32,
  1.3215816e-06'f32, 1.4074654e-06'f32, 1.4989305e-06'f32, 1.5963394e-06'f32,
  1.7000785e-06'f32, 1.8105592e-06'f32, 1.9282195e-06'f32, 2.0535261e-06'f32,
  2.1869758e-06'f32, 2.3290978e-06'f32, 2.4804557e-06'f32, 2.6416497e-06'f32,
  2.8133190e-06'f32, 2.9961443e-06'f32, 3.1908506e-06'f32, 3.3982101e-06'f32,
  3.6190449e-06'f32, 3.8542308e-06'f32, 4.1047004e-06'f32, 4.3714470e-06'f32,
  4.6555282e-06'f32, 4.9580707e-06'f32, 5.2802740e-06'f32, 5.6234160e-06'f32,
  5.9888572e-06'f32, 6.3780469e-06'f32, 6.7925283e-06'f32, 7.2339451e-06'f32,
  7.7040476e-06'f32, 8.2047000e-06'f32, 8.7378876e-06'f32, 9.3057248e-06'f32,
  9.9104632e-06'f32, 1.0554501e-05'f32, 1.1240392e-05'f32, 1.1970856e-05'f32,
  1.2748789e-05'f32, 1.3577278e-05'f32, 1.4459606e-05'f32, 1.5399272e-05'f32,
  1.6400004e-05'f32, 1.7465768e-05'f32, 1.8600792e-05'f32, 1.9809576e-05'f32,
  2.1096914e-05'f32, 2.2467911e-05'f32, 2.3928002e-05'f32, 2.5482978e-05'f32,
  2.7139006e-05'f32, 2.8902651e-05'f32, 3.0780908e-05'f32, 3.2781225e-05'f32,
  3.4911534e-05'f32, 3.7180282e-05'f32, 3.9596466e-05'f32, 4.2169667e-05'f32,
  4.4910090e-05'f32, 4.7828601e-05'f32, 5.0936773e-05'f32, 5.4246931e-05'f32,
  5.7772202e-05'f32, 6.1526565e-05'f32, 6.5524908e-05'f32, 6.9783085e-05'f32,
  7.4317983e-05'f32, 7.9147585e-05'f32, 8.4291040e-05'f32, 8.9768747e-05'f32,
  9.5602426e-05'f32, 0.00010181521'f32, 0.00010843174'f32, 0.00011547824'f32,
  0.00012298267'f32, 0.00013097477'f32, 0.00013948625'f32, 0.00014855085'f32,
  0.00015820453'f32, 0.00016848555'f32, 0.00017943469'f32, 0.00019109536'f32,
  0.00020351382'f32, 0.00021673929'f32, 0.00023082423'f32, 0.00024582449'f32,
  0.00026179955'f32, 0.00027881276'f32, 0.00029693158'f32, 0.00031622787'f32,
  0.00033677814'f32, 0.00035866388'f32, 0.00038197188'f32, 0.00040679456'f32,
  0.00043323036'f32, 0.00046138411'f32, 0.00049136745'f32, 0.00052329927'f32,
  0.00055730621'f32, 0.00059352311'f32, 0.00063209358'f32, 0.00067317058'f32,
  0.00071691700'f32, 0.00076350630'f32, 0.00081312324'f32, 0.00086596457'f32,
  0.00092223983'f32, 0.00098217216'f32, 0.0010459992'f32, 0.0011139742'f32,
  0.0011863665'f32, 0.0012634633'f32, 0.0013455702'f32, 0.0014330129'f32,
  0.0015261382'f32, 0.0016253153'f32, 0.0017309374'f32, 0.0018434235'f32,
  0.0019632195'f32, 0.0020908006'f32, 0.0022266726'f32, 0.0023713743'f32,
  0.0025254795'f32, 0.0026895994'f32, 0.0028643847'f32, 0.0030505286'f32,
  0.0032487691'f32, 0.0034598925'f32, 0.0036847358'f32, 0.0039241906'f32,
  0.0041792066'f32, 0.0044507950'f32, 0.0047400328'f32, 0.0050480668'f32,
  0.0053761186'f32, 0.0057254891'f32, 0.0060975636'f32, 0.0064938176'f32,
  0.0069158225'f32, 0.0073652516'f32, 0.0078438871'f32, 0.0083536271'f32,
  0.0088964928'f32, 0.009474637'f32, 0.010090352'f32, 0.010746080'f32,
  0.011444421'f32, 0.012188144'f32, 0.012980198'f32, 0.013823725'f32,
  0.014722068'f32, 0.015678791'f32, 0.016697687'f32, 0.017782797'f32,
  0.018938423'f32, 0.020169149'f32, 0.021479854'f32, 0.022875735'f32,
  0.024362330'f32, 0.025945531'f32, 0.027631618'f32, 0.029427276'f32,
  0.031339626'f32, 0.033376252'f32, 0.035545228'f32, 0.037855157'f32,
  0.040315199'f32, 0.042935108'f32, 0.045725273'f32, 0.048696758'f32,
  0.051861348'f32, 0.055231591'f32, 0.058820850'f32, 0.062643361'f32,
  0.066714279'f32, 0.071049749'f32, 0.075666962'f32, 0.080584227'f32,
  0.085821044'f32, 0.091398179'f32, 0.097337747'f32, 0.10366330'f32,
  0.11039993'f32, 0.11757434'f32, 0.12521498'f32, 0.13335215'f32,
  0.14201813'f32, 0.15124727'f32, 0.16107617'f32, 0.17154380'f32,
  0.18269168'f32, 0.19456402'f32, 0.20720788'f32, 0.22067342'f32,
  0.23501402'f32, 0.25028656'f32, 0.26655159'f32, 0.28387361'f32,
  0.30232132'f32, 0.32196786'f32, 0.34289114'f32, 0.36517414'f32,
  0.38890521'f32, 0.41417847'f32, 0.44109412'f32, 0.46975890'f32,
  0.50028648'f32, 0.53279791'f32, 0.56742212'f32, 0.60429640'f32,
  0.64356699'f32, 0.68538959'f32, 0.72993007'f32, 0.77736504'f32,
  0.82788260'f32, 0.88168307'f32, 0.9389798'f32, 1.0'f32,
]
# -------------------------------------------------------- floor setup ---

type
  Floor0Setup* = object
    order*: int
    barkMapSize*: int
    amplitudeBits*: int
    amplitudeOffset*: int
    numBooks*: int
    bookList*: array[16, int]
    mapShortBsExp*: int
    mapShort*: seq[int32]
    mapLong*: seq[int32]

  Floor1Class* = object
    mainbook*: int
    dimensions*: int
    subclassBits*: int
    subbooks*: array[8, int]
    subbooksUsed*: uint8

  Floor1Setup* = object
    partitions*: int
    partitionClass*: array[32, int]
    classes*: array[16, Floor1Class]
    multiplier*: int
    xList*: seq[uint32]
    sortOrder*: seq[int]
    neighbors*: seq[tuple[lo, hi: int]]

  FloorKind* = enum
    fk0
    fk1

  FloorObj* = ref object
    case kind*: FloorKind
    of fk0:
      f0setup*: Floor0Setup
      f0unused*: bool
      f0amp*: uint64
      f0coeffs*: array[256, float32]
    of fk1:
      f1setup*: Floor1Setup
      f1unused*: bool
      f1y*: seq[uint32]
      f1finalY*: seq[int32]
      f1step2*: seq[bool]

proc bark(x: float64): float64 =
  13.1 * arctan(0.00074 * x) + 2.24 * arctan(0.0000000185 * x * x) +
    0.0001 * x

proc barkMap(n: int; rate: int; barkMapSize: int): seq[int32] =
  result = newSeq[int32](n)
  let foobarMin = barkMapSize - 1
  let rateBy2n = rate.float64 / (2.0 * n.float64)
  let c = barkMapSize.float64 / bark(0.5 * rate.float64)
  for i in 0 ..< n:
    let f = (bark(rateBy2n * i.float64) * c).floor.int
    result[i] = min(f, foobarMin).int32

# ------------------------------------------------------ floor channel ---

proc readFloor0Setup(bs: var RtlBitReader; bs0exp, bs1exp: int;
    maxCodebook: int): Floor0Setup =
  result.order = bs.readRtlBits(8).int
  let rate = bs.readRtlBits(16).int
  result.barkMapSize = bs.readRtlBits(16).int
  result.amplitudeBits = bs.readRtlBits(6).int
  result.amplitudeOffset = bs.readRtlBits(8).int
  result.numBooks = bs.readRtlBits(4).int + 1
  for i in 0 ..< result.numBooks:
    let b = bs.readRtlBits(8).int
    if b >= maxCodebook:
      raise decodeError("vorbis: floor0, invalid codebook number")
    result.bookList[i] = b
  result.mapShortBsExp = bs0exp
  result.mapShort = barkMap(1 shl (bs0exp - 1), rate, result.barkMapSize)
  result.mapLong = barkMap(1 shl (bs1exp - 1), rate, result.barkMapSize)

proc getRange(multiplier: int): uint32 =
  case multiplier - 1
  of 0: 256
  of 1: 128
  of 2: 86
  of 3: 64
  else: raise decodeError("vorbis: invalid floor multiplier")

proc findNeighbors(v: openArray[uint32]; x: int): tuple[lo, hi: int] =
  let bound = v[x]
  var lo = low(uint32)
  var hi = high(uint32)
  var res = (0, 0)
  for i in 0 ..< x:
    if v[i] > lo and v[i] < bound:
      lo = v[i]
      res[0] = i
    if v[i] < hi and v[i] > bound:
      hi = v[i]
      res[1] = i
  res

proc readFloor1Setup(bs: var RtlBitReader;
    maxCodebook: int): Floor1Setup =
  result.partitions = bs.readRtlBits(5).int
  var maxClass = 0
  if result.partitions > 0:
    for i in 0 ..< result.partitions:
      let c = bs.readRtlBits(4).int
      result.partitionClass[i] = c
      maxClass = max(maxClass, c)
    for i in 0 ..< maxClass + 1:
      result.classes[i].dimensions = bs.readRtlBits(3).int + 1
      result.classes[i].subclassBits = bs.readRtlBits(2).int
      if result.classes[i].subclassBits != 0:
        let mb = bs.readRtlBits(8).int
        if mb >= maxCodebook:
          raise decodeError("vorbis: floor1, invalid codebook for class")
        result.classes[i].mainbook = mb
      let nsub = 1 shl result.classes[i].subclassBits
      for j in 0 ..< nsub:
        var b = bs.readRtlBits(8).int
        if b > 0:
          dec b
          if b >= maxCodebook:
            raise decodeError("vorbis: floor1, invalid codebook for subclass")
          result.classes[i].subbooksUsed =
            result.classes[i].subbooksUsed or (1'u8 shl j)
        result.classes[i].subbooks[j] = b
  result.multiplier = bs.readRtlBits(2).int + 1
  let rangeBits = bs.readRtlBits(4).int
  result.xList.add(0'u32)
  result.xList.add(1'u32 shl rangeBits)
  var seen: seq[uint32] = @[0'u32, 1'u32 shl rangeBits]
  for i in 0 ..< result.partitions:
    let classIdx = result.partitionClass[i]
    for _ in 0 ..< result.classes[classIdx].dimensions:
      let xv = bs.readRtlBits(rangeBits).uint32
      if xv in seen:
        raise decodeError("vorbis: floor1, x_list is not unique")
      seen.add(xv)
      result.xList.add(xv)
      if result.xList.len > 65:
        raise decodeError("vorbis: floor1, x_list too long")
  for i in 0 ..< result.xList.len:
    result.neighbors.add(findNeighbors(result.xList, i))
    result.sortOrder.add(i)
  let xl = result.xList
  result.sortOrder.sort(proc(a, b: int): int = cmp(xl[a], xl[b]))

proc readFloor*(bs: var RtlBitReader; bs0exp, bs1exp: int;
    maxCodebook: int): FloorObj =
  let floorType = bs.readRtlBits(16)
  if floorType == 0:
    let setup = readFloor0Setup(bs, bs0exp, bs1exp, maxCodebook)
    FloorObj(kind: fk0, f0setup: setup, f0unused: false, f0amp: 0,
      f0coeffs: default(array[256, float32]))
  elif floorType == 1:
    let setup = readFloor1Setup(bs, maxCodebook)
    let n = setup.xList.len
    FloorObj(kind: fk1, f1setup: setup, f1unused: false,
      f1y: newSeq[uint32](n), f1finalY: newSeq[int32](n),
      f1step2: newSeq[bool](n))
  else:
    raise decodeError("vorbis: invalid floor type")

# ----------------------------------------------------- floor channel ---

proc floor0ReadChannel(f: FloorObj; bs: var RtlBitReader;
    codebooks: openArray[VorbisCodebook]) =
  f.f0unused = true
  try:
    f.f0amp = bs.readRtlBits64(f.f0setup.amplitudeBits)
  except EndOfStream:
    return
  if f.f0amp != 0:
    let bookBits = ilog(f.f0setup.numBooks.uint32)
    var floorBookIdx = 0
    try:
      floorBookIdx = bs.readRtlBits(bookBits.int).int
    except EndOfStream:
      return
    if floorBookIdx >= f.f0setup.bookList.len:
      raise decodeError("vorbis: floor0, invalid codebook")
    let cbIdx = f.f0setup.bookList[floorBookIdx]
    if cbIdx >= codebooks.len:
      raise decodeError("vorbis: floor0, invalid codebook")
    let order = f.f0setup.order
    var i = 0
    var last = 0.0'f32
    while i < order:
      let vq =
        try: codebooks[cbIdx].readVq(bs)
        except EndOfStream: return
      let take = min(order - i, vq.len)
      for j in 0 ..< take:
        f.f0coeffs[i] = last + vq[j]
        inc i
      last = f.f0coeffs[i - 1]
    for i in 0 ..< order:
      f.f0coeffs[i] = 2.0'f32 * cos(f.f0coeffs[i])
  f.f0unused = f.f0amp == 0

proc linearFloor0Value(p, q: float32; amplitude: uint64; ampBits,
    ampOffset: int): float32 =
  let a = (amplitude * ampOffset.uint64).float32
  let b = sqrt(p + q) * ((1'u64 shl ampBits) - 1).float32
  0.11512925'f32 * exp((a / b) - ampOffset.float32)

proc floor0Synthesis(f: FloorObj; bsExp: int; floor: var openArray[float32]) =
  let n = (1 shl bsExp) shr 1
  let map = if bsExp == f.f0setup.mapShortBsExp: f.f0setup.mapShort
    else: f.f0setup.mapLong
  let omegaStep = PI / f.f0setup.barkMapSize.float64
  var i = 0
  while i < n:
    let iterCond = map[i].int
    let omega = (omegaStep * iterCond.float64).float32
    let cosOmega = cos(omega)
    let twoCos = 2.0'f32 * cosOmega
    var p = 1.0'f32
    var q = 1.0'f32
    var ci = 0
    while ci + 1 < f.f0setup.order:
      p *= f.f0coeffs[ci + 1] - twoCos
      q *= f.f0coeffs[ci] - twoCos
      ci += 2
    if ci < f.f0setup.order:
      let last = f.f0coeffs[ci]
      q *= last - twoCos
      p = p * p * (1.0'f32 - cosOmega * cosOmega)
      q = q * q * 0.25'f32
    else:
      p = p * p * ((1.0'f32 - cosOmega) / 2.0'f32)
      q = q * q * ((1.0'f32 + cosOmega) / 2.0'f32)
    if p + q == 0.0:
      raise decodeError("vorbis: invalid floor0 coefficients")
    let v = linearFloor0Value(p, q, f.f0amp, f.f0setup.amplitudeBits,
      f.f0setup.amplitudeOffset)
    while i < n and map[i].int == iterCond:
      floor[i] = v
      inc i

proc renderPoint(x0: uint32; y0: int32; x1: uint32; y1: int32;
    x: uint32): int32 =
  let dy = y1 -% y0
  let adx = x1 - x0
  let err = cast[uint32](if dy < 0: -dy else: dy) * (x - x0)
  let off = (err div adx).int32
  if dy < 0: y0 -% off else: y0 +% off

proc renderLine(x0: uint32; y0: int32; x1: uint32; y1: int32; n: int;
    v: var openArray[float32]) =
  if x0.int >= n:
    return
  let dy = y1 -% y0
  let adx = cast[int32](x1 - x0)
  let base = dy div adx
  var y = y0
  let sy = if dy < 0: base -% 1 else: base +% 1
  let ady =
    (if dy == low(int32): high(int32) else: abs(dy)) -%
    (if base == low(int32): high(int32) else: abs(base)) *% adx
  v[x0.int] = Floor1InverseDbTable[y]
  var err = 0'i32
  for i in x0.int + 1 ..< min(n, x1.int):
    err = err +% ady
    if err >= adx:
      err = err -% adx
      y = y +% sy
    else:
      y = y +% base
    v[i] = Floor1InverseDbTable[y]

proc floor1Step1(f: FloorObj) =
  let setup = f.f1setup
  let rng = getRange(setup.multiplier)
  f.f1step2[0] = true
  f.f1step2[1] = true
  f.f1finalY[0] = f.f1y[0].int32
  f.f1finalY[1] = f.f1y[1].int32
  for i in 2 ..< setup.xList.len:
    let (loN, hiN) = setup.neighbors[i]
    let predicted = renderPoint(setup.xList[loN], f.f1finalY[loN],
      setup.xList[hiN], f.f1finalY[hiN], setup.xList[i])
    let val = f.f1y[i].int32
    let highroom = rng.int32 - predicted
    let lowroom = predicted
    if val != 0:
      let room = 2 * min(highroom, lowroom)
      f.f1step2[loN] = true
      f.f1step2[hiN] = true
      f.f1step2[i] = true
      f.f1finalY[i] =
        if val >= room:
          if highroom > lowroom: val - lowroom + predicted
          else: predicted - val + highroom - 1
        elif (val and 1) == 1:
          predicted - ((val + 1) div 2)
        else:
          predicted + (val div 2)
    else:
      f.f1step2[i] = false
      f.f1finalY[i] = predicted

proc floor1Step2(f: FloorObj; n: int; floor: var openArray[float32]) =
  let setup = f.f1setup
  let multiplier = setup.multiplier
  let y0 = max(0'i32, min(255'i32, f.f1finalY[setup.sortOrder[0]] * multiplier.int32))
  var hx = 0'u32
  var hy = y0
  var lx = 0'u32
  var ly = y0
  for i in setup.sortOrder[1 .. ^1]:
    if f.f1step2[i]:
      hy = max(0'i32, min(255'i32, f.f1finalY[i] * multiplier.int32))
      hx = setup.xList[i]
      renderLine(lx, ly, hx, hy, n, floor)
      lx = hx
      ly = hy
  if hx.int < n:
    renderLine(hx, hy, n.uint32, hy, n, floor)

proc floor1ReadChannel(f: FloorObj; bs: var RtlBitReader;
    codebooks: openArray[VorbisCodebook]) =
  f.f1unused = true
  var isUsed = false
  try:
    isUsed = bs.readRtlBool()
  except EndOfStream:
    return
  if not isUsed:
    return
  let rng = getRange(f.f1setup.multiplier)
  let rangeBits = ilog(rng - 1).int
  try:
    f.f1y[0] = bs.readRtlBits(rangeBits)
    f.f1y[1] = bs.readRtlBits(rangeBits)
  except EndOfStream:
    return
  var offset = 2
  for ci in 0 ..< f.f1setup.partitions:
    let classIdx = f.f1setup.partitionClass[ci]
    let class = f.f1setup.classes[classIdx]
    let cdim = class.dimensions
    let cbits = class.subclassBits
    let csub = (1 shl cbits) - 1
    var cval = 0'u32
    if cbits > 0:
      try:
        cval = codebooks[class.mainbook].readScalar(bs)
      except EndOfStream:
        return
    for j in 0 ..< cdim:
      let subclassIdx = (cval and csub.uint32).int
      cval = cval shr cbits
      if (class.subbooksUsed and (1'u8 shl subclassIdx)) != 0:
        let subIdx = class.subbooks[subclassIdx].int
        try:
          f.f1y[offset] = codebooks[subIdx].readScalar(bs)
        except EndOfStream:
          return
      else:
        f.f1y[offset] = 0
      inc offset
  f.f1unused = false

proc floorReadChannel*(f: FloorObj; bs: var RtlBitReader;
    codebooks: openArray[VorbisCodebook]) =
  case f.kind
  of fk0: floor0ReadChannel(f, bs, codebooks)
  of fk1: floor1ReadChannel(f, bs, codebooks)

proc floorIsUnused*(f: FloorObj): bool =
  case f.kind
  of fk0: f.f0unused
  of fk1: f.f1unused

proc floorSynthesis*(f: FloorObj; bsExp: int;
    floor: var openArray[float32]) =
  case f.kind
  of fk0: floor0Synthesis(f, bsExp, floor)
  of fk1:
    floor1Step1(f)
    floor1Step2(f, (1 shl bsExp) shr 1, floor)

# ------------------------------------------------------------- residue ---

type
  ResidueClass* = object
    books*: array[8, int]
    used*: uint8

  ResidueSetup* = object
    rtype*: int
    resBegin*: int
    resEnd*: int
    partSize*: int
    classifications*: int
    classbook*: int
    vqClasses*: seq[ResidueClass]
    maxPass*: int

  Residue* = object
    setup*: ResidueSetup
    partClasses*: seq[uint8]
    type2buf*: seq[float32]

proc isUsed*(c: ResidueClass; pass: int): bool {.inline.} =
  (c.used and (1'u8 shl pass)) != 0

proc readResidueSetup*(bs: var RtlBitReader; rtype: int;
    maxCodebook: int): ResidueSetup =
  result.rtype = rtype
  result.resBegin = bs.readRtlBits(24).int
  result.resEnd = bs.readRtlBits(24).int
  result.partSize = bs.readRtlBits(24).int + 1
  result.classifications = bs.readRtlBits(6).int + 1
  result.classbook = bs.readRtlBits(8).int
  if result.classbook >= maxCodebook:
    raise decodeError("vorbis: invalid codebook for residue classbook")
  if result.resEnd < result.resBegin:
    raise decodeError("vorbis: invalid residue begin and end")
  for _ in 0 ..< result.classifications:
    let lo = bs.readRtlBits(3).int
    let hi =
      if bs.readRtlBool(): bs.readRtlBits(5).int
      else: 0
    var cls = ResidueClass(books: [0, 0, 0, 0, 0, 0, 0, 0],
      used: cast[uint8]((hi shl 3) or lo))
    result.vqClasses.add(cls)
  for vc in result.vqClasses.mitems:
    for j in 0 ..< 8:
      if vc.isUsed(j):
        let b = bs.readRtlBits(8).int
        if b == 0 or b >= maxCodebook:
          raise decodeError("vorbis: invalid codebook for residue")
        vc.books[j] = b
        result.maxPass = max(result.maxPass, j)

proc readResidue*(bs: var RtlBitReader; rtype: int;
    maxCodebook: int): Residue =
  Residue(setup: readResidueSetup(bs, rtype, maxCodebook))

proc readResiduePartition0(bs: var RtlBitReader; cb: VorbisCodebook;
    buf: var openArray[float32]) =
  let step = buf.len div cb.dimensions
  for i in 0 ..< step:
    let vq = cb.readVq(bs)
    var k = i
    for v in vq:
      buf[k] = buf[k] + v
      k += step

proc readResiduePartition1(bs: var RtlBitReader; cb: VorbisCodebook;
    buf: var openArray[float32]) =
  let dim = cb.dimensions
  if dim == 2:
    var i = 0
    while i + 2 <= buf.len:
      let vq = cb.readVq(bs)
      buf[i] = buf[i] + vq[0]
      buf[i + 1] = buf[i + 1] + vq[1]
      i += 2
  elif dim == 4:
    var i = 0
    while i + 4 <= buf.len:
      let vq = cb.readVq(bs)
      for j in 0 ..< 4:
        buf[i + j] = buf[i + j] + vq[j]
      i += 4
  else:
    var i = 0
    while i + dim <= buf.len:
      let vq = cb.readVq(bs)
      for j in 0 ..< dim:
        buf[i + j] = buf[i + j] + vq[j]
      i += dim

# ----------------------------------------------------------------- dsp ---

proc generateWinCurve*(bs: int): seq[float32] =
  let n = bs div 2
  let denom = n.float64
  result = newSeq[float32](n)
  for i in 0 ..< n:
    let num = i.float64 + 0.5
    let frac = (PI / 2.0) * (num / denom)
    result[i] = sin((PI / 2.0) * pow(sin(frac), 2.0)).float32

type
  Windows* = object
    short*: seq[float32]
    long*: seq[float32]

  DspChannel* = object
    floor*: seq[float32]
    residue*: seq[float32]
    doNotDecode*: bool
    imdct*: seq[float32]
    overlap*: seq[float32]
    bs0*: int
    bs1*: int

  Dsp* = object
    channels*: seq[DspChannel]
    imdctShort*: Imdct
    imdctLong*: Imdct
    windows*: Windows
    prevBlockFlag*: Option[bool]

proc newDspChannel*(bs0exp, bs1exp: int): DspChannel =
  let bs0 = 1 shl bs0exp
  let bs1 = 1 shl bs1exp
  DspChannel(floor: newSeq[float32](bs1 shr 1),
    residue: newSeq[float32](bs1 shr 1), doNotDecode: false,
    imdct: newSeq[float32](bs1), overlap: newSeq[float32](bs1 shr 1),
    bs0: bs0, bs1: bs1)

proc overlapAdd(outp: var openArray[float32]; left, right,
    win: openArray[float32]) =
  assert outp.len == left.len and left.len == right.len and
    right.len == win.len
  let n = outp.len
  for i in 0 ..< n:
    outp[i] = left[i] * win[n - 1 - i] + right[i] * win[i]

proc synthChannel*(ch: var DspChannel; blockFlag, prevBlockFlag: bool;
    windows: Windows; imdct: var Imdct; buf: var openArray[float32]) =
  let bs = if blockFlag: ch.bs1 else: ch.bs0
  imdct.imdct(ch.floor.toOpenArray(0, bs div 2 - 1),
    ch.imdct.toOpenArray(0, bs - 1))
  let win =
    if blockFlag and prevBlockFlag: windows.long else: windows.short
  if prevBlockFlag == blockFlag:
    overlapAdd(buf, ch.overlap.toOpenArray(0, bs div 2 - 1),
      ch.imdct.toOpenArray(0, bs div 2 - 1), win)
  elif prevBlockFlag and not blockFlag:
    let start = (ch.bs1 - ch.bs0) div 4
    let fin = start + ch.bs0 div 2
    for i in 0 ..< start:
      buf[i] = ch.overlap[i]
    overlapAdd(buf.toOpenArray(start, buf.len - 1),
      ch.overlap.toOpenArray(start, fin - 1),
      ch.imdct.toOpenArray(0, ch.bs0 div 2 - 1), win)
  else:
    let start = (ch.bs1 - ch.bs0) div 4
    let fin = start + ch.bs0 div 2
    overlapAdd(buf.toOpenArray(0, ch.bs0 div 2 - 1),
      ch.overlap.toOpenArray(0, ch.bs0 div 2 - 1),
      ch.imdct.toOpenArray(start, fin - 1), win)
    for i in ch.bs0 div 2 ..< buf.len:
      buf[i] = ch.imdct[fin + (i - ch.bs0 div 2)]
  for i in 0 ..< bs div 2:
    ch.overlap[i] = ch.imdct[bs div 2 + i]

proc resetDsp*(d: var Dsp) =
  for ch in d.channels.mitems:
    for i in 0 ..< ch.overlap.len:
      ch.overlap[i] = 0.0
  d.prevBlockFlag = none(bool)

# ------------------------------------------------------ residue read ---

proc deinterleave2(res: var Residue; chIdx: openArray[int];
    channels: var openArray[DspChannel]) =
  if chIdx.len == 2:
    let c0 = chIdx[0]
    let c1 = chIdx[1]
    var i = 0
    var k = 0
    while k + 2 <= res.type2buf.len:
      channels[c0].residue[i] = res.type2buf[k]
      channels[c1].residue[i] = res.type2buf[k + 1]
      inc i
      k += 2
  else:
    let stride = chIdx.len
    for e, ch in chIdx:
      var o = 0
      var k = e
      while k < res.type2buf.len:
        channels[ch].residue[o] = res.type2buf[k]
        inc o
        k += stride

proc readResidueInnerType2(res: var Residue; bs: var RtlBitReader; bsExp: int;
    codebooks: openArray[VorbisCodebook]; chIdx: openArray[int];
    channels: var openArray[DspChannel]) =
  let classbook = codebooks[res.setup.classbook]
  let fullLen = ((1 shl bsExp) shr 1) * chIdx.len
  let lo = min(res.setup.resBegin, fullLen)
  let hi = min(res.setup.resEnd, fullLen)
  let resLen = hi - lo
  let partsPerClassword = classbook.dimensions
  let partsToRead =
    if res.setup.partSize == 0: 0
    else: resLen div res.setup.partSize
  if res.partClasses.len < partsToRead:
    res.partClasses.setLen(partsToRead)
  if res.type2buf.len < fullLen:
    res.type2buf.setLen(fullLen)
  for i in 0 ..< fullLen:
    res.type2buf[i] = 0.0
  var anyDecode = false
  for ch in chIdx:
    anyDecode = anyDecode or not channels[ch].doNotDecode
  if not anyDecode:
    return
  let partSize = res.setup.partSize
  for pass in 0 .. res.setup.maxPass:
    var partFirst = 0
    while partFirst < partsToRead:
      if pass == 0:
        let code =
          try: classbook.readScalar(bs)
          except EndOfStream: return
        decodeClasses(code, partsPerClassword,
          res.setup.classifications,
          res.partClasses.toOpenArray(partFirst, partsToRead - 1))
      let partLast = min(partsToRead, partFirst + partsPerClassword)
      for part in partFirst ..< partLast:
        let vc = res.setup.vqClasses[res.partClasses[part].int]
        if vc.isUsed(pass):
          let vqbook = codebooks[vc.books[pass]]
          let start = lo + partSize * part
          try:
            readResiduePartition1(bs, vqbook,
              res.type2buf.toOpenArray(start, start + partSize - 1))
          except EndOfStream:
            return
      partFirst += partsPerClassword

proc readResidueInnerType01(res: var Residue; bs: var RtlBitReader; bsExp: int;
    codebooks: openArray[VorbisCodebook]; chIdx: openArray[int];
    channels: var openArray[DspChannel]) =
  let classbook = codebooks[res.setup.classbook]
  let fullLen = (1 shl bsExp) shr 1
  let lo = min(res.setup.resBegin, fullLen)
  let hi = min(res.setup.resEnd, fullLen)
  let resLen = hi - lo
  let partsPerClassword = classbook.dimensions
  let partsToRead =
    if res.setup.partSize == 0: 0
    else: resLen div res.setup.partSize
  let need = partsToRead * chIdx.len
  if res.partClasses.len < need:
    res.partClasses.setLen(need)
  var anyDecode = false
  for ch in chIdx:
    anyDecode = anyDecode or not channels[ch].doNotDecode
    for i in 0 ..< fullLen:
      channels[ch].residue[i] = 0.0
  if not anyDecode:
    return
  let partSize = res.setup.partSize
  for pass in 0 .. res.setup.maxPass:
    var partFirst = 0
    while partFirst < partsToRead:
      if pass == 0:
        for e, ch in chIdx:
          if channels[ch].doNotDecode:
            continue
          let code =
            try: classbook.readScalar(bs)
            except EndOfStream: return
          decodeClasses(code, partsPerClassword,
            res.setup.classifications, res.partClasses.toOpenArray(
              partFirst + e * partsToRead, (e + 1) * partsToRead - 1))
      let partLast = min(partsToRead, partFirst + partsPerClassword)
      for part in partFirst ..< partLast:
        for e, ch in chIdx:
          if channels[ch].doNotDecode:
            continue
          let classIdx = res.partClasses[part + partsToRead * e].int
          let vc = res.setup.vqClasses[classIdx]
          if vc.isUsed(pass):
            let vqbook = codebooks[vc.books[pass]]
            let start = lo + partSize * part
            try:
              if res.setup.rtype == 0:
                readResiduePartition0(bs, vqbook,
                  channels[ch].residue.toOpenArray(start,
                    start + partSize - 1))
              else:
                readResiduePartition1(bs, vqbook,
                  channels[ch].residue.toOpenArray(start,
                    start + partSize - 1))
            except EndOfStream:
              return
      partFirst += partsPerClassword

proc readResidueData*(res: var Residue; bs: var RtlBitReader; bsExp: int;
    codebooks: openArray[VorbisCodebook]; chIdx: openArray[int];
    channels: var openArray[DspChannel]) =
  if res.setup.rtype == 2:
    try:
      res.readResidueInnerType2(bs, bsExp, codebooks, chIdx, channels)
    except EndOfStream:
      discard
    res.deinterleave2(chIdx, channels)
  else:
    try:
      res.readResidueInnerType01(bs, bsExp, codebooks, chIdx, channels)
    except EndOfStream:
      discard

# ------------------------------------------------- mapping and mode ---

type
  ChannelCouple* = object
    magnitude*: int
    angle*: int

  SubMap* = object
    floor*: int
    residue*: int

  Mapping* = object
    couplings*: seq[ChannelCouple]
    multiplex*: seq[int]
    submaps*: seq[SubMap]

  Mode* = object
    blockFlag*: bool
    mapping*: int

proc readMappingType0(bs: var RtlBitReader; audioChannels: int; maxFloor,
    maxResidue: int): Mapping =
  let numSubmaps =
    if bs.readRtlBool(): bs.readRtlBits(4).int + 1
    else: 1
  if bs.readRtlBool():
    let steps = bs.readRtlBits(8).int + 1
    let maxCh = audioChannels - 1
    let cbits = ilog(maxCh.uint32).int
    for _ in 0 ..< steps:
      let mag = bs.readRtlBits(cbits).int
      let ang = bs.readRtlBits(cbits).int
      if mag == ang or mag > maxCh or ang > maxCh:
        raise decodeError("vorbis: invalid channel coupling")
      result.couplings.add(ChannelCouple(magnitude: mag, angle: ang))
  if bs.readRtlBits(2) != 0:
    raise decodeError("vorbis: reserved mapping bits non-zero")
  if numSubmaps > 1:
    for _ in 0 ..< audioChannels:
      let mux = bs.readRtlBits(4).int
      if mux >= numSubmaps:
        raise decodeError("vorbis: invalid channel multiplex")
      result.multiplex.add(mux)
  else:
    for _ in 0 ..< audioChannels:
      result.multiplex.add(0)
  for _ in 0 ..< numSubmaps:
    discard bs.readRtlBits(8)
    let floor = bs.readRtlBits(8).int
    if floor >= maxFloor:
      raise decodeError("vorbis: invalid floor for mapping")
    let residue = bs.readRtlBits(8).int
    if residue >= maxResidue:
      raise decodeError("vorbis: invalid residue for mapping")
    result.submaps.add(SubMap(floor: floor, residue: residue))

proc readMapping(bs: var RtlBitReader; audioChannels, maxFloor,
    maxResidue: int): Mapping =
  let t = bs.readRtlBits(16)
  if t == 0:
    readMappingType0(bs, audioChannels, maxFloor, maxResidue)
  else:
    raise decodeError("vorbis: invalid mapping type")

proc readMode(bs: var RtlBitReader; maxMapping: int): Mode =
  let blockFlag = bs.readRtlBool()
  let windowType = bs.readRtlBits(16)
  let transformType = bs.readRtlBits(16)
  let mapping = bs.readRtlBits(8).int
  if windowType != 0:
    raise decodeError("vorbis: invalid window type for mode")
  if transformType != 0:
    raise decodeError("vorbis: invalid transform type for mode")
  if mapping >= maxMapping:
    raise decodeError("vorbis: invalid mode mapping")
  Mode(blockFlag: blockFlag, mapping: mapping)

proc mapVorbisChannel*(numChannels, ch: int): int =
  ## Vorbis channel index to buffer plane (spec 4.3.9).
  case numChannels
  of 1: [0][ch]
  of 2: [0, 1][ch]
  of 3: [0, 2, 1][ch]
  of 4: [0, 1, 2, 3][ch]
  of 5: [0, 2, 1, 3, 4][ch]
  of 6: [0, 2, 1, 4, 5, 3][ch]
  of 7: [0, 2, 1, 5, 6, 4, 3][ch]
  of 8: [0, 2, 1, 6, 7, 4, 5, 3][ch]
  else: ch

# ------------------------------------------------------ setup headers ---

const
  VorbisPacketIdentification = 1'u8
  VorbisPacketSetup = 5'u8
  VorbisSignature = [0x76'u8, 0x6f, 0x72, 0x62, 0x69, 0x73] # "vorbis"
  VorbisVersion = 0'u32
  VorbisBlocksizeMin = 6
  VorbisBlocksizeMax = 13
  XiphLacedLeadingHeader = 2'u8

type
  IdentHeader* = object
    nChannels*: int
    sampleRate*: uint32
    bs0exp*: int
    bs1exp*: int

  VorbisSetup* = object
    codebooks*: seq[VorbisCodebook]
    floors*: seq[FloorObj]
    residues*: seq[Residue]
    mappings*: seq[Mapping]
    modes*: seq[Mode]

proc vorbisChannelsToChannels*(n: int): Channels =
  ## Vorbis channel order to positioned layouts (spec 4.3.9 sets).
  case n
  of 1: positioned(PosFrontLeft)
  of 2: ChStereo
  of 3: Ch3
  of 4: ChQuad
  of 5: Ch5
  of 6: Ch51
  of 7: Ch7
  of 8: Ch71
  else:
    if n in 9 .. 32: discrete(n)
    else: raise decodeError("vorbis: invalid channel count")

proc readIdentHeader*(r: var Reader): IdentHeader =
  if r.readByte() != VorbisPacketIdentification:
    raise decodeError("vorbis: invalid packet type for identification header")
  if r.readBytesExact(6) != @VorbisSignature:
    raise decodeError("vorbis: invalid header signature")
  if r.readU32Le() != VorbisVersion:
    raise unsupportedError("vorbis: only vorbis 1 is supported")
  let nch = r.readByte().int
  if nch == 0:
    raise decodeError("vorbis: number of channels cannot be 0")
  if nch > 32:
    raise unsupportedError("vorbis: only a maximum of 32 channels are supported")
  let rate = r.readU32Le()
  if rate == 0:
    raise decodeError("vorbis: sample rate cannot be 0")
  discard r.readU32Le()
  discard r.readU32Le()
  discard r.readU32Le()
  let bs = r.readByte().int
  let bs0 = bs and 0x0f
  let bs1 = (bs shr 4) and 0x0f
  if bs0 < VorbisBlocksizeMin or bs0 > VorbisBlocksizeMax:
    raise decodeError("vorbis: blocksize_0 out-of-bounds")
  if bs1 < VorbisBlocksizeMin or bs1 > VorbisBlocksizeMax:
    raise decodeError("vorbis: blocksize_1 out-of-bounds")
  if bs0 > bs1:
    raise decodeError("vorbis: blocksize_0 exceeds blocksize_1")
  if r.readByte() != 0x01:
    raise decodeError("vorbis: ident header framing flag unset")
  IdentHeader(nChannels: nch, sampleRate: rate, bs0exp: bs0, bs1exp: bs1)

proc readSetup*(data: openArray[uint8]; ident: IdentHeader): VorbisSetup =
  var r = newReader(data)
  if r.readByte() != VorbisPacketSetup:
    raise decodeError("vorbis: invalid packet type for setup header")
  if r.readBytesExact(6) != @VorbisSignature:
    raise decodeError("vorbis: invalid setup header signature")
  var bs = newRtlBitReader(r.readBytes(r.remaining()))
  let ncb = bs.readRtlBits(8).int + 1
  for _ in 0 ..< ncb:
    result.codebooks.add(readCodebook(bs))
  let ntd = bs.readRtlBits(6).int + 1
  for _ in 0 ..< ntd:
    if bs.readRtlBits(16) != 0:
      raise decodeError("vorbis: invalid time domain transform")
  let maxCb = result.codebooks.len
  let nf = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nf:
    result.floors.add(readFloor(bs, ident.bs0exp, ident.bs1exp, maxCb))
  let nr = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nr:
    let rt = bs.readRtlBits(16).int
    if rt < 0 or rt > 2:
      raise decodeError("vorbis: invalid residue type")
    result.residues.add(readResidue(bs, rt, maxCb))
  let nm = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nm:
    result.mappings.add(readMapping(bs, ident.nChannels,
      result.floors.len, result.residues.len))
  let nmodes = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nmodes:
    result.modes.add(readMode(bs, result.mappings.len))
  if not bs.readRtlBool():
    raise decodeError("vorbis: setup header framing flag unset")

proc unpackXiphLaced*(extra: openArray[uint8]): tuple[ident,
    setup: seq[uint8]] =
  ## Splits Matroska-style xiph-laced ident+setup (leading 0x02).
  if extra.len == 0:
    raise decodeError("vorbis: extradata is empty")
  if extra[0] != XiphLacedLeadingHeader:
    raise decodeError("vorbis: invalid Xiph lacing count")
  var pos = 1
  var lengths: array[2, int]
  for i in 0 ..< 2:
    while true:
      if pos >= extra.len:
        raise decodeError("vorbis: truncated length lacing")
      let v = extra[pos].int
      inc pos
      lengths[i] += v
      if v < 255:
        break
  if extra.len - pos < lengths[0] + lengths[1]:
    raise decodeError("vorbis: header lengths exceed buffer size")
  if lengths[0] + lengths[1] == 0 or
      pos + lengths[0] + lengths[1] > extra.len:
    raise decodeError("vorbis: no data remains after reading lacing")
  (extra.toOpenArray(pos, pos + lengths[0] - 1).toSeq(),
    extra.toOpenArray(pos + lengths[0] + lengths[1],
      extra.len - 1).toSeq())

proc readExtradata*(extra: openArray[uint8]): tuple[ident: IdentHeader,
    setup: VorbisSetup] =
  if extra.len > 0 and extra[0] == XiphLacedLeadingHeader:
    let (pktIdent, pktSetup) = unpackXiphLaced(extra)
    var r = newReader(pktIdent)
    let ident = readIdentHeader(r)
    (ident, readSetup(pktSetup, ident))
  else:
    var r = newReader(extra)
    let ident = readIdentHeader(r)
    (ident, readSetup(r.readBytes(r.remaining()), ident))

proc skipVorbisCodebook(bs: var RtlBitReader) =
  if bs.readRtlBits(24) != 0x564342'u32:
    raise decodeError("vorbis: invalid codebook sync")
  let dims = bs.readRtlBits(16)
  let entries = bs.readRtlBits(24)
  let ordered = bs.readRtlBool()
  if not ordered:
    if bs.readRtlBool():
      for _ in 0 ..< entries.int:
        if bs.readRtlBool():
          discard bs.readRtlBits(5)
    else:
      bs.ignoreRtlBits(entries.int * 5)
  else:
    var curEntry = 0'u32
    discard bs.readRtlBits(5)
    while true:
      let numBits =
        if entries > curEntry: ilog(entries - curEntry) else: 0
      let num = bs.readRtlBits(numBits.int)
      curEntry += num
      if curEntry > entries:
        raise decodeError("vorbis: invalid codebook")
      if curEntry == entries:
        break
  let lookup = bs.readRtlBits(4)
  case lookup and 0xf
  of 0: discard
  of 1, 2:
    discard bs.readRtlBits(32)
    discard bs.readRtlBits(32)
    let valueBits = bs.readRtlBits(4) + 1
    discard bs.readRtlBool()
    let nvals =
      if lookup == 1: lookup1Values(entries, dims.int)
      else: entries * dims
    bs.ignoreRtlBits((nvals * valueBits).int)
  else:
    raise decodeError("vorbis: invalid codeword lookup type")

proc skipVorbisFloor(bs: var RtlBitReader) =
  let t = bs.readRtlBits(16)
  if t == 0:
    bs.ignoreRtlBits(8 + 16 + 16 + 6 + 8)
    let n = bs.readRtlBits(4) + 1
    bs.ignoreRtlBits(n.int * 8)
  elif t == 1:
    let parts = bs.readRtlBits(5).int
    var classOfPart: array[32, int]
    var dimsOfClass: array[16, int]
    if parts > 0:
      var maxClass = 0
      for i in 0 ..< parts:
        let c = bs.readRtlBits(4).int
        classOfPart[i] = c
        maxClass = max(maxClass, c)
      for i in 0 ..< maxClass + 1:
        dimsOfClass[i] = bs.readRtlBits(3).int + 1
        let subclass = bs.readRtlBits(2)
        if subclass != 0:
          discard bs.readRtlBits(8)
        bs.ignoreRtlBits((1 shl subclass.int) * 8)
    discard bs.readRtlBits(2) # multiplier
    let rangebits = bs.readRtlBits(4).int
    for i in 0 ..< parts:
      bs.ignoreRtlBits(dimsOfClass[classOfPart[i]] * rangebits)
  else:
    raise decodeError("vorbis: invalid floor type")

proc skipVorbisResidue(bs: var RtlBitReader) =
  discard bs.readRtlBits(16)
  bs.ignoreRtlBits(24 + 24 + 24)
  let ncls = bs.readRtlBits(6).int + 1
  discard bs.readRtlBits(8)
  var nbooks = 0
  for _ in 0 ..< ncls:
    let lo = bs.readRtlBits(3).int
    let hi =
      if bs.readRtlBool(): bs.readRtlBits(5).int
      else: 0
    var used = (hi shl 3) or lo
    while used != 0:
      if (used and 1) != 0:
        inc nbooks
      used = used shr 1
  bs.ignoreRtlBits(nbooks * 8)

proc skipVorbisMapping(bs: var RtlBitReader; audioChannels: int) =
  let t = bs.readRtlBits(16)
  if t != 0:
    raise decodeError("vorbis: invalid mapping type")
  let nsub =
    if bs.readRtlBool(): bs.readRtlBits(4).int + 1
    else: 1
  if bs.readRtlBool():
    let steps = bs.readRtlBits(8).int + 1
    let cbits = ilog(max(audioChannels - 1, 0).uint32).int
    bs.ignoreRtlBits(steps * cbits * 2)
  if bs.readRtlBits(2) != 0:
    raise decodeError("vorbis: reserved mapping bits non-zero")
  if nsub > 1:
    bs.ignoreRtlBits(audioChannels * 4)
  bs.ignoreRtlBits(nsub * (8 + 8 + 8))

proc skipVorbisSetupModes*(setupPacket: openArray[uint8];
    audioChannels: int): tuple[numModes: int, blockFlags: uint64] =
  ## Demuxer-side skim: mode count + block flags without building codebooks.
  ## Block exponents come from the ident packet.
  var r = newReader(setupPacket)
  if r.readByte() != VorbisPacketSetup:
    raise decodeError("vorbis: invalid packet type for setup header")
  if r.readBytesExact(6) != @VorbisSignature:
    raise decodeError("vorbis: invalid setup header signature")
  var bs = newRtlBitReader(r.readBytes(r.remaining()))
  let ncb = bs.readRtlBits(8).int + 1
  for _ in 0 ..< ncb:
    skipVorbisCodebook(bs)
  let ntd = bs.readRtlBits(6).int + 1
  for _ in 0 ..< ntd:
    if bs.readRtlBits(16) != 0:
      raise decodeError("vorbis: invalid time domain transform")
  let nf = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nf:
    skipVorbisFloor(bs)
  let nr = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nr:
    skipVorbisResidue(bs)
  let nm = bs.readRtlBits(6).int + 1
  for _ in 0 ..< nm:
    skipVorbisMapping(bs, audioChannels)
  let nmodes = bs.readRtlBits(6).int + 1
  var flags = 0'u64
  for i in 0 ..< nmodes:
    let blockFlag = bs.readRtlBool()
    discard bs.readRtlBits(16)
    discard bs.readRtlBits(16)
    discard bs.readRtlBits(8)
    if blockFlag:
      flags = flags or (1'u64 shl i)
  (nmodes, flags)


# ------------------------------------------------------------- decoder ---

type
  VorbisDecoder* = ref object of AudioDecoder
    opts*: AudioDecoderOptions
    params*: AudioCodecParameters
    ident*: IdentHeader
    codebooks*: seq[VorbisCodebook]
    floors*: seq[FloorObj]
    residues*: seq[Residue]
    modes*: seq[Mode]
    mappings*: seq[Mapping]
    dsp*: Dsp
    buf*: AudioSamples # sfF32

proc newVorbisDecoder*(params: AudioCodecParameters;
    opts = defaultDecoderOptions()): VorbisDecoder =
  if params.codec != CodecVorbis:
    raise unsupportedError("vorbis: invalid codec")
  if params.extraData.len == 0:
    raise unsupportedError("vorbis: missing extra data")
  let (ident, setup) = readExtradata(params.extraData)
  let channels =
    try: vorbisChannelsToChannels(ident.nChannels)
    except AudioError: raise unsupportedError("vorbis: unknown channel map")
  let spec = newAudioSpec(ident.sampleRate, channels)
  let windows = Windows(short: generateWinCurve(1 shl ident.bs0exp),
    long: generateWinCurve(1 shl ident.bs1exp))
  var dspChannels: seq[DspChannel] = @[]
  for _ in 0 ..< ident.nChannels:
    dspChannels.add(newDspChannel(ident.bs0exp, ident.bs1exp))
  result = VorbisDecoder(opts: opts, params: params, ident: ident,
    codebooks: setup.codebooks, floors: setup.floors,
    residues: setup.residues, mappings: setup.mappings,
    modes: setup.modes,
    dsp: Dsp(channels: dspChannels,
      imdctShort: newImdct(1 shl (ident.bs0exp - 1)),
      imdctLong: newImdct(1 shl (ident.bs1exp - 1)),
      windows: windows, prevBlockFlag: none(bool)),
    buf: newAudioSamples(sfF32, spec, 1 shl ident.bs1exp))

proc decodeFrames(d: VorbisDecoder; data: seq[uint8]) =
  var bs = newRtlBitReader(data)
  if bs.readRtlBool():
    raise decodeError("vorbis: not an audio packet")
  let numModes = d.modes.len - 1
  let modeNumber = bs.readRtlBits(ilog(cast[uint32](numModes)).int).int
  if modeNumber >= d.modes.len:
    raise decodeError("vorbis: invalid packet mode number")
  let mode = d.modes[modeNumber]
  let mapping = d.mappings[mode.mapping]
  var imdct {.noInit.}: ptr Imdct
  var bsExp: int
  if mode.blockFlag:
    discard bs.readRtlBool()
    discard bs.readRtlBool()
    bsExp = d.ident.bs1exp
    imdct = d.dsp.imdctLong.addr
  else:
    bsExp = d.ident.bs0exp
    imdct = d.dsp.imdctShort.addr
  let n = 1 shl bsExp
  let n2 = n shr 1
  # Floors, one per channel via the mapping multiplex.
  for mi, ch in d.dsp.channels.mpairs:
    let submapIdx = mapping.multiplex[mi]
    let submap = mapping.submaps[submapIdx]
    let floor = d.floors[submap.floor]
    try:
      floorReadChannel(floor, bs, d.codebooks)
    except EndOfStream as e:
      raise decodeError("vorbis: " & e.msg)
    ch.doNotDecode = floorIsUnused(floor)
    if not ch.doNotDecode:
      floorSynthesis(floor, bsExp, ch.floor.toOpenArray(0, n2 - 1))
    else:
      for i in 0 ..< n2:
        ch.floor[i] = 0.0
  # Non-zero vector propagate for coupled channels.
  for c in mapping.couplings:
    if d.dsp.channels[c.magnitude].doNotDecode !=
        d.dsp.channels[c.angle].doNotDecode:
      d.dsp.channels[c.magnitude].doNotDecode = false
      d.dsp.channels[c.angle].doNotDecode = false
  # Residues, one submap at a time.
  for si, submap in mapping.submaps:
    var chIdx: seq[int] = @[]
    for ci, m in mapping.multiplex:
      if m == si:
        chIdx.add(ci)
    try:
      d.residues[submap.residue].readResidueData(bs, bsExp, d.codebooks,
        chIdx, d.dsp.channels)
    except EndOfStream as e:
      raise decodeError("vorbis: " & e.msg)
  # Inverse coupling, reversed.
  for i in countdown(mapping.couplings.len - 1, 0):
    let c = mapping.couplings[i]
    if c.magnitude == c.angle:
      continue
    for j in 0 ..< n2:
      let m = d.dsp.channels[c.magnitude].residue[j]
      let a = d.dsp.channels[c.angle].residue[j]
      if m > 0:
        if a > 0:
          d.dsp.channels[c.angle].residue[j] = m - a
        else:
          d.dsp.channels[c.magnitude].residue[j] = m + a
          d.dsp.channels[c.angle].residue[j] = m
      else:
        if a > 0:
          d.dsp.channels[c.angle].residue[j] = m + a
        else:
          d.dsp.channels[c.magnitude].residue[j] = m - a
          d.dsp.channels[c.angle].residue[j] = m
  # Dot product.
  for ch in d.dsp.channels.mitems:
    if ch.doNotDecode:
      continue
    for i in 0 ..< n2:
      ch.floor[i] = ch.floor[i] * ch.residue[i]
  # IMDCT + overlap-add.
  d.buf.f32.clear()
  let prevFlag = d.dsp.prevBlockFlag.get(mode.blockFlag)
  let prevN = 1 shl (if prevFlag: d.ident.bs1exp else: d.ident.bs0exp)
  d.buf.f32.renderWith((prevN + n) div 4, i):
    discard i
  for ci, ch in d.dsp.channels.mpairs:
    let planeIdx = mapVorbisChannel(d.ident.nChannels, ci)
    ch.synthChannel(mode.blockFlag, prevFlag, d.dsp.windows, imdct[],
      d.buf.f32.planes[planeIdx].toOpenArray(0,
        d.buf.f32.numFrames - 1))
  # Gapless trim; first packet after reset is silenced.
  if d.opts.gapless:
    if d.dsp.prevBlockFlag.isNone:
      d.buf.f32.clear()
  d.dsp.prevBlockFlag = some(mode.blockFlag)

method codecParams*(d: VorbisDecoder): AudioCodecParameters = d.params

method reset*(d: VorbisDecoder) =
  resetDsp(d.dsp)

method decodePacket*(d: VorbisDecoder; pkt: Packet): AudioSamples =
  try:
    d.decodeFrames(pkt.data)
  except AudioError as e:
    d.buf.clearSamples()
    raise e
  except IndexDefect, RangeDefect:
    d.buf.clearSamples()
    raise decodeError("vorbis: invalid bitstream")
  # Apply packet trims (gapless) after a successful decode.
  if d.opts.gapless and d.buf.framesOf() > 0:
    let total = d.buf.framesOf()
    let dropFirst = min(pkt.trimStart.get.int, total)
    let keep = total - dropFirst
    let dropLast = min(pkt.trimEnd.get.int, keep)
    if dropFirst > 0 or dropLast > 0:
      d.buf.f32.shift(dropFirst)
      d.buf.f32.truncate(d.buf.f32.numFrames - dropLast)
  d.buf

method lastDecoded*(d: VorbisDecoder): AudioSamples = d.buf

proc vorbisDecoderFactory*(params: AudioCodecParameters;
    opts: AudioDecoderOptions): AudioDecoder =
  newVorbisDecoder(params, opts)

proc registerVorbis*() =
  registerAudioDecoder(CodecVorbis, vorbisDecoderFactory)
