//! Calibration from sweeps: the leftover-split check (nearcore's
//! `distribute_gas`, recomputed from each parent's measured use and the
//! declared statics and weights), the per-(method, path) burn table and
//! the TLA+ `GasCall` / `GasBurn` tables.
use crate::spec::{Flow, Resolved};
use crate::{GGAS, Provenance};
use near_contract_sim::Sim;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write;

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}
fn u(v: &Value) -> u64 {
    v.as_u64().unwrap_or(0)
}
fn methods(r: &Value) -> Vec<String> {
    r["methods"].as_array().unwrap().iter().map(|m| s(m).to_owned()).collect()
}
fn actions(r: &Value) -> Vec<String> {
    r["actions"].as_array().unwrap().iter().map(|m| s(m).to_owned()).collect()
}
fn is_refund(r: &Value) -> bool {
    !r["refund"].is_null()
}

/// `"<receiver>.<m1>+<m2>"` of a function-call receipt.
pub fn call_key(r: &Value) -> String {
    format!("{}.{}", s(&r["receiver"]), methods(r).join("+"))
}

/// nearcore's `ReceiptManager::distribute_gas`: weight > 0 actions in
/// creation order get floor(U * w / W), the last one the remainder; W = 0
/// distributes nothing.
pub fn split(u_left: u64, ws: &[u64]) -> Vec<u64> {
    let w_sum: u64 = ws.iter().sum();
    if w_sum == 0 || u_left == 0 {
        return vec![0; ws.len()];
    }
    let last = ws.iter().rposition(|w| *w > 0).unwrap();
    let mut out = vec![0; ws.len()];
    let mut dist = 0u64;
    for (i, w) in ws.iter().enumerate() {
        if *w == 0 {
            continue;
        }
        let a = if i == last { u_left - dist } else { ((u_left as u128 * *w as u128) / w_sum as u128) as u64 };
        dist += a;
        out[i] = a;
    }
    out
}

/// Send and exec fee (gas) of an action-only receipt created by
/// `parent_rx`: receipt creation plus each action's fees. Transfer (by the
/// receiver's account kind), CreateAccount, DeleteAccount, DeleteKey and
/// Stake come from the fee table. AddKey and the deploy actions depend on
/// arguments the outcome does not record (the key's permission and method
/// names, the code size): one such action per receipt is solved from the
/// exec fee the child was measured to prepay (full-access key, or base +
/// per-byte * n with n whole), and its send fee priced from the same
/// parameters (`derived` names what was solved). Anything else is an error.
pub fn action_only_fees(sim: &Sim, parent_rx: &str, r: &Value) -> Result<AoFees, String> {
    use near_contract_sim::nearcore::near_parameters::ActionCosts;
    let rx = s(&r["receiver"]);
    let sir = parent_rx == rx;
    let label = format!("{rx}[{}]", actions(r).join(","));
    let (rs, re) = crate::receipt_fees(sim, sir);
    let (mut send, mut exec) = (rs, re);
    let fees = &sim.config.runtime_config().fees;
    let tab = |c: ActionCosts| (fees.fee(c).send_fee(sir).gas.as_gas(), fees.fee(c).exec_fee().gas.as_gas());
    let mut open: Option<String> = None;
    for a in actions(r) {
        let (sf, ef) = match a.as_str() {
            "Transfer" => crate::transfer_fees(sim, sir, rx),
            "Stake" => tab(ActionCosts::stake),
            "DeleteKey" => tab(ActionCosts::delete_key),
            "CreateAccount" => tab(ActionCosts::create_account),
            "DeleteAccount" => tab(ActionCosts::delete_account),
            "AddKey" | "DeployContract" | "DeployGlobalContract" | "UseGlobalContract" => {
                if open.is_some() {
                    return Err(format!("action-only child {label}: two argument-dependent actions; their fees cannot be told apart"));
                }
                open = Some(a.clone());
                (0, 0)
            }
            other => return Err(format!("action-only child {label}: no fee rule for a {other} action")),
        };
        send += sf;
        exec += ef;
    }
    let mut derived = String::new();
    if let Some(a) = open {
        let measured = u(&r["exec_fees"]);
        let rem = measured.checked_sub(exec).ok_or_else(|| format!("action-only child {label}: measured exec fee {measured} below the table's {exec}"))?;
        // (name, send, exec) of each reading of `rem` that fits.
        let mut fits: Vec<(String, u64, u64)> = vec![];
        let per_byte = |name: &str, base: ActionCosts, byte: ActionCosts, fits: &mut Vec<(String, u64, u64)>| {
            let ((bs, be), (ys, ye)) = (tab(base), tab(byte));
            if rem >= be && ye > 0 && (rem - be) % ye == 0 {
                let n = (rem - be) / ye;
                fits.push((format!("{name}, {n} bytes"), bs + ys * n, rem));
            }
        };
        match a.as_str() {
            "AddKey" => {
                let (fs, fe) = tab(ActionCosts::add_full_access_key);
                if rem == fe {
                    fits.push(("full-access key".into(), fs, fe));
                }
                per_byte("function-call key", ActionCosts::add_function_call_key_base, ActionCosts::add_function_call_key_byte, &mut fits);
            }
            "DeployContract" => per_byte("code", ActionCosts::deploy_contract_base, ActionCosts::deploy_contract_byte, &mut fits),
            "DeployGlobalContract" => per_byte("code", ActionCosts::deploy_global_contract_base, ActionCosts::deploy_global_contract_byte, &mut fits),
            _ => per_byte("identifier", ActionCosts::use_global_contract_base, ActionCosts::use_global_contract_byte, &mut fits),
        }
        if fits.len() != 1 {
            return Err(format!("action-only child {label}: the measured exec fee leaves {rem} gas for {a}, which fits {} readings of the fee table", fits.len()));
        }
        let (what, sf, ef) = fits.pop().unwrap();
        send += sf;
        exec += ef;
        derived = format!("{a}: {what}");
    }
    Ok(AoFees { send, exec, derived })
}

pub struct AoFees {
    pub send: u64,
    pub exec: u64,
    /// What was solved from the measured exec fee (empty: all from the
    /// fee table, so the exec fee is a check).
    pub derived: String,
}

#[derive(Default, Debug)]
pub struct SplitReport {
    /// Function-call children whose attached gas was predicted.
    pub children: usize,
    pub mismatches: usize,
    pub worst: u64,
    /// Of those, children of multi-call receipts (checked per action).
    pub multi_children: usize,
    /// Parents skipped (a child without a declared static), and children
    /// that could not be checked: both block a table.
    pub skipped_parents: usize,
    pub unchecked: usize,
    /// Multi-call receipts: (flow, receipt key, burn of the last action,
    /// burn of the earlier actions), Ggas, at the top of the grid.
    pub per_action: Vec<(String, String, f64, f64)>,
    /// Problems that block a table.
    pub errors: Vec<String>,
    /// Mismatch details (first few).
    pub notes: Vec<String>,
}

fn push_once(v: &mut Vec<String>, n: String) {
    if !v.contains(&n) {
        v.push(n);
    }
}

/// One multi-call receipt at one grid point, for the per-action check.
struct MultiPt {
    gas: u64,
    /// Gas of its last function-call action, as its creator split it.
    last: Option<u64>,
    /// Exec fees of its function-call children plus their statics.
    costs: u64,
    /// (child id, static, weight) per created function-call action.
    acts: Vec<(String, u64, u64)>,
    /// Child id -> (call key, attached).
    kids: Vec<(String, String, u64)>,
    used: u64,
}

/// Recomputes every function-call child's attached gas (nearcore's
/// `distribute_gas`) at every point of `lines`, from the declared statics
/// and weights:
/// - a single-call parent's leftover is its attached gas minus its
///   measured use (`burnt - exec_fees`), its children's exec fees and
///   statics;
/// - a multi-call parent splits per action: the children (all assumed to
///   come from its last action) share that action's gas minus its burn,
///   their exec fees and statics. The last action's burn is not in the
///   outcome, so it is inferred at the top of the grid and the prediction
///   checked at every other point.
pub fn check_split(res: &Resolved, flow: &Flow, lines: &[Value], rep: &mut SplitReport) {
    let mut multi: BTreeMap<String, Vec<MultiPt>> = BTreeMap::new();
    for v in lines {
        let rs: Vec<&Value> = v["receipts"].as_array().unwrap().iter().filter(|r| !r["conversion"].as_bool().unwrap()).collect();
        // Predicted per-action gas of receipts seen as children.
        let mut peract: HashMap<String, Vec<u64>> = HashMap::new();
        for p in &rs {
            if is_refund(p) || s(&p["status"]) != "ok" || methods(p).is_empty() {
                continue;
            }
            let kids: Vec<&&Value> = rs.iter().filter(|c| c["parent"] == p["id"] && !is_refund(c)).collect();
            let fkids: Vec<&&Value> = kids.iter().copied().filter(|c| !methods(c).is_empty()).collect();
            if fkids.is_empty() {
                continue;
            }
            let pid = s(&p["id"]).to_owned();
            let pa = u(&p["attached"]);
            let p_last = peract.get(&pid).and_then(|x| x.last().copied());
            let pkey = call_key(p);
            let mut acts: Vec<(String, u64, u64)> = vec![];
            let mut ok = true;
            for c in &fkids {
                let ck = call_key(c);
                match res.static_of(flow, &pkey, &ck) {
                    Some(st) => {
                        if let Some(x) = st.prepaid_minus_ggas {
                            acts.push((s(&c["id"]).to_owned(), p_last.unwrap_or(pa).saturating_sub(x * GGAS), st.weight));
                        } else {
                            if st.actions.len() != methods(c).len() {
                                push_once(&mut rep.errors, format!("{}: static of {ck} declares {} actions, the receipt has {}", flow.name, st.actions.len(), methods(c).len()));
                                ok = false;
                            }
                            for a in &st.actions {
                                acts.push((s(&c["id"]).to_owned(), a[0] * GGAS, a[1]));
                            }
                        }
                    }
                    None => {
                        push_once(&mut rep.errors, format!("{}: no static declared for {ck} (created by {pkey})", flow.name));
                        ok = false;
                    }
                }
            }
            if !ok {
                rep.skipped_parents += 1;
                rep.unchecked += fkids.len();
                continue;
            }
            let used = u(&p["burnt"]) - u(&p["exec_fees"]);
            let kid_exec: u64 = kids.iter().map(|c| u(&c["exec_fees"])).sum();
            let statics: u64 = acts.iter().map(|a| a.1).sum();
            if methods(p).len() > 1 {
                let fexec: u64 = fkids.iter().map(|c| u(&c["exec_fees"])).sum();
                let shape = fkids.iter().map(|c| call_key(c)).collect::<Vec<_>>().join(",");
                multi.entry(format!("{pkey} -> {shape}")).or_default().push(MultiPt {
                    gas: u(&v["gas"]),
                    last: p_last,
                    costs: fexec + statics,
                    acts: acts.clone(),
                    kids: fkids.iter().map(|c| (s(&c["id"]).to_owned(), call_key(c), u(&c["attached"]))).collect(),
                    used,
                });
                // per-action gas of the children, for their own children
                let sh = split(p_last.unwrap_or(0).saturating_sub(fexec + statics), &acts.iter().map(|a| a.2).collect::<Vec<_>>());
                for ((cid, st, _), a) in acts.iter().zip(&sh) {
                    peract.entry(cid.clone()).or_default().push(st + a);
                }
                continue;
            }
            let left = pa.saturating_sub(used + kid_exec + statics);
            let sh = split(left, &acts.iter().map(|a| a.2).collect::<Vec<_>>());
            let mut pred: HashMap<&str, u64> = HashMap::new();
            for ((cid, st, _), a) in acts.iter().zip(&sh) {
                *pred.entry(cid.as_str()).or_default() += st + a;
                peract.entry(cid.clone()).or_default().push(st + a);
            }
            for c in &fkids {
                let want = *pred.get(s(&c["id"])).unwrap_or(&0);
                record(rep, flow, u(&v["gas"]), &pkey, &call_key(c), u(&c["attached"]), want, false);
            }
        }
    }
    for (key, pts) in multi {
        let Some(top) = pts.iter().filter(|p| p.last.is_some()).max_by_key(|p| p.gas) else {
            rep.unchecked += pts.iter().map(|p| p.kids.len()).sum::<usize>();
            push_once(&mut rep.errors, format!("{}: {key}: the multi-call receipt's per-action gas is unknown (not created by a checked parent)", flow.name));
            continue;
        };
        let w_sum: u64 = top.acts.iter().map(|a| a.2).sum();
        // U at the top: what the weighted children got beyond their statics.
        let u_top: u64 = top.kids.iter().map(|k| k.2).sum::<u64>().saturating_sub(top.acts.iter().map(|a| a.1).sum::<u64>());
        let burn_last = if w_sum == 0 { 0 } else { top.last.unwrap().saturating_sub(top.costs + u_top) };
        if w_sum > 0 {
            rep.per_action.push((flow.name.clone(), key.clone(), burn_last as f64 / GGAS as f64, top.used.saturating_sub(burn_last) as f64 / GGAS as f64));
        }
        for p in &pts {
            let Some(last) = p.last else {
                rep.unchecked += p.kids.len();
                continue;
            };
            let left = if w_sum == 0 { 0 } else { last.saturating_sub(p.costs + burn_last) };
            let sh = split(left, &p.acts.iter().map(|a| a.2).collect::<Vec<_>>());
            let mut pred: HashMap<&str, u64> = HashMap::new();
            for ((cid, st, _), a) in p.acts.iter().zip(&sh) {
                *pred.entry(cid.as_str()).or_default() += st + a;
            }
            let pkey = key.split(" -> ").next().unwrap();
            for (cid, ck, att) in &p.kids {
                if p.gas == top.gas && w_sum > 0 {
                    continue; // the inference point
                }
                record(rep, flow, p.gas, pkey, ck, *att, *pred.get(cid.as_str()).unwrap_or(&0), true);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn record(rep: &mut SplitReport, flow: &Flow, gas: u64, pkey: &str, ck: &str, got: u64, want: u64, multi: bool) {
    let d = got.abs_diff(want);
    rep.children += 1;
    if multi {
        rep.multi_children += 1;
    }
    rep.worst = rep.worst.max(d);
    if d != 0 {
        rep.mismatches += 1;
        if rep.mismatches <= 8 {
            rep.notes.push(format!(
                "split mismatch {} at {:.1} Tgas: {pkey} -> {ck}: sim {got} predicted {want} (diff {d}){}",
                flow.name,
                gas as f64 / 1e12,
                if multi { " [per action]" } else { "" }
            ));
        }
    }
}

/// One burn observation.
#[derive(Debug, Clone)]
pub struct Obs {
    pub flow: String,
    pub path: String,
    pub size: u64,
    pub burn: u64,
    /// A failed receipt's burn up to its failure.
    pub failure: bool,
}

#[derive(Default, Debug)]
pub struct Burns {
    /// (model account, method key, shape) -> observations at each flow's
    /// calibration point.
    pub obs: BTreeMap<(String, String, String), Vec<Obs>>,
    /// Same, min-max over all ok points.
    pub spread: BTreeMap<(String, String, String), (u64, u64)>,
    /// Child call key -> exec fees seen.
    pub fees: BTreeMap<String, BTreeSet<u64>>,
    /// Action-only exec fee checks: (receiver, measured, fee table).
    pub ao_checks: Vec<(String, String, u64, u64)>,
    pub notes: Vec<String>,
    /// Problems that block a table.
    pub errors: Vec<String>,
    /// Burns of failed (not out-of-gas) receipts at the top of a grid.
    pub fail_obs: BTreeMap<(String, String, String), Vec<Obs>>,
    /// Keys whose receipt never succeeded.
    pub never_ok: BTreeSet<String>,
    /// (model account, method key, path) -> (largest burn over all ok
    /// points, flows): for the path keys of merged accounts.
    pub path_max: BTreeMap<(String, String, String), (u64, BTreeSet<String>, usize)>,
}

/// The children of a receipt, as a shape string: function calls by method
/// (`+` within a batch), action-only receipts as `[Action,..]`.
fn shape(rs: &[&Value], p: &Value) -> String {
    let mut k: Vec<String> = rs
        .iter()
        .filter(|c| c["parent"] == p["id"] && !is_refund(c))
        .map(|c| if methods(c).is_empty() { format!("[{}]", actions(c).join(",")) } else { methods(c).join("+") })
        .collect();
    k.sort();
    k.join(",")
}

/// The burn size of receipt `p` in `flow` (see `spec::SizeSrc`).
fn size_of(res: &Resolved, flow: &Flow, p: &Value) -> Result<u64, String> {
    let ck = call_key(p);
    let Some(src) = res.spec.sizes.iter().find(|z| z.key == ck) else { return Ok(flow.size) };
    let raw = if let Some(field) = src.from.strip_prefix("arg:") {
        let a: Value = serde_json::from_str(s(&p["args"])).map_err(|e| format!("{ck}: args not JSON: {e}"))?;
        let x = &a[field];
        x.as_u64().or_else(|| x.as_str().and_then(|t| t.parse().ok())).ok_or(format!("{ck}: no numeric arg {field}"))?
    } else if let Some(field) = src.from.strip_prefix("arg_count:") {
        let a: Value = serde_json::from_str(s(&p["args"])).map_err(|e| format!("{ck}: args not JSON: {e}"))?;
        a[field].as_array().ok_or(format!("{ck}: no array arg {field}"))?.len() as u64
    } else if src.from == "result" {
        s(&p["result"]).trim_matches('"').parse().map_err(|_| format!("{ck}: result not numeric"))?
    } else if src.from == "result_size" {
        u(&p["result_size"])
    } else {
        return Err(format!("{ck}: unknown size source {}", src.from));
    };
    Ok(raw / src.div.max(1))
}

/// The model account, method key and path of function-call receipt `p` in
/// `flow`: the method key is the spec's or the flow's name for the method
/// list (`keys`), else the list; the path is the flow's (`path`, for the
/// calls in `path_for`), else a `[[path_rule]]`'s, else empty.
fn key_parts(res: &Resolved, flow: &Flow, p: &Value) -> (String, String, String) {
    let acct = res.name(s(&p["receiver"])).to_owned();
    let raw = methods(p).join("+");
    let mkey = flow.keys.get(&raw).or_else(|| res.spec.world.keys.get(&raw)).cloned().unwrap_or_else(|| raw.clone());
    let ck = call_key(p);
    let path = if !flow.path.is_empty() && (flow.path_for.is_empty() || flow.path_for.contains(&ck)) {
        flow.path.clone()
    } else if mkey == raw {
        // (not for a receipt the spec renames, e.g. a one-call token batch)
        let logs: Vec<&str> = p["logs"].as_array().map(|a| a.iter().map(s).collect()).unwrap_or_default();
        res.spec.path_rules.iter().find_map(|r| r.path_of(&ck, logs.iter().copied())).unwrap_or("").to_owned()
    } else {
        String::new()
    };
    (acct, mkey, path)
}

/// Burn of every ok function-call receipt: `burnt - exec_fees - send fees
/// of its action-only children` (the creator pays those children's send fees
/// out of its gas: docs/SEMANTICS.md, "Who pays action send and exec
/// fees"). The flow's calibration point is its largest grid gas.
pub fn collect_burns(sim: &Sim, res: &Resolved, flow: &Flow, lines: &[Value], b: &mut Burns) {
    let top = lines.iter().map(|v| u(&v["gas"])).max().unwrap_or(0);
    for v in lines {
        let rs: Vec<&Value> = v["receipts"].as_array().unwrap().iter().filter(|r| !r["conversion"].as_bool().unwrap()).collect();
        for p in &rs {
            if is_refund(p) || methods(p).is_empty() {
                continue;
            }
            let (acct, mkey, path) = key_parts(res, flow, p);
            let size = match size_of(res, flow, p) {
                Ok(z) => z,
                Err(e) => {
                    push_once(&mut b.errors, format!("{}: {e}", flow.name));
                    flow.size
                }
            };
            let key = (acct.clone(), mkey.clone(), shape(&rs, p));
            // A child's exec fee is its creator's to pay; a delegated call's
            // creator is the Delegate receipt (no method), which pays none.
            if rs.iter().any(|x| x["id"] == p["parent"] && !methods(x).is_empty()) {
                b.fees.entry(format!("{acct}.{mkey}")).or_default().insert(u(&p["exec_fees"]));
            }
            if s(&p["status"]) != "ok" {
                if !b.obs.contains_key(&key) {
                    b.never_ok.insert(format!("{acct}.{mkey} ({})", flow.name));
                }
                // A receipt that failed (not out of gas) burnt this much up
                // to its failure; used for keys that never succeed.
                if s(&p["status"]) == "failed" && u(&v["gas"]) == top {
                    let burn = u(&p["burnt"]) - u(&p["exec_fees"]);
                    b.fail_obs.entry(key).or_default().push(Obs { flow: flow.name.clone(), path, size, burn, failure: true });
                }
                continue;
            }
            let mut ao_send = 0u64;
            for c in rs.iter().filter(|c| c["parent"] == p["id"] && !is_refund(c) && methods(c).is_empty()) {
                match action_only_fees(sim, s(&p["receiver"]), c) {
                    Ok(f) => {
                        ao_send += f.send;
                        if u(&v["gas"]) == top {
                            let label = format!("{}[{}]{}", s(&c["receiver"]), actions(c).join(","), if f.derived.is_empty() { String::new() } else { format!(" (solved: {})", f.derived) });
                            b.ao_checks.push((flow.name.clone(), label, u(&c["exec_fees"]), f.exec));
                        }
                    }
                    Err(e) => push_once(&mut b.errors, format!("{}: {e}", flow.name)),
                }
            }
            let burn = u(&p["burnt"]) - u(&p["exec_fees"]) - ao_send;
            let e = b.spread.entry(key.clone()).or_insert((u64::MAX, 0));
            e.0 = e.0.min(burn);
            e.1 = e.1.max(burn);
            if !path.is_empty() {
                let e = b.path_max.entry((acct.clone(), mkey.clone(), path.clone())).or_default();
                e.0 = e.0.max(burn);
                e.1.insert(flow.name.clone());
                e.2 += 1;
            }
            if u(&v["gas"]) == top {
                b.obs.entry(key).or_default().push(Obs { flow: flow.name.clone(), path, size, burn, failure: false });
            }
        }
    }
    let ok_keys: BTreeSet<String> = b.obs.keys().map(|(a, m, _)| format!("{a}.{m}")).collect();
    b.never_ok.retain(|k| !ok_keys.iter().any(|o| k.starts_with(&format!("{o} "))));
}

/// A fitted burn key.
#[derive(Debug, Clone)]
pub struct BurnRow {
    pub acct: String,
    /// `method` or `method/shape` (when the method shows several shapes),
    /// or `method/<flow path>`.
    pub key: String,
    pub shape: String,
    /// Ggas, rounded up: with `per`, every observation is at or below
    /// `base + per · size` (so the model never overstates the gas left).
    pub base: u64,
    /// Gas, unrounded.
    pub base_exact: f64,
    /// Measured on the failure path (the key never succeeded).
    pub failure: bool,
    /// Ggas per size unit, the least-squares slope rounded to the nearest;
    /// `per_exact` unrounded. `base` is fitted against the rounded slope.
    pub per: u64,
    pub per_exact: f64,
    /// The most the line overstates one observation, gas.
    pub max_resid_gas: f64,
    pub n: usize,
    pub flows: Vec<String>,
    pub spread: (u64, u64),
}

/// Fits `base + per · size` (gas) as an upper envelope: no observation lies
/// above the line, so the model never understates a burn it was calibrated
/// on. The slope is the least-squares slope, rounded to the whole Ggas per
/// size unit the table will hold (the base is computed against that rounded
/// slope, so the emitted line is the envelope); the base is the smallest
/// that puts every observation at or below the line. Returns (base, slope
/// before rounding, largest overstatement of an observation), all in gas.
/// With one size, the base is the largest burn and the slope 0.
fn fit(obs: &[Obs]) -> (f64, f64, f64) {
    let sizes: BTreeSet<u64> = obs.iter().map(|o| o.size).collect();
    let per = if sizes.len() < 2 {
        0.0
    } else {
        let n = obs.len() as f64;
        let sx: f64 = obs.iter().map(|o| o.size as f64).sum();
        let sy: f64 = obs.iter().map(|o| o.burn as f64).sum();
        let sxx: f64 = obs.iter().map(|o| (o.size as f64).powi(2)).sum();
        let sxy: f64 = obs.iter().map(|o| o.size as f64 * o.burn as f64).sum();
        (n * sxy - sx * sy) / (n * sxx - sx * sx)
    };
    let per_r = (per / GGAS as f64).round().max(0.0) * GGAS as f64;
    let base = obs.iter().map(|o| o.burn as f64 - per_r * o.size as f64).fold(f64::MIN, f64::max);
    let resid = obs.iter().map(|o| base + per_r * o.size as f64 - o.burn as f64).fold(0.0, f64::max);
    (base, per, resid)
}

/// With `merge`, accounts listed there get one key per method (the
/// largest burn over shapes and paths), for models whose key is fixed,
/// and one key `method/path` per path (flow `path` or `path_rule`): the
/// largest burn of that path at any grid point. A model looks up the path
/// key first and falls back to the method key.
///
/// Returns the rows and, for merged keys, warnings where the largest burn
/// was only seen below the top of the grid (a path the calibration point
/// does not reach): those block a table.
pub fn burn_rows(b: &Burns, merge: &[String]) -> (Vec<BurnRow>, Vec<String>) {
    let mut warn = vec![];
    let mut shapes: BTreeMap<(String, String), BTreeSet<String>> = BTreeMap::new();
    // Keys that never succeeded take the burn up to their failure (not for
    // merged accounts, whose keys hold successful paths).
    // (A failure path is one (account, key, shape, path) with no success.)
    let mut all: BTreeMap<(String, String, String), Vec<Obs>> = b.obs.clone();
    for (k, v) in &b.fail_obs {
        if merge.contains(&k.0) {
            continue;
        }
        let ok_paths: BTreeSet<String> = b.obs.get(k).map(|os| os.iter().map(|o| o.path.clone()).collect()).unwrap_or_default();
        let e = all.entry(k.clone()).or_default();
        e.extend(v.iter().filter(|o| !ok_paths.contains(&o.path)).cloned());
    }
    for (a, m, sh) in all.keys() {
        shapes.entry((a.clone(), m.clone())).or_default().insert(sh.clone());
    }
    let mut merged: BTreeMap<(String, String), Vec<Obs>> = BTreeMap::new();
    let mut mspread: BTreeMap<(String, String), (u64, u64)> = BTreeMap::new();
    for ((a, m, sh), obs) in &b.obs {
        if merge.contains(a) {
            merged.entry((a.clone(), m.clone())).or_default().extend(obs.iter().map(|o| Obs { path: String::new(), ..o.clone() }));
            let sp = b.spread[&(a.clone(), m.clone(), sh.clone())];
            let e = mspread.entry((a.clone(), m.clone())).or_insert((u64::MAX, 0));
            e.0 = e.0.min(sp.0);
            e.1 = e.1.max(sp.1);
        }
    }
    // Several flow paths over one (acct, method, shape) split by path.
    let mut rows = vec![];
    for ((a, m), os) in &merged {
        let (mut base, per, resid) = fit(os);
        let spread = mspread[&(a.clone(), m.clone())];
        let top_max = os.iter().map(|o| o.burn).max().unwrap_or(0);
        if spread.1 > top_max {
            warn.push(format!(
                "{a}.{m}: largest burn {:.3} Tgas seen only below the top of the grid (top: {:.3}); add a flow whose top reaches that path",
                spread.1 as f64 / 1e12,
                top_max as f64 / 1e12
            ));
        }
        if per.round() == 0.0 {
            // One key for every path: the largest burn of any successful
            // receipt at any grid point (refund paths of a resolver, say,
            // only happen below the top of the grid).
            base = base.max(spread.1 as f64);
        }
        let flows: BTreeSet<String> = os.iter().map(|o| o.flow.clone()).collect();
        rows.push(BurnRow {
            acct: a.clone(),
            key: m.clone(),
            shape: shapes[&(a.clone(), m.clone())].iter().cloned().collect::<Vec<_>>().join(" | "),
            base: (base / GGAS as f64).ceil().max(0.0) as u64,
            base_exact: base,
            failure: false,
            per: (per / GGAS as f64).round().max(0.0) as u64,
            per_exact: per / GGAS as f64,
            max_resid_gas: resid,
            n: os.len(),
            flows: flows.into_iter().collect(),
            spread,
        });
    }
    for ((a, m, path), (max, flows, n)) in &b.path_max {
        if !merge.contains(a) {
            continue;
        }
        if let Some(r) = rows.iter().find(|r| &r.acct == a && &r.key == m) {
            if r.per != 0 {
                warn.push(format!("{a}.{m}/{path}: the method's burn depends on a size; path keys are constant"));
                continue;
            }
        }
        rows.push(BurnRow {
            acct: a.clone(),
            key: format!("{m}/{path}"),
            shape: String::new(),
            base: max.div_ceil(GGAS),
            base_exact: *max as f64,
            failure: false,
            per: 0,
            per_exact: 0.0,
            max_resid_gas: 0.0,
            n: *n,
            flows: flows.iter().cloned().collect(),
            spread: (*max, *max),
        });
    }
    for ((a, m, sh), obs) in &all {
        if merge.contains(a) {
            continue;
        }
        let mut by_path: BTreeMap<String, Vec<Obs>> = BTreeMap::new();
        for o in obs {
            by_path.entry(o.path.clone()).or_default().push(o.clone());
        }
        let multi = shapes[&(a.clone(), m.clone())].len() > 1;
        let by_path_n = by_path.len();
        for (path, os) in by_path {
            let is_fail = os.iter().all(|o| o.failure);
            let mut key = m.clone();
            if multi {
                key = format!("{key}/{}", if sh.is_empty() { "-" } else { sh.as_str() });
            }
            if !path.is_empty() {
                key = format!("{key}/{path}");
            }
            let (base, per, resid) = fit(&os);
            let flows: BTreeSet<String> = os.iter().map(|o| o.flow.clone()).collect();
            rows.push(BurnRow {
                acct: a.clone(),
                key,
                shape: sh.clone(),
                base: (base / GGAS as f64).ceil().max(0.0) as u64,
                base_exact: base,
                failure: is_fail,
                per: (per / GGAS as f64).round().max(0.0) as u64,
                per_exact: per / GGAS as f64,
                max_resid_gas: resid,
                n: os.len(),
                flows: flows.into_iter().collect(),
                spread: if by_path_n > 1 || is_fail { (os.iter().map(|o| o.burn).min().unwrap(), os.iter().map(|o| o.burn).max().unwrap()) } else { b.spread[&(a.clone(), m.clone(), sh.clone())] },
            });
        }
    }
    rows.sort_by(|x, y| (&x.acct, &x.key).cmp(&(&y.acct, &y.key)));
    (rows, warn)
}

/// One pair of operators `<prefix>GasBurn` / `<prefix>GasCall`; with
/// `params`, those model accounts become operator parameters, so the table
/// can be instantiated for any account names.
pub struct Table {
    pub prefix: String,
    pub params: Vec<String>,
    pub rows: Vec<BurnRow>,
    /// (account, method key, [static, weight] per action, exec fee, comment)
    pub calls: Vec<(String, String, Vec<[u64; 2]>, u64, String)>,
}

/// Writes a TLA+ module with its provenance header (what the numbers were
/// measured on, and how to reproduce them) and the
/// tables.
pub fn emit_tla(
    module: &str,
    prov: &Provenance,
    wasms: &[(String, String, String, String)],
    tables: &[Table],
    command: &str,
    data: &[String],
    notes: &[String],
    warnings: &[String],
) -> String {
    let mut o = String::new();
    let line = |o: &mut String, t: &str| {
        let _ = writeln!(o, "(* {t:<72}*)");
    };
    let _ = writeln!(o, "{} MODULE {module} {}", "-".repeat(28), "-".repeat(28));
    let _ = writeln!(o, "(***************************************************************************)");
    line(&mut o, "Calibrated gas tables, generated by conformance/ (bin `calibrate`):");
    line(&mut o, "do not edit by hand.  Units: Ggas (1 Tgas = 1000); burn = base + per *");
    line(&mut o, "size.  Measured in near-contract-sim, which runs nearcore's");
    line(&mut o, "Runtime::apply.  Every burn measured is at or below base + per * size");
    line(&mut o, "(per: the fitted slope, rounded; base and exec fees rounded up), so");
    line(&mut o, "the tables never understate what they were measured on; \"max");
    line(&mut o, "residual\" is the most a key overstates one measurement (Ggas).");
    line(&mut o, "");
    provenance_block(&mut o, prov, wasms, command, data);
    if !warnings.is_empty() {
        line(&mut o, "WARNING: PARTIAL CALIBRATION (--allow-partial). These checks failed,");
        line(&mut o, "so some entries below are not backed by a passing split check:");
        for w in warnings {
            wrap_line(&mut o, &format!("  ! {w}"));
        }
        line(&mut o, "");
    }
    for n in notes {
        line(&mut o, n);
    }
    line(&mut o, "Burns depend on the contract's code and state: recalibrate for a real");
    line(&mut o, "deployment (conformance/README.md).");
    let _ = writeln!(o, "(***************************************************************************)");
    let _ = writeln!(o, "EXTENDS TLC, Sequences");
    for t in tables {
        let _ = writeln!(o);
        emit_table(&mut o, t);
    }
    let _ = writeln!(o, "{}", "=".repeat(77));
    o
}

/// A header comment line, padded to 72 columns.
fn hline(o: &mut String, t: &str) {
    let _ = writeln!(o, "(* {t:<72}*)");
}

/// The header's provenance: sim, nearcore, protocol, every wasm's sha256,
/// the command as run and the data lines, then an empty line.
fn provenance_block(o: &mut String, prov: &Provenance, wasms: &[(String, String, String, String)], command: &str, data: &[String]) {
    hline(o, "Provenance:");
    hline(o, &format!("  sim rev          {}", prov.sim_rev));
    hline(o, &format!("  nearcore         {} ({})", prov.nearcore_tag, prov.nearcore_rev));
    hline(o, &format!("  protocol version {}", prov.protocol_version));
    for (id, file, sha, src) in wasms {
        hline(o, &format!("  {id}: {file}"));
        if !src.is_empty() {
            hline(o, &format!("    {src}"));
        }
        hline(o, &format!("    sha256 {}", &sha[..32]));
        hline(o, &format!("           {}", &sha[32..]));
    }
    wrap_line(o, &format!("  command: {command}"));
    for d in data {
        wrap_line(o, &format!("  {d}"));
    }
    hline(o, "");
}

/// A header comment line, wrapped at 72 columns (continuations indented).
fn wrap_line(o: &mut String, t: &str) {
    let indent = t.len() - t.trim_start().len() + 2;
    let mut cl = String::new();
    for w in t.split(' ') {
        if !cl.is_empty() && cl.len() + 1 + w.len() > 72 {
            let _ = writeln!(o, "(* {cl:<72}*)");
            cl = " ".repeat(indent - 1);
        }
        if !cl.is_empty() {
            cl += " ";
        }
        cl += w;
    }
    let _ = writeln!(o, "(* {cl:<72}*)");
}

fn emit_table(o: &mut String, t: &Table) {
    let (prefix, params, rows, calls) = (&t.prefix, &t.params, &t.rows, &t.calls);
    let kexpr = |acct: &str, k: &str| -> String {
        if params.iter().any(|p| p == acct) { format!("{acct} \\o \".{k}\"") } else { format!("\"{acct}.{k}\"") }
    };
    let args = if params.is_empty() { String::new() } else { format!("({})", params.join(", ")) };
    // GasBurn
    let mut burn: Vec<String> = vec![];
    for r in rows {
        let resid = r.max_resid_gas / GGAS as f64;
        burn.push(format!(
            "    {} :> [base |-> {}, per |-> {}]  \\* {} pt{}; spread {:.3}-{:.3} Tgas{}{}",
            kexpr(&r.acct, &r.key),
            r.base,
            r.per,
            r.n,
            if r.n == 1 { "" } else { "s" },
            r.spread.0 as f64 / 1e12,
            r.spread.1 as f64 / 1e12,
            if r.per_exact != 0.0 { format!("; per exact {:.4}", r.per_exact) } else { String::new() },
            if resid >= 0.5 { format!("; max residual {resid:.1}") } else { String::new() },
        ) + if r.failure { "; burn up to the failure (never succeeds)" } else { "" });
    }
    let _ = writeln!(o, "{prefix}GasBurn{args} ==");
    if burn.is_empty() {
        let _ = writeln!(o, "    [k \\in {{}} |-> [base |-> 0, per |-> 0]]");
    } else {
        for (i, l) in burn.iter().enumerate() {
            let sep = if i + 1 < burn.len() { " @@" } else { "" };
            // put the separator before the comment
            let (code, cmt) = l.split_once("  \\*").unwrap();
            let _ = writeln!(o, "{code}{sep}  \\*{cmt}");
        }
    }
    let _ = writeln!(o);
    let mut call: Vec<(String, String)> = vec![];
    for (acct, m, acts, fee, cmt) in calls {
        let st: Vec<String> = acts.iter().map(|a| (a[0]).to_string()).collect();
        let wt: Vec<String> = acts.iter().map(|a| a[1].to_string()).collect();
        call.push((format!("    {} :> [st |-> <<{}>>, wt |-> <<{}>>, fee |-> {}]", kexpr(acct, m), st.join(", "), wt.join(", "), fee), cmt.clone()));
    }
    let _ = writeln!(o, "{prefix}GasCall{args} ==");
    if call.is_empty() {
        let _ = writeln!(o, "    [k \\in {{}} |-> [st |-> <<>>, wt |-> <<>>, fee |-> 0]]");
    } else {
        for (i, (code, cmt)) in call.iter().enumerate() {
            let sep = if i + 1 < call.len() { " @@" } else { "" };
            if cmt.is_empty() {
                let _ = writeln!(o, "{code}{sep}");
            } else {
                let _ = writeln!(o, "{code}{sep}  \\* {cmt}");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Storage bytes (`calibrate --stor`)

/// One storage measurement: the bytes a successful receipt added to its
/// receiver's `storage_usage` (negative: freed), at storage size `size`
/// (`sized`: the key has a `[[stor_size]]`; otherwise `size` is 0 and the
/// key is a constant).
#[derive(Debug, Clone)]
pub struct StorObs {
    pub flow: String,
    pub path: String,
    pub size: u64,
    pub sized: bool,
    pub bytes: i64,
}

#[derive(Default, Debug)]
pub struct Stor {
    /// (model account, method key, shape) -> measurements, one per flow,
    /// path and size (filled by `finish_stor`).
    pub obs: BTreeMap<(String, String, String), Vec<StorObs>>,
    /// (model account, method key, shape, path, flow, size, sized) ->
    /// bytes -> the gas points (Tgas) where a successful receipt of that
    /// key added them. More than one byte count is an error.
    pub by_gas: BTreeMap<(String, String, String, String, String, u64, bool), BTreeMap<i64, BTreeSet<u64>>>,
    /// Action-only receipts, `receiver[actions]` -> bytes seen (reported,
    /// not emitted: the library counts those itself).
    pub action_only: BTreeMap<String, BTreeSet<i64>>,
    /// Keys whose receipt never succeeded at any gas point.
    pub never_ok: BTreeSet<String>,
    /// Successful call receipts measured, over every gas point.
    pub receipts: usize,
    /// Flow runs (flows times gas points).
    pub runs: usize,
    /// Every receipt checked (conversions, refunds and action-only ones
    /// included), over every gas point.
    pub checked: usize,
    /// Problems that block a table.
    pub errors: Vec<String>,
}

/// The storage size of call receipt `p` (JSON, as `dump` writes it) whose
/// full first argument is `args` (see `spec::StorSizeSrc`): `None` if the
/// key has no size source.
pub fn stor_size_of(res: &Resolved, p: &Value, args: &[u8]) -> Result<Option<u64>, String> {
    let ck = call_key(p);
    let Some(src) = res.spec.stor_sizes.iter().find(|z| z.key == ck) else { return Ok(None) };
    let parsed = || -> Result<Value, String> { serde_json::from_slice(args).map_err(|e| format!("{ck}: args not JSON: {e}")) };
    let raw = if let Some(fields) = src.from.strip_prefix("arg_len:") {
        let a = parsed()?;
        let mut n = 0u64;
        for f in fields.split('+') {
            n += a[f].as_str().ok_or(format!("{ck}: no string arg {f}"))?.len() as u64;
        }
        n
    } else if src.from == "predecessor_len" {
        s(&p["predecessor"]).len() as u64
    } else if let Some(field) = src.from.strip_prefix("arg:") {
        let a = parsed()?;
        let x = &a[field];
        x.as_u64().or_else(|| x.as_str().and_then(|t| t.parse().ok())).ok_or(format!("{ck}: no numeric arg {field}"))?
    } else {
        return Err(format!("{ck}: unknown storage size source {}", src.from));
    };
    Ok(Some(raw / src.div.max(1)))
}

/// Every account's `storage_usage` in `sim` (0 if absent), for `ids`.
fn usages(sim: &Sim, ids: &BTreeSet<String>) -> BTreeMap<String, i64> {
    ids.iter().map(|a| (a.clone(), sim.account(a.as_str()).map_or(0, |v| v.storage_usage as i64))).collect()
}

/// Storage measurements of one run of `flow` at prepaid `gas` (its
/// outcomes `os`), from nearcore's `storage_usage` before and after each
/// receipt (the sim's `ReceiptOutcome::storage`). Checks, on every receipt
/// of the run (the transactions' conversions, refunds and action-only
/// receipts included) before any is set aside: that it changed no account
/// but its receiver, and that a failed one changed nothing; and that the
/// receipts' changes add up to each account's change over the run (`before`
/// and `after` are the world either side of it). Then records each
/// successful call receipt's bytes under its key and gas point.
pub fn collect_stor(res: &Resolved, flow: &Flow, gas: u64, os: &[near_contract_sim::TxOutcome], before: &Sim, after: &Sim, st: &mut Stor) {
    use near_contract_sim::ReceiptOutcome;
    let tgas = gas as f64 / 1e12;
    st.runs += 1;
    let all: Vec<&ReceiptOutcome> = os.iter().flat_map(|o| o.transaction.iter().chain(&o.receipts)).collect();
    // Per account: the receipts' changes, summed.
    let mut sum: BTreeMap<String, i64> = BTreeMap::new();
    for r in &all {
        st.checked += 1;
        let rx = r.executor_id.as_str();
        for c in &r.storage {
            *sum.entry(c.account.to_string()).or_default() += c.bytes;
            if c.account.as_str() != rx {
                push_once(&mut st.errors, format!("{} at {tgas:.1} Tgas: a receipt to {rx} changed {}'s storage by {} bytes", flow.name, c.account, c.bytes));
            }
        }
        if r.failure().is_some() && r.storage.iter().any(|c| c.bytes != 0) {
            push_once(&mut st.errors, format!("{} at {tgas:.1} Tgas: a failed receipt to {rx} ({}) changed storage", flow.name, r.method_names.join("+")));
        }
    }
    let mut ids: BTreeSet<String> = sum.keys().cloned().collect();
    ids.extend(res.spec.accounts.iter().map(|a| a.id.clone()));
    ids.extend(res.spec.contracts.iter().map(|c| c.id.clone()));
    ids.extend(all.iter().map(|r| r.executor_id.to_string()));
    let (u0, u1) = (usages(before, &ids), usages(after, &ids));
    for a in &ids {
        let (seen, want) = (sum.get(a).copied().unwrap_or(0), u1[a] - u0[a]);
        if seen != want {
            push_once(&mut st.errors, format!("{} at {tgas:.1} Tgas: {a}: receipts changed its storage by {seen} bytes, view_account by {want}", flow.name));
        }
    }
    // Only now: what is fitted (successful call receipts, refunds aside).
    let by_id: HashMap<String, &ReceiptOutcome> = all.iter().map(|r| (r.id.to_string(), *r)).collect();
    let v = crate::dump_all(os);
    let rs: Vec<&Value> = v["receipts"].as_array().unwrap().iter().filter(|r| !r["conversion"].as_bool().unwrap()).collect();
    for p in &rs {
        if is_refund(p) {
            continue;
        }
        let r = by_id[s(&p["id"])];
        let rx = r.executor_id.as_str();
        let bytes: i64 = r.storage.iter().filter(|c| c.account.as_str() == rx).map(|c| c.bytes).sum();
        if methods(p).is_empty() {
            st.action_only.entry(format!("{rx}[{}]", actions(p).join(","))).or_default().insert(bytes);
            continue;
        }
        let (acct, mkey, path) = key_parts(res, flow, p);
        if s(&p["status"]) != "ok" {
            st.never_ok.insert(format!("{acct}.{mkey} ({})", flow.name));
            continue;
        }
        let (size, sized) = match stor_size_of(res, p, r.args.first().map_or(&[][..], |a| a.as_slice())) {
            Ok(z) => (z.unwrap_or(0), z.is_some()),
            Err(e) => {
                push_once(&mut st.errors, format!("{}: {e}", flow.name));
                (0, true)
            }
        };
        st.receipts += 1;
        st.by_gas.entry((acct, mkey, shape(&rs, p), path, flow.name.clone(), size, sized)).or_default().entry(bytes).or_default().insert(gas);
    }
}

/// Runs `flow` at every gas of `grid` on a fresh copy of its world and
/// collects each run (`collect_stor`). Returns the number of successful
/// call receipts measured.
pub fn measure_stor_flow(res: &Resolved, base: &Sim, flow: &Flow, grid: &[u64], st: &mut Stor) -> usize {
    let w = res.flow_world(base, flow);
    let n0 = st.receipts;
    for &g in grid {
        let mut sim = w.clone();
        let os = crate::spec::run_flow(&mut sim, flow, near_contract_sim::prelude::Gas::from_gas(g));
        collect_stor(res, flow, g, &os, &w, &sim, st);
    }
    st.receipts - n0
}

/// After every flow and gas point: a key's successful receipts must add the
/// same bytes at every gas point (else an error naming them); then one
/// measurement per flow, path and size goes to `obs`.
pub fn finish_stor(st: &mut Stor) {
    for ((a, m, sh, path, flow, size, sized), by) in &st.by_gas {
        if by.len() > 1 {
            let seen: Vec<String> = by
                .iter()
                .map(|(b, gs)| format!("{b} bytes at {} point(s), {:.1}-{:.1} Tgas", gs.len(), *gs.first().unwrap() as f64 / 1e12, *gs.last().unwrap() as f64 / 1e12))
                .collect();
            st.errors.push(format!("{flow}: {a}.{m}{}: bytes depend on gas: {}", if path.is_empty() { String::new() } else { format!(" (path {path})") }, seen.join("; ")));
            continue;
        }
        let bytes = *by.keys().next().unwrap();
        st.obs.entry((a.clone(), m.clone(), sh.clone())).or_default().push(StorObs { flow: flow.clone(), path: path.clone(), size: *size, sized: *sized, bytes });
    }
    let ok: BTreeSet<String> = st.obs.keys().map(|(a, m, _)| format!("{a}.{m} ")).collect();
    st.never_ok.retain(|k| !ok.iter().any(|o| k.starts_with(o.as_str())));
}

/// A storage key: bytes = `base + per * size`, exactly on every
/// measurement.
#[derive(Debug, Clone)]
pub struct StorRow {
    pub acct: String,
    pub key: String,
    pub base: i64,
    pub per: i64,
    pub n: usize,
    /// Smallest and largest size measured.
    pub sizes: (u64, u64),
    /// Distinct sizes measured (0 for a constant key).
    pub distinct: usize,
    pub flows: Vec<String>,
}

/// Distinct sizes a key with a size source needs: two always fit a line,
/// so a third is what tests it.
pub const MIN_SIZES: usize = 3;

/// The exact line of a key's measurements, in whole bytes: `(base, per)`.
/// Bytes are counted exactly (key + value + 40 per record, and so on), so
/// anything else is an error:
/// - a key without a size source is a constant: every measurement the same
///   bytes (per 0);
/// - a key with one needs `MIN_SIZES` distinct sizes, a whole slope, and
///   every measurement on the line (a size source that misses something,
///   or two paths under one key, fail here).
///
/// The arithmetic is checked i128, and `base` and `per` must fit TLC's
/// 32-bit integers, which the table is emitted for.
pub fn fit_exact(obs: &[StorObs]) -> Result<(i64, i64), String> {
    let first = obs.first().ok_or("no measurement")?;
    if obs.iter().any(|o| o.sized != first.sized) {
        return Err("measurements with and without a size source".into());
    }
    if !first.sized {
        if let Some(o) = obs.iter().find(|o| o.bytes != first.bytes) {
            return Err(format!("no size source, but {} bytes ({}) and {} bytes ({})", first.bytes, first.flow, o.bytes, o.flow));
        }
        return Ok((first.bytes, 0));
    }
    let sizes: BTreeSet<u64> = obs.iter().map(|o| o.size).collect();
    if sizes.len() < MIN_SIZES {
        return Err(format!("{} distinct size(s) measured ({}); a line needs {MIN_SIZES} to be tested", sizes.len(), sizes.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(", ")));
    }
    let lo = obs.iter().min_by_key(|o| o.size).unwrap();
    let hi = obs.iter().max_by_key(|o| o.size).unwrap();
    let (num, den) = (hi.bytes as i128 - lo.bytes as i128, hi.size as i128 - lo.size as i128);
    if num % den != 0 {
        return Err(format!("{num} bytes over {den} size units: not a whole slope"));
    }
    let per = num / den;
    let base = (per.checked_mul(lo.size as i128)).and_then(|x| (lo.bytes as i128).checked_sub(x)).ok_or("overflow")?;
    for o in obs {
        let on = per.checked_mul(o.size as i128).and_then(|x| x.checked_add(base));
        if on != Some(o.bytes as i128) {
            return Err(format!("{} bytes at size {} ({}) is off the line {base} + {per} * size", o.bytes, o.size, o.flow));
        }
    }
    let tlc = i32::MIN as i128..=i32::MAX as i128;
    if !tlc.contains(&base) || !tlc.contains(&per) {
        return Err(format!("base {base} or per {per} outside TLC's 32-bit integers"));
    }
    Ok((base as i64, per as i64))
}

fn stor_row(acct: &str, key: String, obs: &[StorObs], errors: &mut Vec<String>) -> Option<StorRow> {
    match fit_exact(obs) {
        Ok((base, per)) => {
            let flows: BTreeSet<String> = obs.iter().map(|o| o.flow.clone()).collect();
            Some(StorRow {
                acct: acct.to_owned(),
                key,
                base,
                per,
                n: obs.len(),
                sizes: (obs.iter().map(|o| o.size).min().unwrap(), obs.iter().map(|o| o.size).max().unwrap()),
                distinct: if obs[0].sized { obs.iter().map(|o| o.size).collect::<BTreeSet<_>>().len() } else { 0 },
                flows: flows.into_iter().collect(),
            })
        }
        Err(e) => {
            errors.push(format!("{acct}.{key}: {e}"));
            None
        }
    }
}

/// The storage keys, named as `burn_rows` names burn keys. With `merge`,
/// those accounts get `method/path` per path, and the bare `method` only
/// if every path and shape of it lies on one line (no "largest" for
/// bytes: a registration and a repeat cannot share a key). Returns the
/// rows, errors (block a table) and notes.
pub fn stor_rows(st: &Stor, merge: &[String]) -> (Vec<StorRow>, Vec<String>, Vec<String>) {
    let (mut rows, mut errors, mut notes) = (vec![], vec![], vec![]);
    let mut shapes: BTreeMap<(String, String), BTreeSet<String>> = BTreeMap::new();
    let mut merged: BTreeMap<(String, String), Vec<StorObs>> = BTreeMap::new();
    for ((a, m, sh), obs) in &st.obs {
        shapes.entry((a.clone(), m.clone())).or_default().insert(sh.clone());
        if merge.contains(a) {
            merged.entry((a.clone(), m.clone())).or_default().extend(obs.iter().cloned());
        }
    }
    for ((a, m), obs) in &merged {
        let mut by_path: BTreeMap<String, Vec<StorObs>> = BTreeMap::new();
        for o in obs {
            by_path.entry(o.path.clone()).or_default().push(o.clone());
        }
        for (path, os) in by_path.iter().filter(|(p, _)| !p.is_empty()) {
            rows.extend(stor_row(a, format!("{m}/{path}"), os, &mut errors));
        }
        if by_path.len() == 1 && by_path.contains_key("") {
            // no paths: the method key is the only one (its fit's error, if any)
            rows.extend(stor_row(a, m.clone(), obs, &mut errors));
        } else if fit_exact(obs).is_ok() {
            rows.extend(stor_row(a, m.clone(), obs, &mut errors));
        } else if by_path.contains_key("") {
            errors.push(format!("{a}.{m}: receipts without a path are not on the line of its other paths; give them a path"));
        } else {
            notes.push(format!("{a}.{m}: no method key (its paths differ): {}", by_path.keys().map(|p| format!("{m}/{p}")).collect::<Vec<_>>().join(", ")));
        }
    }
    for ((a, m, sh), obs) in &st.obs {
        if merge.contains(a) {
            continue;
        }
        let multi = shapes[&(a.clone(), m.clone())].len() > 1;
        let mut by_path: BTreeMap<String, Vec<StorObs>> = BTreeMap::new();
        for o in obs {
            by_path.entry(o.path.clone()).or_default().push(o.clone());
        }
        for (path, os) in by_path {
            let mut key = m.clone();
            if multi {
                key = format!("{key}/{}", if sh.is_empty() { "-" } else { sh.as_str() });
            }
            if !path.is_empty() {
                key = format!("{key}/{path}");
            }
            rows.extend(stor_row(a, key, &os, &mut errors));
        }
    }
    rows.sort_by(|x, y| (&x.acct, &x.key).cmp(&(&y.acct, &y.key)));
    (rows, errors, notes)
}

/// One operator `<prefix>StorBytes`; with `params`, those model accounts
/// become its parameters, as for `Table`.
pub struct StorTable {
    pub prefix: String,
    pub params: Vec<String>,
    pub rows: Vec<StorRow>,
}

/// Writes a TLA+ module of storage tables with its provenance header.
#[allow(clippy::too_many_arguments)]
pub fn emit_stor_tla(
    module: &str,
    prov: &Provenance,
    wasms: &[(String, String, String, String)],
    tables: &[StorTable],
    command: &str,
    data: &[String],
    notes: &[String],
    warnings: &[String],
) -> String {
    let mut o = String::new();
    let _ = writeln!(o, "{} MODULE {module} {}", "-".repeat(28), "-".repeat(28));
    let _ = writeln!(o, "(***************************************************************************)");
    for t in [
        "Measured storage bytes, generated by conformance/ (bin `calibrate`,",
        "--stor): do not edit by hand.  bytes = base + per * size: what a",
        "successful receipt adds to its receiver's storage_usage (negative:",
        "frees), read before and after the receipt in near-contract-sim, which",
        "runs nearcore's Runtime::apply.  Each flow ran at every point of its",
        "gas grid, and a key's successful receipts added the same bytes at",
        "every point.  A key with a size source was measured at 3 or more",
        "distinct sizes, every one exactly on its line; a key without one is a",
        "constant (per 0), the same bytes everywhere.  Read with OStorKey",
        "(modules/NearAsync.tla).",
        "",
    ] {
        hline(&mut o, t);
    }
    provenance_block(&mut o, prov, wasms, command, data);
    if !warnings.is_empty() {
        hline(&mut o, "WARNING: PARTIAL CALIBRATION (--allow-partial). These checks failed,");
        hline(&mut o, "so some entries below are not measured exactly:");
        for w in warnings {
            wrap_line(&mut o, &format!("  ! {w}"));
        }
        hline(&mut o, "");
    }
    for n in notes {
        hline(&mut o, n);
    }
    hline(&mut o, "Bytes depend on the contract's code and state: recalibrate for a real");
    hline(&mut o, "deployment (conformance/README.md).");
    let _ = writeln!(o, "(***************************************************************************)");
    let _ = writeln!(o, "EXTENDS Integers, Sequences, TLC");
    for t in tables {
        let kexpr = |acct: &str, k: &str| -> String {
            if t.params.iter().any(|p| p == acct) { format!("{acct} \\o \".{k}\"") } else { format!("\"{acct}.{k}\"") }
        };
        let args = if t.params.is_empty() { String::new() } else { format!("({})", t.params.join(", ")) };
        let _ = writeln!(o);
        let _ = writeln!(o, "{}StorBytes{args} ==", t.prefix);
        if t.rows.is_empty() {
            let _ = writeln!(o, "    [k \\in {{}} |-> [base |-> 0, per |-> 0]]");
        }
        for (i, r) in t.rows.iter().enumerate() {
            let sep = if i + 1 < t.rows.len() { " @@" } else { "" };
            let sizes = if r.distinct == 0 { "constant".to_owned() } else { format!("{} sizes {}-{}", r.distinct, r.sizes.0, r.sizes.1) };
            let _ = writeln!(
                o,
                "    {} :> [base |-> {}, per |-> {}]{sep}  \\* {} pt{}; {sizes}; {}",
                kexpr(&r.acct, &r.key),
                r.base,
                r.per,
                r.n,
                if r.n == 1 { "" } else { "s" },
                r.flows.join(" ")
            );
        }
    }
    let _ = writeln!(o, "{}", "=".repeat(77));
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(points: &[(u64, u64)]) -> Vec<Obs> {
        points.iter().map(|&(size, burn)| Obs { flow: "f".into(), path: String::new(), size, burn, failure: false }).collect()
    }

    /// The emitted line (slope rounded to whole Ggas, base rounded up) is at
    /// or above every observation, also where least squares would cut below.
    #[test]
    fn fit_is_an_upper_envelope() {
        let cases: [&[(u64, u64)]; 4] = [
            // slope 1.0002 Ggas per unit: rounds down to 1, the base absorbs it
            &[(0, 0), (1000, 1_000_200_000_000), (2000, 2_000_400_000_000)],
            // a point above the least-squares line
            &[(0, 268_000_000_000), (10, 300_000_000_000), (20, 330_000_000_000), (30, 352_000_000_000)],
            // one size: the largest burn
            &[(5, 416_000_000_000), (5, 859_000_000_000)],
            // a falling slope is clamped to 0
            &[(0, 9_000_000_000), (10, 5_000_000_000)],
        ];
        for pts in cases {
            let os = obs(pts);
            let (base, per, resid) = fit(&os);
            let per_g = (per / GGAS as f64).round().max(0.0) as u64;
            let base_g = (base / GGAS as f64).ceil().max(0.0) as u64;
            for o in &os {
                assert!(o.burn <= (base_g + per_g * o.size) * GGAS, "{pts:?}: {o:?} above {base_g} + {per_g}·size");
            }
            assert!(resid >= 0.0);
        }
        let (base, _, resid) = fit(&obs(&[(5, 416_000_000_000), (5, 859_000_000_000)]));
        assert_eq!((base, resid), (859e9, 443e9));
    }

    fn sobs(points: &[(u64, i64)]) -> Vec<StorObs> {
        points.iter().map(|&(size, bytes)| StorObs { flow: "f".into(), path: String::new(), size, sized: true, bytes }).collect()
    }

    /// Storage bytes fit a whole-byte line exactly, at 3 or more sizes, or
    /// the key is an error.
    #[test]
    fn fit_exact_lines() {
        assert_eq!(fit_exact(&sobs(&[(9, 70), (30, 91), (64, 125)])), Ok((61, 1)));
        assert_eq!(fit_exact(&sobs(&[(9, -70), (30, -91), (46, -107)])), Ok((-61, -1)));
        assert_eq!(fit_exact(&sobs(&[(2, 42), (102, 142), (42, 82)])), Ok((40, 1)));
        assert_eq!(fit_exact(&sobs(&[(5, 0), (52, 0), (120, 0)])), Ok((0, 0)));
        // two sizes always fit a line: not a test of one
        assert!(fit_exact(&sobs(&[(9, 70), (64, 125)])).is_err());
        assert!(fit_exact(&sobs(&[(9, 70), (9, 70), (64, 125)])).is_err());
        // one size, two byte counts: two paths under one key
        assert!(fit_exact(&sobs(&[(9, 70), (9, 0), (30, 91)])).is_err());
        // a point off the line through the extremes
        assert!(fit_exact(&sobs(&[(0, 40), (10, 50), (20, 60), (5, 46)])).is_err());
        // not a whole slope
        assert!(fit_exact(&sobs(&[(0, 0), (1, 1), (2, 3)])).is_err());
    }

    /// A key without a size source is a constant: the same bytes at every
    /// measurement, whatever their number.
    #[test]
    fn fit_exact_constants() {
        let c = |bs: &[i64]| -> Vec<StorObs> { bs.iter().map(|&bytes| StorObs { flow: "f".into(), path: String::new(), size: 0, sized: false, bytes }).collect() };
        assert_eq!(fit_exact(&c(&[0])), Ok((0, 0)));
        assert_eq!(fit_exact(&c(&[-69, -69])), Ok((-69, 0)));
        assert!(fit_exact(&c(&[0, 61])).is_err());
        // mixed: one with a size source, one without
        let mut m = c(&[0]);
        m.extend(sobs(&[(1, 0), (2, 0), (3, 0)]));
        assert!(fit_exact(&m).is_err());
    }

    /// Sizes far apart: a u64 difference cast to i64 wraps (u64::MAX - 0
    /// becomes -1, so -1 byte over it read as a slope of 1 and a false
    /// fit); checked i128 arithmetic rejects it. Coefficients outside
    /// TLC's 32-bit integers are rejected too.
    #[test]
    fn fit_exact_wide_sizes() {
        // with the i64 cast, sizes u64::MAX and u64::MAX - 1 read as -1 and -2,
        // and these three points were taken as the line 0 + 1 * size
        assert!(fit_exact(&sobs(&[(0, 0), (u64::MAX - 1, -2), (u64::MAX, -1)])).is_err());
        assert!(fit_exact(&sobs(&[(0, 0), (u64::MAX / 2, -1), (u64::MAX, -1)])).is_err());
        // whole but too steep for TLC
        assert!(fit_exact(&sobs(&[(0, 0), (1, 1 << 40), (2, 1 << 41)])).is_err());
        // base out of range, slope fine
        assert!(fit_exact(&sobs(&[(0, 1 << 40), (1, (1 << 40) + 1), (2, (1 << 40) + 2)])).is_err());
        // the largest in range is accepted
        let m = i32::MAX as i64;
        assert_eq!(fit_exact(&sobs(&[(0, m), (1, m), (2, m)])), Ok((m, 0)));
    }

    /// Bytes that differ between gas points fail the key, loudly.
    #[test]
    fn finish_stor_rejects_gas_dependent_bytes() {
        let mut st = Stor::default();
        let k = ("p".to_owned(), "put".to_owned(), String::new(), "new".to_owned(), "f".to_owned(), 5, true);
        st.by_gas.entry(k.clone()).or_default().entry(45).or_default().extend([1_000_000_000_000, 300_000_000_000_000]);
        st.by_gas.entry(k).or_default().entry(0).or_default().insert(2_000_000_000_000);
        finish_stor(&mut st);
        assert!(st.obs.is_empty());
        assert_eq!(st.errors.len(), 1);
        assert!(st.errors[0].contains("bytes depend on gas"), "{}", st.errors[0]);
    }
}
