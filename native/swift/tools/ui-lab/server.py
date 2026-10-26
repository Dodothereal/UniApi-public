#!/usr/bin/env python3
"""Read-only, loopback-only viewer for explicitly admitted saved PNG captures."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import stat
import struct
from urllib.parse import urlsplit
import zlib

MAX_MANIFEST = 1 << 20
MAX_IMAGE = 32 << 20
MAX_CASES = 128
CASE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")


class AdmissionError(ValueError):
    pass


def require(condition, message="Artifact admission failed"):
    if not condition:
        raise AdmissionError(message)


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def relative_parts(value):
    require(isinstance(value, str) and 0 < len(value) <= 1024)
    require(not value.startswith("/") and "\\" not in value)
    require(all(ord(c) >= 32 and ord(c) != 127 for c in value))
    parts = value.split("/")
    require(all(part not in ("", ".", "..") for part in parts))
    return parts


def open_directory(path):
    """Walk from / without following any ancestor or final symlink."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


class PinnedRoot:
    def __init__(self, path):
        self.path = Path(path).absolute()
        self.fd = open_directory(self.path)
        info = os.fstat(self.fd)
        self.identity = (info.st_dev, info.st_ino)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def check(self):
        current = open_directory(self.path)
        try:
            info = os.fstat(current)
            require((info.st_dev, info.st_ino) == self.identity, "Artifact root changed")
        finally:
            os.close(current)

    def file(self, relative, limit):
        parts = relative_parts(relative)
        descriptor = os.dup(self.fd)
        try:
            for part in parts[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            child = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=descriptor)
            try:
                info = os.fstat(child)
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                        "Only regular, non-hardlinked files are admitted")
                require(0 < info.st_size <= limit, "Artifact exceeds its size bound")
                return child, info
            except BaseException:
                os.close(child)
                raise
        finally:
            os.close(descriptor)

    def read(self, relative, limit):
        descriptor, before = self.file(relative, limit)
        try:
            chunks, remaining = [], limit + 1
            while remaining:
                block = os.read(descriptor, min(remaining, 1 << 20))
                if not block:
                    break
                chunks.append(block)
                remaining -= len(block)
            data = b"".join(chunks)
            require(len(data) == before.st_size and len(data) <= limit)
            require(fingerprint(before) == fingerprint(os.fstat(descriptor)),
                    "Artifact changed during read")
            return data, fingerprint(before)
        finally:
            os.close(descriptor)


def png_dimensions(data):
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Image is not PNG bytes")
    offset, dimensions, has_data, ended = 8, None, False, False
    while offset < len(data):
        require(offset + 12 <= len(data))
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data))
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        require(zlib.crc32(kind + payload) & 0xFFFFFFFF == crc, "PNG chunk CRC differs")
        if dimensions is None:
            require(kind == b"IHDR" and length == 13)
            width, height = struct.unpack_from(">II", payload)
            require(0 < width <= 32768 and 0 < height <= 32768)
            require(width * height <= 64_000_000, "PNG pixel count exceeds bound")
            require(payload[10] == 0 and payload[11] == 0 and payload[12] in (0, 1))
            dimensions = (width, height)
        else:
            require(kind != b"IHDR")
        has_data = has_data or kind == b"IDAT"
        if kind == b"IEND":
            require(length == 0 and end == len(data))
            ended = True
        offset = end
    require(dimensions is not None and has_data and ended, "PNG is incomplete")
    return dimensions


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate manifest key")
        result[key] = value
    return result


def text(value, limit=240):
    require(isinstance(value, str) and 0 < len(value) <= limit)
    require(all(ord(c) >= 32 and ord(c) != 127 for c in value))
    return value


def positive_integer(value):
    require(type(value) is int and 0 < value <= 32768)
    return value


class ArtifactStore:
    def __init__(self, root, manifest="manifest.json"):
        relative_parts(manifest)
        self.root = PinnedRoot(root)
        self.manifest = manifest
        self.cache = {}

    def image(self, value, case_id, role):
        require(isinstance(value, dict))
        required = {"image", "width", "height"}
        require(required <= value.keys() and value.keys() <= required | {"label"})
        path = value["image"]
        relative_parts(path)
        require(path.lower().endswith(".png"), "Expected a PNG filename")
        width, height = positive_integer(value["width"]), positive_integer(value["height"])
        descriptor, info = self.root.file(path, MAX_IMAGE)
        os.close(descriptor)
        key = fingerprint(info)
        cached = self.cache.get(path)
        if cached is None or cached[0] != key:
            data, key = self.root.read(path, MAX_IMAGE)
            cached = (key, png_dimensions(data), hashlib.sha256(data).hexdigest())
            if path not in self.cache and len(self.cache) >= MAX_CASES * 2:
                self.cache.clear()
            self.cache[path] = cached
        require(cached[1] == (width, height), "PNG dimensions differ from manifest")
        digest = cached[2]
        public = {"url": f"/image/{case_id}/{role}?sha256={digest}",
                  "width": width, "height": height, "sha256": digest}
        if "label" in value:
            public["label"] = text(value["label"])
        return public, (path, key, digest)

    def snapshot(self):
        self.root.check()
        data, _ = self.root.read(self.manifest, MAX_MANIFEST)
        document = json.loads(data, object_pairs_hook=unique_object,
                              parse_constant=lambda _: require(False))
        require(isinstance(document, dict) and set(document) == {"version", "cases"})
        require(type(document["version"]) is int and document["version"] == 1)
        require(isinstance(document["cases"], list) and len(document["cases"]) <= MAX_CASES)
        cases, authorized, ids, live_paths = [], {}, set(), set()
        for case in document["cases"]:
            require(isinstance(case, dict))
            required = {"id", "label", "image", "width", "height", "appearance"}
            require(required <= case.keys())
            require(case.keys() <= required | {"page", "viewportWidth", "reference"})
            case_id = text(case["id"], 80)
            require(CASE_ID.fullmatch(case_id) and case_id not in ids)
            ids.add(case_id)
            require(case["appearance"] in ("light", "dark"))
            public = {"id": case_id, "label": text(case["label"]),
                      "appearance": case["appearance"]}
            if "page" in case:
                public["page"] = text(case["page"], 80)
            if "viewportWidth" in case:
                public["viewportWidth"] = positive_integer(case["viewportWidth"])
            image = {key: case[key] for key in ("image", "width", "height")}
            public["image"], authorized[(case_id, "main")] = self.image(image, case_id, "main")
            live_paths.add(case["image"])
            if "reference" in case:
                public["reference"], authorized[(case_id, "reference")] = self.image(
                    case["reference"], case_id, "reference")
                live_paths.add(case["reference"]["image"])
            cases.append(public)
        self.cache = {path: value for path, value in self.cache.items() if path in live_paths}
        payload = json.dumps({"version": 1, "cases": cases}, ensure_ascii=True,
                             separators=(",", ":")).encode()
        return payload, authorized

    def image_bytes(self, authorized):
        path, expected_key, expected_digest = authorized
        data, key = self.root.read(path, MAX_IMAGE)
        require(key == expected_key and hashlib.sha256(data).hexdigest() == expected_digest,
                "Capture changed; refresh the manifest")
        return data


def request_allowed(headers, authority):
    hosts = headers.get_all("Host", [])
    origins = headers.get_all("Origin", [])
    sites = headers.get_all("Sec-Fetch-Site", [])
    lengths = headers.get_all("Content-Length", [])
    return (hosts == [authority] and len(origins) <= 1
            and (not origins or origins == ["http://" + authority])
            and len(sites) <= 1 and (not sites or sites[0] in ("none", "same-origin"))
            and not headers.get_all("Transfer-Encoding", [])
            and (not lengths or lengths == ["0"]))


class ViewerHandler(BaseHTTPRequestHandler):
    server_version = "SnapshotViewer"
    sys_version = ""

    def log_message(self, *_):
        pass  # No request paths, header values or artifact labels in logs.

    def send_content(self, status, content_type, data=b"", etag=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        if status != 304:
            self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", self.server.csp)
        self.send_header("Connection", "close")
        if status == 405:
            self.send_header("Allow", "GET, HEAD")
        if etag is not None:
            self.send_header("ETag", etag)
        self.close_connection = True
        try:
            self.end_headers()
            if self.command != "HEAD" and status != 304:
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass  # Hidden/closed browser pages can abandon an in-flight read.

    def serve_read(self):
        if not request_allowed(self.headers, self.server.authority):
            self.send_content(403, "text/plain; charset=utf-8", b"Request rejected.\n")
            return
        try:
            target = urlsplit(self.path)
            require(not target.scheme and not target.netloc and not target.fragment)
            if self.path in ("/", "/index.html"):
                self.send_content(200, "text/html; charset=utf-8", self.server.index)
                return
            if self.path == "/manifest.json":
                data, _ = self.server.store.snapshot()
                etag = '"' + hashlib.sha256(data).hexdigest() + '"'
                status = 304 if self.headers.get("If-None-Match") == etag else 200
                self.send_content(status, "application/json; charset=utf-8", data, etag)
                return
            match = re.fullmatch(r"/image/([A-Za-z0-9][A-Za-z0-9._-]{0,79})/(main|reference)", target.path)
            if match and re.fullmatch(r"sha256=[a-f0-9]{64}", target.query):
                _, authorized = self.server.store.snapshot()
                value = authorized.get((match[1], match[2]))
                if value is not None and target.query == "sha256=" + value[2]:
                    data = self.server.store.image_bytes(value)
                    self.send_content(200, "image/png", data)
                    return
            self.send_content(404, "text/plain; charset=utf-8", b"Capture not available.\n")
        except (AdmissionError, OSError, ValueError, UnicodeError, struct.error, RecursionError):
            self.send_content(503, "text/plain; charset=utf-8",
                              b"Snapshot admission failed. Publish complete files, then retry.\n")

    def do_GET(self):
        self.serve_read()

    def do_HEAD(self):
        self.serve_read()

    def unsupported(self):
        status = 405 if request_allowed(self.headers, self.server.authority) else 403
        self.send_content(status, "text/plain; charset=utf-8", b"Read-only viewer.\n")

    do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_TRACE = do_CONNECT = unsupported


class ViewerServer(HTTPServer):
    allow_reuse_address = False

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(3)
        return connection, address


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Pinned artifact directory")
    parser.add_argument("--manifest", default="manifest.json", help="Manifest path below root")
    args = parser.parse_args()
    manifest = Path(args.manifest)
    if manifest.is_absolute():
        manifest = manifest.relative_to(args.root.absolute())
    store = ArtifactStore(args.root, manifest.as_posix())
    server = None
    try:
        store.snapshot()  # Fail admission before opening the listener.
        assets = PinnedRoot(Path(__file__).absolute().parent)
        try:
            index, _ = assets.read("index.html", 128 << 10)
        finally:
            assets.close()
        directives = ["default-src 'none'", "img-src 'self'", "connect-src 'self'",
                      "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"]
        for tag, directive in (("script", "script-src"), ("style", "style-src")):
            blocks = re.findall(r"<" + tag + r">([\s\S]*?)</" + tag + r">", index.decode("utf-8"))
            require(len(blocks) == 1, "Expected one embedded script and stylesheet")
            digest = base64.b64encode(hashlib.sha256(blocks[0].encode()).digest()).decode()
            directives.append(directive + " 'sha256-" + digest + "'")
        server = ViewerServer(("127.0.0.1", 0), ViewerHandler)
        server.store, server.index, server.csp = store, index, "; ".join(directives)
        server.authority = "127.0.0.1:" + str(server.server_port)
        print("http://" + server.authority + "/", flush=True)
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        if server is not None:
            server.server_close()
        store.root.close()


if __name__ == "__main__":
    main()
