# Copyright 2017 Sebastien Diot.

## This module should be used as a replacement for "seq" on the shared heap.
## It tries to support the same API, but currently throws exceptions on bad index,
## instead of using assert.

import math

import moduleinit

type
  # TODO Find a way to make the type restriction be recursive
  SharedArray*[T: not (ref|seq|string)] = ptr object
    ## Simple variable-length shared-heap array, with a pre-allocated capacity.
    ## Particularly useful because still compatible with open-array.
    ## It is *not* guarded by a lock, and therefore not thread-safe by default.
    ## This is *by design*, as most concurent code needs "higher-level transactions"
    ## than "get/set" in a list.
    ## WARNING: Do not put any ref-based data in it, or *bad things* will happen;
    ## this is *not* checked automatically.
    size: int
      ## "first int" size, so we are compatible with openarray.
    mycapacity: int
      ## "second int" is required for seq-to-openarray compatibility, and used as "capacity" in our case.
    data: UncheckedArray[T]
      ## The data itself

when NimVersion >= "0.17.3":
  # Need to deal with BackwardsIndex and multi-type slice introduced by:
  # https://github.com/nim-lang/Nim/commit/d52a1061b35bbd2abfbd062b08023d986dbafb3c

  type Index = SomeSignedInt or BackwardsIndex
  template `^^`(s, i: untyped): untyped =
    when i is BackwardsIndex:
      s.len - int(i)
    else: int(i)
else:
  type Index = SomeSignedInt
  template `^^`(s, i: untyped): untyped =
    i

  proc `^`*[T](x: SomeSignedInt; a: SharedArray[T]): int {.inline.} =
    a.len - x


proc len*[T](list: SharedArray[T]): int {.inline, noSideEffect.} =
  ## Returns the current length/size of the shared array. 0 if nil.
  if list != nil:
    list.size
  else:
    0

proc low*[T](list: SharedArray[T]): int {.inline, noSideEffect.} =
  0

proc high*[T](list: SharedArray[T]): int {.inline, noSideEffect.} =
  ## Returns the current highest valid index of the shared array. -1 if nil.
  if list != nil:
    list.size - 1
  else:
    -1

proc isNilOrEmpty*[T](list: SharedArray[T]): bool {.inline, noSideEffect.} =
  ## Returns true if the current length/size of the shared array is 0 or if it is nil.
  (list == nil) or (list.size == 0)

proc clear*[T](list: var SharedArray[T]): void {.inline, noSideEffect.} =
  ## Sets the current length/size of the shared array to 0.
  if list != nil:
    list.size = 0

proc capacity*[T](list: SharedArray[T]): int {.inline, noSideEffect.} =
  ## Returns the fixed capacity of the shared array. 0 if nil.
  if list != nil:
    list.mycapacity
  else:
    0

iterator items*[T](list: SharedArray[T]): T {.inline, noSideEffect.} =
  ## Iterates over all array items. list cannot be nil.
  if list != nil:
    for i in 0..<list.size:
      yield list.data[i]

iterator mitems*[T](list: SharedArray[T]): var T {.inline, noSideEffect.} =
  ## Iterates over all array items. list cannot be nil.
  if list != nil:
    for i in 0..<list.size:
      yield list.data[i]

iterator pairs*[T](list: SharedArray[T]): (int, T) {.inline, noSideEffect.} =
  ## Iterates over all array items, and return the index together with them. list cannot be nil.
  if list != nil:
    for i in 0..<list.size:
      yield (i,list.data[i])

proc initSharedArray*[T](size: int = 64): SharedArray[T] {.inline.} =
  ## Returns a new shared-heap array with a given maximum size, which must be power-of-two.
  assert(size >= 0, "size cannot be negative: " & $size)
  let cap = nextPowerOfTwo(size)
  result = cast[SharedArray[T]](allocShared0(2*sizeof(int)+cap*sizeof(T)))
  # result.size is implicitely 0
  result.mycapacity = cap
  result.size = size

proc deinitSharedArray*[T](list: var SharedArray[T]): void {.inline.} =
  ## Destroys shared-heap array, if not nil.
  if list != nil:
    deallocShared list
    list = nil

template checkIndex[T](list: SharedArray[T]; idx: Index): void =
  ## Validate an index to an existing item.
  assert(list != nil)
  assert((idx >= 0) and (idx < list.size), "bad index: " & $idx & " must be in [0, " & $list.size & "[")

proc `[]`*[T](list: SharedArray[T]; idx: Index): var T {.inline, noSideEffect.} =
  ## Gets an array item.
  let idx2 = list ^^ idx
  checkIndex(list, idx2)
  list.data[idx2]

proc `[]=`*[T](list: var SharedArray[T]; idx: Index, x: T) {.inline, noSideEffect.} =
  ## Sets an array item.
  let idx2 = list ^^ idx
  checkIndex(list, idx2)
  list.data[idx2] = x

proc del*[T](list: var SharedArray[T]; idx: Index): void {.inline.} =
  ## deletes the item at index `i` by putting ``x[high(x)]`` into position `i`.
  ## This is an O(1) operation.
  ##
  ## .. code-block:: nim
  ##  var i = @[1, 2, 3, 4, 5].toSharedArray
  ##  i.del(2) #=> @[1, 2, 5, 4]
  let idx2 = list ^^ idx
  checkIndex(list, idx2)
  let len = list.len - 1
  list.data[idx2] = list.data[len]
  list.setLen(len)

proc delete*[T](list: var SharedArray[T]; idx: Index): void {.inline.} =
  ## deletes the item at index `i` by moving ``x[i+1..]`` by one position.
  ## This is an O(n) operation.
  ##
  ## .. code-block:: nim
  ##  var i = @[1, 2, 3, 4, 5].toSharedArray
  ##  i.delete(2) #=> @[1, 2, 4, 5]
  let idx2 = list ^^ idx
  checkIndex(list, idx2)
  let newSize = list.size-1
  let mem = sizeof(T) * (newSize - idx2)
  copyMem(list.data[idx2].unsafeAddr, list.data[idx2+1].unsafeAddr, mem)
  var defVal: T
  list.data[newSize] = defVal
  list.setLen(newSize)

proc insert*[T](list: var SharedArray[T], value: T, idx: Index = 0): void {.inline.} =
  ## insert an item at index `i` by moving ``x[i..]`` by one position.
  ## This is an O(n) operation.
  ##
  ## .. code-block:: nim
  ##  var i = @[1, 2, 3, 4, 5].toSharedArray
  ##  i.insert(22,2) #=> @[1, 2, 22, 3, 4, 5]
  let idx2 = list ^^ idx
  let newSize = list.size+1
  list.setLen(newSize)
  checkIndex(list, idx2)
  let mem = sizeof(T) * (list.size - idx2)
  copyMem(list.data[idx2+1].unsafeAddr, list.data[idx2].unsafeAddr, mem)
  list.data[idx] = value

proc toSharedArray*[T](src: openarray[T], capacity: int = -1): SharedArray[T] {.inline.} =
  ## Copies an open-array into a new SharedArray.
  ## capacity is used, if bigger than src.len
  let size = len(src)
  assert(size >= 0)
  result = initSharedArray[T](max(size, capacity))
  copyMem(result.data[0].unsafeAddr, src[0].unsafeAddr, sizeof(T) * size)
  result.size = size

proc `@`*[T](list: SharedArray[T]): seq[T] {.inline, noSideEffect.} =
  ## Copies a SharedArray into a Seq
  assert(list != nil)
  result = newSeq[T](list.size)
  copyMem(result[0].unsafeAddr, list.data[0].unsafeAddr, sizeof(T) * list.size)

template asOpenArray*[T](list: SharedArray[T]): openarray[T] =
  ## Casts a SharedArray to an open array.
  cast[seq[T]](list)

proc setLen*[T](list: var SharedArray[T], newLen: int): void =
  ## Sets the current length/size of the shared array. It cannot be nil.
  ## If newLen is greater than the capacity, the SharedArray is copied into
  ## a new SharedArray with the required capacity, list is set to the new
  ## SharedArray, and the old SharedArray is destroyed.
  assert(list != nil)
  assert(newLen >= 0)
  if newLen > list.mycapacity:
    var old = list
    list = toSharedArray(asOpenArray(old), newLen)
    deinitSharedArray(old)
  list.size = newLen

proc add*[T](list: var SharedArray[T]; x: T): void {.inline.} =
  ## Appends an array item.
  assert(list != nil)
  let size = list.size
  list.setLen(size+1)
  list.data[size] = x

proc pop*[T](list: var SharedArray[T]): T {.inline.} =
  ## returns the last item of `list` and decreases ``list.len`` by one. This treats
  ## `list` as a stack and implements the common *pop* operation.
  assert(list != nil)
  var L = list.len-1
  result = list[L]
  setLen(list, L)

proc isNil*[T](list: SharedArray[T]): bool {.inline, noSideEffect.} =
  ## Returns true if list is nil.
  (cast[pointer](list) == nil)

proc `==` *[T](x, y: SharedArray[T]): bool {.noSideEffect.} =
  ## Generic equals operator for SharedArrays: relies on a equals operator for
  ## the element type `T`.
  if cast[pointer](x) == cast[pointer](y):
    return true
  if x.isNil or y.isNil:
    return false
  if x.len != y.len:
    return false
  for i in 0..x.len-1:
    if x[i] != y[i]:
      return false
  return true

proc `==` *[T](x: SharedArray[T], y: openarray[T]): bool {.noSideEffect.} =
  ## Generic equals operator for SharedArrays/openarrays: relies on a equals operator for
  ## the element type `T`.
  if cast[pointer](x) == cast[pointer](y):
    return true
  # TODO: This causes stack-overflow!
  #if x.isNil or (y == nil):
  #  return false
  if x.len != y.len:
    return false
  for i in 0..x.len-1:
    if x[i] != y[i]:
      return false
  return true

proc `==` *[T](x: openarray[T], y: SharedArray[T]): bool {.noSideEffect.} =
  ## Generic equals operator for SharedArrays/openarrays: relies on a equals operator for
  ## the element type `T`.
  if cast[pointer](x) == cast[pointer](y):
    return true
  # TODO: This causes stack-overflow!
  #if (x == nil) or y.isNil:
  #  return false
  if x.len != y.len:
    return false
  for i in 0..x.len-1:
    if x[i] != y[i]:
      return false
  return true

proc collectionToString[T](x: T, prefix, separator, suffix: string): string =
  ## Stolen from system.nim
  result = prefix
  var firstElement = true
  for value in items(x):
    if firstElement:
      firstElement = false
    else:
      result.add(separator)

    when compiles(value.isNil):
      # this branch should not be necessary
      if value.isNil:
        result.add "nil"
      else:
        result.add($value)
    # prevent temporary string allocation
    elif compiles(result.add(value)):
      result.add(value)
    else:
      result.add($value)

  result.add(suffix)

proc `$`*[T](list: SharedArray[T]): string {.inline, noSideEffect.} =
  ## generic ``$`` operator for SharedArrays that is lifted from the components
  ## of `list`. Example:
  ##
  ## .. code-block:: nim
  ##   $(@[23, 45]) == "@[23, 45]"
  if list.isNil:
    "nil"
  else:
    collectionToString(list, "@[", ", ", "]")

proc `&`*[T](x: SharedArray[T], y: T): SharedArray[T] {.inline.} =
  ## Appends element y to the end of the SharedArray.
  ## Requires copying of the SharedArray, which needs to be deallocated separetly.
  ##
  ## .. code-block:: Nim
  ##   assert(@[1, 2, 3] & 4 == @[1, 2, 3, 4])
  let len = x.len
  result = initSharedArray[T](len + 1)
  result.setLen(len + 1)
  copyMem(result.data[0].unsafeAddr, x.data[0].unsafeAddr, sizeof(T) * x.len)
  result[len] = y

proc `&`*[T](x: T, y: SharedArray[T]): SharedArray[T] {.inline.} =
  ## Prepends the element x to the beginning of the SharedArray.
  ## Requires copying of the SharedArray, which needs to be deallocated separetly.
  ##
  ## .. code-block:: Nim
  ##   assert(1 & @[2, 3, 4] == @[1, 2, 3, 4])
  let len = y.len + 1
  result = initSharedArray[T](len)
  result.setLen(len)
  result[0] = x
  copyMem(result.data[1].unsafeAddr, y.data[0].unsafeAddr, sizeof(T) * y.len)

proc reversed*[T](a: SharedArray[T]): SharedArray[T] {.inline.} =
  ## Copy the items into reverse order in a new SharedArray, which needs to be deallocated separetly.
  result = initSharedArray[T](a.len)
  for i in 0..<a.len:
    result[a.len-i-1] = a[i]

proc reversed*[T](a: SharedArray[T], result: var SharedArray[T]) {.inline.} =
  ## Copy the items into reverse order in the given SharedArray.
  let oldResLen = result.len
  result.setLen(a.len)
  for i in 0..<a.len:
    result[a.len-i-1] = a[i]
  var defVal: T
  for i in a.len..<oldResLen:
    result[i] = defVal

iterator zip*[T, U](a: SharedArray[T], b: SharedArray[U]): (T, T)=
  ## Iterates over a pair of SharedArray.
  let len = min(a.len, b.len)
  for i in 0..<len:
    yield (a[i], b[i])

proc concat*[T](sas: varargs[SharedArray[T]]): SharedArray[T] =
  ## Allocate a new SharedArray, containing all the given SharedArray as parameters.
  var total_len = 0
  for sa in sas:
    inc(total_len, sa.len)
  result = initSharedArray[T](total_len)
  var i = 0
  for sa in sas:
    # TODO: Optimize using copyMem
    for val in sa:
      result[i] = val
      inc(i)

proc level0InitModuleVektor*(): void =
  ## Module registration
  discard registerModule("vektor")

when isMainModule:
  echo("TESTING SharedArray ...")
  var sa = initSharedArray[int](4)
  assert(sa != nil)
  assert(sa.len == 4)
  assert(sa.high == 3)
  assert(not sa.isNilOrEmpty)
  assert(not sa.isNil)
  assert(sa.capacity == 4)
  sa.setLen(0)
  sa.add(24)
  assert(sa[^1] == 24)
  sa[0] = 42
  assert(sa[^1] == 42)
  assert(sa.len == 1)
  assert(sa.high == 0)
  assert(not sa.isNilOrEmpty)
  assert(sa.capacity == 4)
  assert(sa[0] == 42)
  assert(@sa == @[42])
  assert(sa.asOpenArray.len == 1)
  assert(sa.asOpenArray.high == 0)
  assert(sa.asOpenArray[0] == 42)
  var found42 = false
  var count = 0
  for i in sa:
    if i == 42:
      found42 = true
    count.inc
  assert(found42)
  assert(count == 1)
  sa.setLen(4)
  assert(sa != nil)
  assert(sa.len == 4)
  assert(sa.high == 3)
  assert(not sa.isNilOrEmpty)
  assert(sa.capacity == 4)
  assert(sa[0] == 42)
  assert(sa[1] == 0)
  assert(sa[2] == 0)
  assert(sa[3] == 0)
  var tmp = sa
  sa.setLen(16)
  sa.setLen(4)
  assert(cast[pointer](sa) != cast[pointer](tmp))
  assert(sa != nil)
  assert(sa.len == 4)
  assert(sa.high == 3)
  assert(not sa.isNilOrEmpty)
  assert(sa.capacity == 16)
  assert(sa[0] == 42)
  assert(sa[1] == 0)
  assert(sa[2] == 0)
  assert(sa[3] == 0)
  var sa2 = @[42,0,0,0].toSharedArray
  assert(sa.len == sa2.len)
  for i in 0..sa.high:
    assert(sa[i] == sa2[i])
  assert(sa == sa2)
  sa.delete(2)
  assert(sa.pop() == 0)
  assert(sa.len == 2)
  assert(sa[0] == 42)
  assert(sa[1] == 0)
  sa.clear
  assert(sa != nil)
  assert(sa.len == 0)
  assert(sa.high == -1)
  assert(sa.isNilOrEmpty)
  assert(sa.capacity == 16)
  sa.deinitSharedArray()
  assert(sa == nil)
  assert(sa.isNil)
  sa2[3] = 24
  sa2.del(1)
  assert($sa2 == "@[42, 24, 0]")
  let s = @[42, 24, 0]
  assert(sa2 == s)
  assert(s == sa2)
  sa2.deinitSharedArray()
  assert(sa2 == nil)
  assert(sa2.isNil)
  sa = @[1, 2].toSharedArray
  sa2 = 0 & sa
  assert(sa2 == @[0, 1, 2])
  sa2.deinitSharedArray()
  sa2 = sa & 3
  assert(sa2 == @[1, 2, 3])
  var sa3 = sa2.reversed()
  assert(sa2 == @[1, 2, 3])
  assert(sa3 == @[3, 2, 1])
  sa3.reversed(sa)
  assert(sa3 == @[3, 2, 1])
  assert(sa == @[1, 2, 3])
  sa.insert(33)
  assert(sa == @[33, 1, 2, 3])
  sa2.insert(44, 1)
  assert(sa2 == @[1, 44, 2, 3])
  var sa4 = concat(sa, sa2, sa3)
  assert(sa4 == @[33, 1, 2, 3, 1, 44, 2, 3, 3, 2, 1])
  var i = 0
  for x,y in sa.zip(sa2):
    assert(x == sa4[i])
    assert(y == sa4[i+4])
    inc(i)
  for i,x in sa.pairs:
    assert(x == sa4[i])
  sa4.deinitSharedArray()
  sa3.deinitSharedArray()
  sa2.deinitSharedArray()
  sa.deinitSharedArray()
