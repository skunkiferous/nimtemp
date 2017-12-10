# Copyright 2017 Sebastien Diot.

import hashes

## This module can be used, when using "text" as a table key (both hashed and
## sorted), stored on the shared heap. One can create a SharedText using a
## "local" cstring, so that no shared heap allocation is needed to query a
## table by key.


const
  EMPTY: cstring = ""

type
  SharedText* = object
    ## Represents "unchangeable" text, optionally allocated on the heap.
    txt: cstring
    txthash: Hash
    txtlen: int
      ## The "sign" of txtlen is used as a marker to know if we need to "free" txt.

proc hash*(st: SharedText): Hash {.inline, noSideEffect.} =
  ## Returns the hash of the SharedText
  result = st.txthash

proc len*(st: SharedText): int {.inline, noSideEffect.} =
  ## Returns the len of the SharedText
  result = abs(st.txtlen)

proc allocated*(st: SharedText): bool {.inline, noSideEffect.} =
  ## Returns true if the SharedText was allocated on the shared heap.
  result = st.txtlen < 0

proc `$`*(st: SharedText): string {.inline.} =
  ## Returns the string representation of the SharedText
  result = $st.txt

proc cstr*(st: SharedText): cstring {.inline.} =
  ## Returns the 'raw' cstring of the SharedText
  result = st.txt

proc `==`*(a, b: SharedText): bool {.inline, noSideEffect.} =
  ## Compares SharedTexts
  (a.txthash == b.txthash) and (a.len == b.len) and (cmp(a.txt, b.txt) == 0)

proc `==`*(st: SharedText, cs: cstring): bool {.inline, noSideEffect.} =
  ## Compares a SharedText to a cstring
  let p = cast[pointer](cs)
  let cs2 = if (p == nil) or (p == cast[pointer](EMPTY)): EMPTY else: cs
  result = (cmp(st.txt, cs2) == 0)

proc `==`*(cs: cstring, st: SharedText): bool {.inline, noSideEffect.} =
  ## Compares a SharedText to a cstring
  let p = cast[pointer](cs)
  let cs2 = if (p == nil) or (p == cast[pointer](EMPTY)): EMPTY else: cs
  result = (cmp(st.txt, cs2) == 0)

proc `<`*(a, b: SharedText): bool {.inline, noSideEffect.} =
  ## Compares SharedTexts
  (cmp(a.txt, b.txt) < 0)

proc `<=`*(a, b: SharedText): bool {.inline, noSideEffect.} =
  ## Compares SharedTexts
  (cmp(a.txt, b.txt) <= 0)

proc copyCString(s: cstring): cstring {.inline.} =
  ## Creates a copy of a cstring into the shared-heap
  let p = cast[pointer](s)
  if (p == nil) or (p == cast[pointer](EMPTY)):
    return EMPTY
  let len = s.len
  result = cast[cstring](allocShared(len+1))
  copyMem(cast[pointer](result), p, len+1)

proc sharedCopy*(st: SharedText): SharedText {.inline.} =
  ## Returns a copy, allocating a copy of the underlying cstring on the shared heap.
  ## The returned object should be "freed" with "deinitSharedText()".
  ## You should only keep one copy of this object, as there are no safeguard
  ## against multiple deallocation.
  result.txt = copyCString(st.txt)
  result.txthash = st.txthash
  if cast[pointer](result.txt) == cast[pointer](EMPTY):
    result.txtlen = st.len
  else:
    result.txtlen = -st.len

proc initSharedText*(s: cstring): SharedText {.inline, noSideEffect.} =
  ## Creates a SharedText; does NOT clone the cstring, and is therefore inherently dangerous!
  let len = if cast[pointer](s) == nil: 0 else: len(s)
  result.txtlen = len
  if len == 0:
    result.txt = EMPTY
    result.txthash = 0
  else:
    result.txt = s
    result.txthash = hash(s)

proc deinitSharedText*(st: var SharedText): void {.inline.} =
  ## Destroys a SharedText. Deallocate the cstring, if allocated on the shared heap with sharedCopy().
  if st.allocated():
    deallocShared(st.txt)
  st.txt = EMPTY
  st.txtlen = 0
  st.txthash = 0

when isMainModule:
  echo("TESTING SharedText ...")
  let text1 = "abc"
  let text2 = "def"
  var st1 = initSharedText(text1)
  var st2 = initSharedText(text2)
  assert(st1.len == 3)
  assert(not st1.allocated())
  assert(st1.cstr == text1.cstring)
  assert(st2.cstr == text2.cstring)
  assert(st1 == text1)
  assert(text1 == st1)
  assert($st1 == text1)
  assert(text1 == $st1)
  assert(st1 != st2)
  assert(st1 < st2)
  assert(st1 <= st2)
  assert(st2 > st1)
  assert(st2 >= st1)
  assert(hash(st1) == hash(text1))
  st2 = sharedCopy(st1)
  assert(cast[pointer](st1.cstr) != cast[pointer](st2.cstr))
  assert(st1.len == 3)
  assert(st2.len == 3)
  assert(hash(st1) == hash(st2))
  assert(not st1.allocated())
  assert(st2.allocated())
  assert(st1 == st2)
  deinitSharedText(st1)
  assert(hash(st1) == 0)
  assert(st1.len == 0)
  assert($st1 == "")
  deinitSharedText(st2)
  assert(hash(st2) == 0)
  assert(st2.len == 0)
  assert($st2 == "")
