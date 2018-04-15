# Copyright 2017 Sebastien Diot.

import moduleinit

# Defines compilation parameters for kueues.

const DEBUG_QUEUES* = false
  ## Do we want traces of what happens, to debug?

const USE_TOPICS* = true
  ## Do we support multiple topics per thread?

const USE_TIMESTAMPS* = true
  ## Do we support message timestamps?

const USE_TYPE_ID* = true
  ## Do we support message-type IDs?

const USE_TWO_WAY_MESSAGING* = true
  ## Do we allow reply to requests?
  ## Requires including the sender, and the request (if any) in the message.

const USE_URGENT_MARKER* = true
  ## Do we track which message were sent with sendMsgNow()/replyNowWith()?

const USE_THREAD_POOL* = false
  ## Do we create our own thread-pool?

const MAX_THREADS* = 64
  ## Maximum threads on any CPU we expect to support in the near future.
  ## Must be power-of-two, maximum 256.
  ##
  ## Why make such a "short term" assumption? Because we are trying to pack
  ## The procees ID, thread ID, and topic ID in 16 or 32-bits...
  ##
  ## MAX_PROCESSES value is based on MAX_THREADS and MAX_TOPICS. Cluster
  ## support is active if MAX_PROCESSES > 1. Setting MAX_PROCESSES to 1
  ## requires defining MAX_TOPICS as 4294967296/MAX_THREADS.

const OUTGOING_MSG_BUFFER_SIZE* = 100
  ## The number of outgoing messages that are buffered, before actually sending
  ## them. Messages are actually sent when either this limit is reached, or
  ## flushMsgs() is called, or recvMsgs() is called. Note that this is the
  ## total buffer size, not per destination.
  ##
  ## Setting this value to 0 disables buffering.

const IMPOSSIBLE_MSG_SIZE*: uint32 = 64*1024*1024
  ## How big a message is too big? (Only applies across the cluster)

const DEFAULT_CLUSTER_PORT*: uint16 = 12345
  ## The default cluster port.

type
  MsgSeqIDTypeEnum* = enum
    ## The type of message sequence ID, if any, added to each message.
    msitNone,         # We don't use Message sequence IDs.
    msitPerTopic32,   # Each Topic has it's own unique 32-bit ID sequence.
    msitPerTopic64,   # Each Topic has it's own unique 64-bit ID sequence.
    msitPerThread32,  # Each Thread has it's own unique 32-bit ID sequence.
    msitPerThread64,  # Each Thread has it's own unique 64-bit ID sequence.
    msitPerProcess32, # Each Process has it's own unique 32-bit ID sequence.
                      # Note that this can have a measurable performance cost,
                      # due to the use of an atomic counter.
                      # Also note that 32-bit IDs might not be sufficient for
                      # long running processes.
    msitPerProcess64, # Each Process has it's own unique 64-bit ID sequence.
                      # Note that this can have a measurable performance cost,
                      # due to the use of an atomic counter.
    msitCluster64     # Message IDs are 64-bit cluster-wide unique.
                      # This is implemented by combining the "QueueID" with a
                      # counter. While it is cheap to realise and makes the ID
                      # unique, it means the ID are NOT globally sorted, which
                      # would require something like PAXOS.
                      # CLUSTER_SUPPORT must be true, if chosen.

const MSG_SEQ_ID_TYPE* = MsgSeqIDTypeEnum.msitPerProcess64
  ## The type of message sequence ID, if any, added to each message.

when USE_TIMESTAMPS:

  type
    Timestamp* = int64
      ## The type of the timestamp stored in messages.
      ## Must be defined, if USE_TIMESTAMPS is true.
    TimestampProvider* = proc (): Timestamp {.nimcall.}
      ## The proc returning the current timestamp
      ## Must be defined, if USE_TIMESTAMPS is true.
      ## PLEASE DON'T CHANGE THIS!
    TimestampValidator* = proc (ts: Timestamp): void {.nimcall.}
      ## The proc validating an "incomming" timestamp.
      ## A timestamp more than 1 minute in the past or future should be invalid.
      ## Must be defined, if USE_TIMESTAMPS is true.
      ## PLEASE DON'T CHANGE THIS!

  import kurrenttime
  let timestampProvider*: TimestampProvider = currentTimeMillis
    ## Must be defined, if USE_TIMESTAMPS is true.
    ## Feel free to change the assigned proc.
  let timestampValidator*: TimestampValidator = checkTimeIsAboutCurrent
    ## Must be defined, if USE_TIMESTAMPS is true.
    ## Feel free to change the assigned proc.

when USE_TOPICS:

  const MAX_TOPICS* = 1048576
    ## Maximum topics per thread, if supported.
    ## Must be power-of-two. Note that MAX_PROCESSES depends on MAX_TOPICS.
    ## In this case, MAX_PROCESSES (the maximum number of running process
    ## in the cluster) will be 4294967296/(MAX_THREADS * MAX_TOPICS).
    ## Example 4294967296/(64 * 1048576) == 64 processes.

else:

  # In this case, MAX_PROCESSES (the maximum number of running process in the
  # cluster) will be 65536/MAX_THREADS.
  discard

when USE_THREAD_POOL:

  const USE_PIN_TO_CPU* = true
    ## Do we call pinToCpu() on each thread-pool thread?

proc level0InitModuleKueues_config*(): void =
  ## Module registration
  if registerModule("kueues_config", "kurrenttime"):
    level0InitModuleKurrenttime()
