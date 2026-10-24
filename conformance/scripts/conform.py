#!/usr/bin/env python3
"""conform.py [--tol GGAS] [flow ...]

Model (TLC logs tla/build/<flow>.log of ProbeConf) vs sim
(data/probes/<flow>.jsonl), per receipt and per prepaid point:
  - status: ok / oog / failed, or not created;
  - attached gas of every function-call receipt (Ggas, sim rounded);
  - edges: the grid points where the status vector changes.
Refund receipts are left out on both sides."""
import collections, json, os, re, sys, tomllib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "scripts"))
from tlcparse import reports  # noqa: E402

TOL = 5
TOKENS = {"ft", "wrap"}


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


def compare(flow, spec, tol):
    names = spec["world"]["names"]
    fl = next(f for f in spec["flow"] if f["name"] == flow)
    bm = ""
    if fl["tx"]["method"] == "batch":
        bm = "+".join(c["method"] for c in json.loads(fl["tx"]["args"])["calls"])
    sim = sim_points(flow, names)
    model = reports(os.path.join(HERE, "tla", "build", f"{flow}.log"))
    res = dict(flow=flow, n=0, stat_ok=0, gas_ok=0, worst=0, receipts=0, mism=[], medges=[], sedges=[], missing=0)
    pm = ps = None
    for pp in sorted(sim):
        if pp not in model:
            res["missing"] += 1
            continue
        res["n"] += 1
        mrecs = []
        for r in model[pp]:
            l = model_label(r, bm)
            if l:
                mrecs.append((l, STAT[r["st"]], r["g"] if r["m"] not in ("XFER",) else None))
        srecs = sim[pp]
        res["receipts"] += len(srecs)
        sm, ss = sig(mrecs), sig(srecs)
        if sm == ss:
            res["stat_ok"] += 1
        elif len(res["mism"]) < 6:
            res["mism"].append((pp, sm, ss))
        gd = 0
        M = collections.defaultdict(list)
        S = collections.defaultdict(list)
        for l, s, g in mrecs:
            if g is not None:
                M[l].append(g)
        for l, s, g in srecs:
            if g is not None:
                S[l].append(g)
        for l in set(M) & set(S):
            for a, b in zip(sorted(M[l]), sorted(S[l])):
                gd = max(gd, abs(a - b))
        res["worst"] = max(res["worst"], gd)
        res["gas_ok"] += gd <= tol
        if sm != pm:
            res["medges"].append((pp, sm))
            pm = sm
        if ss != ps:
            res["sedges"].append((pp, ss))
            ps = ss
    return res


def main():
    args = sys.argv[1:]
    tol = TOL
    if args[:1] == ["--tol"]:
        tol, args = int(args[1]), args[2:]
    spec = tomllib.load(open(os.path.join(HERE, "flows", "probes.toml"), "rb"))
    flows = args or [f["name"] for f in spec["flow"]]
    rows = []
    for f in flows:
        if not os.path.exists(os.path.join(HERE, "tla", "build", f"{f}.log")):
            print(f"== {f}: no TLC log")
            continue
        c = compare(f, spec, tol)
        rows.append(c)
        same = [round(a / 1000, 1) for a, _ in c["medges"]] == [round(a / 1000, 1) for a, _ in c["sedges"]]
        print(f"\n== {f}: {c['n']} points ({c['missing']} missing in the model), {c['receipts']} sim receipts; "
              f"statuses equal at {c['stat_ok']}; attached gas within {tol} Ggas at {c['gas_ok']} (worst {c['worst']}); "
              f"edges {'identical' if same else 'DIFFER'}")
        print("   model edges: " + "; ".join(f"{pp/1000:.1f}" for pp, _ in c["medges"]))
        print("   sim   edges: " + "; ".join(f"{pp/1000:.1f}" for pp, _ in c["sedges"]))
        for pp, s in c["sedges"]:
            print(f"     sim   @{pp/1000:6.1f}: {s}")
        if not same:
            for pp, s in c["medges"]:
                print(f"     model @{pp/1000:6.1f}: {s}")
        for pp, a, b in c["mism"]:
            print(f"   MISMATCH @{pp/1000:.1f}\n      model {a}\n      sim   {b}")
    print("\n| flow | points | sim receipts | statuses equal | attached gas worst (Ggas) | model edges (Tgas) | sim edges (Tgas) |")
    print("|---|---:|---:|---:|---:|---|---|")
    for c in rows:
        print(f"| {c['flow']} | {c['n']} | {c['receipts']} | {c['stat_ok']} | {c['worst']} | "
              f"{', '.join(f'{pp/1000:.1f}' for pp, _ in c['medges'])} | {', '.join(f'{pp/1000:.1f}' for pp, _ in c['sedges'])} |")


if __name__ == "__main__":
    main()
