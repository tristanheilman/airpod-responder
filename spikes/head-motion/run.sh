#!/bin/sh
# A bare executable has no Info.plist, and CoreMotion wants
# NSMotionUsageDescription before it will ask for permission. Embedding the
# plist in the __TEXT,__info_plist section is the usual trick for an
# unbundled binary — the same thing the daemon will need.
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o head-motion -framework CoreMotion \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
# AirPods stream head motion only while they are the active audio output with
# sound playing — the same gate as spatial-audio head tracking. Keep them busy.
if [ -n "$1" ]; then
  ( i=0; while [ $i -lt "$1" ]; do say -r 120 "nod, nod, nod. shake, shake, shake. look around. hold still." ; i=$((i+6)); done ) &
  talker=$!
  trap 'kill $talker 2>/dev/null' EXIT
fi
exec ./head-motion "$@"
