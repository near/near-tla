//! Receipt semantics the library encodes, observed in the sim on the probe
//! contract: local-receipt priority (CONTRACTS D2), signer propagation
//! (D1) and the atomicity of a `[DeleteKey, FunctionCall]` receipt.
//! `cargo test --test semantics -- --nocapture` prints what was observed.
use near_contract_sim::prelude::*;
use near_contract_sim::{AccessKey, TxOutcome};
use near_tla_conformance::probe_wasm;
use serde_json::{Value, json};

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const P: &str = "p.near";
const Q: &str = "q.near";

fn world() -> Sim {
    let (wasm, _) = probe_wasm("probe");
    Fixture::new()
        .account(ALICE, Balance::from_near(100))
        .account(BOB, Balance::from_near(100))
        .contract(P, wasm.clone())
        .contract(Q, wasm)
        .build()
}

fn marks(sim: &Sim) -> String {
    sim.view(P, "marks", json!({})).json::<String>()
}

fn mark<'a>(sim: &'a mut Sim, signer: &str, tag: &str) -> Tx<'a> {
    sim.call(signer, P, "mark").args_json(json!({ "tag": tag }))
}

/// D2: a transaction whose signer is its receiver becomes a local receipt
/// and runs in the block that converts it, before the incoming receipts of
/// that block (runtime/runtime/src/lib.rs, `process_receipts`). A receipt
/// a contract sends to itself is not local.
#[test]
fn local_receipt_runs_before_incoming() {
    let mut sim = world();
    // Block h converts alice's call; its receipt arrives at h + 1.
    let a = mark(&mut sim, ALICE, "a").submit();
    sim.step();
    // Block h + 1 converts p's own call (local) and runs alice's receipt.
    let p = mark(&mut sim, P, "p").submit();
    sim.step();
    sim.settle();
    let (oa, op) = (sim.outcome(a), sim.outcome(p));
    let ha = oa.receipts.iter().find(|r| r.method_names == ["mark"]).unwrap().block_height;
    let hp = op.receipts.iter().find(|r| r.method_names == ["mark"]).unwrap().block_height;
    println!("D2 local: alice's mark ran at #{ha}, p's self-signed mark at #{hp}; marks = {}", marks(&sim));
    assert_eq!(ha, hp, "both run in the same block");
    assert_eq!(marks(&sim), "p,a,", "the local receipt runs first");
}

#[test]
fn contract_self_call_is_not_local() {
    let mut sim = world();
    // p.chain (run at h + 1) sends p.mark("c") to itself (runs at h + 2).
    let kids = json!([{ "method": "mark", "args": "{\"tag\":\"c\"}", "static_ggas": 10000, "weight": 1 }]);
    let c = sim.call(ALICE, P, "chain").args_json(json!({ "kids": kids })).submit();
    sim.step();
    // bob's call converted at h + 1 also arrives at h + 2.
    let b = mark(&mut sim, BOB, "b").submit();
    sim.step();
    // p's own call, converted at h + 2: local.
    let p = mark(&mut sim, P, "p").submit();
    sim.step();
    sim.settle();
    let h = |o: &TxOutcome| o.receipts.iter().find(|r| r.method_names == ["mark"]).unwrap().block_height;
    let (hc, hb, hp) = (h(&sim.outcome(c)), h(&sim.outcome(b)), h(&sim.outcome(p)));
    println!("D2 self-call: chain's self-call mark at #{hc}, bob's at #{hb}, p's self-signed at #{hp}; marks = {}", marks(&sim));
    assert_eq!((hc, hb), (hp, hp), "all three run in one block");
    assert!(marks(&sim).starts_with("p,"), "only the transaction's own receipt is local");
}

fn records(o: &TxOutcome) -> Vec<Value> {
    o.receipts
        .iter()
        .flat_map(|r| r.logs.iter())
        .filter_map(|l| l.strip_prefix("record "))
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// D1: every receipt of a transaction sees its signer and signer key,
/// callbacks and cross-contract children included; the predecessor is the
/// immediate creator.
#[test]
fn signer_propagates_to_children_and_callbacks() {
    let mut sim = world();
    let pk = sim.secret_key(ALICE).public_key().to_string();
    let kids = json!([{ "receiver": Q, "method": "record", "args": "{\"tag\":\"child\"}", "static_ggas": 10000, "weight": 1 }]);
    let cb = json!({ "method": "record", "args": "{\"tag\":\"cb\"}", "static_ggas": 10000, "weight": 1 });
    let o = sim.call(ALICE, P, "chain").args_json(json!({ "kids": kids, "cb": cb })).transact();
    o.assert_success();
    let rs = records(&o);
    println!("D1 records: {rs:?}");
    assert_eq!(rs.len(), 2);
    for r in &rs {
        assert_eq!(r["signer"], ALICE);
        assert_eq!(r["signer_pk"], pk.as_str());
        assert_eq!(r["predecessor"], P);
    }
    assert_eq!(rs[0]["current"], Q);
    assert_eq!(rs[1]["current"], P);
}

fn key(seed: &str) -> PublicKey {
    SecretKey::from_seed(KeyType::ED25519, seed).public_key()
}

fn with_key(sim: &mut Sim, seed: &str) -> PublicKey {
    let k = key(seed);
    sim.tx(P, P).add_key(k.clone(), AccessKey::full_access()).transact().assert_success();
    k
}

fn get(sim: &Sim, k: &str) -> Option<String> {
    sim.view(P, "get", json!({ "key": k })).json::<Option<String>>()
}

/// A receipt's actions are atomic: if any action fails, none of its
/// effects stay (key deletions and the call's state writes alike).
#[test]
fn delete_key_batch_is_atomic() {
    let mut sim = world();
    let put = |k: &str| serde_json::to_vec(&json!({ "key": k, "value": "1" })).unwrap();

    // [DeleteKey(present), put(x)]: both happen.
    let k1 = with_key(&mut sim, "k1");
    let o = sim.tx(P, P).delete_key(k1.clone()).call("put").args(put("x")).transact();
    println!("DeleteKey(present)+put: {:?}", o.failure());
    o.assert_success();
    assert!(sim.access_key(P, &k1).is_none());
    assert_eq!(get(&sim, "x").as_deref(), Some("1"));

    // [DeleteKey(absent), put(y)]: the receipt fails; put never runs.
    let o = sim.tx(P, P).delete_key(key("absent")).call("put").args(put("y")).transact();
    println!("DeleteKey(absent)+put: {:?}", o.failure());
    assert!(o.is_failure());
    assert_eq!(get(&sim, "y"), None);

    // [put(z), DeleteKey(absent)]: put ran, then the receipt failed: z reverted.
    let o = sim.tx(P, P).call("put").args(put("z")).delete_key(key("absent")).transact();
    println!("put+DeleteKey(absent): {:?}", o.failure());
    assert!(o.is_failure());
    assert_eq!(get(&sim, "z"), None);

    // [DeleteKey(present), fail(w)]: the call panics: the key stays, w reverted.
    let k2 = with_key(&mut sim, "k2");
    let o = sim.tx(P, P).delete_key(k2.clone()).call("fail").args(serde_json::to_vec(&json!({ "key": "w" })).unwrap()).transact();
    println!("DeleteKey(present)+fail: {:?}", o.failure());
    assert!(o.is_failure());
    assert!(sim.access_key(P, &k2).is_some());
    assert_eq!(get(&sim, "w"), None);

    // The same batches created by a contract (p.batch_self -> one receipt to p).
    let o = sim.call(ALICE, P, "batch_self").args_json(json!({ "pk": key("absent").to_string(), "key": "v" })).transact();
    let child = o.receipts.iter().find(|r| r.actions.len() == 2).unwrap();
    println!("contract batch DeleteKey(absent)+put: {:?}", child.failure());
    assert!(child.failure().is_some());
    assert_eq!(get(&sim, "v"), None);
    let k3 = with_key(&mut sim, "k3");
    let o = sim.call(ALICE, P, "batch_self").args_json(json!({ "pk": k3.to_string(), "key": "u", "fail": true })).transact();
    let child = o.receipts.iter().find(|r| r.actions.len() == 2).unwrap();
    println!("contract batch DeleteKey(present)+fail: {:?}", child.failure());
    assert!(child.failure().is_some());
    assert!(sim.access_key(P, &k3).is_some());
    assert_eq!(get(&sim, "u"), None);
    let o = sim.call(ALICE, P, "batch_self").args_json(json!({ "pk": k3.to_string(), "key": "t" })).transact();
    assert!(o.receipts.iter().all(|r| r.failure().is_none()), "{o}");
    assert!(sim.access_key(P, &k3).is_none());
    assert_eq!(get(&sim, "t").as_deref(), Some("1"));
}
