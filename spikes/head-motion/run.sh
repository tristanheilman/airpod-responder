#!/bin/sh
# A bare executable has no Info.plist, and CoreMotion wants
# NSMotionUsageDescription before it will ask for permission. Embedding the
# plist in the __TEXT,__info_plist section is the usual trick for an
# unbundled binary — the same thing the daemon will need.
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o head-motion -framework CoreMotion \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
exec ./head-motion "$@"
