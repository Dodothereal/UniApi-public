#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../data/bin
# Build beside the target and rename over it. A root control session may be executing the
# installed binary. ld unlinks and recreates its output, but `codesign --force` rewrites the
# file in place, which can kill a running helper before its watchdog restores automatic fan
# control. The rename leaves the running process on the old inode whatever the tools do.
tmp=$(mktemp ../../data/bin/uniapi-fans.XXXXXX)
trap 'rm -f "$tmp"' EXIT
# See native/fans/verify.sh: a git hook inherits xcrun's SDKROOT, which points
# at the CommandLineTools SDK and can be newer than the CommandLineTools
# swiftc. Nothing invokes this script from a hook today, but the failure is
# silent-until-baffling, so it clears the variable too.
unset SDKROOT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Core/*.swift main.swift -framework IOKit -o "$tmp"
chmod 755 "$tmp"
codesign --force --sign - --identifier uniapi-fans "$tmp"
mv -f "$tmp" ../../data/bin/uniapi-fans
trap - EXIT
