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

/// near-contract-sim's rev: the commit of the tag pinned in `Cargo.toml`,
/// `v0.1.0` (checked against `Cargo.lock` by `provenance`).
pub const SIM_REV: &str = "96bc8fb6a390c22d93cfd3ac30dcc0337a98e1d2";

/// 1 Ggas, the model's gas unit.
pub const GGAS: u64 = 1_000_000_000;

/// The crate's directory. `cargo run` and `cargo test` set `CARGO_MANIFEST_DIR` at run time,
/// which wins over the compile-time value: a binary built in another checkout of the repo
/// (a shared `CARGO_TARGET_DIR` or build cache) would otherwise read and write that
/// checkout's `data/` and flows.
pub fn crate_dir() -> PathBuf {
    std::env::var_os("CARGO_MANIFEST_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")))
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

/// What every calibrated table and sweep records: the sim, nearcore and
/// protocol the numbers were measured on.
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
    dump_all(std::slice::from_ref(o))
}

/// `dump` of several transactions' outcomes (a flow's transaction, then its
/// `after` transactions): their receipts in that order, each with the index
/// of its transaction (`tx`); `tx_ok` is the first transaction's.
pub fn dump_all(os: &[TxOutcome]) -> Value {
    let mut parent: HashMap<String, String> = HashMap::new();
    for o in os {
        for r in o.transaction.iter().chain(&o.receipts) {
            for c in &r.receipt_ids {
                parent.insert(c.to_string(), r.receipt_id.to_string());
            }
        }
    }
    let rs: Vec<Value> = os
        .iter()
        .enumerate()
        .flat_map(|(t, o)| o.transaction.iter().map(move |r| (t, r, true)).chain(o.receipts.iter().map(move |r| (t, r, false))))
        .map(|(t, r, conv)| {
            let id = r.receipt_id.to_string();
            json!({
                "tx": t,
                "id": id,
                "parent": parent.get(&id),
                "conversion": conv,
                "receiver": r.receiver_id.as_str(),
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
    json!({ "tx_ok": os.first().is_some_and(|o| !o.is_failure()), "receipts": rs })
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

/// Writes `bytes` to `path` atomically: to a temp file beside it, unique to
/// this call (`<path>.<pid>.<n>.tmp`), then a rename, so a reader sees the
/// old file or the new one, never a prefix, and two writers never share a
/// temp file (the last rename wins, whole).
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".{}.{n}.tmp", std::process::id()));
    let tmp = PathBuf::from(tmp);
    let res = (|| {
        let mut f = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if res.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    res
}

/// An advisory lock on `<path without extension>.lock` (created if need
/// be, never removed), held until the returned file is dropped: exclusive
/// to publish a sweep's JSONL and meta as one pair, shared to read them.
pub fn lock_beside(path: &Path, exclusive: bool) -> std::io::Result<std::fs::File> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let f = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path.with_extension("lock"))?;
    if exclusive { f.lock()? } else { f.lock_shared()? }
    Ok(f)
}

/// Runs `tx` on a clone of `base` at every gas of `grid`, and returns one
/// JSON value per point (`dump_all` of the outcomes `tx` returns, plus
/// `flow`, `gas` and `yields`, the number of yields still parked once `tx`
/// has returned: `Sim::yields`). With `out`, it writes them as JSON lines
/// to `out` once the whole grid has run (`write_atomic`): an interrupted
/// sweep leaves the previous file whole.
pub fn sweep(
    flow: &str,
    base: &Sim,
    grid: &[u64],
    tx: &dyn Fn(&mut Sim, Gas) -> Vec<TxOutcome>,
    out: Option<&Path>,
) -> Vec<Value> {
    let mut lines = vec![];
    for &g in grid {
        let mut sim = base.clone();
        let os = tx(&mut sim, Gas::from_gas(g));
        let mut v = dump_all(&os);
        v["flow"] = json!(flow);
        v["gas"] = json!(g);
        // yields still parked once the point's last step has run
        v["yields"] = json!(sim.yields().len());
        lines.push(v);
    }
    if let Some(p) = out {
        write_atomic(p, jsonl(&lines).as_bytes()).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    }
    lines
}

/// `lines` as JSON lines (one per value, each ending in a newline).
pub fn jsonl(lines: &[Value]) -> String {
    let mut s = String::new();
    for v in lines {
        s.push_str(&v.to_string());
        s.push('\n');
    }
    s
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

#[cfg(test)]
mod tests {
    use super::*;

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        v.sort();
        v
    }

    #[test]
    fn write_atomic_replaces_whole_and_leaves_no_temp() {
        let dir = std::env::temp_dir().join(format!("near-tla-conf-{}-wa", std::process::id()));
        let p = dir.join("x.jsonl");
        write_atomic(&p, b"old\n").unwrap();
        write_atomic(&p, b"new 1\nnew 2\n").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"new 1\nnew 2\n");
        assert_eq!(names(&dir), ["x.jsonl"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Writers of one path never share a temp file: every write succeeds,
    /// and the file is always one writer's bytes, whole.
    #[test]
    fn write_atomic_concurrent_writers() {
        let dir = std::env::temp_dir().join(format!("near-tla-conf-{}-wac", std::process::id()));
        let p = dir.join("x.jsonl");
        let body = |t: usize| format!("{t}\n").repeat(20_000).into_bytes();
        std::thread::scope(|s| {
            for t in 0..8 {
                let (p, b) = (&p, body(t));
                s.spawn(move || {
                    for _ in 0..50 {
                        write_atomic(p, &b).unwrap();
                    }
                });
            }
        });
        let got = std::fs::read(&p).unwrap();
        assert!((0..8).any(|t| got == body(t)), "file is no writer's bytes whole");
        assert_eq!(names(&dir), ["x.jsonl"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn jsonl_one_line_per_value() {
        let s = jsonl(&[json!({"gas": 1}), json!({"gas": 2})]);
        assert_eq!(s, "{\"gas\":1}\n{\"gas\":2}\n");
    }
}
