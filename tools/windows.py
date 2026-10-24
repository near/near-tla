#!/usr/bin/env python3
"""Fold print-only "window" reports of a TLC run into intervals of prepaid gas.

A window run checks a print-only invariant instead of a real one, so TLC explores the
whole state space and prints every bad state instead of stopping at the first. The
spec reports a bad state with

    PrintT(<<"WIN", "<label>", <gas>, ...>>)

- "WIN" is a literal marker;
- <label> is a string naming what broke (usually the real invariant's name);
- <gas> is an integer, the prepaid gas of the transaction in Ggas (1 Tgas = 1000);
- any further tuple elements are ignored here (use them for your own debugging).

A print-only invariant has the shape `Bad => PrintT(<<"WIN", "Books", gas, ...>>)`;
PrintT returns TRUE, so the run itself passes.

`fold` merges the reported gas values per label into closed intervals; values at most
`step` apart (the gas menu's step, default 100 Ggas = 0.1 Tgas) join one interval.

CLI: windows.py [--step N] <log>...   prints the intervals in Tgas.
"""

from __future__ import annotations

import argparse
import re
import sys

_WIN = re.compile(r'<<\s*"WIN"\s*,\s*"([^"]*)"\s*,\s*(-?\d+)')


def reports(text: str) -> dict[str, set[int]]:
    """label -> set of gas values (Ggas) found in a TLC log."""
    flat = " ".join(text.split())
    out: dict[str, set[int]] = {}
    for label, gas in _WIN.findall(flat):
        out.setdefault(label, set()).add(int(gas))
    return out


def fold(values, step: int = 100) -> list[tuple[int, int]]:
    """Sorted values -> closed intervals; neighbours at most `step` apart merge."""
    out: list[list[int]] = []
    for x in sorted(values):
        if out and x - out[-1][1] <= step:
            out[-1][1] = x
        else:
            out.append([x, x])
    return [(a, b) for a, b in out]


def windows(text: str, step: int = 100) -> dict[str, list[tuple[int, int]]]:
    return {k: fold(v, step) for k, v in sorted(reports(text).items())}


def parse_spec(spec: str) -> list[tuple[int, int]]:
    """'39800-40700, 41000' -> [(39800, 40700), (41000, 41000)] (Ggas). '' -> []."""
    out = []
    for part in [p.strip() for p in spec.split(",") if p.strip()]:
        if "-" in part[1:]:
            i = part.index("-", 1)
            out.append((int(part[:i]), int(part[i + 1:])))
        else:
            out.append((int(part), int(part)))
    return out


def fmt_ggas(iv: list[tuple[int, int]]) -> str:
    return ", ".join(f"{a}-{b}" if a != b else f"{a}" for a, b in iv) or "-"


def fmt_tgas(iv: list[tuple[int, int]]) -> str:
    return ", ".join(f"{a / 1000:.1f}-{b / 1000:.1f}" if a != b else f"{a / 1000:.1f}" for a, b in iv) or "-"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--step", type=int, default=100, help="max gap (Ggas) inside one interval")
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args(argv)
    for log in a.logs:
        with open(log, encoding="utf-8", errors="replace") as f:
            w = windows(f.read(), a.step)
        if not w:
            print(f"{log}: no window")
        for label, iv in w.items():
            print(f"{log}: {label} at {fmt_tgas(iv)} Tgas")
    return 0


if __name__ == "__main__":
    sys.exit(main())
