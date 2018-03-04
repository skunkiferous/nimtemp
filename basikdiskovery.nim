# Copyright 2018 Sebastien Diot.

import nativesockets
import net
import os
import strutils

import diskovery

const CONNECT_TIMEOUT_MS = 1000
  ## How long maximum to wait for a successful "connect" before giving up?

type
  ResourceSet* = object
    what*: string
    where*: seq[string]
    listener*: DiscoveryListenerProc

  MyTuple = tuple[host: string, port: Port, url: string]

  InternalResourceSet = object
    what: string
    where: seq[MyTuple]
    listener: DiscoveryListenerProc

  StaticDNSBasedInit = object
    ## Initialisation data for the staticDNSBasedImpl thread.
    refreshRate: int
      ## Refresh rate in seconds
    resources: int
      ## Total number of resources
    sets: seq[InternalResourceSet]
      ## All resource sets

var staticDNSBasedImplThread {.global.}: Thread[StaticDNSBasedInit]

proc parseURL(hostport: string, assumeStaticIPs: bool): MyTuple =
  ## Converts a URL to an (host,port) pair, if URL is valid.
  let idx = hostport.find(':')
  if (idx < 1) or (idx == high(hostport)):
    raise newException(Exception, "Bad URL: '" & hostport & "': port missing")
  let host = hostport.substr(0,idx-1)
  let portstr = hostport.substr(idx+1)
  var port = -1
  try:
    port = parseInt(portstr)
  except:
    discard
  if (port < 1) or (port > 65535):
    raise newException(Exception, "Bad URL: '" & hostport & "': bad port")
  if assumeStaticIPs:
    var ip: IpAddress
    if isIpAddress(host):
      try:
        ip = parseIpAddress(host)
      except:
        raise newException(Exception, "Bad URL: '" & hostport & "': bad IP address")
    else:
      var hostent: Hostent
      try:
        hostent = getHostByName(host)
      except:
        raise newException(Exception, "Bad URL: '" & hostport & "': bad hostname")
      if hostent.addrList.len == 0:
        raise newException(Exception, "Bad URL: '" & hostport & "': no IP for hostname")
      if hostent.addrList.len > 1:
        raise newException(Exception, "Bad URL: '" & hostport & "': too many IPs for hostname")
      let first = hostent.addrList[0]
      let a = uint8(first[0])
      let b = uint8(first[1])
      let c = uint8(first[2])
      let d = uint8(first[3])
      let ipstr = $a & "." & $b & "." & $c & "." & $d
      try:
        ip = parseIpAddress(ipstr)
      except:
        raise newException(Exception, "Bad URL: '" & hostport & "': failed to parse IP of address: " & ipstr)
    result = ($ip, Port(port), hostport)
  else:
    result = (host, Port(port), hostport)

proc discoveryShutdownBD() {.nimcall.} =
  ## Shuts down the staticDNSBasedImplThread and de-registers the service.
  # TODO
  discoveryShutdown = nil
  discoveryBlockingSearch = nil
  discoveryAsyncSearch = nil

proc discoveryBlockingSearchDB(what: string, timeouMS: int): string {.nimcall, gcsafe.} =
  # TODO
  discard

proc discoveryAsyncSearchBD(what: string, timeouMS: int, listener: DiscoveryListenerProc) {.nimcall, gcsafe.} =
  # TODO
  discard

proc staticDNSBasedImpl(init: StaticDNSBasedInit) {.thread.} =
  ## Regularly poll reources in "init.resources", to see if they are online.
  let refreshRateMS = init.refreshRate * 1000
  var socket = newSocket()
  var known = newSeq[bool](init.resources)
  var found = newSeq[string]()
  while true:
    var k = 0
    for rs in init.sets:
      found.setLen(0)
      let what = rs.what
      for t in rs.where:
        let (host, port, hostname) = t
        var active = false
        try:
          socket.connect(host, port, CONNECT_TIMEOUT_MS)
          active = true
        except:
          discard
        try:
          socket.close()
        except:
          discard
        if active != known[k]:
          # Something changed!
          known[k] = active
          if active:
            echo(what," resource ",hostname," online!")
            found.add(hostname)
          else:
            echo(what," resource ",hostname," offline!")
        inc k
      if not rs.listener.isNil and (len(found) > 0):
        rs.listener(what, found)
    sleep(refreshRateMS)

proc setupBasicDNSBasedImpl*(refreshRate: int, sets: seq[ResourceSet], assumeStaticIPs: bool) =
  ## Configures the discovery service to use a simple static URL based approach
  ## To discover active URLs. The URLs must be of the form "hostname:tcp-port".
  ## A connect on each URL will be tried at a regular interval defined by
  ## refreshRate (in seconds).
  ## If assumeStaticIPs is true, DNS to IP address mapping is assumed to be
  ## static (queried only once).
  if not discoveryShutdown.isNil:
    raise newException(Exception, "Discovery Service is already loaded!")
  var resources = 0
  var init: StaticDNSBasedInit
  init.refreshRate = refreshRate
  init.sets = newSeq[InternalResourceSet](len(sets))
  for i in 0..<len(sets):
    let s = sets[i]
    let n = len(s.where)
    var rs: InternalResourceSet
    rs.what = s.what
    rs.listener = s.listener
    rs.where = newSeq[MyTuple](n)
    for j in 0..<n:
      let hostport = s.where[j]
      rs.where[j] = parseURL(hostport, assumeStaticIPs)
      inc resources
    init.sets[i] = rs
  init.resources = resources

  discoveryShutdown = discoveryShutdownBD
  discoveryBlockingSearch = discoveryBlockingSearchDB
  discoveryAsyncSearch = discoveryAsyncSearchBD

  createThread[StaticDNSBasedInit](staticDNSBasedImplThread, staticDNSBasedImpl, init)
