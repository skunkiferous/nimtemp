# Copyright 2017 Sebastien Diot.

# The Geht Actor System

import gethutil
import kueues


type
  ActorSystemID* = uint32     # The actor system ID (global, 0 for local system)
  # Pointer to an actor system (The same system instance must be used in multiple threads)
  ActorSystem* = distinct Opaque
  LocalActorID* = uint32      # The local actor ID
  ActorID* = object           # The global actor ID
    system*: ActorSystemID    # The system ID of the actor
    actor*: LocalActorID      # The actor ID within the system
  ActorMessageID* = uint32    # The message ID of the actor
  MessageID* = object         # The global message ID
    src*: ActorID             # The global source actor ID
    dst*: ActorID             # The global destination actor ID
    msg*: ActorMessageID      # The message ID of the source actor
  MessagePayload* = seq[NotARef]    # The message payload.
  ReplyHandler* = (proc(request: ref Message, reply: MessagePayload): void)
  ErrorHandler* = (proc(request: ref Message, error: Exception): void)
  Message* = object
    system: ActorSystem # id contains the ActorSystemIDs; can we not map that to the ActorSystem?
    id: MessageID
    msg: MessagePayload
    reply: ReplyHandler
    fail: ErrorHandler
  # Handles a message.
  RequestHandler*[T] = (proc(self: T, request: ref Message): T)

  # If ActorSystemID* = uint32 and LocalActorID* = uint32, the (src + dst) is already 16 bytes *per message*.
  # Why not register a "conversation", which consist of (src + dst), mapped to a uint16, and use that in the message?
  # 64K "conversations" per thread-pair seems a reasonable limitation.
  # OTOH, if we use conversations, then we could have more complex (bigger) system/actor IDs. This might allow us
  # to enable a transparent movement of actors accross threads and systems.
  # Basically, a conversation is like a Socket; UDP or TCP? Then resolving an actor ID to a conversation ID is like
  # a DNS query. The query must contain the actor type. If the actor has a incompatible type, the query fails.
  # This allows the sender, on successful query, to know exactly which requests are permited, and presumably defines
  # for each request an ID, so that it can be used over the network.
  # With this design, the system ID could literally be a socket(IPv6?)+port. There must then also be a way such that
  # if the socket+port refers to the same process (but not nescesarily the same system), a direct communication is
  # possible. I guess we can have some "directory" like in Akka, mapping names to IDs. Redis?
  # OK, so actors have logical names, and (changing) physical addresses. "Services" would also be actors. So, when do
  # you need to query for a specific actor? For example, ship wants to jump to planet X. So it queries it's address,
  # but if not currently loaded, it must request that it gets loaded first.

const
  LOCAL_SYSTEM*: ActorSystemID = 0   # 0 always refers to the local actor system
