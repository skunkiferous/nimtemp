# Copyright 2017 Sebastien Diot.

## This is to test that the code in atomiks actually works with multiple threads

import times, os

import atomiks

var my_byte: byte = 42'u8
var my_short: int16 = 42'i16
var my_uint: uint32 = 42'u32
var my_long: int64 = 42'i64

declVolatile(my_vbyte_ptr, byte, 42'u8)
declVolatile(my_vshort_ptr, int16, 42'i16)
declVolatile(my_vuint_ptr, uint32, 42'u32)
declVolatile(my_vlong_ptr, int64, 42'i64)

let start {.global.} = cpuTime()
let step_1 {.global.} = start + 0.5
let step_2 {.global.} = start + 1.0
let step_3 {.global.} = start + 1.5
let step_4 {.global.} = start + 2.0


proc sleepUntil(until: float): void =
  # Loop protects against spurious sleep returns
  while cpuTime() < until:
    sleep(10)

proc threadAStep1(startAt: float): void =
  sleepUntil(startAt)
  echo("Thread A starting step 1 at " & $cpuTime())
  atomicStoreFull(my_vbyte_ptr, my_byte)
  atomicStoreFull(my_vshort_ptr, my_short)
  atomicStoreFull(my_vuint_ptr, my_uint)
  atomicStoreFull(my_vlong_ptr, my_long)
  echo("Thread A done step 1 at " & $cpuTime())

proc threadBStep2(startAt: float): void =
  sleepUntil(startAt)
  echo("Thread B starting step 2/1 at " & $cpuTime())
  assert(atomicLoadFull(my_vbyte_ptr) == my_byte)
  assert(atomicLoadFull(my_vshort_ptr) == my_short)
  assert(atomicLoadFull(my_vuint_ptr) == my_uint)
  assert(atomicLoadFull(my_vlong_ptr) == my_long)
  echo("Thread B starting step 2/2 at " & $cpuTime())
  assert(atomicExchangeFull(my_vbyte_ptr, 0'u8) == my_byte)
  assert(atomicExchangeFull(my_vshort_ptr, 0'i16) == my_short)
  assert(atomicExchangeFull(my_vuint_ptr, 0'u32) == my_uint)
  assert(atomicExchangeFull(my_vlong_ptr, 0'i64) == my_long)
  echo("Thread B done step 2 at " & $cpuTime())

proc threadAStep3(startAt: float): void =
  sleepUntil(startAt)
  echo("Thread A starting step 3/1 at " & $cpuTime())
  assert(not atomicCompareExchangeFull(my_vbyte_ptr, addr my_byte, 10'u8))
  assert(not atomicCompareExchangeFull(my_vshort_ptr, addr my_short, 10'i16))
  assert(not atomicCompareExchangeFull(my_vuint_ptr, addr my_uint, 10'u32))
  assert(not atomicCompareExchangeFull(my_vlong_ptr, addr my_long, 10'i64))
  echo("Thread A starting step 3/2 at " & $cpuTime())
  assert(0'u8 == my_byte)
  assert(0'i16 == my_short)
  assert(0'u32 == my_uint)
  assert(0'i64 == my_long)
  echo("Thread A starting step 3/3 at " & $cpuTime())
  assert(atomicCompareExchangeFull(my_vbyte_ptr, addr my_byte, 10'u8))
  assert(atomicCompareExchangeFull(my_vshort_ptr, addr my_short, 10'i16))
  assert(atomicCompareExchangeFull(my_vuint_ptr, addr my_uint, 10'u32))
  assert(atomicCompareExchangeFull(my_vlong_ptr, addr my_long, 10'i64))
  echo("Thread A done step 3 at " & $cpuTime())

proc threadBStep4(startAt: float): void =
  sleepUntil(startAt)
  echo("Thread B starting step 4 at " & $cpuTime())
  assert(atomicLoadFull(my_vbyte_ptr) == 10'u8)
  assert(atomicLoadFull(my_vshort_ptr) == 10'i16)
  assert(atomicLoadFull(my_vuint_ptr) == 10'u32)
  assert(atomicLoadFull(my_vlong_ptr) == 10'i64)
  echo("Thread B starting step 4 at " & $cpuTime())

proc threadASteps() {.thread.} =
  threadAStep1(step_1)
  threadAStep3(step_3)

proc threadBSteps() {.thread.} =
  threadBStep2(step_2)
  threadBStep4(step_4)

when isMainModule:
  var threadA: Thread[void]
  var threadB: Thread[void]

  createThread[void](threadA, threadASteps)
  createThread[void](threadB, threadBSteps)

  joinThreads(threadA, threadB)

  echo("DONE TESTING atomics2!")
