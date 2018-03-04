# Copyright 2018 Sebastien Diot.

import os
import strutils

import diskovery
import basikdiskovery

proc MyListener(what: string, where: openarray[string]) {.nimcall, gcsafe.} =
  echo("what: '",what,"', where: ",len(where))

proc testDiscovery() =
  var sets = newSeq[ResourceSet](1)
  sets[0].what = "website"
  sets[0].where = newSeq[string]()
  sets[0].where.add("shadowdemon.com:80")
  sets[0].listener = MyListener

  setupBasicDNSBasedImpl(1, sets, false)
  onDiscoveryReady()
  sleep(3000)

when isMainModule:
  echo("TESTING basikdiskovery ...")
  testDiscovery()
