# Copyright 2018 Sebastien Diot.

# Module kluster

import moduleinit

# This module provides a generic interface to a "cluster" implementation.
# It should allow compiling the code that accesses the cluster against this
# single module, and only reference the actual implementation in the app main
# module.
#
# Since the setup of every implementation could be totally different, we do not
# define a specific setup method declaration.
#
# A "cluster" is defined as a set of nodes, with no central (SPOF) node that
# all nodes have to connect to. For simplicity, we are assuming the cluster
# size is limited to 256 node. And nodes communicate by sending "messages" to
# each other. An implementation might, or might not, guarantee delivery. There
# will be some maximum message size.
#
# Discovery of other nodes is usually required, and might be implemented in
# multiple ways, including using a central service (Redix, ZooKeeper, ...).
# This should be generally independent of the cluster implementation.
#
# The implementation module must at least define "sendMessage", and
# optionally "sendMessages", "RESERVED", or both "allocMessage" and
# "deallocMessage". It must also call "messageSent" and "messageReceiver".
#
# The client module(s) must at least define "messageReceiver", and optionally
# "messageSent".

type
  Message* = pointer
    ## Represents a message
  NodeID* = uint8
    ## Represents a cluster node ID
  MessageNodeID* = tuple[message: Message, node: NodeID]

  AllocMessageProc* = proc(size: Natural): Message {.nimcall, gcsafe.}
    ## A proc that allocates memory to store a Message of size bytes.
  DeallocMessageProc* = proc(message: Message): void {.nimcall, gcsafe.}
    ## A proc that de-allocates memory allocated with AllocMessageProc.
  MessageReceiverProc* = proc(message: Message, node: NodeID): void {.nimcall, gcsafe.}
    ## A proc that processes received messages.
  SendMessageProc* = proc(message: Message, node: NodeID): void {.nimcall, gcsafe.}
    ## A proc that sends a message.
  SendMessagesProc* = proc(messages: varargs[MessageNodeID]): void {.nimcall, gcsafe.}
    ## A proc that sends messages.
  MessageSentProc* = proc(message: Message, node: NodeID): void {.nimcall, gcsafe.}
    ## A proc that is called after a message was sent, to allow deallocation.


var allocMessage*: AllocMessageProc
  ## Allocates memory to store a Message of size bytes (impl-defined).

var deallocMessage*: DeallocMessageProc
  ## De-allocates memory allocated with AllocMessageProc (impl-defined).

var sendMessage*: SendMessageProc
  ## A proc that sends a message (impl-defined).

var sendMessages*:  SendMessagesProc
  ## A proc that sends messages (impl-defined).

var SEND_MESSAGE_BLOCKS* = false
  ## It is assumed that most implementations will NOT block in sendMessage(s).
  ## If sendMessage(s) does block, SEND_MESSAGE_BLOCKS should be set to true.
  ## (impl-defined).


var messageSent*: MessageSentProc
  ## A proc that is called after a message was sent, to allow deallocation
  # (user-defined).

var messageReceiver*: MessageReceiverProc
  ## A proc that processes received messages (user-defined).


proc level0InitModuleKluster*(): void =
  ## Module registration
  discard registerModule("kluster")

########################################################
# Default implementation of some of the methods follows:
########################################################

var RESERVED*: Natural = 0
  ## Amount of "reserved" memory added to each message by the cluster code
  ## (impl-defined). Should be a multiple of sizeof(int).
  ## Only used if using the default allocMessage and deallocMessage.

proc defaultAllocMessage*(size: Natural): Message {.nimcall, gcsafe.} =
  ## Default implementatiom of AllocMessageProc
  cast[Message](cast[ByteAddress](allocShared0(size+RESERVED)) +% RESERVED)

proc defaultDallocMessage*(message: Message): void {.nimcall, gcsafe.} =
  ## Default implementatiom of DeallocMessageProc
  deallocShared(cast[pointer](cast[ByteAddress](message) -% RESERVED))

proc defaultSendMessages*(messages: varargs[MessageNodeID]): void {.nimcall, gcsafe.} =
  ## Default implementatiom of SendMessagesProc
  for m in messages:
    sendMessage(m.message, m.node)

proc defaultMessageSent*(message: Message, node: NodeID): void {.nimcall, gcsafe.} =
  ## Default implementatiom of MessageSentProc
  deallocMessage(message)

allocMessage = defaultAllocMessage
deallocMessage = defaultDallocMessage
sendMessages = defaultSendMessages
messageSent = defaultMessageSent
