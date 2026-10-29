#!/bin/bash
# Build the official pinned CLI only; no model download, inference or installation.
# Reuse the checked source/build caches; Metal source is embedded, with no metallib.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 && "$1" == --output && "$2" == /* ]] || { echo 'Usage: build-local-whisper.sh --output /absolute/path/uniapi-whisper' >&2; exit 64; }
output="$2"
native_arch="${UNIAPI_NATIVE_ARCH-$(uname -m)}"
case "$native_arch" in arm64|x86_64) ;; *) echo 'UNIAPI_NATIVE_ARCH must be arm64 or x86_64.' >&2; exit 64;; esac
export UNIAPI_NATIVE_ARCH="$native_arch"
source "$repo/native/swift/tools/swift-environment.sh"
uniapi_swift_environment
cache="$repo/.cache/whisper-runtime"
archive="$cache/whisper-v1.9.4.tar.gz"
source_root="$cache/whisper.cpp-1.9.4"
build_root="$cache/build-$native_arch"
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
# second source/build tree. CMake invalidates objects when compiler flags change.
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
# GGML_ABORT / WHISPER_ASSERT retain __FILE__ even in Release. Map compiler
# paths, not arbitrary source literals or linked bytes. The pinned Metal .m
# files use the C compile rule, so C_FLAGS also covers their Objective-C macros.
# Preserve other cached flags (or the initial environment) and quote each
# argument for CMake's Unix Makefiles generator, including roots with spaces.
python3 - "$source_root" "$build_root" "$native_arch" > "$work/compiler-flags" <<'PYFLAGS'
import os, pathlib, shlex, sys
source, build, arch = sys.argv[1:]
roots = []
for root, replacement in ((source, "whisper.cpp"), (build, "whisper-build")):
    # Clang can report macros with the supplied spelling but canonicalize the
    # debug compilation directory (for example, the system's temporary path).
    for spelling in dict.fromkeys((root, str(pathlib.Path(root).resolve()))):
        if any(character in spelling for character in '\r\n=$#'):
            raise SystemExit("Whisper prefix-map roots contain unsupported characters")
        roots.append((spelling, replacement))
options = ("-ffile-prefix-map", "-fmacro-prefix-map", "-fdebug-prefix-map")
prefixes = tuple(f"{option}={root}=" for root, _ in roots for option in options)
maps = [f"{option}={root}={replacement}" for root, replacement in roots for option in options]
cached = {}
intel_baseline = ['-march=x86-64', '-mtune=generic'] if arch == 'x86_64' else []
def intel_flags(flags):
    flags = [flag for flag in flags if flag not in intel_baseline]
    if arch == 'x86_64' and any(flag.startswith(('-m', '-arch', '-target', '--target', '-Xarch_', '-Xclang')) for flag in flags):
        raise SystemExit('Intel Whisper baseline refuses custom target or CPU flags')
    return flags
cache_file = pathlib.Path(build) / "CMakeCache.txt"
if cache_file.is_file():
    for line in cache_file.read_text().splitlines():
        for language in ("C", "CXX"):
            key = f"CMAKE_{language}_FLAGS:STRING="
            if line.startswith(key): cached[language] = line[len(key):]
            if arch == 'x86_64' and line.startswith(f"CMAKE_{language}_FLAGS_RELEASE:STRING="):
                intel_flags(shlex.split(line.split('=', 1)[1]))
for language, environment in (("C", "CFLAGS"), ("CXX", "CXXFLAGS")):
    flags = shlex.split(cached.get(language, os.environ.get(environment, "")))
    flags = [flag for flag in flags if not flag.startswith(prefixes)]
    sys.stdout.write(shlex.join(intel_flags(flags) + maps + intel_baseline) + '\0')
PYFLAGS
exec 3< "$work/compiler-flags"
IFS= read -r -d '' c_flags <&3
IFS= read -r -d '' cxx_flags <&3
exec 3<&-
# Set cache flags on every configure; generated flags.make is an explicit
# dependency of each object, so pre-remapping objects must be rebuilt. Keep
# compilers, Release settings and optional backends unchanged. GGML_NATIVE=OFF
# alone still enables x86 ISA defaults in this pin; Intel uses the baseline ISA.
arch_options=(-DGGML_NATIVE=OFF)
if [[ "$native_arch" == x86_64 ]]; then
  arch_options+=(-DGGML_CPU_ALL_VARIANTS=OFF)
  for feature in SSE42 AVX AVX2 AVX_VNNI BMI2 FMA F16C AVX512 AVX512_VBMI AVX512_VNNI AVX512_BF16 AMX_TILE AMX_INT8 AMX_BF16; do
    arch_options+=("-DGGML_$feature=OFF")
  done
fi
cmake -S "$source_root" -B "$build_root" -G 'Unix Makefiles' \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$UNIAPI_SWIFT_SDK" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$native_arch" \
  -DCMAKE_C_FLAGS:STRING="$c_flags" -DCMAKE_CXX_FLAGS:STRING="$cxx_flags" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=OFF "${arch_options[@]}"
cmake --build "$build_root" --target whisper-cli -j2
binary="$build_root/bin/whisper-cli"
actual_arch="$(lipo -archs "$binary")"
[[ "$actual_arch" == "$native_arch" ]] || { echo 'Unexpected Whisper architecture; refusing publication.' >&2; exit 1; }
# Static whisper/ggml may use macOS frameworks/libraries; reject non-system
# dylibs instead of silently creating an incomplete standalone bundle.
otool -L "$binary" | tail -n +2 | while IFS= read -r dependency; do
  dependency="${dependency#"${dependency%%[![:space:]]*}"}"
  case "$dependency" in /System/Library/*|/usr/lib/*) ;; *) echo 'Non-system Whisper runtime dependency refused.' >&2; exit 1;; esac
done
# Prefix maps affect compiler-generated paths, not ordinary string literals.
# Refuse publication if a future source or build change leaves either behind.
python3 - "$binary" "$repo" "$source_root" "$build_root" <<'PYPATHS'
import pathlib, sys
binary, *roots = sys.argv[1:]
data = pathlib.Path(binary).read_bytes()
paths = {spelling.encode() for root in roots for spelling in (root, str(pathlib.Path(root).resolve()))}
home = pathlib.Path.home()
if home != pathlib.Path("/"):
    paths.add(str(home).encode() + b"/")
if any(path in data for path in paths) or b"/Users/" in data or b"/home/" in data:
    raise SystemExit("Whisper binary retains private build paths; refusing publication")
PYPATHS
[[ ! -L "$output" && ! -L "$(dirname "$output")" ]] || { echo 'Linked Whisper output refused.' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
published="$(mktemp "$(dirname "$output")/.uniapi-whisper.XXXXXX")"
trap 'rm -f "$published"; rm -rf "$work"' EXIT
cp "$binary" "$published"
chmod 755 "$published"
mv -f "$published" "$output"
echo "Built pinned whisper.cpp v1.9.4 CLI: $output"
