# Copyright 2017 Sebastien Diot.

import math

const WORD_SIZE = sizeof(int)

proc genericAllocAligned*(size: Natural, align: Natural, allocate: proc (size: Natural): pointer {.noconv.}): pointer =
  assert(isPowerOfTwo(align), "align must be power of two: " & $align)
  assert(allocate != nil, "allocate cannot be nil")
  if align > WORD_SIZE:
    assert(align <= 256)
    let a = allocate(size + align)
    if a == nil:
      return nil
    var p = cast[int](a)
    let mask = int(align-1)
    let offset = if ((p and mask) != 0): (p and mask) else: int(align)
    inc(p, offset)
    cast[ptr[byte]](p-1)[] = byte(offset)
    result = cast[pointer](p)
  else:
    result = allocate(size)
  # Returns an aligned memory block of size bytes, with a given allocator.
  # It is assumed that, the allocator will always align memory at *least* on word boundary.
  # align must be a power-of-two, no bigger than 256.
  # The result *must* be deallocated with genericDeallocAligned(), using the same align value,
  # and a compatible deallocator.

proc genericDeallocAligned*(p: pointer, align: Natural, deallocate: proc (mem: pointer): void {.noconv.}): void =
  assert(deallocate != nil, "deallocate cannot be nil")
  # Cannot validate that align matches the call to genericAllocAligned,
  # or that deallocate() is compatible with allocate()
  if p != nil:
    if align > WORD_SIZE:
      assert(p != nil)
      let offset = cast[ptr[byte]](cast[int](p) - 1)[]
      let a = cast[pointer](cast[int](p) - cast[int](offset))
      deallocate(a)
    else:
      deallocate(p)
  # Frees a block of memory allocated with genericAllocAligned(), with a given deallocator.
  # The align parameter must be the same as in the call to genericAllocAligned().

proc allocAligned*(size: Natural, align: Natural): pointer {.inline.} =
  genericAllocAligned(size, align, alloc)
  # Returns an aligned memory block of size bytes, using "alloc()" as allocator.
  # align must be a power-of-two, no bigger than 256.
  # The result *must* be deallocated with deallocAligned(), using the same align value.

proc alloc0Aligned*(size: Natural, align: Natural): pointer {.inline.} =
  genericAllocAligned(size, align, alloc0)
  # Returns an aligned memory block of size bytes, using "alloc0()" as allocator.
  # align must be a power-of-two, no bigger than 256.
  # The result *must* be deallocated with deallocAligned(), using the same align value.

proc deallocAligned*(p: pointer, align: Natural): void {.inline.} =
  genericDeallocAligned(p, align, dealloc)
  # Frees a block of memory allocated with allocAligned() or alloc0Aligned().
  # The align parameter must be the same as in the call to allocAligned()/alloc0Aligned().

proc allocSharedAligned*(size: Natural, align: Natural): pointer {.inline.} =
  genericAllocAligned(size, align, allocShared)
  # Returns an aligned memory block of size bytes, using "allocShared()" as allocator.
  # align must be a power-of-two, no bigger than 256.
  # The result *must* be deallocated with deallocSharedAligned(), using the same align value.

proc allocShared0Aligned*(size: Natural, align: Natural): pointer {.inline.} =
  genericAllocAligned(size, align, allocShared0)
  # Returns an aligned memory block of size bytes, using "allocShared0()" as allocator.
  # align must be a power-of-two, no bigger than 256.
  # The result *must* be deallocated with deallocSharedAligned(), using the same align value.

proc deallocSharedAligned*(p: pointer, align: Natural): void {.inline.} =
  genericDeallocAligned(p, align, deallocShared)
  # Frees a block of memory allocated with allocSharedAligned() or allocShared0Aligned().
  # The align parameter must be the same as in the call to allocSharedAligned()/allocShared0Aligned().


when isMainModule:
  let LOOPS = 123
  let ALIGN = 16'u8
  echo "LOOPS: ", LOOPS
  echo "WORD_SIZE: ", WORD_SIZE
  echo "ALIGN: ", ALIGN
  echo "LOCAL:"
  for i in 1..LOOPS:
    let p = alloc0Aligned(i, ALIGN)
    if p != nil:
      deallocAligned(p, ALIGN)
    else:
      echo "FAILED FOR: ",i
  echo "SHARED:"
  for i in 1..LOOPS:
    let p = allocShared0Aligned(i, ALIGN)
    if p != nil:
      deallocSharedAligned(p, ALIGN)
    else:
      echo "FAILED FOR: ",i
  echo "DONE!"