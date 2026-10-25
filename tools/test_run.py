#!/usr/bin/env python3
"""Self-tests for the runner: python3 -m unittest tools/test_run.py

Canned TLC 2.19 output snippets, toy module names; no TLC needed.
"""

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import audit  # noqa: E402
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

    def test_constant_level_invariant(self):
        """An invariant that reads no variable is checked once, before the search."""
        text = ("Starting... (2026-01-01 00:00:00)\n"
                "Error: The invariant of FeesOk is equal to FALSE\n"
                "Finished in 00s at (2026-01-01 00:00:00)\n")
        r = tlcparse.parse(text, 151)
        self.assertEqual((r.verdict, r.name), ("violation", "FeesOk"))
        # a non-Boolean value that merely starts with FALSE is not a violation
        r = tlcparse.parse(text.replace("FALSE\n", "FALSELY\n"), 151)
        self.assertNotEqual(r.verdict, "violation")

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
            invariants = ["Inv"]
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

    def test_pass_needs_an_invariant_not_only_properties(self):
        """An empty INVARIANTS section is refused for a pass run, properties or not."""
        with self.assertRaisesRegex(run.ConfigError, "empty INVARIANTS"):
            self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\nproperties = ["Live"]\n')
        (r,) = self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "pass"\nproperties = ["Live"]\n'
                         'allow_no_invariants = "a liveness-only check"\n')
        self.assertEqual(r.properties, ["Live"])
        # a must-fail run on a property alone stays allowed
        (r,) = self.load('spec = "Toy"\n[[run]]\nname = "x"\nexpect = "violation"\ninvariant = "Live"\n'
                         'properties = ["Live"]\n')
        self.assertEqual(r.invariant, "Live")

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

    def test_module_qualified_constant(self):
        """`Mod!Name` overrides a definition of a module the spec reaches, INSTANCE included."""
        lib = self.d / "lib"
        lib.mkdir()
        write(lib, "Fees.tla", '---- MODULE Fees ----\nRounding == "up"\nFee(x) == x\n====\n')
        write(lib, "Plat.tla", "---- MODULE Plat ----\nCONSTANT Accts\nTable == INSTANCE Fees\n====\n")
        write(lib, "Other.tla", '---- MODULE Other ----\nKnob == 1\n====\n')
        write(self.d, "Spec3.tla", "---- MODULE Spec3 ----\nEXTENDS Plat\n====\n")
        (r,) = self.load('spec = "Spec3"\nlibrary = "lib"\n[constants]\n"Fees!Rounding" = \'"nearest"\'\n'
                         '[[run]]\nname = "q"\nexpect = "pass"\ninvariants = ["A"]\n'
                         '[run.constants]\nAccts = "{1}"\n')
        self.assertEqual(r.constants["Fees!Rounding"], '"nearest"')
        self.assertIsNone(run.check_constants(r))
        self.assertEqual(set(run.reachable_modules("Spec3", [str(self.d), str(lib)])), {"Spec3", "Plat", "Fees"})
        tla, cfg = run.wrapper(r, "MC_q")
        self.assertIn('const_Fees_Rounding == "nearest"\n', tla)
        self.assertIn("  Rounding <- [Fees] const_Fees_Rounding\n", cfg)
        self.assertIn("  Accts <- const_Accts\n", cfg)
        for bad in ("Other!Knob",      # a module the spec does not reach
                    "Fees!Fee",        # not zero-arity
                    "Fees!Rounds",     # not defined there
                    "Rounding"):       # unqualified: Fees is INSTANCEd, not EXTENDed
            r.constants = {bad: "1"}
            with self.subTest(bad), self.assertRaises(run.ConfigError):
                run.check_constants(r)
        r.library = [str(self.d / "nowhere")]
        r.constants = {"Fees!Rounding": "1"}
        self.assertIsNotNone(run.check_constants(r))  # Plat missing: skipped with a warning
        for name in ("Fees!", "!Rounding", "Fees!Round!ing", "Fe es!Rounding"):
            with self.subTest(name), self.assertRaises(run.ConfigError):
                self.load(f'spec = "Spec3"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["A"]\n'
                          f'[run.constants]\n"{name}" = "1"\n')
        with self.assertRaises(run.ConfigError):  # two keys, one wrapper definition
            self.load('spec = "Spec3"\n[[run]]\nname = "x"\nexpect = "pass"\ninvariants = ["A"]\n'
                      '[run.constants]\n"Fees!Rounding" = "1"\nFees_Rounding = "2"\n')

    def test_module_qualified_constant_parameter_rejected(self):
        """`Mod!Knob` for a CONSTANT Knob would generate `Knob <- [Mod] ...`, which TLC does
        not accept as an assignment ("not assigned a value"): rejected, with the way out."""
        lib = self.d / "lib"
        lib.mkdir()
        write(lib, "ModC.tla", "---- MODULE ModC ----\nCONSTANT Knob\nDef == 1\n====\n")
        write(lib, "ModD.tla", "---- MODULE ModD ----\nCONSTANTS Dial, Knob2\n====\n")
        write(lib, "Plat.tla", "---- MODULE Plat ----\nEXTENDS ModC\nCONSTANT Dial\n"
                               "T == INSTANCE ModD WITH Knob2 <- 1\n====\n")
        write(self.d, "Spec4.tla", "---- MODULE Spec4 ----\nEXTENDS Plat\n====\n")
        (r,) = self.load('spec = "Spec4"\nlibrary = "lib"\n[[run]]\nname = "q"\nexpect = "pass"\n'
                         'invariants = ["A"]\n[run.constants]\n"ModC!Knob" = "10"\n')
        with self.assertRaisesRegex(run.ConfigError, r"Knob is a CONSTANT of ModC.*unqualified, 'Knob'"):
            run.check_constants(r)
        for ok in ({"Knob": "10"}, {"ModC!Def": "2"}, {"Dial": "1"}):
            r.constants = ok
            with self.subTest(ok):
                self.assertIsNone(run.check_constants(r))
        r.constants = {"ModD!Dial": "1"}   # also declared by Plat: unqualified works
        with self.assertRaisesRegex(run.ConfigError, r"unqualified, 'Dial'"):
            run.check_constants(r)
        r.constants = {"ModD!Knob2": "1"}  # only in the INSTANCEd module
        with self.assertRaisesRegex(run.ConfigError, r"INSTANCE ModD WITH Knob2 <- \.\.\."):
            run.check_constants(r)
        self.assertEqual(run.module_names("---- MODULE M ----\nEXTENDS A\nCONSTANT K\nD == 1\n====\n"),
                         (["A"], {"K"}, {"D"}))

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
        self.assertEqual(files, ["MC_t.cfg", "MC_t.tla", "jtmp"])  # a fresh dir: nothing else in it
        # TLC unpacks its standard modules into a private java.io.tmpdir, not a shared one
        self.assertIn(f"-Djava.io.tmpdir={os.path.join(cwd, 'jtmp')}", cmd)
        self.assertNotEqual(Path(cwd).resolve(), (self.d / "build").resolve())
        lib = next(c for c in cmd if c.startswith("-DTLA-Library="))
        self.assertNotIn("build", lib)
        self.assertFalse(os.path.exists(cwd))  # temp dir removed
        self.assertFalse((self.d / "build" / "t.log").exists())  # passing run: log removed

    # the JVM thread stack: 16m for every run, after it TLC_JAVA_OPTS, then a run's own stack
    def test_thread_stack(self):
        old = os.environ.pop("TLC_JAVA_OPTS", None)
        try:
            self.outputs = [(PASS, 0), (PASS, 0)]
            self.assertTrue(self.go(self.load('expect = "pass"\ninvariants = ["Small"]')).ok)
            os.environ["TLC_JAVA_OPTS"] = "-Xss4m"
            self.assertTrue(self.go(self.load('expect = "pass"\ninvariants = ["Small"]\nstack = "512k"')).ok)
        finally:
            os.environ.pop("TLC_JAVA_OPTS", None)
            if old is not None:
                os.environ["TLC_JAVA_OPTS"] = old
        xss = [[c for c in cmd if c.startswith("-Xss")] for cmd, _, _ in self.calls]
        self.assertEqual(xss, [["-Xss16m"], ["-Xss16m", "-Xss4m", "-Xss512k"]])
        with self.assertRaisesRegex(run.ConfigError, "stack must be a JVM size"):
            self.load('expect = "pass"\ninvariants = ["Small"]\nstack = "16 MB"')

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


TOY_RUNS = """\
spec = "Toy"
library = "lib"
invariants = ["Small"]
[[run]]
name = "t_ok"
expect = "pass"
[[run]]
name = "t_win"
expect = "pass"
expect_window = "1"
[[run]]
name = "t_bad"
expect = "violation"
invariant = "Small"
"""

WIT = "[[witness]]\nid = \"seen\"\nexpr = '~(x > 0)'\n"
MUT = ("[[mutant]]\nid = \"m\"\nfile = \"Toy.tla\"\nfind = \"x + 1\"\nreplace = \"x\"\n"
       "class = \"dropped step\"\n")
WIT_INV = INV.replace("Invariant Small", "Invariant Wit_seen")


class AntiVacuityLoadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        write(self.d, "Toy.tla", "---- MODULE Toy ----\nStep == x' = x + 1\n====\n")
        (self.d / "lib").mkdir()
        write(self.d / "lib", "Lib.tla", "---- MODULE Lib ----\nGuard == TRUE\n====\n")

    def tearDown(self):
        self.tmp.cleanup()

    def load(self, extra: str):
        return run.load_doc(write(self.d, "runs.toml", TOY_RUNS + extra))

    def test_defaults_and_fields(self):
        _, (w, u), (m,) = self.load(
            WIT + 'about = "x moves"\n'
            + "[[witness]]\nid = \"never\"\nexpr = 'x # 9'\nexpect = \"unreachable\"\nreason = \"bounded\"\n"
            + 'runs = ["t_*"]\n' + MUT)
        # default: every pass run without expect_window
        self.assertEqual((w.runs, w.op, w.expect, w.about), (["t_ok"], "Wit_seen", "reached", "x moves"))
        self.assertEqual((u.runs, u.reason), (["t_ok", "t_win", "t_bad"], "bounded"))
        self.assertEqual((m.runs, m.count, m.library, m.equivalent, m.cls),
                         (["t_ok"], 1, False, None, "dropped step"))

    def test_validation(self):
        bad = {
            "unknown witness key": WIT + "exp = 'x'\n",
            "bad id": WIT.replace('"seen"', '"a-b"'),
            "empty expr": WIT.replace("'~(x > 0)'", "' '"),
            "duplicate id": WIT + WIT,
            "unreachable without reason": WIT + 'expect = "unreachable"\n',
            "reason without unreachable": WIT + 'reason = "x"\n',
            "unknown expect": WIT + 'expect = "maybe"\n',
            "glob matches nothing": WIT + 'runs = ["nope*"]\n',
            "empty runs": WIT + "runs = []\n",
            "mutant on a must-fail run": MUT + 'runs = ["t_bad"]\n',
            "mutant file with a path": MUT.replace('"Toy.tla"', '"../Toy.tla"'),
            "mutant file missing": MUT.replace('"Toy.tla"', '"Nope.tla"'),
            "mutant without class": MUT.replace('class = "dropped step"\n', ""),
            "mutant without replace": MUT.replace('replace = "x"\n', ""),
            "mutant no-op": MUT.replace('replace = "x"', 'replace = "x + 1"'),
            "mutant count 0": MUT + "count = 0\n",
            "empty equivalent": MUT + 'equivalent = ""\n',
            "unknown mutant key": MUT + "lib = 0\n",
            "string library flag": MUT + 'library = "true"\n',
        }
        for why, body in bad.items():
            with self.subTest(why), self.assertRaises(run.ConfigError):
                self.load(body)
        # a library mutant's file is looked up at preflight, not at load
        self.load(MUT.replace('"Toy.tla"', '"Lib.tla"') + "library = true\n")

    def test_no_default_run(self):
        with self.assertRaises(run.ConfigError):
            run.load_doc(write(self.d, "runs.toml", 'spec = "Toy"\ninvariants = ["A"]\n[[run]]\nname = "v"\n'
                               'expect = "violation"\ninvariant = "A"\n' + WIT))

    def test_selection_narrows_checks(self):
        write(self.d, "runs.toml", TOY_RUNS + WIT + 'runs = ["t_ok", "t_bad"]\n'
              + "[[witness]]\nid = \"v\"\nexpr = 'TRUE'\nruns = [\"t_bad\"]\n")
        runs, wits, muts = run.select_checks([str(self.d), "t_ok"])
        self.assertEqual([r.name for r in runs], ["t_ok"])
        self.assertEqual([(w.id, w.runs) for w in wits], [("seen", ["t_ok"])])
        self.assertEqual(muts, [])
        self.assertEqual([r.name for r in run.select([str(self.d)])], ["t_ok", "t_win", "t_bad"])

    def test_witness_wrapper(self):
        (r, *_), (w,), _ = self.load("[[witness]]\nid = \"seen\"\nexpr = '''\n  ~(/\\ x > 0\n    /\\ x < 3)\n'''\n")
        tla, cfg = run.wrapper(r, "MC_t_ok__w_seen", [w.op], [], defs=[(w.op, w.expr)])
        self.assertIn("Wit_seen ==\n    ~(/\\ x > 0\n      /\\ x < 3)\n====", tla)
        self.assertIn("INVARIANTS\n  Wit_seen\n", cfg)
        self.assertNotIn("Small", cfg)  # checked alone


class AntiVacuityFakeTLCTest(unittest.TestCase):
    """Witness and mutant jobs end to end, with canned TLC output."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name).resolve()
        write(self.d, "Toy.tla", "---- MODULE Toy ----\nStep == x' = x + 1\n====\n")
        write(self.d, "Other.tla", "---- MODULE Other ----\n====\n")
        (self.d / "lib").mkdir()
        write(self.d / "lib", "Lib.tla", "---- MODULE Lib ----\nGuard == TRUE\n====\n")
        self.calls = []
        self.outputs = []
        self._orig = run.subprocess.run
        run.subprocess.run = self.fake

    def tearDown(self):
        run.subprocess.run = self._orig
        self.tmp.cleanup()

    def fake(self, cmd, cwd=None, timeout=None, **kw):
        lib = next(c for c in cmd if c.startswith("-DTLA-Library=")).split("=", 1)[1].split(os.pathsep)
        mods = {d: {f: Path(d, f).read_text() for f in sorted(os.listdir(d)) if f.endswith(".tla")}
                for d in lib if os.path.isdir(d)}
        cfg = Path(cwd, cmd[cmd.index("-config") + 1]).read_text()
        self.calls.append((cmd, cwd, lib, mods, timeout, cfg))
        text, code = self.outputs.pop(0)
        if text is None:
            raise subprocess.TimeoutExpired(cmd, timeout, output=b"Starting...\n")
        return subprocess.CompletedProcess(cmd, code, stdout=text.encode())

    def load(self, extra: str, runs_toml: str = TOY_RUNS):
        runs, wits, muts = run.load_doc(write(self.d, "runs.toml", runs_toml + extra))
        return {r.name: r for r in runs}, wits, muts

    def checks(self, by, wits, muts, failed=()):
        with contextlib.redirect_stderr(io.StringIO()):
            return run.run_checks(wits, muts, by, set(failed), "tla2tools.jar", None, keep=False)

    def test_witness_verdicts(self):
        cases = [
            ("", WIT_INV, 12, True, "reached"),
            ("", PASS, 0, False, "never reached"),
            ('expect = "unreachable"\nreason = "bounded"\n', PASS, 0, True, "never reached"),
            ('expect = "unreachable"\nreason = "bounded"\n', WIT_INV, 12, False, "reached"),
            ("", ASSERT, 14, False, "assert"),
            ("", None, None, False, "timeout"),
        ]
        for extra, text, code, ok, actual in cases:
            with self.subTest(extra=extra, actual=actual):
                by, wits, muts = self.load(WIT + extra)
                self.outputs = [(text, code)]
                (o,) = self.checks(by, wits, muts)
                self.assertEqual((o.ok, o.actual, o.kind, o.check), (ok, actual, "witness", "seen"), o.notes)
                if actual == "never reached" and not ok:
                    self.assertIn("vacuous: witness seen never reached", o.notes)
        cmd, cwd, lib, mods, timeout, cfg = self.calls[0]
        self.assertEqual(timeout, by["t_ok"].budget_s)  # a job is stopped at its run's budget
        self.assertEqual(lib[0], str(self.d))           # the spec dir, unpatched
        self.assertIn("INVARIANTS\n  Wit_seen\n", cfg)
        self.assertNotIn("Small", cfg)

    def test_witness_runs_on_each_listed_run(self):
        by, wits, muts = self.load(WIT + 'runs = ["t_ok", "t_bad"]\n')
        self.outputs = [(WIT_INV, 12), (PASS, 0)]
        outs = self.checks(by, wits, muts)
        self.assertEqual([(o.run, o.ok) for o in outs], [("t_ok", True), ("t_bad", False)])

    def test_mutant_patches_a_copy(self):
        by, wits, muts = self.load(MUT)
        self.outputs = [(INV, 12)]
        (o,) = self.checks(by, wits, muts)
        self.assertEqual((o.ok, o.actual, o.expect, o.kind), (True, "killed Small", "killed", "mutant"))
        cmd, cwd, lib, mods, _, cfg = self.calls[0]
        self.assertTrue(lib[0].startswith(cwd), lib)                 # the patched copy comes first
        self.assertEqual(sorted(mods[lib[0]]), ["Other.tla", "Toy.tla"])
        self.assertIn("Step == x' = x\n", mods[lib[0]]["Toy.tla"])
        self.assertIn("x + 1", (self.d / "Toy.tla").read_text())    # the original is untouched
        self.assertNotIn(str(self.d), lib)
        self.assertIn("INVARIANTS\n  Small\n", cfg)                  # the run's own invariants
        self.assertFalse(os.path.exists(cwd))

    def test_library_mutant(self):
        by, wits, muts = self.load(MUT.replace('"Toy.tla"', '"Lib.tla"').replace('"x + 1"', '"Guard == TRUE"')
                                   .replace('replace = "x"', 'replace = "Guard == FALSE"') + "library = true\n")
        self.outputs = [(INV, 12)]
        (o,) = self.checks(by, wits, muts)
        self.assertTrue(o.ok, o.notes)
        _, cwd, lib, mods, _, _ = self.calls[0]
        self.assertEqual(lib[0], str(self.d))                        # the spec dir as is
        self.assertTrue(lib[1].startswith(cwd))                      # the library copy in its place
        self.assertIn("Guard == FALSE", mods[lib[1]]["Lib.tla"])
        self.assertIn("Guard == TRUE", (self.d / "lib" / "Lib.tla").read_text())

    def test_library_mutant_shadowed_by_spec_dir(self):
        write(self.d, "Lib.tla", "---- MODULE Lib ----\nGuard == TRUE\n====\n")
        with self.assertRaisesRegex(run.ConfigError, "shadows the library module"):
            self.load(MUT.replace('"Toy.tla"', '"Lib.tla"').replace('"x + 1"', '"Guard == TRUE"')
                      .replace('replace = "x"', 'replace = "Guard == FALSE"') + "library = true\n")

    def test_mutant_verdicts(self):
        cases = [
            ("", [(ASSERT, 14)], False, "killed (assert)"),       # not an invariant: no coverage
            ('killed_by = ["assert"]\n', [(ASSERT, 14)], True, "killed (assert)"),
            ('killed_by = ["Other"]\n', [(INV, 12)], False, "killed Small"),  # the wrong invariant
            ('killed_by = ["Small"]\n', [(INV, 12)], True, "killed Small"),
            ("", [(PASS, 0)], False, "survived"),
            ('equivalent = "x is never read"\n', [(PASS, 0)], True, "equivalent"),
            ('equivalent = "x is never read"\n', [(INV, 12)], False, "killed Small"),
            ("", [(None, None)], False, "timeout"),                  # never "survived"
            ("", [(SEMANTIC, 150)], False, "error"),
        ]
        for extra, outs, ok, actual in cases:
            with self.subTest(extra=extra, actual=actual):
                by, wits, muts = self.load(MUT + extra)
                self.outputs = list(outs)
                (o,) = self.checks(by, wits, muts)
                self.assertEqual((o.ok, o.actual), (ok, actual), o.notes)
                if actual == "survived":
                    self.assertIn("survived: no run caught mutant m (dropped step)", o.notes)

    def test_mutant_deadlock_reported_separately(self):
        dl = TOY_RUNS.replace('name = "t_ok"\nexpect = "pass"\n', 'name = "t_ok"\nexpect = "pass"\ndeadlock = true\n')
        by, wits, muts = self.load(MUT + 'killed_by = ["deadlock"]\n', dl)
        self.outputs = [(DEADLOCK, 11)]
        (o,) = self.checks(by, wits, muts)
        self.assertEqual((o.ok, o.actual), (True, "killed (deadlock)"))
        self.assertNotIn("-deadlock", self.calls[0][0])

    def test_killed_by_any_run_but_a_timeout_fails(self):
        by, wits, muts = self.load(MUT + 'runs = ["t_ok", "t_win"]\n')
        self.outputs = [(PASS, 0), (INV, 12)]
        (o,) = self.checks(by, wits, muts)
        self.assertEqual((o.ok, o.actual, o.run), (True, "killed Small", "t_ok,t_win"))
        self.outputs = [(None, None), (INV, 12)]
        (o,) = self.checks(by, wits, muts)
        self.assertEqual((o.ok, o.actual), (False, "killed Small"))

    def test_checks_of_a_failed_run_are_skipped(self):
        by, wits, muts = self.load(WIT + MUT)
        outs = self.checks(by, wits, muts, failed=["t_ok"])
        self.assertEqual([(o.kind, o.ok, o.actual) for o in outs],
                         [("witness", False, "skipped"), ("mutant", False, "skipped")])
        self.assertEqual(self.calls, [])

    def test_preflight_counts_before_any_jvm(self):
        write(self.d, "runs.toml", TOY_RUNS + MUT.replace('find = "x + 1"', 'find = "x"')
              .replace('replace = "x"', 'replace = "y"'))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            rc = run.main([str(self.d), "--anti-vacuity", "--jar", str(self.d / "Toy.tla")])
        self.assertEqual(rc, 2)
        self.assertIn("find occurs 2 times", err.getvalue())
        self.assertEqual(self.calls, [])  # no JVM started, not even for the plain runs
        # without --anti-vacuity the count is not checked
        self.outputs = [(PASS, 0), (PASS + '<<"WIN", "B", 1>>', 0), (INV, 12)]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(run.main([str(self.d), "--jar", str(self.d / "Toy.tla")]), 0)

    def test_main_off_by_default_and_on_with_flag(self):
        write(self.d, "runs.toml", TOY_RUNS + WIT)
        jar = str(self.d / "Toy.tla")
        base = [(PASS, 0), (PASS + '<<"WIN", "B", 1>>', 0), (INV, 12)]
        self.outputs = list(base)
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            rc = run.main([str(self.d), "--jar", jar])
        self.assertEqual((rc, len(self.calls)), (0, 3))
        self.assertNotIn("witness", out.getvalue())
        self.outputs = base + [(PASS, 0)]
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            rc = run.main([str(self.d), "--jar", jar, "--anti-vacuity", "--json", str(self.d / "r.json")])
        self.assertEqual((rc, len(self.calls)), (1, 7))
        self.assertIn("vacuous: witness seen never reached", out.getvalue())
        self.assertIn("witnesses 1 (1 jobs): reached 0", out.getvalue())
        kinds = [o["kind"] for o in json.loads((self.d / "r.json").read_text())]
        self.assertEqual(kinds, ["run", "run", "run", "witness"])
        with contextlib.redirect_stdout(io.StringIO()) as out:
            run.main([str(self.d), "--list", "--anti-vacuity"])
        self.assertIn("witness seen", out.getvalue())

    def test_job_log_rewrites_home(self):
        by, wits, muts = self.load(WIT)
        home = os.path.expanduser("~")
        self.outputs = [(f"Parsing file {home}/models/Toy.tla\n" + PASS, 0)]
        (o,) = self.checks(by, wits, muts)
        self.assertFalse(o.ok)
        log = (self.d / "build" / "t_ok__w_seen.log").read_text()
        self.assertIn("~/models/Toy.tla", log)
        self.assertNotIn(home + "/", log)


SWEEP_RUNS = """\
spec = "Toy"
library = "lib"
invariants = ["Small"]
[constants]
Menu = "{0}"
[[run]]
name = "t_gas"
expect = "pass"
[[run]]
name = "t_win"
expect = "pass"
expect_window = "1"
"""
LEAST = ("[[sweep]]\nid = \"need\"\nkind = \"least_gas\"\nrun = \"t_gas\"\nknob = \"Menu\"\n"
         "form = '{%d}'\nlo = 0\nhi = 100\n")
SIZE = "[[sweep]]\nid = \"sz\"\nkind = \"size\"\nrun = \"t_gas\"\nknob = \"N\"\ncap = 10\nlimit = \"MaxLogs\"\n"


class SweepTest(unittest.TestCase):
    """[[sweep]] loading, the value and search helpers, and both kinds end to end."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name).resolve()
        write(self.d, "Toy.tla", "---- MODULE Toy ----\nCONSTANTS Menu, N\n====\n")
        (self.d / "lib").mkdir()
        write(self.d / "lib", "NearAsync.tla", "---- MODULE NearAsync ----\nMaxLogs              == 100      \\* x\n====\n")
        self.calls = []
        self.outputs = {}
        self._orig = run.subprocess.run
        run.subprocess.run = self.fake

    def tearDown(self):
        run.subprocess.run = self._orig
        self.tmp.cleanup()

    def fake(self, cmd, cwd=None, timeout=None, **kw):
        wrapper = Path(cwd, cmd[-1]).read_text()
        self.calls.append(wrapper)
        m = re.search(r"const_N == (-?\d+)", wrapper) or re.search(r"const_Menu == \{(-?\d+)\}", wrapper)
        text = WIN_PASS if "MC_t_win" in cmd[-1] else self.outputs(int(m.group(1)))
        return subprocess.CompletedProcess(cmd, 0 if text is PASS or text is WIN_PASS else 12, stdout=text.encode())

    def load(self, extra: str):
        runs, _, _ = run.load_doc(write(self.d, "runs.toml", SWEEP_RUNS + extra))
        return {r.name: r for r in runs}, run._SWEEPS[(self.d / "runs.toml").resolve()]

    def sweep(self, by, sw):
        with contextlib.redirect_stderr(io.StringIO()):
            return run.do_sweep(sw, by, "tla2tools.jar", None, keep=False)

    def test_load(self):
        _, (sw,) = self.load(LEAST + 'success = ["Small"]\nexpect_need = 7\n')
        self.assertEqual((sw.kind, sw.run, sw.knobs, sw.form, sw.lo, sw.hi, sw.success, sw.expect_need, sw.exact),
                         ("least_gas", "t_gas", ["Menu"], "{%d}", 0, 100, ["Small"], 7, False))
        _, (sw,) = self.load(LEAST + 'covers = ["on_x", "v.near.on_y log-size", "on_z least-gas owed"]\n')
        self.assertEqual(sw.covers, ["on_x", "v.near.on_y log-size", "on_z least-gas owed"])
        _, (sw,) = self.load(LEAST + 'exact = true\nstep = 5\n')
        self.assertEqual((sw.exact, sw.step), (True, 5))
        _, (sz,) = self.load(SIZE + 'knob = ["N", "Menu"]\n'.replace("knob", "form = '%d'\nfloor = 1\n#"))
        self.assertEqual((sz.cap, sz.limit, sz.floor), (10, "MaxLogs", 1))
        bad = {
            "unknown key": LEAST + "lim = 1\n",
            "kind": LEAST.replace("least_gas", "most_gas"),
            "run of another file": LEAST.replace('"t_gas"', '"nope"'),
            "no %d": LEAST.replace("{%d}", "{1}"),
            "hi below lo": LEAST.replace("hi = 100", "hi = 0"),
            "size key on least_gas": LEAST + "cap = 3\n",
            "least_gas key on size": SIZE + "hi = 3\n",
            "neither cap nor limit": SIZE.replace("cap = 10\nlimit = \"MaxLogs\"\n", ""),
            "bad expect verdict": SIZE + 'expect = { "10" = "fails" }\n',
            "window_run without window": LEAST + 'window_run = "t_gas"\n',
            "duplicate id": LEAST + LEAST,
            "step without exact": LEAST + "step = 5\n",
            "step 0": LEAST + "exact = true\nstep = 0\n",
            "exact not a bool": LEAST + "exact = 1\n",
            "exact on size": SIZE + "exact = true\n",
            "covers rule": LEAST + 'covers = ["on_x trie"]\n',
            "least-gas on size": SIZE + 'covers = ["on_x least-gas"]\n',
            "covers role": LEAST + 'covers = ["on_x least-gas both"]\n',
            "covers newline": LEAST + 'covers = ["on_x\\n"]\n',
            "covers empty": LEAST + "covers = []\n",
        }
        for what, text in bad.items():
            with self.subTest(what=what), self.assertRaises(run.ConfigError):
                self.load(text)

    def test_helpers(self):
        self.assertEqual(run.size_values([1, 10, 100], 0), [0, 1, 2, 9, 10, 11, 99, 100, 101])
        self.assertEqual(run.size_values([1, None, 2], 1), [1, 2, 3])
        for need in (1, 2, 37, 100):
            seen = []
            got = run.search_least(lambda v: seen.append(v) or v >= need, 0, 100)
            self.assertEqual(got, need)
            self.assertLessEqual(len(seen), 7)
        # Not monotone (holds at 20 and from 50): bisection finds the boundary 50, the scan 20.
        nm = lambda v: v == 20 or v >= 50
        self.assertEqual(run.search_least(nm, 0, 100), 50)
        self.assertEqual(run.scan_least(nm, run.scan_values(0, 100, 1)), (20, 50))
        self.assertEqual(run.scan_least(lambda v: v >= 37, run.scan_values(0, 100, 1)), (37, 37))
        self.assertEqual(run.scan_values(0, 25, 10), [0, 10, 20, 25])
        self.assertEqual(run.fmt_vals([21, 22, 23, 49, 60, 61]), "21..23, 49, 60..61")
        by, (sz,) = self.load(SIZE)
        self.assertEqual(run.limit_value(sz, by["t_gas"]), 100)

    def test_least_gas_end_to_end(self):
        by, (sw,) = self.load(LEAST + "expect_need = 37\n")
        self.outputs = lambda v: PASS if v >= 37 else INV
        rows = self.sweep(by, sw)
        self.assertEqual([(o.check, o.actual, o.ok) for o in rows],
                         [("need Menu=36", "violation Small", True), ("need Menu=37", "pass", True),
                          ("need Menu=38", "pass", True), ("need", "boundary 37", True)])
        self.assertEqual(rows[-1].expect, "boundary 37")
        self.assertIn("not checked", " ".join(rows[-1].notes))
        self.assertIn("const_Menu == {37}", "\n".join(self.calls))

    def test_least_gas_non_monotone_bisection_vs_exact(self):
        # Success at 20 and from 50 up.  Bisection reports the boundary 50 and passes (it
        # cannot see 20), labelled as a boundary; the exact scan finds 20 and fails as
        # non-monotone, naming 21..49 and 50.
        self.outputs = lambda v: PASS if v == 20 or v >= 50 else INV
        by, (sw,) = self.load(LEAST)
        rows = self.sweep(by, sw)
        self.assertEqual((rows[-1].actual, rows[-1].ok), ("boundary 50", True))
        self.assertIn("only if success is monotone", " ".join(rows[-1].notes))
        by, (sw,) = self.load(LEAST + "exact = true\n")
        n0 = len(self.calls)
        rows = self.sweep(by, sw)
        self.assertEqual(len(self.calls) - n0, 101)  # every value of 0..100, each once
        self.assertEqual([(o.check, o.actual) for o in rows[:-1]],
                         [("need Menu=19", "violation Small"), ("need Menu=20", "pass"),
                          ("need Menu=21", "violation Small"), ("need Menu=49", "violation Small"),
                          ("need Menu=50", "pass")])
        self.assertEqual((rows[-1].actual, rows[-1].ok), ("need 20", False))
        self.assertIn("fails at 21..49 above it", " ".join(rows[-1].notes))
        self.assertIn("every scanned value from 50", " ".join(rows[-1].notes))
        # Monotone: the scan agrees with bisection, and expect_need is checked against it.
        self.outputs = lambda v: PASS if v >= 37 else INV
        by, (sw,) = self.load(LEAST + "exact = true\nstep = 10\nexpect_need = 40\n")
        rows = self.sweep(by, sw)
        self.assertEqual([(o.check, o.actual) for o in rows],
                         [("need Menu=30", "violation Small"), ("need Menu=40", "pass"), ("need", "need 40")])
        self.assertTrue(rows[-1].ok)
        self.assertIn("in steps of 10", " ".join(rows[-1].notes))

    def test_least_gas_non_monotone_and_errors(self):
        by, (sw,) = self.load(LEAST)
        self.outputs = lambda v: PASS if v == 37 or v >= 50 else INV
        rows = self.sweep(by, sw)
        self.assertFalse(rows[-1].ok)
        self.assertIn("non-monotone", " ".join(rows[2].notes))
        self.outputs = lambda v: ASSERT
        (row,) = self.sweep(by, sw)
        self.assertEqual((row.actual, row.ok), ("error", False))
        self.outputs = lambda v: PASS
        (row,) = self.sweep(by, sw)
        self.assertIn("already holds at lo", " ".join(row.notes))

    def test_least_gas_from_window(self):
        by, (sw,) = self.load(LEAST + 'window_run = "t_win"\n')
        self.outputs = lambda v: PASS if v >= 37 else INV
        rows = self.sweep(by, sw)
        self.assertEqual(rows[-1].actual, "boundary 37")
        self.assertIn("top bad value 30", " ".join(rows[-1].notes))

    def test_size_end_to_end(self):
        by, (sz,) = self.load(SIZE + 'floor = 1\nexpect = { "11" = "violation Small" }\n')
        self.outputs = lambda v: INV if v == 11 else PASS
        rows = self.sweep(by, sz)
        self.assertEqual([o.check.split("=")[1] for o in rows], ["1", "2", "9", "10", "11", "99", "100", "101"])
        self.assertTrue(all(o.ok for o in rows), [(o.check, o.actual, o.notes) for o in rows])
        self.outputs = lambda v: PASS
        rows = self.sweep(by, sz)
        self.assertEqual([o.ok for o in rows if o.check.endswith("=11")], [False])


WIN_PASS = PASS.replace("Model checking completed.", '<<"WIN", "Small", 30, 0>>\n<<"WIN", "Small", 20, 0>>\n'
                        "Model checking completed.")


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


def fact(to="v", m="on_cb", owed=False, detached=False, cb=True, mode="fault", worst=False,
         known=False, fixed=False, lgn=0, lgb=0, trn=0, lib=False) -> audit.Fact:
    return audit.Fact(to, m, owed, detached, cb, mode, worst, known, fixed, lgn, lgb, trn, lib)


def tla_fact(f: audit.Fact) -> str:
    """The tuple as TLC's PrintT shows it."""
    v = lambda x: ("TRUE" if x else "FALSE") if isinstance(x, bool) else (str(x) if isinstance(x, int) else f'"{x}"')
    return "<<" + ", ".join(['"AUDIT"'] + [v(x) for x in vars(f).values()]) + ">>"


class AuditTest(unittest.TestCase):
    """The audit's fact parser, its rules, the [audit] table and the runner's hook."""

    def rules(self, facts, sweeps=(), methods=None, accept=None):
        gaps, _ = audit.gaps(facts, list(sweeps), methods, accept or {})
        return sorted((g.key, g.rule, g.accepted is not None, g.lib) for g in gaps)

    def test_parse(self):
        f = fact(owed=True, mode="gas", worst=True, known=True, fixed=True, lgn=1, lgb=120, trn=88)
        text = tla_fact(f)
        wrapped = text.replace(", ", ",\n   ", 4)  # TLC wraps a long tuple
        self.assertEqual(audit.parse("x\n" + wrapped + "\n<<\"WIN\", \"A\", 3>>\n"), {f})
        self.assertEqual(audit.parse('<<"AUDIT", "v", "m">>'), set())  # wrong arity: ignored
        # strings may hold >>, commas and escaped quotes; account ids may hold dots
        odd = fact(to="vault.near", m='ph>>a,n"tom')
        self.assertEqual(audit.parse(tla_fact(odd).replace('n"tom', 'n\\"tom')), {odd})
        self.assertEqual(audit.parse(tla_fact(fact()).replace("FALSE", "7", 1)), set())  # wrong types

    def test_owed_rules(self):
        owed = dict(owed=True, m="on_res")
        # fault mode only
        self.assertEqual(self.rules({"a": {fact(**owed)}}),
                         [("v.on_res", "gas", False, False), ("v.on_res", "logs", False, False)])
        # gas mode, no TrieGasWorst, no sweep
        g = fact(**owed, mode="gas", known=True, fixed=True, lgn=1, lgb=50)
        self.assertEqual(self.rules({"a": {g}}),
                         [("v.on_res", "least-gas", False, False), ("v.on_res", "log-size", False, False),
                          ("v.on_res", "trie", False, False)])
        # TrieGasWorst without declared writes, then with
        w0 = fact(**owed, mode="gas", worst=True, known=True, fixed=True, lgn=1, lgb=50)
        self.assertIn(("v.on_res", "writes", False, False), self.rules({"a": {g}, "b": {w0}}))
        w1 = fact(**owed, mode="gas", worst=True, known=True, fixed=True, lgn=1, lgb=50, trn=40)
        sweeps = [audit.SweepRef("need", "least_gas", ["b"], ["on_res"])]
        # a budget sweep closes least-gas, not log-size
        self.assertEqual(self.rules({"a": {g}, "b": {w1}}, sweeps), [("v.on_res", "log-size", False, False)])
        sweeps = [audit.SweepRef("need", "least_gas", ["b"], ["on_res", "on_res log-size"])]
        self.assertEqual(self.rules({"a": {g}, "b": {w1}}, sweeps), [])
        # a sweep that does not list it in covers credits nothing
        self.assertIn(("v.on_res", "least-gas", False, False),
                      self.rules({"a": {g}, "b": {w1}}, [audit.SweepRef("need", "least_gas", ["b"], ["on_other"])]))
        # a sweep of a run that does not execute it covers nothing
        self.assertIn(("v.on_res", "least-gas", False, False),
                      self.rules({"a": {g}, "b": {w1}}, [audit.SweepRef("need", "least_gas", ["c"], ["on_res"])]))
        # a size sweep covers log-size, not least-gas
        got = self.rules({"b": {w1}}, [audit.SweepRef("sz", "size", ["b"], ["v.on_res"])])
        self.assertEqual(got, [("v.on_res", "least-gas", False, False)])

    def test_direct_calls_close_nothing(self):
        # owed in fault mode only; a direct (unowed) call of the same method runs in gas mode
        owed = fact(owed=True, m="on_res")
        direct = fact(m="on_res", cb=False, mode="gas", worst=True, known=True, fixed=True, trn=4, lgn=1, lgb=9)
        self.assertEqual(self.rules({"a": {owed}, "b": {direct}},
                                    [audit.SweepRef("need", "least_gas", ["b"], ["on_res"])]),
                         [("v.on_res", "gas", False, False), ("v.on_res", "logs", False, False)])

    def test_roles_judged_apart(self):
        def rules(facts, sweeps=(), accept=None):
            gaps, _ = audit.gaps(facts, list(sweeps), None, accept or {})
            return sorted((g.label, g.rule, g.accepted is not None) for g in gaps)
        # owed only in fault mode, declaring no logs; an unowed callback fully checked in gas mode
        owed = fact(owed=True)
        cb = fact(mode="gas", worst=True, known=True, fixed=True, trn=4, lgn=1, lgb=9)
        sw = [audit.SweepRef("need", "least_gas", ["b"], ["on_cb least-gas callback", "on_cb log-size callback"])]
        self.assertEqual(rules({"a": {owed}, "b": {cb}}, sw),
                         [("v.on_cb (owed)", "gas", False), ("v.on_cb (owed)", "logs", False)])
        # both roles in one base run: an entry without a role credits neither
        owed_gas = fact(owed=True, mode="gas", worst=True, known=True, fixed=True, trn=4, lgn=1, lgb=9)
        plain = [audit.SweepRef("need", "least_gas", ["a"], ["on_cb", "on_cb log-size"])]
        self.assertEqual(rules({"a": {owed_gas, cb}}, plain),
                         [("v.on_cb (callback)", "least-gas", False), ("v.on_cb (callback)", "log-size", False),
                          ("v.on_cb (owed)", "least-gas", False), ("v.on_cb (owed)", "log-size", False)])
        # with roles named, each closes its own; accept can name a role
        named = [audit.SweepRef("need", "least_gas", ["a"], ["on_cb least-gas owed", "on_cb log-size owed"])]
        self.assertEqual(rules({"a": {owed_gas, cb}}, named, {"on_cb least-gas callback": "x"}),
                         [("v.on_cb (callback)", "least-gas", True), ("v.on_cb (callback)", "log-size", False)])
        # a single role: no label, and a plain entry credits
        self.assertEqual(rules({"a": {owed_gas}}, plain), [])
        _, n = audit.gaps({"a": {owed_gas, cb}}, [], None, {})
        self.assertEqual(n, 1)

    def test_callbacks_and_plain_receipts(self):
        # a callback with a weight: no gas rule; one that logs: log-size
        self.assertEqual(self.rules({"a": {fact(mode="gas", known=True)}}), [])
        self.assertEqual(self.rules({"a": {fact(lgn=1, lgb=10)}}), [("v.on_cb", "log-size", False, False)])
        # a fixed budget makes a callback a subject; "logs" is for owed receipts only
        self.assertEqual(self.rules({"a": {fact(mode="gas", known=True, fixed=True)}}),
                         [("v.on_cb", "least-gas", False, False), ("v.on_cb", "trie", False, False)])
        # a first receipt is not audited, logs or not
        self.assertEqual(self.rules({"a": {fact(cb=False, lgn=1, lgb=10, mode="gas", fixed=True)}}), [])

    def test_dotted_accounts(self):
        f = {"a": {fact(to="vault.near", owed=True, m="on_res")}}
        self.assertEqual(self.rules(f, methods=["on_res", "vault.near.on_res"],
                                    accept={"on_res gas": "x", "vault.near.on_res logs": "y"}),
                         [("vault.near.on_res", "gas", True, False), ("vault.near.on_res", "logs", True, False)])

    def test_accept_inventory_and_library(self):
        f = {"a": {fact(owed=True, m="on_res")}}
        self.assertEqual(self.rules(f, accept={"on_res gas": "x"}),
                         [("v.on_res", "gas", True, False), ("v.on_res", "logs", False, False)])
        self.assertEqual(self.rules(f, accept={"v.on_res": "x"}),
                         [("v.on_res", "gas", True, False), ("v.on_res", "logs", True, False)])
        self.assertEqual(self.rules(f, methods=["on_res", "v.on_res", "w.on_res", "on_other"],
                                    accept={"v.on_res": "x", "on_other": "y"}),
                         [("on_other", "inventory", True, False), ("v.on_res", "gas", True, False),
                          ("v.on_res", "logs", True, False), ("w.on_res", "inventory", False, False)])
        lib = {"a": {fact(to="ft", m="ft_resolve_transfer", owed=True, lib=True)}}
        rep = audit.Report("x/runs.toml", 1, 2, audit.gaps(lib, [], None, {})[0], 1)
        self.assertEqual(rep.open, [])
        text = audit.render(rep)
        self.assertIn("1 of 2 runs", text)
        self.assertIn("no [audit] methods", text)
        self.assertIn("library token methods", text)

    def test_load_audit(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            write(d, "Toy.tla", "---- MODULE Toy ----\n====\n")
            base = 'spec = "Toy"\n[[run]]\nname = "a"\nexpect = "pass"\ninvariants = ["I"]\n'
            p = write(d, "runs.toml", base + '[audit]\nmethods = ["on_x", "v.on_y"]\n'
                      '[audit.accept]\n"on_x trie" = "no writes"\n"v.on_y" = "out of scope"\n')
            run.load_file(p)
            cfg = run._AUDIT[p.resolve()]
            self.assertEqual((cfg.methods, cfg.accept, cfg.runs),
                             (["on_x", "v.on_y"], {"on_x trie": "no writes", "v.on_y": "out of scope"}, 1))
            bad = {
                "unknown key": '[audit]\nmethod = ["x"]\n',
                "bad method": '[audit]\nmethods = ["a b"]\n',
                "trailing newline": '[audit]\nmethods = ["on_x\\n"]\n',
                "unknown rule": '[audit.accept]\n"on_x tri" = "why"\n',
                "unknown role": '[audit.accept]\n"on_x trie owe" = "why"\n',
                "empty reason": '[audit.accept]\n"on_x" = " "\n',
                "per-run audit": 'audit = 1\n',
            }
            for what, extra in bad.items():
                with self.subTest(what=what), self.assertRaises(run.ConfigError):
                    text = base + extra if what != "per-run audit" else base.replace('name = "a"', 'name = "a"\n' + extra)
                    run.load_file(write(d, "runs.toml", text))

    def test_wrapper_and_main(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t).resolve()
            write(d, "Toy.tla", "---- MODULE Toy ----\nEXTENDS NearAsync\n====\n")
            (d / "lib").mkdir()
            write(d / "lib", "NearAsync.tla", "---- MODULE NearAsync ----\nAuditOn == FALSE\nAuditReg == 41\n====\n")
            p = write(d, "runs.toml", 'spec = "Toy"\nlibrary = "lib"\ninvariants = ["I"]\n'
                      '[[run]]\nname = "a"\nexpect = "pass"\n[[run]]\nname = "b"\nexpect = "pass"\n'
                      '[audit]\nmethods = ["on_res"]\n')
            ra, rb = run.load_file(p)
            tla, cfg = run.wrapper(ra, "MC_a", audit_on=True)
            self.assertIn("const_AuditOn == TRUE", tla)
            self.assertIn("AuditOn <- const_AuditOn", cfg)
            self.assertNotIn("AuditOn", run.wrapper(ra, "MC_a")[1])
            self.assertTrue(run.auditable(ra))
            self.assertTrue(run.audit_override(ra, True))
            self.assertFalse(run.audit_override(ra, False))
            ra.constants["AuditOn"] = "TRUE"  # the run's own setting: kept, facts still read
            self.assertFalse(run.audit_override(ra, True))
            self.assertTrue(run.auditable(ra))
            del ra.constants["AuditOn"]
            f = fact(owed=True, m="on_res", mode="gas", known=True, fixed=True)
            seen = []

            def fake(cmd, cwd=None, **kw):
                seen.append(Path(cwd, cmd[-1].replace(".tla", ".cfg")).read_text())
                return subprocess.CompletedProcess(cmd, 0, stdout=(tla_fact(f) + "\n" + PASS).encode())
            orig, run.subprocess.run = run.subprocess.run, fake
            out = io.StringIO()
            try:
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(run.main([str(p), "--jar", str(p)]), 0)
                    self.assertEqual(run.main([str(p), "a", "--no-audit", "--jar", str(p)]), 0)
            finally:
                run.subprocess.run = orig
            self.assertTrue(all("AuditOn <- const_AuditOn" in c for c in seen[:2]))
            self.assertNotIn("AuditOn", seen[2])
            text = out.getvalue()
            self.assertEqual(text.count("audit runs.toml") + text.count(f"audit {run.rel(p)}"), 1)
            for rule in ("trie", "least-gas", "logs"):
                self.assertRegex(text, rf"v\.on_res\s+{rule}\s")
            # a library without the hook: run as before, no report
            write(d / "lib", "NearAsync.tla", "---- MODULE NearAsync ----\n====\n")
            run._AUDITABLE.clear()
            self.assertFalse(run.auditable(ra))


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
