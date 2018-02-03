# Copyright 2017 Sebastien Diot.

## Experimental module, used to define objects that can be efficiently "serialized", independent of CPU endianness.

#import endians

type
  Uint8Array* {.unchecked.} [SIZE: static[int]] = array[SIZE, uint8]
  Uint16Array* {.unchecked.} [SIZE: static[int]] = array[SIZE, uint16]
  Uint32Array* {.unchecked.} [SIZE: static[int]] = array[SIZE, uint32]
  Uint64Array* {.unchecked.} [SIZE: static[int]] = array[SIZE, uint64]

  SavableValue* = SomeNumber|char|bool
    ## Things that can be put in Savable

  Savable*[U8,U16,U32,U64: static[int]] = object
    ## Type for "savable" objects.
    ## Allows quick endian convertion for cross-platform compatibility.
    when U64 > 0:
      u64fields*: Uint64Array[U64]
        ## All uint64 (bytes) values
    when U32 > 0:
      u32fields*: Uint32Array[U32]
        ## All uint32 (bytes) values
    when U16 > 0:
      u16fields*: Uint16Array[U16]
        ## All uint16 (bytes) values
    when U8 > 0:
      u8fields*: Uint8Array[U8]
        ## All uint8 (bytes) values

proc getAt*[T: SavableValue, U8,U16,U32,U64: static[int]](
    s: var Savable[U8,U16,U32,U64], N: static[int]): T {.inline.} =
  ## Returns a field from Savable
  static:
    assert(N >= 0, "negative index not allowed: " & $N)
    assert((T != int) and (T != uint) and (T != float), "Only fixed-size types allowed!")
  when (T == char) or (T == bool):
    # We make sure char and bool are treated as 1 byte everywhere.
    static:
      assert(N < U8, "index too big: " & $N & " >= " & $U8)
    cast[T](s.u8fields[N])
  elif sizeof(T) == 8:
    static:
      assert(N < U64, "index too big: " & $N & " >= " & $U64)
    cast[T](s.u64fields[N])
  elif sizeof(T) == 4:
    static:
      assert(N < U32, "index too big: " & $N & " >= " & $U32)
    cast[T](s.u32fields[N])
  elif sizeof(T) == 2:
    static:
      assert(N < U16, "index too big: " & $N & " >= " & $U16)
    cast[T](s.u16fields[N])
  elif sizeof(T) == 1:
    static:
      assert(N < U8, "index too big: " & $N & " >= " & $U8)
    cast[T](s.u8fields[N])
  else:
    static: assert(false, "invalid parameter size: " & $sizeof(T))

proc setAt*[T: SavableValue, U8,U16,U32,U64: static[int]](
    s: var Savable[U8,U16,U32,U64], N: static[int], v: T) {.inline.} =
  ## Sets a field from Savable
  static:
    assert(N >= 0, "negative index not allowed!")
    assert((T != int) and (T != uint) and (T != float), "Only fixed-size types allowed!")
  when (T == char) or (T == bool):
    # We make sure char and bool are treated as 1 byte everywhere.
    static:
      assert(N < U8, "index too big: " & $N & " >= " & $U8)
    s.u8fields[N] = cast[uint8](v)
  elif sizeof(T) == 8:
    static:
      assert(N < U64, "index too big: " & $N & " >= " & $U64)
    s.u64fields[N] = cast[uint64](v)
  elif sizeof(T) == 4:
    static:
      assert(N < U32, "index too big: " & $N & " >= " & $U32)
    s.u32fields[N] = cast[uint32](v)
  elif sizeof(T) == 2:
    static:
      assert(N < U16, "index too big: " & $N & " >= " & $U16)
    s.u16fields[N] = cast[uint16](v)
  elif sizeof(T) == 1:
    static:
      assert(N < U8, "index too big: " & $N & " >= " & $U8)
    s.u8fields[N] = cast[uint8](v)
  else:
    static: assert(false, "invalid parameter size: " & $sizeof(T))

type
  TestSaveable* = Savable[4,3,2,1]

var ts: TestSaveable

ts.setAt(2, true)
var b: bool = ts.getAt[TestSaveable,4,3,2,1](2)
echo($b)

#[
template `+`[T](p: ptr T, off: int): ptr T =
  cast[ptr type(p[])](cast[ByteAddress](p) +% off * sizeof(p[]))

const LITTLE_ENDIAN = (cpuEndian == littleEndian)
  ## Is the CPU little endian?

proc hostToLittleEndian*[U8,U16,U32,U64: static[int]](
    s: var Savable[U8,U16,U32,U64]): void =
  ## Converts a Savable from "host endian" to "little endian".
  when LITTLE_ENDIAN:
    discard
  else:
    when U64 > 0:
      let u64fields = addr s.u64fields
      for i in 0..<U64:
        let p = u64fields + i
        swapEndian64(p, p)
    when U32 > 0:
      let u32fields = addr s.u32fields
      for i in 0..<U32:
        let p = u32fields + i
        swapEndian32(p, p)
    when U16 > 0:
      let u16fields = addr s.u16fields
      for i in 0..<U16:
        let p = u16fields + i
        swapEndian16(p, p)

proc littleEndianToHost*[U8,U16,U32,U64: static[int]](
    s: var Savable[U8,U16,U32,U64]): void {.inline.} =
  ## Converts a Savable from "little endian" to "host endian".
  hostToLittleEndian(s)
]#
