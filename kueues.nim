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

import osproc
import math
import algorithm
import times
import os
import typetraits
import strutils
import hashes
import tables

import atomiks
import typerekjister

import ./kueues_config

export hash, `==`


const USE_MSG_SEQ_ID = (MSG_SEQ_ID_TYPE != MsgSeqIDTypeEnum.msitNone)
  ## Do we use message sequence IDs?

const USE_OUT_BUFFERS = (OUTGOING_MSG_BUFFER_SIZE > 0)
  ## Do we use outgoing messages buffers?

when DEBUG_QUEUES:
  from gethutil import toBin
  echo("DEBUG_QUEUES: " & $DEBUG_QUEUES)
  echo("USE_TOPICS: " & $USE_TOPICS)
  echo("USE_TYPE_ID: " & $USE_TYPE_ID)
  echo("USE_TIMESTAMPS: " & $USE_TIMESTAMPS)
  echo("USE_TWO_WAY_MESSAGING: " & $USE_TWO_WAY_MESSAGING)
  echo("USE_OOB_MARKER: " & $USE_OOB_MARKER)
  echo("MAX_THREADS: " & $MAX_THREADS)
  when USE_TOPICS:
    echo("MAX_TOPICS: " & $MAX_TOPICS)
  echo("OUTGOING_MSG_BUFFER_SIZE: " & $OUTGOING_MSG_BUFFER_SIZE)
  echo("USE_MSG_SEQ_ID: " & $USE_MSG_SEQ_ID)
  when USE_MSG_SEQ_ID:
    echo("MSG_SEQ_ID_TYPE: " & $MSG_SEQ_ID_TYPE)

static:
  assert(isPowerOfTwo(MAX_THREADS), "MAX_THREADS must be power of two: " & $MAX_THREADS)
  assert((MAX_THREADS <= 256), "MAX_THREADS currently limited to 256: " & $MAX_THREADS)

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

static:
  assert(isPowerOfTwo(MAX_PROCESSES), "MAX_PROCESSES must be power of two: " & $MAX_PROCESSES)
  assert((MAX_THREADS * MAX_PROCESSES <= 65536), "MAX_THREADS * MAX_PROCESSES must not be > 65536")

when DEBUG_QUEUES:
  echo("MAX_PROCESSES: " & $MAX_PROCESSES)

const THREAD_BITS = countBits32(MAX_THREADS-1)
  ## Number of bits to represent the thread ID.
const PROCESS_BITS = countBits32(MAX_PROCESSES-1)
  ## Number of bits to represent the process ID.
const THREAD_AND_PROCESS_BITS = THREAD_BITS + PROCESS_BITS
  ## Number of bits to represent the process and thread ID.

const THREAD_ID_MASK = uint16(MAX_THREADS-1)
  ## Bit-Mask to extract Thread IDs from a QueueID
const PROCESS_ID_MASK = uint16(MAX_PROCESSES-1)
  ## Bit-Mask to extract Process IDs from a QueueID

when USE_TOPICS:
  const TOPIC_ID_MASK = uint32(MAX_TOPICS-1)
    ## Bit-Mask to extract Topic IDs from a QueueID

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

when USE_TOPICS:
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
else:
  type
    QueueID* = distinct uint16
      ## The complete queue ID, containing the process ID and thread ID.

proc `==` *(a, b: QueueID): bool {.borrow.}
proc `$` *(id: QueueID): string {.borrow.}

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
else:
  const USE_BIG_TIMESTAMPS: bool = false
  const USE_SMALL_TIMESTAMPS: bool = false

when USE_MSG_SEQ_ID:
  const USE_SMALL_SEQ_ID: bool = (MSG_SEQ_ID_TYPE == msitPerTopic32) or
    (MSG_SEQ_ID_TYPE == msitPerThread32) or (MSG_SEQ_ID_TYPE == msitPerProcess32)
  const USE_BIG_SEQ_ID: bool = (MSG_SEQ_ID_TYPE == msitPerTopic64) or
    (MSG_SEQ_ID_TYPE == msitPerThread64) or (MSG_SEQ_ID_TYPE == msitPerProcess64)
  static:
    assert(USE_BIG_SEQ_ID or USE_SMALL_SEQ_ID, "Unsupported MSG_SEQ_ID_TYPE (" & $MSG_SEQ_ID_TYPE & ")")
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
    proc seqidProvider(): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      inc myThreadSeqID
      result = myThreadSeqID
      assert(result > 0, "Maximum message sequence ID reached!")

  when MSG_SEQ_ID_TYPE == msitPerProcess64:
    declVolatile(myProcessGlobalSeqID, MsgSeqID, MsgSeqID(0))
    # Current (global) per Process message sequence ID.
    proc seqidProvider(): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      result = atomicIncRelaxed(myProcessGlobalSeqID)
      assert(result > 0, "Maximum message sequence ID reached!")

when USE_SMALL_SEQ_ID:
  type
    MsgSeqID* = int32
      ## The type of the message sequence ID.
  when MSG_SEQ_ID_TYPE == msitPerThread32:
    var myThreadSeqID {.threadvar.}: MsgSeqID
      ## Current message sequence ID for the Thread.
    proc seqidProvider(): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      inc myThreadSeqID
      result = myThreadSeqID
      assert(result > 0, "Maximum message sequence ID reached!")

  when MSG_SEQ_ID_TYPE == msitPerProcess32:
    declVolatile(myProcessGlobalSeqID, MsgSeqID, MsgSeqID(0))
    # Current (global) per Process message sequence ID.
    proc seqidProvider(): MsgSeqID =
      ## Generates a message sequence ID for the Thread.
      result = atomicIncRelaxed(myProcessGlobalSeqID)
      assert(result > 0, "Maximum message sequence ID reached!")

type
  MsgBase* = object
    ## The base of a message, without the "content"
    when USE_BIG_TIMESTAMPS:
      mytimestamp: Timestamp
        ## The message creation timestamp
        ## User-defined size; assumed 8/16 bytes in this case.
        ## Put before pointers, because we want the fields sorted by size,
        ## and it is either the same, or bigger.
    when USE_BIG_SEQ_ID:
      myseqid: MsgSeqID
        ## The message sequence ID.
        ## Should be 8 bytes in this case.
    previous: ptr[MsgBase]
      ## The previous message sent to this queue, if any.
      ## Should not be visible from API consumers.
      ## Platform-dependent; assumed 8 bytes in 64-bits and otherwise 4 bytes.
    when USE_TWO_WAY_MESSAGING:
      myrequest: ptr[MsgBase]
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
    QueueID(uint32(threadID) or (uint32(processID) shl THREAD_BITS) or (uint32(topicID) shl THREAD_AND_PROCESS_BITS))

  proc `$` *(queue: QueueID): string =
    ## String representation of a QueueID.
    let p = $pid(queue)
    let tt: ThreadID = tid(queue)
    let t = $tt
    let c = $cid(queue)
    p & "." & t & "." & c

else:
  proc queueID*(processID: ProcessID, threadID: ThreadID): QueueID {.inline, noSideEffect.} =
    ## Returns the QueueID of a ThreadID in a ProcessID
    QueueID(uint16(threadID) or uint16(processID shl THREAD_BITS))

  proc `$` *(queue: QueueID): string =
    ## String representation of a QueueID.
    $pid(queue) & "." & $tid(queue)

declVolatile(myProcessGlobalID, int, UNINIT_PROCESS_ID)
# My own (global) process ID

var myLocalThreadID {.threadvar.}: int
  ## My own thread ID
var myInternalBuffer {.threadvar.}: ptr[MsgBase]
  ## "Internal" (same thread) message buffer.
var myInternalBufferSize {.threadvar.}: int
  ## "Internal" (same thread) message buffer current size.

when USE_OUT_BUFFERS:
  var myOutgoingBuffer {.threadvar.}: array[0..MAX_THREADS-1, ptr[MsgBase]]
    ## Outgoing message buffers; one per thread.
    ## Since we want a compile-time defined array size, we use MAX_THREADS instead of MAX_CPU_THREADS.
  var myOutgoingBufferSize {.threadvar.}: int
    ## Outgoing message buffers total current size.

when USE_TOPICS:
  var currentTopicID {.threadvar.}: int
    ## Current topic ID
  const USE_TOPIC_SEQ = USE_MSG_SEQ_ID and ((MSG_SEQ_ID_TYPE == msitPerTopic32) or (MSG_SEQ_ID_TYPE == msitPerTopic64))
    ## Do we use topices and message sequence IDs together?
  when USE_TOPIC_SEQ:
    var topicSeqIDs {.threadvar.}: TableRef[TopicID, MsgSeqID]
      ## There can be many topics, so we don't want to pre-initialize a maximum-size array.
      ## Also, maybe the topics are "sparse", since they are user-defined,
      ## rather than "dense" in the lower-value range.

proc initProcessID*(pid: ProcessID): void =
  ## Initialises the ProcessID. Can only be called once!
  var expectedPID = UNINIT_PROCESS_ID
  let prevPID = addr expectedPID
  if not atomicCompareExchangeFull(myProcessGlobalID, prevPID, int(pid)):
    raise newException(Exception, "ProcessID already initialised: " & $expectedPID)

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
  when USE_TOPIC_SEQ:
    proc seqidProvider(): MsgSeqID =
      ## Generates a message sequence ID for the Topic.
      let t = myTopicID()
      if topicSeqIDs.isNil:
        topicSeqIDs = newTable[TopicID, MsgSeqID]()
      result = topicSeqIDs.getOrDefault(t) + 1
      assert(result > 0, "Maximum message sequence ID reached!")
      topicSeqIDs[t] = result

proc myQueueID*(): QueueID {.inline.} =
  ## My QueueID
  when USE_TOPICS:
    queueID(myProcessID(), myThreadID(), myTopicID())
  else:
    queueID(myProcessID(), myThreadID())


declVolatileArray(threadQueues, ptr[MsgBase], MAX_THREADS)
# Declares a volatile, global array of ptr[MsgBase], to serve as message queues.
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

proc sendMsg2[T](q: QueueID, m: ptr[Msg[T]], buffered: bool = true): void =
  ## Sends a message. m cannot be nil.
  assert(m != nil, "cannot send nil message")
  assert(q.pid == myProcessID(), "TODO: distributed messaging not currently implemented")
  let tid = int(q.tid)
  when USE_TWO_WAY_MESSAGING:
    m.mybase.mysender = myQueueID()
  when USE_TOPICS:
    m.mybase.myreceiver = q
  when USE_TIMESTAMPS:
    m.mybase.mytimestamp = timestampProvider()
  when USE_MSG_SEQ_ID:
    m.mybase.myseqid = seqidProvider()
  when USE_URGENT_MARKER:
    m.mybase.myurgent = not buffered
  if tid == int(myThreadID()):
    m.mybase.previous = myInternalBuffer
    myInternalBuffer = addr m.mybase
    myInternalBufferSize.inc
  else:
    when USE_OUT_BUFFERS:
      if buffered:
        m.mybase.previous = myOutgoingBuffer[tid]
        myOutgoingBuffer[tid] = addr m.mybase
        myOutgoingBufferSize.inc
        if myOutgoingBufferSize >= OUTGOING_MSG_BUFFER_SIZE:
          flushMsgs()
        return
    let tqP = threadQueues[tid]
    m.mybase.previous = volatileLoad(tqP)
    let prevMsgP = addr m.mybase.previous
    while not atomicCompareExchangeFull(tqP, prevMsgP, cast[ptr[MsgBase]](m)):
      discard

when USE_TYPE_ID:
  proc idOfType*(T: typedesc): MsgTypeID {.inline.} =
    ## Returns the ID of a type.
    let tid = messageTypeRegister.get(T).id()
    assert(int64(tid) <= int64(high(MsgTypeID)))
    MsgTypeID(tid)

  proc sendMsg*[T](q: QueueID, m: ptr[Msg[T]]): void {.inline.} =
    ## Sends a message. m cannot be nil.
    let typeidOfT {.global.} = idOfType(T)
    m.mybase.mytypeid = typeidOfT
    sendMsg2[T](q, m)

  proc sendMsgNow*[T](q: QueueID, m: ptr[Msg[T]]): void {.inline.} =
    ## Sends a message immediatly, bypassing any buffer. m cannot be nil.
    let typeidOfT {.global.} = idOfType(T)
    m.mybase.mytypeid = typeidOfT
    sendMsg2[T](q, m, false)

else:
  proc sendMsg*[T](q: QueueID, m: ptr[Msg[T]]): void {.inline.} =
    ## Sends a message. m cannot be nil.
    sendMsg2[T](q, m)

  proc sendMsgNow*[T](q: QueueID, m: ptr[Msg[T]]): void {.inline.} =
    ## Sends a message immediatly, bypassing any buffer. m cannot be nil.
    sendMsg2[T](q, m, false)

when USE_TWO_WAY_MESSAGING:
  proc replyWith*[Q,A](request: ptr[Msg[Q]], reply: ptr[Msg[A]]): void =
    ## Sends a reply message. request and reply cannot be nil.
    assert(request != nil, "request cannot be nil")
    assert(reply != nil, "reply cannot be nil")
    reply.mybase.myrequest = addr request.mybase
    sendMsg(request.mybase.mysender, reply)

  proc replyNowWith*[Q,A](request: ptr[Msg[Q]], reply: ptr[Msg[A]]): void =
    ## Sends a reply message immediatly, bypassing any buffer. request and reply cannot be nil.
    assert(request != nil, "request cannot be nil")
    assert(reply != nil, "reply cannot be nil")
    reply.mybase.myrequest = addr request.mybase
    sendMsgNow(request.mybase.mysender, reply)

proc recvMsgs*(): seq[ptr[MsgBase]] =
  ## Receives messages, if any, from the own queue.
  ## Returns messages in *reverse* order of arrival.
  flushMsgs()
  result = newSeq[ptr[MsgBase]]()
  let tqP = threadQueues[int(myThreadID())]
  var m = atomicExchangeFull(tqP, nil)
  while m != nil:
    result.add(m)
    m = m.previous

proc recvMsgs*(waitInSecs: float, wait: proc (s: int): void = sleep): seq[ptr[MsgBase]] =
  ## Receives messages from the own queue, if any.
  ## Returns messages in *reverse* order of arrival.
  if myInternalBufferSize > 0:
    result = newSeq[ptr[MsgBase]](myInternalBufferSize)
    var m = myInternalBuffer
    while m != nil:
      result.add(m)
      m = m.previous
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
    result = newSeq[ptr[MsgBase]](0)
    while m != nil:
      result.add(m)
      m = m.previous

proc pendingMsg*(): bool =
  ## Returns true, if there are currently pending incomming messages.
  (myInternalBufferSize > 0) or (volatileLoad(threadQueues[int(myThreadID())]) != nil)
