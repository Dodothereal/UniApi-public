# Zstandard decoder

This directory contains the unmodified Zstandard 1.5.7 decompressor, compiled
into the native application. Reading compressed Codex history requires no
installed command, subprocess, network request or extracted transcript file.

Upstream: https://github.com/facebook/zstd
Tag: `v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`.
The upstream `LICENSE` (BSD) and `COPYING` (GPLv2 alternative) are preserved.
UniApi uses the BSD license option.

`zstddeclib.c` was generated with upstream's unmodified amalgamator:

```sh
cd build/single_file_libs
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

SHA-256 identities:

- `zstddeclib.c`: `5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0`.
- `include/zstd.h`: `9b4bc8245565c98ccfc61c07749928b57e7c0f6fddb0530c4f6aa1971893d88b`.
- `include/zstd_errors.h`: `66a8c3f71d12ea6e797e4f622f31f3f8f81c41b36f48cad4f5de7d8bfb6aac0a`.

Only the decompressor is included. Swift owns file admission, cancellation,
stream framing, metadata projection and cache publication. Keep this source
unchanged when updating the wrapper; upstream changes require a version update.
