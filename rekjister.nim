# Copyright 2017 Sebastien Diot.

## Maps keys to IDs and values. Map IDs to values as well, at runtime.
## This module is thread-safe.
## No attempt is made to return the same IDs on every run,
## But it is possible to pre-initialise a Register with specific IDs.

import algorithm
import hashes
import locks
import math
import options
import sets

import diktionary
import vektor

type
  RegistrationID* = uint32
      ## The unique registration ID
  Registration*[K,V] = object
    ## A unique value in the register.
    myid: RegistrationID
      ## The unique ID
    mykey: K
      ## The unique key
    myvalue: V
      ## The unique value
  Register*[K,V] = object
    ## A register mapping keys K to ID and values V, such that getting V from
    ## ID is just an array indexing.
    table: SharedTable[K, RegistrationID]
      ## The K to ID map
    list: SharedArray[Registration[K,V]]
      ## The ID to V array
    myfrozen: bool
      ## Can the register be modified?
    lock: Lock
      ## Lock to allow multi-threaded use.
  Cleaner*[K,V] = proc (id: RegistrationID, key: var K, value: var V): void {.nimcall.}

template withLk(t, x: untyped) =
  acquire(t.lock)
  try:
    x
  finally:
    release(t.lock)


proc initRegistration*[K,V](id: int64, key: K, value: V): Registration[K,V] =
  ## Creates a Registration. Normally used to pre-initialize a Register.
  result.myid = RegistrationID(id)
  result.mykey = key
  result.myvalue = value
  assert(int64(result.myid) == id)

proc `$`*[K,V](r: Registration[K,V]): string {.inline.} =
  ## Returns the string representation of the Registration
  result = "(" & $r.myid & "," & $r.mykey & "," & $r.myvalue & ")"

proc id*[K,V](r: Registration[K,V]): RegistrationID {.inline, noSideEffect.} =
  ## Returns the id of the registered value.
  result = r.myid

proc key*[K,V](r: Registration[K,V]): K {.inline, noSideEffect.} =
  ## Returns the key of the registered value.
  result = r.mykey

proc value*[K,V](r: Registration[K,V]): V {.inline, noSideEffect.} =
  ## Returns the registered value.
  result = r.myvalue

proc len*[K,V](reg: var Register[K,V]): int {.inline, noSideEffect.} =
  ## Returns the current size of the register.
  result = 0
  reg.withLk:
    result = reg.list.len

proc initRegister*[K,V](capacity: int = 64): Register[K,V] =
  ## Creates a new register, with a given (power-of-two) capacity.
  assert(capacity >= 0)
  initLock result.lock
  result.withLk:
    result.table = initSharedTable[K, RegistrationID](diktionary.rightSize(capacity))
    result.list = initSharedArray[Registration[K,V]](capacity)
    result.list.setLen(0)

proc initRegister*[K,V](src: var openarray[Registration[K,V]]): Register[K,V] =
  ## Creates a new register, and initialise it from src.
  ## Note: src will be *sorted* by ID during creation!
  # First, validate the input.
  proc v_id_cmp(a,b: Registration[K,V]): int =
    int(a.myid) - int(b.myid)
  sort(src, v_id_cmp)
  var keys: HashSet[K]
  keys.init(sets.rightSize(src.len))
  var nextID: RegistrationID = 0
  for r in src:
    if nextID != r.myid:
      raise newException(Exception, "Registration (ID: " & $r.myid & ", key: " & r.mykey & "): ID should be " & $nextID)
    if keys.containsOrIncl(r.mykey):
      raise newException(Exception, "Registration (ID: " & $r.myid & ", key: " & r.mykey & "): duplicate key!")
    nextID.inc
  # Input seems OK... so create it.
  result = initRegister[K,V](src.len)
  result.withLk:
    for r in src:
      result.table[r.mykey] = r.myid
      result.list.add(r)

#[
template initRegister*[K,V](iter: untyped): Register[K,V] =
  ## Creates a new register, and initialise it from src.
  var values = newSeq[Registration[K,V]]()
  for r in iter:
    values.add(r)
  initRegister[K,V](values)
]#
proc deinitRegister*[K,V](reg: var Register[K,V], cleaner: Cleaner[K,V] = nil): void =
  ## Destroys a register.
  reg.withLk:
    if cleaner != nil:
      for r in reg.list.mitems:
        cleaner(r.myid, r.mykey, r.myvalue)
    deinitSharedTable(reg.table)
    deinitSharedArray(reg.list)
  deinitLock(reg.lock)

proc freeze*[K,V](reg: var Register[K,V]): void {.inline, noSideEffect.} =
  ## Freezes the register, so that no new value can be registered.
  reg.withLk:
    reg.myfrozen = true

proc frozen*[K,V](reg: var Register[K,V]): bool {.inline, noSideEffect.} =
  ## Returns true if no new value can be registered.
  reg.withLk:
    result = reg.myfrozen

proc fromKey*[K,V](reg: var Register[K,V], k: K): Option[Registration[K,V]] {.inline, noSideEffect.} =
  ## Returns a keys's value, if present.
  result = none(Registration[K,V])
  reg.withLk:
    reg.table.withValue(k, rid) do:
      result = some(reg.list[int(rid[])])

proc fromID*[K,V](reg: var Register[K,V], id: RegistrationID): Option[Registration[K,V]] {.inline, noSideEffect.} =
  ## Returns a keys's value, if present.
  result = none(Registration[K,V])
  reg.withLk:
    if int(id) < reg.list.len:
      result = some(reg.list[int(id)])

proc register*[K,V](reg: var Register[K,V], key: K, value: V): Registration[K,V] =
  ## Registers a value, and returns it's Registration.
  ## Raises an Exception, if the key was already registered, or the Register is frozen.
  reg.withLk:
    if reg.table.hasKey(key):
      raise newException(Exception, "Key " & $key & " already registered!")
    if reg.myfrozen:
      raise newException(Exception, "Register is frozen!")
    result.mykey = key
    result.myvalue = value
    result.myid = RegistrationID(reg.list.len)
    reg.list.add(result)
    reg.table[key] = result.myid

iterator items*[K,V](reg: var Register[K,V]): Registration[K,V] {.inline.} =
  ## Returns over all Registrations. reg cannot be nil.
  var values: seq[Registration[K,V]]
  reg.withLk:
    let a = reg.list
    values = @a
  for r in values:
    yield r

when isMainModule:
  echo("TESTING Register ...")
  import threadpool

  var reg = initRegister[char,int]()

  proc typeIDTestHelper(): RegistrationID = reg.fromKey('A').get.id

  let r0 = reg.register('A', 0x0A).id
  let r1 = reg.register('B', 0x0B).id

  assert(reg.len == 2)

  proc testRegisteredID(): void =
    let t0 = reg.fromKey('A').get.id
    let t1 = reg.fromKey('B').get.id
    let fv = spawn typeIDTestHelper()
    let t3 = ^fv
    assert(t0 != t1)
    assert(t0 == t3)
    assert(t0 == r0)
    assert(t1 == r1)
    assert(reg.fromKey('C').isNone)

  proc testRegisteredKeyValue(): void =
    let v0 = reg.fromID(r0).get
    let v1 = reg.fromID(r1).get
    assert(v0.key == 'A')
    assert(v1.key == 'B')
    assert(v0.value == 0x0A)
    assert(v1.value == 0x0B)
    assert(reg.fromID(66).isNone)
    assert($v0 == "(0,A,10)")

  proc testRegisterFail(): void =
    var success = false
    try:
      discard reg.register('A', 66)
      success = true
    except:
      discard
    assert(not success, "duplicate register('A') should have failed")
    reg.freeze
    assert(reg.frozen, "register not frozen")
    success = false
    try:
      discard reg.register('C', 0x0C)
      success = true
    except:
      discard
    assert(not success, "register('C') allowed after freeze")
    assert(reg.len == 2)

  proc testRegisterPreInit(): void =
    deinitRegister(reg)
    var values = newSeq[Registration[char,int]]()
    values.add(initRegistration[char,int](0, 'C', 0x0C))
    values.add(initRegistration[char,int](1, 'D', 0x0D))
    reg = initRegister[char,int](values)
    assert(reg.len == 2)
    let v0 = reg.fromID(0).get
    let v1 = reg.fromID(1).get
    assert(v0.key == 'C')
    assert(v1.key == 'D')
    assert(v0.value == 0x0C)
    assert(v1.value == 0x0D)

  proc testRegisterItems(): void =
    var expected = newSeq[Registration[char,int]]()
    expected.add(initRegistration[char,int](0, 'C', 0x0C))
    expected.add(initRegistration[char,int](1, 'D', 0x0D))
    var actual = newSeq[Registration[char,int]]()
    for r in reg:
      actual.add(r)
    assert(expected == actual, $expected & " vs " & $actual)

  testRegisteredID()
  testRegisteredKeyValue()
  testRegisterFail()
  testRegisterPreInit()
  testRegisterItems()

  deinitRegister(reg)