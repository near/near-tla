#!/usr/bin/env python3
"""mkconf.py [--grid standard|smoke|lo:hi:step] [flow ...]

Writes tla/build/MC_<flow>.tla and .cfg for every flow of
flows/probes.toml (or the named ones): the flow's transaction as a model
receipt for ProbeConf.tla, over the flow's prepaid-gas grid (Ggas), and its
`after` steps (ProbeConf's After: transactions at their own gas, or a block
that times out the parked yield; the clock is one tick, YieldTicks = 1).

A flow's `path` suffixes the burn key of every receipt it applies to
(`path_for`, empty: all), the leaves' too (their payload's gk).

Every burn key the model will look up must be in tla/CalibProbes.tla; a
missing one is an error unless the flow's `model_keys` maps it to another
key (recorded in flows/probes.toml, e.g. for a path the sim never
completes).

The fee table runs with FeeRounding "nearest" (pinned in the cfg), not the
library's default "up": conformance measures accuracy, and "up" overstates
an action-only child's fee by up to 4 Ggas, which moves a creator's edge
onto the next 0.1 Tgas grid point where the margin is that thin (two
storage_deposit refund flows). Those shifts are on the safe side only."""
import json, os, re, sys, tomllib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(HERE, "flows", "probes.toml")
CALIB = os.path.join(HERE, "tla", "CalibProbes.tla")
BUILD = os.path.join(HERE, "tla", "build")
REG = 1250000000000000000000
NEAR = 10**24


def grid(g):
    """TLA+ set expression of the grid, in Ggas."""
    if g == "standard":
        return "{t * 100 : t \\in 5..1300} \\cup {t * 10000 : t \\in 14..30}"
    if g == "smoke":
        return "{t * 2500 : t \\in 2..52} \\cup {300000}"
    lo, hi, st = (round(float(x) * 10) for x in g.split(":"))
    return f"{{t * 100 : t \\in {{{lo} + i * {st} : i \\in 0..{(hi - lo) // st}}}}}"


def grid_points(g):
    """The points of `grid(g)` as a set of Ggas (the same grid as the
    crate's `spec::parse_grid`; conform.py checks sweeps against it)."""
    if g == "standard":
        return {t * 100 for t in range(5, 1301)} | {t * 10000 for t in range(14, 31)}
    if g == "smoke":
        return {t * 2500 for t in range(2, 53)} | {300000}
    lo, hi, st = (round(float(x) * 10) for x in g.split(":"))
    return {(lo + i * st) * 100 for i in range((hi - lo) // st + 1)}


def dep(d):
    """Deposit (yocto) in model units: 1 NEAR = 1000; 1 yocto, the storage
    minimum and other sub-milliNEAR amounts are 1."""
    d = int(d or 0)
    if d == 0:
        return 0
    if d == REG or d < 10**21:
        return 1
    return d // 10**21


def q(s):
    return '"' + s + '"'


class Ctx:
    def __init__(self, spec, keys):
        self.names = spec["world"]["names"]
        self.wkeys = spec["world"].get("keys", {})
        self.keys = keys
        self.errors = []
        self.notes = []

    def n(self, sim_id):
        return self.names.get(sim_id, sim_id)

    def key(self, flow, acct, k):
        """The burn key `acct.k`, which the calibration must have, or the
        flow's explicit `model_keys` substitute for it."""
        full = f"{acct}.{k}"
        sub = flow.get("model_keys", {}).get(full)
        if sub:
            if not sub.startswith(acct + "."):
                self.errors.append(f"{flow['name']}: model_keys {full} -> {sub}: not a key of {acct}")
            elif sub not in self.keys:
                self.errors.append(f"{flow['name']}: model_keys {full} -> {sub}: no such calibrated key")
            self.notes.append(f"{flow['name']}: {full} -> {sub} (model_keys)")
            return sub.split(".", 1)[1]
        if full not in self.keys:
            self.errors.append(f"{flow['name']}: no calibrated burn key {full} (the sim never completed that path?"
                               " recalibrate, or map it in the flow's model_keys)")
        return k

    def path_of(self, flow, ck):
        """The flow's path suffix, if it applies to call key `ck`."""
        p = flow.get("path", "")
        pf = flow.get("path_for", [])
        return f"/{p}" if p and (not pf or ck in pf) else ""


def pa(fields):
    if not fields:
        return "PA(PA0)"
    return "PA([PA0 EXCEPT " + ", ".join(f"!.{k} = {v}" for k, v in fields.items()) + "])"


def leaf_args(m, args, gk=""):
    a = json.loads(args) if args else {}
    f = {"gk": q(gk)} if gk else {}
    if m == "burn":
        f["n"] = a["ggas"]
    elif m == "ret":
        f["n"] = a["bytes"] // 1000
    return pa(f)


def kid(ctx, c, here, flow=None):
    rx = c.get("receiver", here)
    to, m = ctx.n(rx), c["method"]
    gk = ""
    if flow is not None:
        # (not checked here: a kid of a creator that always fails never
        # runs; TLC asserts every key a run looks up)
        path = ctx.path_of(flow, f"{rx}.{m}")
        gk = m + path if path else ""
    return f'KidRec({q(to)}, {q(m)}, {leaf_args(m, c.get("args", ""), gk)}, {c.get("static_ggas", 0)}, {c.get("weight", 0)}, {dep(c.get("deposit", "0"))})'


# The async probe's keys the model picks by what happens (ProbeConf).
YKEYS = {"resume": ["resume/ok", "resume/none"], "on_yield": ["on_yield/payload", "on_yield/timeout"]}


def after(ctx, flow):
    """ProbeConf's After: the flow's `after` steps as records."""
    steps = []
    for st in flow.get("after", []):
        if st.get("expire"):
            steps.append('[k |-> "expire", to |-> "", m |-> "", a |-> PA(PA0), fr |-> "", g |-> 0]')
            continue
        c = st["call"]
        to, m = ctx.n(c["receiver"]), c["method"]
        a = json.loads(c["args"]) if c.get("args") else {}
        if m != "resume":
            raise SystemExit(f"{flow['name']}: no model for an after step {to}.{m}")
        if a["bytes"] > 1024:
            raise SystemExit(f"{flow['name']}: a payload over 1024 bytes fails the resumer in nearcore; the model does not check it")
        for k in YKEYS[m]:
            ctx.key(flow, to, k)
        g = round(float(c.get("tgas", 300)) * 1000)
        steps.append(f'[k |-> "tx", to |-> {q(to)}, m |-> {q(m)}, a |-> {pa({"n": a["bytes"]})}, '
                     f'fr |-> {q(ctx.n(c["signer"]))}, g |-> {g}]')
    return "<<" + ", ".join(steps) + ">>"


def first(ctx, flow):
    tx = flow["tx"]
    rx, m = tx["receiver"], tx["method"]
    a = json.loads(tx["args"]) if tx.get("args") else {}
    here = ctx.n(rx)
    if m == "chain":
        kids = a["kids"]
        cb = a.get("cb")
        ms = [k["method"] for k in kids] + ([cb["method"]] if cb else [])
        ck = flow.get("keys", {}).get("chain") or "chain/" + ",".join(sorted(ms))
        f = {"kids": "<<" + ", ".join(kid(ctx, k, rx, flow) for k in kids) + ">>",
             "gk": q(ctx.key(flow, here, ck + ctx.path_of(flow, f"{rx}.chain")))}
        if cb:
            f["cb"] = "<<" + kid(ctx, cb, rx, flow) + ">>"
        if a.get("detach"):
            f["det"] = "TRUE"
        args = pa(f)
    elif m == "yield_create":
        yk = flow.get("keys", {}).get(m) or m
        f = {"st": a["cb_ggas"], "wt": a["cb_weight"], "rb": a.get("resume", -1),
             "gk": q(ctx.key(flow, here, yk + ctx.path_of(flow, f"{rx}.{m}")))}
        if a.get("resume") is not None and a["resume"] > 1024:
            raise SystemExit(f"{flow['name']}: a payload over 1024 bytes fails the resumer in nearcore; the model does not check it")
        for k in YKEYS["on_yield"]:
            ctx.key(flow, here, k)
        args = pa(f)
    elif m == "send":
        f = {"to": q(ctx.n(a["to"])), "amt": dep(a["yocto"])}
        shape = "[Transfer]"
        if a.get("cb"):
            f["cb"] = "<<" + kid(ctx, {"method": "on_read", "static_ggas": a.get("cb_ggas", 0), "weight": 1}, rx) + ">>"
            shape += ",on_read"
        f["gk"] = q(ctx.key(flow, here, "send/" + shape + ctx.path_of(flow, f"{rx}.send")))
        args = pa(f)
    elif m == "batch":
        calls = a["calls"]
        ms = "+".join(c["method"] for c in calls)
        tk = flow.get("keys", {}).get(ms) or ctx.wkeys.get(ms, ms)
        nd = sd = 0
        sd_acct, xf, rc, amt, msg = "", "", "", 0, ""
        for c in calls:
            ca = json.loads(c["args"]) if c.get("args") else {}
            if c["method"] == "near_deposit":
                nd = dep(c.get("deposit"))
            elif c["method"] == "storage_deposit":
                sd, sd_acct = dep(c.get("deposit")), ctx.n(ca.get("account_id", ""))
            elif c["method"] in ("ft_transfer", "ft_transfer_call"):
                xf, rc, amt, msg = c["method"], ctx.n(ca["receiver_id"]), 1, ca.get("msg", "")
        kids = "<<" + ", ".join(kid(ctx, c, a["receiver"]) for c in calls) + ">>"
        f = {"to": q(ctx.n(a["receiver"])), "kids": kids,
             "fee": f'ProbeGasCall[{q(ctx.n(a["receiver"]) + "." + tk)}].fee',
             "bargs": f"BatchArgs({nd}, {sd}, {q(sd_acct)}, {q(xf)}, {q(rc)}, {amt}, {q(msg)})",
             "gk": q(ctx.key(flow, here, "batch/" + ms))}
        args = pa(f)
    elif m in ("ft_transfer", "ft_transfer_call"):
        amt = 1 if here == "wnear_probe" else int(a["amount"])
        args = f'FtArgs({q(ctx.n(a["receiver_id"]))}, {amt}, {q(a.get("msg", "").replace(":", ""))})'
    elif m in ("storage_deposit", "storage_balance_of", "ft_balance_of"):
        args = f'SdArgs({q(ctx.n(a.get("account_id", "")))})'
    elif m == "near_withdraw":
        args = f'NwArgs({dep(a["amount"])})'
    elif m in ("near_deposit", "ft_total_supply"):
        args = "TA0"
    else:
        raise SystemExit(f"{flow['name']}: no model for {rx}.{m}")
    signer = ctx.n(tx["signer"])
    return signer, f'Rcpt(1, 1, {q(here)}, {q(signer)}, {q(m)}, {args}, {dep(tx.get("deposit"))}, {q(signer)}, 0)'


CFG = """INIT Init
NEXT Next
CONSTANTS
  Accounts <- Accts
  StakingAcct <- mc_staking
  MinStake = 1
  StorageFloor <- ConfFloor
  MayFail <- mc_empty
  MaxFails = 0
  MaxEpoch = 0
  MaxReward = 0
  Exists <- ConfExists
  GasMode <- mc_gas
  GasCall <- ProbeGasCall
  GasBurn <- ProbeGasBurn
  LogOn = TRUE
  TokYocto = 1
  TokenAccts <- mc_tokens
  TokHolders <- ConfHolders
  TokStorageMin <- ConfStorageMin
  TokDev <- ConfDev
  TokCallReserve <- ConfReserve
  WNearAccts <- mc_wnear
  AcctKind <- ConfKinds
  Contracts <- ConfContracts
  FirstRcpt <- mc_first
  Signer0 <- mc_signer
  Grid <- mc_grid
  After <- mc_after
  MaxBlk <- mc_maxblk
  YieldTicks <- mc_one
  FeeRounding <- [NearFees] mc_fee_rounding
INVARIANTS
  Report
  NotStuck
  TypeOK
"""


def main():
    args = sys.argv[1:]
    g_override = None
    if args[:1] == ["--grid"]:
        g_override, args = args[1], args[2:]
    spec = tomllib.load(open(SPEC, "rb"))
    keys = set(re.findall(r'^\s+"([^"]+)" :> \[base', open(CALIB).read(), re.M))
    ctx = Ctx(spec, keys)
    os.makedirs(BUILD, exist_ok=True)
    for flow in spec["flow"]:
        if args and flow["name"] not in args:
            continue
        name = flow["name"]
        signer, rc = first(ctx, flow)
        mod = f"MC_{name}"
        with open(os.path.join(BUILD, mod + ".tla"), "w") as f:
            f.write(f"---- MODULE {mod} ----\n\\* generated by scripts/mkconf.py from flows/probes.toml: {flow.get('about', '')}\n")
            f.write("EXTENDS ProbeConf, CalibProbes\n")
            f.write('mc_staking == "p"\nmc_empty == {}\nmc_gas == "gas"\nmc_tokens == Toks\nmc_wnear == {"wnear_probe"}\n')
            f.write(f"mc_signer == {q(signer)}\n")
            f.write(f"mc_grid == {grid(g_override or flow.get('grid', 'standard'))}\n")
            f.write(f"mc_first == {rc}\n")
            f.write(f"mc_after == {after(ctx, flow)}\n")
            f.write("mc_one == 1\nmc_maxblk == 1 + Len(mc_after)\n")
            f.write('mc_fee_rounding == "nearest"\n====\n')
        with open(os.path.join(BUILD, mod + ".cfg"), "w") as f:
            f.write(CFG)
        print(mod)
    for n in ctx.notes:
        print("note:", n, file=sys.stderr)
    if ctx.errors:
        for e in ctx.errors:
            print("error:", e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
