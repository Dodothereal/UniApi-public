#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../data/bin
# Built beside the target and renamed over it: `codesign --force` rewrites a
# file in place and would corrupt a copy that is mid-execution.
tmp=$(mktemp ../../data/bin/uniapi-battery.XXXXXX)
trap 'rm -f "$tmp"' EXIT
# A git hook inherits xcrun's SDKROOT, which can point at an SDK newer than the
# CommandLineTools compiler. See the long note in native/fans/verify.sh.
unset SDKROOT
clang -O2 -fobjc-arc -mmacosx-version-min=14.0 \
  main.m smc.m hold.m preferences.m -framework Foundation -framework IOKit -o "$tmp"
chmod 755 "$tmp"
codesign --force --sign - --identifier uniapi-battery "$tmp"
mv -f "$tmp" ../../data/bin/uniapi-battery
trap - EXIT
