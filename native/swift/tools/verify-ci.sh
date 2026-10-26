#!/bin/bash
# The native macOS gate, shared by local verification and CI. No app runs.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Native Swift UI gate applies to macOS only.'
  exit 0
fi
source tools/swift-environment.sh
uniapi_swift_environment
exec bash tools/verify.sh "$@"
