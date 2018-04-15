# Copyright 2017 Sebastien Diot.

import asyncdispatch
import nativesockets
import os
import typetraits

import kueues_config
import kueues
from gethutil import toBin

echo("TESTING message queues ...", getThreadId())

const USE_OUT_BUFFERS = (OUTGOING_MSG_BUFFER_SIZE > 0)

const USE_MSG_SEQ_ID = (MSG_SEQ_ID_TYPE != MsgSeqIDTypeEnum.msitNone)
const USE_CLUSTER_MSG_SEQ_ID = (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitCluster64)

const USE_MSG_PROC_SEQ_ID = (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerProcess32) or
  (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerProcess64)

const CLUSTER_SEQ_ID_BITS = uint64(sizeof(uint64) - sizeof(QueueID)) * 8
const CLUSTER_SEQ_ID_SEQ_MASK: uint64 = (1'u64 shl CLUSTER_SEQ_ID_BITS) - 1'u64
const CLUSTER_SEQ_ID_QUEUE_MASK: uint64 = uint64(-1'i64) xor CLUSTER_SEQ_ID_SEQ_MASK

type
  TstMsg = Msg[int]
  TstRep = Msg[float]

var dst: QueueID
var m: TstMsg


when USE_MSG_SEQ_ID and USE_CLUSTER_MSG_SEQ_ID and USE_TOPICS:
  proc testSeqID(s: MsgSeqID, q: QueueID, m: int): void =
    let s2 = uint64(s)
    let q2 = uint64(q)
    let s3 = (s2 and CLUSTER_SEQ_ID_SEQ_MASK)
    let q3 = ((s2 and CLUSTER_SEQ_ID_QUEUE_MASK) shr CLUSTER_SEQ_ID_BITS)
    assert(s3 == uint64(m), $s3)
    assert(q3 == q2)

proc initTest() =
  echo("CLUSTER_SEQ_ID_BITS: " & $CLUSTER_SEQ_ID_BITS)
  echo("CLUSTER_SEQ_ID_SEQ_MASK:\n    " & toBin(CLUSTER_SEQ_ID_SEQ_MASK))
  echo("CLUSTER_SEQ_ID_QUEUE_MASK:\n    " & toBin(CLUSTER_SEQ_ID_QUEUE_MASK))

  when USE_TOPICS:
    echo("QUEUE PROCESS MASK:\n    " & toBin(uint64(queueID(ProcessID(uint64(-1)), ThreadID(0), TopicID(0)))))
    echo("QUEUE THREAD MASK:\n    " & toBin(uint64(queueID(ProcessID(0), ThreadID(uint64(-1)), TopicID(0)))))
    echo("QUEUE TOPIC MASK:\n    " & toBin(uint64(queueID(ProcessID(0), ThreadID(0), TopicID(uint64(-1))))))
  else:
    echo("QUEUE PROCESS MASK:\n    " & toBin(uint64(queueID(ProcessID(uint64(-1)), ThreadID(0)))))
    echo("QUEUE THREAD MASK:\n    " & toBin(uint64(queueID(ProcessID(0), ThreadID(uint64(-1))))))

  var pc: ProcessConfig
  pc.pid = ProcessID(0)

  when CLUSTER_SUPPORT:
    proc processMapper(pid: ProcessID, port: var Port, address: var NotAString): void {.gcSafe.} =
      address.fill("localhost")
      port = Port(int(DEFAULT_CLUSTER_PORT) + int(pid))

    pc.processMapper = processMapper

  initProcess(pc)

proc startTest() =
  initThreadID(ThreadID(0))

  m.content = 42

  when USE_TOPICS:
    initTopicID(TopicID(33))
    let pid = myProcessID()
    dst = queueID(pid, ThreadID(1), TopicID(99))
  else:
    dst = queueID(myProcessID(), ThreadID(1))

  assert(not pendingMsg())
  sendMsgNow(dst, addr m)
  when USE_TWO_WAY_MESSAGING:
    assert(replyPending(addr m))

  echo("First msg sent from Thread 0.")

proc receiverProc(rcv: ptr MsgBase) =
  let request: ptr TstMsg = cast[ptr TstMsg](rcv)
  when USE_TWO_WAY_MESSAGING:
    assert(request.sender.pid == ProcessID(0))
    assert(request.sender.tid == ThreadID(0))
  when USE_TOPICS:
    when USE_TWO_WAY_MESSAGING:
      assert(request.sender.cid == TopicID(33))
    initTopicID(request.receiver.cid)
    assert(request.receiver.cid == myTopicID())
    assert(request.receiver.pid == ProcessID(0))
    assert(request.receiver.tid == myThreadID())
    assert(request.receiver == myQueueID())
  when USE_TYPE_ID:
    echo("checking type of [int]")
    assert((request.typeid == idOfType(int)) and (request.typeid != idOfType(float)),
      "Expected: " & $idOfType(int) & " Actual: " & $request.typeid)
  when USE_MSG_SEQ_ID:
    when USE_CLUSTER_MSG_SEQ_ID:
      when USE_TOPICS:
        testSeqID(request.seqid, queueID(ProcessID(0), ThreadID(0), TopicID(33)), 1)
      else:
        testSeqID(request.seqid, queueID(ProcessID(0), ThreadID(0)), 1)
    else:
      assert(request.seqid == MsgSeqID(1), "Wrong seqid: " & toBin(request.seqid))
  when USE_URGENT_MARKER:
    assert(request.urgent)
  assert(request.content == 42)
  when USE_TIMESTAMPS:
    echo("Message received after " & $(timestampProvider() - request.timestamp) & " 'timestamp units'")
  else:
    echo("Message received!")
  when USE_TWO_WAY_MESSAGING:
    var reply: ptr TstRep = createShared(TstRep)
    reply.content = 24.0
    replyNowWith(request, reply)

proc receiver() {.thread.} =
  initThreadID(ThreadID(1))
  echo("Thread 1 initialised.", getThreadId())
  let rcv = recvMsgs(1)
  assert(rcv.len == 1, "Expected 1 message, but got " & $(rcv.len))
  receiverProc(rcv[0])

when USE_TWO_WAY_MESSAGING:
  proc afterReceiver(rcv: ptr MsgBase) =
    let reply = cast[ptr TstRep](rcv)
    assert(reply.sender.pid == ProcessID(0))
    assert(reply.sender.tid == ThreadID(1))
    when USE_TOPICS:
      assert(reply.sender.cid == TopicID(99))
      assert(reply.receiver.cid == TopicID(33))
      assert(reply.receiver.pid == ProcessID(0))
      assert(reply.receiver.tid == ThreadID(0))
    when USE_TYPE_ID:
      echo("checking type of [float]")
      assert((reply.typeid == idOfType(float)) and (reply.typeid != idOfType(int)),
        "Expected: " & $idOfType(float) & " Actual: " & $reply.typeid)
      let request = cast[ptr TstMsg](reply.request)
      assert(reply.typeid != request.typeid, "Not Expected: " & $request.typeid)
    when USE_MSG_SEQ_ID:
      when USE_MSG_PROC_SEQ_ID:
        assert(reply.seqid == MsgSeqID(2))
      elif USE_CLUSTER_MSG_SEQ_ID:
        when USE_TOPICS:
          testSeqID(reply.seqid, queueID(ProcessID(0), ThreadID(1), TopicID(99)), 1)
        else:
          testSeqID(reply.seqid, queueID(ProcessID(0), ThreadID(1)), 1)
      else:
        assert(reply.seqid == MsgSeqID(1))
    when USE_URGENT_MARKER:
      assert(reply.urgent)
    assert(reply.content == 24.0)
    when USE_TIMESTAMPS:
      echo("Reply received after " & $(timestampProvider() - reply.timestamp) & " 'timestamp units'")
    else:
      echo("Reply received!")
    deallocShared(reply)

proc afterReceiver() =
  when USE_TWO_WAY_MESSAGING:
    assert(pendingMsg())
  else:
    assert(not pendingMsg())
  let rcv = recvMsgs()
  when USE_TWO_WAY_MESSAGING:
    assert(not replyPending(addr m))
    assert(rcv.len == 1)
    afterReceiver(rcv[0])
  else:
    assert(rcv.len == 0)
  assert(not pendingMsg())

proc runReceiver() =
  var thread: Thread[void]
  createThread[void](thread, receiver)
  joinThread(thread)

when USE_OUT_BUFFERS:
  var m2: TstMsg
  var m3: TstMsg

  proc receiver2() {.thread.} =
    initThreadID(ThreadID(1))
    echo("Thread 1 initialised.", getThreadId())
    assert(not pendingMsg())

  proc runReceiver2() =
    m2.content = 2
    m3.content = 3
    sendMsg(dst, addr m2)
    sendMsg(dst, addr m3)

    var thread2: Thread[void]
    createThread[void](thread2, receiver2)
    joinThread(thread2)

    flushMsgs()

  proc receiver3(rcv0, rcv1: ptr MsgBase) =
    # rcv is in *reverse* order!
    let tm2 = cast[ptr TstMsg](rcv1)
    let tm3 = cast[ptr TstMsg](rcv0)
    assert(tm2.content == 2)
    assert(tm3.content == 3)
    when USE_URGENT_MARKER:
      assert(not tm2.urgent)
      assert(not tm3.urgent)
    when USE_MSG_SEQ_ID:
      when USE_MSG_PROC_SEQ_ID:
        assert(tm2.seqid == MsgSeqID(3))
        assert(tm3.seqid == MsgSeqID(4))
      elif USE_CLUSTER_MSG_SEQ_ID:
        when USE_TOPICS:
          testSeqID(tm2.seqid, queueID(ProcessID(0), ThreadID(0), TopicID(33)), 2)
          testSeqID(tm3.seqid, queueID(ProcessID(0), ThreadID(0), TopicID(33)), 3)
        else:
          testSeqID(tm2.seqid, queueID(ProcessID(0), ThreadID(0)), 2)
          testSeqID(tm3.seqid, queueID(ProcessID(0), ThreadID(0)), 3)
      else:
        assert(tm2.seqid == MsgSeqID(2))
        assert(tm3.seqid == MsgSeqID(3))
      var request = createShared(TstRep)
      request.content = 123.0
      sendMsgNow(tm2.sender, request)

  proc receiver3() {.thread.} =
    initThreadID(ThreadID(1))
    echo("Thread 1 initialised.", getThreadId())
    let rcv = recvMsgs()
    assert(rcv.len == 2)
    receiver3(rcv[0], rcv[1])

  proc runReceiver3() =
    var thread3: Thread[void]
    createThread[void](thread3, receiver3)
    joinThread(thread3)

    let rcv2 = recvMsgs()
    assert(rcv2.len == 1)
    let request2 = cast[ptr TstRep](rcv2[0])
    assert(request2.content == 123.0)
    deallocShared(request2)
    echo("Out-buffers tested.")

proc test() =
  initTest()
  startTest()
  runReceiver()
  afterReceiver()

  when USE_OUT_BUFFERS:
    runReceiver2()
    runReceiver3()

  terminateProcess()
  echo("DONE!")

test()
