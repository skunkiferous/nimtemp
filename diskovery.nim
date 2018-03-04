# Copyright 2018 Sebastien Diot.

# Module diskovery

import nativesockets
import net
import os
import strutils

import moduleinit

# This module provides a generic interface to a "discovery" service.
# It should allow compiling the code that requires discovery against this
# single module, and only reference the actual implementation in the app main
# module.
#
# Since the setup of every implementation could be totally different, we do not
# define a specific setup method declaration.

type
  DiscoveryListenerProc* = proc(what: string, where: openarray[string]) {.nimcall, gcsafe.}
    ## Type of a proc that received info over some newly discovered resources.
    ## "what" designates the type of resource.
    ## "where" contains 0 (in the case of a failed query) or more URLs to the
    ## resources.

  DiscoveryBlockingSearchProc* = proc(what: string, timeoutMS: int): string {.nimcall, gcsafe.}
    ## Type of a proc that synchronously queries the discovery service.
    ## It receives the query string, and an optional query timeout in
    ## milliseconds. It returns a (possibly empty on timeout) "URL" to the
    ## requested resource.
    ## "what" designates the type of resource.

  DiscoveryAsyncSearchProc* = proc(what: string, timeoutMS: int, listener: DiscoveryListenerProc) {.nimcall, gcsafe.}
    ## Type of a proc that asynchronously queries the discovery service.
    ## It receives the query string, an optional query timeout in milliseconds,
    ## and a listener for the results.
    ## "what" designates the type of resource.
    ## "listener" will presumably be called form a differen thread.


var discoveryBlockingSearch*: DiscoveryBlockingSearchProc
  ## The discovery service blocking search proc.
  ## Should be initialised by the implementation before use!

var discoveryAsyncSearch*: DiscoveryAsyncSearchProc
  ## The discovery service asynchronous search proc.
  ## Should be initialised by the implementation before use!

proc onDiscoveryReady*() =
  ## Must be called after the discovery service implementation was loaded,
  ## to verify that it was corretly initialized.
  if discoveryBlockingSearch.isNil:
    raise newException(Exception, "discoveryBlockingSearch is nil")
  if discoveryAsyncSearch.isNil:
    raise newException(Exception, "discoveryAsyncSearch is nil")

proc level0InitModuleDiskovery*(): void =
  ## Module registration
  discard registerModule("diskovery")
