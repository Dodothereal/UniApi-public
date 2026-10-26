#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Activity native checks skipped: macOS only.'
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export UNIAPI_ACTIVITY_BINARY="$work/uniapi-activity"
bash native/activity/build.sh
python3 native/activity/test_helper.py
