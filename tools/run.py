#!/usr/bin/env python3
"""Run the TLC model-checking runs declared in runs.toml files and check their expectations.

usage: tools/run.py [options] [paths or run names...]

Arguments are runs.toml files, directories (searched recursively for runs.toml), or run
names (shell-style globs such as 'pay_*' work; names are looked up under examples/).
With no arguments every run under examples/ is checked.

For each run the runner writes, into build/ beside the runs.toml (gitignored):
  MC_<run>.tla   a wrapper that EXTENDS the spec and defines const_<C> == <expr>
  MC_<run>.cfg   a TLC config substituting C <- const_<C> (cfg files cannot hold tuples)
  <run>.log      TLC's output, with $HOME rewritten to ~
then runs TLC with -DTLA-Library=<spec dir>:<library>, parses the verdict, prints a
table and exits nonzero if any run does not match its expectation. Build files of runs
that match are deleted unless --keep; those of mismatching runs are always kept.

runs.toml format
----------------
  spec = "Pay"                # default module (a .tla beside runs.toml)
  workers = 2                 # TLC workers (default 2, capped at 4)
  library = "../../modules"   # relative to runs.toml (default ../../modules)
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
  tags = ["semantics:x"]      # free-form
  expect_output = 'regex'     # optional: must match the log (whitespace collapsed)
  expect_window = "39800-40700"   # optional: print-only window (see tools/windows.py),
                              # Ggas intervals "lo-hi, lo-hi"; a string checks the union of
                              # all labels, a table { Books = "..." } checks per label
  window_step = 100           # optional: max gap inside one window interval (Ggas)
  [run.constants]             # CONSTANT name -> TLA+ expression text (merged over
  Menu = '<<1, 2>>'           # [constants]); TOML ints and booleans are also accepted

Every key except name/expect/invariant/expect_*/window_step may also be given at the
top level as a default for all runs of the file.

A run that takes longer than budget_s fails but is still reported; a run still going
after 3 x budget_s is killed and reported as "timeout".

Peel mode (--peel): on a violation, drop the violated invariant/property and rerun,
until the run is clean, stops for another reason, or nothing is left; report the set
of violated names. expect = "violation" then means "the invariant is in the set".

Environment: TLA2TOOLS_JAR (if tools/tla2tools.jar is missing), NEAR_TLA_LIBRARY
(like --library), TLC_JAVA_OPTS (extra JVM options, e.g. -Xmx4g).
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import tlcparse  # noqa: E402
import trace as tlctrace  # noqa: E402  (tools/trace.py, not the stdlib module)
import windows  # noqa: E402

MAX_WORKERS = 4
HARD_TIMEOUT_FACTOR = 3
EXPECTS = ("pass", "violation", "assert", "deadlock")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

FILE_KEYS = {"spec", "workers", "library", "budget_s", "init", "next", "specification",
             "invariants", "properties", "deadlock", "tags", "constants", "run"}
RUN_ONLY_KEYS = {"name", "expect", "invariant", "expect_output", "expect_window", "window_step"}
RUN_KEYS = (FILE_KEYS - {"run"}) | RUN_ONLY_KEYS


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

    @property
    def dir(self) -> Path:
        return self.toml.parent

    @property
    def build(self) -> Path:
        return self.dir / "build"


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


def _str_list(where: str, key: str, v) -> list[str]:
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise ConfigError(f"{where}: {key} must be a list of strings")
    return list(v)


def load_file(path: Path) -> list[Run]:
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
        merged = {**defaults, **{k: v for k, v in raw.items() if k != "constants"}}
        name = merged.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            raise ConfigError(f"{where}: name must match {NAME_RE.pattern}")
        where = f"{rel(path)} run {name}"
        spec = merged.get("spec")
        if not isinstance(spec, str) or not IDENT_RE.match(spec):
            raise ConfigError(f"{where}: spec must name a module")
        if not (path.parent / f"{spec}.tla").is_file():
            raise ConfigError(f"{where}: {spec}.tla not found beside runs.toml")
        expect = merged.get("expect")
        if expect not in EXPECTS:
            raise ConfigError(f"{where}: expect must be one of {EXPECTS}")
        lib = merged.get("library", "../../modules")
        libs = [lib] if isinstance(lib, str) else _str_list(where, "library", lib)
        consts = {}
        for src in (file_consts, raw.get("constants", {})):
            if not isinstance(src, dict):
                raise ConfigError(f"{where}: constants must be a table")
            for k, v in src.items():
                if not IDENT_RE.match(k):
                    raise ConfigError(f"{where}: bad constant name {k!r}")
                consts[k] = tla_value(k, v)
        r = Run(
            name=name, toml=path, spec=spec, expect=expect,
            library=[str((path.parent / x).resolve()) for x in libs],
            workers=int(merged.get("workers", 2)),
            budget_s=float(merged.get("budget_s", 60)),
            specification=merged.get("specification"),
            invariants=_str_list(where, "invariants", merged.get("invariants", [])),
            properties=_str_list(where, "properties", merged.get("properties", [])),
            deadlock=bool(merged.get("deadlock", False)),
            tags=_str_list(where, "tags", merged.get("tags", [])),
            constants=consts,
            invariant=merged.get("invariant"),
            expect_output=merged.get("expect_output"),
            expect_window=merged.get("expect_window"),
            window_step=int(merged.get("window_step", 100)),
        )
        if r.specification:
            if "init" in merged or "next" in merged:
                raise ConfigError(f"{where}: give either specification or init/next, not both")
            r.init = r.next = None
        else:
            r.init, r.next = merged.get("init", "Init"), merged.get("next", "Next")
        for n in [r.init, r.next, r.specification, *r.invariants, *r.properties]:
            if n is not None and not IDENT_RE.match(n):
                raise ConfigError(f"{where}: {n!r} is not an operator name")
        if r.expect == "violation":
            if not r.invariant:
                raise ConfigError(f"{where}: expect = \"violation\" needs invariant = \"<name>\"")
            if r.invariant not in r.invariants + r.properties:
                raise ConfigError(f"{where}: invariant {r.invariant} is not in invariants/properties")
        elif r.invariant:
            raise ConfigError(f"{where}: invariant is only meaningful with expect = \"violation\"")
        if r.expect == "deadlock" and not r.deadlock:
            raise ConfigError(f"{where}: expect = \"deadlock\" needs deadlock = true")
        if r.expect_window is not None:
            ws = r.expect_window.values() if isinstance(r.expect_window, dict) else [r.expect_window]
            try:
                for w in ws:
                    windows.parse_spec(w)
            except (ValueError, AttributeError) as e:
                raise ConfigError(f"{where}: bad expect_window: {e}") from e
        if r.expect_output is not None:
            try:
                re.compile(r.expect_output)
            except re.error as e:
                raise ConfigError(f"{where}: bad expect_output regex: {e}") from e
        out.append(r)
    return out


def find_tomls(p: Path) -> list[Path]:
    if p.is_file():
        return [p]
    return sorted(x for x in p.rglob("runs.toml") if "build" not in x.relative_to(p).parts)


def select(args: list[str]) -> list[Run]:
    """Runs named by `args` (paths and/or run names); no args = everything under examples/."""
    paths = [a for a in args if os.path.exists(a)]
    names = [a for a in args if not os.path.exists(a)]
    tomls: list[Path] = []
    for a in paths or ([] if names else [str(ROOT / "examples")]):
        tomls += [t.resolve() for t in find_tomls(Path(a))]
    pool = list(dict.fromkeys(tomls + ([t.resolve() for t in find_tomls(ROOT / "examples")] if names else [])))
    loaded = {t: load_file(t) for t in pool}
    seen: dict[str, Path] = {}
    for t, rs in loaded.items():
        for r in rs:
            if r.name in seen:
                raise ConfigError(f"run name {r.name} is used in {rel(seen[r.name])} and {rel(t)}")
            seen[r.name] = t
    chosen = [r for t in dict.fromkeys(tomls) for r in loaded[t]]
    everything = [r for rs in loaded.values() for r in rs]
    for n in names:
        hit = [r for r in everything if fnmatch.fnmatchcase(r.name, n)]
        if not hit:
            raise ConfigError(f"no run or path named {n!r}")
        chosen += [r for r in hit if r not in chosen]
    return chosen


# ---------------------------------------------------------------- generation


def wrapper(run: Run, mod: str, invariants=None, properties=None) -> tuple[str, str]:
    """(wrapper module text, cfg text) for `run`, module name `mod`."""
    invs = run.invariants if invariants is None else invariants
    props = run.properties if properties is None else properties
    tla = [f"---- MODULE {mod} ----",
           f"\\* Generated by tools/run.py for run {run.name}; do not edit.",
           f"EXTENDS {run.spec}"]
    tla += [f"const_{k} == {v}" for k, v in run.constants.items()]
    tla.append("====")
    cfg = [f"\\* Generated by tools/run.py for run {run.name}; do not edit."]
    if run.specification:
        cfg.append(f"SPECIFICATION {run.specification}")
    else:
        cfg += [f"INIT {run.init}", f"NEXT {run.next}"]
    if run.constants:
        cfg.append("CONSTANTS")
        cfg += [f"  {k} <- const_{k}" for k in run.constants]
    if invs:
        cfg.append("INVARIANTS")
        cfg += [f"  {i}" for i in invs]
    if props:
        cfg.append("PROPERTIES")
        cfg += [f"  {p}" for p in props]
    return "\n".join(tla) + "\n", "\n".join(cfg) + "\n"


# ---------------------------------------------------------------- running


def home_rewrite(text: str, home: str | None = None) -> str:
    homes = {home} if home else {os.path.expanduser("~"), os.path.realpath(os.path.expanduser("~"))}
    for h in sorted((h for h in homes if h and h != "/"), key=len, reverse=True):
        text = text.replace(h.rstrip("/"), "~")
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
    notes: list[str] = field(default_factory=list)
    log: str = ""
    peeled: list[str] | None = None


def tlc_once(run: Run, mod: str, invs, props, jar: str, workers: int):
    """Write the wrapper + cfg, run TLC; return (Result, wall seconds, log text, log path)."""
    run.build.mkdir(exist_ok=True)
    tla, cfg = wrapper(run, mod, invs, props)
    (run.build / f"{mod}.tla").write_text(tla)
    (run.build / f"{mod}.cfg").write_text(cfg)
    log_path = run.build / f"{mod.removeprefix('MC_')}.log"
    meta = tempfile.mkdtemp(prefix=f"tlc-{mod}-", dir="/tmp" if os.path.isdir("/tmp") else None)
    libpath = os.pathsep.join([str(run.dir)] + run.library)
    cmd = ["java", "-XX:+UseParallelGC", *shlex.split(os.environ.get("TLC_JAVA_OPTS", "")),
           f"-DTLA-Library={libpath}", "-cp", jar, "tlc2.TLC",
           *([] if run.deadlock else ["-deadlock"]),
           "-workers", str(workers), "-metadir", meta, "-config", f"{mod}.cfg", f"{mod}.tla"]
    hard = max(HARD_TIMEOUT_FACTOR * run.budget_s, run.budget_s + 30)
    t0 = time.monotonic()
    timed_out = False
    try:
        p = subprocess.run(cmd, cwd=run.build, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=hard)
        out, code = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out, code, timed_out = e.stdout or b"", None, True
    wall = time.monotonic() - t0
    shutil.rmtree(meta, ignore_errors=True)
    text = out.decode("utf-8", errors="replace") if isinstance(out, bytes) else out
    res = tlcparse.parse(text, code)
    if timed_out:
        res.verdict, res.message = "timeout", f"killed after {hard:.0f}s"
    log = home_rewrite(
        f"# run {run.name} ({rel(run.toml)})\n# {' '.join(shlex.quote(c) for c in cmd)}\n" + text
        + f"\n# runner: wall={wall:.1f}s exit={code} verdict={res.label()}\n")
    log_path.write_text(log)
    return res, wall, log, log_path


def check(run: Run, res, wall: float, log: str) -> tuple[bool, list[str]]:
    notes = []
    if res.verdict == "violation":
        ok = run.expect == "violation" and res.name == run.invariant
    else:
        ok = res.verdict == run.expect
    if res.message:
        notes.append(res.message)
    if wall > run.budget_s:
        ok = False
        notes.append(f"over budget: {wall:.1f}s > {run.budget_s:g}s")
    if run.expect_output is not None:
        if not re.search(run.expect_output, " ".join(log.split())):
            ok = False
            notes.append(f"expect_output /{run.expect_output}/ not found")
    if run.expect_window is not None:
        w = windows.windows(log, run.window_step)
        got_all = windows.fold(set().union(*windows.reports(log).values()) if w else set(), run.window_step)
        notes.append("window " + "; ".join(f"{k} {windows.fmt_ggas(v)}" for k, v in w.items()) if w
                     else "window: none")
        if isinstance(run.expect_window, dict):
            for label, spec in run.expect_window.items():
                if w.get(label, []) != windows.parse_spec(spec):
                    ok = False
                    notes.append(f"expected window {label} {spec}")
        elif got_all != windows.parse_spec(run.expect_window):
            ok = False
            notes.append(f"expected window {run.expect_window}")
    return ok, notes


def cleanup(run: Run, mod: str):
    """Delete the wrapper, cfg, log and TLC trace files of one TLC invocation."""
    for p in [run.build / f"{mod}.tla", run.build / f"{mod}.cfg",
              run.build / f"{mod.removeprefix('MC_')}.log", *run.build.glob(f"{mod}_TTrace_*")]:
        p.unlink(missing_ok=True)
    try:
        run.build.rmdir()
    except OSError:
        pass


def do_run(run: Run, jar: str, workers: int | None, keep: bool, print_trace: bool) -> Outcome:
    w = min(workers or run.workers, MAX_WORKERS)
    mod = f"MC_{run.name}"
    res, wall, log, log_path = tlc_once(run, mod, None, None, jar, w)
    ok, notes = check(run, res, wall, log)
    o = Outcome(run.name, rel(run.dir), run.expect if run.expect != "violation" else f"violation {run.invariant}",
                res.label(), ok, wall, run.budget_s, res.generated, res.distinct, res.depth, notes, rel(log_path))
    if print_trace and res.verdict in ("violation", "assert", "deadlock"):
        o.notes.append("trace:\n" + tlctrace.summary(log))
    if ok and not keep:
        cleanup(run, mod)
        o.log = ""
    return o


def do_peel(run: Run, jar: str, workers: int | None, keep: bool, print_trace: bool) -> Outcome:
    w = min(workers or run.workers, MAX_WORKERS)
    invs, props = list(run.invariants), list(run.properties)
    peeled, wall_total, notes, mods = [], 0.0, [], []
    i = 0
    while True:
        mod = f"MC_{run.name}" + (f"_p{i}" if i else "")
        mods.append(mod)
        res, wall, log, log_path = tlc_once(run, mod, invs, props, jar, w)
        wall_total += wall
        print(f"  {run.name} step {i}: {res.label()} ({fmt_n(res.distinct)} distinct, {wall:.1f}s)",
              file=sys.stderr, flush=True)
        if wall > run.budget_s:
            notes.append(f"step {i} over budget: {wall:.1f}s > {run.budget_s:g}s")
        if print_trace and res.verdict in ("violation", "assert", "deadlock"):
            notes.append(f"trace (step {i}):\n" + tlctrace.summary(log))
        if res.verdict != "violation" or res.name not in invs + props:
            break
        peeled.append(res.name)
        invs = [x for x in invs if x != res.name]
        props = [x for x in props if x != res.name]
        if not invs and not props:
            break
        i += 1
    # "exhausted": the last remaining invariant/property was violated and peeled.
    final = "exhausted" if res.verdict == "violation" and res.name in peeled else res.verdict
    if res.message:
        notes.append(res.message)
    over = any("over budget" in n for n in notes)
    if run.expect == "violation":
        ok = run.invariant in peeled and final in ("pass", "exhausted", "violation")
    elif run.expect == "pass":
        ok = not peeled and final == "pass"
    else:
        ok = final == run.expect
    ok = ok and not over
    actual = "peeled {" + ", ".join(peeled) + "}" + (f" then {res.label()}" if final not in ("pass", "exhausted") else "")
    o = Outcome(run.name, rel(run.dir), run.expect if run.expect != "violation" else f"violation {run.invariant}",
                actual, ok, wall_total, run.budget_s, res.generated, res.distinct, res.depth, notes,
                rel(log_path), peeled)
    if ok and not keep:
        for m in mods:
            cleanup(run, m)
        o.log = ""
    return o


# ---------------------------------------------------------------- output


def fmt_n(n) -> str:
    return "-" if n is None else f"{n:,}"


def table(outs: list[Outcome]) -> str:
    head = ("run", "expect", "actual", "generated", "distinct", "depth", "secs", "result")
    rows = [(o.run, o.expect, o.actual, fmt_n(o.generated), fmt_n(o.distinct), fmt_n(o.depth),
             f"{o.seconds:.1f}", "ok" if o.ok else "FAIL") for o in outs]
    wid = [max(len(str(x[i])) for x in [head, *rows]) for i in range(len(head))]
    line = lambda r: " | ".join(str(c).ljust(wid[i]) for i, c in enumerate(r)).rstrip()  # noqa: E731
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
    ap.add_argument("--workers", type=int, help=f"override TLC workers (capped at {MAX_WORKERS})")
    ap.add_argument("--library", help="override every run's library dir ($NEAR_TLA_LIBRARY likewise)")
    ap.add_argument("--keep", action="store_true", help="keep build files and logs of passing runs")
    ap.add_argument("--print-trace", action="store_true", help="print a counterexample summary on a violation")
    ap.add_argument("--peel", action="store_true", help="peel mode: drop violated invariants and rerun")
    ap.add_argument("--json", metavar="PATH", help="also write the results as JSON")
    a = ap.parse_args(argv)
    try:
        runs = select(a.targets)
        lib = a.library or os.environ.get("NEAR_TLA_LIBRARY")
        if lib:
            for r in runs:
                r.library = [str(Path(x).resolve()) for x in lib.split(os.pathsep)]
        if a.list:
            for r in runs:
                exp = r.expect + (f" {r.invariant}" if r.invariant else "")
                print(f"{r.name:24} {rel(r.dir):24} {exp:24} {' '.join(r.tags)}")
            return 0
        if not runs:
            print("no runs selected", file=sys.stderr)
            return 2
        jar = find_jar(a.jar)
    except ConfigError as e:
        print(f"run.py: {e}", file=sys.stderr)
        return 2
    outs = []
    for r in runs:
        print(f"running {r.name} ({rel(r.dir)}) ...", file=sys.stderr, flush=True)
        outs.append((do_peel if a.peel else do_run)(r, jar, a.workers, a.keep, a.print_trace))
    print(table(outs))
    bad = [o.run for o in outs if not o.ok]
    print(f"\n{len(outs) - len(bad)}/{len(outs)} runs as expected" + (f"; FAILED: {' '.join(bad)}" if bad else ""))
    if a.json:
        Path(a.json).write_text(json.dumps([asdict(o) for o in outs], indent=2) + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
