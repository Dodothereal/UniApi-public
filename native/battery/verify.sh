#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ]; then echo 'Native battery checks: macOS only'; exit 0; fi
unset SDKROOT
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -fobjc-arc -mmacosx-version-min=14.0 main.m smc.m hold.m preferences.m -framework Foundation -framework IOKit -o "$work/uniapi-battery"
# `state` is read-only and needs no privileges, so CI can run it for real on
# any Mac. On a machine without the charge-limit service it reports
# supported:false rather than failing, which is itself the case worth testing.
out=$("$work/uniapi-battery" state)
echo "$out"
python3 - "$out" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert s.get("ok") is True, "state did not report ok"
assert isinstance(s.get("supported"), bool), "missing supported flag"
assert isinstance(s.get("levels"), list), "missing levels list"
assert all(isinstance(v, int) for v in s["levels"]), "levels must be whole percentages"
b = s.get("battery") or {}
assert isinstance(b.get("present"), bool), "missing battery presence"
if b.get("present"):
    assert 0 <= b["percent"] <= 100, "battery percent out of range"
if s["supported"]:
    assert s["levels"], "a supported Mac must report the levels it accepts"
    assert 1 <= s["limit"] <= 100, "invalid current limit"
print("native battery state checks passed")
PY
# Refusals must not need a real change to verify. The helper exits non-zero on
# a refusal, and this script runs under `set -o pipefail`, so the output is
# captured first rather than piped straight into grep.
refusal=$("$work/uniapi-battery" bogus 2>/dev/null || true)
echo "$refusal" | grep -q '"ok":false' || { echo "unknown command was not refused: $refusal"; exit 1; }
# Invalid syntax is rejected before a setter, regardless of future OS levels.
refusal=$("$work/uniapi-battery" set invalid 2>/dev/null || true)
echo "$refusal" | grep -q '"ok":false' || { echo "invalid input was not refused: $refusal"; exit 1; }
clang -fobjc-arc -mmacosx-version-min=14.0 hold_test.m smc.m preferences.m -framework Foundation -framework IOKit -o "$work/hold-tests"
"$work/hold-tests"
clang -fobjc-arc -mmacosx-version-min=14.0 preferences_test.m -framework Foundation -framework IOKit -o "$work/preferences-tests"
"$work/preferences-tests"
echo "native battery refusal and parser checks passed"
