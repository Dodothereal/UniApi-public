#!/usr/bin/env python3
"""Secret scanner for the UniApi working tree.

This repo is one `git add -A` away from publishing live API keys: providers.json
holds them in plain text by design, several docs quote real request payloads,
and agents write new tooling here constantly. So nothing reaches GitHub without
passing this scan - it runs in the pre-push hook and in CI.

    python3 tools/scan_secrets.py               # every git-tracked file
    python3 tools/scan_secrets.py --staged      # only what is staged (pre-commit)
    python3 tools/scan_secrets.py --paths a b   # specific files
    python3 tools/scan_secrets.py --all         # tracked + untracked, ignoring .gitignore

Exit codes: 0 clean, 1 findings, 2 usage/environment error.

Agents: when you add a provider whose key has a new prefix, add a rule to
PATTERNS. When a scan trips on something that is genuinely not a secret, add a
narrow entry to ALLOW - never widen a pattern to make a finding go away, and
say in the commit message why the value is safe.
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (name, compiled regex, minimum match length). The prefixes come from the
# providers this repo actually talks to plus the usual platform tokens.
PATTERNS = [
    ("anthropic key",      re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}"), 0),
    ("openai-style key",   re.compile(r"\bsk-(?!ant-)[A-Za-z0-9_\-]{24,}"), 0),
    ("nvidia nim key",     re.compile(r"\bnvapi-[A-Za-z0-9_\-]{20,}"), 0),
    ("devved key",         re.compile(r"\bdvd_[A-Za-z0-9_\-]{20,}"), 0),
    ("github token",       re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"), 0),
    ("github fine-grained", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{50,}"), 0),
    ("slack token",        re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"), 0),
    ("google api key",     re.compile(r"\bAIza[A-Za-z0-9_\-]{35}"), 0),
    ("aws access key",     re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), 0),
    ("telegram bot token", re.compile(r"\b\d{8,12}:AA[A-Za-z0-9_\-]{30,}"), 0),
    ("private key block",  re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"), 0),
    ("serpapi key",        re.compile(r"\bserpapi[_-]?key[\"'\s:=]+[0-9a-f]{40,}", re.I), 0),
    ("wispr token",        re.compile(r"\bwispr[_-]?(?:session|auth)[_-]?token[\"'\s:=]+\S{20,}", re.I), 0),
    # A credential-looking assignment with a long opaque value. Deliberately
    # conservative: it wants a secret-ish name, a separator, and >=24 chars of
    # key-shaped text, so ordinary config strings do not trip it.
    ("generic credential", re.compile(
        r"(?i)\b(?:api[_-]?key|auth[_-]?token|access[_-]?token|client[_-]?secret|password|passwd)"
        # The '=' is for base64 padding: without it any key ending in '=' or
        # '==' did not match at all, which is most base64-encoded secrets.
        r"\s*[:=]\s*[\"']([A-Za-z0-9_\-\.+/=]{24,})[\"']"), 0),
]

# Values that match a pattern but are demonstrably not live credentials.
# Substring match against the matched text.
ALLOW = (
    "REDACTED", "PLACEHOLDER", "EXAMPLE", "your-key", "your_key", "xxxxx",
    "CHANGEME", "changeme", "sk-xxx", "<key>", "dummy", "FAKE", "fake-",
    # The scanner's own rules and the docs that explain them.
    "sk-ant-[A-Za-z0-9", "nvapi-[A-Za-z0-9", "dvd_[A-Za-z0-9",
)

# Files whose contents are structurally noisy (hashes, minified bundles) and
# cannot hold a hand-written credential.
SKIP_NAMES = {"pnpm-lock.yaml", "package-lock.json", "yarn.lock"}
SKIP_DIRS = ("node_modules/", "client/dist/", "build.noindex/", ".git/", "data/", "legacy/swift-app/build/")
SKIP_EXTS = (".icns", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip", ".par", ".woff", ".woff2", ".ttf", ".pdf", ".mp3", ".mp4", ".wav")


def allowed(text):
    return any(a in text for a in ALLOW)


def scan_text(text, name="<text>"):
    """Return a list of human-readable findings for one file's contents."""
    hits = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if len(line) > 4000:
            continue  # a minified or base64 blob, not hand-written config
        for label, rx, _minlen in PATTERNS:
            for m in rx.finditer(line):
                found = m.group(1) if m.groups() else m.group(0)
                # Only the matched value is tested against the allowlist, not
                # the whole line: `const k = "sk-live..."  // not a FAKE one`
                # would otherwise be hidden by the word FAKE in the comment.
                if allowed(found):
                    continue
                masked = found[:6] + "..." + found[-4:] if len(found) > 14 else found
                hits.append("%s:%d: %s (%s)" % (name, lineno, label, masked))
    return hits


def should_skip(rel):
    if os.path.basename(rel) in SKIP_NAMES:
        return True
    if any(rel.startswith(d) or ("/" + d) in rel for d in SKIP_DIRS):
        return True
    if rel.lower().endswith(SKIP_EXTS):
        return True
    return False


def git_files(mode):
    if mode == "staged":
        cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"]
    elif mode == "all":
        cmd = ["git", "ls-files", "--cached", "--others", "--exclude-standard"]
    else:
        cmd = ["git", "ls-files"]
    try:
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print("git failed: %s" % e, file=sys.stderr)
        sys.exit(2)
    return [f for f in out.splitlines() if f.strip()]


def main():
    ap = argparse.ArgumentParser(description="Scan for credentials that must never reach GitHub.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--staged", action="store_true", help="only staged files")
    g.add_argument("--all", action="store_true", help="tracked and untracked files")
    g.add_argument("--paths", nargs="+", help="explicit paths")
    ap.add_argument("-q", "--quiet", action="store_true", help="print only findings")
    args = ap.parse_args()

    if args.paths:
        files = args.paths
    else:
        files = git_files("staged" if args.staged else "all" if args.all else "tracked")

    findings, scanned = [], 0
    for rel in files:
        if should_skip(rel):
            continue
        path = rel if os.path.isabs(rel) else os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        scanned += 1
        findings.extend(scan_text(text, rel))

    if findings:
        print("SECRET SCAN FAILED - %d finding(s) in %d files:" % (len(findings), scanned))
        for f in findings:
            print("  %s" % f)
        print("\nNothing may be pushed while this fails. Either remove the value and")
        print("untrack the file, or - if it is genuinely not a secret - add a narrow")
        print("entry to ALLOW in tools/scan_secrets.py and explain it in the commit.")
        return 1

    if not args.quiet:
        print("secret scan clean (%d files)" % scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
