# Copyright 2017 Sebastien Diot.

# Shamelessly stolen from Jehan Forum example

template ptrMath*(body: untyped) =
  template `+`*[T](p: ptr T, off: int): ptr T =
    cast[ptr type(p[])](cast[ByteAddress](p) +% off * sizeof(p[]))

  template `+=`*[T](p: ptr T, off: int) =
    p = p + off

  template `-`*[T](p: ptr T, off: int): ptr T =
    cast[ptr type(p[])](cast[ByteAddress](p) -% off * sizeof(p[]))

  template `-=`*[T](p: ptr T, off: int) =
    p = p - off

  template `[]`*[T](p: ptr T, off: int): T =
    (p + off)[]

  template `[]=`*[T](p: ptr T, off: int, val: T) =
    (p + off)[] = val

  body
