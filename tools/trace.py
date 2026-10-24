#!/usr/bin/env python3
"""Summarise the counterexample in a TLC log.

TLC prints a violating behaviour as numbered states:

    State 1: <Initial predicate>
    /\\ x = 0
    /\\ y = {}

    State 2: <Next line 7, col 9 to line 7, col 27 of module M>
    ...

`states(text)` returns [(number, action, {var: value})]; values are TLC's text with
whitespace collapsed. `summary(text)` prints the initial state, then for each step the
action name and only the variables that changed.

CLI: trace.py [--width N] <log>
"""

from __future__ import annotations

import argparse
import re
import sys

_STATE = re.compile(r"^State (\d+): (.*)$")
_VAR = re.compile(r"^(?:/\\ )?([A-Za-z_][A-Za-z0-9_]*) = (.*)$")


def _action(header: str) -> str:
    h = header.strip()
    if h.startswith("<") and h.endswith(">"):
        h = h[1:-1]
    return h.split(" line ")[0].strip() or h


def states(text: str) -> list[tuple[int, str, dict[str, str]]]:
    out: list[tuple[int, str, dict[str, str]]] = []
    cur: dict[str, str] | None = None  # variables of the state block being read
    var = None
    for line in text.splitlines():
        m = _STATE.match(line)
        if m:
            cur, var = {}, None
            out.append((int(m.group(1)), _action(m.group(2)), cur))
            continue
        if cur is None:
            continue
        if not line.strip():  # a blank line ends the state block
            cur = None
            continue
        mv = _VAR.match(line)
        # A new variable starts with "/\ " (several variables) or is the block's first line.
        if mv and (line.startswith("/\\ ") or var is None):
            var = mv.group(1)
            cur[var] = mv.group(2).strip()
        elif var is not None:
            cur[var] += " " + line.strip()
    for _, _, vs in out:
        for k in vs:
            vs[k] = " ".join(vs[k].split())
    return out


def _cut(s: str, width: int) -> str:
    return s if width <= 0 or len(s) <= width else s[: width - 3] + "..."


def summary(text: str, width: int = 160) -> str:
    st = states(text)
    if not st:
        return "(no counterexample in log)"
    lines = []
    prev: dict[str, str] = {}
    for n, act, vs in st:
        lines.append(f"State {n}: {act}")
        changed = vs if not prev else {k: v for k, v in vs.items() if prev.get(k) != v}
        for k, v in changed.items():
            lines.append(f"    {k} = {_cut(v, width)}")
        if prev and not changed:
            lines.append("    (no change)")
        prev = vs
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--width", type=int, default=160, help="truncate values to N chars (0 = no limit)")
    ap.add_argument("log")
    a = ap.parse_args(argv)
    with open(a.log, encoding="utf-8", errors="replace") as f:
        print(summary(f.read(), a.width))
    return 0


if __name__ == "__main__":
    sys.exit(main())
