#!/usr/bin/env python3
"""SANY-parse TLA+ modules and fail on any parse or semantic error.

usage: tools/sany.py [--jar JAR] [--library DIR] PATH...

PATH is a .tla file or a directory (searched recursively for *.tla, skipping build/;
an empty directory is fine, but at least one file must be found overall).
Each file is parsed from its own directory with -DTLA-Library=<its dir>:<library>
(default library: modules/).

SANY in tla2tools v1.7.4 exits 0 even when it reports semantic errors, so the output
is checked as well: any of the patterns in ERRORS, or a nonzero exit, is a failure.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

from run import ConfigError, find_jar, home_rewrite  # noqa: E402

ERRORS = re.compile(
    r"\*\*\* Errors:|Semantic errors|Parsing or semantic analysis failed|\*\*\*\s*Parse Error|"
    r"Fatal errors while parsing|Could not parse module|\*\*\* Abort messages"
)


def files(paths: list[str]) -> list[Path]:
    out: list[Path] = []
    for a in paths:
        p = Path(a)
        if p.is_dir():
            found = sorted(x for x in p.rglob("*.tla") if "build" not in x.relative_to(p).parts)
            if not found:
                print(f"note: no .tla files in {a}")
            out += found
        elif p.suffix == ".tla" and p.is_file():
            out.append(p)
        else:
            raise ConfigError(f"not a .tla file or directory: {a}")
    return list(dict.fromkeys(x.resolve() for x in out))


def sany(jar: str, f: Path, library: str) -> tuple[bool, str]:
    cmd = ["java", "-Xss16m", f"-DTLA-Library={os.pathsep.join([str(f.parent), library])}",
           "-cp", jar, "tla2sany.SANY", f.name]
    try:
        p = subprocess.run(cmd, cwd=f.parent, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=300)
    except FileNotFoundError as e:
        raise ConfigError(f"cannot run java: {e}") from e
    return p.returncode == 0 and not ERRORS.search(p.stdout), p.stdout


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="tools/sany.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--jar", help="tla2tools.jar (default tools/tla2tools.jar, else $TLA2TOOLS_JAR)")
    ap.add_argument("--library", default=str(ROOT / "modules"), help="library dir (default modules/)")
    a = ap.parse_args(argv)
    try:
        jar = find_jar(a.jar)
        fs = files(a.paths)
    except ConfigError as e:
        print(f"sany.py: {e}", file=sys.stderr)
        return 2
    if not fs:
        print("sany.py: no .tla files found", file=sys.stderr)
        return 2
    lib = str(Path(a.library).resolve())
    bad = []
    for f in fs:
        try:
            ok, out = sany(jar, f, lib)
        except ConfigError as e:
            print(f"sany.py: {e}", file=sys.stderr)
            return 2
        name = home_rewrite(os.path.relpath(f, ROOT) if f.is_relative_to(ROOT) else str(f))
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            bad.append(name)
            body = [ln for ln in out.splitlines() if ln.strip() and not ln.startswith(("Parsing file", "Semantic processing"))]
            print(home_rewrite("\n".join("    " + ln for ln in body)))
    print(f"\n{len(fs) - len(bad)}/{len(fs)} modules parse" + (f"; FAILED: {' '.join(bad)}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
