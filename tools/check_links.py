#!/usr/bin/env python3
"""Check relative links and #anchors in Markdown files, offline.

usage: tools/check_links.py [PATH...]   (default: the repo root)

For every *.md file (skipping .git, build/, target/ and node_modules/), each inline link
[text](target) and reference definition [label]: target is checked:
- http(s)://, mailto: and other URL schemes are skipped (no network);
- a relative path must exist (relative to the file; a leading / means the repo root);
- a #anchor must match a heading in the target Markdown file (GitHub's slug rules:
  lowercase, punctuation dropped, spaces to '-', duplicates get -1, -2, ...) or an
  explicit <a name="..."> / id="..." in it.
Links inside fenced code blocks and inline code spans are ignored.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", "build", "target", "node_modules", ".venv"}

FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"<a\s+[^>]*(?:name|id)\s*=\s*\"([^\"]+)\"|\bid\s*=\s*\"([^\"]+)\"")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def slug(text: str) -> str:
    t = re.sub(r"<[^>]+>", "", text)  # inline html
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)  # links -> their text
    t = t.replace("`", "").strip().lower()
    t = re.sub(r"[^\w\- ]", "", t)  # keep letters, digits, _, -, space
    return t.replace(" ", "-")


def lines_outside_code(text: str, strip_inline: bool = True):
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        m = FENCE.match(line)
        if m:
            if fence is None:
                fence = m.group(1)
            elif line.strip().startswith(fence):
                fence = None
            continue
        if fence is None:
            yield n, INLINE_CODE.sub("", line) if strip_inline else line


def anchors(path: Path, cache: dict) -> set[str]:
    if path not in cache:
        seen: dict[str, int] = {}
        out: set[str] = set()
        text = path.read_text(encoding="utf-8", errors="replace")
        for _, line in lines_outside_code(text, strip_inline=False):
            m = HEADING.match(line)
            if m:
                s = slug(m.group(2))
                k = seen.get(s, 0)
                out.add(s if k == 0 else f"{s}-{k}")
                seen[s] = k + 1
            for a, b in HTML_ANCHOR.findall(line):
                out.add(a or b)
        cache[path] = out
    return cache[path]


def md_files(paths: list[Path]) -> list[Path]:
    out = []
    for p in paths:
        if p.is_file():
            out.append(p)
            continue
        for f in sorted(p.rglob("*.md")):
            if not SKIP_DIRS.intersection(f.relative_to(p).parts):
                out.append(f)
    return out


def check(files: list[Path]) -> list[str]:
    errs, cache = [], {}
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        for n, line in lines_outside_code(text):
            targets = INLINE_LINK.findall(line)
            m = REF_DEF.match(line)
            if m:
                targets.append(m.group(1))
            for t in targets:
                if SCHEME.match(t) or t.startswith("//"):
                    continue
                path_part, _, frag = t.partition("#")
                path_part = unquote(path_part.split("?")[0])
                if path_part:
                    base = ROOT if path_part.startswith("/") else f.parent
                    target = (base / path_part.lstrip("/")).resolve()
                else:
                    target = f.resolve()
                where = f"{f.relative_to(ROOT) if f.resolve().is_relative_to(ROOT) else f}:{n}"
                if not target.exists():
                    errs.append(f"{where}: broken link {t}")
                    continue
                if frag and target.is_file() and target.suffix.lower() == ".md":
                    if unquote(frag).lower() not in {a.lower() for a in anchors(target, cache)}:
                        errs.append(f"{where}: missing anchor #{frag} in {path_part or f.name}")
    return errs


def main(argv=None) -> int:
    args = sys.argv[1:] if argv is None else argv
    files = md_files([Path(a).resolve() for a in args] or [ROOT])
    errs = check(files)
    for e in errs:
        print(e)
    print(f"{len(files)} markdown files, {len(errs)} broken links")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
