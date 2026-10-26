#!/usr/bin/env python3
"""Data-only admission/router tests. No listener, browser, app or operator access."""
from email.message import Message
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
import zlib

import server


def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))


def png():
    # A private one-pixel parser fixture, not a claimed native screenshot.
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\xff"))
            + chunk(b"IEND", b""))


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="selftest-", dir=Path(__file__).parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "captures"
        self.root.mkdir()
        (self.root / "case.png").write_bytes(png())
        self.case = {"id": "case-dark", "label": "Private test capture", "image": "case.png",
                     "width": 1, "height": 1, "appearance": "dark", "viewportWidth": 683}
        self.publish()
        self.store = server.ArtifactStore(self.root)
        self.addCleanup(self.store.root.close)

    def publish(self, cases=None):
        (self.root / "manifest.json").write_text(json.dumps({
            "version": 1, "cases": [self.case] if cases is None else cases}))

    def headers(self, **values):
        headers = Message()
        headers["Host"] = "127.0.0.1:12345"
        for name, value in values.items():
            headers[name] = value
        return headers

    def request(self, path, headers=None, method="GET"):
        # Call the actual handler without constructing HTTPServer or a socket.
        handler = object.__new__(server.ViewerHandler)
        handler.path, handler.command = path, method
        handler.headers = self.headers() if headers is None else headers
        handler.server = SimpleNamespace(store=self.store, authority="127.0.0.1:12345",
                                         index=b"private index", csp="default-src 'none'")
        responses = []
        handler.send_content = lambda *args: responses.append(args)
        if method in ("GET", "HEAD"):
            handler.serve_read()
        else:
            handler.unsupported()
        return responses[0]

    def test_authorized_png_and_sanitized_manifest_route(self):
        response = self.request("/manifest.json")
        self.assertEqual(response[0], 200)
        public = json.loads(response[2])["cases"][0]
        self.assertNotIn("case.png", response[2].decode())
        self.assertEqual(public["image"]["sha256"], hashlib.sha256(png()).hexdigest())
        image = self.request(public["image"]["url"])
        self.assertEqual(image[:2], (200, "image/png"))
        self.assertEqual(image[2], png())

    def test_only_fixed_and_authorized_routes_are_served(self):
        for target in ["/case.png", "/manifest.json?path=case.png", "/../case.png",
                       "/%2e%2e/case.png", "/server.py", "/image/missing/main?sha256=" + "0" * 64]:
            self.assertEqual(self.request(target)[0], 404, target)
        self.assertEqual(self.request("/")[0], 200)
        self.assertEqual(self.request("/", method="HEAD")[0], 200)
        self.assertEqual(self.request("/", method="POST")[0], 405)

    def test_strict_host_origin_and_fetch_site(self):
        for host in ["localhost:12345", "127.0.0.1:9999", "evil.example:12345"]:
            headers = self.headers(); headers.replace_header("Host", host)
            self.assertEqual(self.request("/manifest.json", headers)[0], 403)
        for origin in ["null", "https://127.0.0.1:12345", "http://127.0.0.1:9999", "https://evil.example"]:
            self.assertEqual(self.request("/", self.headers(Origin=origin))[0], 403)
        self.assertEqual(self.request("/", self.headers(Origin="http://127.0.0.1:12345"))[0], 200)
        for site in ["cross-site", "same-site"]:
            self.assertFalse(server.request_allowed(self.headers(**{"Sec-Fetch-Site": site}), "127.0.0.1:12345"))

    def test_duplicate_headers_and_request_bodies_are_rejected(self):
        for name in ["Host", "Origin", "Sec-Fetch-Site", "Content-Length"]:
            headers = self.headers()
            if name != "Host":
                headers[name] = "0"
            headers[name] = "0"
            self.assertFalse(server.request_allowed(headers, "127.0.0.1:12345"))
        self.assertFalse(server.request_allowed(self.headers(**{"Content-Length": "1"}), "127.0.0.1:12345"))
        self.assertFalse(server.request_allowed(self.headers(**{"Transfer-Encoding": "chunked"}), "127.0.0.1:12345"))

    def test_traversal_absolute_and_backslash_manifest_paths_rejected(self):
        for value in ["../case.png", "/case.png", "a/../case.png", "a\\case.png", "./case.png"]:
            self.case["image"] = value; self.publish()
            self.assertEqual(self.request("/manifest.json")[0], 503, value)

    def test_leaf_and_ancestor_symlinks_rejected(self):
        (self.root / "leaf.png").symlink_to("case.png")
        (self.root / "linked-dir").symlink_to(self.root, target_is_directory=True)
        for value in ["leaf.png", "linked-dir/case.png"]:
            self.case["image"] = value; self.publish()
            self.assertEqual(self.request("/manifest.json")[0], 503)

    def test_hardlinked_and_nonregular_images_rejected(self):
        os.link(self.root / "case.png", self.root / "alias.png")
        self.assertEqual(self.request("/manifest.json")[0], 503)
        (self.root / "alias.png").unlink()
        os.mkfifo(self.root / "pipe.png")
        self.case["image"] = "pipe.png"; self.publish()
        self.assertEqual(self.request("/manifest.json")[0], 503)

    def test_pinned_root_replacement_rejected(self):
        old = self.root.with_name("old-captures"); self.root.rename(old)
        self.root.mkdir()
        self.assertEqual(self.request("/manifest.json")[0], 503)

    def test_png_bytes_dimensions_and_crc_rejected(self):
        for content in [b"\xff\xd8JPEG despite PNG filename", png()[:-1], png()[:-4] + b"bad!"]:
            (self.root / "case.png").write_bytes(content)
            self.assertEqual(self.request("/manifest.json")[0], 503)
        (self.root / "case.png").write_bytes(png())
        self.case["width"] = 2; self.publish()
        self.assertEqual(self.request("/manifest.json")[0], 503)

    def test_duplicate_ids_keys_invalid_schema_and_boolean_sizes_rejected(self):
        self.publish([self.case, self.case]); self.assertEqual(self.request("/manifest.json")[0], 503)
        (self.root / "manifest.json").write_text('{"version":1,"version":1,"cases":[]}')
        self.assertEqual(self.request("/manifest.json")[0], 503)
        self.case["height"] = True; self.publish()
        self.assertEqual(self.request("/manifest.json")[0], 503)
        self.case["height"] = 1; self.case["extra"] = "ignored fields must not be admitted"; self.publish()
        self.assertEqual(self.request("/manifest.json")[0], 503)

    def test_reference_is_explicitly_admitted_and_revocation_is_immediate(self):
        self.case["reference"] = {"image": "case.png", "width": 1, "height": 1, "label": "Reference"}
        self.publish()
        payload, authorized = self.store.snapshot()
        reference_url = json.loads(payload)["cases"][0]["reference"]["url"]
        self.assertEqual(self.request(reference_url)[0], 200)
        self.assertEqual(len(authorized), 2)
        self.publish([])
        self.assertEqual(self.request(reference_url)[0], 404)

    def test_changed_capture_is_not_served_under_old_digest(self):
        payload, _ = self.store.snapshot()
        old_url = json.loads(payload)["cases"][0]["image"]["url"]
        # Valid PNG, changed ancillary metadata, same pixel dimensions.
        changed = png()[:-12] + chunk(b"tEXt", b"label\x00changed") + png()[-12:]
        (self.root / "case.png").write_bytes(changed)
        self.assertEqual(self.request(old_url)[0], 404)
        payload, _ = self.store.snapshot()
        new_url = json.loads(payload)["cases"][0]["image"]["url"]
        self.assertNotEqual(new_url, old_url)
        self.assertEqual(self.request(new_url)[2], changed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
