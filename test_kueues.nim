# Copyright 2017 Sebastien Diot.

import kueues_config
import kueues

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
  dst = queueID(myProcessID(), ThreadID(1), TopicID(99))
else:
  dst = queueID(myProcessID(), ThreadID(1))
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
