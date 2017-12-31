# Copyright 2017 Sebastien Diot.

import kueues_config
import kueues

echo("TESTING message queues ...")

const USE_OUT_BUFFERS = (OUTGOING_MSG_BUFFER_SIZE > 0)

const USE_MSG_SEQ_ID = (MSG_SEQ_ID_TYPE != MsgSeqIDTypeEnum.msitNone)

const USE_MSG_PROC_SEQ_ID = (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerProcess32) or
  (MSG_SEQ_ID_TYPE == MsgSeqIDTypeEnum.msitPerProcess64)

initProcessID(ProcessID(0))
initThreadID(ThreadID(0))

type
  TstMsg = Msg[int]

var m: TstMsg
m.content = 42

var dst: QueueID
when USE_TOPICS:
  initTopicID(TopicID(33))
  dst = queueID(myProcessID(), ThreadID(1), TopicID(99))
else:
  dst = queueID(myProcessID(), ThreadID(1))

assert(not pendingMsg())
sendMsgNow(dst, addr m)

proc receiver() {.thread.} =
  initThreadID(ThreadID(1))
  let rcv = recvMsgs(1)
  assert(rcv.len == 1)
  let request = cast[ptr[TstMsg]](rcv[0])
  when USE_TWO_WAY_MESSAGING:
    assert(request.sender.pid == ProcessID(0))
    assert(request.sender.tid == ThreadID(0))
  when USE_TOPICS:
    when USE_TWO_WAY_MESSAGING:
      assert(request.sender.cid == TopicID(33))
    initTopicID(request.receiver.cid)
    assert(request.receiver.pid == ProcessID(0))
    assert(request.receiver.tid == myThreadID())
    assert(request.receiver.cid == myTopicID())
    assert(request.receiver == myQueueID())
  when USE_TYPE_ID:
    assert(request.typeid == idOfType(int))
  when USE_MSG_SEQ_ID:
    assert(request.seqid == MsgSeqID(1))
  when USE_URGENT_MARKER:
    assert(request.urgent)
  assert(request.content == 42)
  when USE_TIMESTAMPS:
    echo("Message received after " & $(timestampProvider() - request.timestamp) & " 'timestamp units'")
  else:
    echo("Message received!")
  when USE_TWO_WAY_MESSAGING:
    var reply = createShared(TstMsg)
    reply.content = 24
    replyNowWith(request, reply)

var thread: Thread[void]
createThread[void](thread, receiver)

joinThread(thread)

when USE_TWO_WAY_MESSAGING:
  assert(pendingMsg())
else:
  assert(not pendingMsg())
let rcv = recvMsgs()
when USE_TWO_WAY_MESSAGING:
  assert(rcv.len == 1)
  let reply = cast[ptr[TstMsg]](rcv[0])
  when USE_TWO_WAY_MESSAGING:
    assert(reply.sender.pid == ProcessID(0))
    assert(reply.sender.tid == ThreadID(1))
  when USE_TOPICS:
    when USE_TWO_WAY_MESSAGING:
      assert(reply.sender.cid == TopicID(99))
    assert(reply.receiver.pid == ProcessID(0))
    assert(reply.receiver.tid == ThreadID(0))
    assert(reply.receiver.cid == TopicID(33))
  when USE_TYPE_ID:
    assert(reply.typeid == idOfType(int))
  when USE_MSG_SEQ_ID:
    when USE_MSG_PROC_SEQ_ID:
      assert(reply.seqid == MsgSeqID(2))
    else:
      assert(reply.seqid == MsgSeqID(1))
  when USE_URGENT_MARKER:
    assert(reply.urgent)
  assert(reply.content == 24)
  when USE_TIMESTAMPS:
    echo("Reply received after " & $(timestampProvider() - reply.timestamp) & " 'timestamp units'")
  else:
    echo("Reply received!")
  deallocShared(reply)
else:
  assert(rcv.len == 0)
assert(not pendingMsg())

when USE_OUT_BUFFERS:
  var m2: TstMsg
  var m3: TstMsg
  m2.content = 2
  m3.content = 3
  sendMsg(dst, addr m2)
  sendMsg(dst, addr m3)

  proc receiver2() {.thread.} =
    initThreadID(ThreadID(1))
    assert(not pendingMsg())

  var thread2: Thread[void]
  createThread[void](thread2, receiver2)
  joinThread(thread2)

  flushMsgs()

  proc receiver3() {.thread.} =
    initThreadID(ThreadID(1))
    let rcv = recvMsgs()
    assert(rcv.len == 2)
    # rcv is in *reverse* order!
    let tm2 = cast[ptr[TstMsg]](rcv[1])
    let tm3 = cast[ptr[TstMsg]](rcv[0])
    assert(tm2.content == 2)
    assert(tm3.content == 3)
    when USE_URGENT_MARKER:
      assert(not tm2.urgent)
      assert(not tm3.urgent)
    when USE_MSG_SEQ_ID:
      when USE_MSG_PROC_SEQ_ID:
        assert(tm2.seqid == MsgSeqID(3))
        assert(tm3.seqid == MsgSeqID(4))
      else:
        assert(tm2.seqid == MsgSeqID(2))
        assert(tm3.seqid == MsgSeqID(3))

  var thread3: Thread[void]
  createThread[void](thread3, receiver3)
  joinThread(thread3)
