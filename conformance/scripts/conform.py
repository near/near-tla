#!/usr/bin/env python3
"""conform.py [--tol GGAS] [--subset] [flow ...]

Model (TLC logs tla/build/<flow>.log of ProbeConf) vs sim
(data/probes/<flow>.jsonl), per receipt and per prepaid point:
  - status: ok / oog / failed, or not created;
  - attached gas of every function-call receipt (Ggas, sim rounded),
    compared jointly with the status: see `joint`;
  - the number of yields still parked at the end of the point (the
    sweep's `yields`, the model's Parked), part of the status vector;
  - edges: the grid points where the status vector changes, over the
    sim's whole grid (a point the model lacks is its own status).
Refund receipts are left out on both sides. A receipt's label carries
its transaction (1 for the swept one, then the `after` transactions in
order; the sweep's `tx` + 1), so receipts of different transactions never
pair, in the statuses, the gas or the edges.

A flow passes only if
  - TLC finished without error (the log is read once: completion and
    reports come from the same bytes);
  - the sweep is bound to its provenance: the .meta.json is a JSON object
    with every field of META_FIELDS, it names the current flows file and
    the flow's declared grid, and its point count and sha256 are the
    JSONL's (a missing field fails: `{}` binds nothing);
  - the sweep holds every point of the flow's declared grid exactly once
    (an empty or truncated sweep fails);
  - the model has every grid point and none outside it, and reports one
    outcome per point (two reports of a point that differ in any field,
    parked yields, receiver, method or transaction included, fail);
  - every status vector (parked yields included) is equal, the edges are
    identical, and at every point the receipts pair up by label
    (transaction included) and status with attached gas within --tol
    (default 5 Ggas).
Exits 1 if any flow fails. --subset compares only the grid points the
model has (for a quick run on a coarser grid; reported as such, and still
exits 1 on any other failure)."""
import collections, hashlib, json, math, os, sys, tomllib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "scripts"))
from mkconf import grid_points  # noqa: E402
from tlcparse import parse  # noqa: E402

TOL = 5
TOKENS = {"ft_probe", "wnear_probe"}  # model names of the token accounts
FLOWS = os.path.join(HERE, "flows", "probes.toml")
DATA = os.path.join(HERE, "data", "probes")
BUILD = os.path.join(HERE, "tla", "build")
MISSING = "<no model point>"
# The .meta.json fields conform.py checks; a meta without any of them fails.
META_FIELDS = ("flows_sha256", "grid", "points", "jsonl_sha256")


def label(tx, body):
    """A receipt's label: its transaction (1, 2, ... in the flow) and what
    it is (`receiver::methods` or `receiver[actions]`)."""
    return f"tx{tx}:{body}"


def sim_records(v, names):
    """(label, status, attached Ggas or None) of every non-refund receipt
    of one sweep line. The sweep numbers transactions from 0."""
    recs = []
    for r in v["receipts"]:
        if r["conversion"] or r["refund"]:
            continue
        tx = r["tx"]
        if not isinstance(tx, int) or isinstance(tx, bool) or tx < 0:
            raise ValueError(f"bad tx {tx!r}")
        to = names.get(r["receiver"], r["receiver"])
        if r["methods"]:
            body = f"{to}::{'+'.join(r['methods'])}"
            g = round(r["attached"] / 1e9)
        else:
            body = f"{to}[{','.join(r['actions'])}]"
            g = None
        recs.append((label(tx + 1, body), r["status"], g))
    return recs


def parked_of(v):
    """The sweep line's count of yields still parked (`yields`)."""
    n = v["yields"]
    if not isinstance(n, int) or isinstance(n, bool) or n < 0:
        raise ValueError(f"bad yields {n!r}")
    return n


def load_sweep(flow, gname, data_dir, flows_sha, names):
    """The sweep of `flow` as {prepaid Ggas: (records, parked)}, and what is wrong
    with it: its meta must be bound to it and it must hold the declared
    grid `gname`, every point once."""
    problems = []
    jp = os.path.join(data_dir, f"{flow}.jsonl")
    mp = os.path.join(data_dir, f"{flow}.meta.json")
    with open(jp, "rb") as f:
        raw = f.read()
    want = grid_points(gname)
    m = None
    if not os.path.exists(mp):
        problems.append("no provenance (.meta.json) beside the sweep (re-run calibrate)")
    else:
        try:
            with open(mp) as f:
                m = json.load(f)
        except ValueError as e:
            problems.append(f"unreadable .meta.json ({e})")
        else:
            if not isinstance(m, dict):
                problems.append(f".meta.json is not a JSON object ({type(m).__name__})")
                m = None
    if m is not None:
        # Every field is required and checked: no field, no pass.
        lacks = [k for k in META_FIELDS if k not in m]
        if lacks:
            problems.append(f".meta.json lacks {', '.join(lacks)} (re-run calibrate)")
        if "flows_sha256" in m and m["flows_sha256"] != flows_sha:
            problems.append("sweep is from another flows/probes.toml (re-run calibrate)")
        if "grid" in m and m["grid"] != gname:
            problems.append(f"sweep is on grid {m['grid']!r}, the flow declares {gname!r}")
        if "jsonl_sha256" in m and m["jsonl_sha256"] != hashlib.sha256(raw).hexdigest():
            problems.append("JSONL sha256 differs from its .meta.json (re-run calibrate)")
        if "points" in m and m["points"] != len(want):
            problems.append(f".meta.json says {m['points']!r} points, the grid has {len(want)}")
    out, dup, bad = {}, set(), 0
    lines = raw.splitlines()
    for line in lines:
        try:
            v = json.loads(line)
            gas = v["gas"]
            assert v["flow"] == flow and isinstance(gas, int) and gas % 10**9 == 0
            recs = sim_records(v, names)
            parked = parked_of(v)
        except (ValueError, KeyError, TypeError, AssertionError):
            bad += 1
            continue
        pp = gas // 10**9
        if pp in out:
            dup.add(pp)
        out[pp] = (recs, parked)
    if not lines:
        problems.append("empty sweep")
    if m is not None and "points" in m and m["points"] != len(lines):
        problems.append(f"JSONL has {len(lines)} lines, .meta.json says {m['points']!r}")
    if bad:
        problems.append(f"{bad} JSONL lines unreadable (no tx or yields field: re-run calibrate), "
                        "of another flow or off the Ggas grid")
    if dup:
        problems.append(f"{len(dup)} grid points more than once in the sweep")
    if set(out) - want:
        problems.append(f"{len(set(out) - want)} sweep points outside the grid")
    if want - set(out):
        problems.append(f"{len(want - set(out))} grid points missing in the sweep")
    return out, problems


def model_label(r, batch_methods):
    if r["m"] == "XFER":
        return label(r["tx"], f'{r["to"]}[Transfer]')
    if r["m"] == "REFUND":
        return None
    if r["m"] == "batch" and batch_methods and r["to"] in TOKENS:
        return label(r["tx"], f'{r["to"]}::{batch_methods}')
    return label(r["tx"], f'{r["to"]}::{r["m"]}')


STAT = {"ok": "ok", "oog": "oog", "fail": "failed", "forced": "forced"}


def model_records(recs, batch_methods):
    out = []
    for r in recs:
        l = model_label(r, batch_methods)
        if l:
            out.append((l, STAT[r["st"]], r["g"] if r["m"] != "XFER" else None))
    return out


def sig(recs, parked=0):
    """The status vector: every (label, status) with its multiplicity, and
    the parked yields if any."""
    c = collections.Counter((l, s) for l, s, _ in recs)
    out = " ".join(f"{l}={s}" + (f"x{n}" if n > 1 else "") for (l, s), n in sorted(c.items()))
    return out + (f" parked-yields={parked}" if parked else "")


def joint(mrecs, srecs):
    """Pair model and sim receipts by (label, status), multiplicity kept,
    and return (statuses equal, worst attached-gas difference of the best
    pairing). A point's gas is within tolerance iff the statuses are equal
    and worst <= tol.

    Receipts of different (label, status) never pair, so the pairing splits
    into one per group, and a group pairs only if both sides have as many
    receipts in it (the status check). Within a group, pairing the sorted
    gas values in order minimises the largest difference: for a1 <= a2 and
    b1 <= b2, max(|a1-b1|, |a2-b2|) <= max(|a1-b2|, |a2-b1|), so uncrossing
    two pairs never makes the largest difference worse, and some pairing
    within tolerance exists iff the sorted one is within it. A receipt
    without gas (action-only) pairs only with another without gas. If the
    statuses differ, worst covers the groups of equal size only."""
    M, S = collections.defaultdict(list), collections.defaultdict(list)
    for l, s, g in mrecs:
        M[(l, s)].append(g)
    for l, s, g in srecs:
        S[(l, s)].append(g)
    equal = {k: len(v) for k, v in M.items()} == {k: len(v) for k, v in S.items()}
    worst = 0
    key = lambda g: (g is not None, g or 0)  # noqa: E731
    for k in set(M) & set(S):
        if len(M[k]) != len(S[k]):
            continue
        for a, b in zip(sorted(M[k], key=key), sorted(S[k], key=key)):
            d = 0 if a is None and b is None else math.inf if a is None or b is None else abs(a - b)
            worst = max(worst, d)
    return equal, worst


def tlc_ok(text):
    """Whether a TLC log's text records a run that finished without error."""
    return "Model checking completed. No error has been found" in text and "Error:" not in text


def empty_row(flow, problem):
    return dict(flow=flow, n=0, stat_ok=0, gas_ok=0, worst=0, receipts=0, mism=[], medges=[], sedges=[], missing=0,
                problems=[problem])


def compare(flow, spec, tol, subset, flows_sha, data_dir=DATA, build_dir=BUILD):
    names = spec["world"].get("names", {})
    fl = next(f for f in spec["flow"] if f["name"] == flow)
    gname = fl.get("grid", "standard")
    bm = ""
    if fl["tx"]["method"] == "batch":
        bm = "+".join(c["method"] for c in json.loads(fl["tx"]["args"])["calls"])
    log = os.path.join(build_dir, f"{flow}.log")
    res = dict(flow=flow, n=0, stat_ok=0, gas_ok=0, worst=0, receipts=0, mism=[], medges=[], sedges=[], missing=0,
               problems=[])
    # One read of the log: the completion check and the reports come from
    # the same bytes, so a log rewritten meanwhile can't mix two runs.
    with open(log) as f:
        text = f.read()
    if not tlc_ok(text):
        res["problems"].append("TLC did not finish without error")
    sim, sweep_problems = load_sweep(flow, gname, data_dir, flows_sha, names)
    res["problems"] += sweep_problems
    model, nondet = parse(text)
    if nondet:
        res["problems"].append(f"the model reports more than one outcome at {len(nondet)} points (nondeterministic)")
    grid = grid_points(gname)
    if set(model) - grid:
        res["problems"].append(f"{len(set(model) - grid)} model points outside the grid")
    if not set(model) & grid:
        res["problems"].append("the model has no grid point")
    pm = ps = None
    for pp in sorted(grid & set(sim)):
        srecs, sparked = sim[pp]
        ss = sig(srecs, sparked)
        if pp not in model:
            res["missing"] += 1
            if subset:
                continue
            sm = MISSING
            mrecs = []
        else:
            mrecs = model_records(model[pp][0], bm)
            sm = sig(mrecs, model[pp][1])
        res["n"] += 1
        res["receipts"] += len(srecs)
        equal, gd = joint(mrecs, srecs)
        if equal and sm == ss:
            res["stat_ok"] += 1
        elif len(res["mism"]) < 6:
            res["mism"].append((pp, sm, ss))
        res["worst"] = max(res["worst"], gd)
        res["gas_ok"] += equal and gd <= tol and sm != MISSING
        if sm != pm:
            res["medges"].append((pp, sm))
            pm = sm
        if ss != ps:
            res["sedges"].append((pp, ss))
            ps = ss
    if res["missing"] and not subset:
        res["problems"].append(f"{res['missing']} grid points missing in the model")
    if res["stat_ok"] < res["n"]:
        res["problems"].append(f"statuses differ at {res['n'] - res['stat_ok']} points")
    if [a for a, _ in res["medges"]] != [a for a, _ in res["sedges"]]:
        res["problems"].append("edges differ")
    if res["gas_ok"] < res["n"]:
        res["problems"].append(f"attached gas not paired within {tol} Ggas by label and status at "
                               f"{res['n'] - res['gas_ok']} points")
    return res


def main(argv=None, flows_path=FLOWS, data_dir=DATA, build_dir=BUILD):
    args = list(sys.argv[1:] if argv is None else argv)
    tol, subset = TOL, False
    while args and args[0].startswith("--"):
        if args[0] == "--tol":
            tol, args = int(args[1]), args[2:]
        elif args[0] == "--subset":
            subset, args = True, args[1:]
        else:
            sys.exit(__doc__)
    with open(flows_path, "rb") as f:
        raw = f.read()
    flows_sha = hashlib.sha256(raw).hexdigest()
    spec = tomllib.loads(raw.decode())
    known = [f["name"] for f in spec["flow"]]
    flows = args or known
    rows = []
    for f in flows:
        problem = None
        if f not in known:
            problem = "no such flow in flows/probes.toml"
        elif not os.path.exists(os.path.join(data_dir, f"{f}.jsonl")):
            problem = f"no sim data data/probes/{f}.jsonl (run calibrate first: README.md, Running)"
        elif not os.path.exists(os.path.join(build_dir, f"{f}.log")):
            problem = f"no TLC log tla/build/{f}.log (run scripts/mkconf.py and scripts/tlc.sh first)"
        if problem:
            rows.append(empty_row(f, problem))
            print(f"\n== {f}: FAIL: {problem}")
            continue
        c = compare(f, spec, tol, subset, flows_sha, data_dir, build_dir)
        rows.append(c)
        print(f"\n== {f}: {'PASS' if not c['problems'] else 'FAIL: ' + '; '.join(c['problems'])}")
        print(f"   {c['n']} points compared ({c['missing']} missing in the model{', skipped: --subset' if subset and c['missing'] else ''}), "
              f"{c['receipts']} sim receipts; statuses equal at {c['stat_ok']}; attached gas within {tol} Ggas at "
              f"{c['gas_ok']} (worst {c['worst']})")
        print("   model edges: " + "; ".join(f"{pp/1000:.1f}" for pp, _ in c["medges"]))
        print("   sim   edges: " + "; ".join(f"{pp/1000:.1f}" for pp, _ in c["sedges"]))
        for pp, s in c["sedges"]:
            print(f"     sim   @{pp/1000:6.1f}: {s}")
        if [a for a, _ in c["medges"]] != [a for a, _ in c["sedges"]]:
            for pp, s in c["medges"]:
                print(f"     model @{pp/1000:6.1f}: {s}")
        for pp, a, b in c["mism"]:
            print(f"   MISMATCH @{pp/1000:.1f}\n      model {a}\n      sim   {b}")
    print(f"\n| flow | points | missing | sim receipts | statuses equal | gas within {tol} | gas worst (Ggas) | model edges (Tgas) | sim edges (Tgas) | result |")
    print("|---|---:|---:|---:|---:|---:|---:|---|---|---|")
    for c in rows:
        print(f"| {c['flow']} | {c['n']} | {c['missing']} | {c['receipts']} | {c['stat_ok']} | {c['gas_ok']} | {c['worst']} | "
              f"{', '.join(f'{pp/1000:.1f}' for pp, _ in c['medges'])} | {', '.join(f'{pp/1000:.1f}' for pp, _ in c['sedges'])} | "
              f"{'pass' if not c['problems'] else 'FAIL'} |")
    edge_bad = sum(1 for c in rows if [a for a, _ in c["medges"]] != [a for a, _ in c["sedges"]])
    print(f"\ntotals: {len(rows)} flows, {sum(c['n'] for c in rows)} points, {sum(c['receipts'] for c in rows)} sim receipts; "
          f"status mismatches at {sum(c['n'] - c['stat_ok'] for c in rows)} points; edges differ in {edge_bad} flows; "
          f"gas over {tol} Ggas at {sum(c['n'] - c['gas_ok'] for c in rows)} points; "
          f"{sum(c['missing'] for c in rows)} model points missing")
    bad = [c["flow"] for c in rows if c["problems"]]
    if bad:
        print(f"\nconform: {len(bad)} of {len(rows)} flows FAIL: {' '.join(bad)}", file=sys.stderr)
        return 1
    print(f"\nconform: all {len(rows)} flows pass{' (subset of the grid)' if subset else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
