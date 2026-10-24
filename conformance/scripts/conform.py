#!/usr/bin/env python3
"""conform.py [--tol GGAS] [--subset] [flow ...]

Model (TLC logs tla/build/<flow>.log of ProbeConf) vs sim
(data/probes/<flow>.jsonl), per receipt and per prepaid point:
  - status: ok / oog / failed, or not created;
  - attached gas of every function-call receipt (Ggas, sim rounded);
  - edges: the grid points where the status vector changes, over the
    sim's whole grid (a point the model lacks is its own status).
Refund receipts are left out on both sides.

A flow passes only if TLC finished without error, the sim data was swept
from the current flows file, the model has every grid point, every status
vector is equal, the edges are identical and every attached gas is within
--tol (default 5 Ggas). Exits 1 if any flow fails. --subset compares only
the points the model has (for a quick run on a coarser grid; reported as
such, and still exits 1 on any other failure)."""
import collections, hashlib, json, os, sys, tomllib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "scripts"))
from tlcparse import reports  # noqa: E402

TOL = 5
TOKENS = {"ft", "wrap"}
FLOWS = os.path.join(HERE, "flows", "probes.toml")
MISSING = "<no model point>"


def sim_points(flow, names):
    out = {}
    for line in open(os.path.join(HERE, "data", "probes", f"{flow}.jsonl")):
        v = json.loads(line)
        recs = []
        for r in v["receipts"]:
            if r["conversion"] or r["refund"]:
                continue
            to = names.get(r["receiver"], r["receiver"])
            if r["methods"]:
                label = f"{to}::{'+'.join(r['methods'])}"
                g = round(r["attached"] / 1e9)
            else:
                label = f"{to}[{','.join(r['actions'])}]"
                g = None
            recs.append((label, r["status"], g))
        out[v["gas"] // 10**9] = recs
    return out


def model_label(r, batch_methods):
    if r["m"] == "XFER":
        return f'{r["to"]}[Transfer]'
    if r["m"] == "REFUND":
        return None
    if r["m"] == "batch" and batch_methods and r["to"] in TOKENS:
        return f'{r["to"]}::{batch_methods}'
    return f'{r["to"]}::{r["m"]}'


STAT = {"ok": "ok", "oog": "oog", "fail": "failed", "forced": "forced"}


def sig(recs):
    c = collections.Counter((l, s) for l, s, _ in recs)
    return " ".join(f"{l}={s}" + (f"x{n}" if n > 1 else "") for (l, s), n in sorted(c.items()))


def tlc_ok(log):
    t = open(log).read()
    return "Model checking completed. No error has been found" in t and "Error:" not in t


def data_fresh(flow, flows_sha):
    mp = os.path.join(HERE, "data", "probes", f"{flow}.meta.json")
    if not os.path.exists(mp):
        return "no provenance (.meta.json) beside the sweep"
    m = json.load(open(mp))
    if m.get("flows_sha256") != flows_sha:
        return "sweep is from another flows/probes.toml (re-run calibrate)"
    return None


def compare(flow, spec, tol, subset, flows_sha):
    names = spec["world"]["names"]
    fl = next(f for f in spec["flow"] if f["name"] == flow)
    bm = ""
    if fl["tx"]["method"] == "batch":
        bm = "+".join(c["method"] for c in json.loads(fl["tx"]["args"])["calls"])
    log = os.path.join(HERE, "tla", "build", f"{flow}.log")
    res = dict(flow=flow, n=0, stat_ok=0, gas_ok=0, worst=0, receipts=0, mism=[], medges=[], sedges=[], missing=0,
               problems=[])
    if not tlc_ok(log):
        res["problems"].append("TLC did not finish without error")
    stale = data_fresh(flow, flows_sha)
    if stale:
        res["problems"].append(stale)
    sim = sim_points(flow, names)
    model = reports(log)
    pm = ps = None
    for pp in sorted(sim):
        srecs = sim[pp]
        ss = sig(srecs)
        if pp not in model:
            res["missing"] += 1
            if subset:
                continue
            sm = MISSING
            mrecs = []
        else:
            mrecs = []
            for r in model[pp]:
                l = model_label(r, bm)
                if l:
                    mrecs.append((l, STAT[r["st"]], r["g"] if r["m"] != "XFER" else None))
            sm = sig(mrecs)
        res["n"] += 1
        res["receipts"] += len(srecs)
        if sm == ss:
            res["stat_ok"] += 1
        elif len(res["mism"]) < 6:
            res["mism"].append((pp, sm, ss))
        M, S = collections.defaultdict(list), collections.defaultdict(list)
        for l, _, g in mrecs:
            if g is not None:
                M[l].append(g)
        for l, _, g in srecs:
            if g is not None:
                S[l].append(g)
        gd = 0
        for l in set(M) & set(S):
            for a, b in zip(sorted(M[l]), sorted(S[l])):
                gd = max(gd, abs(a - b))
        res["worst"] = max(res["worst"], gd)
        res["gas_ok"] += gd <= tol and sm != MISSING
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
        res["problems"].append(f"attached gas off by more than {tol} Ggas at {res['n'] - res['gas_ok']} points")
    return res


def main():
    args = sys.argv[1:]
    tol, subset = TOL, False
    while args and args[0].startswith("--"):
        if args[0] == "--tol":
            tol, args = int(args[1]), args[2:]
        elif args[0] == "--subset":
            subset, args = True, args[1:]
        else:
            sys.exit(__doc__)
    raw = open(FLOWS, "rb").read()
    flows_sha = hashlib.sha256(raw).hexdigest()
    spec = tomllib.loads(raw.decode())
    flows = args or [f["name"] for f in spec["flow"]]
    rows = []
    for f in flows:
        if not os.path.exists(os.path.join(HERE, "tla", "build", f"{f}.log")):
            rows.append(dict(flow=f, n=0, stat_ok=0, gas_ok=0, worst=0, receipts=0, mism=[], medges=[], sedges=[],
                             missing=0, problems=["no TLC log"]))
            print(f"== {f}: no TLC log")
            continue
        c = compare(f, spec, tol, subset, flows_sha)
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
    bad = [c["flow"] for c in rows if c["problems"]]
    if bad:
        print(f"\nconform: {len(bad)} of {len(rows)} flows FAIL: {' '.join(bad)}", file=sys.stderr)
        sys.exit(1)
    print(f"\nconform: all {len(rows)} flows pass{' (subset of the grid)' if subset else ''}")


if __name__ == "__main__":
    main()
