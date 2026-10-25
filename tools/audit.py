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

Each role of a method is judged on its own executions: owed ones, and unowed ones as a
callback; a direct call of the same method closes nothing. A sweep counts for the receipts in
its `covers`: "<method>" closes least-gas for a least_gas sweep and log-size for a size
sweep; "<method> <rule>" names the rule. A method with both roles has a gap per role,
labelled (owed) or (callback); for it a covers entry must name the role, "<method> <rule>
<role>", or it credits nothing (an entry naming only the method needs the role if the method
is seen in both roles on any account). A role named in a covers entry or accept key matches that role
whether or not the selected runs show the other.

`[audit] accept` silences a gap with a reason: `"<key>" = "why"` for every rule,
`"<key> <rule>"` for one, `"<key> <rule> <role>"` for one role, where the key is
`acct.method` or `method`. The library's
own token methods (ExecLib) are judged and reported apart, and none of their gaps fails
anything; where the contract's own code runs the same name, covers entries and `methods`
count only the contract's own executions.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

RULES = ("gas", "trie", "writes", "least-gas", "logs", "log-size", "inventory")
ROLES = ("owed", "callback")

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
    role: str = ""     # "owed" or "callback" ("" for an inventory gap)
    labelled: bool = False  # the method shows both roles here: label the role

    @property
    def label(self) -> str:
        return f"{self.key} ({self.role})" if self.labelled else self.key


@dataclass
class SweepRef:
    """What the audit needs of a [[sweep]]: its kind, its base run, and the receipts whose
    budget or input its knob varies (`covers`: "<method>" or "<method> <rule>")."""
    id: str
    kind: str
    runs: list[str]
    covers: list[str] = field(default_factory=list)

    def credits(self, key: str, runs: set[str], rule: str, role: str, ambiguous, shadowed) -> bool:
        """Whether the sweep closes `rule` (least-gas or log-size) for `key` in `role`: a
        covers entry names the key, as "<key>" (the kind's rule: least-gas for least_gas,
        log-size for size), "<key> <rule>" or "<key> <rule> <role>", and its base run
        executes it in that role (`runs`). An entry that names a role credits that role
        only; one that does not credits nothing if what it names (`acct.method`, or a
        method on every account) is seen in both roles (`ambiguous(name)`). No entry
        credits a library execution of a name the contract's own code also runs
        (`shadowed(name)`): the contract's own executions come first."""
        if not runs & set(self.runs):
            return False
        own = "least-gas" if self.kind == "least_gas" else "log-size"
        for c in self.covers:
            k, r, ro = (c.split(" ") + ["", ""])[:3]
            if (k == key or k == method_of(key)) and (r or own) == rule \
                    and (ro == role if ro else not ambiguous(k)) and not shadowed(k):
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
    hookless: int = 0  # runs that ran without the audit hook (an older library): no facts

    @property
    def whole(self) -> bool:
        """Every run of the file ran (with or without the hook)."""
        return self.ran + self.hookless >= self.total

    @property
    def open(self) -> list[Gap]:
        return [g for g in self.gaps if not g.accepted and not g.lib]


def failures(rep: Report) -> list[str]:
    """What --anti-vacuity counts as failed in a report: each open gap of the contract's own
    receipts, and a missing [audit] methods list. Nothing for a report on some of its file's
    runs only (its gaps may be closed by a run that did not run). Runs without the hook ran
    but say nothing: their file is still checked, on the other runs' facts."""
    if not rep.whole:
        return []
    out = [f"audit:{g.label} {g.rule}@{rep.toml}" for g in rep.open]
    if not rep.inventory:
        out.append(f"audit:methods@{rep.toml}")
    return out


def _accepted(accept: dict[str, str], key: str, rule: str, role: str = "") -> str | None:
    m = method_of(key)
    keys = [f"{key} {rule} {role}", f"{m} {rule} {role}"] if role else []
    for k in keys + [f"{key} {rule}", f"{m} {rule}", key, m]:
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
    # the contract's own executions and the library's (ExecLib) are judged apart
    by_key: dict[tuple[str, bool], list[tuple[str, Fact]]] = {}
    roles_of: dict[str, set[str]] = {}  # acct.method and method -> the roles seen
    own_names: set[str] = set()         # acct.method and method the contract's own code runs
    for run, fs in facts.items():
        for f in fs:
            by_key.setdefault((f.key, f.lib), []).append((run, f))
            if not f.lib:
                own_names |= {f.key, f.m}
            if f.owed or f.cb:
                for name in (f.key, f.m):
                    roles_of.setdefault(name, set()).add("owed" if f.owed else "callback")

    def ambiguous(name: str) -> bool:
        return len(roles_of.get(name, ())) > 1
    out: list[Gap] = []
    subjects = 0

    def gap(key, rule, text, lib, role="", both=False):
        out.append(Gap(key, rule, text, lib, _accepted(accept, key, rule, role), role, both))

    for key, lib in sorted(by_key):
        rows = by_key[(key, lib)]
        # each role is judged on its own executions: owed ones, and unowed ones as a
        # callback; a direct call of the same method closes nothing
        roles = [(owed, [(r, f) for r, f in rows if (f.owed if owed else f.cb and not f.owed)])
                 for owed in (True, False)]
        roles = [(o, sub) for o, sub in roles if sub]
        both = len(roles) == 2
        counted = False
        for owed, sub in roles:
            role = "owed" if owed else "callback"
            gas = [(r, f) for r, f in sub if f.mode == "gas"]
            fixed = any(f.fixed for _, f in gas)
            what = "owed" if owed else ("callback with a fixed budget" if fixed else "callback")
            if (owed or fixed) and not lib and not counted:
                subjects += 1
                counted = True
            shadowed = (lambda n: n in own_names) if lib else (lambda n: False)
            for rule, text in _role_gaps(key, owed, fixed, what, sub, gas, sweeps, role,
                                         ambiguous, shadowed):
                gap(key, rule, text, lib, role, both)
    for meth in methods or []:
        if not any(k == meth or method_of(k) == meth for k, lib in by_key if not lib):
            out.append(Gap(meth, "inventory", "listed in [audit] methods; no run executes it: "
                           "model it, or accept it with the reason it is out of scope",
                           False, _accepted(accept, meth, "inventory")))
    return out, subjects


def _role_gaps(key: str, owed: bool, fixed: bool, what: str, sub, gas, sweeps, role: str,
               ambiguous, shadowed):
    """(rule, text) for each gap of one role of a method: `sub` its executions in that role,
    `gas` those in gas mode; `ambiguous` and `shadowed` as for SweepRef.credits."""
    if owed or fixed:
        if not gas:
            if owed:
                yield "gas", (f"{what}; no gas-mode run executes it, so nothing checks that its "
                              "gas covers its work (without a calibration: HostFloorGas, "
                              "docs/USAGE.md section 12)")
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
            if not any(s.credits(key, {r for r, _ in gas}, "least-gas", role, ambiguous, shadowed)
                       for s in sweeps):
                yield "least-gas", (f"{what}; no least_gas sweep covers it (covers, with a base "
                                    "run that executes it in gas mode), so its need is not measured")
    logged = [(r, f) for r, f in sub if f.lgb > 0 or f.lgn > 0]
    if not logged:
        if owed:
            yield "logs", (f"{what}; declares no logs in any run: if it emits events or logs, "
                           "declare them (OLog, EvLen) with lengths from its input")
        return
    sizes = sorted({f.lgb for _, f in logged})
    if not any(s.credits(key, {r for r, _ in logged}, "log-size", role, ambiguous, shadowed)
                   for s in sweeps):
        seen = (f"{sizes[0]} bytes in every run" if len(sizes) == 1
                else f"{sizes[0]} to {sizes[-1]} bytes")
        yield "log-size", (f"{what}; logs {seen}, and no sweep covers its log size: sweep the "
                           "input its length grows with (ids, amounts, a memo) to MaxLogBytes "
                           "and MaxLogs")


def render(rep: Report) -> str:
    head = f"audit {rep.toml}"
    if not rep.whole:
        head += f" ({rep.ran + rep.hookless} of {rep.total} runs; sweeps and gaps judged on those)"
    if rep.hookless:
        head += (f" ({rep.hookless} run(s) without the audit hook, an older library, "
                 "contribute nothing)")
    own = [g for g in rep.gaps if not g.lib]
    lib = [g for g in rep.gaps if g.lib]
    open_ = [g for g in own if not g.accepted]
    head += (f": {rep.subjects} owed or fixed-budget receipt(s), {len(open_)} open gap(s)"
             + (f", {len(own) - len(open_)} accepted" if len(own) > len(open_) else "")
             + ("" if rep.inventory else "; no [audit] methods, so a method no run executes "
                "goes unreported"))
    lines = [head]
    width = max([len(g.label) for g in own] + [8])
    for g in open_:
        lines.append(f"  {g.label:{width}}  {g.rule:9}  {g.text}")
    for g in own:
        if g.accepted:
            lines.append(f"  {g.label:{width}}  {g.rule:9}  accepted: {g.accepted}")
    if lib:
        by: dict[str, list[str]] = {}
        for g in lib:
            by.setdefault(g.label, []).append(g.rule + (" (accepted)" if g.accepted else ""))
        lines.append("  library token methods, standard implementations (for where your "
                     "contract depends on them): "
                     + "; ".join(f"{k} {', '.join(v)}" for k, v in by.items()))
    return "\n".join(lines)
