# Copyright 2017 Sebastien Diot.

import mylist
#import typeregister

# First, test the List.

proc testNewList(): void =
  echo "STARTING testNewList()"
  var a = newList[bool](3)
  assert(not a.isNil)
  assert(len(a) == 3)
  assert(not a[0])
  assert(not a[1])
  assert(not a[2])
  a[1] = true
  assert(not a[0])
  assert(a[1])
  assert(not a[2])
  destroy(a)
  assert(a.isNil)
  echo "DONE testNewList()"

proc testCopyList(): void =
  echo "STARTING testCopyList()"
  var b = copyList[bool](@[true,false])
  assert(b[0])
  assert(not b[1])
  b[0] = false
  assert(not b[0])
  assert(not b[1])
  destroy(b)
  assert(b.isNil)
  echo "DONE testCopyList()"

proc testListToSeq(): void =
  echo "STARTING testListToSeq()"
  var a = newList[bool](3)
  a[1] = true
  var s = a.toSeq
  assert(s is seq)
  assert(len(s) == 3)
  assert(not s[0])
  assert(s[1])
  assert(not s[2])
  s[1] = false
  assert(not s[1])
  assert(a[1])
  destroy(a)
  echo "DONE testListToSeq()"

proc listAsArrayTestHelper(a: openarray[bool]): void =
  assert(a is openarray[bool])
  assert(len(a) == 3)
  assert(not a[0])
  assert(a[1])
  assert(not a[2])

proc testListAsArray(): void =
  echo "STARTING testListAsArray()"
  var lst = newList[bool](3)
  lst[1] = true
  listAsArrayTestHelper(lst.asArray)
  destroy(lst)
  echo "DONE testListAsArray()"

proc testCStringList(): void =
  echo "STARTING testCStringList()"
  var a = newList[cstring](3)
  let cs: cstring = "0"
  a[0] = cs
  a[1] = "1"
  a[2] = "2"
  let cs2: cstring = a[2]
  echo(cs2)
  destroy(a)
  echo "DONE testCStringList()"

proc testListAll(): void =
  echo "RUNNING ALL List TESTS"
  testNewList()
  testCopyList()
  testListToSeq()
  testListAsArray()
  testCStringList()
  echo "ALL List TESTS DONE"

#[
proc testTypeID(): void =
  echo "STARTING testTypeID()"
  let t0 = typeID(uint8)
  let t1 = typeID(bool)
  let t3 = typeID(uint8)
  assert(t0 == t3)
  echo "DONE testTypeID()"
]#
proc testAll(): void =
  echo "RUNNING ALL TESTS"
  testListAll()
  #testTypeID()
  echo "ALL TESTS DONE"

when isMainModule:
  testAll()