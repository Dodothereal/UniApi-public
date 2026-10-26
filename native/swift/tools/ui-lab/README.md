# Read-only native capture viewer

This is a saved-image inspection tool, not an imitation or implementation of
UniApi. It displays supplied native PNG artifacts unchanged. There are no
application action/input APIs, app sessions, backend adapters, operator stores,
external scripts, fonts, analytics, network providers or subprocesses.

## Start the viewer

Choose the actual capture directory and a manifest below it:

```sh
python3 -B native/swift/tools/ui-lab/server.py \
  --root "$(pwd)/.cache/ACTUAL-CAPTURE-ROOT" \
  --manifest manifest.json
```

The command validates the initial manifest/images before binding, then prints one URL such as
`http://127.0.0.1:49152/`. The OS chooses a free ephemeral port; there is no fixed
port, auto-open or app launch. Open that exact printed URL in the in-app browser. Ctrl-C closes this viewer's listener/descriptors;
it signals no other process. No environment variables or service state change.
An absolute --manifest path is also accepted if it is lexically below --root.

Run data-only tests separately:

```sh
python3 -B native/swift/tools/ui-lab/selftest.py
```

The twelve tests use private temporary files below this folder, the actual
admission/router code and no listening socket, browser, app or operator data.
Their one-pixel PNG is a parser fixture, never a claimed native capture.
The public preview validation scope is recorded in [Validation](../../../../docs/VALIDATION.md).

## Artifact manifest v1

```json
{
  "version": 1,
  "cases": [
    {
      "id": "arena-dark683",
      "label": "Arena populated / narrow",
      "page": "Arena",
      "image": "arena-dark683/initial.png",
      "width": 1366,
      "height": 1536,
      "viewportWidth": 683,
      "appearance": "dark",
      "reference": {
        "image": "references/arena-dark683.png",
        "width": 1366,
        "height": 1536,
        "label": "Earlier native capture"
      }
    }
  ]
}
```

No example capture directory/files are created. Required case fields are id,
label, image, width, height and appearance. Optional fields are page,
viewportWidth and reference. Reference requires image/width/height; its label
is optional. All paths are relative to the pinned root. Width/height must equal
the actual PNG's pixel dimensions; optional viewportWidth describes the native
layout width in points, independently of capture scale. Appearance is exactly
light or dark. IDs are unique ASCII, start alphanumeric and contain at most80
characters from letters/digits/dot/underscore/hyphen. Labels are bounded plain
text. Unknown fields, duplicate JSON keys, duplicate IDs and boolean dimensions
are rejected. An empty cases list is allowed.

Write complete PNGs first, then atomically publish the manifest. To replace a
capture, atomically replace the regular PNG file; do not write it in place
during a read. The manifest can change while the server is running. A missing,
malformed or partially published admitted file fails the entire manifest
closed with a generic503 response. Replaced file identities/digests are
rechecked; revoked IDs no longer have an image route. No image is copied,
converted, downsampled or rewritten by the server.

## Inspection controls

- Case picker with text search, Light/Dark and width filters. It shows page,
  appearance, native viewport points when supplied and actual image pixels.
- Fit keeps the complete image visible;1x maps one image pixel to one CSS
  pixel;2x doubles CSS dimensions. Overflow panes are keyboard-focusable and
  scrollable. These scales describe browser CSS pixels, not physical display
  pixels or native app points. The browser's own page zoom remains independent.
- Optional reference checkbox shows the separately admitted PNG alongside the
  current image; narrow panes stack them. Each caption exposes a SHA-256 prefix
  and its full hash in a title. No custom rendering is placed over the image.
- Manifest refresh every five seconds only while document.visible, using
  ETags. Hidden/pagehide cancels the pending fetch/timer; visibility return
  refreshes immediately. Image panes rebuild only when their selected case, image hashes, comparison
  mode or zoom changes (or Refresh explicitly requests a retry). Unrelated
  manifest updates preserve pane focus and scroll. Stable image hashes are cached by file identity and
  size/mtime/ctime; changed images are hashed and structurally checked again.

## Security and scope

The server binds only127.0.0.1 with port0. Before serving any viewer data it
requires the exact127.0.0.1:port Host, rejects duplicate Host/Origin headers,
and permits only absent Origin or the exact http origin on that listener.
Origin:null, foreign ports/schemes and Sec-Fetch-Site cross-site/same-site are
rejected. Normal browser top-level navigation without Origin remains allowed.
Requests with transfer encoding or a nonzero/duplicate content length are
rejected. GET/HEAD are the only data methods; other methods have no action API.
No CORS permissions are granted. CSP allows only the embedded hashed script
and stylesheet, same-origin images/fetch, and forbids frames/forms/base URLs.
Headers also set nosniff, no-store and same-origin resource policy.

The only resources are / or /index.html, /manifest.json (a sanitized public
projection), and /image/CASE_ID/main-or-reference?sha256=DIGEST. There is no
directory listing, root/manifest path exposure, arbitrary path route, file URL,
upload, shell, proxy, redirect, action or app-input endpoint. Metadata is
rendered with textContent, never HTML. The manifest grants image authorization;
the server does not discover captures by directory enumeration.

Absolute root ancestors and every manifest/image path component are opened
with no-follow directory/file descriptors. Root device/inode is pinned and
rechecked. Leaves must be regular files with one hardlink; symlinks, hardlinks,
FIFOs, traversal and absolute image paths are refused. File identities are
checked before/after reads. PNG signature, bounded chunk lengths/CRCs, IHDR
dimensions and terminal IEND are checked; JPEG bytes with a.png name fail.
PNG structure is not a full decoder/provenance proof. The caller must supply actual
native captures and their own source/case evidence; this tool cannot infer
that an arbitrary valid PNG came from the actual production view.

Bounds:1MiB manifest,128 cases,32MiB per image,32768 per dimension and64million
pixels per image. HTTP connections have a three-second socket timeout and
responses close the connection. A local same-user process can read admitted
captures; this is not an authenticated multi-user service or a safe way to
publish sensitive images. No install, application isolation, visual parity,
input behavior or performance acceptance follows from preparing this viewer.
