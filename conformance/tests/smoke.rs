//! Smoke run of the conformance sweep: a handful of flows from
//! flows/probes.toml on the smoke grid (5-130 Tgas every 2.5, and 300),
//! nearcore's leftover split checked against the declared statics and
//! weights (0 mismatches), a few window edges on a 0.1 Tgas grid, and the
//! standard-token burns that modules/CalibStd.tla holds.
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
    "wrap_call",
    "wrap_withdraw",
    "wrap_batch_DSC",
];

fn resolved() -> Resolved {
    Resolved::new(&crate_dir().join("flows/probes.toml"), None)
}

fn run(res: &Resolved, base: &near_contract_sim::prelude::Sim, name: &str, g: &[u64]) -> Vec<Value> {
    let flow = res.spec.flows.iter().find(|f| f.name == name).unwrap_or_else(|| panic!("no flow {name}"));
    let w = res.flow_world(base, flow);
    let tx = flow.tx.clone();
    sweep(name, &w, g, &|sim, gas| spec::run(sim, &tx, Some(gas)), None)
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
    let rows = calib::burn_rows(&burns, &["ft".into(), "wrap".into()]);
    let burn = |acct: &str, key: &str| rows.iter().find(|r| r.acct == acct && r.key == key).map(|r| r.base);
    // As in modules/CalibStd.tla.
    assert_eq!(burn("ft", "ft_transfer_call"), Some(1587));
    assert_eq!(burn("ft", "ft_resolve_transfer"), Some(858));
    assert_eq!(burn("wrap", "ft_transfer_call"), Some(1588));
    assert_eq!(burn("wrap", "near_withdraw"), Some(582));
    assert_eq!(burn("wrap", "batch/DSC"), Some(2739));
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
    assert_eq!(edge_points(&res, &base, "wrap_batch_DSC", 430, 440), [43.0, 43.6]);
}
