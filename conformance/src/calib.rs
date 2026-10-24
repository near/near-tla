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
    /// Keys whose receipt never succeeded.
    pub never_ok: BTreeSet<String>,
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
    } else if src.from == "result" {
        s(&p["result"]).trim_matches('"').parse().map_err(|_| format!("{ck}: result not numeric"))?
    } else if src.from == "result_size" {
        u(&p["result_size"])
    } else {
        return Err(format!("{ck}: unknown size source {}", src.from));
    };
    Ok(raw / src.div.max(1))
}

/// Burn of every ok function-call receipt: `burnt - exec_fees - send fees
/// of its action-only children` (CONTRACTS D6). The flow's calibration
/// point is its largest grid gas.
pub fn collect_burns(sim: &Sim, res: &Resolved, flow: &Flow, lines: &[Value], b: &mut Burns) {
    let top = lines.iter().map(|v| u(&v["gas"])).max().unwrap_or(0);
    for v in lines {
        let rs: Vec<&Value> = v["receipts"].as_array().unwrap().iter().filter(|r| !r["conversion"].as_bool().unwrap()).collect();
        for p in &rs {
            if is_refund(p) || methods(p).is_empty() {
                continue;
            }
            let acct = res.name(s(&p["receiver"])).to_owned();
            let raw = methods(p).join("+");
            let mkey = flow.keys.get(&raw).or_else(|| res.spec.world.keys.get(&raw)).cloned().unwrap_or(raw);
            let ck = call_key(p);
            let path = if !flow.path.is_empty() && (flow.path_for.is_empty() || flow.path_for.contains(&ck)) { flow.path.clone() } else { String::new() };
            let size = match size_of(res, flow, p) {
                Ok(z) => z,
                Err(e) => {
                    push_once(&mut b.errors, format!("{}: {e}", flow.name));
                    flow.size
                }
            };
            let key = (acct.clone(), mkey.clone(), shape(&rs, p));
            if rs.iter().any(|x| x["id"] == p["parent"]) {
                b.fees.entry(format!("{acct}.{mkey}")).or_default().insert(u(&p["exec_fees"]));
            }
            if s(&p["status"]) != "ok" {
                if !b.obs.contains_key(&key) {
                    b.never_ok.insert(format!("{acct}.{mkey} ({})", flow.name));
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
            if u(&v["gas"]) == top {
                b.obs.entry(key).or_default().push(Obs { flow: flow.name.clone(), path, size, burn });
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
    /// Ggas.
    pub base: u64,
    /// Ggas per size unit, rounded; `per_exact` unrounded.
    pub per: u64,
    pub per_exact: f64,
    pub max_resid_gas: f64,
    pub n: usize,
    pub flows: Vec<String>,
    pub spread: (u64, u64),
}

fn fit(obs: &[Obs]) -> (f64, f64, f64) {
    let sizes: BTreeSet<u64> = obs.iter().map(|o| o.size).collect();
    if sizes.len() < 2 {
        let m = obs.iter().map(|o| o.burn).max().unwrap() as f64;
        let resid = obs.iter().map(|o| m - o.burn as f64).fold(0.0, f64::max);
        return (m, 0.0, resid);
    }
    let n = obs.len() as f64;
    let sx: f64 = obs.iter().map(|o| o.size as f64).sum();
    let sy: f64 = obs.iter().map(|o| o.burn as f64).sum();
    let sxx: f64 = obs.iter().map(|o| (o.size as f64).powi(2)).sum();
    let sxy: f64 = obs.iter().map(|o| o.size as f64 * o.burn as f64).sum();
    let per = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    let base = (sy - per * sx) / n;
    let resid = obs.iter().map(|o| (o.burn as f64 - (base + per * o.size as f64)).abs()).fold(0.0, f64::max);
    (base, per, resid)
}

/// With `merge`, accounts listed there get one key per method (the
/// largest burn over shapes and paths), for models whose key is fixed.
///
/// Returns the rows and, for merged keys, warnings where the largest burn
/// was only seen below the top of the grid (a path the calibration point
/// does not reach): those block a table.
pub fn burn_rows(b: &Burns, merge: &[String]) -> (Vec<BurnRow>, Vec<String>) {
    let mut warn = vec![];
    let mut shapes: BTreeMap<(String, String), BTreeSet<String>> = BTreeMap::new();
    for (a, m, sh) in b.obs.keys() {
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
            base: (base / GGAS as f64).round().max(0.0) as u64,
            per: (per / GGAS as f64).round().max(0.0) as u64,
            per_exact: per / GGAS as f64,
            max_resid_gas: resid,
            n: os.len(),
            flows: flows.into_iter().collect(),
            spread,
        });
    }
    for ((a, m, sh), obs) in &b.obs {
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
                base: (base / GGAS as f64).round().max(0.0) as u64,
                per: (per / GGAS as f64).round().max(0.0) as u64,
                per_exact: per / GGAS as f64,
                max_resid_gas: resid,
                n: os.len(),
                flows: flows.into_iter().collect(),
                spread: if by_path_n > 1 { (os.iter().map(|o| o.burn).min().unwrap(), os.iter().map(|o| o.burn).max().unwrap()) } else { b.spread[&(a.clone(), m.clone(), sh.clone())] },
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

/// Writes a TLA+ module with the provenance header (CONTRACTS C4) and the
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
    line(&mut o, "Runtime::apply.");
    line(&mut o, "");
    line(&mut o, "Provenance:");
    line(&mut o, &format!("  sim rev          {}", prov.sim_rev));
    line(&mut o, &format!("  nearcore         {} ({})", prov.nearcore_tag, prov.nearcore_rev));
    line(&mut o, &format!("  protocol version {}", prov.protocol_version));
    for (id, file, sha, src) in wasms {
        line(&mut o, &format!("  {id}: {file}"));
        if !src.is_empty() {
            line(&mut o, &format!("    {src}"));
        }
        line(&mut o, &format!("    sha256 {}", &sha[..32]));
        line(&mut o, &format!("           {}", &sha[32..]));
    }
    wrap_line(&mut o, &format!("  command: {command}"));
    for d in data {
        wrap_line(&mut o, &format!("  {d}"));
    }
    line(&mut o, "");
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
        ));
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
