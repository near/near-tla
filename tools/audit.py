"""The runner's audit: which receipts the runs reached, and which checks none of them made.

With the audit on (the default; `run.py --no-audit` turns it off), the runner sets the
library's `AuditOn`, and `Exec` prints one AUDIT tuple per distinct fact about each receipt it
runs (NearAsync.AuditFact). After the runs, the runner reports per runs.toml the gaps below,
from those facts, the file's `[[sweep]]` tables and its `[audit]` table
(docs/USAGE.md, "Auditing what the runs reach"):

  gas        an owed receipt that no gas-mode run executes
  trie       an owed receipt, or a callback with a fixed budget (weight 0), that runs in gas
             mode but in no run with TrieGasWorst
  writes     the same, run with TrieGasWorst, that declares no writes there (OWriteKey)
  least-gas  the same, with no least_gas sweep that covers it and whose base run executes it
             in gas mode
  logs       an owed receipt that declares no logs in any run
  log-size   an owed receipt or callback that logs, with no sweep that covers its log size
             (a size sweep, or "<method> log-size" in a least_gas sweep's covers) and whose
             base run executes it
  inventory  a method in `[audit] methods` that no run executes

Each role is judged on its own executions: an owed receipt on its owed runs, a callback on
its unowed runs as a callback, so a direct call of the same method closes nothing. A sweep
counts for the receipts in its `covers`: "<method>" closes least-gas for a least_gas sweep
and log-size for a size sweep; "<method> <rule>" names the rule.

`[audit] accept` silences a gap with a reason: `"<key>" = "why"` for every rule, or
`"<key> <rule>" = "why"` for one, where the key is `acct.method` or `method`. The library's
own token methods (ExecLib) are reported apart, and none of their gaps fails anything.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

RULES = ("gas", "trie", "writes", "least-gas", "logs", "log-size", "inventory")

_START = re.compile(r'<<\s*"AUDIT"\s*,')
_TOKEN = re.compile(r'\s*(?:"((?:[^"\\]|\\.)*)"|(TRUE|FALSE)|(-?\d+))\s*(,|>>)', re.S)
_ESC = re.compile(r'\\(.)', re.S)


@dataclass(frozen=True)
class Fact:
    to: str
    m: str
    owed: bool
    detached: bool
    cb: bool
    mode: str
    worst: bool
    known: bool
    fixed: bool
    lgn: int
    lgb: int
    trn: int
    lib: bool

    @property
    def key(self) -> str:
        return f"{self.to}.{self.m}"


_FIELDS = len(Fact.__dataclass_fields__)
_SHAPE = ("", "", False, False, False, "", False, False, False, 0, 0, 0, False)


def method_of(key: str) -> str:
    """The method of `acct.method` (account ids may hold dots; method names do not)."""
    return key.rsplit(".", 1)[-1]


def parse(text: str) -> set[Fact]:
    """The AUDIT facts in TLC's output. A tuple can span lines, and a string in it can
    hold `>>`, `,` or an escaped quote; anything that is not a whole tuple of the right
    fields is skipped."""
    out = set()
    for start in _START.finditer(text):
        pos, vals = start.end(), []
        while True:
            m = _TOKEN.match(text, pos)
            if not m:
                vals = None
                break
            s, b, n, sep = m.groups()
            vals.append(int(n) if n else (b == "TRUE" if b else _ESC.sub(r"\1", s)))
            pos = m.end()
            if sep == ">>":
                break
        if vals is not None and len(vals) == _FIELDS and \
                [type(v) for v in vals] == [type(v) for v in _SHAPE]:
            out.add(Fact(*vals))
    return out


@dataclass
class Gap:
    key: str
    rule: str
    text: str
    lib: bool = False
    accepted: str | None = None


@dataclass
class SweepRef:
    """What the audit needs of a [[sweep]]: its kind, its base run, and the receipts whose
    budget or input its knob varies (`covers`: "<method>" or "<method> <rule>")."""
    id: str
    kind: str
    runs: list[str]
    covers: list[str] = field(default_factory=list)

    def credits(self, key: str, runs: set[str], rule: str) -> bool:
        """Whether the sweep closes `rule` (least-gas or log-size) for `key`: a covers entry
        names the key, as "<key>" (the kind's rule: least-gas for least_gas, log-size for
        size) or "<key> <rule>", and its base run executes it in `runs`."""
        if not runs & set(self.runs):
            return False
        own = "least-gas" if self.kind == "least_gas" else "log-size"
        for c in self.covers:
            k, _, r = c.partition(" ")
            if (k == key or k == method_of(key)) and (r or own) == rule:
                return True
        return False


@dataclass
class Report:
    toml: str
    ran: int
    total: int
    gaps: list[Gap] = field(default_factory=list)
    subjects: int = 0
    inventory: bool = False

    @property
    def open(self) -> list[Gap]:
        return [g for g in self.gaps if not g.accepted and not g.lib]


def _accepted(accept: dict[str, str], key: str, rule: str) -> str | None:
    m = method_of(key)
    for k in (f"{key} {rule}", f"{m} {rule}", key, m):
        if k in accept:
            return accept[k]
    return None


def _names(runs) -> str:
    runs = sorted(runs)
    return ", ".join(runs[:3]) + (f" and {len(runs) - 3} more" if len(runs) > 3 else "")


def gaps(facts: dict[str, set[Fact]], sweeps: list[SweepRef], methods: list[str] | None,
         accept: dict[str, str]) -> tuple[list[Gap], int]:
    """The gaps in `facts` (run name -> its facts) and the number of the model's own
    receipts checked for gas (owed receipts and callbacks with a fixed budget)."""
    by_key: dict[str, list[tuple[str, Fact]]] = {}
    for run, fs in facts.items():
        for f in fs:
            by_key.setdefault(f.key, []).append((run, f))
    out: list[Gap] = []
    subjects = 0

    def gap(key, rule, text, lib):
        out.append(Gap(key, rule, text, lib, _accepted(accept, key, rule)))

    for key in sorted(by_key):
        rows = by_key[key]
        lib = all(f.lib for _, f in rows)
        # each role is judged on its own executions: an owed receipt on its owed runs, a
        # callback on its unowed runs as a callback; a direct call closes nothing
        roles = [(True, [(r, f) for r, f in rows if f.owed]),
                 (False, [(r, f) for r, f in rows if f.cb and not f.owed])]
        counted = False
        for owed, sub in roles:
            if not sub:
                continue
            gas = [(r, f) for r, f in sub if f.mode == "gas"]
            fixed = any(f.fixed for _, f in gas)
            what = "owed" if owed else ("callback with a fixed budget" if fixed else "callback")
            if (owed or fixed) and not counted:
                subjects += not lib
                counted = True
            for rule, text in _role_gaps(key, owed, fixed, what, sub, gas, sweeps):
                if not any(g.key == key and g.rule == rule for g in out):
                    gap(key, rule, text, lib)
    for meth in methods or []:
        if not any(k == meth or method_of(k) == meth for k in by_key):
            out.append(Gap(meth, "inventory", "listed in [audit] methods; no run executes it: "
                           "model it, or accept it with the reason it is out of scope",
                           False, _accepted(accept, meth, "inventory")))
    return out, subjects


def _role_gaps(key: str, owed: bool, fixed: bool, what: str, sub, gas, sweeps):
    """(rule, text) for one role of a receipt: `sub` its executions in that role, `gas`
    those in gas mode."""
    if owed or fixed:
        if not gas:
            if owed:
                yield "gas", (f"{what}; no gas-mode run executes it, so nothing checks that its "
                              "gas covers its work")
        else:
            worst = [f for _, f in gas if f.worst]
            if not worst:
                yield "trie", (f"{what}; runs in gas mode ({_names({r for r, _ in gas})}) but in "
                               "no run with TrieGasWorst, so its writes are charged only the "
                               "calibrated trie depth")
            elif all(f.trn == 0 for f in worst):
                yield "writes", (f"{what}; runs with TrieGasWorst but declares no writes "
                                 "(OWriteKey), so the switch charges it nothing: declare each "
                                 "storage write and remove it makes")
            if not any(s.credits(key, {r for r, _ in gas}, "least-gas") for s in sweeps):
                yield "least-gas", (f"{what}; no least_gas sweep covers it (covers, with a base "
                                    "run that executes it in gas mode), so its need is not measured")
    logged = [(r, f) for r, f in sub if f.lgb > 0 or f.lgn > 0]
    if not logged:
        if owed:
            yield "logs", (f"{what}; declares no logs in any run: if it emits events or logs, "
                           "declare them (OLog, EvLen) with lengths from its input")
        return
    sizes = sorted({f.lgb for _, f in logged})
    if not any(s.credits(key, {r for r, _ in logged}, "log-size") for s in sweeps):
        seen = (f"{sizes[0]} bytes in every run" if len(sizes) == 1
                else f"{sizes[0]} to {sizes[-1]} bytes")
        yield "log-size", (f"{what}; logs {seen}, and no sweep covers its log size: sweep the "
                           "input its length grows with (ids, amounts, a memo) to MaxLogBytes "
                           "and MaxLogs")


def render(rep: Report) -> str:
    head = f"audit {rep.toml}"
    if rep.ran < rep.total:
        head += f" ({rep.ran} of {rep.total} runs; sweeps and gaps judged on those)"
    own = [g for g in rep.gaps if not g.lib]
    lib = [g for g in rep.gaps if g.lib]
    open_ = [g for g in own if not g.accepted]
    head += (f": {rep.subjects} owed or fixed-budget receipt(s), {len(open_)} open gap(s)"
             + (f", {len(own) - len(open_)} accepted" if len(own) > len(open_) else "")
             + ("" if rep.inventory else "; no [audit] methods, so a method no run executes "
                "goes unreported"))
    lines = [head]
    width = max([len(g.key) for g in own] + [8])
    for g in open_:
        lines.append(f"  {g.key:{width}}  {g.rule:9}  {g.text}")
    for g in own:
        if g.accepted:
            lines.append(f"  {g.key:{width}}  {g.rule:9}  accepted: {g.accepted}")
    if lib:
        by: dict[str, list[str]] = {}
        for g in lib:
            by.setdefault(g.key, []).append(g.rule + (" (accepted)" if g.accepted else ""))
        lines.append("  library token methods, standard implementations (for where your "
                     "contract depends on them): "
                     + "; ".join(f"{k} {', '.join(v)}" for k, v in by.items()))
    return "\n".join(lines)
