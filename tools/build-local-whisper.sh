#!/bin/bash
# Build the official pinned CLI only; no model download, inference or installation.
# Reuse the proved source/build caches; Metal source is embedded, with no metallib.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 && "$1" == --output && "$2" == /* ]] || { echo 'Usage: build-local-whisper.sh --output /absolute/path/uniapi-whisper' >&2; exit 64; }
output="$2"
source "$repo/native/swift/tools/swift-environment.sh"
uniapi_swift_environment
cache="$repo/.cache/whisper-runtime"
archive="$cache/whisper-v1.9.4.tar.gz"
source_root="$cache/whisper.cpp-1.9.4"
build_root="$cache/build-$(uname -m)"
archive_sha=57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae
archive_url=https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.4
for path in "$repo/.cache" "$cache" "$archive" "$source_root" "$build_root"; do
  [[ ! -L "$path" ]] || { echo 'Linked Whisper cache refused.' >&2; exit 1; }
done
mkdir -p "$cache"
work="$(mktemp -d "$cache/.prepare.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Hash every invocation, including cache hits; never retrieve upstream main.
[[ ! -e "$archive" || -f "$archive" ]] || { echo 'Expected a regular Whisper archive.' >&2; exit 1; }
if [[ ! -f "$archive" ]]; then
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 "$archive_url" --output "$work/source.tar.gz"
  actual="$(shasum -a 256 "$work/source.tar.gz")"; actual="${actual%% *}"
  [[ "$actual" == "$archive_sha" ]] || { echo 'Whisper source archive checksum mismatch.' >&2; exit 1; }
  mv "$work/source.tar.gz" "$archive"
fi
actual="$(shasum -a 256 "$archive")"; actual="${actual%% *}"
[[ "$actual" == "$archive_sha" ]] || { echo 'Whisper source archive checksum mismatch.' >&2; exit 1; }
if [[ ! -d "$source_root" ]]; then
  tar -xzf "$archive" -C "$work"
  mv "$work/whisper.cpp-1.9.4" "$source_root"
fi
# Check cached release sources against the admitted archive without making a
# second source/build tree. The existing build directory keeps its objects.
python3 - "$archive" "$cache" <<'PY'
import pathlib, sys, tarfile
archive, cache = sys.argv[1], pathlib.Path(sys.argv[2])
with tarfile.open(archive, "r:gz") as source:
    for member in source:
        relative = pathlib.PurePosixPath(member.name)
        if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] != "whisper.cpp-1.9.4":
            raise SystemExit("Unexpected Whisper archive path")
        file = cache.joinpath(*relative.parts)
        if file.is_symlink():
            raise SystemExit("Linked Whisper source refused")
        if member.isdir():
            if not file.is_dir(): raise SystemExit("Whisper source directory is missing")
        elif member.isfile():
            if not file.is_file(): raise SystemExit("Whisper source file is missing")
            with source.extractfile(member) as expected, file.open("rb") as actual:
                while True:
                    chunk = expected.read(1 << 20)
                    if actual.read(len(chunk) if chunk else 1) != chunk:
                        raise SystemExit("Cached Whisper source differs from the pinned archive")
                    if not chunk: break
        else:
            raise SystemExit("Unexpected Whisper source member")
PY
# The CLI includes these embedded examples; preserve their selected MIT notices
# as well as the root license in the one allowlisted bundled license resource.
python3 - "$source_root" "$repo/native/swift/Resources/Whisper-LICENSE.txt" <<'PYLICENSE'
import pathlib, sys
source, bundled = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
stb = (source / "examples/stb_vorbis.c").read_text().split("ALTERNATIVE A - MIT License\n", 1)[1].split("\n------------------------------------------------------------------------------", 1)[0]
mini = (source / "examples/miniaudio.h").read_text().split("ALTERNATIVE 2 - MIT No Attribution\n", 1)[1].split("\n*/", 1)[0]
expected = ((source / "LICENSE").read_text() + "\n\nwhisper.cpp v1.9.4 - examples/stb_vorbis.c\n\nALTERNATIVE A - MIT License\n" + stb + "\n\nwhisper.cpp v1.9.4 - examples/miniaudio.h\n\nALTERNATIVE 2 - MIT No Attribution\n" + mini + "\n")
if bundled.read_bytes() != expected.encode("utf-8"):
    raise SystemExit("Bundled Whisper notices differ from the pinned source")
PYLICENSE
# Match the manual proof's configuration so its objects remain reusable. Do not
# change compilers or optional backend defaults on an already-proved build.
cmake -S "$source_root" -B "$build_root" -G 'Unix Makefiles' \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$UNIAPI_SWIFT_SDK" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=OFF
cmake --build "$build_root" --target whisper-cli -j2
binary="$build_root/bin/whisper-cli"
# Static whisper/ggml may use macOS frameworks/libraries; reject non-system
# dylibs instead of silently creating an incomplete standalone bundle.
otool -L "$binary" | tail -n +2 | while IFS= read -r dependency; do
  dependency="${dependency#"${dependency%%[![:space:]]*}"}"
  case "$dependency" in /System/Library/*|/usr/lib/*) ;; *) echo 'Non-system Whisper runtime dependency refused.' >&2; exit 1;; esac
done
[[ ! -L "$output" && ! -L "$(dirname "$output")" ]] || { echo 'Linked Whisper output refused.' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
published="$(mktemp "$(dirname "$output")/.uniapi-whisper.XXXXXX")"
trap 'rm -f "$published"; rm -rf "$work"' EXIT
cp "$binary" "$published"
chmod 755 "$published"
mv -f "$published" "$output"
echo "Built pinned whisper.cpp v1.9.4 CLI: $output"
