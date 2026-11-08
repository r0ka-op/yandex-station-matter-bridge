#!/usr/bin/env python3
"""Fail when the candidate Git tree contains private or generated artifacts."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEXT_EXTENSIONS = {
    ".c", ".cs", ".http", ".ini", ".json", ".md", ".ps1", ".psd1",
    ".py", ".sh", ".toml", ".txt", ".xml", ".yaml", ".yml",
}
FORBIDDEN_SUFFIXES = {
    ".der", ".elf", ".key", ".p12", ".p7b", ".pcap", ".pcapng",
    ".pem", ".pfx", ".tar", ".zip",
}
PATTERNS = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "lab-ip": re.compile(r"\b192\.168\.10\.\d{1,3}\b"),
    "private-ssh-alias": re.compile(r"\btest-stend-" + r"alice\b", re.I),
    "private-node-id": re.compile(r"(?:nodeId\s*[\"']?\s*[:=]\s*|Node ID\s+`?)258\b", re.I),
    "private-mac": re.compile(r"\bEC34E262" + r"3DC7\b", re.I),
    "windows-user-path": re.compile(r"[A-Za-z]:\\Users\\[^\\\s]+", re.I),
    "unix-home-path": re.compile(r"/" + r"home/[^/\s]+/"),
}


def candidate_files() -> list[Path]:
    proc = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, text=True, capture_output=True, check=True,
    )
    return [ROOT / line for line in proc.stdout.splitlines() if line]


def main() -> int:
    failures: list[str] = []
    for path in candidate_files():
        rel = path.relative_to(ROOT).as_posix()
        if not path.is_file():
            continue
        parts = set(path.parts)
        if {"__pycache__", ".pytest_cache", ".venv"} & parts:
            failures.append(f"generated directory: {rel}")
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            failures.append(f"forbidden artifact type: {rel}")
        if path.stat().st_size > 2 * 1024 * 1024:
            failures.append(f"unexpected file over 2 MiB: {rel}")
        if path.suffix.lower() not in TEXT_EXTENSIONS and path.name not in {
            "LICENSE", "NOTICE", ".gitignore",
        }:
            continue
        try:
            text = path.read_text(encoding="utf-8-sig")
        except UnicodeDecodeError:
            failures.append(f"non-UTF-8 text candidate: {rel}")
            continue
        for name, pattern in PATTERNS.items():
            if pattern.search(text):
                failures.append(f"{name}: {rel}")
    if failures:
        print("PUBLICATION_SAFETY=FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"PUBLICATION_SAFETY=PASS files={len(candidate_files())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
