#!/usr/bin/env python3
"""Exact native bundle admission and staging. This is build tooling, not app code."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct

FAN_LICENSES = ("SMC-research-LICENSE.md", "ThermalForge-LICENSE.txt")
APP_EXECUTABLES = (
    "Contents/MacOS/UniApiNative",
    "Contents/Resources/Helpers/uniapi-fans",
    "Contents/Resources/Helpers/uniapi-battery",
    "Contents/Resources/Helpers/uniapi-shim",
    "Contents/Resources/Helpers/uniapi-whisper",
)
APP_RESOURCES = {
    "Contents/Resources/install-battery-helper.sh": "native/swift/tools/install-battery-helper.sh",
    "Contents/Resources/battery-handoff.sh": "native/swift/tools/battery-handoff.sh",
    "Contents/Resources/install-fan-helper.sh": "native/fans/install-daemon.sh",
    "Contents/Resources/UniApi.icns": "assets/UniApi.icns",
    "Contents/Resources/providers.example.json": "providers.example.json",
    "Contents/Resources/Licenses/SMC-research-LICENSE.md": "native/fans/Resources/SMC-research-LICENSE.md",
    "Contents/Resources/Licenses/ThermalForge-LICENSE.txt": "native/fans/Resources/ThermalForge-LICENSE.txt",
    "Contents/Resources/Licenses/UniApi-LICENSE": "LICENSE",
    "Contents/Resources/Licenses/Zstandard-LICENSE": "native/swift/Sources/CZstd/LICENSE",
    "Contents/Resources/Licenses/Whisper-LICENSE": "native/swift/Resources/Whisper-LICENSE.txt",
    "Contents/Resources/Licenses/Lucide-LICENSE": "native/swift/Resources/Lucide-LICENSE.txt",
}
APP_FILES = frozenset(APP_EXECUTABLES) | frozenset(APP_RESOURCES) | {"Contents/Info.plist"}
SIGNATURE_FILE = "Contents/_CodeSignature/CodeResources"
PACKAGE_FILES = frozenset({"tools/install-native.sh", "install.sh", "INSTALL.md", "LICENSE"})
PLIST_FIELDS = frozenset({
    "CFBundleExecutable", "CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName",
    "CFBundleIconFile", "CFBundlePackageType", "CFBundleShortVersionString", "CFBundleVersion",
    "LSMinimumSystemVersion", "NSHighResolutionCapable",
})
IDENTITIES = {"production": ("app.devved.uniapi.hub", "UniApi"),
              "development": ("app.devved.uniapi.native-development", "UniApi Native")}
ARCHITECTURES = {"arm64": 0x0100000C, "x86_64": 0x01000007}
CPU_SUBTYPES = {"arm64": 0, "x86_64": 3}


def version_string(version):
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise RuntimeError("Native bundle version must have three numeric components")
    return version


def bundle_info(variant, version):
    if variant not in IDENTITIES:
        raise RuntimeError("Expected production or development bundle")
    identity, name = IDENTITIES[variant]
    return {"CFBundleExecutable": "UniApiNative", "CFBundleIdentifier": identity,
            "CFBundleName": name, "CFBundleDisplayName": name, "CFBundleIconFile": "UniApi",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version_string(version),
            "CFBundleVersion": version, "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True}


DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
READ_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)


def relative_parts(relative):
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        raise RuntimeError("Native manifest requires a path inside its selected root")
    return path.parts


class ManifestDirectory:
    """A selected root may be an intentional alias; paths below it may not.

    Resolve the selection once (including macOS /var aliases), then retain its
    descriptor. Never resolve a resource's parent through untrusted links.
    """
    def __init__(self, root, allow_root_alias=True):
        root = Path(root)
        if not allow_root_alias and root.is_symlink():
            raise RuntimeError("Native manifest root must be an unlinked directory: " + str(root))
        try:
            self.path = root.resolve(strict=True) if allow_root_alias else root.parent.resolve(strict=True) / root.name
            self.fd = os.open(self.path, DIRECTORY_FLAGS)
        except OSError as error:
            raise RuntimeError("Native manifest directory is missing or linked: " + str(root)) from error

    def __enter__(self):
        return self

    def __exit__(self, *_):
        os.close(self.fd)

    @contextmanager
    def directory(self, relative="", create=False):
        fd = os.dup(self.fd)
        try:
            for name in relative_parts(relative):
                if create:
                    try:
                        os.mkdir(name, 0o755, dir_fd=fd)
                    except FileExistsError:
                        pass
                child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
                os.close(fd); fd = child
            yield fd
        except OSError as error:
            raise RuntimeError("Native manifest directory is missing or linked: " + str(self.path / relative)) from error
        finally:
            os.close(fd)

    @contextmanager
    def child(self, relative):
        with self.directory(relative) as fd:
            child = object.__new__(ManifestDirectory)
            child.path, child.fd = self.path / relative, os.dup(fd)
            with child:
                yield child

    def read(self, relative, maximum=256 * 1024 * 1024, executable=False):
        parts = relative_parts(relative)
        if not parts:
            raise RuntimeError("Native manifest requires a file inside its selected root")
        with self.directory(Path(*parts[:-1])) as parent:
            try:
                fd = os.open(parts[-1], READ_FLAGS, dir_fd=parent)
            except OSError as error:
                raise RuntimeError("Native manifest source is missing or linked: " + str(self.path / relative)) from error
        try:
            return read_regular_descriptor(fd, self.path / relative, maximum, executable)
        finally:
            os.close(fd)

    def write_new(self, relative, data, mode):
        parts = relative_parts(relative)
        if not parts:
            raise RuntimeError("Native manifest requires a file inside its selected root")
        with self.directory(Path(*parts[:-1]), create=True) as parent:
            fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=parent)
        with os.fdopen(fd, "wb") as output:
            output.write(data); os.fchmod(output.fileno(), mode)

    def exact_tree(self, relative, required, optional=frozenset()):
        files, directories = set(), set()
        def visit(fd, prefix):
            with os.scandir(fd) as entries:
                for entry in entries:
                    name = entry.name
                    path = (prefix / name).as_posix()
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        directories.add(path)
                        child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
                        try:
                            visit(child, prefix / name)
                        finally:
                            os.close(child)
                    elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                        files.add(path)
                    else:
                        raise RuntimeError("Linked or special content entered the native manifest: " + path)
        with self.directory(relative) as fd:
            try:
                visit(fd, Path())
            except OSError as error:
                raise RuntimeError("Native manifest tree changed or contains a linked directory") from error
        if not required <= files or files - required - optional:
            raise RuntimeError("Native manifest file mismatch; missing=" + repr(sorted(required - files)) +
                               "; unexpected=" + repr(sorted(files - required - optional)))
        allowed = {str(parent) for file in files for parent in Path(file).parents if str(parent) != "."}
        if directories != allowed:
            raise RuntimeError("Unexpected directory entered the native manifest: " + repr(sorted(directories - allowed)))
        return files


def read_regular_descriptor(fd, file, maximum, executable=False):
    """Read only the admitted descriptor, including mode and stability checks."""
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= maximum:
            raise RuntimeError("Native manifest requires a bounded unlinked regular file: " + str(file))
        if executable and not info.st_mode & 0o111:
            raise RuntimeError("Native executable is not executable: " + str(file))
        chunks, count = [], 0
        while True:
            block = os.read(fd, 1 << 20)
            if not block:
                break
            count += len(block)
            if count > maximum:
                raise RuntimeError("Native manifest source exceeded its size bound: " + str(file))
            chunks.append(block)
        after = os.fstat(fd)
        signature = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if count != info.st_size or signature(info) != signature(after):
            raise RuntimeError("Native manifest source changed during read: " + str(file))
        return b"".join(chunks)
    except OSError as error:
        raise RuntimeError("Native manifest source read failed: " + str(file)) from error


def regular_bytes(file, maximum=256 * 1024 * 1024):
    file = Path(file)
    with ManifestDirectory(file.parent) as root:
        return root.read(file.name, maximum)


def exact_tree(root, required, optional=frozenset()):
    with ManifestDirectory(root, allow_root_alias=False) as selected:
        return selected.exact_tree("", required, optional)


def native_executable(data, file):
    # A renamed script, SQLite database or web runtime cannot occupy a helper slot.
    thin = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}
    magic = data[:4]
    if magic in thin and len(data) >= 32:
        _, cpu, subtype, kind = struct.unpack(thin[magic] + "IIII", data[:16])
        architectures = frozenset(name for name, value in ARCHITECTURES.items()
                                  if value == cpu and subtype & 0x00FFFFFF == CPU_SUBTYPES[name])
        if architectures and kind == 2:
            return architectures
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic in fat and len(data) >= 8:
        endian, wide = fat[magic]
        count = struct.unpack(endian + "I", data[4:8])[0]
        width = 32 if wide else 20
        if 0 < count <= 8 and len(data) >= 8 + count * width:
            architectures = set()
            for index in range(count):
                record = data[8 + index * width:8 + (index + 1) * width]
                cpu, subtype, offset, size, *_ = struct.unpack(endian + ("IIQQII" if wide else "IIIII"), record)
                if offset < 8 + count * width or size < 32 or offset + size > len(data):
                    break
                found = native_executable(data[offset:offset + size], file)
                declared = frozenset(name for name, value in ARCHITECTURES.items()
                                     if value == cpu and subtype & 0x00FFFFFF == CPU_SUBTYPES[name])
                if found != declared or architectures.intersection(found):
                    break
                architectures.update(found)
            else:
                return frozenset(architectures)
    raise RuntimeError("Expected a native macOS executable in manifest slot: " + str(file))


def selected_architectures(architecture):
    if architecture is None:
        return None
    if architecture not in ARCHITECTURES:
        raise RuntimeError("Expected arm64 or x86_64 native architecture")
    return frozenset({architecture})


def matching_architectures(data, file, expected):
    actual = native_executable(data, file)
    if expected is not None and actual != expected:
        raise RuntimeError("Native executable architecture differs from selected bundle: " + str(file))
    return actual


def text_resource(data, file):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RuntimeError("Expected UTF-8 text resource: " + str(file)) from error
    if "\0" in text:
        raise RuntimeError("Binary content entered text resource: " + str(file))
    if str(file).endswith(".sh") and text.splitlines()[0] not in {"#!/bin/bash", "#!/bin/zsh"}:
        raise RuntimeError("Expected a shell installer in manifest slot: " + str(file))


def validate_app(app, variant="production", version=None, architecture=None):
    with ManifestDirectory(app, allow_root_alias=False) as root:
        validate_app_directory(root, variant, version, architecture)


def validate_app_directory(root, variant, version, architecture=None):
    files = root.exact_tree("", APP_FILES, {SIGNATURE_FILE})
    data = root.read("Contents/Info.plist", 1 << 20)
    try:
        info = plistlib.loads(data)
    except Exception as error:
        raise RuntimeError("Native Info.plist is invalid") from error
    if not isinstance(info, dict) or set(info) != PLIST_FIELDS:
        raise RuntimeError("Native Info.plist has missing or unexpected flags/fields")
    version = version_string(info.get("CFBundleShortVersionString")) if version is None else version_string(version)
    if info != bundle_info(variant, version) or type(info["NSHighResolutionCapable"]) is not bool:
        raise RuntimeError("Native Info.plist identity/version/production fields differ from the manifest")
    expected = selected_architectures(architecture)
    for relative in APP_EXECUTABLES:
        expected = matching_architectures(root.read(relative, executable=True), root.path / relative, expected)
    for relative in APP_RESOURCES:
        file = root.path / relative
        data = root.read(relative, 16 << 20)
        if relative.endswith(".icns"):
            if len(data) < 8 or data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data):
                raise RuntimeError("Native icon is invalid")
        elif relative.endswith(".json"):
            try:
                document = json.loads(data)
            except (ValueError, UnicodeError) as error:
                raise RuntimeError("Native provider template is invalid JSON") from error
            if not isinstance(document, dict) or not isinstance(document.get("providers"), list):
                raise RuntimeError("Native provider template is invalid")
        else:
            text_resource(data, file)
    if SIGNATURE_FILE in files:
        try:
            if not isinstance(plistlib.loads(root.read(SIGNATURE_FILE, 1 << 20)), dict):
                raise ValueError()
        except (ValueError, plistlib.InvalidFileException) as error:
            raise RuntimeError("Native resource signature is invalid") from error


def validate_package(stage, version=None, architecture=None):
    required = {"UniApi.app/" + file for file in APP_FILES} | set(PACKAGE_FILES)
    with ManifestDirectory(stage, allow_root_alias=False) as root:
        root.exact_tree("", required, {"UniApi.app/" + SIGNATURE_FILE})
        with root.child("UniApi.app") as app:
            validate_app_directory(app, "production", version, architecture)
        for relative in PACKAGE_FILES:
            text_resource(root.read(relative, 16 << 20), relative)


def validate_inputs(repo):
    with ManifestDirectory(repo) as root:
        root.exact_tree("native/fans/Resources", set(FAN_LICENSES))
        for source in APP_RESOURCES.values():
            root.read(source, 16 << 20)


def stage_app(repo, binaries, fan_helper, app, variant, version, *, whisper_helper, architecture=None):
    app, fan_helper, whisper_helper = Path(app), Path(fan_helper), Path(whisper_helper)
    # Every relative component is opened below its selected, pinned root.
    # Read the admitted descriptors once; publishing never reopens source paths.
    with ManifestDirectory(repo) as root, ManifestDirectory(binaries) as binary_root, ManifestDirectory(fan_helper.parent) as fan_root, ManifestDirectory(whisper_helper.parent) as whisper_root:
        root.exact_tree("native/fans/Resources", set(FAN_LICENSES))
        contents = {relative: root.read(source, 16 << 20) for relative, source in APP_RESOURCES.items()}
        for name in ("uniapi-battery", "uniapi-shim"):
            contents["Contents/Resources/Helpers/" + name] = binary_root.read(name)
        contents["Contents/MacOS/UniApiNative"] = binary_root.read("UniApiNative")
        contents["Contents/Resources/Helpers/uniapi-fans"] = fan_root.read(fan_helper.name)
        contents["Contents/Resources/Helpers/uniapi-whisper"] = whisper_root.read(whisper_helper.name, executable=True)
        expected = selected_architectures(architecture)
        for relative in APP_EXECUTABLES:
            expected = matching_architectures(contents[relative], relative, expected)
    info = bundle_info(variant, version)
    with ManifestDirectory(app.parent) as parent:
        try:
            os.mkdir(app.name, 0o755, dir_fd=parent.fd)
        except FileExistsError as error:
            raise RuntimeError("Native staging destination already exists") from error
        with parent.child(app.name) as output:
            for relative, data in contents.items():
                mode = 0o755 if relative in APP_EXECUTABLES or relative.endswith(".sh") else 0o644
                output.write_new(relative, data, mode)
            output.write_new("Contents/Info.plist", plistlib.dumps(info), 0o644)
            validate_app_directory(output, variant, version, architecture)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["stage-app", "validate-app", "validate-package", "validate-inputs"])
    parser.add_argument("--app"); parser.add_argument("--stage"); parser.add_argument("--repo")
    parser.add_argument("--bin-dir"); parser.add_argument("--fan-helper"); parser.add_argument("--whisper-helper")
    parser.add_argument("--variant", choices=IDENTITIES, default="production")
    parser.add_argument("--version")
    parser.add_argument("--arch", choices=ARCHITECTURES)
    args = parser.parse_args()
    if args.operation == "validate-inputs":
        if not args.repo: parser.error("validate-inputs requires repo")
        validate_inputs(args.repo)
    elif args.operation == "stage-app":
        if not all([args.app, args.repo, args.bin_dir, args.fan_helper, args.whisper_helper, args.version]):
            parser.error("stage-app requires app, repo, bin-dir, fan-helper, whisper-helper and version")
        stage_app(args.repo, args.bin_dir, args.fan_helper, args.app, args.variant, args.version, whisper_helper=args.whisper_helper, architecture=args.arch)
    elif args.operation == "validate-app":
        if not args.app: parser.error("validate-app requires app")
        validate_app(args.app, args.variant, args.version, architecture=args.arch)
    else:
        if not args.stage: parser.error("validate-package requires stage")
        validate_package(args.stage, args.version, architecture=args.arch)


if __name__ == "__main__":
    main()
