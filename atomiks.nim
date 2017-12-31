# Copyright 2017 Sebastien Diot.

{.experimental.}

from volatile import nil

const
  hasThreadSupport = compileOption("threads") and not defined(nimscript)
    ## Do we even have threads?

type
  VolatilePtr*[T] = distinct ptr T
    ## A pointer to some volatile value
  VolatileArray*[N : static[int];T] = distinct ptr T
    ## An array to some volatile values

template declVolatile*(name: untyped, T: typedesc) {.dirty.} =
  ## Defines an hidden volatile value and a pointer to it
  var `volatile XXX name XXX value` {.global,volatile.}: T
  let `name` {.global.} = cast[VolatilePtr[T]](addr `volatile XXX name XXX value`)

template declVolatile*(name: untyped, T: typedesc, init: T) {.dirty.} =
  ## Defines an hidden volatile value, with an initial value,  and a pointer to it
  var `volatile XXX name XXX value` {.global,volatile.} = init
  let `name` {.global.} = cast[VolatilePtr[T]](addr `volatile XXX name XXX value`)

template declVolatileArray*(name: untyped, T: typedesc, N: static[int]) {.dirty.} =
  ## Defines an hidden volatile value array and a pointer to it
  static: assert(N > 0)
  var `volatile XXX name XXX value` {.global,volatile.}: array[N,T]
  let `name` {.global.} = cast[VolatileArray[N,T]](addr `volatile XXX name XXX value`[0])

proc `[]`*[N;T](v: VolatileArray[N,T], i: int): VolatilePtr[T] {.inline, noSideEffect.} =
  ## Accesses a specific volatile loation in a volatile array
  assert((0 <= i) and (i < N))
  result = cast[VolatilePtr[T]](cast[ByteAddress](v)+i*sizeof(T))

when declared(atomicLoadN):
  static:
    echo("COMPILING USING PTHREADS!")

  template volatileLoad*[T: AtomType](src: VolatilePtr[T]): T =
    ## Generates a volatile load of the value stored in the container `src`.
    ## Note that this only effects code generation on `C` like backends
    volatile.volatileLoad(cast[ptr T](src))

  template volatileStore*[T: AtomType](dest: VolatilePtr[T], val: T) =
    ## Generates a volatile store into the container `dest` of the value
    ## `val`. Note that this only effects code generation on `C` like
    ## backends
    volatile.volatileStore(cast[ptr T](dest), val)

  proc atomicLoadFull*[T: AtomType](p: VolatilePtr[T]): T {.inline.} =
    ## This proc implements an atomic load operation. It returns the contents at p.
    atomicLoadN(cast[ptr[T]](p), ATOMIC_SEQ_CST)

  proc atomicStoreFull*[T: AtomType](p: VolatilePtr[T], val: T): void {.inline.} =
    ## This proc implements an atomic store operation. It writes val at p.
    atomicStoreN(cast[ptr[T]](p), val, ATOMIC_SEQ_CST)

  proc atomicExchangeFull*[T: AtomType](p: VolatilePtr[T], val: T): T {.inline.} =
    ## This proc implements an atomic exchange operation. It writes val at p,
    ## and returns the previous contents at p.
    atomicExchangeN(cast[ptr[T]](p), val, ATOMIC_SEQ_CST)

  proc atomicCompareExchangeFull*[T: AtomType](p: VolatilePtr[T], expected: ptr T, desired: T): bool {.inline.} =
    ## This proc implements an atomic compare and exchange operation. This compares the
    ## contents at p with the contents at expected and if equal, writes desired at p.
    ## If they are not equal, the current contents at p is written into expected.
    ## True is returned if desired is written at p. False is returned otherwise,
    atomicCompareExchangeN(cast[ptr[T]](p), expected, desired, false, ATOMIC_SEQ_CST, ATOMIC_RELAXED)

  proc atomicIncRelaxed*[T: AtomType](p: VolatilePtr[T], x: T = cast[T](1)): T =
    ## Increments a volatile (32/64 bit) value, and returns the new value.
    ## Performed in RELAXED/No-Fence memory-model.
    when (sizeof(T) == 8) or (sizeof(T) == 4):
      cast[T](atomicAddFetch(cast[ptr[T]](p), x, ATOMIC_RELAXED))
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))

  proc atomicDecRelaxed*[T: AtomType](p: VolatilePtr[T], x: T = cast[T](1)): T =
    ## Increments a volatile (32/64 bit) value, and returns the new value.
    ## Performed in RELAXED/No-Fence memory-model.
    when (sizeof(T) == 8) or (sizeof(T) == 4):
      cast[T](atomicSubFetch(cast[ptr[T]](p), x, ATOMIC_RELAXED))
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))

elif defined(vcc) and hasThreadSupport:
  # Windows...

  static:
    echo("COMPILING USING WINDOWS THREADS!")

  type
    AtomType* = SomeNumber|pointer|ptr|char|bool
      ## Things that can be volatile

  template volatileLoad*[T: AtomType](src: VolatilePtr[T]): T =
    ## Generates a volatile load of the value stored in the container `src`.
    ## Note that this only effects code generation on `C` like backends
    volatile.volatileLoad(cast[ptr T](src))

  template volatileStore*[T: AtomType](dest: VolatilePtr[T], val: T) =
    ## Generates a volatile store into the container `dest` of the value
    ## `val`. Note that this only effects code generation on `C` like
    ## backends
    volatile.volatileStore(cast[ptr T](dest), val)

  when defined(cpp):
    proc interlockedOr64(p: pointer; value: int64): int64
      {.importcpp: "_InterlockedOr64(static_cast<__int64 volatile *>(#), #)", header: "<intrin.h>".}
    proc interlockedOr32(p: pointer; value: int32): int32
      {.importcpp: "_InterlockedOr(static_cast<long volatile *>(#), #)", header: "<intrin.h>".}
    proc interlockedOr16(p: pointer; value: int16): int16
      {.importcpp: "_InterlockedOr16(static_cast<short volatile *>(#), #)", header: "<intrin.h>".}
    proc interlockedOr8(p: pointer; value: int8): int8
      {.importcpp: "_InterlockedOr8(static_cast<char volatile *>(#), #)", header: "<intrin.h>".}

    proc interlockedExchange64(p: pointer; exchange: int64): int64
      {.importcpp: "_InterlockedExchange64(static_cast<__int64 volatile *>(#), #)", header: "<intrin.h>".}
    proc interlockedExchange32(p: pointer; exchange: int32): int32
      {.importcpp: "_InterlockedExchange(static_cast<long volatile *>(#), #)", header: "<intrin.h>".}
    proc interlockedExchange16(p: pointer; exchange: int16): int16
      {.importcpp: "_InterlockedExchange16(static_cast<short volatile *>(#), #)", header: "<intrin.h>".}
    proc interlockedExchange8(p: pointer; exchange: int8): int8
      {.importcpp: "_InterlockedExchange8(static_cast<char volatile *>(#), #)", header: "<intrin.h>".}

    proc interlockedCompareExchange64(p: pointer; exchange, comparand: int64): int64
      {.importcpp: "_InterlockedCompareExchange64(static_cast<__int64 volatile *>(#), #, #)", header: "<intrin.h>".}
    proc interlockedCompareExchange32(p: pointer; exchange, comparand: int32): int32
      {.importcpp: "_InterlockedCompareExchange(static_cast<long volatile *>(#), #, #)", header: "<intrin.h>".}
    proc interlockedCompareExchange16(p: pointer; exchange, comparand: int16): int16
      {.importcpp: "_InterlockedCompareExchange16(static_cast<short volatile *>(#), #, #)", header: "<intrin.h>".}
    proc interlockedCompareExchange8(p: pointer; exchange, comparand: int8): int8
      {.importcpp: "_InterlockedCompareExchange8(static_cast<char volatile *>(#), #, #)", header: "<intrin.h>".}

    proc interlockedExchangeAdd64(p: pointer; val: int64): int64
      {.importcpp: "_InterlockedExchangeAdd64(static_cast<__int64 volatile *>(#), #)", header: "<windows.h>".}
    proc interlockedExchangeAdd32(p: pointer; val: int32): int32
      {.importcpp: "_InterlockedExchangeAdd(static_cast<long volatile *>(#), #)", header: "<windows.h>".}

    # These two are only available on Windows 8+, so Windows 7 is dead!
    proc interlockedExchangeAddNoFence64(p: pointer; val: int64): int64
      {.importcpp: "_InterlockedExchangeAddNoFence64(static_cast<__int64 volatile *>(#), #)", header: "<windows.h>".}
    proc interlockedExchangeAddNoFence32(p: pointer; val: int32): int32
      {.importcpp: "_InterlockedExchangeAddNoFence(static_cast<long volatile *>(#), #)", header: "<windows.h>".}

  else:
    proc interlockedOr64(p: pointer; value: int64): int64
      {.importc: "_InterlockedOr64", header: "<intrin.h>".}
    proc interlockedOr32(p: pointer; value: int32): int32
      {.importc: "_InterlockedOr", header: "<intrin.h>".}
    proc interlockedOr16(p: pointer; value: int16): int16
      {.importc: "_InterlockedOr16", header: "<intrin.h>".}
    proc interlockedOr8(p: pointer; value: int8): int8
      {.importc: "_InterlockedOr8", header: "<intrin.h>".}

    proc interlockedExchange64(p: pointer; exchange: int64): int64
      {.importc: "_InterlockedExchange64", header: "<intrin.h>".}
    proc interlockedExchange32(p: pointer; exchange: int32): int32
      {.importc: "_InterlockedExchange", header: "<intrin.h>".}
    proc interlockedExchange16(p: pointer; exchange: int16): int16
      {.importc: "_InterlockedExchange16", header: "<intrin.h>".}
    proc interlockedExchange8(p: pointer; exchange: int8): int8
      {.importc: "_InterlockedExchange8", header: "<intrin.h>".}

    proc interlockedCompareExchange64(p: pointer; exchange, comparand: int64): int64
      {.importc: "_InterlockedCompareExchange64", header: "<intrin.h>".}
    proc interlockedCompareExchange32(p: pointer; exchange, comparand: int32): int32
      {.importc: "_InterlockedCompareExchange", header: "<intrin.h>".}
    proc interlockedCompareExchange16(p: pointer; exchange, comparand: int16): int16
      {.importc: "_InterlockedCompareExchange16", header: "<intrin.h>".}
    proc interlockedCompareExchange8(p: pointer; exchange, comparand: int8): int8
      {.importc: "_InterlockedCompareExchange8", header: "<intrin.h>".}

    proc interlockedExchangeAdd64(p: pointer, val: int64): int64
      {.importc: "_InterlockedExchangeAdd64", header: "<windows.h>".}
    proc interlockedExchangeAdd32(p: pointer, val: int32): int32
      {.importc: "_InterlockedExchangeAdd", header: "<windows.h>".}

    # These two are only available on Windows 8+, so Windows 7 is dead!
    proc interlockedExchangeAddNoFence64(p: pointer, val: int64): int64
      {.importc: "_InterlockedExchangeAddNoFence64", header: "<windows.h>".}
    proc interlockedExchangeAddNoFence32(p: pointer, val: int32): int32
      {.importc: "_InterlockedExchangeAddNoFence", header: "<windows.h>".}

  proc atomicLoadFull*[T: AtomType](p: VolatilePtr[T]): T {.inline.} =
    ## This proc implements an atomic load operation. It returns the contents at p.
    let pp = cast[pointer](p)
    when sizeof(T) == 8:
      cast[T](interlockedOr64(pp, 0'i64))
    elif sizeof(T) == 4:
      cast[T](interlockedOr32(pp, 0'i32))
    elif sizeof(T) == 2:
      cast[T](interlockedOr16(pp, 0'i16))
    elif sizeof(T) == 1:
      cast[T](interlockedOr8(pp, 0'i8))
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))

  proc atomicExchangeFull*[T: AtomType](p: VolatilePtr[T], exchange: T): T {.inline.} =
    ## This proc implements an atomic exchange operation. It writes "exchange" at p,
    ## and returns the previous contents at p.
    let pp = cast[pointer](p)
    when sizeof(T) == 8:
      cast[T](interlockedExchange64(pp, cast[int64](exchange)))
    elif sizeof(T) == 4:
      cast[T](interlockedExchange32(pp, cast[int32](exchange)))
    elif sizeof(T) == 2:
      cast[T](interlockedExchange16(pp, cast[int16](exchange)))
    elif sizeof(T) == 1:
      cast[T](interlockedExchange8(pp, cast[int8](exchange)))
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))

  proc atomicStoreFull*[T: AtomType](p: VolatilePtr[T], val: T): void {.inline.} =
    ## No simple "store" available on Windows, uses exchange instead!
    ## This proc implements an atomic store operation. It writes val at p.
    discard atomicExchangeFull(p, val)

  proc atomicCompareExchangeFull*[T: AtomType](p: VolatilePtr[T], expected: ptr T, desired: T): bool {.inline.} =
    ## This proc implements an atomic compare and exchange operation. This compares the
    ## contents at p with the contents at expected and if equal, writes desired at p.
    ## If they are not equal, the current contents at p is written into expected.
    ## True is returned if desired is written at p. False is returned otherwise.
    let pp = cast[pointer](p)
    let oldVal = expected[]
    when sizeof(T) == 8:
      let current = cast[T](interlockedCompareExchange64(pp, cast[int64](desired), cast[int64](oldVal)))
    elif sizeof(T) == 4:
      let current = cast[T](interlockedCompareExchange32(pp, cast[int32](desired), cast[int32](oldVal)))
    elif sizeof(T) == 2:
      let current = cast[T](interlockedCompareExchange16(pp, cast[int16](desired), cast[int16](oldVal)))
    elif sizeof(T) == 1:
      let current = cast[T](interlockedCompareExchange8(pp, cast[int8](desired), cast[int8](oldVal)))
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))
    expected[] = current
    current == oldVal

  proc atomicIncFull*[T: AtomType](p: VolatilePtr[T], x: T = 1.int32): T =
    ## Increments a volatile (32/64 bit) value, and returns the new value.
    let pp = cast[pointer](p)
    when sizeof(T) == 8:
      cast[T](interlockedExchangeAdd64(pp, cast[int64](x))) + x
    elif sizeof(T) == 4:
      cast[T](interlockedExchangeAdd32(pp, cast[int32](x))) + x
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))

  proc atomicDecFull*[T: AtomType](p: VolatilePtr[T], x: T = 1.int32): T =
    ## Increments a volatile (32/64 bit) value, and returns the new value.
    let pp = cast[pointer](p)
    when sizeof(T) == 8:
      cast[T](interlockedExchangeAdd64(pp, -cast[int64](x))) - x
    elif sizeof(T) == 4:
      cast[T](interlockedExchangeAdd32(pp, -cast[int32](x))) - x
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))

  proc atomicIncRelaxed*[T: AtomType](p: VolatilePtr[T], x: T = 1.int32): T =
    ## Increments a volatile (32/64 bit) value, and returns the new value.
    ## Performed in RELAXED/No-Fence memory-model.
    ## Will only compile on Windows 8+!
    # XXX interlockedExchangeAddNoFence() is a lie! It doesn't actually exist!
    atomicIncFull(p,x)
    #[
    let pp = cast[pointer](p)
    when sizeof(T) == 8:
      cast[T](interlockedExchangeAddNoFence64(pp, cast[int64](x))) + x
    elif sizeof(T) == 4:
      cast[T](interlockedExchangeAddNoFence32(pp, cast[int32](x))) + x
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))
    ]#

  proc atomicDecRelaxed*[T: AtomType](p: VolatilePtr[T], x: T = 1.int32): T =
    ## Increments a volatile (32/64 bit) value, and returns the new value.
    ## Performed in RELAXED/No-Fence memory-model.
    ## Will only compile on Windows 8+!
    # XXX interlockedExchangeAddNoFence() is a lie! It doesn't actually exist!
    atomicDecFull(p,x)
    #[
    let pp = cast[pointer](p)
    when sizeof(T) == 8:
      cast[T](interlockedExchangeAddNoFence64(pp, -cast[int64](x))) - x
    elif sizeof(T) == 4:
      cast[T](interlockedExchangeAddNoFence32(pp, -cast[int32](x))) - x
    else:
      static: assert(false, "invalid parameter size: " & $sizeof(T))
    ]#

else:
  static:
    echo("COMPILING WITHOUT ANY KNOWN THREADS!")
  # XXX fixme
  discard
