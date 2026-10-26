#!/usr/bin/env bash
# Public source gate. No server, provider calls, installation or GUI smoke.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "") native=1 ;;
  --static) native=0 ;;
  *) echo 'Usage: bash tools/verify.sh [--static]' >&2; exit 64 ;;
esac
[[ "$#" -le 1 ]] || { echo 'Unexpected verification arguments.' >&2; exit 64; }
python="${PYTHON:-python3}"
command -v "$python" >/dev/null || { echo 'Python 3 is required for public verification.' >&2; exit 1; }

echo '== Public source and credential boundaries'
"$python" -B tools/pentest.py --static
echo '== Native resource admission'
"$python" -B tools/native_manifest.py validate-inputs --repo "$PWD"
echo '== Native pricing source matches the vendored catalog'
"$python" -B tools/generate_statistics_pricing.py --check
echo '== Public Python fixtures (private temporary roots and mocked commands)'
"$python" -B -m unittest discover -s tools -p 'test_*.py' -v

if [[ "$native" == 0 ]]; then
  echo 'Public static checks passed. Swift compilation/tests and application runtime were not run.'
  exit 0
fi
[[ "$(uname -s)" == Darwin ]] || {
  echo 'The full gate requires macOS and SDK26.5; use --static on other hosts.' >&2
  exit 1
}
echo '== All native release tests (including PublicSettings and Whisper tests)'
# No --filter: newly exported native tests are discovered by SwiftPM too.
bash native/swift/tools/verify-ci.sh
echo 'Public source fixtures and native release tests passed; no application/install/device acceptance is claimed.'
