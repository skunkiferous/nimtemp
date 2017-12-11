# Copyright 2017 Sebastien Diot.

# General utilities for the Geht Actor System

import unicode


#[
# FOR DEBUGGING:
proc binDigits(x: BiggestInt, r: int): int =
  ## Calculates how many digits `x` has when each digit covers `r` bits.
  result = 1
  var y = x shr r
  while y > 0:
    y = y shr r
    inc(result)

proc toBin*(x: BiggestInt, len: Natural = 0): string =
  ## converts `x` into its binary representation. The resulting string is
  ## always `len` characters long. By default the length is determined
  ## automatically. No leading ``0b`` prefix is generated.
  var
    mask: BiggestInt = 1
    shift: BiggestInt = 0
    len = if len == 0: binDigits(x, 1) else: len
  result = newString(len)
  for j in countdown(len-1, 0):
    result[j] = chr(int((x and mask) shr shift) + ord('0'))
    shift = shift + 1
    mask = mask shl 1
]#

proc toBin*[T: SomeNumber](x: T): string =
  ## converts `x` into its binary representation.
  var
    mask: T = 1
    shift: T = 0
    len = sizeof(T)*8
  result = newString(len)
  for j in countdown(len-1, 0):
    result[j] = chr(int((x and mask) shr shift) + ord('0'))
    shift = shift + 1
    mask = mask shl 1

type
  Opaque* = distinct int64  # Normally stores a pointer. Always 64-bits.

converter toOpaque*(t: pointer): Opaque = cast[Opaque](t)
converter toPointer*(o: Opaque): pointer = cast[pointer](o)
proc `==`*(a, b: Opaque): bool {.borrow.}

# <stuff> to bool (aka "Bad Style", according to the Nim Manual, but Python does that too...)
# Note: float to bool too dangerous; 0.00...1 is still "true".

converter toBool*(x: char): bool = x != char(0)
converter toBool*(x: Rune): bool = x != Rune(0)

converter toBool*(x: uint): bool = x != 0
converter toBool*(x: uint8): bool = x != 0
converter toBool*(x: uint16): bool = x != 0
converter toBool*(x: uint32): bool = x != 0
converter toBool*(x: uint64): bool = x != 0
converter toBool*(x: int): bool = x != 0
converter toBool*(x: int8): bool = x != 0
converter toBool*(x: int16): bool = x != 0
converter toBool*(x: int32): bool = x != 0
converter toBool*(x: int64): bool = x != 0

converter toBool*(x: enum): bool = x != 0

converter toBool*(x: pointer): bool = x != nil
converter toBool*(x: ptr[any]): bool = x != nil

converter toBool*(x: Opaque): bool = x != Opaque(0)

converter toBool*(x: auto): bool = (x != nil) and (x.len != 0)

type
  NotARefType* = enum  # The list types of (non-ref, fixed-size) basic types
    narBool,
    narChar,
    narRune,
    narUint8,
    narUint16,
    narUint32,
    narUint64,
    narInt8,
    narInt16,
    narInt32,
    narInt64,
    narFloat32,
    narFloat64,
    narCString,
    narPointer
  NotARef* = object    # Can contain any sort of non-ref, fixed-size, basic type.
    case kind: NotARefType
    of narBool: boolValue: bool
    of narChar: charValue: char
    of narRune: runeValue: Rune
    of narUint8: uint8Value: uint8
    of narUint16: uint16Value: uint16
    of narUint32: uint32Value: uint32
    of narUint64: uint64Value: uint64
    of narInt8: int8Value: int8
    of narInt16: int16Value: int16
    of narInt32: int32Value: int32
    of narInt64: int64Value: int64
    of narFloat32: float32Value: float32
    of narFloat64: float64Value: float64
    of narCString: cstringValue: cstring
    of narPointer: pointerValue: pointer
