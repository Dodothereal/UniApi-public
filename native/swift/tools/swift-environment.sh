#!/bin/bash
# One pinned SDK/toolchain selection for native CI, staging and packaging.
uniapi_swift_environment() {
  local native_sdk="${UNIAPI_SWIFT_SDK:-}" native_compiler="${UNIAPI_SWIFT_TOOLCHAIN:-}"
  local native_candidate native_developer="${DEVELOPER_DIR:-}"
  if [[ -z "$native_sdk" ]]; then
    for native_candidate in "${native_developer:-/nonexistent}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk" \
      /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
      /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk; do
      if [[ -d "$native_candidate" ]]; then native_sdk="$native_candidate"; break; fi
    done
  fi
  [[ "$native_sdk" == /*/MacOSX26.5.sdk && -d "$native_sdk" ]] || {
    echo 'Install/configure the required MacOSX26.5.sdk (UNIAPI_SWIFT_SDK).' >&2; return 1;
  }
  if [[ -z "$native_compiler" ]]; then
    if [[ "$native_sdk" == */Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk ]]; then
      native_developer="${native_sdk%/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk}"
      native_compiler="$native_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    elif [[ "$native_sdk" == */CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
      native_compiler="${native_sdk%/SDKs/MacOSX26.5.sdk}/usr/bin/swift"
    elif [[ -n "$native_developer" ]]; then
      native_compiler="$native_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    else
      native_compiler="$(command -v swift || true)"
    fi
  fi
  [[ "$native_compiler" == /* && -x "$native_compiler" && -x "$(dirname "$native_compiler")/swiftc" ]] || {
    echo 'Configure a matching Swift/Swiftc toolchain (UNIAPI_SWIFT_TOOLCHAIN).' >&2; return 1;
  }
  [[ "$native_sdk$native_compiler" != *$'\n'* && "$native_sdk$native_compiler" != *$'\r'* ]] || return 1
  export UNIAPI_SWIFT_SDK="$native_sdk" UNIAPI_SWIFT_TOOLCHAIN="$native_compiler"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  uniapi_swift_environment
  printf '%s\n' "$UNIAPI_SWIFT_SDK" "$UNIAPI_SWIFT_TOOLCHAIN"
fi
