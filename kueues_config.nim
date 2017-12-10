# Copyright 2017 Sebastien Diot.

# Defines compilation parameters for kueues.

const DEBUG_QUEUES* = false
  ## Do we want traces of what happens, to debug?

const USE_TOPICS* = true
  ## Do we support multiple topics per thread?

const USE_TIMESTAMPS* = true
  ## Do we support message timestamps?

const USE_TYPE_ID* = true
  ## Do we support message-type IDs?

const TWO_WAY_MESSAGING* = true
  ## Do we allow reply to requests?
  ## Requires including the sender, and the request (if any) in the message.

const MAX_THREADS* = 64
  ## Maximum threads on any CPU we expect to support in the near future.
  ## Must be power-of-two, maximum 256.
  ## Why make such a "short term" assumption? Because we are trying to pack
  ## The procees ID, thread ID, and topic ID in 32-bits.

when USE_TIMESTAMPS:

  type
    Timestamp* = float
      ## The type of the timestamp stored in messages.
      ## Must be defined, if USE_TIMESTAMPS is true.
    TimestampProvider* = proc (): Timestamp {.nimcall.}
      ## The proc returning the current timestamp
      ## Must be defined, if USE_TIMESTAMPS is true.

  import times
  let timestampProvider*: TimestampProvider = cpuTime
    ## Must be defined, if USE_TIMESTAMPS is true.

when USE_TOPICS:

  const MAX_TOPICS* = 1048576
    ## Maximum topics per thread, if supported.
    ## Must be power-of-two. Note that MAX_PROCESSES depends on MAX_TOPICS.
    ## In this case, MAX_PROCESSES (the maximum number of running process in the cluster)
    ## will be 4294967296/(MAX_THREADS * MAX_TOPICS).
    ## Example 4294967296/(64 * 1048576) == 64 processes.

else:

  # In this case, MAX_PROCESSES (the maximum number of running process in the cluster)
  # will be 65536/MAX_THREADS.
  discard
