#!/usr/bin/env python3
"""Check local Markdown links without network access."""
from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def main() -> int:
    failures: list[str] = []
    checked = 0
    for document in ROOT.rglob("*.md"):
        if ".git" in document.parts or any(p in {".venv", "build", "dist"} for p in document.parts):
            continue
        text = document.read_text(encoding="utf-8-sig")
        for raw in LINK.findall(text):
            target = raw.strip().strip("<>").split("#", 1)[0]
            if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                continue
            checked += 1
            resolved = (document.parent / unquote(target)).resolve()
            if not resolved.exists():
                failures.append(f"{document.relative_to(ROOT)} -> {raw}")
    if failures:
        print("MARKDOWN_LINKS=FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"MARKDOWN_LINKS=PASS checked={checked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
