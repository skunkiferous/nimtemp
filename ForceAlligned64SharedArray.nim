# Copyright 2017 Sebastien Diot.

# Shamelessly stolen from mratsim forum example!

const FORCE_ALIGN = 64

type
  BlasBufferArray*[T]  = object
    dataRef: ref[ptr T]
    data*: ptr UncheckedArray[T]
    len*: int

proc deallocBlasBufferArray*[T](dataRef: ref[ptr T]) =
  if not dataRef[].isNil:
    deallocShared(dataRef[])
    dataRef[] = nil

proc newBlasBuffer*[T](size: int): BlasBufferArray[T] =
  ## Create a heap array aligned with FORCE_ALIGN
  new(result.dataRef, deallocBlasBufferArray)

  # Allocate memory, we will move the pointer, if it does not fall at a modulo FORCE_ALIGN boundary
  let address = cast[ByteAddress](allocShared0(sizeof(T) * size + FORCE_ALIGN - 1))

  result.dataRef[] = cast[ptr T](address)
  result.len = size

  if (address and (FORCE_ALIGN - 1)) == 0:
    result.data = cast[ptr UncheckedArray[T]](address)
  else:
    let offset = FORCE_ALIGN - (address and (FORCE_ALIGN - 1))
    let data_start = cast[ptr UncheckedArray[T]](address +% offset)
    result.data = data_start
