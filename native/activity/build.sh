#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output="${UNIAPI_ACTIVITY_BINARY:-../../data/bin/uniapi-activity}"
mkdir -p "$(dirname "$output")"
tmp=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
unset SDKROOT
clang -O2 -Wall -Wextra -fobjc-arc -mmacosx-version-min=14.0 \
  main.m -framework Foundation -framework AppKit -lproc -o "$tmp"
chmod 755 "$tmp"
codesign --force --sign - --identifier uniapi-activity "$tmp"
mv -f "$tmp" "$output"
trap - EXIT
