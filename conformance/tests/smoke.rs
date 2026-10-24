//! Smoke run of the conformance sweep: a handful of flows from
//! flows/probes.toml on the smoke grid (5-130 Tgas every 2.5, and 300),
//! nearcore's leftover split checked against the declared statics and
//! weights (0 mismatches), a few window edges on a 0.1 Tgas grid, and the
//! standard-token burns that modules/CalibStd.tla holds; and the storage
//! bytes of flows/storage.toml that modules/StorStd.tla and
//! examples/storage-stake/StorKv.tla hold (`calibrate --stor`).
//!
//!   cargo test --release --test smoke -- --test-threads 1
//!
//! The full grid is `cargo run --release --bin calibrate -- --flows
//! flows/probes.toml` (README.md).
use near_tla_conformance::calib::{self, Burns, SplitReport};
use near_tla_conformance::spec::{self, Resolved};
use near_tla_conformance::{crate_dir, edges, grid, sweep};
use serde_json::Value;

const FLOWS: &[&str] = &[
    "chain1",
    "chain3w",
    "retc10000",
    "send_eth_new_cb",
    "send_named_missing_cb",
    "ft_call_return",
    "ft_call_panic",
    "wnear_call",
    "wnear_call_return",
    "wnear_withdraw",
    "wnear_batch_DSC",
    "ft_batch_C",
];

fn resolved() -> Resolved {
    Resolved::new(&crate_dir().join("flows/probes.toml"), None)
}

fn run(res: &Resolved, base: &near_contract_sim::prelude::Sim, name: &str, g: &[u64]) -> Vec<Value> {
    let flow = res.spec.flows.iter().find(|f| f.name == name).unwrap_or_else(|| panic!("no flow {name}"));
    let w = res.flow_world(base, flow);
    sweep(name, &w, g, &|sim, gas| spec::run_flow(sim, flow, gas), None)
}

#[test]
fn smoke_grid_split_and_burns() {
    let res = resolved();
    let base = res.world();
    let mut split = SplitReport::default();
    let mut burns = Burns::default();
    for name in FLOWS {
        let lines = run(&res, &base, name, &grid::smoke());
        assert_eq!(lines.len(), grid::smoke().len());
        let flow = res.spec.flows.iter().find(|f| f.name == *name).unwrap();
        calib::check_split(&res, flow, &lines, &mut split);
        calib::collect_burns(&base, &res, flow, &lines, &mut burns);
    }
    println!("split: {} children, {} mismatches, worst {} gas", split.children, split.mismatches, split.worst);
    assert!(split.children > 500, "{} children checked", split.children);
    assert_eq!(split.mismatches, 0, "{:?}", split.notes);
    assert!(split.errors.is_empty() && burns.errors.is_empty(), "{:?} {:?}", split.errors, burns.errors);
    assert_eq!(split.skipped_parents + split.unchecked, 0);
    assert!(split.multi_children > 0, "multi-call children checked per action");
    let (rows, _) = calib::burn_rows(&burns, &["ft_probe".into(), "wnear_probe".into()]);
    let burn = |acct: &str, key: &str| rows.iter().find(|r| r.acct == acct && r.key == key).map(|r| r.base);
    // As in modules/CalibStd.tla (burns rounded up to whole Ggas).
    // (1592 is the largest over all six ft_call flows; these two may give 1591)
    assert!(matches!(burn("ft_probe", "ft_transfer_call"), Some(1591..=1592)));
    assert_eq!(burn("ft_probe", "ft_resolve_transfer"), Some(859));
    assert_eq!(burn("ft_probe", "batch/C"), Some(1599));
    assert_eq!(burn("wnear_probe", "ft_transfer_call"), Some(1593));
    assert_eq!(burn("wnear_probe", "ft_resolve_transfer"), Some(867));
    assert_eq!(burn("wnear_probe", "near_withdraw"), Some(579));
    assert_eq!(burn("wnear_probe", "batch/DSC"), Some(2742));
    // path keys from the resolver's logs: it refunds (return) or not (keep)
    assert_eq!(burn("ft_probe", "ft_resolve_transfer/refund"), Some(859));
    assert_eq!(burn("wnear_probe", "ft_resolve_transfer/norefund"), Some(419));
    // the per-action check's inferred burn of the batch's last action
    let last = split.per_action.iter().find(|x| x.0 == "wnear_batch_DSC").map(|x| x.2.round() as u64);
    assert_eq!(last, Some(1558));
}

/// Action-only children with AddKey, CreateAccount and DeleteAccount
/// (flows/actions.toml): every send fee is priced, every exec fee from the
/// fee table matches the measured one.
#[test]
fn action_only_fees() {
    let res = Resolved::new(&crate_dir().join("flows/actions.toml"), None);
    let base = res.world();
    let mut burns = Burns::default();
    for flow in &res.spec.flows {
        let lines = run(&res, &base, &flow.name, &grid::smoke());
        calib::collect_burns(&base, &res, flow, &lines, &mut burns);
    }
    println!("{:#?}", burns.ao_checks);
    assert!(burns.errors.is_empty(), "{:?}", burns.errors);
    assert_eq!(burns.ao_checks.len(), 4);
    for (f, rx, got, want) in &burns.ao_checks {
        assert_eq!(got, want, "{f}: {rx}");
    }
}

/// Window edges (Tgas) where the flow's status vector changes, on a 0.1
/// Tgas grid around them; the first point of the range is always listed.
fn edge_points(res: &Resolved, base: &near_contract_sim::prelude::Sim, name: &str, lo10: u64, hi10: u64) -> Vec<f64> {
    edges(&run(res, base, name, &grid::range(lo10, hi10, 1))).into_iter().map(|(t, _)| t).collect()
}

#[test]
fn window_edges() {
    let res = resolved();
    let base = res.world();
    // ft_transfer_call: fails below burn + 2 child fees + the resolver's
    // 5 Tgas; the receiver runs out of gas below 8.8.
    assert_eq!(edge_points(&res, &base, "ft_call_return", 80, 92), [8.0, 8.4, 8.8]);
    assert_eq!(edge_points(&res, &base, "wnear_batch_DSC", 430, 440), [43.0, 43.6]);
}

/// Every flow of flows/storage.toml at every point of its grid: the
/// receipts' storage changes add up to view_account's, a key's bytes are
/// the same at every gas point, every sized key lies on a whole-byte line
/// at 3 or more sizes, and the lines are the ones the generated tables hold.
#[test]
fn storage_bytes_table() {
    let res = Resolved::new(&crate_dir().join("flows/storage.toml"), None);
    let base = res.world();
    let mut st = calib::Stor::default();
    for flow in &res.spec.flows {
        calib::measure_stor_flow(&res, &base, flow, &spec::parse_grid(&flow.grid), &mut st);
    }
    calib::finish_stor(&mut st);
    let (rows, errors, _) = calib::stor_rows(&st, &["ft_probe".into(), "wnear_probe".into()]);
    assert!(st.errors.is_empty() && errors.is_empty(), "{:?} {errors:?}", st.errors);
    let got: Vec<String> = rows.iter().map(|r| format!("{}.{} {} {}", r.acct, r.key, r.base, r.per)).collect();
    println!("{}", got.join("\n"));
    for want in [
        "p.put/new 40 1",
        "p.put/same 0 0",
        "ft_probe.storage_deposit/new 61 1",
        "ft_probe.storage_deposit/registered 0 0",
        "ft_probe.storage_unregister -61 -1",
        "ft_probe.ft_transfer 0 0",
        "wnear_probe.storage_deposit/new 61 1",
        "wnear_probe.near_deposit/new 61 1",
        "wnear_probe.near_deposit/registered 0 0",
        "wnear_probe.storage_unregister -61 -1",
        "wnear_probe.near_withdraw 0 0",
    ] {
        assert!(got.iter().any(|g| g == want), "{want} not in the table");
    }
    // the committed tables hold every row, with the same line
    let std = std::fs::read_to_string(crate_dir().join("../modules/StorStd.tla")).unwrap();
    let kv = std::fs::read_to_string(crate_dir().join("../examples/storage-stake/StorKv.tla")).unwrap();
    for r in &rows {
        let (text, param) = match r.acct.as_str() {
            "ft_probe" => (&std, "ft"),
            "wnear_probe" => (&std, "wnear"),
            _ => (&kv, "app"),
        };
        let line = format!("{param} \\o \".{}\" :> [base |-> {}, per |-> {}]", r.key, r.base, r.per);
        assert!(text.contains(&line), "{line} not in the committed table");
    }
}
