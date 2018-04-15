# Copyright 2017 Sebastien Diot.

# Defines a proc that returns the "current time" in milliseconds since epoch.

import times

import moduleinit

var CORRECTION_MILLIS*: int64 = 0
  ## Maybe you use multiple nodes, and you somehow want to "improve" to
  ## correctness of currentTimeMillis() by adding some offset.
  ## In a multi-threaded app, it should be set only once before creating threads
  ## that call currentTimeMillis().

var ACCEPTABLE_ERROR_MILLIS*: int64 = 60000
  ## When comparing some time to the current time, a difference larger than
  ## this will cause an exception.
  ## In a multi-threaded app, it should be set only once before creating threads
  ## that call currentTimeMillis().


proc currentTimeMillis*(): int64 =
  ## Returns the "current time" in milliseconds since epoch.
  # Only a rough solution, until PR https://github.com/nim-lang/Nim/pull/6978
  # is available.
  result = int64(epochTime() * 1000) + CORRECTION_MILLIS

proc checkTimeIsAboutCurrent*(ts: int64): void =
  ## Checks that the given time is "approximatelly" right, by a margin of 60 seconds.
  let now = currentTimeMillis()
  let diff = (now - ts)
  if diff > ACCEPTABLE_ERROR_MILLIS:
    raise newException(Exception, "ts too far in the past (" & $diff & " > " & $ACCEPTABLE_ERROR_MILLIS & ")")
  if diff < -ACCEPTABLE_ERROR_MILLIS:
    raise newException(Exception, "ts too far in the future (" & $diff & " < -" & $ACCEPTABLE_ERROR_MILLIS & ")")

proc level0InitModuleKurrenttime*(): void =
  ## Module registration
  discard registerModule("kurrenttime")

when isMainModule:
  echo("TESTING currentTimeMillis() ...")
  # 2017-12-28 about 14:30 UTC
  let WHEN_THIS_WAS_CODED = 1514471129355'i64
  let ABOUT_100_YEARS = 100'i64 * 365'i64 * 24'i64 * 60'i64 * 60'i64 * 1000'i64
  let now = currentTimeMillis()
  assert((now > WHEN_THIS_WAS_CODED) and (now < WHEN_THIS_WAS_CODED + ABOUT_100_YEARS))

