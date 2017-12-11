# Copyright 2017 Sebastien Diot.

# A type-register maps types to IDs and back, at runtime.
# No attempt is made to return the same IDs on every run.

import typetraits
import hashes
import options

import rekjister
import tekst

export hash, `==`, id

type
  TypeInfoIntern[M] = object
    ## "internal" type-information type
    mysize: uint32
    myinfo: M
  TypeRegister*[M: not (ref|seq|string)] = Register[SharedText,TypeInfoIntern[M]]
    ## A type register support type T meta-info.
  TypeInfo*[M] = Registration[SharedText,TypeInfoIntern[M]]
    ## Information about a registered type.
  TypeID* = RegistrationID
    ## The ID of a type


converter toSharedText*(T: typedesc): SharedText {.inline, noSideEffect.} =
  ## Automatically converts a type to a SharedText. The type name is *not* cloned.
  result = initSharedText(T.name)

proc name*[M](ti: TypeInfo[M]): cstring {.inline, noSideEffect.} =
  ## Returns the id of the type
  result = ti.key.cstr

proc size*[M](ti: TypeInfo[M]): uint32 {.inline, noSideEffect.} =
  ## Returns the size of the type
  result = ti.value.mysize

proc info*[M](ti: TypeInfo[M]): M {.inline, noSideEffect.} =
  ## Returns the meta-info of the type
  result = ti.value.myinfo

proc initTypeInfo*[M](id: uint32, name: cstring, size: uint32, info: M): TypeInfo[M] {.inline, noSideEffect.} =
  ## Initialises and return a TypeInfo[M]. name is *not* cloned.
  var tii: TypeInfoIntern[M]
  tii.mysize = size
  tii.myinfo = info
  result = initRegistration[SharedText,TypeInfo[M]](id, tii)
  var key = result.key
  var value = result.value

proc deinitTypeInfo[M](id: TypeID, key: var SharedText, value: var TypeInfoIntern[M]): void {.nimcall.} =
  ## Frees memory used by the type name cstring.
  deinitSharedText(key)

proc initTypeRegister*(M: typedesc, capacity: int = 64): TypeRegister[M] =
  ## Creates a new type register.
  initRegister[SharedText,TypeInfoIntern[M]](capacity)

proc initTypeRegister*(M: typedesc, src: openArray[TypeInfo[M]]): TypeRegister[M] =
  ## Creates a new type register, and initialise it from src.
  ## Note: src will be *sorted* by ID during creation!
  # First, validate the hell out of the input.
  for ti in src:
    if ti.key.len == 0:
      raise newException(Exception, "Type (ID: " & $ti.id & "): name cannot be empty!")
    if $(ti.key).split.len != 1:
      raise newException(Exception, "Type (ID: " & $ti.id & ", name: " & ti.key & "): name cannot contain whitespace!")
    if ti.value.mysize == 0:
      raise newException(Exception, "Type (ID: " & $ti.id & ", name: " & ti.key & "): cannot have size 0")
  # Input seems OK... so create it.
  result = initTypeRegister(M, src)

proc deinitTypeRegister*[M](reg: var TypeRegister[M]) =
  ## Frees memory used by the type register.
  deinitRegister(reg, deinitTypeInfo[M])

proc find*[M](reg: var TypeRegister[M], T: typedesc): Option[TypeInfo[M]] {.inline, noSideEffect.} =
  ## Returns a type's type-info, if present.
  reg.fromKey(toSharedText(T))

proc find*[M](reg: var TypeRegister[M], id: TypeID): Option[TypeInfo[M]] {.inline, noSideEffect.} =
  ## Returns a type's type-info, if present.
  reg.fromID(id)

proc register*[M](reg: var TypeRegister[M], T: typedesc, info: M): TypeInfo[M] =
  ## Register a new type, and returns it's type-info.
  var tii: TypeInfoIntern[M]
  tii.mysize = uint32(sizeof(T))
  tii.myinfo = info
  reg.register(toSharedText(T).sharedCopy(), tii)

proc get*[M](reg: var TypeRegister[M], T: typedesc): TypeInfo[M] {.inline.} =
  ## Returns a type's type-info, if present.
  ## Otherwise, register the type with a default meta-info!
  let tmp = reg.find(T)
  if isSome(tmp):
    return tmp.unsafeGet
  try:
    var m: M
    return reg.register(T, m)
  except:
    if reg.frozen:
      raise newException(Exception, "TypeRegister is frozen!")
    # Must be there now!
    return reg.find(T).get

when isMainModule:
  import threadpool

  var reg = initTypeRegister(bool)

  proc typeIDTestHelper(): uint32 = reg.get(uint8).id

  proc testTypeID(): void =
    echo "STARTING testTypeID()"
    let t0 = reg.get(uint8).id
    let t1 = reg.get(bool).id
    let fv = spawn typeIDTestHelper()
    let t3 = ^fv
    assert(t0 != t1)
    assert(t0 == t3)
    echo "DONE testTypeID()"

  proc testTypeName(): void =
    echo "STARTING testTypeName()"
    let t0 = reg.get(uint8).name
    let t1 = reg.get(bool).name
    assert($t0 == "uint8")
    assert($t1 == "bool")
    echo "DONE testTypeName()"

  testTypeID()
  testTypeName()

  deinitTypeRegister(reg)