# Copyright 2017 Sebastien Diot.

## Zero-Copy queues, for multi-threading.
##
## (Eventually) the queues will allow cluster-communication "transparently"
## (as much as possible). There are a few restrictions; unlike Nim channels,
## the messages are NOT copied. This means the sender should not modify the
## message after sending it. And the receiver should not modify the message,
## if the sender is going to "look at it again". Additionally, the allocation
## strategy is in the hands of the user. The user has the responsibility to
## de-allocate the message in a safe way, as the user decides how to allocate
## the messages in the first place. This might eventually be replaced with a
## "safe" default allocation strategy.
##
## Multiple kueues features can be configured in the module kueues_config.

import algorithm
import asyncdispatch
import asyncnet
import hashes
import locks
import math
import nativesockets
import options
import os
import osproc
import sets
import strutils
import tables
import times
import typetraits

import atomiks
import diktionary
import typerekjister

import ./kueues_config

export hash, `==`

const USE_SMALL_PTR = sizeof(pointer) == 4
  ## 32 bit pointers?

const USE_BIG_PTR = sizeof(pointer) > 4
  ## 64 bit pointers?

const USE_MSG_SEQ_ID = (MSG_SEQ_ID_TYPE != MsgSeqIDTypeEnum.msitNone)
  ## Do we use message sequence IDs?

const MSG_SEQ_ID_PER_PROCESS = USE_MSG_SEQ_ID and ((MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerProcess32) or
  (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerProcess64))
  ## Do we use *validate* sequence IDs per process?

const MSG_SEQ_ID_PER_THREAD = USE_MSG_SEQ_ID and ((MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerThread32) or
  (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerThread64) or
  ((MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitCluster64) and not USE_TOPICS))
  ## Do we use *validate* sequence IDs per thread?

when USE_MSG_SEQ_ID and USE_TWO_WAY_MESSAGING and not (MSG_SEQ_ID_PER_PROCESS or MSG_SEQ_ID_PER_THREAD):
  echo("TODO: seq ID not validated when using topics!")

const USE_OUT_BUFFERS = (OUTGOING_MSG_BUFFER_SIZE > 0)
  ## Do we use outgoing messages buffers?

when DEBUG_QUEUES:
  from gethutil import toBin
  echo("DEBUG_QUEUES: " & $DEBUG_QUEUES)
  echo("64-bits: " & $USE_BIG_PTR)
  echo("USE_TOPICS: " & $USE_TOPICS)
  echo("USE_TYPE_ID: " & $USE_TYPE_ID)
  echo("USE_TIMESTAMPS: " & $USE_TIMESTAMPS)
  echo("USE_TWO_WAY_MESSAGING: " & $USE_TWO_WAY_MESSAGING)
  echo("MAX_THREADS: " & $MAX_THREADS)
  when USE_TOPICS:
    echo("MAX_TOPICS: " & $MAX_TOPICS)
  echo("OUTGOING_MSG_BUFFER_SIZE: " & $OUTGOING_MSG_BUFFER_SIZE)
  echo("USE_MSG_SEQ_ID: " & $USE_MSG_SEQ_ID)
  when USE_MSG_SEQ_ID:
    echo("MSG_SEQ_ID_TYPE: " & $MSG_SEQ_ID_TYPE)
  echo("USE_URGENT_MARKER: " & $USE_URGENT_MARKER)
  echo("IMPOSSIBLE_MSG_SIZE: " & $IMPOSSIBLE_MSG_SIZE)

static:
  assert(isPowerOfTwo(MAX_THREADS), "MAX_THREADS must be power of two: " & $MAX_THREADS)
  assert((MAX_THREADS <= 256), "MAX_THREADS currently limited to 256: " & $MAX_THREADS)
  assert((int64(IMPOSSIBLE_MSG_SIZE) <= int64(high(int32))), "IMPOSSIBLE_MSG_SIZE currently limited to " & $high(int32))

when USE_TOPICS:
  static:
    assert(isPowerOfTwo(MAX_TOPICS), "MAX_TOPICS must be power of two: " & $MAX_TOPICS)
    assert((int64(MAX_THREADS) * MAX_TOPICS < high(int32)), "MAX_TOPICS too big: " & $MAX_TOPICS)
  const MAX_PROCESSES* = int(4294967296'i64 div int64(MAX_THREADS * MAX_TOPICS))
    ## Maximum processes (cluster size) we expect to support in the near future.
    ## MAX_THREADS * MAX_PROCESSES must not be > 65536, because both are stored in a uint16.
    ## If using topics, consider reducing this value, or MAX_THREADS, to allow
    ## more than 65536 topics.
else:
  const MAX_PROCESSES* = int(65536 div MAX_THREADS)
    ## Maximum processes (cluster size) we expect to support in the near future.
    ## MAX_THREADS * MAX_PROCESSES must not be > 65536, because both are stored in a uint16.
    ## If using topics, consider reducing this value, or MAX_THREADS, to allow
    ## more than 65536 topics.
  static:
    assert(not USE_MSG_SEQ_ID or ((MSG_SEQ_ID_TYPE != msitPerTopic32) and (MSG_SEQ_ID_TYPE != msitPerTopic64)),
      "MSG_SEQ_ID_TYPE can only be a topic, if topics are enabled!")

const CLUSTER_SUPPORT* = (MAX_PROCESSES > 1)
  ## Are we operating in a cluster?

when DEBUG_QUEUES:
  echo("CLUSTER_SUPPORT: " & $CLUSTER_SUPPORT)
  echo("MAX_PROCESSES: " & $MAX_PROCESSES)

static:
  assert(CLUSTER_SUPPORT or (MSG_SEQ_ID_TYPE != MsgSeqIDTypeEnum.msitCluster64),
    "Cluster must be supported, if MSG_SEQ_ID_TYPE == msitCluster64")
  assert(isPowerOfTwo(MAX_PROCESSES), "MAX_PROCESSES must be power of two: " & $MAX_PROCESSES)
  assert((MAX_THREADS * MAX_PROCESSES <= 65536), "MAX_THREADS * MAX_PROCESSES must not be > 65536")

const THREAD_BITS = countBits32(MAX_THREADS-1)
  ## Number of bits to represent the thread ID.
const PROCESS_BITS = countBits32(MAX_PROCESSES-1)
  ## Number of bits to represent the process ID.

const THREAD_ID_MASK = uint16(MAX_THREADS-1)
  ## Bit-Mask to extract Thread IDs from a QueueID
const PROCESS_ID_MASK = uint16(MAX_PROCESSES-1)
  ## Bit-Mask to extract Process IDs from a QueueID

when USE_TOPICS:
  const TOPIC_ID_MASK = uint32(MAX_TOPICS-1)
    ## Bit-Mask to extract Topic IDs from a QueueID
  const THREAD_AND_PROCESS_BITS = THREAD_BITS + PROCESS_BITS
    ## Number of bits to represent the process and thread ID.

const UNINIT_PROCESS_ID = -1
  ## Value of own process ID, before initialisation.

let MAX_CPU_THREADS* {.global.} = min(max(countProcessors(), 2), MAX_THREADS)
  ## Maximum threads on this CPU. countProcessors() return cores*2 on Hyper-threading CPUs.


when DEBUG_QUEUES:
  echo("THREAD_BITS: " & $THREAD_BITS)
  echo("PROCESS_BITS: " & $PROCESS_BITS)
  echo("THREAD_ID_MASK: " & toBin(THREAD_ID_MASK))
  echo("PROCESS_ID_MASK: " & toBin(PROCESS_ID_MASK))
  when USE_TOPICS:
    echo("TOPIC_ID_MASK: " & toBin(TOPIC_ID_MASK))
  echo("MAX_CPU_THREADS: " & $MAX_CPU_THREADS)

when USE_TYPE_ID:
  var messageTypeRegister {.global.} = initTypeRegister(bool)

proc `$` (i: uint): string {.inline.} =
  ## Nim has issues converting an uint (8/16/32) to a string!
  $uint64(i)

type
  ThreadID* = distinct range[0'u8..uint8(MAX_THREADS-1)]
    ## Thread ID, within process.
  ProcessID* = distinct range[0'u16..uint16(MAX_PROCESSES-1)]
    ## Process ID of thread.

proc `==` *(a, b: ThreadID): bool {.borrow.}
proc `$` *(id: ThreadID): string {.borrow.}
proc `==` *(a, b: ProcessID): bool {.borrow.}
proc `$` *(id: ProcessID): string {.borrow.}

when CLUSTER_SUPPORT:
  let MAGIC: uint32 = htonl(1530959153'u32)
    ## Some "magic number", to detect connection from peer.
  let VERSION: uint32 = htonl(000_000_001'u32)
    ## The kueues version. Communication requires the same version.

  type
    PeerConnection = object
      ## Represents a peer connection, on the cluster.
      pid: ProcessID
      sock: AsyncSocket
      domain: Domain
      localAddr: string
      localPort: Port
      remoteAddr: string
      remotePort: Port
      valid: bool
      when MSG_SEQ_ID_PER_PROCESS:
        lastseqid: uint64
      when MSG_SEQ_ID_PER_THREAD:
        lastseqid: ref[array[uint64,MAX_THREADS]]

    NotAString* = array[256,char]
    ProcessIDToAddress* = proc (pid: ProcessID, port: var Port, address: var NotAString): void {.nimcall,gcSafe.}
      ## Takes a ProcessID, and returns the port/address for it.

  proc `$` *(nas: var NotAString): string =
    ## Creates a string with the content of nas.
    let size = nas.find(char(0)) + 1
    result = newStringOfCap(size)
    for i in 0..size:
      result.add(nas[i])

  proc fill*(nas: var NotAString, s: string): void {.gcSafe.} =
    ## Fills nas with the content of s.
    ## The content of s must fit in nas, or an exceptio is thrown.
    let size = len(s)
    if size > high(NotAString):
      raise newException(Exception, "s is too big: " & $size)
    for i in 0..size:
      nas[i] = s[i]

  when DEBUG_QUEUES:
    echo("MAGIC: " & $MAGIC)
    echo("VERSION: " & $VERSION)

when USE_TOPICS:
  const USE_TOPIC_SEQ = USE_MSG_SEQ_ID and ((MSG_SEQ_ID_TYPE == msitPerTopic32) or
    (MSG_SEQ_ID_TYPE == msitPerTopic64) or (MSG_SEQ_ID_TYPE == msitCluster64))
    ## Do we use topices and message sequence IDs together?

  type
    TopicID* = distinct range[0'u32..uint32(MAX_TOPICS-1)]
      ## TopicID, within thread.
      ## Hint, since the "getter" for ThreadID is "tid()", the "getter" for
      ## TopicID is "cid()", as in "category ID".
      ## If you hav a better getter name, say so!
    QueueID* = distinct uint32
      ## The complete queue ID, containing the process ID, thread ID, and topic ID.

  proc `==` *(a, b: TopicID): bool {.borrow.}
  proc `$` *(id: TopicID): string {.borrow.}

  when USE_TOPIC_SEQ and (MSG_SEQ_ID_TYPE == msitCluster64):
    const QUEUE_ID_MASK = uint32(-1)
else:
  type
    QueueID* = distinct uint16
      ## The complete queue ID, containing the process ID and thread ID.

  const QUEUE_ID_MASK = uint16(-1)

proc `==` *(a, b: QueueID): bool {.borrow.}

when USE_TYPE_ID:
  type
    MsgTypeID* = distinct uint16
      ## We assume a limited number of message types, because it would
      ## otherwise increase our message size, which maters when we send them
      ## over the network.

  proc `==` *(a, b: MsgTypeID): bool {.borrow.}
  proc `$` *(id: MsgTypeID): string {.borrow.}

when DEBUG_QUEUES:
  echo("ThreadID: range[0.." & $(MAX_THREADS-1) & "]")
  echo("ProcessID: range[0.." & $(MAX_PROCESSES-1) & "]")
  when USE_TOPICS:
    echo("TopicID: range[0.." & $(MAX_TOPICS-1) & "]")
  echo("QueueID: uint" & $(8 * sizeof(QueueID)))

when USE_TIMESTAMPS:
  const TS_SIZE = sizeof(Timestamp)
  static:
    assert((TS_SIZE == 4) or (TS_SIZE == 8) or (TS_SIZE == 16), "sizeof(Timestamp) expected to be 4/8/16")
    # Timestamp size expected to be 4 or 8 bytes, possibly platform dependent.
    # Timestamp of size 16 concievable, if some combination of real-time and
    # counters is used.
  const USE_BIG_TIMESTAMPS: bool = (TS_SIZE >= 8)
  const USE_SMALL_TIMESTAMPS: bool = (TS_SIZE < 8)
  when DEBUG_QUEUES:
    echo("USE_SMALL_TIMESTAMPS: " & $USE_SMALL_TIMESTAMPS)
    echo("USE_BIG_TIMESTAMPS: " & $USE_BIG_TIMESTAMPS)

else:
  const USE_BIG_TIMESTAMPS: bool = false
  const USE_SMALL_TIMESTAMPS: bool = false

when USE_MSG_SEQ_ID:
  const USE_SMALL_SEQ_ID: bool = (MSG_SEQ_ID_TYPE == msitPerTopic32) or
    (MSG_SEQ_ID_TYPE == msitPerThread32) or (MSG_SEQ_ID_TYPE == msitPerProcess32)
  const USE_BIG_SEQ_ID: bool = (MSG_SEQ_ID_TYPE == msitPerTopic64) or
    (MSG_SEQ_ID_TYPE == msitPerThread64) or (MSG_SEQ_ID_TYPE == msitPerProcess64) or
    (MSG_SEQ_ID_TYPE == msitCluster64)
  static:
    assert(USE_BIG_SEQ_ID or USE_SMALL_SEQ_ID, "Unsupported MSG_SEQ_ID_TYPE (" & $MSG_SEQ_ID_TYPE & ")")
  when DEBUG_QUEUES:
    echo("USE_SMALL_SEQ_ID: " & $USE_SMALL_SEQ_ID)
    echo("USE_BIG_SEQ_ID: " & $USE_BIG_SEQ_ID)
else:
  const USE_BIG_SEQ_ID: bool = false
  const USE_SMALL_SEQ_ID: bool = false

when USE_BIG_SEQ_ID:
  type
    MsgSeqID* = int64
      ## The type of the message sequence ID.

  when MSG_SEQ_ID_TYPE == msitPerThread64:
    var myThreadSeqID {.threadvar.}: MsgSeqID
      ## Current message sequence ID for the Thread.
    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      inc myThreadSeqID
      result = myThreadSeqID
      assert(result > 0, "Maximum message sequence ID reached!")

  when MSG_SEQ_ID_TYPE == msitPerProcess64:
    declVolatile(myProcessGlobalSeqID, MsgSeqID, MsgSeqID(0))
    # Current (global) per Process message sequence ID.
    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      result = atomicIncRelaxed(myProcessGlobalSeqID)
      assert(result > 0, "Maximum message sequence ID reached!")

  when (MSG_SEQ_ID_TYPE == msitCluster64) and not USE_TOPICS:
    var myClusterSeqID {.threadvar.}: uint64
      ## Current (partial) message sequence ID for the Cluster.
    const CLUSTER_SEQ_ID_BITS = uint64(sizeof(uint64) - sizeof(QueueID)) * 8'u64
    const CLUSTER_SEQ_ID_SEQ_MASK: uint64 = (1'u64 shl CLUSTER_SEQ_ID_BITS) - 1'u64
    const CLUSTER_SEQ_ID_QUEUE_MASK: uint64 = uint64(-1'i64) xor CLUSTER_SEQ_ID_SEQ_MASK
    when DEBUG_QUEUES:
      echo("CLUSTER_SEQ_ID_BITS: " & $CLUSTER_SEQ_ID_BITS)
      echo("CLUSTER_SEQ_ID_SEQ_MASK: " & toBin(CLUSTER_SEQ_ID_SEQ_MASK))
      echo("CLUSTER_SEQ_ID_QUEUE_MASK: " & toBin(CLUSTER_SEQ_ID_QUEUE_MASK))

    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Cluster.
      inc myClusterSeqID
      var tmp = myClusterSeqID
      assert((tmp and CLUSTER_SEQ_ID_QUEUE_MASK) == 0, "Maximum message sequence ID reached!")
      tmp = tmp or ((uint64(q) and uint64(QUEUE_ID_MASK)) shl CLUSTER_SEQ_ID_BITS)
      result = MsgSeqID(tmp)

when USE_SMALL_SEQ_ID:
  type
    MsgSeqID* = int32
      ## The type of the message sequence ID.
  when MSG_SEQ_ID_TYPE == msitPerThread32:
    var myThreadSeqID {.threadvar.}: MsgSeqID
      ## Current message sequence ID for the Thread.
    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      inc myThreadSeqID
      result = myThreadSeqID
      assert(result > 0, "Maximum message sequence ID reached!")

  when MSG_SEQ_ID_TYPE == msitPerProcess32:
    declVolatile(myProcessGlobalSeqID, MsgSeqID, MsgSeqID(0))
    # Current (global) per Process message sequence ID.
    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      result = atomicIncRelaxed(myProcessGlobalSeqID)
      assert(result > 0, "Maximum message sequence ID reached!")

const NEED_DUMMY_PADDING = USE_SMALL_PTR and (USE_BIG_SEQ_ID or USE_BIG_TIMESTAMPS)
  ## If "previous" is 4 bytes, and there are 8 bytes fields after it, add
  ## some padding so they are aligned.

const MSG_PREVIOUS_OVERHEAD = if USE_BIG_PTR or NEED_DUMMY_PADDING: 8 else: 4
  ## "previous" is not really part of the message data; it just saves us having
  ## to wrap the message in a linked-list node. This represents the "overhead"
  ## of "previous", including optional padding.

type
  MsgBase* = object
    ## The base of a message, without the "content"
    previous: ptr MsgBase
      ## The previous message sent to this queue, if any.
      ## Should not be visible from API consumers.
      ## Platform-dependent; assumed 8 bytes in 64-bits and otherwise 4 bytes.
    when NEED_DUMMY_PADDING:
      xxdummyxx: uint32
        ## If "previous" is 4 bytes, and there are 8 bytes fields after it, add
        ## some padding so they are aligned.
    when USE_BIG_SEQ_ID:
      myseqid: MsgSeqID
        ## The message sequence ID.
        ## Should be 8 bytes in this case.
    when USE_BIG_TIMESTAMPS:
      mytimestamp: Timestamp
        ## The message creation timestamp
        ## User-defined size; assumed 8/16 bytes in this case.
        ## Put before pointers, because we want the fields sorted by size,
        ## and it is either the same, or bigger.
    when USE_TWO_WAY_MESSAGING:
      myrequest: ptr MsgBase
        ## The request message to which this message answers, if any.
        ## Platform-dependent; assumed 8 bytes in 64-bits and otherwise 4 bytes.
    when USE_SMALL_TIMESTAMPS:
      mytimestamp: Timestamp
        ## The message creation timestamp
        ## User-defined size; assumed 4 bytes in this case.
        ## Put after pointers, because we want the fields sorted by size,
        ## and it is either the same, or smaller.
    when USE_SMALL_SEQ_ID:
      myseqid: MsgSeqID
        ## The message sequence ID.
        ## Should be 4 bytes in this case.
    when USE_TWO_WAY_MESSAGING:
      mysender: QueueID
        ## The message sender. Only defined for two-way messaging.
        ## Should be 4 bytes with "topics", and 2 otherwise.
    when USE_TOPICS:
      myreceiver: QueueID
        ## The message receiver. Implicit, unless we use topics
        ## Should be 4 bytes with "topics", and 2 otherwise.
    when USE_TYPE_ID:
      mytypeid: MsgTypeID
        ## The message type ID.
        ## Should always be 2 bytes.
    when USE_URGENT_MARKER:
      myurgent: bool
        ## The message out-of-band (now/urgent) marker.

  Msg*[T: not (ref|string|seq)] = object
    ## A message with it's content
    mybase: MsgBase
      ## The message "base". We cannot "inherit", because it would introduce the RTTI overhead.
    content*: T
      ## The content of a message.

#static:
block:
  var tmpmsg: Msg[int]
  let mybaseAtStartOfMsg = pointer(addr tmpmsg.mybase) == pointer(addr tmpmsg)
  assert(mybaseAtStartOfMsg, "Msg.mybase not at start of Msg!")

when USE_TIMESTAMPS:
  proc timestamp*[T](msg: ptr Msg[T]): Timestamp {.inline, noSideEffect.} =
    ## The message creation timestamp.
    assert(msg != nil, "msg cannot be nil")
    msg.mybase.mytimestamp

when USE_MSG_SEQ_ID:
  proc seqid*[T](msg: ptr Msg[T]): MsgSeqID {.inline, noSideEffect.} =
    ## The message sequence ID.
    assert(msg != nil, "msg cannot be nil")
    msg.mybase.myseqid

when USE_TWO_WAY_MESSAGING:
  proc sender*[T](msg: ptr Msg[T]): QueueID {.inline, noSideEffect.} =
    ## The message sender. Only defined for two-way messaging.
    assert(msg != nil, "msg cannot be nil")
    msg.mybase.mysender

when USE_URGENT_MARKER:
  proc urgent*[T](msg: ptr Msg[T]): bool {.inline, noSideEffect.} =
    ## The message out-of-band (now/urgent) marker.
    assert(msg != nil, "msg cannot be nil")
    result = msg.mybase.myurgent

when USE_TOPICS:
  proc receiver*[T](msg: ptr Msg[T]): QueueID {.inline, noSideEffect.} =
    ## The message receiver. Implicit, unless we use topics
    assert(msg != nil, "msg cannot be nil")
    msg.mybase.myreceiver

when USE_TYPE_ID:
  proc typeid*[T](msg: ptr Msg[T]): MsgTypeID {.inline, noSideEffect.} =
    ## The message type ID.
    assert(msg != nil, "msg cannot be nil")
    msg.mybase.mytypeid

proc tid*(queue: QueueID): ThreadID {.inline, noSideEffect.} =
  ## Returns the ThreadID of a queue
  ThreadID(uint16(queue) and THREAD_ID_MASK)

proc pid*(queue: QueueID): ProcessID {.inline, noSideEffect.} =
  ## Returns the ProcessID of a queue
  ProcessID((uint16(queue) shr THREAD_BITS) and PROCESS_ID_MASK)

when USE_TOPICS:
  proc cid*(queue: QueueID): TopicID {.inline, noSideEffect.} =
    ## Returns the TopicID of a queue.
    ## Since tid() is the ThreadID, I had to use something else;
    ## Think of cid() as "category ID" ...
    TopicID((uint32(queue) shr THREAD_AND_PROCESS_BITS) and TOPIC_ID_MASK)

  proc queueID*(processID: ProcessID, threadID: ThreadID, topicID: TopicID): QueueID {.inline, noSideEffect.} =
    ## Returns the QueueID of a ThreadID in a ProcessID
    QueueID(uint32(uint16(threadID) and THREAD_ID_MASK) or (uint32(uint16(processID) and PROCESS_ID_MASK) shl THREAD_BITS) or
      (uint32(uint32(topicID) and TOPIC_ID_MASK) shl THREAD_AND_PROCESS_BITS))

  proc `$` *(queue: QueueID): string =
    ## String representation of a QueueID.
    $pid(queue) & "." & $tid(queue) & "." & $cid(queue)

else:
  proc queueID*(processID: ProcessID, threadID: ThreadID): QueueID {.inline, noSideEffect.} =
    ## Returns the QueueID of a ThreadID in a ProcessID
    QueueID(uint16(uint16(threadID) and THREAD_ID_MASK) or uint16((uint16(processID) and PROCESS_ID_MASK) shl THREAD_BITS))

  proc `$` *(queue: QueueID): string =
    ## String representation of a QueueID.
    $pid(queue) & "." & $tid(queue)


declVolatile(myProcessGlobalID, int, UNINIT_PROCESS_ID)
# My own (global) process ID

declVolatile(myProcessMapper, pointer, pointer(nil))
# Maps ProcessID to network address

declVolatile(myClusterPort, uint16, 0'u16)
# The Port used to communicate over the cluster.
# It is assumed, that all nodes use the same port.


var myLocalThreadID {.threadvar.}: int
  ## My own thread ID
var myInternalBuffer {.threadvar.}: ptr MsgBase
  ## "Internal" (same thread) message buffer.
var myInternalBufferSize {.threadvar.}: int
  ## "Internal" (same thread) message buffer current size.

when USE_TWO_WAY_MESSAGING:
  var myPendingRequests {.threadvar.}: HashSet[ptr MsgBase]
  myPendingRequests.init()

when USE_OUT_BUFFERS:
  var myOutgoingBuffer {.threadvar.}: array[0..MAX_THREADS-1, ptr MsgBase]
    ## Outgoing message buffers; one per thread.
    ## Since we want a compile-time defined array size, we use MAX_THREADS instead of MAX_CPU_THREADS.
  var myOutgoingBufferSize {.threadvar.}: int
    ## Outgoing message buffers total current size.

when USE_TOPICS:
  var currentTopicID {.threadvar.}: int
    ## Current topic ID
  when USE_TOPIC_SEQ:
    var topicSeqIDs {.threadvar.}: TableRef[TopicID, MsgSeqID]
      ## There can be many topics, so we don't want to pre-initialize a maximum-size array.
      ## Also, maybe the topics are "sparse", since they are user-defined,
      ## rather than "dense" in the lower-value range.

proc initThreadID*(tid: ThreadID): void =
  ## Initialises the ThreadID. Can only be called once!
  if myLocalThreadID != 0:
    raise newException(Exception, "ThreadID already initialised: " & $(myLocalThreadID - 1))
  myLocalThreadID = int(tid) + 1

when USE_TOPICS:
  proc initTopicID*(cid: TopicID): void =
    ## Initialises the TopicID. Should be called before processing any topic.
    currentTopicID = int(cid)

proc myProcessID*(): ProcessID {.inline.} =
  ## Returns the own process ID. Fails if not initialised.
  let pid = volatileLoad(myProcessGlobalID)
  assert(pid >= 0, "ProcessID uninitialised!")
  ProcessID(pid)

proc myThreadID*(): ThreadID {.inline.} =
  ## Returns the thread ID. Fails if not initialised.
  assert(myLocalThreadID > 0, "ThreadID uninitialised!")
  ThreadID(myLocalThreadID - 1)

when USE_TOPICS:
  proc myTopicID*(): TopicID {.inline.} =
    ## My topic ID
    TopicID(currentTopicID)
  when USE_TOPIC_SEQ and (MSG_SEQ_ID_TYPE != msitCluster64):
    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Topic.
      let t = myTopicID()
      if topicSeqIDs.isNil:
        topicSeqIDs = newTable[TopicID, MsgSeqID]()
      result = topicSeqIDs.getOrDefault(t) + 1
      assert(result > 0, "Maximum message sequence ID reached!")
      topicSeqIDs[t] = result

  when USE_TOPIC_SEQ and (MSG_SEQ_ID_TYPE == msitCluster64):
    const CLUSTER_SEQ_ID_BITS = uint64(sizeof(uint64) - sizeof(QueueID)) * 8'u64
    const CLUSTER_SEQ_ID_SEQ_MASK: uint64 = (1'u64 shl CLUSTER_SEQ_ID_BITS) - 1'u64
    const CLUSTER_SEQ_ID_QUEUE_MASK: uint64 = uint64(-1'i64) xor CLUSTER_SEQ_ID_SEQ_MASK
    when DEBUG_QUEUES:
      echo("CLUSTER_SEQ_ID_BITS: " & $CLUSTER_SEQ_ID_BITS)
      echo("CLUSTER_SEQ_ID_SEQ_MASK: " & toBin(CLUSTER_SEQ_ID_SEQ_MASK))
      echo("CLUSTER_SEQ_ID_QUEUE_MASK: " & toBin(CLUSTER_SEQ_ID_QUEUE_MASK))

    proc seqidProvider(q: QueueID): MsgSeqID =
      ## Generates a message sequence ID for the Cluster.
      let t = myTopicID()
      if topicSeqIDs.isNil:
        topicSeqIDs = newTable[TopicID, MsgSeqID]()
      result = topicSeqIDs.getOrDefault(t) + 1
      assert(result > 0, "Maximum message sequence ID reached!")
      topicSeqIDs[t] = result
      result = MsgSeqID(uint64(result) or ((uint64(q) and uint64(QUEUE_ID_MASK)) shl CLUSTER_SEQ_ID_BITS))

proc myQueueID*(): QueueID {.inline.} =
  ## My QueueID
  when USE_TOPICS:
    queueID(myProcessID(), myThreadID(), myTopicID())
  else:
    queueID(myProcessID(), myThreadID())


declVolatileArray(threadQueues, ptr MsgBase, MAX_THREADS)
# Declares a volatile, global array of ptr MsgBase, to serve as message queues.
# Since we want a compile-time defined array size, we use MAX_THREADS instead of MAX_CPU_THREADS.


proc flushMsgs*(): void =
  ## Flushes buffered outgoing messages, if any.
  when USE_OUT_BUFFERS:
    if myOutgoingBufferSize > 0:
      myOutgoingBufferSize = 0
      for tid in 0..MAX_CPU_THREADS-1:
        # myOutgoingBuffer[myThreadID()] should always be nil!
        let last = myOutgoingBuffer[tid]
        if last != nil:
          myOutgoingBuffer[tid] = nil
          var first = last
          while first.previous != nil:
            first = first.previous
          let tqP = threadQueues[tid]
          first.previous = volatileLoad(tqP)
          let prevMsgP = addr first.previous
          while not atomicCompareExchangeFull(tqP, prevMsgP, last):
            discard

when USE_OUT_BUFFERS:
  proc bufferOutgoing(tid: int, m: ptr MsgBase): void =
    ## Buffers outgoing messages.
    m.previous = myOutgoingBuffer[tid]
    myOutgoingBuffer[tid] = m
    myOutgoingBufferSize.inc
    if myOutgoingBufferSize >= OUTGOING_MSG_BUFFER_SIZE:
      flushMsgs()

proc sendMsgInternally(q: QueueID, m: ptr MsgBase, buffered: bool): void =
  ## Sends a message "internally". m cannot be nil.
  let tid = int(q.tid)
  if tid == int(myThreadID()):
    m.previous = myInternalBuffer
    myInternalBuffer = m
    myInternalBufferSize.inc
  else:
    when USE_OUT_BUFFERS:
      if buffered:
        bufferOutgoing(tid, m)
        return
    let tqP = threadQueues[tid]
    m.previous = volatileLoad(tqP)
    let prevMsgP = addr m.previous
    while not atomicCompareExchangeFull(tqP, prevMsgP, cast[ptr MsgBase](m)):
      discard

proc sendMsgInternally[T](q: QueueID, m: ptr Msg[T], buffered: bool): void =
  ## Sends a message "internally". m cannot be nil.
  sendMsgInternally(q, cast[ptr MsgBase](m), buffered)

when CLUSTER_SUPPORT:
  # Forward declaration:
  proc sendMsgExternally[T](q: QueueID, m: ptr Msg[T], size: uint32) {.async.}

proc fillAndSendMsg[T](q: QueueID, m: ptr Msg[T], buffered: bool): void =
  ## Sends a message. m cannot be nil.
  assert(m != nil, "cannot send nil message")
  when USE_TWO_WAY_MESSAGING:
    m.mybase.mysender = myQueueID()
    # New requests (those not replying to something) are tracked.
    if m.mybase.myrequest == nil:
      myPendingRequests.incl(cast[ptr MsgBase](m))
  when USE_TOPICS:
    m.mybase.myreceiver = q
  when USE_TIMESTAMPS:
    m.mybase.mytimestamp = timestampProvider()
  when USE_MSG_SEQ_ID:
    when USE_TWO_WAY_MESSAGING:
      m.mybase.myseqid = seqidProvider(m.mybase.mysender)
    else:
      m.mybase.myseqid = seqidProvider(myQueueID())
  if q.pid == myProcessID():
    when USE_URGENT_MARKER:
      m.mybase.myurgent = not buffered
    sendMsgInternally(q, m, buffered)
  else:
    assert(CLUSTER_SUPPORT, "Message for other process only allowed on cluster!")
    when CLUSTER_SUPPORT:
      when USE_URGENT_MARKER:
        # Assume all cluster messages are urgent ...
        m.mybase.myurgent = true
      let size = uint32(sizeof(Msg[T]))
      if size > IMPOSSIBLE_MSG_SIZE:
        raise newException(Exception, "Message too big (" & $uint(size) & " bytes)!")
      asyncCheck sendMsgExternally(q, m, size)

when USE_TYPE_ID:
  proc idOfType*(T: typedesc): MsgTypeID {.inline.} =
    ## Returns the ID of a type.
    let tid = messageTypeRegister.get(T).id()
    assert(int64(tid) <= int64(high(MsgTypeID)))
    MsgTypeID(tid)

  proc sendMsg*[T](q: QueueID, m: ptr Msg[T]): void {.inline.} =
    ## Sends a message. m cannot be nil.
    # TODO Type to make this only-once somehow.
    #let typeidOfT {.global.} = idOfType(T)
    let typeidOfT = idOfType(T)
    m.mybase.mytypeid = typeidOfT
    fillAndSendMsg[T](q, m, true)

  proc sendMsgNow*[T](q: QueueID, m: ptr Msg[T]): void {.inline.} =
    ## Sends a message immediatly, bypassing any buffer. m cannot be nil.
    # TODO Type to make this only-once somehow.
    #let typeidOfT {.global.} = idOfType(T)
    let typeidOfT = idOfType(T)
    m.mybase.mytypeid = typeidOfT
    fillAndSendMsg[T](q, m, false)

else:
  proc sendMsg*[T](q: QueueID, m: ptr Msg[T]): void {.inline.} =
    ## Sends a message. m cannot be nil.
    fillAndSendMsg[T](q, m, true)

  proc sendMsgNow*[T](q: QueueID, m: ptr Msg[T]): void {.inline.} =
    ## Sends a message immediatly, bypassing any buffer. m cannot be nil.
    fillAndSendMsg[T](q, m, false)

when USE_TWO_WAY_MESSAGING:
  proc replyWith*[Q,A](request: ptr Msg[Q], reply: ptr Msg[A]): void =
    ## Sends a reply message. request and reply cannot be nil.
    assert(request != nil, "request cannot be nil")
    assert(reply != nil, "reply cannot be nil")
    reply.mybase.myrequest = addr request.mybase
    sendMsg(request.mybase.mysender, reply)

  proc replyNowWith*[Q,A](request: ptr Msg[Q], reply: ptr Msg[A]): void =
    ## Sends a reply message immediatly, bypassing any buffer. request and reply cannot be nil.
    assert(request != nil, "request cannot be nil")
    assert(reply != nil, "reply cannot be nil")
    reply.mybase.myrequest = addr request.mybase
    sendMsgNow(request.mybase.mysender, reply)

when USE_TWO_WAY_MESSAGING:
  proc validateRequest(msg: ptr MsgBase): bool =
    ## Validates the request field of a received message.
    let r = cast[ptr MsgBase](msg.myrequest)
    if r != nil:
      # We got a reply to something.
      result = myPendingRequests.contains(r)
      myPendingRequests.excl(r)
    else:
      result = true

  proc replyPending*[T](m: ptr Msg[T]): bool =
    ## Is m one of our requests, for which a reply is pending?
    myPendingRequests.contains(cast[ptr MsgBase](m))

proc collectReceived(msg: ptr MsgBase, collected: var seq[ptr MsgBase]) =
  ## Follow the linked list of messages, adding each valid message to collected.
  var m = msg
  while m != nil:
    when USE_TWO_WAY_MESSAGING:
      if validateRequest(m):
        collected.add(m)
    else:
      collected.add(m)
    m = m.previous

proc recvMsgs*(): seq[ptr MsgBase] =
  ## Receives messages, if any, from the own queue.
  ## Returns messages in *reverse* order of arrival.
  flushMsgs()
  result = newSeq[ptr MsgBase]()
  let tqP = threadQueues[int(myThreadID())]
  collectReceived(atomicExchangeFull(tqP, nil), result)

proc recvMsgs*(waitInSecs: float, wait: proc (s: int): void = sleep): seq[ptr MsgBase] =
  ## Receives messages from the own queue, if any.
  ## Returns messages in *reverse* order of arrival.
  if myInternalBufferSize > 0:
    result = newSeq[ptr MsgBase](myInternalBufferSize)
    collectReceived(myInternalBuffer, result)
    myInternalBuffer = nil
    myInternalBufferSize = 0
  else:
    flushMsgs()
    let tqP = threadQueues[int(myThreadID())]
    # sleep "resolution" is waitInSecs/10 in ms
    let slp = max(int(waitInSecs * (1000.0/10.0)), 1)
    let until = cpuTime() + waitInSecs
    var m = atomicExchangeFull(tqP, nil)
    if waitInSecs > 0:
      # Warning: No locks; busy wait!
      while (m == nil) and (cpuTime() < until):
        wait(slp)
        m = atomicExchangeFull(tqP, nil)
    result = newSeq[ptr MsgBase](0)
    collectReceived(m, result)

proc pendingMsg*(): bool =
  ## Returns true, if there are currently pending incomming messages.
  (myInternalBufferSize > 0) or (volatileLoad(threadQueues[int(myThreadID())]) != nil)

proc initProcessPID(pid: ProcessID): void =
  ## Initialises the process PID. Must be called exactly once!
  var expectedPID = UNINIT_PROCESS_ID
  let prevPID = addr expectedPID
  if not atomicCompareExchangeFull(myProcessGlobalID, prevPID, int(pid)):
    raise newException(Exception, "ProcessID already initialised: " & $expectedPID)

when CLUSTER_SUPPORT:
  var myPeers: TableRef[ProcessID, AsyncSocket]
    ## The peer ProcessID to AsyncSocket map

  var runForeverThreadThread: Thread[tuple[port: Port, address: NotAString]]
    ## The thread of "asyncdispatch".

  proc peers(): TableRef[ProcessID, AsyncSocket] =
    ## Returns the "peers" table.
    if myPeers == nil:
      myPeers = newTable[ProcessID, AsyncSocket]()
    result = myPeers

  proc descSocket(asock: AsyncSocket): string =
    ## Describe a socket for logging purpose.
    var domain: Domain
    var localAddr: string
    var localPort: Port
    var remoteAddr: string
    var remotePort: Port
    try:
      let socket = asock.getFd()
      domain = socket.getSockDomain()
      try:
        (localAddr, localPort) = socket.getLocalAddr(domain)
      except:
        discard
      try:
        (remoteAddr, remotePort) = socket.getPeerAddr(domain)
      except:
        discard
    except:
      discard
    result = "Local: " & localAddr & ":" & $localPort & ", Remote: " & remoteAddr & ":" & $remotePort

  proc initPeerConnection(peerProcess: ProcessID, asock: AsyncSocket): PeerConnection =
    let socket = asock.getFd()
    result.domain = socket.getSockDomain()
    let (localAddr, localPort) = socket.getLocalAddr(result.domain)
    let (remoteAddr, remotePort) = socket.getPeerAddr(result.domain)
    result.localAddr = localAddr
    result.localPort = localPort
    result.remoteAddr = remoteAddr
    result.remotePort = remotePort
    result.pid = peerProcess
    result.sock = asock
    when MSG_SEQ_ID_PER_THREAD:
      result.lastseqid = new array[uint64,MAX_THREADS]
    result.valid = true

  proc closePeer(peerProcess: ProcessID, peer: AsyncSocket) =
    ## Closes a peer process, if connected.
    var sock = peer
    if peers().take(peerProcess, sock):
      if peerProcess != myProcessID():
        echo("Closing peer " & $peerProcess & "; " & descSocket(sock))
    if sock != nil:
      try:
        sock.close()
      except:
        discard

  proc registerPeer(peer: PeerConnection) =
    ## Reads one message from the peer.
    # Just in case ...
    closePeer(peer.pid, nil)
    echo("Peer " & $peer & " connected.")
    peers()[peer.pid] = peer.sock

  proc readUint32(peer: AsyncSocket): Future[uint32] {.async.} =
    # Reads a "network order" uint32 from the socket.
    var netint: uint32 = 0
    let bytesRead = await peer.recvInto(addr netint, 4)
    if bytesRead != 4:
      raise newException(Exception, "Fail to read uint32!")
    result = ntohl(netint)

  proc writeUint32(peer: AsyncSocket, value: uint32) {.async.} =
    # Writes a "network order" uint32 to the socket.
    var netint: uint32 = htonl(value)
    await peer.send(addr netint, 4)

  proc validateReadMsg(peer: PeerConnection, msg: ptr MsgBase, receiver: QueueID) =
    ## Makes sure the message is valid.
    when USE_TWO_WAY_MESSAGING:
      let spid = msg.mysender.pid
      if spid != peer.pid:
        raise newException(Exception, "Wrong Message sender PID! Expected: " &
          $peer.pid & ", but received: " & $spid)
      # msg.myrequest is validated in the recvMsgs() method, as this must
      # happen within the receiving thread.
    when USE_TIMESTAMPS:
      timestampValidator(msg.mytimestamp)
    let rpid = receiver.pid
    if rpid != myProcessID():
      raise newException(Exception, "Wrong Message receiver PID! Expected: " &
        $myProcessID() & ", but received: " & $rpid)
    let tid = int(receiver.tid)
    if (tid < 0) or (tid >= MAX_CPU_THREADS):
      raise newException(Exception, "Wrong Message receiver TID! Expected between: [0, " &
        $MAX_CPU_THREADS & "[, but received: " & $tid)
    when USE_TYPE_ID:
      if messageTypeRegister.find(TypeID(msg.mytypeid)).isNone:
        raise newException(Exception, "Wrong/Unknown Message type ID: " & $msg.mytypeid)
    when USE_URGENT_MARKER:
      # Assume all cluster messages are urgent ...
      msg.myurgent = true
    when USE_MSG_SEQ_ID:
      # Only validate, if we have already received one message.
      when MSG_SEQ_ID_PER_PROCESS:
        if peer.lastseqid > 0'u64:
          if uint64(msg.myseqid) <= peer.lastseqid:
            raise newException(Exception, "Wrong Message seq ID! Expected: " &
              $(peer.lastseqid + 1) & ", but received: " & $msg.myseqid)
      when USE_TWO_WAY_MESSAGING and not MSG_SEQ_ID_PER_PROCESS:
        # Without sender, no way to validate thread seq ID
        when MSG_SEQ_ID_PER_THREAD:
          let stid = int(msg.mysender.tid)
          let lastseqid = peer.lastseqid[stid]
          if lastseqid > 0'u64:
            if msg.myseqid <= lastseqid:
              raise newException(Exception, "Wrong Message seq ID! Expected: " &
                $(lastseqid + 1) & ", but received: " & $msg.myseqid)

  # Forward decalaration:
  proc openPeerConnection(pid: ProcessID): Future[AsyncSocket] {.async.}

  proc sendMsgExternally[T](q: QueueID, m: ptr Msg[T], size: uint32) {.async.} =
    ## Sends a message "externally", across the cluster. m cannot be nil.
    # Note: this proc needed to be "forward declared".
    let pid = q.pid
    var sock: AsyncSocket
    sock = peers()[pid]
    if sock == nil:
      sock = await openPeerConnection(pid)
    await writeUint32(sock, size)
    let expected = int(size - MSG_PREVIOUS_OVERHEAD)
    var msgData = cast[pointer](cast[ByteAddress](m) +% MSG_PREVIOUS_OVERHEAD)
    await sock.send(msgData, expected)

  proc readMsg(peer: PeerConnection): Future[uint64] {.async.} =
    ## Reads one message from the peer.
    var size = await readUint32(peer.sock)
    if size > IMPOSSIBLE_MSG_SIZE:
      raise newException(Exception, "Message too big (" & $size & " bytes)!")
    var msg = allocShared0(size)
    try:
      let expected = int(size - MSG_PREVIOUS_OVERHEAD)
      var msgData = cast[pointer](cast[ByteAddress](msg) +% MSG_PREVIOUS_OVERHEAD)
      let bytesRead = await peer.sock.recvInto(msgData, expected)
      if (bytesRead < 0) or (bytesRead != expected):
        raise newException(Exception, "Fail to read full message (" & $size & " bytes)!")
      var msg2 = cast[ptr MsgBase](msg)
      var receiver: QueueID
      when USE_TOPICS:
        receiver = msg2.myreceiver
      else:
        receiver = QueueID(await readUint32(peer.sock))
      validateReadMsg(peer, msg2, receiver)
      when USE_MSG_SEQ_ID:
        result = uint64(msg2.myseqid)
      sendMsgInternally(receiver, msg2, false)
      msg = nil
    finally:
      if msg != nil:
        # Failure! Prevent memory leaks!
        deallocShared(msg)

  proc processPeerLoop(pc: PeerConnection) {.async.} =
    ## Processes a cluster peer connection (needed due to compiler bug).
    var peer = pc
    let loop = peer.valid
    while loop:
      when USE_MSG_SEQ_ID:
        # Update lastseqid of PeerConnection
        peer.lastseqid = await readMsg(peer)
      else:
        await readMsg(peer)

  proc processPeer(sock: AsyncSocket) {.async.} =
    ## Processes a cluster peer connection
    let myProc = myProcessID()
    var peer: PeerConnection
    try:
      let magic = await readUint32(peer.sock)
      let version = await readUint32(peer.sock)
      let procid = await readUint32(peer.sock)
      if (magic == MAGIC) and (version == VERSION) and (procid <= high(ProcessID)) and
        (procid != uint32(myProc)) and (procid != uint32(myProc)):
        peer = initPeerConnection(ProcessID(procid), sock)
        registerPeer(peer)
      await processPeerLoop(peer)
    finally:
      closePeer(peer.pid, sock)

  proc mapPID2Address(pid: ProcessID): (string, Port) {.gcSafe.} =
    ## Opens a connection to another peer.
    let m: pointer = volatileLoad(myProcessMapper)
    let mapper = cast[ProcessIDToAddress](m)
    assert(mapper != nil, "Process Mapper uninitialised!")
    var port = Port(volatileLoad(myClusterPort))
    assert(port != Port(0), "Cluster Port uninitialised!")
    var address: NotAString
    mapper(pid, port, address)
    result = ($address, port)

  proc openPeerConnection(pid: ProcessID): Future[AsyncSocket] {.async.} =
    ## Opens a connection to another peer.
    let (address, port) = mapPID2Address(pid)
    if (address == nil) or (len(address) == 0):
      raise newException(Exception, "Process Mapper returned empty address for ProcessID: " & $pid)
    let sock = await asyncnet.dial(address, port)
    await sock.writeUint32(MAGIC)
    await sock.writeUint32(VERSION)
    await sock.writeUint32(uint32(myProcessID()))
    asyncCheck processPeer(sock)
    result = sock

  proc initCluster(port: Port, address: string) {.async.} =
    ## Initiates the cluster networking.
    var server = newAsyncSocket()
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(port, address)
    server.listen()

    while true:
      let peer = await server.accept()
      asyncCheck processPeer(peer)

  proc runForeverThread(t: tuple[port: Port, address: NotAString]) {.thread.} =
    ## Executes runForever() in a separate thread.
    asyncCheck initCluster(t.port, $t.address)
    runForever()

  proc initProcess*(pid: ProcessID, processMapper: ProcessIDToAddress): void =
    ## Initialises the process. Must be called exactly once!
    if processMapper == nil:
      raise newException(Exception, "processMapper cannot be nil")
    initProcessPID(pid)
    var port: Port
    var address: NotAString
    processMapper(pid, port, address)
    if int(port) == 0:
      raise newException(Exception, "Process Mapper returned Port 0 for ProcessID: " & $pid)
    let address2 = $address
    if (address2 == nil) or (len(address2) == 0):
      raise newException(Exception, "Process Mapper returned empty address for ProcessID: " & $pid)
    var expectedMapper: pointer = nil
    let prevMapper = addr expectedMapper
    if not atomicCompareExchangeFull(myProcessMapper, prevMapper, processMapper):
      raise newException(Exception, "Process Mapper already initialised")
    var expectedClusterPort = 0'u16
    let prevClusterPort = addr expectedClusterPort
    if not atomicCompareExchangeFull(myClusterPort, prevClusterPort, uint16(port)):
      raise newException(Exception, "Cluster Port already initialised")
    createThread(runForeverThreadThread, runForeverThread, (port, address))
else:
  proc initProcess*(pid: ProcessID): void =
    ## Initialises the process. Must be called exactly once!
    initProcessPID(pid)
