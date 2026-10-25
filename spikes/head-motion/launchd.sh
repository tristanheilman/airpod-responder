#!/bin/sh
# The TCC question: does an unbundled binary started by launchd — not by a
# terminal — still get head motion? Runs the spike as a one-off LaunchAgent
# for 20 seconds and prints what it wrote. Nod and shake while it runs.
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o head-motion -framework CoreMotion \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
label=com.airpodresponder.head-motion-spike
plist="$HOME/Library/LaunchAgents/$label.plist"
out=/tmp/head-motion-launchd.out
rm -f "$out"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$PWD/head-motion</string><string>20</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$out</string>
  <key>StandardErrorPath</key><string>$out</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "started under launchd — nod and shake for the next 20 seconds"
# Keep the AirPods routed to the Mac (and the motion stream alive) while the
# launchd job runs; without audio they drift back to the phone.
( i=0; while [ $i -lt 20 ]; do say -r 120 "nod, nod, nod. shake, shake, shake. look around. hold still."; i=$((i+6)); done ) &
sleep 23
kill %1 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$plist"
echo "--- what it saw:"
cat "$out"
