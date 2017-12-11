# Copyright 2017 Sebastien Diot.

#import macros, strutils

#[
type
  VolatilePtr*[T] = distinct ptr T
  # Means it's a pointer to some volatile value

proc hasAnnotation(stuff: NimNode, annotation: static[string]): bool {.compileTime.} =
  (stuff.pragma.findChild(it.kind in {nnkSym, nnkIdent} and $it == annotation) != nil)

template toVolatilePtr*[T](t: untyped) =
  when hasAnnotation(t, "volatile"):
    VolatilePtr[T](addr t)
  else:
    {.error: "t is not volatile!".}


when isMainModule:
  var tua = 42'i32
  let p: VolatilePtr[int32] = toVolatilePtr[int32](tua)
  let tua2: int32 = 42'i32 #atomicLoadNSeqCST[int32](p)
  assert(tua2 == tua)
]#

type
  VolatilePtr*[T] = distinct ptr T

proc toVolatilePtr*[T](t: var T): VolatilePtr[T] =
  cast[VolatilePtr[T]](addr t)
  # Pretend we're actually checking it's volatile, which is apparently not possible to do.

var my_vbyte {.volatile.}: byte = 42'u8
var my_vbyte_ptr = toVolatilePtr[byte](my_vbyte)

type
  AtomType* = SomeNumber|pointer|ptr|char|bool
when defined(cpp):
  proc interlockedOr8(p: pointer; value: int8): int8
    {.importcpp: "_InterlockedOr8(static_cast<char volatile *>(#), #)", header: "<intrin.h>".}
else:
  proc interlockedOr8(p: pointer; value: int8): int8
    {.importc: "_InterlockedOr8", header: "<intrin.h>".}

proc atomicLoadFull*[T: AtomType](p: VolatilePtr[T]): T {.inline.} =
  let pp = cast[pointer](p)
  when sizeof(T) == 1:
    cast[T](interlockedOr8(pp, 0'i8))
  else: # TODO, sizeof(T) == (2|4|8)
    static: assert(false, "invalid parameter size: " & $sizeof(T))

assert(atomicLoadFull(my_vbyte_ptr) == 42'u8)
