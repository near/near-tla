#!/usr/bin/env python3
"""Self-tests for the runner: python3 -m unittest tools/test_run.py

Canned TLC 2.19 output snippets, toy module names; no TLC needed.
"""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run  # noqa: E402
import tlcparse  # noqa: E402
import tlctrace  # noqa: E402
import windows  # noqa: E402

PASS = """\
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Semantic processing of module Toy
Starting... (2026-01-01 00:00:00)
Computing initial states...
Model checking completed. No error has been found.
  Estimates of the probability that TLC did not check all reachable states
  because two distinct states had the same fingerprint:
  calculated (optimistic):  val = 0.0
12,345 states generated, 6,789 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 17.
Finished in 01min 05s at (2026-01-01 00:01:05)
"""

INV = """\
Error: Invariant Small is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\\ x = 0
/\\ y = <<"a",
      "b">>

State 2: <Step line 7, col 9 to line 7, col 27 of module Toy>
/\\ x = 1
/\\ y = <<"a", "b">>

State 3: <Other line 9, col 9 to line 9, col 27 of module Toy>
/\\ x = 1
/\\ y = <<"c">>

3 states generated, 3 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 3.
Finished in 00s at (2026-01-01 00:00:00)
"""

ASSERT = """\
Error: The first argument of Assert evaluated to FALSE; the second argument was:
"missing key"
Error: The behavior up to this point is:
State 1: <Initial predicate>
x = 0

Error: The error occurred when TLC was evaluating the nested
expressions at the following positions:
0. Line 8, column 10 to line 8, column 58 in Toy
3 states generated, 3 distinct states found, 0 states left on queue.
"""

ASSUME = """\
Starting... (2026-01-01 00:00:00)
Error: Assumption line 5, col 8 to line 5, col 12 of module Toy is false.
Finished in 00s at (2026-01-01 00:00:00)
"""

DEADLOCK = """\
Error: Deadlock reached.
Error: The behavior up to this point is:
State 1: <Initial predicate>
x = 0

4 states generated, 4 distinct states found, 0 states left on queue.
"""

SEMANTIC = """\
Semantic errors:

*** Errors: 1

line 5, col 14 to line 5, col 22 of module Toy

Unknown operator: `Undefined'.

Starting... (2026-01-01 00:00:00)
Error: Parsing or semantic analysis failed.
"""

SYNTAX = """\
***Parse Error***
Was expecting "==== or more Module body"
Encountered "0" at line 4, column 15 and token "="

Fatal errors while parsing TLA+ spec in file Toy
"""

UNKNOWN_INV = """\
Error: The invariant Nope specified in the configuration file
is not defined in the specification.
Finished in 00s at (2026-01-01 00:00:00)
"""


class ParseTest(unittest.TestCase):
    def test_pass_and_counts(self):
        r = tlcparse.parse(PASS, 0)
        self.assertEqual(r.verdict, "pass")
        self.assertEqual((r.generated, r.distinct, r.depth), (12345, 6789, 17))
        self.assertEqual(r.tlc_seconds, 65)

    def test_invariant(self):
        r = tlcparse.parse(INV, 12)
        self.assertEqual((r.verdict, r.name), ("violation", "Small"))
        self.assertEqual(r.label(), "violation Small")

    def test_action_property_and_temporal(self):
        r = tlcparse.parse("Error: Action property Mono is violated.\n", 13)
        self.assertEqual((r.verdict, r.name), ("violation", "Mono"))
        r = tlcparse.parse("Error: Temporal properties were violated.\n", 13)
        self.assertEqual((r.verdict, r.name), ("violation", "<temporal>"))

    def test_assert(self):
        r = tlcparse.parse(ASSERT, 14)
        self.assertEqual(r.verdict, "assert")
        self.assertEqual(r.message, '"missing key"')

    def test_assumption(self):
        self.assertEqual(tlcparse.parse(ASSUME, 10).verdict, "assumption")

    def test_deadlock(self):
        self.assertEqual(tlcparse.parse(DEADLOCK, 11).verdict, "deadlock")

    def test_semantic_error(self):
        r = tlcparse.parse(SEMANTIC, 150)
        self.assertEqual(r.verdict, "error")
        self.assertIn("Unknown operator", r.message)

    def test_parse_error(self):
        r = tlcparse.parse(SYNTAX, 150)
        self.assertEqual(r.verdict, "error")
        self.assertIn("Was expecting", r.message)

    def test_parse_error_wins_over_other_errors(self):
        self.assertEqual(tlcparse.parse(SEMANTIC + INV, 150).verdict, "error")

    def test_config_error(self):
        r = tlcparse.parse(UNKNOWN_INV, 151)
        self.assertEqual(r.verdict, "error")
        self.assertIn("is not defined", r.message)

    def test_unfinished_and_bare_exit_code(self):
        self.assertEqual(tlcparse.parse("Starting...\n", None).verdict, "unfinished")
        self.assertEqual(tlcparse.parse("Starting...\n", 1).verdict, "error")


class TraceTest(unittest.TestCase):
    def test_states(self):
        st = tlctrace.states(INV)
        self.assertEqual([(n, a) for n, a, _ in st], [(1, "Initial predicate"), (2, "Step"), (3, "Other")])
        self.assertEqual(st[0][2], {"x": "0", "y": '<<"a", "b">>'})

    def test_summary_shows_changes_only(self):
        s = tlctrace.summary(INV)
        self.assertIn("State 2: Step\n    x = 1\nState 3", s)
        self.assertIn('State 3: Other\n    y = <<"c">>', s)

    def test_single_variable(self):
        self.assertEqual(tlctrace.states(DEADLOCK), [(1, "Initial predicate", {"x": "0"})])


class WindowsTest(unittest.TestCase):
    LOG = '<<"WIN", "Bal", 1200, {}>>\n<<"WIN",\n  "Bal", 1100, {"cb"}>>\n<<"WIN", "Bal", 1500>>\n' \
          '<<"WIN", "Other", 7>>\n'

    def test_reports_and_fold(self):
        self.assertEqual(windows.reports(self.LOG), {"Bal": {1100, 1200, 1500}, "Other": {7}})
        self.assertEqual(windows.windows(self.LOG)["Bal"], [(1100, 1200), (1500, 1500)])
        self.assertEqual(windows.fold([1, 3, 5], step=2), [(1, 5)])

    def test_parse_spec(self):
        self.assertEqual(windows.parse_spec("1100-1200, 1500"), [(1100, 1200), (1500, 1500)])
        self.assertEqual(windows.parse_spec(""), [])


def write(d: Path, name: str, text: str) -> Path:
    p = d / name
    p.write_text(textwrap.dedent(text))
    return p


class LoadAndWrapperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        write(self.d, "Toy.tla", "---- MODULE Toy ----\nCONSTANTS N, Menu, Who, Flag\n====\n")

    def tearDown(self):
        self.tmp.cleanup()

    def load(self, toml: str):
        return run.load_file(write(self.d, "runs.toml", toml))

    def test_defaults_and_constant_merge(self):
        rs = self.load("""
            spec = "Toy"
            library = "lib"
            invariants = ["Inv"]
            [constants]
            N = 3
            Flag = true
            Menu = '<<1, 2>>'
            [[run]]
            name = "a"
            expect = "pass"
            [[run]]
            name = "b"
            expect = "violation"
            invariant = "Inv"
            workers = 1
            [run.constants]
            N = '{1, 2}'
            """)
        a, b = rs
        self.assertEqual(a.constants, {"N": "3", "Flag": "TRUE", "Menu": "<<1, 2>>"})
        self.assertEqual(b.constants["N"], "{1, 2}")
        self.assertEqual(a.library, [str((self.d / "lib").resolve())])
        self.assertEqual((a.init, a.next, a.invariants, a.deadlock), ("Init", "Next", ["Inv"], False))
        self.assertEqual((a.workers, b.workers), (2, 1))

    def test_workers_flag_only_lowers(self):
        a, b = self.load("""
            spec = "Toy"
            invariants = ["Inv"]
            [[run]]
            name = "a"
            expect = "pass"
            workers = 1
            [[run]]
            name = "b"
            expect = "pass"
            workers = 3
            """)
        self.assertEqual(run.effective_workers(a, 4), 1)
        self.assertEqual(run.effective_workers(b, 2), 2)
        self.assertEqual(run.effective_workers(b, None), 3)

    def test_wrapper_and_cfg(self):
        (r,) = self.load(
            'spec = "Toy"\n[[run]]\nname = "w"\nexpect = "pass"\ninvariants = ["A", "B"]\n'
            'properties = ["P"]\n[run.constants]\nMenu = \'<<39000, 39100>>\'\n'
            "Who = '''\n  /\\ x\n  /\\ y\n'''\n")
        tla, cfg = run.wrapper(r, "MC_w")
        self.assertIn("---- MODULE MC_w ----", tla)
        self.assertIn("EXTENDS Toy\n", tla)
        self.assertIn("const_Menu == <<39000, 39100>>\n", tla)
        self.assertIn("const_Who ==\n    /\\ x\n    /\\ y\n", tla)  # multi-line: indented
        self.assertTrue(tla.rstrip().endswith("===="))
        self.assertIn("INIT Init\nNEXT Next\n", cfg)
        self.assertIn("CONSTANTS\n  Menu <- const_Menu\n  Who <- const_Who\n", cfg)
        self.assertIn("INVARIANTS\n  A\n  B\nPROPERTIES\n  P\n", cfg)
        _, cfg2 = run.wrapper(r, "MC_w_p1", invariants=["B"], properties=[])
        self.assertIn("INVARIANTS\n  B\n", cfg2)
        self.assertNotIn("PROPERTIES", cfg2)

    def test_specification(self):
        (r,) = self.load("""
            spec = "Toy"
            [[run]]
            name = "s"
            expect = "pass"
            specification = "Spec"
            properties = ["Live"]
            """)
        _, cfg = run.wrapper(r, "MC_s")
        self.assertIn("SPECIFICATION Spec\n", cfg)
        self.assertNotIn("INIT", cfg)
        self.assertNotIn("CONSTANTS", cfg)

    def test_validation(self):
        bad = {
            "violation without invariant": 'expect = "violation"\ninvariants = ["A"]',
            "invariant not checked": 'expect = "violation"\ninvariant = "B"\ninvariants = ["A"]',
            "unknown expect": 'expect = "maybe"',
            "unknown key": 'expect = "pass"\ninvariantz = ["A"]',
            "deadlock expect without flag": 'expect = "deadlock"',
            "bad window": 'expect = "pass"\ninvariants = ["A"]\nexpect_window = "a-b"',
            "reversed window": 'expect = "pass"\ninvariants = ["A"]\nexpect_window = "2-1"',
            "string boolean": 'expect = "pass"\ninvariants = ["A"]\ndeadlock = "false"',
            "string workers": 'expect = "pass"\ninvariants = ["A"]\nworkers = "2"',
            "too many workers": 'expect = "pass"\ninvariants = ["A"]\nworkers = 9',
            "temporal among several": 'expect = "violation"\ninvariant = "P"\nproperties = ["P", "Q"]',
        }
        for why, body in bad.items():
            with self.subTest(why), self.assertRaises(run.ConfigError):
                self.load(f'spec = "Toy"\n[[run]]\nname = "x"\n{body}\n')
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Missing"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["A"]\n')
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Toy"\n[[run]]\nname = "has-dash"\nexpect = "pass"\ninvariants = ["A"]\n')

    # 1. vacuous pass
    def test_pass_needs_something_to_check(self):
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\n')
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\nallow_no_invariants = " "\n')
        (r,) = self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\n'
                         'allow_no_invariants = "print-only window run"\nexpect_window = "1"\n')
        self.assertEqual(r.allow_no_invariants, "print-only window run")

    def test_zero_distinct_states_is_not_a_pass(self):
        (r,) = self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["A"]\n')
        empty = PASS.replace("12,345 states generated, 6,789 distinct", "0 states generated, 0 distinct")
        res = tlcparse.parse(empty, 0)
        self.assertEqual(res.verdict, "pass")
        ok, notes = run.check(r, res, 1.0, empty)
        self.assertFalse(ok)
        self.assertIn("vacuous", " ".join(notes))
        self.assertTrue(run.check(r, tlcparse.parse(PASS, 0), 1.0, PASS)[0])

    # 6. constant names
    def test_constant_may_not_shadow_operator(self):
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["N"]\n'
                      '[run.constants]\nN = "1"\n')
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["A"]\n'
                      'next = "Menu"\n[run.constants]\nMenu = "1"\n')

    def test_constants_checked_against_extends_chain(self):
        lib = self.d / "lib"
        lib.mkdir()
        write(lib, "Base.tla", """\
            ---- MODULE Base ----
            EXTENDS Naturals
            CONSTANT
                Accounts,   \\* comment CONSTANT Fake
                Op(_, _)
            (* CONSTANTS AlsoFake *)
            DefaultKind == "named"
            Helper(x) == x
            ====
            """)
        write(self.d, "Spec2.tla",
              '---- MODULE Spec2 ----\nEXTENDS Base, TLC\nCONSTANTS U, V\nS == "CONSTANT Str"\n====\n')
        (r,) = self.load('spec = "Spec2"\nlibrary = "lib"\n[[run]]\nname = "x"\nexpect = "pass"\n'
                         'invariants = ["A"]\n[run.constants]\nU = "1"\nV = "2"\nAccounts = "{}"\n'
                         'DefaultKind = \'"eth"\'\n')
        self.assertIsNone(run.check_constants(r))
        self.assertEqual(run.declared_constants("Spec2", [str(self.d), str(lib)]),
                         {"U", "V", "S", "Accounts", "Op", "DefaultKind"})
        for typo in ("Acounts", "Fake", "AlsoFake", "Str", "Helper"):
            r.constants = {typo: "1"}
            with self.subTest(typo), self.assertRaises(run.ConfigError):
                run.check_constants(r)
        r.library = [str(self.d / "nowhere")]
        self.assertIsNotNone(run.check_constants(r))  # Base missing: skipped with a warning

    # 7. temporal properties
    def test_temporal_matches_only_property(self):
        (r,) = self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "violation"\ninvariant = "Live"\n'
                         'invariants = ["A"]\nproperties = ["Live"]\n')
        res = tlcparse.parse("Error: Temporal properties were violated.\n", 13)
        self.assertTrue(run.check(r, res, 1.0, "")[0])
        res = tlcparse.parse("Error: Invariant A is violated.\n", 12)
        self.assertFalse(run.check(r, res, 1.0, "")[0])

    # 9. window labels
    def test_window_table_rejects_unlisted_labels(self):
        (r,) = self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["W"]\n'
                         'expect_window = { Bal = "1100" }\n')
        res = tlcparse.parse(PASS, 0)
        self.assertTrue(run.check(r, res, 1.0, PASS + '<<"WIN", "Bal", 1100>>')[0])
        ok, notes = run.check(r, res, 1.0, PASS + '<<"WIN", "Bal", 1100>> <<"WIN", "Other", 5>>')
        self.assertFalse(ok)
        self.assertIn("unexpected window label Other", notes)
        self.assertFalse(run.check(r, res, 1.0, PASS)[0])  # listed label missing

    def test_check_window_and_output(self):
        (r,) = self.load("""
            spec = "Toy"
            [[run]]
            name = "g"
            expect = "pass"
            invariants = ["W"]
            expect_window = "1100-1200"
            expect_output = 'gas \\|-> 1100'
            """)
        res = tlcparse.parse(PASS, 0)
        ok, notes = run.check(r, res, 1.0, PASS + '<<"WIN", "Bal", 1100>> <<"WIN", "Bal", 1200>> [gas\n |-> 1100]')
        self.assertTrue(ok, notes)
        self.assertEqual(r.expect_output, r"gas \|-> 1100")
        ok, notes = run.check(r, res, 1.0, PASS + '<<"WIN", "Bal", 1100>> gas |-> 1100')
        self.assertFalse(ok)  # window mismatch
        ok, notes = run.check(r, res, 1.0, PASS + '<<"WIN", "Bal", 1100>> <<"WIN", "Bal", 1200>> gas |-> 1200')
        self.assertFalse(ok)  # output mismatch
        ok, _ = run.check(r, res, 999.0, PASS + '<<"WIN", "Bal", 1100>> <<"WIN", "Bal", 1200>> gas |-> 1100')
        self.assertFalse(ok)  # over budget


class FakeTLCTest(unittest.TestCase):
    """End-to-end through do_run/do_peel with subprocess.run replaced by canned TLC output."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        write(self.d, "Toy.tla", "---- MODULE Toy ----\n====\n")
        self.calls = []
        self.outputs = []
        self._orig = run.subprocess.run
        run.subprocess.run = self.fake

    def tearDown(self):
        run.subprocess.run = self._orig
        self.tmp.cleanup()

    def fake(self, cmd, cwd=None, **kw):
        self.calls.append((cmd, cwd, sorted(os.listdir(cwd))))
        text, code = self.outputs.pop(0)
        return subprocess.CompletedProcess(cmd, code, stdout=text.encode())

    def load(self, body: str) -> run.Run:
        (r,) = run.load_file(write(self.d, "runs.toml",
                                   f'spec = "Toy"\nlibrary = "."\n[[run]]\nname = "t"\n{body}\n'))
        return r

    def go(self, r, peel=False):
        with contextlib.redirect_stderr(io.StringIO()):  # peel prints its steps
            return (run.do_peel if peel else run.do_run)(r, "tla2tools.jar", None, keep=False, print_trace=False)

    # 5. stale build modules cannot shadow the spec
    def test_wrapper_runs_outside_build(self):
        r = self.load('expect = "pass"\ninvariants = ["Small"]')
        (self.d / "build").mkdir()
        write(self.d / "build", "Toy.tla", "---- MODULE Toy ----\nStale == TRUE\n====\n")
        self.outputs = [(PASS, 0)]
        o = self.go(r)
        self.assertTrue(o.ok, o.notes)
        cmd, cwd, files = self.calls[0]
        self.assertEqual(files, ["MC_t.cfg", "MC_t.tla"])  # a fresh dir: nothing else in it
        self.assertNotEqual(Path(cwd).resolve(), (self.d / "build").resolve())
        lib = next(c for c in cmd if c.startswith("-DTLA-Library="))
        self.assertNotIn("build", lib)
        self.assertFalse(os.path.exists(cwd))  # temp dir removed
        self.assertFalse((self.d / "build" / "t.log").exists())  # passing run: log removed

    def test_mismatch_keeps_wrapper_and_log(self):
        r = self.load('expect = "pass"\ninvariants = ["Small"]')
        self.outputs = [(INV, 12)]
        self.assertFalse(self.go(r).ok)
        for f in ("MC_t.tla", "MC_t.cfg", "t.log"):
            self.assertTrue((self.d / "build" / f).exists(), f)

    # 8. expect_output sees TLC's output only, not the runner's header/footer
    def test_expect_output_ignores_runner_lines(self):
        r = self.load('expect = "pass"\ninvariants = ["Small"]\nexpect_output = "runner: wall"')
        self.outputs = [(PASS, 0)]
        self.assertFalse(self.go(r).ok)
        self.assertIn("runner: wall", (self.d / "build" / "t.log").read_text())

    # 2. pass needs exit code 0
    def test_pass_needs_exit_zero(self):
        r = self.load('expect = "pass"\ninvariants = ["Small"]')
        self.outputs = [(PASS, 1)]
        self.assertFalse(self.go(r).ok)

    # 3. peel is lenient only for expect = "violation"
    def test_peel(self):
        two = 'invariants = ["Small", "Big"]'
        cases = [
            (f'expect = "violation"\ninvariant = "Small"\n{two}', [(INV, 12), (PASS, 0)], True),
            (f'expect = "pass"\n{two}', [(INV, 12), (PASS, 0)], False),
            (f'expect = "pass"\n{two}', [(PASS, 0)], True),
            (f'expect = "assert"\n{two}', [(INV, 12), (ASSERT, 14)], False),
            (f'expect = "assert"\n{two}', [(ASSERT, 14)], True),
            (f'expect = "deadlock"\ndeadlock = true\n{two}', [(INV, 12), (DEADLOCK, 11)], False),
        ]
        for body, outs, want in cases:
            with self.subTest(body=body, outs=len(outs)):
                r = self.load(body)
                self.outputs = list(outs)
                o = self.go(r, peel=True)
                self.assertEqual(o.ok, want, (o.actual, o.notes))
                self.assertEqual(self.outputs, [])


class SelectionAndLibraryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name).resolve()
        for sub, names in (("m1", ["a1", "a2"]), ("m2", ["b1"])):
            (self.d / sub).mkdir()
            write(self.d / sub, "Toy.tla", "---- MODULE Toy ----\n====\n")
            body = "".join(f'[[run]]\nname = "{n}"\nexpect = "pass"\ninvariants = ["I"]\n' for n in names)
            write(self.d / sub, "runs.toml", f'spec = "Toy"\n{body}')

    def tearDown(self):
        self.tmp.cleanup()

    def names(self, *args):
        return [r.name for r in run.select([str(a) for a in args])]

    # 2. names filter within the given paths
    def test_names_filter_given_paths(self):
        self.assertEqual(self.names(self.d), ["a1", "a2", "b1"])
        self.assertEqual(self.names(self.d, "a2"), ["a2"])
        self.assertEqual(self.names(self.d, "a*"), ["a1", "a2"])
        self.assertEqual(self.names(self.d / "m1" / "runs.toml", "a1"), ["a1"])
        self.assertEqual(self.names(self.d / "m1", self.d / "m2", "b1", "a1"), ["b1", "a1"])
        with self.assertRaises(run.ConfigError):
            self.names(self.d / "m1", "b1")  # b1 exists, but not in the given path

    @unittest.skipUnless((run.ROOT / "examples" / "pay" / "runs.toml").is_file(), "needs examples/pay")
    def test_bare_names_use_repo_examples(self):
        self.assertEqual(self.names("pay_std"), ["pay_std"])

    # 1. library fallback for models outside examples/<name>/
    def test_default_library_falls_back_to_repo_modules(self):
        (r,) = run.load_file(self.d / "m2" / "runs.toml")
        self.assertEqual(r.library, [str(run.ROOT / "modules")])
        # ../../modules is used when it exists
        nested = self.d / "x" / "y"
        nested.mkdir(parents=True)
        (self.d / "modules").mkdir()
        write(nested, "Toy.tla", "---- MODULE Toy ----\n====\n")
        write(nested, "runs.toml", 'spec = "Toy"\n[[run]]\nname = "n"\nexpect = "pass"\ninvariants = ["I"]\n')
        (r,) = run.load_file(nested / "runs.toml")
        self.assertEqual(r.library, [str(self.d / "modules")])

    def test_explicit_library_wins(self):
        write(self.d / "m2", "runs.toml",
              'spec = "Toy"\nlibrary = "nowhere"\n[[run]]\nname = "b1"\nexpect = "pass"\ninvariants = ["I"]\n')
        (r,) = run.load_file(self.d / "m2" / "runs.toml")
        self.assertEqual(r.library, [str(self.d / "m2" / "nowhere")])


class ParsePrintTTest(unittest.TestCase):
    # 2. a PrintT of the sentence is not a pass
    def test_printed_sentence_is_not_a_pass(self):
        fake = '"Model checking completed. No error has been found."\n'
        self.assertNotEqual(tlcparse.parse(fake, 0).verdict, "pass")
        fake_inv = '"Error: Invariant X is violated."\n' + PASS
        self.assertEqual(tlcparse.parse(fake_inv, 0).verdict, "pass")


class HomeRewriteTest(unittest.TestCase):
    def test_rewrite(self):
        self.assertEqual(run.home_rewrite("at /fakehome/u/x and /fakehome/u", home="/fakehome/u"), "at ~/x and ~")
        # path boundary: a longer name with the same prefix is left alone
        self.assertEqual(run.home_rewrite("/fakehome/u2/x", home="/fakehome/u"), "/fakehome/u2/x")

    def test_temp_paths(self):
        s = "Parsing file /private/var/folders/ab/cd123/T/Naturals.tla and /tmp/tlc-x/MC.tla"
        self.assertEqual(run.home_rewrite(s, home="/fakehome/u"),
                         "Parsing file <tmp>/Naturals.tla and <tmp>/tlc-x/MC.tla")


if __name__ == "__main__":
    unittest.main()
