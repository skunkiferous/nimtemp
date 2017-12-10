# Copyright 2017 Sebastien Diot.

## This module is almost an exact copy of the tables standard library module,
## except it works in the shared heap.
##
## The ``tables`` module implements variants of an efficient `hash table`:idx:
## (also often named `dictionary`:idx: in other programming languages) that is
## a mapping from keys to values. ``SharedTable`` is the usual hash table,
## ``SharedOrderedTable`` is like ``SharedTable`` but remembers insertion order
## and ``SharedCountTable`` is a mapping from a key to its number of occurrences.
## For consistency with every other data type in Nim these have **value**
## semantics, this means that ``=`` performs a copy of the hash table.
## For **pointer** semantics use the ``Ptr`` variant: ``SharedTablePtr``,
## ``SharedOrderedTablePtr``, ``SharedCountTablePtr``.
## To give an example, when `a` is a SharedTable, then `var b = a` gives `b`
## as a new independent table. b is initialised with the contents of `a`.
## Changing `b` does not affect `a` and vice versa:
##
## .. code-block::
##   import diktionary
##
##   var
##     a = {1: "one", 2: "two"}.toSharedTable  # creates a SharedTable
##     b = a
##
##   echo a, b  # output: {1: one, 2: two}{1: one, 2: two}
##
##   b[3] = "three"
##   echo a, b  # output: {1: one, 2: two}{1: one, 2: two, 3: three}
##   echo a == b  # output: false
##
##   a.deinitSharedTable()
##
## On the other hand, when `a` is a SharedTablePtr instead, then changes to `b` also affect `a`.
## Both `a` and `b` reference the same data structure:
##
## .. code-block::
##   import diktionary
##
##   var
##     a = {1: "one", 2: "two"}.newSharedTable  # creates a SharedTablePtr
##     b = a
##
##   echo a, b  # output: {1: one, 2: two}{1: one, 2: two}
##
##   b[3] = "three"
##   echo a, b  # output: {1: one, 2: two, 3: three}{1: one, 2: two, 3: three}
##   echo a == b  # output: true
##
##   a.deinitSharedTable()
##
##
## If you are using simple standard types like ``int`` for the
## keys of the table you won't have any problems, but as soon as you try to use
## a more complex object as a key you will be greeted by a strange compiler
## error::
##
##   Error: type mismatch: got (Person)
##   but expected one of:
##   hashes.hash(x: openarray[A]): Hash
##   hashes.hash(x: int): Hash
##   hashes.hash(x: float): Hash
##   …
##
## What is happening here is that the types used for table keys require to have
## a ``hash()`` proc which will convert them to a `Hash <hashes.html#Hash>`_
## value, and the compiler is listing all the hash functions it knows.
## Additionally there has to be a ``==`` operator that provides the same
## semantics as its corresponding ``hash`` proc.
##
## After you add ``hash`` and ``==`` for your custom type everything will work.
## Currently however ``hash`` for objects is not defined, whereas
## ``system.==`` for objects does exist and performs a "deep" comparison (every
## field is compared) which is usually what you want. So in the following
## example implementing only ``hash`` suffices:
##
## .. code-block::
##   type
##     Person = object
##       firstName, lastName: SharedText
##
##   proc hash(x: Person): Hash =
##     ## Piggyback on the already available SharedText hash proc.
##     ##
##     ## Without this proc nothing works!
##     result = x.firstName.hash !& x.lastName.hash
##     result = !$result
##
##   var
##     salaries = initSharedTable[Person, int]()
##     p1, p2: Person
##
##   p1.firstName = "Jon"
##   p1.lastName = "Ross"
##   salaries[p1] = 30_000
##
##   p2.firstName = "소진"
##   p2.lastName = "박"
##   salaries[p2] = 45_000

import
  hashes, math

import vektor

include "system/inclrtl"

type
  KeyValuePair[A: not (ref|seq|string), B: not (ref|seq|string)] = tuple[hcode: Hash, key: A, val: B]
  KeyValuePairSA[A, B] = SharedArray[KeyValuePair[A, B]]
  SharedTable*[A, B] = object ## generic hash table
    data: KeyValuePairSA[A, B]
    counter: int
  SharedTablePtr*[A,B] = ptr SharedTable[A, B]

template maxHash(t): untyped = high(t.data)
template dataLen(t): untyped = len(t.data)

#include tableimpl
## An ``include`` file for the different table implementations.

# hcode for real keys cannot be zero.  hcode==0 signifies an empty slot.  These
# two procs retain clarity of that encoding without the space cost of an enum.
proc isEmpty(hcode: Hash): bool {.inline.} =
  result = hcode == 0

proc isFilled(hcode: Hash): bool {.inline.} =
  result = hcode != 0

const
  growthFactor = 2

proc mustRehash(length, counter: int): bool {.inline.} =
  assert(length > counter)
  result = (length * 2 < counter * 3) or (length - counter < 4)

proc nextTry(h, maxHash: Hash): Hash {.inline.} =
  result = (h + 1) and maxHash

template rawGetKnownHCImpl() {.dirty.} =
  var h: Hash = hc and maxHash(t)   # start with real hash value
  while isFilled(t.data[h].hcode):
    # Compare hc THEN key with boolean short circuit. This makes the common case
    # zero ==key's for missing (e.g.inserts) and exactly one ==key for present.
    # It does slow down succeeding lookups by one extra Hash cmp&and..usually
    # just a few clock cycles, generally worth it for any non-integer-like A.
    if t.data[h].hcode == hc and t.data[h].key == key:
      return h
    h = nextTry(h, maxHash(t))
  result = -1 - h                   # < 0 => MISSING; insert idx = -1 - result

template genHashImpl(key, hc: typed) =
  hc = hash(key)
  if hc == 0:       # This almost never taken branch should be very predictable.
    hc = 314159265  # Value doesn't matter; Any non-zero favorite is fine.

template genHash(key: typed): Hash =
  var res: Hash
  genHashImpl(key, res)
  res

template rawGetImpl() {.dirty.} =
  genHashImpl(key, hc)
  rawGetKnownHCImpl()

template rawGetDeepImpl() {.dirty.} =   # Search algo for unconditional add
  genHashImpl(key, hc)
  var h: Hash = hc and maxHash(t)
  while isFilled(t.data[h].hcode):
    h = nextTry(h, maxHash(t))
  result = h

template rawInsertImpl() {.dirty.} =
  data[h].key = key
  data[h].val = val
  data[h].hcode = hc

proc rawGetKnownHC[X, A](t: X, key: A, hc: Hash): int {.inline.} =
  rawGetKnownHCImpl()

proc rawGetDeep[X, A](t: X, key: A, hc: var Hash): int {.inline.} =
  rawGetDeepImpl()

proc rawGet[X, A](t: X, key: A, hc: var Hash): int {.inline.} =
  rawGetImpl()

proc rawInsert[X, A, B](t: var X, data: var KeyValuePairSA[A, B],
                     key: A, val: B, hc: Hash, h: Hash) =
  rawInsertImpl()

template addImpl(enlarge) {.dirty.} =
  if mustRehash(t.dataLen, t.counter): enlarge(t)
  var hc: Hash
  var j = rawGetDeep(t, key, hc)
  rawInsert(t, t.data, key, val, hc, j)
  inc(t.counter)

template maybeRehashPutImpl(enlarge) {.dirty.} =
  if mustRehash(t.dataLen, t.counter):
    enlarge(t)
    index = rawGetKnownHC(t, key, hc)
  index = -1 - index                  # important to transform for mgetOrPutImpl
  rawInsert(t, t.data, key, val, hc, index)
  inc(t.counter)

template putImpl(enlarge) {.dirty.} =
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index >= 0: t.data[index].val = val
  else: maybeRehashPutImpl(enlarge)

template mgetOrPutImpl(enlarge) {.dirty.} =
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index < 0:
    # not present: insert (flipping index)
    maybeRehashPutImpl(enlarge)
  # either way return modifiable val
  result = t.data[index].val

template hasKeyOrPutImpl(enlarge) {.dirty.} =
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index < 0:
    result = false
    maybeRehashPutImpl(enlarge)
  else: result = true

template default[T](t: typedesc[T]): T =
  var v: T
  v

template delImplIdx(t, i) =
  let msk = maxHash(t)
  if i >= 0:
    dec(t.counter)
    block outer:
      while true:         # KnuthV3 Algo6.4R adapted for i=i+1 instead of i=i-1
        var j = i         # The correctness of this depends on (h+1) in nextTry,
        var r = j         # though may be adaptable to other simple sequences.
        t.data[i].hcode = 0              # mark current EMPTY
        t.data[i].key = default(type(t.data[i].key))
        t.data[i].val = default(type(t.data[i].val))
        while true:
          i = (i + 1) and msk            # increment mod table size
          if isEmpty(t.data[i].hcode):   # end of collision cluster; So all done
            break outer
          r = t.data[i].hcode and msk    # "home" location of key@i
          if not ((i >= r and r > j) or (r > j and j > i) or (j > i and i >= r)):
            break
        when defined(js):
          t.data[j] = t.data[i]
        else:
          shallowCopy(t.data[j], t.data[i]) # data[j] will be marked EMPTY next loop

template delImpl() {.dirty.} =
  var hc: Hash
  var i = rawGet(t, key, hc)
  delImplIdx(t, i)

template clearImpl() {.dirty.} =
  for i in 0 .. <t.data.len:
    when compiles(t.data[i].hcode): # SharedCountTable records don't contain a hcode
      t.data[i].hcode = 0
    t.data[i].key = default(type(t.data[i].key))
    t.data[i].val = default(type(t.data[i].val))
  t.counter = 0


proc clear*[A, B](t: var SharedTable[A, B]) =
  ## Resets the table so that it is empty.
  clearImpl()

proc clear*[A, B](t: SharedTablePtr[A, B]) =
  ## Resets the table so that it is empty.
  clearImpl()

proc rightSize*(count: Natural): int {.inline.} =
  ## Return the value of `initialSize` to support `count` items.
  ##
  ## If more items are expected to be added, simply add that
  ## expected extra amount to the parameter before calling this.
  ##
  ## Internally, we want mustRehash(rightSize(x), x) == false.
  result = nextPowerOfTwo(count * 3 div 2  +  4)

proc len*[A, B](t: SharedTable[A, B]): int =
  ## returns the number of keys in `t`.
  result = t.counter

template get(t, key): untyped =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  mixin rawGet
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index >= 0: result = t.data[index].val
  else:
    when compiles($key):
      raise newException(KeyError, "key not found: " & $key)
    else:
      raise newException(KeyError, "key not found")

template getOrDefaultImpl(t, key): untyped =
  mixin rawGet
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index >= 0: result = t.data[index].val

proc `[]`*[A, B](t: SharedTable[A, B], key: A): B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  get(t, key)

proc `[]`*[A, B](t: var SharedTable[A, B], key: A): var B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  get(t, key)

proc mget*[A, B](t: var SharedTable[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised. Use ```[]```
  ## instead.
  get(t, key)

proc getOrDefault*[A, B](t: SharedTable[A, B], key: A): B = getOrDefaultImpl(t, key)

template withValue*[A, B](t: var SharedTable[A, B], key: A,
                          value, body: untyped) =
  ## retrieves the value at ``t[key]``.
  ## `value` can be modified in the scope of the ``withValue`` call.
  ##
  ## .. code-block:: nim
  ##
  ##   sharedTable.withValue(key, value) do:
  ##     # block is executed only if ``key`` in ``t``
  ##     value.name = "username"
  ##     value.uid = 1000
  ##
  mixin rawGet
  var hc: Hash
  var index = rawGet(t, key, hc)
  let hasKey = index >= 0
  if hasKey:
    var value {.inject.} = addr(t.data[index].val)
    body

template withValue*[A, B](t: var SharedTable[A, B], key: A,
                          value, body1, body2: untyped) =
  ## retrieves the value at ``t[key]``.
  ## `value` can be modified in the scope of the ``withValue`` call.
  ##
  ## .. code-block:: nim
  ##
  ##   table.withValue(key, value) do:
  ##     # block is executed only if ``key`` in ``t``
  ##     value.name = "username"
  ##     value.uid = 1000
  ##   do:
  ##     # block is executed when ``key`` not in ``t``
  ##     raise newException(KeyError, "Key not found")
  ##
  mixin rawGet
  var hc: Hash
  var index = rawGet(t, key, hc)
  let hasKey = index >= 0
  if hasKey:
    var value {.inject.} = addr(t.data[index].val)
    body1
  else:
    body2

iterator allValues*[A, B](t: SharedTable[A, B]; key: A): B =
  ## iterates over any value in the table `t` that belongs to the given `key`.
  var h: Hash = genHash(key) and high(t.data)
  while isFilled(t.data[h].hcode):
    if t.data[h].key == key:
      yield t.data[h].val
    h = nextTry(h, high(t.data))

proc hasKey*[A, B](t: SharedTable[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  var hc: Hash
  result = rawGet(t, key, hc) >= 0

proc contains*[A, B](t: SharedTable[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

iterator pairs*[A, B](t: SharedTable[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: var SharedTable[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t`. The values
  ## can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: SharedTable[A, B]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].key

iterator values*[A, B](t: SharedTable[A, B]): B =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

iterator mvalues*[A, B](t: var SharedTable[A, B]): var B =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

proc del*[A, B](t: var SharedTable[A, B], key: A) =
  ## deletes `key` from hash table `t`.
  delImpl()

proc take*[A, B](t: var SharedTable[A, B], key: A, val: var B): bool =
  ## Deletes the ``key`` from the table.
  ## Returns ``true``, if the ``key`` existed, and sets ``val`` to the
  ## mapping of the key. Otherwise, returns ``false``, and the ``val`` is
  ## unchanged.
  var hc: Hash
  var index = rawGet(t, key, hc)
  result = index >= 0
  if result:
    shallowCopy(val, t.data[index].val)
    delImplIdx(t, index)

proc enlarge[A, B](t: var SharedTable[A, B]) =
  var n: KeyValuePairSA[A, B]
  n = initSharedArray[KeyValuePair[A, B]](len(t.data) * growthFactor)
  swap(t.data, n)
  for i in countup(0, high(n)):
    let eh = n[i].hcode
    if isFilled(eh):
      var j: Hash = eh and maxHash(t)
      while isFilled(t.data[j].hcode):
        j = nextTry(j, maxHash(t))
      rawInsert(t, t.data, n[i].key, n[i].val, eh, j)

proc mgetOrPut*[A, B](t: var SharedTable[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified.
  mgetOrPutImpl(enlarge)

proc hasKeyOrPut*[A, B](t: var SharedTable[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  hasKeyOrPutImpl(enlarge)

proc `[]=`*[A, B](t: var SharedTable[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  putImpl(enlarge)

proc add*[A, B](t: var SharedTable[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  addImpl(enlarge)

proc len*[A, B](t: SharedTablePtr[A, B]): int =
  ## returns the number of keys in `t`.
  result = t.counter

proc initSharedTable*[A, B](initialSize=64): SharedTable[A, B] =
  ## creates a new shared hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  result.data = initSharedArray[KeyValuePair[A, B]](initialSize)

proc deinitSharedTable*[A, B](st: var SharedTable[A, B]) =
  ## Destroys a shared hash table.
  st.counter = 0
  st.data.deinitSharedArray()

proc deinitSharedTable*[A, B](st: SharedTablePtr[A, B]) =
  ## Destroys a shared hash table.
  st.counter = 0
  st.data.deinitSharedArray()

proc toSharedTable*[A, B](pairs: openArray[(A,
                    B)]): SharedTable[A, B] =
  ## creates a new hash table that contains the given `pairs`.
  result = initSharedTable[A, B](rightSize(pairs.len))
  for key, val in items(pairs): result[key] = val

template dollarImpl(): untyped {.dirty.} =
  if t.len == 0:
    result = "{:}"
  else:
    result = "{"
    for key, val in pairs(t):
      if result.len > 1: result.add(", ")
      result.add($key)
      result.add(": ")
      result.add($val)
    result.add("}")

proc `$`*[A, B](t: SharedTable[A, B]): string =
  ## The `$` operator for hash tables.
  dollarImpl()

proc hasKey*[A, B](t: SharedTablePtr[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = t[].hasKey(key)

template equalsImpl(s, t: typed): typed =
  if s.counter == t.counter:
    # different insertion orders mean different 'data' seqs, so we have
    # to use the slow route here:
    for key, val in s:
      if not t.hasKey(key): return false
      if t.getOrDefault(key) != val: return false
    return true

proc `==`*[A, B](s, t: SharedTable[A, B]): bool =
  ## The `==` operator for hash tables. Returns ``true`` iff the content of both
  ## tables contains the same key-value pairs. Insert order does not matter.
  equalsImpl(s, t)

proc indexBy*[A, B, C](collection: A, index: proc(x: B): C): SharedTable[C, B] =
  ## Index the collection with the proc provided.
  # TODO: As soon as supported, change collection: A to collection: A[B]
  result = initSharedTable[C, B]()
  for item in collection:
    result[index(item)] = item

iterator pairs*[A, B](t: SharedTablePtr[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: SharedTablePtr[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t`. The values
  ## can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: SharedTablePtr[A, B]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].key

iterator values*[A, B](t: SharedTablePtr[A, B]): B =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

iterator mvalues*[A, B](t: SharedTablePtr[A, B]): var B =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

proc `[]`*[A, B](t: SharedTablePtr[A, B], key: A): var B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``.  If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  result = t[][key]

proc mget*[A, B](t: SharedTablePtr[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  t[][key]

proc getOrDefault*[A, B](t: SharedTablePtr[A, B], key: A): B = getOrDefault(t[], key)

proc mgetOrPut*[A, B](t: SharedTablePtr[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified.
  t[].mgetOrPut(key, val)

proc hasKeyOrPut*[A, B](t: var SharedTablePtr[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  t[].hasKeyOrPut(key, val)

proc contains*[A, B](t: SharedTablePtr[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

proc `[]=`*[A, B](t: SharedTablePtr[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  t[][key] = val

proc add*[A, B](t: SharedTablePtr[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  t[].add(key, val)

proc del*[A, B](t: SharedTablePtr[A, B], key: A) =
  ## deletes `key` from hash table `t`.
  t[].del(key)

proc take*[A, B](t: SharedTablePtr[A, B], key: A, val: var B): bool =
  ## Deletes the ``key`` from the table.
  ## Returns ``true``, if the ``key`` existed, and sets ``val`` to the
  ## mapping of the key. Otherwise, returns ``false``, and the ``val`` is
  ## unchanged.
  result = t[].take(key, val)

proc `$`*[A, B](t: SharedTablePtr[A, B]): string =
  ## The `$` operator for hash tables.
  dollarImpl()

proc `==`*[A, B](s, t: SharedTablePtr[A, B]): bool =
  ## The `==` operator for hash tables. Returns ``true`` iff either both tables
  ## are ``nil`` or none is ``nil`` and the content of both tables contains the
  ## same key-value pairs. Insert order does not matter.
  if isNil(s): result = isNil(t)
  elif isNil(t): result = false
  else: equalsImpl(s[], t[])

proc newSharedTable*[A, B](initialSize=64): SharedTablePtr[A, B] =
  result = createShared(SharedTable[A, B])
  result[] = initSharedTable[A, B](initialSize)

proc newSharedTable*[A, B](pairs: openArray[(A, B)]): SharedTablePtr[A, B] =
  ## creates a new hash table that contains the given `pairs`.
  result = createShared(SharedTable[A, B])
  result[] = toSharedTable[A, B](pairs)

proc newSharedTableFrom*[A, B, C](collection: A, index: proc(x: B): C): SharedTablePtr[C, B] =
  ## Index the collection with the proc provided.
  # TODO: As soon as supported, change collection: A to collection: A[B]
  result = newSharedTable[C, B]()
  for item in collection:
    result[index(item)] = item

# ------------------------------ ordered table ------------------------------

type
  OrderedKeyValuePair[A: not (ref|seq|string), B: not (ref|seq|string)] = tuple[
    hcode: Hash, next: int, key: A, val: B]
  OrderedKeyValuePairSA[A, B] = SharedArray[OrderedKeyValuePair[A, B]]
  SharedOrderedTable* [A, B] = object ## table that remembers insertion order
    data: OrderedKeyValuePairSA[A, B]
    counter, first, last: int
  SharedOrderedTablePtr*[A, B] = ptr SharedOrderedTable[A, B]

proc len*[A, B](t: SharedOrderedTable[A, B]): int {.inline.} =
  ## returns the number of keys in `t`.
  result = t.counter

proc clear*[A, B](t: var SharedOrderedTable[A, B]) =
  ## Resets the table so that it is empty.
  clearImpl()
  t.first = -1
  t.last = -1

proc clear*[A, B](t: var SharedOrderedTablePtr[A, B]) =
  ## Resets the table so that is is empty.
  clear(t[])

template forAllOrderedPairs(yieldStmt: untyped): typed {.dirty.} =
  var h = t.first
  while h >= 0:
    var nxt = t.data[h].next
    if isFilled(t.data[h].hcode): yieldStmt
    h = nxt

iterator pairs*[A, B](t: SharedOrderedTable[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: var SharedOrderedTable[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order. The values can be modified.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: SharedOrderedTable[A, B]): A =
  ## iterates over any key in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].key

iterator values*[A, B](t: SharedOrderedTable[A, B]): B =
  ## iterates over any value in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].val

iterator mvalues*[A, B](t: var SharedOrderedTable[A, B]): var B =
  ## iterates over any value in the table `t` in insertion order. The values
  ## can be modified.
  forAllOrderedPairs:
    yield t.data[h].val

proc rawGetKnownHC[A, B](t: SharedOrderedTable[A, B], key: A, hc: Hash): int =
  rawGetKnownHCImpl()

proc rawGetDeep[A, B](t: SharedOrderedTable[A, B], key: A, hc: var Hash): int {.inline.} =
  rawGetDeepImpl()

proc rawGet[A, B](t: SharedOrderedTable[A, B], key: A, hc: var Hash): int =
  rawGetImpl()

proc `[]`*[A, B](t: SharedOrderedTable[A, B], key: A): B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  get(t, key)

proc `[]`*[A, B](t: var SharedOrderedTable[A, B], key: A): var B{.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  get(t, key)

proc mget*[A, B](t: var SharedOrderedTable[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  get(t, key)

proc getOrDefault*[A, B](t: SharedOrderedTable[A, B], key: A): B =
  getOrDefaultImpl(t, key)


proc hasKey*[A, B](t: SharedOrderedTable[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  var hc: Hash
  result = rawGet(t, key, hc) >= 0

proc contains*[A, B](t: SharedOrderedTable[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

proc rawInsert[A, B](t: var SharedOrderedTable[A, B],
                     data: var OrderedKeyValuePairSA[A, B],
                     key: A, val: B, hc: Hash, h: Hash) =
  rawInsertImpl()
  data[h].next = -1
  if t.first < 0: t.first = h
  if t.last >= 0: data[t.last].next = h
  t.last = h

proc enlarge[A, B](t: var SharedOrderedTable[A, B]) =
  var n: OrderedKeyValuePairSA[A, B]
  n = initSharedArray[OrderedKeyValuePair[A, B]](len(t.data) * growthFactor)
  var h = t.first
  t.first = -1
  t.last = -1
  swap(t.data, n)
  while h >= 0:
    var nxt = n[h].next
    let eh = n[h].hcode
    if isFilled(eh):
      var j: Hash = eh and maxHash(t)
      while isFilled(t.data[j].hcode):
        j = nextTry(j, maxHash(t))
      rawInsert(t, t.data, n[h].key, n[h].val, n[h].hcode, j)
    h = nxt

proc `[]=`*[A, B](t: var SharedOrderedTable[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  putImpl(enlarge)

proc add*[A, B](t: var SharedOrderedTable[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  addImpl(enlarge)

proc mgetOrPut*[A, B](t: var SharedOrderedTable[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``value`` if not present, either way
  ## returning a value which can be modified.
  mgetOrPutImpl(enlarge)

proc hasKeyOrPut*[A, B](t: var SharedOrderedTable[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  hasKeyOrPutImpl(enlarge)

proc initSharedOrderedTable*[A, B](initialSize=64): SharedOrderedTable[A, B] =
  ## creates a new shared ordered hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  result.first = -1
  result.last = -1
  result.data = initSharedArray[OrderedKeyValuePair[A, B]](initialSize)

proc deinitSharedOrderedTable*[A, B](st: var SharedOrderedTable[A, B]) =
  ## Destroys a shared ordered hash table.
  st.counter = 0
  st.first = -1
  st.last = -1
  st.data.deinitSharedArray()

proc deinitSharedOrderedTable*[A, B](st: SharedOrderedTablePtr[A, B]) =
  ## Destroys a shared ordered hash table.
  st.counter = 0
  st.first = -1
  st.last = -1
  st.data.deinitSharedArray()

proc toSharedOrderedTable*[A, B](pairs: openArray[(A,
                           B)]): SharedOrderedTable[A, B] =
  ## creates a new ordered hash table that contains the given `pairs`.
  result = initSharedOrderedTable[A, B](rightSize(pairs.len))
  for key, val in items(pairs): result[key] = val

proc `$`*[A, B](t: SharedOrderedTable[A, B]): string =
  ## The `$` operator for ordered hash tables.
  dollarImpl()

proc `==`*[A, B](s, t: SharedOrderedTable[A, B]): bool =
  ## The `==` operator for ordered hash tables. Returns true iff both the
  ## content and the order are equal.
  if s.counter != t.counter:
    return false
  var ht = t.first
  var hs = s.first
  while ht >= 0 and hs >= 0:
    var nxtt = t.data[ht].next
    var nxts = s.data[hs].next
    if isFilled(t.data[ht].hcode) and isFilled(s.data[hs].hcode):
      if (s.data[hs].key != t.data[ht].key) or (s.data[hs].val != t.data[ht].val):
        return false
    ht = nxtt
    hs = nxts
  return true

proc sort*[A, B](t: var SharedOrderedTable[A, B],
                 cmp: proc (x,y: (A, B)): int) =
  ## sorts `t` according to `cmp`. This modifies the internal list
  ## that kept the insertion order, so insertion order is lost after this
  ## call but key lookup and insertions remain possible after `sort` (in
  ## contrast to the `sort` for count tables).
  var list = t.first
  var
    p, q, e, tail, oldhead: int
    nmerges, psize, qsize, i: int
  if t.counter == 0: return
  var insize = 1
  while true:
    p = list; oldhead = list
    list = -1; tail = -1; nmerges = 0
    while p >= 0:
      inc(nmerges)
      q = p
      psize = 0
      i = 0
      while i < insize:
        inc(psize)
        q = t.data[q].next
        if q < 0: break
        inc(i)
      qsize = insize
      while psize > 0 or (qsize > 0 and q >= 0):
        if psize == 0:
          e = q; q = t.data[q].next; dec(qsize)
        elif qsize == 0 or q < 0:
          e = p; p = t.data[p].next; dec(psize)
        elif cmp((t.data[p].key, t.data[p].val),
                 (t.data[q].key, t.data[q].val)) <= 0:
          e = p; p = t.data[p].next; dec(psize)
        else:
          e = q; q = t.data[q].next; dec(qsize)
        if tail >= 0: t.data[tail].next = e
        else: list = e
        tail = e
      p = q
    t.data[tail].next = -1
    if nmerges <= 1: break
    insize = insize * 2
  t.first = list
  t.last = tail

proc len*[A, B](t: SharedOrderedTablePtr[A, B]): int {.inline.} =
  ## returns the number of keys in `t`.
  result = t.counter

iterator pairs*[A, B](t: SharedOrderedTablePtr[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: SharedOrderedTablePtr[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order. The values can be modified.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: SharedOrderedTablePtr[A, B]): A =
  ## iterates over any key in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].key

iterator values*[A, B](t: SharedOrderedTablePtr[A, B]): B =
  ## iterates over any value in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].val

iterator mvalues*[A, B](t: SharedOrderedTablePtr[A, B]): var B =
  ## iterates over any value in the table `t` in insertion order. The values
  ## can be modified.
  forAllOrderedPairs:
    yield t.data[h].val

proc `[]`*[A, B](t: SharedOrderedTablePtr[A, B], key: A): var B =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  result = t[][key]

proc mget*[A, B](t: SharedOrderedTablePtr[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  result = t[][key]

proc getOrDefault*[A, B](t: SharedOrderedTablePtr[A, B], key: A): B =
  getOrDefault(t[], key)

proc mgetOrPut*[A, B](t: SharedOrderedTablePtr[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified.
  result = t[].mgetOrPut(key, val)

proc hasKeyOrPut*[A, B](t: var SharedOrderedTablePtr[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `val`.
  result = t[].hasKeyOrPut(key, val)

proc hasKey*[A, B](t: SharedOrderedTablePtr[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = t[].hasKey(key)

proc contains*[A, B](t: SharedOrderedTablePtr[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

proc `[]=`*[A, B](t: SharedOrderedTablePtr[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  t[][key] = val

proc add*[A, B](t: SharedOrderedTablePtr[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  t[].add(key, val)

proc newSharedOrderedTable*[A, B](initialSize=64): SharedOrderedTablePtr[A, B] =
  ## creates a new ordered hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  result = createShared(SharedOrderedTable[A, B])
  result[] = initSharedOrderedTable[A, B](initialSize)

proc newSharedOrderedTable*[A, B](pairs: openArray[(A, B)]): SharedOrderedTablePtr[A, B] =
  ## creates a new ordered hash table that contains the given `pairs`.
  result = newSharedOrderedTable[A, B](rightSize(pairs.len))
  for key, val in items(pairs): result.add(key, val)

proc `$`*[A, B](t: SharedOrderedTablePtr[A, B]): string =
  ## The `$` operator for ordered hash tables.
  dollarImpl()

proc `==`*[A, B](s, t: SharedOrderedTablePtr[A, B]): bool =
  ## The `==` operator for ordered hash tables. Returns true iff either both
  ## tables are ``nil`` or none is ``nil`` and the content and the order of
  ## both are equal.
  if isNil(s): result = isNil(t)
  elif isNil(t): result = false
  else: result = s[] == t[]

proc sort*[A, B](t: SharedOrderedTablePtr[A, B],
                 cmp: proc (x,y: (A, B)): int) =
  ## sorts `t` according to `cmp`. This modifies the internal list
  ## that kept the insertion order, so insertion order is lost after this
  ## call but key lookup and insertions remain possible after `sort` (in
  ## contrast to the `sort` for count tables).
  t[].sort(cmp)

proc del*[A, B](t: var SharedOrderedTable[A, B], key: A) =
  ## deletes `key` from ordered hash table `t`. O(n) complexity.
  var n: OrderedKeyValuePairSA[A, B]
  n = initSharedArray[OrderedKeyValuePair[A, B]](len(t.data))
  var h = t.first
  t.first = -1
  t.last = -1
  swap(t.data, n)
  let hc = genHash(key)
  while h >= 0:
    var nxt = n[h].next
    if isFilled(n[h].hcode):
      if n[h].hcode == hc and n[h].key == key:
        dec t.counter
      else:
        var j = -1 - rawGetKnownHC(t, n[h].key, n[h].hcode)
        rawInsert(t, t.data, n[h].key, n[h].val, n[h].hcode, j)
    h = nxt

proc del*[A, B](t: var SharedOrderedTablePtr[A, B], key: A) =
  ## deletes `key` from ordered hash table `t`. O(n) complexity.
  t[].del(key)

# ------------------------------ count tables -------------------------------

type
  SharedCountTable* [
      A: not (ref|seq|string)] = object ## table that counts the number of each key
    data: SharedArray[tuple[key: A, val: int]]
    counter: int
  SharedCountTablePtr*[A] = ptr SharedCountTable[A]

proc len*[A](t: SharedCountTable[A]): int =
  ## returns the number of keys in `t`.
  result = t.counter

proc clear*[A](t: SharedCountTablePtr[A]) =
  ## Resets the table so that it is empty.
  clearImpl()

proc clear*[A](t: var SharedCountTable[A]) =
  ## Resets the table so that it is empty.
  clearImpl()

iterator pairs*[A](t: SharedCountTable[A]): (A, int) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A](t: var SharedCountTable[A]): (A, var int) =
  ## iterates over any (key, value) pair in the table `t`. The values can
  ## be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator keys*[A](t: SharedCountTable[A]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].key

iterator values*[A](t: SharedCountTable[A]): int =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

iterator mvalues*[A](t: SharedCountTable[A]): var int =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

proc rawGet[A](t: SharedCountTable[A], key: A): int =
  var h: Hash = hash(key) and high(t.data) # start with real hash value
  while t.data[h].val != 0:
    if t.data[h].key == key: return h
    h = nextTry(h, high(t.data))
  result = -1 - h                   # < 0 => MISSING; insert idx = -1 - result

template ctget(t, key: untyped): untyped =
  var index = rawGet(t, key)
  if index >= 0: result = t.data[index].val
  else:
    when compiles($key):
      raise newException(KeyError, "key not found: " & $key)
    else:
      raise newException(KeyError, "key not found")

proc `[]`*[A](t: SharedCountTable[A], key: A): int {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`,
  ## the ``KeyError`` exception is raised. One can check with ``hasKey``
  ## whether the key exists.
  ctget(t, key)

proc `[]`*[A](t: var SharedCountTable[A], key: A): var int {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ctget(t, key)

proc mget*[A](t: var SharedCountTable[A], key: A): var int {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  ctget(t, key)

proc getOrDefault*[A](t: SharedCountTable[A], key: A): int =
  var index = rawGet(t, key)
  if index >= 0: result = t.data[index].val

proc hasKey*[A](t: SharedCountTable[A], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = rawGet(t, key) >= 0

proc contains*[A](t: SharedCountTable[A], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A](t, key)

proc rawInsert[A](t: SharedCountTable[A], data: var SharedArray[tuple[key: A, val: int]],
                  key: A, val: int) =
  var h: Hash = hash(key) and high(data)
  while data[h].val != 0: h = nextTry(h, high(data))
  data[h].key = key
  data[h].val = val

proc enlarge[A](t: var SharedCountTable[A]) =
  var n: SharedArray[tuple[key: A, val: int]]
  n = initSharedArray[tuple[key: A, val: int]](len(t.data) * growthFactor)
  for i in countup(0, high(t.data)):
    if t.data[i].val != 0: rawInsert(t, n, t.data[i].key, t.data[i].val)
  swap(t.data, n)

proc `[]=`*[A](t: var SharedCountTable[A], key: A, val: int) =
  ## puts a (key, value)-pair into `t`.
  assert val >= 0
  var h = rawGet(t, key)
  if h >= 0:
    t.data[h].val = val
  else:
    if mustRehash(len(t.data), t.counter): enlarge(t)
    rawInsert(t, t.data, key, val)
    inc(t.counter)
    #h = -1 - h
    #t.data[h].key = key
    #t.data[h].val = val

proc initSharedCountTable*[A](initialSize=64): SharedCountTable[A] =
  ## creates a new count table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc in this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  result.data = initSharedArray[tuple[key: A, val: int]](initialSize)

proc deinitSharedCountTable*[A](st: var SharedCountTable[A]) =
  ## Destroys a shared count hash table.
  st.counter = 0
  st.data.deinitSharedArray()

proc deinitSharedCountTable*[A](st: SharedCountTablePtr[A]) =
  ## Destroys a shared count hash table.
  st.counter = 0
  st.data.deinitSharedArray()

proc toSharedCountTable*[A](keys: openArray[A]): SharedCountTable[A] =
  ## creates a new count table with every key in `keys` having a count of 1.
  result = initSharedCountTable[A](rightSize(keys.len))
  for key in items(keys): result[key] = 1

proc `$`*[A](t: SharedCountTable[A]): string =
  ## The `$` operator for count tables.
  dollarImpl()

proc `==`*[A](s, t: SharedCountTable[A]): bool =
  ## The `==` operator for count tables. Returns ``true`` iff both tables
  ## contain the same keys with the same count. Insert order does not matter.
  equalsImpl(s, t)

proc inc*[A](t: var SharedCountTable[A], key: A, val = 1) =
  ## increments `t[key]` by `val`.
  var index = rawGet(t, key)
  if index >= 0:
    inc(t.data[index].val, val)
    if t.data[index].val == 0: dec(t.counter)
  else:
    if mustRehash(len(t.data), t.counter): enlarge(t)
    rawInsert(t, t.data, key, val)
    inc(t.counter)

proc smallest*[A](t: SharedCountTable[A]): tuple[key: A, val: int] =
  ## returns the (key,val)-pair with the smallest `val`. Efficiency: O(n)
  assert t.len > 0
  var minIdx = 0
  for h in 1..high(t.data):
    if t.data[h].val > 0 and t.data[minIdx].val > t.data[h].val: minIdx = h
  result.key = t.data[minIdx].key
  result.val = t.data[minIdx].val

proc largest*[A](t: SharedCountTable[A]): tuple[key: A, val: int] =
  ## returns the (key,val)-pair with the largest `val`. Efficiency: O(n)
  assert t.len > 0
  var maxIdx = 0
  for h in 1..high(t.data):
    if t.data[maxIdx].val < t.data[h].val: maxIdx = h
  result.key = t.data[maxIdx].key
  result.val = t.data[maxIdx].val

proc sort*[A](t: var SharedCountTable[A]) =
  ## sorts the count table so that the entry with the highest counter comes
  ## first. This is destructive! You must not modify `t` afterwards!
  ## You can use the iterators `pairs`,  `keys`, and `values` to iterate over
  ## `t` in the sorted order.

  # we use shellsort here; fast enough and simple
  var h = 1
  while true:
    h = 3 * h + 1
    if h >= high(t.data): break
  while true:
    h = h div 3
    for i in countup(h, high(t.data)):
      var j = i
      while t.data[j-h].val <= t.data[j].val:
        swap(t.data[j], t.data[j-h])
        j = j-h
        if j < h: break
    if h == 1: break

proc len*[A](t: SharedCountTablePtr[A]): int =
  ## returns the number of keys in `t`.
  result = t.counter

iterator pairs*[A](t: SharedCountTablePtr[A]): (A, int) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A](t: SharedCountTablePtr[A]): (A, var int) =
  ## iterates over any (key, value) pair in the table `t`. The values can
  ## be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator keys*[A](t: SharedCountTablePtr[A]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].key

iterator values*[A](t: SharedCountTablePtr[A]): int =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

iterator mvalues*[A](t: SharedCountTablePtr[A]): var int =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

proc `[]`*[A](t: SharedCountTablePtr[A], key: A): var int {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  result = t[][key]

proc mget*[A](t: SharedCountTablePtr[A], key: A): var int {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  result = t[][key]

proc getOrDefault*[A](t: SharedCountTablePtr[A], key: A): int =
  result = t[].getOrDefault(key)

proc hasKey*[A](t: SharedCountTablePtr[A], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = t[].hasKey(key)

proc contains*[A](t: SharedCountTablePtr[A], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A](t, key)

proc `[]=`*[A](t: SharedCountTablePtr[A], key: A, val: int) =
  ## puts a (key, value)-pair into `t`. `val` has to be positive.
  assert val > 0
  t[][key] = val

proc newSharedCountTable*[A](initialSize=64): SharedCountTablePtr[A] =
  ## creates a new count table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` method in this module.
  result = createShared(SharedCountTable[A])
  result[] = initSharedCountTable[A](initialSize)

proc newSharedCountTable*[A](keys: openArray[A]): SharedCountTablePtr[A] =
  ## creates a new count table with every key in `keys` having a count of 1.
  result = newSharedCountTable[A](rightSize(keys.len))
  for key in items(keys): result[key] = 1

proc `$`*[A](t: SharedCountTablePtr[A]): string =
  ## The `$` operator for count tables.
  dollarImpl()

proc `==`*[A](s, t: SharedCountTablePtr[A]): bool =
  ## The `==` operator for count tables. Returns ``true`` iff either both tables
  ## are ``nil`` or none is ``nil`` and both contain the same keys with the same
  ## count. Insert order does not matter.
  if isNil(s): result = isNil(t)
  elif isNil(t): result = false
  else: result = s[] == t[]

proc inc*[A](t: SharedCountTablePtr[A], key: A, val = 1) =
  ## increments `t[key]` by `val`.
  t[].inc(key, val)

proc smallest*[A](t: SharedCountTablePtr[A]): (A, int) =
  ## returns the (key,val)-pair with the smallest `val`. Efficiency: O(n)
  t[].smallest

proc largest*[A](t: SharedCountTablePtr[A]): (A, int) =
  ## returns the (key,val)-pair with the largest `val`. Efficiency: O(n)
  t[].largest

proc sort*[A](t: SharedCountTablePtr[A]) =
  ## sorts the count table so that the entry with the highest counter comes
  ## first. This is destructive! You must not modify `t` afterwards!
  ## You can use the iterators `pairs`,  `keys`, and `values` to iterate over
  ## `t` in the sorted order.
  t[].sort

proc merge*[A](s: var SharedCountTable[A], t: SharedCountTable[A]) =
  ## merges the second table into the first one
  for key, value in t:
    s.inc(key, value)

proc merge*[A](s, t: SharedCountTable[A]): SharedCountTable[A] =
  ## merges the two tables into a new one
  result = initSharedCountTable[A](nextPowerOfTwo(max(s.len, t.len)))
  for table in @[s, t]:
    for key, value in table:
      result.inc(key, value)

proc merge*[A](s, t: SharedCountTablePtr[A]) =
  ## merges the second table into the first one
  s[].merge(t[])


when isMainModule:
  echo("TESTING SharedTable ...")
  # The original tests are based on "string"s, but we cannot use that, since cannot be used in the shared heap.
  type
    STRING = object
      mystr: cstring
      myhash: Hash

  proc copyCString(s: cstring): cstring =
    let len = s.len
    result = cast[cstring](allocShared(len+1))
    copyMem(cast[pointer](result), cast[pointer](s), len+1)

  proc S(s: string): STRING =
    result.mystr = copyCString(s)
    result.myhash = s.hash

  converter toString(s: STRING): string =
    result = $s.mystr

  proc hash(s: STRING): Hash =
    result = s.myhash

  proc `$`(s: STRING): string {.inline.} =
    result = $s.mystr

  proc `==`(a, b: STRING): bool =
    (a.myhash == b.myhash) and (cmp(a.mystr, b.mystr) == 0)

  type
    Person = object
      firstName, lastName: STRING

  proc hash(x: Person): Hash =
    ## Piggyback on the already available string hash proc.
    ##
    ## Without this proc nothing works!
    result = x.firstName.hash !& x.lastName.hash
    result = !$result

  var
    salaries = initSharedTable[Person, int]()
    p1, p2: Person
  p1.firstName = S("Jon")
  p1.lastName = S("Ross")
  salaries[p1] = 30_000
  p2.firstName = S("소진")
  p2.lastName = S("박")
  salaries[p2] = 45_000
  salaries.deinitSharedTable()
  var
    s2 = initSharedOrderedTable[Person, int]()
    s3 = initSharedCountTable[Person]()
  s2[p1] = 30_000
  s2[p2] = 45_000
  s3[p1] = 30_000
  s3[p2] = 45_000
  s2.deinitSharedOrderedTable()
  s3.deinitSharedCountTable()

  block: # Ordered table should preserve order after deletion
    var
      s4 = initSharedOrderedTable[int, int]()
    s4[1] = 1
    s4[2] = 2
    s4[3] = 3

    var prev = 0
    for i in s4.values:
      doAssert(prev < i)
      prev = i

    s4.del(2)
    doAssert(2 notin s4)
    doAssert(s4.len == 2)
    prev = 0
    for i in s4.values:
      doAssert(prev < i)
      prev = i
    s4.deinitSharedOrderedTable()

  block: # Deletion from SharedOrderedTable should account for collision groups. See issue #5057.
    # The bug is reproducible only with exact keys
    let key1 = S("boy_jackpot.inGamma")
    let key2 = S("boy_jackpot.outBlack")

    var t = {
        key1: 0,
        key2: 0
    }.toSharedOrderedTable()

    t.del(key1)
    assert(t.len == 1)
    assert(key2 in t)
    t.deinitSharedOrderedTable()

  var
    t1 = initSharedCountTable[STRING]()
    t2 = initSharedCountTable[STRING]()
  t1.inc(S("foo"))
  t1.inc(S("bar"), 2)
  t1.inc(S("baz"), 3)
  t2.inc(S("foo"), 4)
  t2.inc(S("bar"))
  t2.inc(S("baz"), 11)
  merge(t1, t2)
  assert(t1[S("foo")] == 5)
  assert(t1[S("bar")] == 3)
  assert(t1[S("baz")] == 14)
  t1.deinitSharedCountTable()
  t2.deinitSharedCountTable()

  let
    t1r = newSharedCountTable[STRING]()
    t2r = newSharedCountTable[STRING]()
  t1r.inc(S("foo"))
  t1r.inc(S("bar"), 2)
  t1r.inc(S("baz"), 3)
  t2r.inc(S("foo"), 4)
  t2r.inc(S("bar"))
  t2r.inc(S("baz"), 11)
  merge(t1r, t2r)
  assert(t1r[S("foo")] == 5)
  assert(t1r[S("bar")] == 3)
  assert(t1r[S("baz")] == 14)
  t1r.deinitSharedCountTable()
  t2r.deinitSharedCountTable()

  var
    t1l = initSharedCountTable[STRING]()
    t2l = initSharedCountTable[STRING]()
  t1l.inc(S("foo"))
  t1l.inc(S("bar"), 2)
  t1l.inc(S("baz"), 3)
  t2l.inc(S("foo"), 4)
  t2l.inc(S("bar"))
  t2l.inc(S("baz"), 11)
  let
    t1merging = t1l
    t2merging = t2l
  let merged = merge(t1merging, t2merging)
  assert(merged[S("foo")] == 5)
  assert(merged[S("bar")] == 3)
  assert(merged[S("baz")] == 14)
  t1l.deinitSharedCountTable()
  t1l.deinitSharedCountTable()

  block:
    let testKey = S("TESTKEY")
    let t: SharedCountTablePtr[STRING] = newSharedCountTable[STRING]()

    # Before, does not compile with error message:
    #test_counttable.nim(7, 43) template/generic instantiation from here
    #lib/pure/collections/tables.nim(117, 21) template/generic instantiation from here
    #lib/pure/collections/tableimpl.nim(32, 27) Error: undeclared field: 'hcode
    doAssert 0 == t.getOrDefault(testKey)
    t.inc(testKey,3)
    doAssert 3 == t.getOrDefault(testKey)
    t.deinitSharedCountTable()

  block:
    # Clear tests
    var clearTable = newSharedTable[int, STRING]()
    clearTable[42] = S("asd")
    clearTable[123123] = S("piuyqwb ")
    doAssert clearTable[42] == S("asd")
    clearTable.clear()
    doAssert(not clearTable.hasKey(123123))
    doAssert clearTable.getOrDefault(42) == nil
    clearTable.deinitSharedTable()

  block: #5482
    var a = [(S("wrong?"),S("foo")), (S("wrong?"), S("foo2"))].newSharedOrderedTable()
    var b = newSharedOrderedTable[STRING, STRING](initialSize=2)
    b.add(S("wrong?"), S("foo"))
    b.add(S("wrong?"), S("foo2"))
    assert a == b
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()

  block: #5482
    var a = {S("wrong?"): S("foo"), S("wrong?"): S("foo2")}.newSharedOrderedTable()
    var b = newSharedOrderedTable[STRING, STRING](initialSize=2)
    b.add(S("wrong?"), S("foo"))
    b.add(S("wrong?"), S("foo2"))
    assert a == b
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()

  block: #5487
    var a = {S("wrong?"): S("foo"), S("wrong?"): S("foo2")}.newSharedOrderedTable()
    var b = newSharedOrderedTable[STRING, STRING]() # notice, default size!
    b.add(S("wrong?"), S("foo"))
    b.add(S("wrong?"), S("foo2"))
    assert a == b
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()

  block: #5487
    var a = [(S("wrong?"),S("foo")), (S("wrong?"), S("foo2"))].newSharedOrderedTable()
    var b = newSharedOrderedTable[STRING, STRING]()  # notice, default size!
    b.add(S("wrong?"), S("foo"))
    b.add(S("wrong?"), S("foo2"))
    assert a == b
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()

  block:
    var a = {S("wrong?"): S("foo"), S("wrong?"): S("foo2")}.newSharedOrderedTable()
    var b = [(S("wrong?"),S("foo")), (S("wrong?"), S("foo2"))].newSharedOrderedTable()
    var c = newSharedOrderedTable[STRING, STRING]() # notice, default size!
    c.add(S("wrong?"), S("foo"))
    c.add(S("wrong?"), S("foo2"))
    assert a == b
    assert a == c
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()
    c.deinitSharedOrderedTable()


  block: #6250
    var
      a = {3: 1}.toSharedOrderedTable
      b = {3: 2}.toSharedOrderedTable
    assert((a == b) == false)
    assert((b == a) == false)
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()

  block: #6250
    var
      a = {3: 2}.toSharedOrderedTable
      b = {3: 2}.toSharedOrderedTable
    assert((a == b) == true)
    assert((b == a) == true)
    a.deinitSharedOrderedTable()
    b.deinitSharedOrderedTable()

