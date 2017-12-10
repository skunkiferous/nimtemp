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

import atomiks
import typerekjister

import ./kueues_config

when DEBUG_QUEUES:
  from gethutil import toBin
  echo("DEBUG_QUEUES: " & $DEBUG_QUEUES)
  echo("USE_TOPICS: " & $USE_TOPICS)
  echo("USE_TYPE_ID: " & $USE_TYPE_ID)
  echo("USE_TIMESTAMPS: " & $USE_TIMESTAMPS)
  echo("TWO_WAY_MESSAGING: " & $TWO_WAY_MESSAGING)
  echo("MAX_THREADS: " & $MAX_THREADS)
  when USE_TOPICS:
    echo("MAX_TOPICS: " & $MAX_TOPICS)

static:
  assert(isPowerOfTwo(MAX_THREADS), "MAX_THREADS must be power of two: " & $MAX_THREADS)
  assert((MAX_THREADS <= 256), "MAX_THREADS currently limited to 256: " & $MAX_THREADS)

when USE_TIMESTAMPS:
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

type
  ThreadID* = range[0..MAX_THREADS-1]
    ## Thread ID, within process.
  ProcessID* = range[0..MAX_PROCESSES-1]
    ## Process ID of thread.

when USE_TOPICS:
  type
    TopicID* = range[0..MAX_TOPICS-1]
      ## QueueID, within thread.
    QueueID* = distinct uint32
      ## The complete queue ID, containing the process ID, thread ID, and topic ID.
else:
  type
    QueueID* = distinct uint16
      ## The complete queue ID, containing the process ID and thread ID.

proc `==` *(a, b: QueueID): bool {.borrow.}
proc `$` *(a: QueueID): string {.borrow.}

when DEBUG_QUEUES:
  echo("ThreadID: range[0.." & $(MAX_THREADS-1) & "]")
  echo("ProcessID: range[0.." & $(MAX_PROCESSES-1) & "]")
  when USE_TOPICS:
    echo("TopicID: range[0.." & $(MAX_TOPICS-1) & "]")
  echo("QueueID: uint" & $(8 * sizeof(QueueID)))

type
  MsgBase* = object
    ## The base of a message, without the "content"
    previous: ptr[MsgBase]
      ## The previous message sent to this queue, if any.
      ## Should not be visible from API consumers.
    when TWO_WAY_MESSAGING:
      sender*: QueueID
        ## The message sender. Only defined for two-way messaging.
      request: ptr[MsgBase]
        ## The request message to which this message answers, if any.
    when USE_TOPICS:
      receiver*: QueueID
        ## The message receiver. Implicit, unless we use topics
    when USE_TIMESTAMPS:
      timestamp: Timestamp
        ## The message creation timestamp
    when USE_TYPE_ID:
      typeid: TypeID
        ## The message type ID

  Msg*[T: not (ref|string|seq)] = object
    ## A message with it's content
    base*: MsgBase
      ## The message "base". We cannot "inherit", because it would introduce the RTTI overhead.
    content*: T
      ## The content of a message.

proc tid*(queue: QueueID): ThreadID {.inline.} =
  ## Returns the ThreadID of a queue
  ThreadID(uint16(queue) and THREAD_ID_MASK)

proc pid*(queue: QueueID): ProcessID {.inline.} =
  ## Returns the ProcessID of a queue
  ProcessID((uint16(queue) shr THREAD_BITS) and PROCESS_ID_MASK)

when USE_TOPICS:
  proc cid*(queue: QueueID): TopicID {.inline.} =
    ## Returns the TopicID of a queue.
    ## Since tid() is the ThreadID, I had to use something else;
    ## Think of cid() as "category ID" ...
    TopicID((uint32(queue) shr THREAD_AND_PROCESS_BITS) and TOPIC_ID_MASK)

  proc queue*(processID: ProcessID, threadID: ThreadID, topicID: TopicID): QueueID {.inline.} =
    ## Returns the QueueID of a ThreadID in a ProcessID
    QueueID(uint32(threadID) or uint32(processID shl THREAD_BITS) or uint32(topicID shl THREAD_AND_PROCESS_BITS))
else:
  proc queue*(processID: ProcessID, threadID: ThreadID): QueueID {.inline.} =
    ## Returns the QueueID of a ThreadID in a ProcessID
    QueueID(uint16(threadID) or uint16(processID shl THREAD_BITS))

declVolatile(myProcessGlobalID, int, UNINIT_PROCESS_ID)
# My own (global) process ID

var myLocalThreadID {.threadvar.}: int
  ## My own thread ID

when USE_TOPICS:
  var currentTopicID {.threadvar.}: int
    ## Current topic ID

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
  myLocalThreadID = tid + 1

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

proc myQueueID*(): QueueID {.inline.} =
  ## My QueueID
  when USE_TOPICS:
    queue(myProcessID(), myThreadID(), myTopicID())
  else:
    queue(myProcessID(), myThreadID())


declVolatileArray(threadQueues, ptr[MsgBase], MAX_THREADS)
# Declares a volatile, global array of ptr[MsgBase], to serve as message queues.
# Since we want a compile-time defined array size, we use MAX_THREADS instead of MAX_CPU_THREADS.


proc sendMsg2[T](q: QueueID, m: ptr[Msg[T]]): void =
  ## Sends a message. m cannot be nil.
  assert(m != nil, "cannot send nil message")
  assert(q.pid == myProcessID(), "TODO: distributed messaging not currently implemented")
  when TWO_WAY_MESSAGING:
    m.base.sender = myQueueID()
  when USE_TOPICS:
    m.base.receiver = q
  when USE_TIMESTAMPS:
    m.base.timestamp = timestampProvider()
  let tqP = threadQueues[int(q.tid)]
  m.base.previous = volatileLoad(tqP)
  let prevMsgP = addr m.base.previous
  while not atomicCompareExchangeFull(tqP, prevMsgP, cast[ptr[MsgBase]](m)):
    discard

when USE_TYPE_ID:
  proc idOfType*(T: typedesc): TypeID {.inline.} =
    ## Returns the ID of a type.
    # FIXME!
    messageTypeRegister.get(T).id()
    #TypeID(hash(T.name))

  proc sendMsg*[T](q: QueueID, m: ptr[Msg[T]]): void {.inline.} =
    ## Sends a message. m cannot be nil.
    let typeidOfT {.global.} = idOfType(T)
    m.base.typeid = typeidOfT
    sendMsg2[T](q, m)
else:
  proc sendMsg*[T](q: QueueID, m: ptr[Msg[T]]): void {.inline.} =
    ## Sends a message. m cannot be nil.
    sendMsg2[T](q, m)

when TWO_WAY_MESSAGING:
  proc replyWith*[Q,A](request: ptr[Msg[Q]], reply: ptr[Msg[A]]): void =
    ## Sends a reply message. request and reply cannot be nil.
    assert(request != nil, "request cannot be nil")
    assert(reply != nil, "reply cannot be nil")
    reply.base.request = addr request.base
    sendMsg(request.base.sender, reply)

proc recvMsg*(): seq[ptr[MsgBase]] =
  ## Receives messages from the own queue, if any.
  ## Returns messages in *reverse* order of arrival.
  result = newSeq[ptr[MsgBase]](0)
  let tqP = threadQueues[int(myThreadID())]
  var m = atomicExchangeFull(tqP, nil)
  while m != nil:
    result.add(m)
    m = m.previous


proc recvMsg*(waitInSecs: float, wait: proc (s: int): void = sleep): seq[ptr[MsgBase]] =
  ## Receives messages from the own queue, if any.
  ## Returns messages in *reverse* order of arrival.
  result = newSeq[ptr[MsgBase]](0)
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
  while m != nil:
    result.add(m)
    m = m.previous


when isMainModule:
  echo("TESTING message queues ...")

  initProcessID(ProcessID(0))
  initThreadID(0)

  type
    TstMsg = Msg[int]

  var m: TstMsg
  m.content = 42

  var dst: QueueID
  when USE_TOPICS:
    initTopicID(33)
    dst = queue(myProcessID(), ThreadID(1), TopicID(99))
  else:
    dst = queue(myProcessID(), ThreadID(1))
  sendMsg(dst, addr m)

  proc receiver() {.thread.} =
    initThreadID(1)
    let rcv = recvMsg(1)
    assert(rcv.len == 1)
    let request = cast[ptr[TstMsg]](rcv[0])
    let base = request.base
    when TWO_WAY_MESSAGING:
      assert(base.sender.pid == 0)
      assert(base.sender.tid == 0)
    when USE_TOPICS:
      when TWO_WAY_MESSAGING:
        assert(base.sender.cid == 33)
      initTopicID(base.receiver.cid)
      assert(base.receiver.pid == 0)
      assert(base.receiver.tid == myThreadID())
      assert(base.receiver.cid == myTopicID())
      assert(base.receiver == myQueueID())
    when USE_TYPE_ID:
      assert(base.typeid == idOfType(int))
    assert(request.content == 42)
    when USE_TIMESTAMPS:
      echo("Message received after " & $(timestampProvider() - base.timestamp))
    else:
      echo("Message received!")
    when TWO_WAY_MESSAGING:
      var reply = createShared(TstMsg)
      reply.content = 24
      replyWith(request, reply)

  var thread: Thread[void]
  createThread[void](thread, receiver)

  joinThread(thread)

  let rcv = recvMsg()
  when TWO_WAY_MESSAGING:
    assert(rcv.len == 1)
    let reply = cast[ptr[TstMsg]](rcv[0])
    let base = reply.base
    when TWO_WAY_MESSAGING:
      assert(base.sender.pid == 0)
      assert(base.sender.tid == 1)
    when USE_TOPICS:
      when TWO_WAY_MESSAGING:
        assert(base.sender.cid == 99)
      assert(base.receiver.pid == 0)
      assert(base.receiver.tid == 0)
      assert(base.receiver.cid == 33)
    when USE_TYPE_ID:
      assert(base.typeid == idOfType(int))
    assert(reply.content == 24)
    when USE_TIMESTAMPS:
      echo("Reply received after " & $(timestampProvider() - base.timestamp))
    else:
      echo("Reply received!")
    deallocShared(reply)
  else:
    assert(rcv.len == 0)
