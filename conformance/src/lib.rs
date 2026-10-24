//! near-tla conformance: runs the probe contracts in near-contract-sim
//! (nearcore's own `Runtime::apply`), dumps every receipt of a transaction
//! at each point of a prepaid-gas grid, and supplies what the calibration
//! tool and the sweeps share.
//!
//! The JSONL schema `dump` writes is documented in `README.md`.
pub mod calib;
pub mod spec;

use near_contract_sim::nearcore::near_parameters::{transfer_exec_fee, transfer_send_fee};
use near_contract_sim::prelude::*;
use near_contract_sim::{Failure, ReceiptOutcome, TxOutcome};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// near-contract-sim's rev, as pinned in `Cargo.toml` (checked against
/// `Cargo.lock` by `provenance`).
pub const SIM_REV: &str = "29e909033bb59eab792dee136e9d02870488bc3e";

/// 1 Ggas, the model's gas unit.
pub const GGAS: u64 = 1_000_000_000;

pub fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// A probe's wasm from `probes/res/`, its sha256 checked against
/// `probes/res/SHA256SUMS` so a stale or foreign file can't pass silently.
pub fn probe_wasm(name: &str) -> (Vec<u8>, String) {
    let dir = crate_dir().join("probes/res");
    let file = format!("{name}.wasm");
    let wasm = std::fs::read(dir.join(&file))
        .unwrap_or_else(|e| panic!("probes/res/{file}: {e}: run probes/build.sh"));
    let sums = std::fs::read_to_string(dir.join("SHA256SUMS")).expect("probes/res/SHA256SUMS");
    let want = sums
        .lines()
        .find(|l| l.split_whitespace().nth(1) == Some(file.as_str()))
        .unwrap_or_else(|| panic!("{file} is not in probes/res/SHA256SUMS"))
        .split_whitespace()
        .next()
        .unwrap()
        .to_owned();
    let got = sha256_hex(&wasm);
    assert_eq!(got, want, "probes/res/{file}: sha256 differs from SHA256SUMS (rebuild with probes/build.sh)");
    (wasm, got)
}

/// What every calibrated table and sweep records (CONTRACTS C4).
#[derive(Clone, Debug, serde::Serialize)]
pub struct Provenance {
    pub sim_rev: String,
    pub nearcore_tag: String,
    pub nearcore_rev: String,
    pub protocol_version: u32,
}

/// The sim rev and the nearcore tag and commit it was built against (read
/// from this crate's `Cargo.lock`), and the protocol version `sim` runs.
pub fn provenance(sim: &Sim) -> Provenance {
    let lock = include_str!("../Cargo.lock");
    let mut sim_rev = String::new();
    let (mut tag, mut rev) = (String::new(), String::new());
    for l in lock.lines() {
        let Some(src) = l.strip_prefix("source = \"") else { continue };
        let src = src.trim_end_matches('"');
        if src.starts_with("git+https://github.com/near/near-contract-sim") {
            sim_rev = src.rsplit('#').next().unwrap_or("").to_owned();
        }
        if src.starts_with("git+https://github.com/near/nearcore") && tag.is_empty() {
            tag = src.split("tag=").nth(1).and_then(|s| s.split('#').next()).unwrap_or("").to_owned();
            rev = src.rsplit('#').next().unwrap_or("").to_owned();
        }
    }
    assert!(sim_rev.starts_with(SIM_REV), "Cargo.lock pins near-contract-sim {sim_rev}, not {SIM_REV}");
    Provenance { sim_rev, nearcore_tag: tag, nearcore_rev: rev, protocol_version: sim.config.protocol_version }
}

/// Send and exec fee (gas) of a Transfer action to `receiver`, by its
/// account type, as `promise_batch_action_transfer` charges them
/// (near-vm-runner `logic/host.rs`, `transfer_send_fee` /
/// `transfer_exec_fee` in near-parameters `cost.rs`).
pub fn transfer_fees(sim: &Sim, sir: bool, receiver: &str) -> (u64, u64) {
    let rc = sim.config.runtime_config();
    let id: AccountId = receiver.parse().unwrap();
    let w = &rc.wasm_config;
    let s = transfer_send_fee(&rc.fees, sir, w.eth_implicit_accounts, w.universal_accounts, id.get_account_type());
    let e = transfer_exec_fee(&rc.fees, w.eth_implicit_accounts, w.universal_accounts, id.get_account_type());
    (s.gas.as_gas(), e.gas.as_gas())
}

/// Send and exec fee of a new action receipt (`action_receipt_creation`).
pub fn receipt_fees(sim: &Sim, sir: bool) -> (u64, u64) {
    use near_contract_sim::nearcore::near_parameters::ActionCosts;
    let f = sim.config.runtime_config().fees.fee(ActionCosts::new_action_receipt);
    (f.send_fee(sir).gas.as_gas(), f.exec_fee().gas.as_gas())
}

/// "ok" | "oog" | "failed".
pub fn status(r: &ReceiptOutcome) -> &'static str {
    match r.failure() {
        None => "ok",
        Some(Failure::OutOfGas) => "oog",
        Some(_) => "failed",
    }
}

/// Every receipt of the outcome, the conversion first, refunds included,
/// as JSON values (schema in README.md).
pub fn dump(o: &TxOutcome) -> Value {
    let mut parent: HashMap<String, String> = HashMap::new();
    for r in o.transaction.iter().chain(&o.receipts) {
        for c in &r.receipt_ids {
            parent.insert(c.to_string(), r.id.to_string());
        }
    }
    let rs: Vec<Value> = o
        .transaction
        .iter()
        .map(|r| (r, true))
        .chain(o.receipts.iter().map(|r| (r, false)))
        .map(|(r, conv)| {
            let id = r.id.to_string();
            json!({
                "id": id,
                "parent": parent.get(&id),
                "conversion": conv,
                "receiver": r.executor_id.as_str(),
                "predecessor": r.predecessor_id.as_str(),
                "methods": r.method_names,
                "actions": r.actions,
                "args": r.args.first().filter(|a| a.len() <= 512).map(|a| String::from_utf8_lossy(a).into_owned()),
                "refund": r.refund.as_ref().map(|x| format!("{x:?}")),
                "callback": r.is_callback(),
                "attached": r.attached_gas.as_gas(),
                "burnt": r.gas_burnt.as_gas(),
                "exec_fees": r.prepaid_exec_fees.as_gas(),
                "deposit": r.deposit.as_yoctonear().to_string(),
                "status": status(r),
                "fail": r.failure().map(|f| format!("{f:?}")),
                "result_size": r.value().map(|v| v.len()),
                "result": r.value().filter(|v| v.len() <= 64).map(|v| String::from_utf8_lossy(v).into_owned()),
                "logs": r.logs,
                "block": r.block_height,
            })
        })
        .collect();
    json!({ "tx_ok": !o.is_failure(), "receipts": rs })
}

/// Prepaid-gas grids, in gas.
pub mod grid {
    /// 0.5-130.0 Tgas in 0.1 steps, then 140-300 in steps of 10 (1313 points).
    pub fn standard() -> Vec<u64> {
        range(5, 1300, 1).into_iter().chain((14..=30u64).map(|t| t * 10_000_000_000_000)).collect()
    }
    /// `lo10..=hi10` tenths of a Tgas, every `step10` tenths.
    pub fn range(lo10: u64, hi10: u64, step10: u64) -> Vec<u64> {
        (lo10..=hi10).step_by(step10 as usize).map(|t| t * 100_000_000_000).collect()
    }
    /// The smoke grid: 5-130 Tgas every 2.5, and 300 (52 points).
    pub fn smoke() -> Vec<u64> {
        let mut g = range(50, 1300, 25);
        g.push(300_000_000_000_000);
        g
    }
}

/// Runs `tx` on a clone of `base` at every gas of `grid`, writing one JSON
/// line per point (`dump` plus `flow` and `gas`) to `out`. Returns the
/// lines.
pub fn sweep(
    flow: &str,
    base: &Sim,
    grid: &[u64],
    tx: &dyn Fn(&mut Sim, Gas) -> TxOutcome,
    out: Option<&Path>,
) -> Vec<Value> {
    let mut f = out.map(|p| {
        if let Some(d) = p.parent() {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::File::create(p).unwrap()
    });
    let mut lines = vec![];
    for &g in grid {
        let mut sim = base.clone();
        let o = tx(&mut sim, Gas::from_gas(g));
        let mut v = dump(&o);
        v["flow"] = json!(flow);
        v["gas"] = json!(g);
        if let Some(f) = f.as_mut() {
            writeln!(f, "{v}").unwrap();
        }
        lines.push(v);
    }
    lines
}

/// The status vector of one point: each non-refund, non-conversion
/// receipt as `receiver::methods=status` (or `receiver[actions]=status`),
/// sorted. A change in it between grid points is an edge.
pub fn shape(v: &Value) -> String {
    let mut s: Vec<String> = v["receipts"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["refund"].is_null() && !r["conversion"].as_bool().unwrap())
        .map(|r| {
            let m: Vec<&str> = r["methods"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
            let a: Vec<&str> = r["actions"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
            let name = if m.is_empty() { format!("{}[{}]", r["receiver"].as_str().unwrap(), a.join(",")) } else { format!("{}::{}", r["receiver"].as_str().unwrap(), m.join("+")) };
            format!("{name}={}", r["status"].as_str().unwrap())
        })
        .collect();
    s.sort();
    s.join(" ")
}

/// Grid points (Tgas) where the status vector changes, with the new vector.
pub fn edges(lines: &[Value]) -> Vec<(f64, String)> {
    let mut out = vec![];
    let mut last = String::new();
    for v in lines {
        let s = shape(v);
        if s != last {
            out.push((v["gas"].as_u64().unwrap() as f64 / 1e12, s.clone()));
            last = s;
        }
    }
    out
}
