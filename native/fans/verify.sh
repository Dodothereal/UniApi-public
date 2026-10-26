#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ]; then echo 'Native fan tests: macOS only'; exit 0; fi
# Apple's git runs hooks through xcrun, which exports SDKROOT pointing at the
# CommandLineTools SDK. Where that SDK is newer than the CommandLineTools
# swiftc - a 6.4 SDK against a 6.3.3 compiler is the common pairing once Xcode
# is also installed - swiftc obeys the inherited SDKROOT, tries to rebuild the
# Swift stdlib from its .swiftinterface and dies. The symptom is maddening:
# `tools/verify.sh --static` is green by hand and the identical run inside
# .githooks/pre-push blocks every push with "failed to build module 'Swift'".
# Clearing it lets swiftc choose the SDK matching whichever compiler it is.
unset SDKROOT
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc Core/*.swift Tests/CoreTests.swift -framework IOKit -o "$work/tests"

# Sensor discovery must not filter on the reading it happens to see. The helper is a LaunchDaemon
# now, so it starts at boot on a cold machine, where every Tg* GPU key reports the idle sentinel
# below 10C. A value filter here excluded them for the process's entire lifetime, which made
# Snapshot.temperature("GPU") nil, which made Policy.shouldRelease say "blind", which refused every
# acquisition - observed 1h50m after a reboot with the machine at 107C and the fans at 2422 RPM.
# The per-read filter in snapshot() is the right place for a sentinel; init is not.
if grep -n 'sensorKeys.append' -B 3 Core/Hardware.swift | grep -qE 'value\(key\)[^!]*>=|v >= 10'; then
  echo "FAIL: Hardware.init filters sensor discovery on the current reading - a cold sensor at boot is excluded forever" >&2
  exit 1
fi
echo "PASS: sensor discovery does not exclude a sensor that is merely cold right now"
swiftc Core/*.swift main.swift -framework IOKit -o "$work/helper"
"$work/tests"
# Hardware probing is separate so CI on a fanless host still verifies policy.
