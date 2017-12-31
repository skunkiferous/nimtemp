# Copyright 2017 Sebastien Diot.

# Defines a proc that returns the "current time" in milliseconds since epoch.

import times

var CORRECTION_MILLIS*: int64 = 0
  ## Maybe you have a cluster, and you somehow want to "improve" to correctness
  ## of currentTimeMillis() by adding some offset.
  ## In a multi-threaded app, it should be set only once before creating threads
  ## that call currentTimeMillis().


proc currentTimeMillis*(): int64 =
  ## Returns the "current time" in milliseconds since epoch.
  # Only a rough solution, until PR https://github.com/nim-lang/Nim/pull/6978
  # is available.
  result = int64(epochTime() * 1000) + CORRECTION_MILLIS

when isMainModule:
  echo("TESTING currentTimeMillis() ...")
  # 2017-12-28 about 14:30 UTC
  let WHEN_THIS_WAS_CODED = 1514471129355'i64
  let ABOUT_100_YEARS = 100'i64 * 365'i64 * 24'i64 * 60'i64 * 60'i64 * 1000'i64
  let now = currentTimeMillis()
  assert((now > WHEN_THIS_WAS_CODED) and (now < WHEN_THIS_WAS_CODED + ABOUT_100_YEARS))

