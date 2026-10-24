#!/usr/bin/env python3
"""Self-tests for conform.py: python3 -m unittest conformance/scripts/test_conform.py

A toy flows file, sweep and TLC log in a temp directory; no Rust, no TLC,
no data/ needed.
"""

import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import conform  # noqa: E402
import tlcparse  # noqa: E402
from mkconf import grid_points  # noqa: E402

FLOWS = """\
[world]
names = { "q-probe.near" = "q" }

[[flow]]
name = "f"
grid = "1:1.2:0.1"
tx = { signer = "alice.near", receiver = "q-probe.near", method = "work", args = "{}" }
"""
GRID = [1000, 1100, 1200]  # Ggas
OK_LOG = "Model checking completed. No error has been found.\n"


def sim_line(pp, recs, flow="f"):
    """A sweep line at `pp` Ggas with the conversion and `recs`
    (status, attached Ggas) as q-probe.near::work receipts."""
    rs = [dict(conversion=True, refund=None, receiver="alice.near", methods=[], actions=[], attached=0, status="ok")]
    rs += [dict(conversion=False, refund=None, receiver="q-probe.near", methods=["work"], actions=["FunctionCall"],
                attached=g * 10**9, status=s) for s, g in recs]
    return json.dumps(dict(flow=flow, gas=pp * 10**9, tx_ok=True, receipts=rs)) + "\n"


def model_report(pp, recs, to="q", m="work", tx=1):
    body = ", ".join(f'[to |-> "{to}", m |-> "{m}", st |-> "{s}", tx |-> {tx}, id |-> {i + 1}, g |-> {g}]'
                     for i, (s, g) in enumerate(recs))
    return f'<< "CONF", {pp}, {{{body}}} >>\n'


def read(path):
    with open(path) as f:
        return f.read()


class Conform(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.flows, self.data, self.build = (os.path.join(d, x) for x in ("probes.toml", "data", "build"))
        os.makedirs(self.data)
        os.makedirs(self.build)
        with open(self.flows, "w") as f:
            f.write(FLOWS)
        self.flows_sha = hashlib.sha256(FLOWS.encode()).hexdigest()

    def tearDown(self):
        self.tmp.cleanup()

    def write_sim(self, text, meta=None, **over):
        """The sweep `text`, and a meta bound to it (fields in `over`
        replace the bound ones; meta=False writes none; any other `meta`,
        `{}` included, is written as given)."""
        with open(os.path.join(self.data, "f.jsonl"), "w") as f:
            f.write(text)
        if meta is False:
            return
        if meta is None:
            m = dict(flows_file="probes.toml", flows_sha256=self.flows_sha, grid="1:1.2:0.1", points=len(GRID),
                     jsonl_sha256=hashlib.sha256(text.encode()).hexdigest())
            m.update(over)
        else:
            m = meta
        with open(os.path.join(self.data, "f.meta.json"), "w") as f:
            json.dump(m, f)

    def write_model(self, points):
        with open(os.path.join(self.build, "f.log"), "w") as f:
            for pp, recs in points.items():
                f.write(model_report(pp, recs))
            f.write(OK_LOG)

    def run_compare(self, subset=False):
        spec = conform.tomllib.loads(FLOWS)
        return conform.compare("f", spec, conform.TOL, subset, self.flows_sha, self.data, self.build)

    def run_main(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return conform.main(list(args), self.flows, self.data, self.build)

    def good(self):
        """A sweep and model that agree: two work receipts at every point."""
        recs = [("ok", 10000), ("oog", 20000)]
        self.write_sim("".join(sim_line(pp, recs) for pp in GRID))
        self.write_model({pp: recs for pp in GRID})

    def assertProblem(self, res, text):
        self.assertTrue(any(text in p for p in res["problems"]), res["problems"])

    def test_agreeing_flow_passes(self):
        self.good()
        res = self.run_compare()
        self.assertEqual(res["problems"], [])
        self.assertEqual((res["n"], res["stat_ok"], res["gas_ok"], res["receipts"]), (3, 3, 3, 6))
        self.assertEqual(self.run_main(), 0)

    def test_gas_within_tolerance_passes(self):
        self.write_sim("".join(sim_line(pp, [("ok", 10003), ("oog", 19996)]) for pp in GRID))
        self.write_model({pp: [("ok", 10000), ("oog", 20000)] for pp in GRID})
        res = self.run_compare()
        self.assertEqual(res["problems"], [])
        self.assertEqual(res["worst"], 4)

    def test_swapped_status_and_gas_fails(self):
        # Same (label, status) multiset and same gas multiset per label,
        # but the gas belongs to the other status.
        self.write_sim("".join(sim_line(pp, [("oog", 10000), ("ok", 20000)]) for pp in GRID))
        self.write_model({pp: [("ok", 10000), ("oog", 20000)] for pp in GRID})
        res = self.run_compare()
        self.assertEqual(res["stat_ok"], 3)
        self.assertEqual(res["gas_ok"], 0)
        self.assertEqual(res["worst"], 10000)
        self.assertProblem(res, "attached gas not paired")
        self.assertEqual(self.run_main(), 1)

    def test_joint_pairing(self):
        j = conform.joint
        self.assertEqual(j([("a", "ok", 1), ("a", "ok", 9)], [("a", "ok", 8), ("a", "ok", 2)]), (True, 1))
        self.assertEqual(j([("a", "ok", 1), ("a", "oog", 9)], [("a", "oog", 1), ("a", "ok", 9)]), (True, 8))
        self.assertEqual(j([("a", "ok", 1)], [("a", "ok", 1), ("a", "ok", 1)]), (False, 0))
        self.assertEqual(j([("t[Transfer]", "ok", None)], [("t[Transfer]", "ok", None)]), (True, 0))

    def test_empty_sweep_fails(self):
        self.good()
        self.write_sim("")  # meta bound to the empty file
        res = self.run_compare()
        self.assertProblem(res, "empty sweep")
        self.assertProblem(res, "3 grid points missing in the sweep")
        self.assertEqual(res["n"], 0)
        self.assertEqual(self.run_main(), 1)

    def test_empty_sweep_with_stale_meta_fails(self):
        self.good()
        with open(os.path.join(self.data, "f.jsonl"), "w"):
            pass  # truncated by an interrupted rerun; the old meta remains
        res = self.run_compare()
        self.assertProblem(res, "empty sweep")
        self.assertProblem(res, "sha256 differs")
        self.assertEqual(self.run_main(), 1)

    def test_truncated_sweep_with_stale_meta_fails(self):
        self.good()
        # the mismatching last point is cut off; the old meta remains
        text = read(os.path.join(self.data, "f.jsonl")).splitlines(keepends=True)
        with open(os.path.join(self.data, "f.jsonl"), "w") as f:
            f.write("".join(text[:2]))
        self.write_model({1000: [("ok", 10000), ("oog", 20000)], 1100: [("ok", 10000), ("oog", 20000)],
                          1200: [("ok", 99999), ("oog", 20000)]})
        res = self.run_compare()
        self.assertProblem(res, "sha256 differs")
        self.assertProblem(res, "JSONL has 2 lines")
        self.assertProblem(res, "1 grid points missing in the sweep")
        self.assertEqual(self.run_main(), 1)

    def test_truncated_sweep_with_bound_meta_fails(self):
        self.good()
        text = "".join(sim_line(pp, [("ok", 10000), ("oog", 20000)]) for pp in GRID[:2])
        self.write_sim(text, points=2)  # sha and count of the prefix
        res = self.run_compare()
        self.assertProblem(res, "says 2 points, the grid has 3")
        self.assertProblem(res, "1 grid points missing in the sweep")
        self.assertEqual(self.run_main(), 1)

    def test_duplicate_point_fails(self):
        self.good()
        recs = [("ok", 10000), ("oog", 20000)]
        self.write_sim("".join(sim_line(pp, recs) for pp in [1000, 1100, 1100, 1200]))
        res = self.run_compare()
        self.assertProblem(res, "1 grid points more than once")
        self.assertProblem(res, "JSONL has 4 lines")
        self.assertEqual(self.run_main(), 1)

    def test_point_outside_grid_fails(self):
        self.good()
        recs = [("ok", 10000), ("oog", 20000)]
        self.write_sim("".join(sim_line(pp, recs) for pp in [1000, 1100, 1250]))
        res = self.run_compare()
        self.assertProblem(res, "1 sweep points outside the grid")
        self.assertProblem(res, "1 grid points missing in the sweep")

    def test_line_of_another_flow_fails(self):
        self.good()
        recs = [("ok", 10000), ("oog", 20000)]
        self.write_sim(sim_line(1000, recs) + sim_line(1100, recs) + sim_line(1200, recs, flow="g"))
        self.assertProblem(self.run_compare(), "1 JSONL lines unreadable, of another flow")

    def test_missing_model_point_fails(self):
        self.good()
        self.write_model({pp: [("ok", 10000), ("oog", 20000)] for pp in GRID[:2]})
        res = self.run_compare()
        self.assertEqual(res["missing"], 1)
        self.assertProblem(res, "1 grid points missing in the model")
        self.assertEqual(self.run_main(), 1)
        # --subset compares the points the model has
        self.assertEqual(self.run_compare(subset=True)["problems"], [])
        self.assertEqual(self.run_main("--subset"), 0)

    def test_extra_model_point_fails(self):
        self.good()
        self.write_model({pp: [("ok", 10000), ("oog", 20000)] for pp in GRID + [1300]})
        self.assertProblem(self.run_compare(), "1 model points outside the grid")
        self.assertEqual(self.run_main("--subset"), 1)

    def test_empty_model_fails_even_with_subset(self):
        self.good()
        self.write_model({})
        self.assertProblem(self.run_compare(subset=True), "the model has no grid point")

    def test_missing_receipt_in_model_fails(self):
        self.good()
        self.write_model({pp: [("ok", 10000)] for pp in GRID})
        res = self.run_compare()
        self.assertEqual(res["stat_ok"], 0)
        self.assertEqual(res["gas_ok"], 0)
        self.assertProblem(res, "statuses differ at 3 points")

    def test_meta_checks(self):
        self.good()
        text = read(os.path.join(self.data, "f.jsonl"))
        self.write_sim(text, meta=False)
        os.remove(os.path.join(self.data, "f.meta.json"))
        self.assertProblem(self.run_compare(), "no provenance")
        self.write_sim(text, jsonl_sha256=None)
        self.assertProblem(self.run_compare(), "sha256 differs")
        self.write_sim(text)
        m = json.loads(read(os.path.join(self.data, "f.meta.json")))
        del m["jsonl_sha256"]
        with open(os.path.join(self.data, "f.meta.json"), "w") as f:
            json.dump(m, f)
        self.assertProblem(self.run_compare(), "lacks jsonl_sha256")
        self.write_sim(text, flows_sha256="0" * 64)
        self.assertProblem(self.run_compare(), "another flows/probes.toml")
        # swept on another grid than the flow declares
        self.write_sim(text, grid="smoke")
        self.assertProblem(self.run_compare(), "on grid 'smoke'")

    def test_empty_meta_fails(self):
        # A complete, matching sweep whose meta is `{}`: nothing binds it.
        self.good()
        self.write_sim(read(os.path.join(self.data, "f.jsonl")), meta={})
        self.assertEqual(json.loads(read(os.path.join(self.data, "f.meta.json"))), {})
        res = self.run_compare()
        self.assertProblem(res, ".meta.json lacks flows_sha256, grid, points, jsonl_sha256")
        self.assertEqual(self.run_main(), 1)

    def test_meta_missing_any_field_fails(self):
        self.good()
        text = read(os.path.join(self.data, "f.jsonl"))
        for k in conform.META_FIELDS:
            with self.subTest(field=k):
                self.write_sim(text)
                m = json.loads(read(os.path.join(self.data, "f.meta.json")))
                del m[k]
                self.write_sim(text, meta=m)
                self.assertProblem(self.run_compare(), f".meta.json lacks {k}")
                self.assertEqual(self.run_main(), 1)

    def test_meta_not_an_object_fails(self):
        self.good()
        text = read(os.path.join(self.data, "f.jsonl"))
        for meta in ([], None, "x", 3):
            with self.subTest(meta=meta):
                self.write_sim(text, meta=False)
                with open(os.path.join(self.data, "f.meta.json"), "w") as f:
                    json.dump(meta, f)
                self.assertProblem(self.run_compare(), "not a JSON object")
                self.assertEqual(self.run_main(), 1)

    def test_repeated_reports_differing_in_any_field_fail(self):
        # Two reports of one point, equal in (id, status, gas): the earlier
        # disagrees with the sim, the later agrees. Neither may be dropped.
        recs = [("ok", 10000), ("oog", 20000)]
        for field, other in (("to", dict(to="p")), ("m", dict(m="rest")), ("tx", dict(tx=2))):
            with self.subTest(field=field):
                self.good()
                with open(os.path.join(self.build, "f.log"), "w") as f:
                    f.write(model_report(1000, recs, **other))
                    for pp in GRID:
                        f.write(model_report(pp, recs))
                    f.write(OK_LOG)
                res = self.run_compare()
                self.assertProblem(res, "more than one outcome at 1 points")
                self.assertEqual(self.run_main(), 1)

    def test_repeated_equal_reports_pass(self):
        # The same outcome reported twice (two behaviours reaching it) is fine.
        self.good()
        recs = [("ok", 10000), ("oog", 20000)]
        with open(os.path.join(self.build, "f.log"), "a") as f:
            # the same records, printed in another order
            f.write(model_report(1100, recs).replace(
                '[to |-> "q", m |-> "work", st |-> "ok", tx |-> 1, id |-> 1, g |-> 10000], '
                '[to |-> "q", m |-> "work", st |-> "oog", tx |-> 1, id |-> 2, g |-> 20000]',
                '[to |-> "q", m |-> "work", st |-> "oog", tx |-> 1, id |-> 2, g |-> 20000], '
                '[to |-> "q", m |-> "work", st |-> "ok", tx |-> 1, id |-> 1, g |-> 10000]'))
        self.assertEqual(self.run_compare()["problems"], [])

    def test_parse_reports(self):
        recs = [("ok", 1), ("oog", 2)]
        out, nondet = tlcparse.parse(model_report(5, recs) + model_report(5, recs, to="p") + model_report(6, recs))
        self.assertEqual(sorted(out), [5, 6])
        self.assertEqual(nondet, {5: 2})
        self.assertEqual(out[6][0], dict(to="q", m="work", st="ok", tx=1, id=1, g=1))

    def test_tlc_log_is_read_once(self):
        # The log is rewritten between reads: the first snapshot is a
        # finished run whose report disagrees with the sim, the second an
        # unfinished run that agrees. The comparison must use one snapshot.
        recs = [("ok", 10000), ("oog", 20000)]
        self.good()
        log = os.path.join(self.build, "f.log")
        first = "".join(model_report(pp, [("ok", 99999), ("oog", 20000)]) for pp in GRID) + OK_LOG
        second = "".join(model_report(pp, recs) for pp in GRID) + "Starting... (still running)\n"
        real_open, opens = open, []

        def regenerating_open(path, *a, **k):
            if os.path.abspath(path) == log:
                opens.append(path)
                if len(opens) == 2:
                    with real_open(log, "w") as f:
                        f.write(second)
            return real_open(path, *a, **k)

        for run, want in ((self.run_compare, None), (self.run_main, 1)):
            with open(log, "w") as f:
                f.write(first)
            opens.clear()
            with mock.patch("builtins.open", regenerating_open):
                got = run()
            if want is None:
                self.assertEqual(got["problems"], ["attached gas not paired within 5 Ggas by label and status at 3 points"])
            else:
                self.assertEqual(got, want)
            self.assertEqual(len(opens), 1)

    def test_failed_tlc_run_fails(self):
        self.good()
        with open(os.path.join(self.build, "f.log"), "a") as f:
            f.write("Error: something\n")
        self.assertProblem(self.run_compare(), "TLC did not finish")

    def test_grid_sizes(self):
        # the crate's grid module: standard 1313 points, smoke 52
        self.assertEqual(len(grid_points("standard")), 1313)
        self.assertEqual(len(grid_points("smoke")), 52)
        self.assertEqual(grid_points("1:1.2:0.1"), set(GRID))
        self.assertEqual(min(grid_points("standard")), 500)
        self.assertEqual(max(grid_points("standard")), 300000)


if __name__ == "__main__":
    unittest.main()
