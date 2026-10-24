#!/usr/bin/env python3
r"""Run the TLC model-checking runs declared in runs.toml files and check their expectations.

usage: tools/run.py [options] [paths...] [run names...]

Arguments are runs.toml files, directories (searched recursively for runs.toml), and
run names (shell-style globs such as 'pay_*' work). Names filter the runs of the given
paths; with names only, they are looked up under the repo's examples/. With no
arguments every run under examples/ is checked. Example, one run of your own model:
  tools/run.py path/to/model/ my_run --print-trace

For each run the runner generates
  MC_<run>.tla   a wrapper that EXTENDS the spec and defines const_<C> == <expr>
  MC_<run>.cfg   a TLC config substituting C <- const_<C> (cfg files cannot hold tuples);
                 for a key Mod!C, C <- [Mod] const_Mod_C
in a fresh temporary directory (so nothing stale can shadow a module), runs TLC there
with -DTLA-Library=<spec dir>:<library>, writes TLC's output to build/<run>.log beside
the runs.toml ($HOME rewritten to ~, temp dirs to <tmp>), parses the verdict, prints a
table and exits nonzero if any run does not match its expectation. Wrapper, cfg and log
are kept in build/ (gitignored) for mismatching runs, and for every run with --keep.

runs.toml format
----------------
  spec = "Pay"                # default module (a .tla beside runs.toml)
  workers = 2                 # TLC workers (default 2, max 4); --workers can only lower it
  library = "../../modules"   # relative to runs.toml. Default ../../modules, and if that
                              # does not exist (a model outside examples/<name>/), the
                              # modules/ dir of the repo this runner lives in. An explicit
                              # library, --library or $NEAR_TLA_LIBRARY always wins
  [constants]                 # optional: file-level constants shared by every run
  U = '"u"'

  [[run]]
  name = "pay_std"            # unique across all loaded files; [A-Za-z][A-Za-z0-9_]*
  expect = "pass"             # "pass" | "violation" | "assert" | "deadlock"
  invariant = "Books"         # required with expect = "violation": the violated name
  budget_s = 60               # wall-clock budget; a slower run fails (but is reported)
  init = "Init"               # default Init
  next = "Next"               # default Next
  # specification = "Spec"    # a temporal formula instead of init/next
  invariants = ["Books"]
  properties = []
  deadlock = false            # false (default): pass -deadlock, quiescence is fine
  stack = "256k"              # optional: the JVM thread stack (-Xss) for this run; the
                              # default is 16m (DEFAULT_STACK), for every TLC run
  tags = ["semantics:x"]      # free-form
  expect_output = 'regex'     # optional: must match TLC's output (whitespace collapsed)
  expect_window = "39800-40700"   # optional: print-only window (see tools/windows.py):
                              # ascending Ggas intervals "lo-hi, lo-hi". A string checks the
                              # union of all labels; a table { Books = "..." } checks each
                              # label and fails on labels it does not list
  window_step = 100           # optional: max gap inside one window interval (Ggas)
  allow_no_invariants = "why" # optional: lets expect = "pass" run without any invariant
                              # or property; the value must say why
  [run.constants]             # CONSTANT name -> TLA+ expression text (merged over
  Menu = '<<1, 2>>'           # [constants]); TOML ints and booleans are also accepted
  "NearFees!FeeRounding" = '"nearest"'   # Mod!Name: a definition of a module the spec
                              # EXTENDS or INSTANCEs (directly or through its modules):
                              # TLC's `Name <- [Mod] expr`, which also reaches a named
                              # instance such as NearAsync's NearFeeTable. Definitions
                              # only: a CONSTANT of Mod is an error (assign it unqualified,
                              # or bind it with INSTANCE Mod WITH)

Every key except name/expect/invariant/expect_*/window_step/allow_no_invariants may also
be given at the top level as a default for all runs of the file.

Anti-vacuity checks (run with --anti-vacuity, after the plain runs; always validated)
  [[witness]]                 # a situation that must be reachable
  id = "refund_seen"          # [A-Za-z][A-Za-z0-9_]*, unique in the file
  expr = '~(\E r \in Runnable : r.m = "on_done" /\ ~r.res.ok)'
  about = "on_done sees Failed"   # optional
  runs = ["*_ok"]             # optional globs over this file's runs; default: every
                              # expect = "pass" run without expect_window
  # expect = "unreachable"    # documented exception (default "reached"); needs
  # reason = "why"            # a reason
  The wrapper defines Wit_<id> == <expr> and TLC checks it alone, once per listed run.
  It must be violated (the situation is reached). A pass is "vacuous: witness <id>
  never reached" and fails; with expect = "unreachable" a pass is required instead.

  [[mutant]]                  # a deliberate bug some listed run must catch
  id = "skip_rollback"
  file = "Model.tla"          # a .tla beside runs.toml; with library = true, a module of
  # library = true            # the run's library (the first library dir that has it)
  find = 'ELSE rollback(S)'   # exact text; must occur `count` times (default 1),
  replace = 'ELSE S'          # checked for every mutant before any JVM starts
  count = 1
  class = "failure branch skips rollback"
  runs = ["model_ok"]         # optional, as for witnesses; expect = "pass" runs only
  # equivalent = "why"        # an accepted survivor must say why
  # killed_by = ["Books"]     # optional: the kills that count (invariant names, "assert",
  #                           # "deadlock"); default: any invariant violation
  The runner copies the spec dir's (or library dir's) .tla files into the job's temp
  dir, patches the copy and puts it in the copied dir's place on -DTLA-Library; the
  originals are never touched. Each listed run is checked with its own invariants and
  properties. Killed: some run violates an invariant (one listed in killed_by, if given).
  An Assert or a deadlock alone is reported as "killed (assert)" / "killed (deadlock)" and
  fails unless killed_by lists it: it shows the mutant broke the model, not that an
  invariant covers it. A library mutant whose module also sits beside runs.toml is refused
  (TLC would load that copy, not the patched one). Survived (every run passes) fails unless
  `equivalent` is given; a mutant marked equivalent that is killed fails too. A timeout
  or an error is its own result, never "survived", and fails. Each job has its run's
  budget_s and is stopped at it.

Sweeps (run with --sweep, after the plain runs; always validated)
  [[sweep]]                   # least gas: the smallest knob value at which `success` holds
  id = "need"                 # [A-Za-z][A-Za-z0-9_]*, unique in the file
  kind = "least_gas"
  run = "vault_gas_short"     # the base run (this file's): its constants, budget, workers
  knob = "GasMenu"            # a constant (or a list of constants) set to each value
  form = '{%d}'               # its TLA+ text, %d replaced by the value (default '%d')
  lo = 0                      # a value at which success fails (default 0)
  hi = 300000                 # a value at which it holds
  success = ["OwedOK"]        # invariants that define success (default: the run's)
  window_run = "vault_gas_win"   # optional: a print-only window run of this file; its
                              # windows' top value becomes lo and the next value hi
  # window_label = "OwedOK"   # optional: only that label's window
  # expect_need = 8600        # optional: the need must be this
  [sweep.constants]           # optional overrides of the base run's constants
  It checks hi (must hold) and lo (must fail), bisects with one TLC run per value, then
  reports need - 1, need and need + 1. The sweep fails unless need - 1 fails and need and
  need + 1 hold (a failure at need + 1 is non-monotone), or if a job ends in anything but
  pass or a violation of a success invariant.

  [[sweep]]                   # sizes: each value at 1, the cap and the protocol limit, +-1
  id = "memo"
  kind = "size"
  run = "vault_log_capped"
  knob = "Memos"
  form = '{%d}'
  cap = 16377                 # the contract's own cap (optional)
  limit = "MaxLogBytes"       # the protocol limit: a number or a NearAsync limit name
  floor = 1                   # optional: drop values below it (default 0)
  expect = { "16378" = "pass" }   # optional: verdicts per value ("pass", "violation Inv",
                              # "assert", "deadlock"); without it every verdict is reported
  Each value runs with the base run's invariants (or `success`). The sweep fails on a
  value whose verdict differs from `expect`, or on a timeout or error.

Checks
- "pass" needs TLC's exit code 0, its "No error has been found" line, and at least one
  distinct state; expect = "pass" needs at least one invariant (properties alone do not
  count), or allow_no_invariants.
- Constant names must be CONSTANTs declared by the spec or a module it EXTENDS, or
  zero-arity definitions there (TLC's `<-` overrides a definition too; the library uses
  that for overridable defaults). A `Mod!Name` key must name a zero-arity definition or
  CONSTANT of a module reachable from the spec through EXTENDS and INSTANCE. They are
  found by a simple parse of the spec dir and the library. A constant may not reuse the name of init/next/specification or of a
  checked invariant/property.
- Temporal properties: TLC does not name a violated temporal property. expect =
  "violation" with a property as `invariant` therefore requires that property to be
  the only entry of `properties`; TLC's "Temporal properties were violated" then
  matches it.
- A run slower than budget_s fails but is still reported; a run still going after
  3 x budget_s is killed and reported as "timeout".

Peel mode (--peel): on a violation, drop the violated invariant/property and rerun
until the run is clean, stops for another reason, or nothing is left; report the set
of violated names. expect = "violation" then means "the invariant is in the set"; any
other expectation requires that nothing was peeled. Peel mode checks verdicts, budgets
and vacuity only, not expect_output or expect_window.

A temporal formula goes in `specification` (not `spec`, which names the module).

--sweep: after the plain runs, run every [[sweep]] whose base run is selected, and print
a table. --least-gas 'KNOB=FORM' --gas-range LO:HI [--success INV,..] runs an ad-hoc
least-gas sweep on each selected run.

--anti-vacuity: after the plain runs, check every [[witness]] and [[mutant]] of the
selected runs (a check of a run that did not match its expectation is skipped) and print
a table and a per-file summary. Off by default; peel mode and windows are unaffected.

Environment: TLA2TOOLS_JAR (if tools/tla2tools.jar is missing), NEAR_TLA_LIBRARY
(like --library), TLC_JAVA_OPTS (extra JVM options, e.g. -Xmx4g; they come after the
default -Xss16m, so an -Xss there wins, and a run's own stack after them).
"""

from __future__ import annotations

import sys

if sys.version_info < (3, 11):
    sys.exit(f"tools/run.py needs Python 3.11 or newer (for tomllib); this is {sys.version.split()[0]}")

import argparse  # noqa: E402
import fnmatch  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import textwrap  # noqa: E402
import time  # noqa: E402
import tomllib  # noqa: E402
from dataclasses import asdict, dataclass, field, replace  # noqa: E402
from pathlib import Path  # noqa: E402

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import tlcparse  # noqa: E402
import tlctrace  # noqa: E402
import windows  # noqa: E402

MAX_WORKERS = 4
DEFAULT_LIBRARY = "../../modules"
HARD_TIMEOUT_FACTOR = 3
# TLC evaluates recursive operators on the JVM thread stack; the default (512 KB to 1 MB)
# overflows on deep evaluations (StackOverflowError). Every run gets this one.
DEFAULT_STACK = "16m"
STACK_RE = re.compile(r"^[1-9][0-9]*[kKmM]$")
EXPECTS = ("pass", "violation", "assert", "deadlock")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

FILE_KEYS = {"spec", "workers", "library", "budget_s", "init", "next", "specification",
             "invariants", "properties", "deadlock", "tags", "constants", "run", "witness", "mutant",
             "sweep", "stack"}
RUN_ONLY_KEYS = {"name", "expect", "invariant", "expect_output", "expect_window", "window_step",
                 "allow_no_invariants"}
RUN_KEYS = (FILE_KEYS - {"run", "witness", "mutant", "sweep"}) | RUN_ONLY_KEYS
WITNESS_KEYS = {"id", "expr", "about", "runs", "expect", "reason"}
MUTANT_KEYS = {"id", "file", "find", "replace", "count", "class", "runs", "library", "equivalent",
               "killed_by"}
WITNESS_EXPECTS = ("reached", "unreachable")
SWEEP_KEYS = {"id", "kind", "run", "knob", "form", "constants", "lo", "hi", "success", "window_run",
              "window_label", "expect_need", "cap", "limit", "floor", "expect"}
SWEEP_KINDS = ("least_gas", "size")
LEAST_GAS_ONLY = {"lo", "hi", "success", "window_run", "window_label", "expect_need"}
SIZE_ONLY = {"cap", "limit", "floor", "expect"}

# Standard and community modules that declare no CONSTANTS.
NO_CONSTANT_MODULES = {
    "Naturals", "Integers", "Reals", "Sequences", "FiniteSets", "TLC", "Bags", "RealTime",
    "TLCExt", "Randomization", "Json", "Bitwise", "Functions", "Folds", "FiniteSetsExt",
    "SequencesExt", "BagsExt", "IOUtils", "CSV", "Combinatorics", "Graphs", "Relation",
    "UndirectedGraphs", "DyadicRationals", "Statistics", "VectorClocks", "TLAPS",
}


class ConfigError(Exception):
    pass


@dataclass
class Run:
    name: str
    toml: Path
    spec: str
    expect: str
    library: list[str]
    workers: int = 2
    budget_s: float = 60
    init: str | None = "Init"
    next: str | None = "Next"
    specification: str | None = None
    invariants: list[str] = field(default_factory=list)
    properties: list[str] = field(default_factory=list)
    deadlock: bool = False
    tags: list[str] = field(default_factory=list)
    constants: dict[str, str] = field(default_factory=dict)
    invariant: str | None = None
    expect_output: str | None = None
    expect_window: str | dict | None = None
    window_step: int = 100
    allow_no_invariants: str | None = None
    stack: str | None = None

    @property
    def dir(self) -> Path:
        return self.toml.parent

    @property
    def build(self) -> Path:
        return self.dir / "build"


@dataclass
class Witness:
    """A [[witness]]: `expr` must be violated (the situation reached) by each run in `runs`."""
    id: str
    toml: Path
    expr: str
    runs: list[str]
    about: str = ""
    expect: str = "reached"
    reason: str | None = None

    @property
    def op(self) -> str:
        return f"Wit_{self.id}"


@dataclass
class Mutant:
    """A [[mutant]]: `find` -> `replace` in `file`; some run in `runs` must catch it."""
    id: str
    toml: Path
    file: str
    find: str
    replace: str
    cls: str
    runs: list[str]
    count: int = 1
    library: bool = False
    equivalent: str | None = None
    killed_by: list[str] | None = None  # accepted kills: invariant names, "assert", "deadlock"


@dataclass
class Sweep:
    """A [[sweep]]: least gas (bisect a knob) or sizes (1, cap and limit, +-1) on one run."""
    id: str
    toml: Path
    kind: str
    run: str
    knobs: list[str]
    form: str = "%d"
    constants: dict[str, str] = field(default_factory=dict)
    lo: int = 0
    hi: int | None = None
    success: list[str] | None = None
    window_run: str | None = None
    window_label: str | None = None
    expect_need: int | None = None
    cap: int | None = None
    limit: int | str | None = None
    floor: int = 0
    expect: dict[str, str] = field(default_factory=dict)


# Sweeps by runs.toml, filled by load_doc (which keeps its 3-tuple for callers).
_SWEEPS: dict[Path, list[Sweep]] = {}


# ---------------------------------------------------------------- loading


def tla_value(name: str, v) -> str:
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        if not v.strip():
            raise ConfigError(f"constant {name}: empty expression")
        return v
    raise ConfigError(f"constant {name}: expected TLA+ expression text (a string), got {type(v).__name__}")


def _typed(where: str, d: dict, key: str, kinds, default=None):
    """d[key] if present and of one of `kinds`, else default; ConfigError on a wrong type."""
    if key not in d:
        return default
    v = d[key]
    kinds = kinds if isinstance(kinds, tuple) else (kinds,)
    if isinstance(v, bool) and bool not in kinds:  # TOML true is not an int here
        ok = False
    else:
        ok = isinstance(v, kinds)
    if not ok:
        names = " or ".join(k.__name__ for k in kinds)
        raise ConfigError(f"{where}: {key} must be a {names}, got {type(v).__name__} {v!r}")
    return v


def _str_list(where: str, d: dict, key: str) -> list[str]:
    v = d.get(key, [])
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise ConfigError(f"{where}: {key} must be a list of strings")
    return list(v)


def load_file(path: Path) -> list[Run]:
    return load_doc(path)[0]


def load_doc(path: Path) -> tuple[list[Run], list[Witness], list[Mutant]]:
    """The runs, witnesses and mutants of one runs.toml, validated."""
    path = path.resolve()
    try:
        with open(path, "rb") as f:
            doc = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{rel(path)}: {e}") from e
    unknown = set(doc) - FILE_KEYS
    if unknown:
        raise ConfigError(f"{rel(path)}: unknown top-level keys {sorted(unknown)}")
    runs_raw = doc.get("run", [])
    if not isinstance(runs_raw, list) or not runs_raw:
        raise ConfigError(f"{rel(path)}: no [[run]] entries")
    defaults = {k: v for k, v in doc.items() if k not in ("run", "constants")}
    file_consts = doc.get("constants", {})
    out = []
    for i, raw in enumerate(runs_raw):
        where = f"{rel(path)} run #{i + 1}"
        unknown = set(raw) - RUN_KEYS
        if unknown:
            raise ConfigError(f"{where}: unknown keys {sorted(unknown)}")
        m = {**defaults, **{k: v for k, v in raw.items() if k != "constants"}}
        name = _typed(where, m, "name", str)
        if not name or not NAME_RE.match(name):
            raise ConfigError(f"{where}: name must match {NAME_RE.pattern}")
        where = f"{rel(path)} run {name}"
        spec = _typed(where, m, "spec", str)
        if not spec or not IDENT_RE.match(spec):
            raise ConfigError(f"{where}: spec must name a module")
        if not (path.parent / f"{spec}.tla").is_file():
            raise ConfigError(f"{where}: {spec}.tla not found beside runs.toml")
        expect = _typed(where, m, "expect", str)
        if expect not in EXPECTS:
            raise ConfigError(f"{where}: expect must be one of {EXPECTS}")
        lib = _typed(where, m, "library", (str, list), DEFAULT_LIBRARY)
        libs = [lib] if isinstance(lib, str) else _str_list(where, m, "library")
        libs = [str((path.parent / x).resolve()) for x in libs]
        if "library" not in m and not os.path.isdir(libs[0]):
            libs = [str(ROOT / "modules")]  # a model outside examples/<name>/
        consts = {}
        for src in (file_consts, raw.get("constants", {})):
            if not isinstance(src, dict):
                raise ConfigError(f"{where}: constants must be a table")
            for k, v in src.items():
                if not all(IDENT_RE.match(x) for x in k.split("!", 1)):
                    raise ConfigError(f"{where}: bad constant name {k!r} (Name or Mod!Name)")
                consts[k] = tla_value(k, v)
        defs: dict[str, str] = {}
        for k in consts:
            d = const_def_name(k)
            if d in defs:
                raise ConfigError(f"{where}: constants {defs[d]!r} and {k!r} both define {d}")
            defs[d] = k
        workers = _typed(where, m, "workers", int, 2)
        if not 1 <= workers <= MAX_WORKERS:
            raise ConfigError(f"{where}: workers must be 1..{MAX_WORKERS}")
        budget = _typed(where, m, "budget_s", (int, float), 60)
        if budget <= 0:
            raise ConfigError(f"{where}: budget_s must be positive")
        r = Run(
            name=name, toml=path, spec=spec, expect=expect,
            library=libs,
            workers=workers, budget_s=float(budget),
            specification=_typed(where, m, "specification", str),
            invariants=_str_list(where, m, "invariants"),
            properties=_str_list(where, m, "properties"),
            deadlock=_typed(where, m, "deadlock", bool, False),
            tags=_str_list(where, m, "tags"),
            constants=consts,
            invariant=_typed(where, m, "invariant", str),
            expect_output=_typed(where, m, "expect_output", str),
            expect_window=_typed(where, m, "expect_window", (str, dict)),
            window_step=_typed(where, m, "window_step", int, 100),
            allow_no_invariants=_typed(where, m, "allow_no_invariants", str),
            stack=_typed(where, m, "stack", str),
        )
        if r.stack is not None and not STACK_RE.match(r.stack):
            raise ConfigError(f"{where}: stack must be a JVM size such as \"256k\" or \"16m\"")
        if r.specification:
            if "init" in m or "next" in m:
                raise ConfigError(f"{where}: give either specification or init/next, not both")
            r.init = r.next = None
        else:
            r.init, r.next = _typed(where, m, "init", str, "Init"), _typed(where, m, "next", str, "Next")
        for n in [r.init, r.next, r.specification, *r.invariants, *r.properties]:
            if n is not None and not IDENT_RE.match(n):
                raise ConfigError(f"{where}: {n!r} is not an operator name")
        operators = {r.init, r.next, r.specification, *r.invariants, *r.properties} - {None}
        clash = sorted(set(r.constants) & operators)
        if clash:
            raise ConfigError(f"{where}: constants {clash} reuse the name of init/next/an invariant/property")
        if r.expect == "violation":
            if not r.invariant:
                raise ConfigError(f"{where}: expect = \"violation\" needs invariant = \"<name>\"")
            if r.invariant not in r.invariants + r.properties:
                raise ConfigError(f"{where}: invariant {r.invariant} is not in invariants/properties")
            if r.invariant in r.properties and len(r.properties) > 1:
                raise ConfigError(f"{where}: TLC does not name a violated temporal property; an expected "
                                  f"property violation must be the only entry of properties")
        elif r.invariant:
            raise ConfigError(f"{where}: invariant is only meaningful with expect = \"violation\"")
        if r.allow_no_invariants is not None and not r.allow_no_invariants.strip():
            raise ConfigError(f"{where}: allow_no_invariants must say why (a non-empty string)")
        if r.expect == "pass" and not r.invariants and not r.allow_no_invariants:
            what = "only properties" if r.properties else "no invariants or properties"
            raise ConfigError(f"{where}: expect = \"pass\" with an empty INVARIANTS section ({what}) can "
                              f"pass without checking a state; add an invariant, or set "
                              f"allow_no_invariants = \"<why>\"")
        if r.expect == "deadlock" and not r.deadlock:
            raise ConfigError(f"{where}: expect = \"deadlock\" needs deadlock = true")
        if r.expect_window is not None:
            ws = r.expect_window.values() if isinstance(r.expect_window, dict) else [r.expect_window]
            for w in ws:
                if not isinstance(w, str):
                    raise ConfigError(f"{where}: expect_window values must be strings")
                try:
                    windows.parse_spec(w)
                except ValueError as e:
                    raise ConfigError(f"{where}: bad expect_window {w!r}: {e}") from e
        if r.expect_output is not None:
            try:
                re.compile(r.expect_output)
            except re.error as e:
                raise ConfigError(f"{where}: bad expect_output regex: {e}") from e
        out.append(r)
    wits, muts = load_checks(path, doc, out)
    _SWEEPS[path] = load_sweeps(path, doc, out)
    return out, wits, muts


def load_sweeps(path: Path, doc: dict, runs: list[Run]) -> list[Sweep]:
    """Validate the [[sweep]] tables of one runs.toml."""
    raw_list = doc.get("sweep", [])
    if not isinstance(raw_list, list) or not all(isinstance(x, dict) for x in raw_list):
        raise ConfigError(f"{rel(path)}: sweep must be an array of tables ([[sweep]])")
    by = {r.name: r for r in runs}
    out: list[Sweep] = []
    for i, raw in enumerate(raw_list):
        where = f"{rel(path)} sweep #{i + 1}"
        unknown = set(raw) - SWEEP_KEYS
        if unknown:
            raise ConfigError(f"{where}: unknown keys {sorted(unknown)}")
        sid = _typed(where, raw, "id", str)
        if not sid or not NAME_RE.match(sid):
            raise ConfigError(f"{where}: id must match {NAME_RE.pattern}")
        where = f"{rel(path)} sweep {sid}"
        if any(s.id == sid for s in out):
            raise ConfigError(f"{where}: duplicate id")
        kind = _typed(where, raw, "kind", str)
        if kind not in SWEEP_KINDS:
            raise ConfigError(f"{where}: kind must be one of {SWEEP_KINDS}")
        wrong = set(raw) & (SIZE_ONLY if kind == "least_gas" else LEAST_GAS_ONLY)
        if wrong:
            raise ConfigError(f"{where}: {sorted(wrong)} do not apply to kind = \"{kind}\"")
        base = _typed(where, raw, "run", str)
        if base not in by:
            raise ConfigError(f"{where}: run {base!r} is not a run of this file")
        knob = _typed(where, raw, "knob", (str, list))
        knobs = [knob] if isinstance(knob, str) else _str_list(where, raw, "knob")
        if not knobs or not all(all(IDENT_RE.match(x) for x in k.split("!", 1)) for k in knobs):
            raise ConfigError(f"{where}: knob must name a constant (Name or Mod!Name), or a list of them")
        form = _typed(where, raw, "form", str, "%d")
        if "%d" not in form:
            raise ConfigError(f"{where}: form must contain %d (the value)")
        consts = raw.get("constants", {})
        if not isinstance(consts, dict):
            raise ConfigError(f"{where}: constants must be a table")
        sw = Sweep(sid, path, kind, base, knobs, form, {k: tla_value(k, v) for k, v in consts.items()})
        if kind == "least_gas":
            sw.lo = _typed(where, raw, "lo", int, 0)
            sw.hi = _typed(where, raw, "hi", int)
            if sw.hi is None or sw.hi <= sw.lo:
                raise ConfigError(f"{where}: hi is required and must be above lo")
            if "success" in raw:
                sw.success = _str_list(where, raw, "success")
                if not sw.success or not all(IDENT_RE.match(x) for x in sw.success):
                    raise ConfigError(f"{where}: success must be a non-empty list of invariant names")
            elif not by[base].invariants:
                raise ConfigError(f"{where}: run {base} has no invariants; give success = [...]")
            sw.window_run = _typed(where, raw, "window_run", str)
            if sw.window_run is not None and (sw.window_run not in by or by[sw.window_run].expect_window is None):
                raise ConfigError(f"{where}: window_run must name a run of this file with expect_window")
            sw.window_label = _typed(where, raw, "window_label", str)
            if sw.window_label is not None and sw.window_run is None:
                raise ConfigError(f"{where}: window_label needs window_run")
            sw.expect_need = _typed(where, raw, "expect_need", int)
        else:
            sw.cap = _typed(where, raw, "cap", int)
            sw.limit = _typed(where, raw, "limit", (int, str))
            if sw.cap is None and sw.limit is None:
                raise ConfigError(f"{where}: give cap, limit or both")
            if isinstance(sw.limit, str) and not IDENT_RE.match(sw.limit):
                raise ConfigError(f"{where}: limit must be a number or a NearAsync limit name")
            sw.floor = _typed(where, raw, "floor", int, 0)
            exp = raw.get("expect", {})
            if not isinstance(exp, dict) or not all(isinstance(v, str) for v in exp.values()):
                raise ConfigError(f"{where}: expect must be a table of value = \"verdict\" strings")
            for k, v in exp.items():
                if not re.fullmatch(r"-?\d+", k):
                    raise ConfigError(f"{where}: expect key {k!r} is not a value")
                if not (v in ("pass", "assert", "deadlock") or re.fullmatch(r"violation [A-Za-z_]\w*", v)):
                    raise ConfigError(f"{where}: expect {k} = {v!r}: give \"pass\", \"violation <Inv>\", "
                                      f"\"assert\" or \"deadlock\"")
            sw.expect = dict(exp)
        out.append(sw)
    return out


def _check_runs(where: str, d: dict, runs: list[Run], mutant: bool) -> list[str]:
    """The run names a check applies to: its `runs` globs, or the default set."""
    if "runs" in d:
        globs = _str_list(where, d, "runs")
        if not globs:
            raise ConfigError(f"{where}: runs is empty")
        names: list[str] = []
        for g in globs:
            hit = [r.name for r in runs if fnmatch.fnmatchcase(r.name, g)]
            if not hit:
                raise ConfigError(f"{where}: runs entry {g!r} matches no run of this file")
            names += [n for n in hit if n not in names]
    else:
        # print-only window runs check no real invariant: listed explicitly or not at all
        names = [r.name for r in runs if r.expect == "pass" and r.expect_window is None]
        if not names:
            raise ConfigError(f"{where}: no expect = \"pass\" run to apply to; give runs = [...]")
    if mutant:
        by = {r.name: r for r in runs}
        for n in names:
            if by[n].expect != "pass":
                raise ConfigError(f"{where}: run {n} is expect = \"{by[n].expect}\"; a mutant needs runs "
                                  f"that pass unmutated")
            if not by[n].invariants and not by[n].properties:
                raise ConfigError(f"{where}: run {n} checks no invariant, so it cannot kill a mutant")
    return names


def _nonempty(where: str, d: dict, key: str, required: bool = True) -> str | None:
    v = _typed(where, d, key, str)
    if v is None and not required:
        return None
    if v is None or not v.strip():
        raise ConfigError(f"{where}: {key} must be a non-empty string")
    return v


def load_checks(path: Path, doc: dict, runs: list[Run]) -> tuple[list[Witness], list[Mutant]]:
    """Validate the [[witness]] and [[mutant]] tables of one runs.toml."""
    wits: list[Witness] = []
    muts: list[Mutant] = []
    for kind, keys in (("witness", WITNESS_KEYS), ("mutant", MUTANT_KEYS)):
        raw_list = doc.get(kind, [])
        if not isinstance(raw_list, list) or not all(isinstance(x, dict) for x in raw_list):
            raise ConfigError(f"{rel(path)}: {kind} must be an array of tables ([[{kind}]])")
        seen: set[str] = set()
        for i, raw in enumerate(raw_list):
            where = f"{rel(path)} {kind} #{i + 1}"
            unknown = set(raw) - keys
            if unknown:
                raise ConfigError(f"{where}: unknown keys {sorted(unknown)}")
            wid = _typed(where, raw, "id", str)
            if not wid or not NAME_RE.match(wid):
                raise ConfigError(f"{where}: id must match {NAME_RE.pattern}")
            where = f"{rel(path)} {kind} {wid}"
            if wid in seen:
                raise ConfigError(f"{where}: duplicate id")
            seen.add(wid)
            names = _check_runs(where, raw, runs, kind == "mutant")
            if kind == "witness":
                expect = _typed(where, raw, "expect", str, "reached")
                if expect not in WITNESS_EXPECTS:
                    raise ConfigError(f"{where}: expect must be one of {WITNESS_EXPECTS}")
                reason = _nonempty(where, raw, "reason", required=expect == "unreachable")
                if reason is not None and expect != "unreachable":
                    raise ConfigError(f"{where}: reason is only meaningful with expect = \"unreachable\"")
                wits.append(Witness(wid, path, _nonempty(where, raw, "expr"), names,
                                    _typed(where, raw, "about", str, ""), expect, reason))
            else:
                file = _nonempty(where, raw, "file")
                if "/" in file or "\\" in file or not file.endswith(".tla"):
                    raise ConfigError(f"{where}: file must be a bare module file name such as Model.tla")
                library = _typed(where, raw, "library", bool, False)
                if not library and not (path.parent / file).is_file():
                    raise ConfigError(f"{where}: {file} not found beside runs.toml (library = true for a "
                                      f"library module)")
                if library and (path.parent / file).is_file():
                    # TLC finds the spec dir's copy first, so the patched library copy would never load
                    raise ConfigError(f"{where}: {file} is beside runs.toml, which shadows the library "
                                      f"module; patch it there (library = false) or remove it")
                killed_by = _typed(where, raw, "killed_by", list, None)
                if killed_by is not None and (not killed_by or not all(isinstance(k, str) and k for k in killed_by)):
                    raise ConfigError(f"{where}: killed_by must be a non-empty list of invariant names, "
                                      f'"assert" or "deadlock"')
                count = _typed(where, raw, "count", int, 1)
                if count < 1:
                    raise ConfigError(f"{where}: count must be at least 1")
                replace = _typed(where, raw, "replace", str)
                if replace is None:
                    raise ConfigError(f"{where}: replace is required (it may be empty)")
                find = _nonempty(where, raw, "find")
                if find == replace:
                    raise ConfigError(f"{where}: replace equals find")
                muts.append(Mutant(wid, path, file, find, replace, _nonempty(where, raw, "class"), names,
                                   count, library, _nonempty(where, raw, "equivalent", required=False),
                                   killed_by))
    return wits, muts


# ------------------------------------------------- declared CONSTANTS (light TLA+ parse)


def strip_tla(src: str) -> str:
    """Source with comments removed and string literals emptied (newlines kept)."""
    out, i, n, depth = [], 0, len(src), 0
    while i < n:
        if depth:
            if src.startswith("(*", i):
                depth, i = depth + 1, i + 2
            elif src.startswith("*)", i):
                depth, i = depth - 1, i + 2
            else:
                if src[i] == "\n":
                    out.append("\n")
                i += 1
        elif src.startswith("(*", i):
            depth, i = 1, i + 2
        elif src.startswith("\\*", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src[i] == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


_ID_LIST_ITEM = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\s*_(?:\s*,\s*_)*\s*\))?\s*(,?)")


def _id_list(text: str, pos: int) -> list[str]:
    names = []
    while True:
        m = _ID_LIST_ITEM.match(text, pos)
        if not m:
            return names
        names.append(m.group(1))
        pos = m.end()
        if not m.group(2):
            return names


_ZERO_ARITY_DEF = re.compile(r"^[ \t]*(?:LOCAL[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*==", re.M)


def module_names(src: str) -> tuple[list[str], set[str], set[str]]:
    """(EXTENDS list, declared CONSTANTs, zero-arity definitions) of one module's source."""
    s = strip_tla(src)
    m = re.search(r"\bEXTENDS\b", s)
    ext = _id_list(s, m.end()) if m else []
    defs: set[str] = set(_ZERO_ARITY_DEF.findall(s))
    consts: set[str] = set()
    for m in re.finditer(r"\bCONSTANTS?\b", s):
        consts.update(_id_list(s, m.end()))
    return ext, consts, defs


def module_decls(src: str) -> tuple[list[str], set[str]]:
    """(EXTENDS list, names a cfg may substitute) of one module's source.

    The names are the declared CONSTANTs plus zero-arity definitions: TLC's `Name <- Def`
    also overrides a defined operator, and the library uses that for overridable
    defaults.
    """
    ext, consts, defs = module_names(src)
    return ext, consts | defs


_INSTANCE = re.compile(r"\bINSTANCE\s+([A-Za-z_][A-Za-z0-9_]*)")


def reachable_modules(spec: str, dirs: list[str]) -> dict[str, Path] | None:
    """Every module `spec` reaches through EXTENDS and INSTANCE (itself included), by
    name, with its file; standard modules are left out. None if a module is missing."""
    found: dict[str, Path] = {}
    todo = [spec]
    while todo:
        mod = todo.pop()
        if mod in found:
            continue
        path = next((Path(d) / f"{mod}.tla" for d in dirs if (Path(d) / f"{mod}.tla").is_file()), None)
        if path is None:
            if mod in NO_CONSTANT_MODULES:
                continue
            return None
        found[mod] = path
        src = path.read_text(encoding="utf-8", errors="replace")
        todo += module_decls(src)[0] + _INSTANCE.findall(strip_tla(src))
    return found


def declared_constants(spec: str, dirs: list[str]) -> set[str] | None:
    """Substitutable names (CONSTANTs, zero-arity definitions) of `spec` and its EXTENDS
    chain, or None if a module is missing."""
    seen: set[str] = set()
    consts: set[str] = set()
    todo = [spec]
    while todo:
        mod = todo.pop()
        if mod in seen:
            continue
        seen.add(mod)
        path = next((Path(d) / f"{mod}.tla" for d in dirs if (Path(d) / f"{mod}.tla").is_file()), None)
        if path is None:
            if mod in NO_CONSTANT_MODULES:
                continue
            return None
        ext, cs = module_decls(path.read_text(encoding="utf-8", errors="replace"))
        consts |= cs
        todo += ext
    return consts


def check_constants(run: Run) -> str | None:
    """ConfigError for undeclared constant names; a warning string if the check was skipped."""
    declared = declared_constants(run.spec, [str(run.dir), *run.library])
    if declared is None:
        return f"{run.name}: could not find every module EXTENDed by {run.spec}; constant names not checked"
    unknown = sorted(k for k in run.constants if "!" not in k and k not in declared)
    if unknown:
        raise ConfigError(f"{rel(run.toml)} run {run.name}: {unknown} are neither CONSTANTs nor "
                          f"definitions of {run.spec} or a module it EXTENDS")
    qualified = [k for k in run.constants if "!" in k]
    if qualified:
        mods = reachable_modules(run.spec, [str(run.dir), *run.library])
        if mods is None:
            return f"{run.name}: could not find every module {run.spec} reaches; {qualified} not checked"
        for k in qualified:
            mod, name = k.split("!", 1)
            if mod not in mods:
                raise ConfigError(f"{rel(run.toml)} run {run.name}: {k!r}: {run.spec} neither EXTENDS "
                                  f"nor INSTANCEs a module {mod}")
            _, consts, defs = module_names(mods[mod].read_text(encoding="utf-8", errors="replace"))
            if name in consts:
                # TLC's `Name <- [Mod] expr` overrides a definition only; for a CONSTANT it
                # leaves the parameter unassigned and TLC stops.
                how = (f"assign it unqualified, {name!r}"
                       if name in declared else
                       f"bind it where {mod} is instantiated, `INSTANCE {mod} WITH {name} <- ...`, or "
                       f"declare a CONSTANT there and assign that")
                raise ConfigError(f"{rel(run.toml)} run {run.name}: {k!r}: {name} is a CONSTANT of {mod}, "
                                  f"and a module-qualified key only overrides definitions; {how}")
            if name not in defs:
                raise ConfigError(f"{rel(run.toml)} run {run.name}: {k!r}: {name} is not a zero-arity "
                                  f"definition of {mod}")
    return None


def find_tomls(p: Path) -> list[Path]:
    if p.is_file():
        return [p]
    return sorted(x for x in p.rglob("runs.toml") if "build" not in x.relative_to(p).parts)


def select(args: list[str]) -> list[Run]:
    """Runs named by `args`.

    - no args: every run under the repo's examples/;
    - paths only: every run in those runs.toml files / directories;
    - names only: matching runs under the repo's examples/;
    - paths and names: matching runs within the given paths only.
    """
    return select_checks(args)[0]


def select_checks(args: list[str]) -> tuple[list[Run], list[Witness], list[Mutant]]:
    """As select(), with the witnesses and mutants of the chosen runs (each narrowed to
    its chosen runs; a check none of whose runs was chosen is left out)."""
    paths = [a for a in args if os.path.exists(a)]
    names = [a for a in args if not os.path.exists(a)]
    tomls: list[Path] = []
    for a in paths or [str(ROOT / "examples")]:
        tomls += [t.resolve() for t in find_tomls(Path(a))]
    pool = list(dict.fromkeys(tomls))
    docs = {t: load_doc(t) for t in pool}
    loaded = {t: d[0] for t, d in docs.items()}
    seen: dict[str, Path] = {}
    for t, rs in loaded.items():
        for r in rs:
            if r.name in seen:
                raise ConfigError(f"run name {r.name} is used in {rel(seen[r.name])} and {rel(t)}")
            seen[r.name] = t
    everything = [r for t in pool for r in loaded[t]]
    chosen: list[Run] = [] if names else everything
    where = "the given paths" if paths else "examples/"
    for n in names:
        hit = [r for r in everything if fnmatch.fnmatchcase(r.name, n)]
        if not hit:
            raise ConfigError(f"no path, and no run named {n!r} in {where}")
        chosen += [r for r in hit if r not in chosen]
    picked = {r.name for r in chosen}
    wits: list[Witness] = []
    muts: list[Mutant] = []
    for t in pool:
        for w in docs[t][1]:
            if set(w.runs) & picked:
                wits.append(Witness(**{**asdict(w), "toml": w.toml, "runs": [n for n in w.runs if n in picked]}))
        for m in docs[t][2]:
            if set(m.runs) & picked:
                muts.append(Mutant(**{**asdict(m), "toml": m.toml, "runs": [n for n in m.runs if n in picked]}))
    return chosen, wits, muts


# ---------------------------------------------------------------- generation


def const_def_name(key: str) -> str:
    """The wrapper's definition for constant key `Name` or `Mod!Name`."""
    return "const_" + key.replace("!", "_")


def cfg_substitution(key: str) -> str:
    """The cfg line for constant key `Name` (`Name <- const_Name`) or `Mod!Name`
    (`Name <- [Mod] const_Mod_Name`: TLC's override of a definition in module Mod; it does
    not assign a CONSTANT, which check_constants rejects)."""
    if "!" in key:
        mod, name = key.split("!", 1)
        return f"{name} <- [{mod}] {const_def_name(key)}"
    return f"{key} <- {const_def_name(key)}"


def _definition(name: str, expr: str) -> str:
    if "\n" not in expr.strip():
        return f"{name} == {expr.strip()}"
    return f"{name} ==\n" + textwrap.indent(textwrap.dedent(expr.strip("\n")), "    ")


def wrapper(run: Run, mod: str, invariants=None, properties=None, defs=()) -> tuple[str, str]:
    """(wrapper module text, cfg text) for `run`, module name `mod`; `defs` are extra
    (name, expression) definitions, such as a witness."""
    invs = run.invariants if invariants is None else invariants
    props = run.properties if properties is None else properties
    tla = [f"---- MODULE {mod} ----",
           f"\\* Generated by tools/run.py for run {run.name}; do not edit.",
           f"EXTENDS {run.spec}"]
    tla += [_definition(const_def_name(k), v) for k, v in run.constants.items()]
    tla += [_definition(n, e) for n, e in defs]
    tla.append("====")
    cfg = [f"\\* Generated by tools/run.py for run {run.name}; do not edit."]
    if run.specification:
        cfg.append(f"SPECIFICATION {run.specification}")
    else:
        cfg += [f"INIT {run.init}", f"NEXT {run.next}"]
    if run.constants:
        cfg.append("CONSTANTS")
        cfg += [f"  {cfg_substitution(k)}" for k in run.constants]
    if invs:
        cfg.append("INVARIANTS")
        cfg += [f"  {i}" for i in invs]
    if props:
        cfg.append("PROPERTIES")
        cfg += [f"  {p}" for p in props]
    return "\n".join(tla) + "\n", "\n".join(cfg) + "\n"


# ---------------------------------------------------------------- running

_TMP_PATTERNS = (
    r"(?:/private)?/var/folders/[^/\s]+/[^/\s]+/T(?![\w.-])",
    r"(?:/private)?/tmp(?![\w.-])",
)


def home_rewrite(text: str, home: str | None = None) -> str:
    """Replace the home directory (at path boundaries) with ~ and temp dirs with <tmp>."""
    tmps = {os.path.realpath(tempfile.gettempdir()), tempfile.gettempdir()}
    for t in sorted((t.rstrip("/") for t in tmps if t not in ("", "/")), key=len, reverse=True):
        text = re.sub(r"(?<![\w.-])" + re.escape(t) + r"(?![\w.-])", "<tmp>", text)
    for pat in _TMP_PATTERNS:
        text = re.sub(r"(?<![\w.-])" + pat, "<tmp>", text)
    homes = {home} if home else {os.path.expanduser("~"), os.path.realpath(os.path.expanduser("~"))}
    for h in sorted((h.rstrip("/") for h in homes if h and h != "/"), key=len, reverse=True):
        text = re.sub(r"(?<![\w.-])" + re.escape(h) + r"(?![\w.-])", "~", text)
    return text


def rel(p) -> str:
    p = Path(p)
    try:
        return str(p.resolve().relative_to(ROOT))
    except ValueError:
        return home_rewrite(str(p))


def find_jar(arg: str | None) -> str:
    if arg:
        jar = arg
    elif (HERE / "tla2tools.jar").is_file():
        jar = str(HERE / "tla2tools.jar")
    else:
        jar = os.environ.get("TLA2TOOLS_JAR", "")
    if not jar or not os.path.isfile(jar):
        raise ConfigError("tla2tools.jar not found: pass --jar, put it at tools/tla2tools.jar, "
                          "or set TLA2TOOLS_JAR")
    return str(Path(jar).resolve())


@dataclass
class Outcome:
    run: str
    example: str
    expect: str
    actual: str
    ok: bool
    seconds: float
    budget_s: float
    generated: int | None = None
    distinct: int | None = None
    depth: int | None = None
    tlc_seconds: int | None = None
    notes: list[str] = field(default_factory=list)
    log: str = ""
    peeled: list[str] | None = None
    kind: str = "run"  # "run", "witness" or "mutant"
    check: str = ""    # the witness or mutant id


@dataclass
class Attempt:
    mod: str
    res: tlcparse.Result
    wall: float
    tlc_text: str  # TLC's own output only
    tla: str
    cfg: str
    log_path: Path


def mutant_target(run: Run, m: Mutant) -> tuple[int, Path]:
    """(index in [spec dir, *library], path) of the file mutant `m` patches for `run`."""
    if not m.library:
        return 0, run.dir / m.file
    for i, d in enumerate(run.library, start=1):
        if (Path(d) / m.file).is_file():
            return i, Path(d) / m.file
    raise ConfigError(f"{rel(m.toml)} mutant {m.id}: {m.file} is in none of run {run.name}'s library dirs")


def patched_text(run: Run, m: Mutant) -> str:
    """The patched module text; ConfigError unless `find` occurs exactly `count` times."""
    _, path = mutant_target(run, m)
    text = path.read_text(encoding="utf-8")
    n = text.count(m.find)
    if n != m.count:
        raise ConfigError(f"{rel(m.toml)} mutant {m.id}: find occurs {n} times in {rel(path)}, "
                          f"count = {m.count}")
    return text.replace(m.find, m.replace)


def stage(work: str, run: Run, m: Mutant) -> list[str]:
    """Copy the .tla files of the dir `m` patches into `work`, patch the copy, and return
    the module search path with the copy in the original's place."""
    dirs = [str(run.dir), *run.library]
    i, path = mutant_target(run, m)
    copy = Path(work, "spec" if i == 0 else f"lib{i}")
    copy.mkdir()
    for f in Path(dirs[i]).glob("*.tla"):
        shutil.copyfile(f, copy / f.name)
    (copy / m.file).write_text(patched_text(run, m), encoding="utf-8")
    dirs[i] = str(copy)
    return dirs


def tlc_once(run: Run, mod: str, invs, props, jar: str, workers: int, defs=(), patch: Mutant | None = None,
             hard: float | None = None) -> Attempt:
    """Generate the wrapper + cfg in a fresh temp dir, run TLC there, write build/<log>.
    `defs` go into the wrapper; `patch` runs TLC on a patched copy of the spec or library
    dir; `hard` (default 3 x budget_s) is when TLC is stopped."""
    tla, cfg = wrapper(run, mod, invs, props, defs)
    work = tempfile.mkdtemp(prefix=f"tlc-{mod}-", dir="/tmp" if os.path.isdir("/tmp") else None)
    if hard is None:
        hard = max(HARD_TIMEOUT_FACTOR * run.budget_s, run.budget_s + 30)
    timed_out = False
    t0 = time.monotonic()
    try:
        dirs = stage(work, run, patch) if patch else [str(run.dir), *run.library]
        libpath = os.pathsep.join(dirs)
        # TLC unpacks its standard modules into java.io.tmpdir; a private one per run keeps
        # concurrent TLC processes from parsing each other's half-written copies.
        jtmp = os.path.join(work, "jtmp")
        os.makedirs(jtmp)
        cmd = ["java", "-XX:+UseParallelGC", f"-Xss{DEFAULT_STACK}", f"-Djava.io.tmpdir={jtmp}",
               *shlex.split(os.environ.get("TLC_JAVA_OPTS", "")),
               *([f"-Xss{run.stack}"] if run.stack else []),
               f"-DTLA-Library={libpath}", "-cp", jar, "tlc2.TLC",
               *([] if run.deadlock else ["-deadlock"]),
               "-workers", str(workers), "-metadir", os.path.join(work, "states"),
               "-config", f"{mod}.cfg", f"{mod}.tla"]
        Path(work, f"{mod}.tla").write_text(tla)
        Path(work, f"{mod}.cfg").write_text(cfg)
        try:
            p = subprocess.run(cmd, cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=hard)
            out, code = p.stdout, p.returncode
        except subprocess.TimeoutExpired as e:
            out, code, timed_out = e.stdout or b"", None, True
        except FileNotFoundError as e:
            raise ConfigError(f"cannot run java: {e}") from e
    finally:
        shutil.rmtree(work, ignore_errors=True)
    wall = time.monotonic() - t0
    text = out.decode("utf-8", errors="replace") if isinstance(out, bytes) else (out or "")
    res = tlcparse.parse(text, code)
    if timed_out:
        res.verdict, res.message = "timeout", f"killed after {hard:.0f}s"
    shown = [rel(jar) if c == jar else c for c in cmd]
    head = f"# run {run.name} ({rel(run.toml)})\n"
    if patch:
        head += f"# mutant {patch.id}: {patch.file}{' (library)' if patch.library else ''}\n"
    log = home_rewrite(
        head + f"# {' '.join(shlex.quote(c) for c in shown)}\n" + text
        + f"\n# runner: wall={wall:.1f}s exit={code} verdict={res.label()}\n")
    run.build.mkdir(exist_ok=True)
    log_path = run.build / f"{mod.removeprefix('MC_')}.log"
    log_path.write_text(log)
    return Attempt(mod, res, wall, text, tla, cfg, log_path)


def verdict_matches(run: Run, res) -> bool:
    if res.verdict == "violation":
        return run.expect == "violation" and (
            res.name == run.invariant or (res.name == "<temporal>" and run.invariant in run.properties))
    return res.verdict == run.expect


def check(run: Run, res, wall: float, tlc_text: str) -> tuple[bool, list[str]]:
    """Does one TLC result meet the run's expectations? `tlc_text` is TLC's output only."""
    ok = verdict_matches(run, res)
    notes = [res.message] if res.message else []
    if res.verdict == "pass" and not res.distinct:
        ok = False
        notes.append("vacuous: TLC explored no distinct states")
    if wall > run.budget_s:
        ok = False
        notes.append(f"over budget: {wall:.1f}s > {run.budget_s:g}s")
    if run.expect_output is not None and not re.search(run.expect_output, " ".join(tlc_text.split())):
        ok = False
        notes.append(f"expect_output /{run.expect_output}/ not found")
    if run.expect_window is not None:
        got = windows.windows(tlc_text, run.window_step)
        notes.append("window " + "; ".join(f"{k} {windows.fmt_ggas(v)}" for k, v in got.items())
                     if got else "window: none")
        if isinstance(run.expect_window, dict):
            for label in sorted(set(got) | set(run.expect_window)):
                want = run.expect_window.get(label)
                if want is None:
                    ok = False
                    notes.append(f"unexpected window label {label}")
                elif got.get(label, []) != windows.parse_spec(want):
                    ok = False
                    notes.append(f"expected window {label} {want}")
        else:
            union = windows.fold(set().union(*windows.reports(tlc_text).values()), run.window_step)
            if union != windows.parse_spec(run.expect_window):
                ok = False
                notes.append(f"expected window {run.expect_window}")
    return ok, notes


def keep_or_clean(run: Run, attempts: list[Attempt], ok: bool, keep: bool) -> None:
    """Keep wrapper/cfg/log in build/ on a mismatch or with --keep; else remove the logs."""
    if ok and not keep:
        for a in attempts:
            a.log_path.unlink(missing_ok=True)
        try:
            run.build.rmdir()
        except OSError:
            pass
    else:
        for a in attempts:
            (run.build / f"{a.mod}.tla").write_text(a.tla)
            (run.build / f"{a.mod}.cfg").write_text(a.cfg)


def finish(run: Run, attempts: list[Attempt], ok: bool, actual: str, notes: list[str],
           keep: bool, peeled=None) -> Outcome:
    """Build the Outcome; keep wrapper/cfg/log in build/ on a mismatch or with --keep."""
    last = attempts[-1]
    keep_or_clean(run, attempts, ok, keep)
    expect = run.expect if run.expect != "violation" else f"violation {run.invariant}"
    return Outcome(run.name, rel(run.dir), expect, actual, ok, sum(a.wall for a in attempts), run.budget_s,
                   last.res.generated, last.res.distinct, last.res.depth, last.res.tlc_seconds, notes,
                   "" if ok and not keep else rel(last.log_path), peeled)


def effective_workers(run: Run, cli: int | None) -> int:
    """The run's own setting is an upper bound; --workers can only lower it."""
    return max(1, min(run.workers, cli or MAX_WORKERS, MAX_WORKERS))


def do_run(run: Run, jar: str, workers: int | None, keep: bool, print_trace: bool) -> Outcome:
    a = tlc_once(run, f"MC_{run.name}", None, None, jar, effective_workers(run, workers))
    ok, notes = check(run, a.res, a.wall, a.tlc_text)
    if print_trace and a.res.verdict in ("violation", "assert", "deadlock"):
        notes.append("trace:\n" + tlctrace.summary(a.tlc_text))
    return finish(run, [a], ok, a.res.label(), notes, keep)


def do_peel(run: Run, jar: str, workers: int | None, keep: bool, print_trace: bool) -> Outcome:
    w = effective_workers(run, workers)
    invs, props = list(run.invariants), list(run.properties)
    peeled: list[str] = []
    attempts: list[Attempt] = []
    notes: list[str] = []
    while True:
        i = len(attempts)
        a = tlc_once(run, f"MC_{run.name}" + (f"_p{i}" if i else ""), invs, props, jar, w)
        attempts.append(a)
        res = a.res
        print(f"  {run.name} step {i}: {res.label()} ({fmt_n(res.distinct)} distinct, {a.wall:.1f}s)",
              file=sys.stderr, flush=True)
        if a.wall > run.budget_s:
            notes.append(f"step {i} over budget: {a.wall:.1f}s > {run.budget_s:g}s")
        if print_trace and res.verdict in ("violation", "assert", "deadlock"):
            notes.append(f"trace (step {i}):\n" + tlctrace.summary(a.tlc_text))
        name = res.name
        if name == "<temporal>" and len(props) == 1:
            name = props[0]
        if res.verdict != "violation" or name not in invs + props:
            break
        peeled.append(name)
        invs = [x for x in invs if x != name]
        props = [x for x in props if x != name]
        if not invs and not props:
            break
    res = attempts[-1].res
    # "exhausted": the last remaining invariant/property was violated and peeled.
    final = "exhausted" if res.verdict == "violation" and peeled and not invs and not props else res.verdict
    if res.message:
        notes.append(res.message)
    if final == "pass" and not res.distinct:
        notes.append("vacuous: TLC explored no distinct states")
        final = "vacuous"
    if run.expect == "violation":
        ok = run.invariant in peeled and final in ("pass", "exhausted")
    else:
        ok = not peeled and final == run.expect
    ok = ok and not any("over budget" in n for n in notes)
    actual = "peeled {" + ", ".join(peeled) + "}" + (f" then {res.label()}" if final not in ("pass", "exhausted") else "")
    return finish(run, attempts, ok, actual, notes, keep, peeled)


# ---------------------------------------------------------------- anti-vacuity


def preflight(muts: list[Mutant], by_name: dict[str, Run]) -> None:
    """Every mutant's find text occurs `count` times in the file each of its runs would
    patch. One ConfigError listing every mismatch; called before any JVM starts."""
    errs = []
    for m in muts:
        done: set[Path] = set()
        for n in m.runs:
            try:
                path = mutant_target(by_name[n], m)[1]
                if path not in done:
                    done.add(path)
                    patched_text(by_name[n], m)
            except ConfigError as e:
                errs.append(str(e))
    if errs:
        raise ConfigError("mutant patch check failed:\n  " + "\n  ".join(errs))


def _job_note(run: Run, a: Attempt) -> str:
    return f"{run.name}: {a.res.label()} ({fmt_n(a.res.distinct)} distinct, {a.wall:.1f}s)"


def do_witness(w: Witness, run: Run, jar: str, workers: int | None, keep: bool) -> Outcome:
    """Check Wit_<id> alone on `run`: violated = reached."""
    a = tlc_once(run, f"MC_{run.name}__w_{w.id}", [w.op], [], jar, effective_workers(run, workers),
                 defs=[(w.op, w.expr)], hard=run.budget_s)
    res = a.res
    notes = [res.message] if res.message and res.verdict not in ("violation", "pass") else []
    if res.verdict == "violation" and res.name == w.op:
        actual = "reached"
    elif res.verdict == "pass" and res.distinct:
        actual = "never reached"
    elif res.verdict == "pass":
        actual = "error"
        notes.append("vacuous: TLC explored no distinct states")
    else:
        actual = res.label()
    ok = actual == ("reached" if w.expect == "reached" else "never reached")
    if actual == "never reached" and w.expect == "reached":
        notes.append(f"vacuous: witness {w.id} never reached")
    if actual == "reached" and w.expect == "unreachable":
        notes.append(f"witness {w.id} reached, but marked unreachable ({w.reason})")
    keep_or_clean(run, [a], ok, keep)
    return Outcome(run.name, rel(run.dir), w.expect, actual, ok, a.wall, run.budget_s, res.generated,
                   res.distinct, res.depth, res.tlc_seconds, notes, "" if ok and not keep else rel(a.log_path),
                   kind="witness", check=w.id)


def mutant_verdict(results: list[tlcparse.Result]) -> str:
    """One mutant's result over its runs: killed <inv> | killed (assert|deadlock) |
    timeout | error | survived."""
    for res in results:
        if res.verdict == "violation":
            return f"killed {res.name}"
    for kind in ("assert", "deadlock"):
        if any(res.verdict == kind for res in results):
            return f"killed ({kind})"
    if any(res.verdict == "timeout" for res in results):
        return "timeout"
    if all(res.verdict == "pass" and res.distinct for res in results):
        return "survived"
    return "error"


def do_mutant(m: Mutant, runs: list[Run], jar: str, workers: int | None, keep: bool) -> Outcome:
    """Check every listed run on the patched copy, each with its own invariants."""
    attempts = []
    notes = []
    bad = False  # a job that timed out or errored fails the mutant, whatever the others said
    for run in runs:
        a = tlc_once(run, f"MC_{run.name}__m_{m.id}", None, None, jar, effective_workers(run, workers),
                     patch=m, hard=run.budget_s)
        attempts.append((run, a))
        notes.append(_job_note(run, a) + (f": {a.res.message}" if a.res.verdict not in ("violation", "pass")
                                          and a.res.message else ""))
        bad = bad or a.res.verdict not in ("violation", "assert", "deadlock", "pass") or (
            a.res.verdict == "pass" and not a.res.distinct)
    actual = mutant_verdict([a.res for _, a in attempts])
    if m.equivalent is None:
        # what caught it, over every run: violated invariants, and "assert" / "deadlock"
        kills = {a.res.name if a.res.verdict == "violation" else a.res.verdict
                 for _, a in attempts if a.res.verdict in ("violation", "assert", "deadlock")}
        accepted = kills & set(m.killed_by) if m.killed_by else kills - {"assert", "deadlock"}
        ok = bool(accepted) and not bad
        if accepted:
            k = sorted(accepted)[0]
            actual = f"killed ({k})" if k in ("assert", "deadlock") else f"killed {k}"
        if actual == "survived":
            notes.append(f"survived: no run caught mutant {m.id} ({m.cls})")
        elif kills and not accepted:
            notes.append(f"caught only by {', '.join(sorted(kills))}, not by "
                         + (f"killed_by {m.killed_by}" if m.killed_by else
                            'an invariant (list "assert" / "deadlock" in killed_by to accept that)'))
    else:
        ok = actual == "survived"
        if actual.startswith("killed"):
            notes.append(f"marked equivalent ({m.equivalent}), but {actual}")
    if bad and actual.startswith("killed"):
        notes.append("a job timed out or failed")
    for run, a in attempts:
        keep_or_clean(run, [a], ok, keep)
    last = attempts[-1][1]
    logs = [rel(a.log_path) for _, a in attempts]
    return Outcome(",".join(r.name for r in runs), rel(runs[0].dir),
                   "equivalent" if m.equivalent is not None else "killed",
                   "equivalent" if ok and m.equivalent is not None else actual, ok,
                   sum(a.wall for _, a in attempts), runs[0].budget_s, last.res.generated, last.res.distinct,
                   last.res.depth, last.res.tlc_seconds, notes, "" if ok and not keep else " ".join(logs),
                   kind="mutant", check=m.id)


def run_checks(wits: list[Witness], muts: list[Mutant], by_name: dict[str, Run], failed: set[str],
               jar: str, workers: int | None, keep: bool) -> list[Outcome]:
    """Every witness x run and every mutant; checks of runs in `failed` are skipped."""
    outs = []

    def skipped(kind, cid, names, example, budget):
        return Outcome(",".join(names), example, "-", "skipped", False, 0.0, budget,
                       notes=[f"skipped: run {', '.join(names)} did not match its expectation"],
                       kind=kind, check=cid)

    for w in wits:
        for n in w.runs:
            run = by_name[n]
            if n in failed:
                outs.append(skipped("witness", w.id, [n], rel(run.dir), run.budget_s))
                continue
            print(f"witness {w.id} on {n} ...", file=sys.stderr, flush=True)
            outs.append(do_witness(w, run, jar, workers, keep))
    for m in muts:
        runs = [by_name[n] for n in m.runs if n not in failed]
        if not runs:
            outs.append(skipped("mutant", m.id, m.runs, rel(by_name[m.runs[0]].dir), by_name[m.runs[0]].budget_s))
            continue
        print(f"mutant {m.id} on {', '.join(r.name for r in runs)} ...", file=sys.stderr, flush=True)
        outs.append(do_mutant(m, runs, jar, workers, keep))
    return outs


def check_table(outs: list[Outcome]) -> str:
    head = ("check", "run", "expect", "actual", "secs", "result")
    rows = [(f"{o.kind} {o.check}", o.run, o.expect, o.actual, f"{o.seconds:.1f}", "ok" if o.ok else "FAIL")
            for o in outs]
    return _table(head, rows, outs)


def sweep_table(outs: list[Outcome]) -> str:
    head = ("sweep", "run", "expect", "actual", "distinct", "secs", "result")
    rows = [(o.check, o.run, o.expect, o.actual, fmt_n(o.distinct), f"{o.seconds:.1f}", "ok" if o.ok else "FAIL")
            for o in outs]
    return _table(head, rows, outs)


def summary(outs: list[Outcome]) -> str:
    """One line per example directory: what the mutants and witnesses gave."""
    lines = []
    for ex in dict.fromkeys(o.example for o in outs):
        mo = [o for o in outs if o.example == ex and o.kind == "mutant"]
        wo = [o for o in outs if o.example == ex and o.kind == "witness"]
        parts = []
        if mo:
            killed = [o for o in mo if o.actual.startswith("killed")]
            by_ad = sum(1 for o in killed if o.actual in ("killed (assert)", "killed (deadlock)"))
            parts.append(f"mutants {len(mo)}: killed {len(killed)}" + (f" ({by_ad} by assert/deadlock)" if by_ad else "")
                         + f", equivalent {sum(o.actual == 'equivalent' for o in mo)}"
                         + f", survived {sum(o.actual == 'survived' for o in mo)}"
                         + f", timeout {sum(o.actual == 'timeout' for o in mo)}"
                         + f", other {sum(o.actual in ('error', 'skipped') for o in mo)}")
        if wo:
            parts.append(f"witnesses {len({o.check for o in wo})} ({len(wo)} jobs): "
                         f"reached {sum(o.actual == 'reached' for o in wo)}, "
                         f"unreachable as documented {sum(o.ok and o.expect == 'unreachable' for o in wo)}, "
                         f"never reached {sum(o.actual == 'never reached' and o.expect == 'reached' for o in wo)}, "
                         f"other {sum(o.actual not in ('reached', 'never reached') for o in wo)}")
        lines.append(f"{ex}: " + "; ".join(parts))
    return "\n".join(lines)


# ---------------------------------------------------------------- sweeps


def select_sweeps(picked: set[str]) -> list[Sweep]:
    """The loaded sweeps whose base run is among the picked runs."""
    return [sw for t in _SWEEPS for sw in _SWEEPS[t] if sw.run in picked]


_LIMIT_DEF = r"^{}\s*==\s*(\d+)"


def limit_value(sw: Sweep, run: Run) -> int | None:
    """A size sweep's protocol limit: a number, or a NearAsync definition such as MaxLogBytes
    (read from the run's library)."""
    if sw.limit is None or isinstance(sw.limit, int):
        return sw.limit
    for d in run.library:
        f = Path(d) / "NearAsync.tla"
        if f.is_file():
            m = re.search(_LIMIT_DEF.format(re.escape(sw.limit)), f.read_text(encoding="utf-8"), re.M)
            if m:
                return int(m.group(1))
    raise ConfigError(f"{rel(sw.toml)} sweep {sw.id}: no numeric definition {sw.limit} in NearAsync.tla "
                      f"of run {run.name}'s library")


def size_values(one_cap_limit: list[int | None], floor: int) -> list[int]:
    """1, the cap and the limit, each with -1 and +1; at or above floor, ascending."""
    vals = {x + d for x in one_cap_limit if x is not None for d in (-1, 0, 1)}
    return sorted(v for v in vals if v >= floor)


def search_least(ok, lo: int, hi: int) -> int:
    """The least v in (lo, hi] with ok(v), given ok(hi) and not ok(lo); ok raises to abort.
    Bisection: assumes success is monotone between lo and hi."""
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if ok(mid):
            hi = mid
        else:
            lo = mid
    return hi


def sweep_run(sw: Sweep, base: Run, v: int, invariants: list[str]) -> Run:
    """The base run with the knob(s) set to v, checking `invariants` and expecting a pass."""
    text = sw.form.replace("%d", str(v))
    tag = str(v) if v >= 0 else f"n{-v}"
    return replace(base, name=f"{base.name}__s_{sw.id}_{tag}",
                   constants={**base.constants, **sw.constants, **{k: text for k in sw.knobs}},
                   expect="pass", invariant=None, invariants=list(invariants), expect_output=None,
                   expect_window=None, allow_no_invariants=None, tags=list(base.tags))


def do_sweep(sw: Sweep, by_name: dict[str, Run], jar: str, workers: int | None, keep: bool) -> list[Outcome]:
    """Run one sweep; one Outcome row per reported value, then a summary row."""
    base = by_name[sw.run]
    invs = sw.success if sw.success is not None else base.invariants
    seen: dict[int, Attempt] = {}
    rows: list[Outcome] = []

    class Abort(Exception):
        pass

    def job(v: int) -> Attempt:
        if v not in seen:
            r = sweep_run(sw, base, v, invs)
            warn = check_constants(r)
            if warn:
                print(f"warning: {warn}", file=sys.stderr)
            print(f"sweep {sw.id}: {', '.join(sw.knobs)} = {v} ...", file=sys.stderr, flush=True)
            a = tlc_once(r, f"MC_{r.name}", None, None, jar, effective_workers(r, workers))
            seen[v] = a
            keep_or_clean(r, [a], a.res.verdict in ("pass", "violation"), keep)
        return seen[v]

    def label(a: Attempt) -> str:
        return a.res.label() if not (a.res.verdict == "pass" and not a.res.distinct) else "vacuous"

    def row(v, expect, actual, ok, notes=(), a: Attempt | None = None) -> Outcome:
        res = a.res if a else tlcparse.Result()
        return Outcome(base.name, rel(base.dir), expect, actual, ok, a.wall if a else 0.0, base.budget_s,
                       res.generated, res.distinct, res.depth, res.tlc_seconds, list(notes),
                       "" if ok or a is None else rel(a.log_path), kind="sweep",
                       check=f"{sw.id} {'/'.join(sw.knobs)}={v}" if v is not None else sw.id)

    if sw.kind == "size":
        lim = limit_value(sw, base)
        vals = size_values([1, sw.cap, lim], sw.floor)
        for v in vals:
            a = job(v)
            got = label(a)
            want = sw.expect.get(str(v))
            ok = got not in ("timeout", "error", "unfinished", "vacuous") and (want is None or got == want)
            what = [n for n, x in (("1", 1), ("cap", sw.cap), ("limit", lim)) if x is not None and abs(v - x) <= 1]
            rows.append(row(v, want or "-", got, ok, [f"around {', '.join(what)}"] + (
                [a.res.message] if a.res.message and a.res.verdict not in ("pass", "violation") else []), a))
        return rows

    def holds(v: int) -> bool:
        a = job(v)
        if a.res.verdict == "pass" and a.res.distinct:
            return True
        if a.res.verdict == "violation" and a.res.name in invs:
            return False
        raise Abort(f"{', '.join(sw.knobs)} = {v}: {label(a)}" + (f" ({a.res.message})" if a.res.message else ""))

    lo, hi = sw.lo, sw.hi
    notes: list[str] = []
    try:
        if sw.window_run:
            wr = by_name.get(sw.window_run)
            if wr is None:
                raise ConfigError(f"{rel(sw.toml)} sweep {sw.id}: select window_run {sw.window_run} too")
            print(f"sweep {sw.id}: window run {wr.name} ...", file=sys.stderr, flush=True)
            a = tlc_once(wr, f"MC_{wr.name}__s_{sw.id}", None, None, jar, effective_workers(wr, workers))
            keep_or_clean(wr, [a], a.res.verdict == "pass", keep)
            rep = windows.reports(a.tlc_text)
            vals = rep.get(sw.window_label, set()) if sw.window_label else set().union(*rep.values()) if rep else set()
            if vals and max(vals) < hi:
                top = max(vals)
                notes.append(f"window run {wr.name}: top bad value {top}")
                lo = max(lo, top)
                if lo + wr.window_step < hi and holds(lo + wr.window_step):
                    hi = lo + wr.window_step
            else:
                notes.append(f"window run {wr.name}: no window below hi; bracket {lo}..{hi}")
        if not holds(hi):
            raise Abort(f"success fails at hi = {hi}")
        if holds(lo):
            raise Abort(f"success already holds at lo = {lo}: lower lo")
        need = search_least(holds, lo, hi)
        holds(need + 1)
    except Abort as e:
        rows.append(row(None, "need" if sw.expect_need is None else f"need {sw.expect_need}", "error", False,
                        notes + [str(e)]))
        return rows
    for v, want in ((need - 1, "fail"), (need, "pass"), (need + 1, "pass")):
        a = seen[v]
        ok = (label(a) == "pass") == (want == "pass")
        rows.append(row(v, "pass" if want == "pass" else "violation", label(a), ok,
                        ["non-monotone: success fails above need"] if v == need + 1 and not ok else [], a))
    good = all(o.ok for o in rows) and (sw.expect_need is None or need == sw.expect_need)
    rows.append(row(None, "need" if sw.expect_need is None else f"need {sw.expect_need}", f"need {need}", good,
                    notes + [f"{len(seen)} TLC runs; least {', '.join(sw.knobs)} at which "
                             f"{', '.join(invs)} {'holds' if len(invs) == 1 else 'hold'}: {need}"]))
    return rows


def run_sweeps(sweeps: list[Sweep], by_name: dict[str, Run], jar: str,
               workers: int | None, keep: bool) -> list[Outcome]:
    """Every sweep, in order.  A base run's own verdict does not matter: a must-fail run is a
    natural base (its sweep checks `success`, not the run's expectation)."""
    outs: list[Outcome] = []
    for sw in sweeps:
        outs += do_sweep(sw, by_name, jar, workers, keep)
    return outs


def adhoc_sweeps(runs: list[Run], spec: str, rng: str, success: str | None) -> list[Sweep]:
    """--least-gas 'KNOB=FORM' --gas-range LO:HI [--success A,B] on each selected run."""
    knob, _, form = spec.partition("=")
    if not IDENT_RE.match(knob) or (form and "%d" not in form):
        raise ConfigError("--least-gas takes KNOB or 'KNOB=FORM' with %d in FORM")
    try:
        lo, hi = (int(x) for x in rng.split(":"))
    except ValueError as e:
        raise ConfigError("--gas-range takes LO:HI") from e
    if hi <= lo:
        raise ConfigError("--gas-range: HI must be above LO")
    succ = [x for x in (success or "").split(",") if x] or None
    out = []
    for r in runs:
        if succ is None and not r.invariants:
            raise ConfigError(f"run {r.name} has no invariants: give --success")
        out.append(Sweep("adhoc", r.toml, "least_gas", r.name, [knob], form or "%d", {}, lo, hi, succ))
    return out


# ---------------------------------------------------------------- output


def fmt_n(n) -> str:
    return "-" if n is None else f"{n:,}"


def table(outs: list[Outcome]) -> str:
    head = ("run", "expect", "actual", "generated", "distinct", "depth", "secs", "result")
    rows = [(o.run, o.expect, o.actual, fmt_n(o.generated), fmt_n(o.distinct), fmt_n(o.depth),
             f"{o.seconds:.1f}", "ok" if o.ok else "FAIL") for o in outs]
    return _table(head, rows, outs)


def _table(head, rows, outs: list[Outcome]) -> str:
    wid = [max(len(str(x[i])) for x in [head, *rows]) for i in range(len(head))]

    def line(r):
        return " | ".join(str(c).ljust(wid[i]) for i, c in enumerate(r)).rstrip()

    out = [line(head), "-+-".join("-" * x for x in wid)]
    for o, r in zip(outs, rows):
        out.append(line(r))
        for n in o.notes:
            out.append("    " + n.replace("\n", "\n    "))
        if not o.ok and o.log:
            out.append(f"    log: {o.log}")
    return "\n".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="tools/run.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="*", help="runs.toml files, directories, or run names/globs")
    ap.add_argument("--list", action="store_true", help="list the selected runs and exit")
    ap.add_argument("--jar", help="tla2tools.jar (default tools/tla2tools.jar, else $TLA2TOOLS_JAR)")
    ap.add_argument("--workers", type=int, help="lower every run's TLC workers to at most N")
    ap.add_argument("--library", help="override every run's library dir ($NEAR_TLA_LIBRARY likewise)")
    ap.add_argument("--keep", action="store_true", help="keep wrapper, cfg and log of passing runs in build/")
    ap.add_argument("--print-trace", action="store_true", help="print a counterexample summary on a violation")
    ap.add_argument("--peel", action="store_true", help="peel mode: drop violated invariants and rerun")
    ap.add_argument("--json", metavar="PATH", help="also write the results as JSON")
    ap.add_argument("--anti-vacuity", action="store_true",
                    help="after the runs, check every [[witness]] and [[mutant]] of the selected runs")
    ap.add_argument("--sweep", action="store_true",
                    help="after the runs, run every [[sweep]] whose base run is selected")
    ap.add_argument("--least-gas", metavar="KNOB[=FORM]",
                    help="ad-hoc least-gas sweep of each selected run (FORM: TLA+ text with %%d)")
    ap.add_argument("--gas-range", metavar="LO:HI", help="bracket for --least-gas (LO fails, HI holds)")
    ap.add_argument("--success", metavar="INV,..", help="success invariants for --least-gas (default: the run's)")
    a = ap.parse_args(argv)
    try:
        if a.workers is not None and a.workers < 1:
            raise ConfigError("--workers must be at least 1")
        runs, wits, muts = select_checks(a.targets)
        if not a.anti_vacuity:
            wits, muts = [], []
        sweeps = select_sweeps({r.name for r in runs}) if a.sweep else []
        if a.least_gas:
            if not a.gas_range:
                raise ConfigError("--least-gas needs --gas-range LO:HI")
            sweeps += adhoc_sweeps(runs, a.least_gas, a.gas_range, a.success)
        lib = a.library or os.environ.get("NEAR_TLA_LIBRARY")
        if lib:
            for r in runs:
                r.library = [str(Path(x).resolve()) for x in lib.split(os.pathsep)]
        for r in runs:
            warn = check_constants(r)
            if warn:
                print(f"warning: {warn}", file=sys.stderr)
        if a.list:
            for r in runs:
                exp = r.expect + (f" {r.invariant}" if r.invariant else "")
                print(f"{r.name:26} {rel(r.dir):38} {exp:26} {' '.join(r.tags)}")
            for w in wits:
                print(f"witness {w.id:18} {rel(w.toml.parent):38} {w.expect:26} {' '.join(w.runs)}")
            for m in muts:
                exp = "equivalent" if m.equivalent is not None else "killed"
                print(f"mutant  {m.id:18} {rel(m.toml.parent):38} {exp:26} {' '.join(m.runs)}")
            for sw in sweeps:
                print(f"sweep   {sw.id:18} {rel(sw.toml.parent):38} {sw.kind:26} {sw.run}")
            return 0
        if not runs:
            print("no runs selected", file=sys.stderr)
            return 2
        jar = find_jar(a.jar)
        by_name = {r.name: r for r in runs}
        preflight(muts, by_name)
        outs = []
        for r in runs:
            print(f"running {r.name} ({rel(r.dir)}) ...", file=sys.stderr, flush=True)
            outs.append((do_peel if a.peel else do_run)(r, jar, a.workers, a.keep, a.print_trace))
        failed = {o.run for o in outs if not o.ok}
        checks = run_checks(wits, muts, by_name, failed, jar, a.workers, a.keep) if a.anti_vacuity else []
        swept = run_sweeps(sweeps, by_name, jar, a.workers, a.keep) if sweeps else []
    except ConfigError as e:
        print(f"run.py: {e}", file=sys.stderr)
        return 2
    print(table(outs))
    bad = [o.run for o in outs if not o.ok]
    print(f"\n{len(outs) - len(bad)}/{len(outs)} runs as expected" + (f"; FAILED: {' '.join(bad)}" if bad else ""))
    bad_checks = []
    if a.anti_vacuity:
        print("\n" + check_table(checks) if checks else "\nno witnesses or mutants for the selected runs")
        if checks:
            print("\n" + summary(checks))
        bad_checks = [f"{o.kind}:{o.check}@{o.run}" for o in checks if not o.ok]
        print(f"\n{len(checks) - len(bad_checks)}/{len(checks)} checks as expected"
              + (f"; FAILED: {' '.join(bad_checks)}" if bad_checks else ""))
    bad_sweeps = []
    if sweeps:
        print("\n" + sweep_table(swept))
        bad_sweeps = [o.check for o in swept if not o.ok]
        print(f"\n{len(swept) - len(bad_sweeps)}/{len(swept)} sweep rows as expected"
              + (f"; FAILED: {'; '.join(bad_sweeps)}" if bad_sweeps else ""))
    if a.json:
        Path(a.json).write_text(json.dumps([asdict(o) for o in outs + checks + swept], indent=2, default=str) + "\n")
    return 1 if bad or bad_checks or bad_sweeps else 0


if __name__ == "__main__":
    sys.exit(main())
