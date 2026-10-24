#!/usr/bin/env python3
"""Check relative links and #anchors in Markdown files, offline.

usage: tools/check_links.py [--root DIR] [PATH...]   (default: the repo root)

For every *.md file (skipping .git, build/, target/ and node_modules/), each inline link
[text](target) or [text](<target with spaces>) and each reference definition
[label]: target is checked:
- http(s)://, mailto: and other URL schemes are skipped (no network);
- a relative path must exist (relative to the file; a leading / means the root), with
  exactly the same letter case (so macOS behaves like Linux), and must stay inside the
  root;
- a #anchor must match a heading in the target Markdown file (ATX "# x" or setext
  "x" + "===" / "---"; GitHub's slug rules: emphasis and code markers dropped,
  lowercase, punctuation dropped, spaces to '-', duplicates get -1, -2, ...) or an
  explicit <a name="..."> / id="..." in it.
Links inside fenced or 4-space-indented code blocks and inline code spans are ignored,
and so are footnote definitions ([^1]: ...).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", "build", "target", "node_modules", ".venv"}

FENCE = re.compile(r"^ {0,3}(```+|~~~+)")
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
INLINE_LINK = re.compile(
    r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(?:<([^<>\n]*)>|([^()\s]+))"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)")
REF_DEF = re.compile(r"^ {0,3}\[(?!\^)[^\]]+\]:\s*(?:<([^<>\n]*)>|(\S+))")
ATX = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
SETEXT = re.compile(r"^ {0,3}(=+|-+)\s*$")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
HTML_ANCHOR = re.compile(r"<a\s+[^>]*(?:name|id)\s*=\s*\"([^\"]+)\"|\bid\s*=\s*\"([^\"]+)\"")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
EMPHASIS = re.compile(r"(?<![\w])(\*{1,3}|_{1,3})(?=\S)(.+?)(?<=\S)\1(?![\w])")


def slug(text: str) -> str:
    t = re.sub(r"<[^>]+>", "", text)  # inline html
    t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", t)  # links -> their text
    # emphasis markers go, but not inside code spans (where _ and * are literal)
    parts = re.split(r"(`+[^`]*`+)", t)
    t = "".join(p.strip("`") if p.startswith("`") else EMPHASIS.sub(r"\2", EMPHASIS.sub(r"\2", p))
                for p in parts)
    t = t.strip().lower()
    t = re.sub(r"[^\w\- ]", "", t)  # keep letters, digits, _, -, space
    return t.replace(" ", "-")


def prose_lines(text: str):
    """(line number, line) for lines outside fenced and indented code blocks."""
    fence = None
    prev_blank, in_indented, prev_prose = True, False, ""
    for n, line in enumerate(text.splitlines(), 1):
        m = FENCE.match(line)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        blank = not line.strip()
        indented = line.startswith(("    ", "\t"))
        if in_indented and (indented or blank):
            prev_blank = blank
            continue
        in_indented = False
        # An indented code block starts after a blank line, unless it continues a list.
        if indented and prev_blank and not LIST_ITEM.match(prev_prose) and not prev_prose.startswith((" ", "\t")):
            in_indented = True
            continue
        if not blank:
            prev_prose = line
        prev_blank = blank
        yield n, line


def anchors(path: Path, cache: dict) -> set[str]:
    if path not in cache:
        seen: dict[str, int] = {}
        out: set[str] = set()

        def add(s: str):
            k = seen.get(s, 0)
            out.add(s if k == 0 else f"{s}-{k}")
            seen[s] = k + 1

        prev = None  # previous prose line, a setext heading candidate
        for _, line in prose_lines(path.read_text(encoding="utf-8", errors="replace")):
            m = ATX.match(line)
            if m:
                add(slug(m.group(2)))
                prev = None
            elif SETEXT.match(line) and prev is not None and prev.strip() and not LIST_ITEM.match(prev) \
                    and not (line.strip().startswith("-") and not prev.strip()):
                add(slug(prev.strip()))
                prev = None
            else:
                prev = line if line.strip() else None
            for a, b in HTML_ANCHOR.findall(line):
                out.add(a or b)
        cache[path] = out
    return cache[path]


def exists_exact(root: Path, target: Path) -> bool:
    """Does `target` (inside root) exist with exactly this letter case?"""
    cur = root
    for part in target.relative_to(root).parts:
        try:
            if part not in os.listdir(cur):
                return False
        except (NotADirectoryError, FileNotFoundError):
            return False
        cur = cur / part
    return True


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


def links(line: str) -> list[str]:
    code_free = INLINE_CODE.sub("", line)
    out = [a or b for a, b in INLINE_LINK.findall(code_free)]
    m = REF_DEF.match(code_free)
    if m:
        out.append(m.group(1) or m.group(2))
    return out


def check(files: list[Path], root: Path = ROOT) -> list[str]:
    errs, cache = [], {}
    root = root.resolve()
    for f in files:
        f = f.resolve()
        name = str(f.relative_to(root)) if f.is_relative_to(root) else str(f)
        for n, line in prose_lines(f.read_text(encoding="utf-8", errors="replace")):
            for t in links(line):
                t = t.strip()
                if not t or SCHEME.match(t) or t.startswith("//"):
                    continue
                path_part, _, frag = t.partition("#")
                path_part = unquote(path_part.split("?")[0])
                where = f"{name}:{n}"
                if path_part:
                    base = root if path_part.startswith("/") else f.parent
                    target = Path(os.path.normpath(base / path_part.lstrip("/")))
                else:
                    target = f
                if not target.is_relative_to(root):
                    errs.append(f"{where}: link leaves the repository: {t}")
                    continue
                if not exists_exact(root, target):
                    errs.append(f"{where}: broken link {t}")
                    continue
                if frag and target.is_file() and target.suffix.lower() == ".md":
                    if unquote(frag).lower() not in {a.lower() for a in anchors(target, cache)}:
                        errs.append(f"{where}: missing anchor #{frag} in {path_part or f.name}")
    return errs


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="tools/check_links.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--root", default=str(ROOT), help="links may not leave this dir (default: the repo)")
    a = ap.parse_args(argv)
    root = Path(a.root).resolve()
    files = md_files([Path(p).resolve() for p in a.paths] or [root])
    errs = check(files, root)
    for e in errs:
        print(e)
    print(f"{len(files)} markdown files, {len(errs)} broken links")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
