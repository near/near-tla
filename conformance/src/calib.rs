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

/// Send fee (gas) of an action-only receipt created by `parent_rx`:
/// receipt creation plus each action's send fee (Transfer by receiver
/// account type), and the exec fee the fee table predicts.
pub fn action_only_fees(sim: &Sim, parent_rx: &str, r: &Value) -> Result<(u64, u64), String> {
    use near_contract_sim::nearcore::near_parameters::ActionCosts;
    let rx = s(&r["receiver"]);
    let sir = parent_rx == rx;
    let (rs, re) = crate::receipt_fees(sim, sir);
    let (mut send, mut exec) = (rs, re);
    let fees = &sim.config.runtime_config().fees;
    for a in actions(r) {
        let (sf, ef) = match a.as_str() {
            "Transfer" => crate::transfer_fees(sim, sir, rx),
            "Stake" => (fees.fee(ActionCosts::stake).send_fee(sir).gas.as_gas(), fees.fee(ActionCosts::stake).exec_fee().gas.as_gas()),
            "DeleteKey" => (fees.fee(ActionCosts::delete_key).send_fee(sir).gas.as_gas(), fees.fee(ActionCosts::delete_key).exec_fee().gas.as_gas()),
            "CreateAccount" => (fees.fee(ActionCosts::create_account).send_fee(sir).gas.as_gas(), fees.fee(ActionCosts::create_account).exec_fee().gas.as_gas()),
            other => return Err(format!("action-only child with a {other} action: its send fee is not computed (calibrate it by hand)")),
        };
        send += sf;
        exec += ef;
    }
    Ok((send, exec))
}

#[derive(Default, Debug)]
pub struct SplitReport {
    pub children: usize,
    pub mismatches: usize,
    pub worst: u64,
    pub batch_children: usize,
    pub batch_worst: u64,
    pub notes: Vec<String>,
}

/// Recomputes every function-call child's attached gas from its parent's
/// measured use (`burnt - exec_fees`), the children's exec fees and the
/// declared statics and weights, at every point of `lines`.
pub fn check_split(res: &Resolved, flow: &Flow, lines: &[Value], rep: &mut SplitReport) {
    for v in lines {
        let rs: Vec<&Value> = v["receipts"].as_array().unwrap().iter().filter(|r| !r["conversion"].as_bool().unwrap()).collect();
        // Predicted per-action gas of receipts seen as children (for
        // prepaid-relative statics of their own children).
        let mut peract: HashMap<String, Vec<u64>> = HashMap::new();
        for p in &rs {
            if is_refund(p) || s(&p["status"]) != "ok" || methods(p).is_empty() {
                continue;
            }
            let kids: Vec<&&Value> = rs.iter().filter(|c| c["parent"] == p["id"] && !is_refund(c)).collect();
            if kids.is_empty() {
                continue;
            }
            let pid = s(&p["id"]).to_owned();
            let pa = u(&p["attached"]);
            let p_last = peract.get(&pid).and_then(|x| x.last().copied()).unwrap_or(pa);
            let pkey = call_key(p);
            let mut acts: Vec<(String, u64, u64)> = vec![];
            let mut ok = true;
            for c in &kids {
                if methods(c).is_empty() {
                    continue;
                }
                let ck = call_key(c);
                match res.static_of(flow, &pkey, &ck) {
                    Some(st) => {
                        if let Some(x) = st.prepaid_minus_ggas {
                            acts.push((s(&c["id"]).to_owned(), p_last.saturating_sub(x * GGAS), st.weight));
                        } else {
                            for a in &st.actions {
                                acts.push((s(&c["id"]).to_owned(), a[0] * GGAS, a[1]));
                            }
                        }
                    }
                    None => {
                        let n = format!("{}: no static declared for {ck} (created by {pkey})", flow.name);
                        if !rep.notes.contains(&n) {
                            rep.notes.push(n);
                        }
                        ok = false;
                    }
                }
            }
            if !ok {
                continue;
            }
            let used = u(&p["burnt"]) - u(&p["exec_fees"]);
            let need = used + kids.iter().map(|c| u(&c["exec_fees"])).sum::<u64>() + acts.iter().map(|a| a.1).sum::<u64>();
            let left = pa.saturating_sub(need);
            let sh = split(left, &acts.iter().map(|a| a.2).collect::<Vec<_>>());
            let mut pred: HashMap<&str, u64> = HashMap::new();
            for ((cid, st, _), a) in acts.iter().zip(&sh) {
                *pred.entry(cid.as_str()).or_default() += st + a;
                peract.entry(cid.clone()).or_default().push(st + a);
            }
            let batch = methods(p).len() > 1;
            for c in &kids {
                if methods(c).is_empty() {
                    continue;
                }
                let d = u(&c["attached"]).abs_diff(*pred.get(s(&c["id"])).unwrap_or(&0));
                if batch {
                    rep.batch_children += 1;
                    rep.batch_worst = rep.batch_worst.max(d);
                    continue;
                }
                rep.children += 1;
                rep.worst = rep.worst.max(d);
                if d != 0 {
                    rep.mismatches += 1;
                    if rep.mismatches <= 8 {
                        rep.notes.push(format!(
                            "split mismatch {} at {:.1} Tgas: {pkey} -> {}: sim {} predicted {} (diff {d})",
                            flow.name,
                            u(&v["gas"]) as f64 / 1e12,
                            call_key(c),
                            u(&c["attached"]),
                            pred.get(s(&c["id"])).unwrap_or(&0)
                        ));
                    }
                }
            }
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
            let mkey = res.spec.world.keys.get(&raw).cloned().unwrap_or(raw);
            let ck = call_key(p);
            let path = if !flow.path.is_empty() && (flow.path_for.is_empty() || flow.path_for.contains(&ck)) { flow.path.clone() } else { String::new() };
            let size = match size_of(res, flow, p) {
                Ok(z) => z,
                Err(e) => {
                    if !b.notes.contains(&e) {
                        b.notes.push(e);
                    }
                    flow.size
                }
            };
            let key = (acct.clone(), mkey.clone(), shape(&rs, p));
            if let Some(par) = rs.iter().find(|x| x["id"] == p["parent"]) {
                if !methods(par).is_empty() || true {
                    b.fees.entry(format!("{acct}.{mkey}")).or_default().insert(u(&p["exec_fees"]));
                }
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
                    Ok((send, exec)) => {
                        ao_send += send;
                        if u(&v["gas"]) == top {
                            b.ao_checks.push((flow.name.clone(), format!("{}[{}]", s(&c["receiver"]), actions(c).join(",")), u(&c["exec_fees"]), exec));
                        }
                    }
                    Err(e) => {
                        if !b.notes.contains(&e) {
                            b.notes.push(e)
                        }
                    }
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
pub fn burn_rows(b: &Burns, merge: &[String]) -> Vec<BurnRow> {
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
    rows
}

/// One pair of operators `<prefix>GasBurn` / `<prefix>GasCall`; with
/// `params`, those model accounts become operator parameters, so the table
/// can be instantiated for any account names.
pub struct Table {
    pub prefix: String,
    pub params: Vec<String>,
    pub rows: Vec<BurnRow>,
    pub calls: Vec<(String, String, Vec<[u64; 2]>, u64)>,
}

/// Writes a TLA+ module with the provenance header (CONTRACTS C4) and the
/// tables.
pub fn emit_tla(
    module: &str,
    prov: &Provenance,
    wasms: &[(String, String, String, String)],
    tables: &[Table],
    command: &str,
    notes: &[String],
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
    let mut cl = String::from("  command:");
    for w in command.split(' ') {
        if cl.len() + 1 + w.len() > 72 {
            line(&mut o, &cl);
            cl = String::from("   ");
        }
        cl += " ";
        cl += w;
    }
    line(&mut o, &cl);
    line(&mut o, "");
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
    let mut call: Vec<String> = vec![];
    for (acct, m, acts, fee) in calls {
        let st: Vec<String> = acts.iter().map(|a| (a[0]).to_string()).collect();
        let wt: Vec<String> = acts.iter().map(|a| a[1].to_string()).collect();
        call.push(format!("    {} :> [st |-> <<{}>>, wt |-> <<{}>>, fee |-> {}]", kexpr(acct, m), st.join(", "), wt.join(", "), fee));
    }
    let _ = writeln!(o, "{prefix}GasCall{args} ==");
    if call.is_empty() {
        let _ = writeln!(o, "    [k \\in {{}} |-> [st |-> <<>>, wt |-> <<>>, fee |-> 0]]");
    } else {
        let _ = writeln!(o, "{}", call.join(" @@\n"));
    }
}
