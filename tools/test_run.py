"""Self-tests for the runner: python3 -m unittest tools/test_run.py

Canned TLC 2.19 output snippets, toy module names; no TLC needed.
"""

import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run  # noqa: E402
import tlcparse  # noqa: E402
import trace as tlctrace  # noqa: E402
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
        self.assertEqual((r.generated, r.distinct, r.left, r.depth), (12345, 6789, 0, 17))
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
        self.assertEqual(tlcparse.parse(SEMANTIC + INV).verdict, "error")

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
        write(self.d, "Toy.tla", "---- MODULE Toy ----\n====\n")

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
            workers = 9
            [run.constants]
            N = '{1, 2}'
            """)
        a, b = rs
        self.assertEqual(a.constants, {"N": "3", "Flag": "TRUE", "Menu": "<<1, 2>>"})
        self.assertEqual(b.constants["N"], "{1, 2}")
        self.assertEqual(a.library, [str((self.d / "lib").resolve())])
        self.assertEqual((a.init, a.next, a.invariants, a.deadlock), ("Init", "Next", ["Inv"], False))
        self.assertEqual(b.workers, 9)  # capped at run time, not load time

    def test_wrapper_and_cfg(self):
        (r,) = self.load("""
            spec = "Toy"
            [[run]]
            name = "w"
            expect = "pass"
            invariants = ["A", "B"]
            properties = ["P"]
            [run.constants]
            Menu = '<<39000, 39100>>'
            Who = '"u"'
            """)
        tla, cfg = run.wrapper(r, "MC_w")
        self.assertIn("---- MODULE MC_w ----", tla)
        self.assertIn("EXTENDS Toy\n", tla)
        self.assertIn("const_Menu == <<39000, 39100>>\n", tla)
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
            "bad window": 'expect = "pass"\nexpect_window = "a-b"',
        }
        for why, body in bad.items():
            with self.subTest(why), self.assertRaises(run.ConfigError):
                self.load(f'spec = "Toy"\n[[run]]\nname = "x"\n{body}\n')
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Missing"\n[[run]]\nname = "x"\nexpect = "pass"\n')
        with self.assertRaises(run.ConfigError):
            self.load('spec = "Toy"\n[[run]]\nname = "has-dash"\nexpect = "pass"\n')

    def test_check_window_and_output(self):
        (r,) = self.load("""
            spec = "Toy"
            [[run]]
            name = "g"
            expect = "pass"
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


class HomeRewriteTest(unittest.TestCase):
    def test_rewrite(self):
        self.assertEqual(run.home_rewrite("at /fakehome/u/x and /fakehome/u", home="/fakehome/u"), "at ~/x and ~")


if __name__ == "__main__":
    unittest.main()
