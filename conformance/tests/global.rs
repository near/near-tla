//! Global contracts (NEP-591), observed in the sim before the library
//! models them: DeployGlobalContract by code hash and by account id (what
//! it burns, its fees, when the code becomes usable), UseGlobalContract
//! (the identifier's storage bytes, a missing identifier), what users see
//! when the owner redeploys by account id, the 10 KB DeleteAccount rule
//! with a by-account identifier, and a callback that arrives after its
//! account's code changed. Each test prints what it observed;
//! `cargo test --test global -- --nocapture` shows it.
//!
//! nearcore references are at the pinned rev (README, "Pins"):
//! `runtime/runtime/src/global_contracts.rs` (action_deploy_global_contract
//! :25-63, use_global_contract :76-109, initiate_distribution :143-171,
//! apply_distribution_current_shard :191-246, check_and_update_nonce
//! :251-269), `runtime/runtime/src/lib.rs` (the FunctionCall arm resolves
//! the account's contract when the receipt runs, :684-700),
//! `runtime/runtime/src/actions.rs` (get_contract_storage_usage :426-440,
//! check_actor_permissions :755-812), `runtime/runtime/src/config.rs`
//! (send fees :171-191, exec fees :380-395),
//! `core/primitives-core/src/account.rs` (identifier_storage_usage
//! :182-188), `core/parameters/res/runtime_configs/77.yaml` (fees, the
//! 0.0001 N per byte burn).
//!
//! Every test runs on the existing probe wasms (`probes/res/`); none needs a
//! new probe.
use near_contract_sim::nearcore::near_parameters::ActionCosts;
use near_contract_sim::nearcore::near_primitives::action::DeleteAccountAction;
use near_contract_sim::prelude::*;
use near_contract_sim::{GlobalContractDeployMode, GlobalContractIdentifier, ReceiptOutcome};
use near_tla_conformance::probe_wasm;
use serde_json::json;

const ALICE: &str = "alice.near";
const Q: &str = "q-probe.near";
/// Publishes the global contracts; 8 bytes, so a by-account identifier
/// (8) differs from a by-hash one (32).
const OWNER: &str = "pub.near";

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

fn yocto(b: Balance) -> i128 {
    b.as_yoctonear() as i128
}

fn world() -> Sim {
    let (wasm, _) = probe_wasm("probe");
    Fixture::new().account(ALICE, near(1000)).account(OWNER, near(10_000)).contract(Q, wasm).build()
}

fn usage(sim: &Sim, id: &str) -> u64 {
    sim.account(id).unwrap().storage_usage
}

fn err(o: &TxOutcome) -> String {
    format!("{:?}", o.failure())
}

fn rerr(r: &ReceiptOutcome) -> String {
    format!("{:?}", r.failure())
}

fn by_hash(wasm: &[u8]) -> GlobalContractIdentifier {
    GlobalContractIdentifier::CodeHash(CryptoHash::hash_bytes(wasm))
}

fn by_owner() -> GlobalContractIdentifier {
    GlobalContractIdentifier::AccountId(OWNER.parse().unwrap())
}

fn publish(sim: &mut Sim, wasm: &[u8], mode: GlobalContractDeployMode) {
    sim.tx(OWNER, OWNER).deploy_global(wasm.to_vec(), mode).transact().assert_success();
}

fn use_global(sim: &mut Sim, id: &str, g: GlobalContractIdentifier) -> TxOutcome {
    sim.tx(id, id).use_global(g).transact()
}

fn mark(sim: &mut Sim, id: &str, tag: &str) -> TxOutcome {
    sim.call(ALICE, id, "mark").args_json(json!({ "tag": tag })).transact()
}

fn not_found(o: &TxOutcome) -> bool {
    err(o).contains("MethodNotFound")
}

/// The receipt the transaction's signer ran on itself (not a refund).
fn own(o: &TxOutcome, id: &str) -> ReceiptOutcome {
    o.receipts.iter().find(|r| r.receiver_id.as_str() == id && r.refund.is_none()).unwrap().clone()
}

fn ggas(g: u64) -> f64 {
    g as f64 / 1e9
}

/// (send, exec) of `c` for a self-signed receipt.
fn fee(sim: &Sim, c: ActionCosts) -> (u64, u64) {
    let f = sim.config.runtime_config().fees.fee(c);
    (f.send_fee(true).gas.as_gas(), f.exec_fee().gas.as_gas())
}

/// G1: DeployGlobalContract, by code hash and by account id. It burns
/// 0.0001 N per code byte (10x the storage rate), on top of gas, and adds
/// nothing to the owner's storage or code. The code becomes usable when
/// the distribution receipt the deploy emits runs, a block later: a
/// UseGlobalContract in the deploy's own batch fails, and the failed batch
/// burns gas only. Short of the burn it fails with LackBalanceForState
/// (gas only, too); only the account itself may deploy.
#[test]
fn deploy_global() {
    let (a, _) = probe_wasm("probe");
    let mut sim = world();
    let n = a.len() as u64;
    let burn = sim.global_storage_cost(n);
    assert_eq!(burn.as_yoctonear(), u128::from(n) * 10u128.pow(20), "0.0001 N per byte");
    assert_eq!(sim.storage_cost(1).as_yoctonear(), 10u128.pow(19), "the storage rate, for comparison");
    let none = sim.account(ALICE).unwrap().code_hash;

    for (what, mode, id) in [
        ("by hash", GlobalContractDeployMode::CodeHash, by_hash(&a)),
        ("by account", GlobalContractDeployMode::AccountId, by_owner()),
    ] {
        assert!(sim.global_contract_code(id.clone()).is_none());
        let (b0, u0) = (sim.balance(OWNER), usage(&sim, OWNER));
        let o = sim.tx(OWNER, OWNER).deploy_global(a.clone(), mode).transact();
        o.assert_success();
        for r in &o.receipts {
            println!(
                "  {what}: receipt on {} actions {:?} block {} burnt {:.3} Ggas",
                r.receiver_id,
                r.actions,
                r.block_height,
                ggas(r.gas_burnt.as_gas())
            );
        }
        let paid = yocto(b0) - yocto(sim.balance(OWNER));
        println!(
            "{what}: {n} bytes; owner paid {paid} yN = gas {} + burn {}; owner usage {u0} -> {}",
            yocto(o.effects().gas_paid()),
            yocto(burn),
            usage(&sim, OWNER)
        );
        assert_eq!(paid, yocto(o.effects().gas_paid()) + yocto(burn));
        assert_eq!(usage(&sim, OWNER), u0, "the owner stores nothing");
        assert_eq!(sim.account(OWNER).unwrap().code_hash, none, "the owner doesn't use it");
        assert_eq!(sim.global_contract_code(id), Some(a.clone()));

        // Gas: receipt + base + per byte, send at sir rates and exec.
        let send = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
        let exec = own(&o, OWNER).gas_burnt.as_gas();
        let (rs, re) = fee(&sim, ActionCosts::new_action_receipt);
        let (bs, be) = fee(&sim, ActionCosts::deploy_global_contract_base);
        let (ps, pe) = fee(&sim, ActionCosts::deploy_global_contract_byte);
        println!("  send {:.3} exec {:.3} Ggas", ggas(send), ggas(exec));
        assert_eq!((send, exec), (rs + bs + ps * n, re + be + pe * n));
    }
    let fees = &sim.config.runtime_config().fees;
    let g = |c: ActionCosts| {
        let f = fees.fee(c);
        [f.send_fee(true).gas.as_gas(), f.send_fee(false).gas.as_gas(), f.exec_fee().gas.as_gas()]
    };
    assert_eq!(g(ActionCosts::deploy_global_contract_base), [184_765_750_000; 3]);
    assert_eq!(g(ActionCosts::deploy_global_contract_byte), [6_812_999, 47_683_715, 70_000_000]);
    assert_eq!(g(ActionCosts::use_global_contract_base), [184_765_750_000; 3]);
    assert_eq!(g(ActionCosts::use_global_contract_byte), [6_812_999, 47_683_715, 64_572_944]);

    // The code shows up one block after the deploy runs.
    let (b, _) = probe_wasm("async_probe");
    let mut s = sim.clone();
    s.tx(OWNER, OWNER).deploy_global(b.clone(), GlobalContractDeployMode::AccountId).submit();
    s.step();
    let after_deploy = s.global_contract_code(by_owner()) == Some(a.clone());
    s.step();
    let after_next = s.global_contract_code(by_owner()) == Some(b.clone());
    println!(
        "redeploy by account: old code after the deploy's block {after_deploy}, new code a block later {after_next}"
    );
    assert!(after_deploy && after_next);

    // Deploy and use in one batch: not published yet.
    let b0 = sim.balance(OWNER);
    let o = sim
        .tx(OWNER, OWNER)
        .deploy_global(b.clone(), GlobalContractDeployMode::CodeHash)
        .use_global(by_hash(&b))
        .transact();
    println!("[DeployGlobal(hash), UseGlobal(hash)] in one batch: {}", err(&o));
    assert!(err(&o).contains("GlobalContractDoesNotExist"), "{o}");
    assert!(sim.global_contract_code(by_hash(&b)).is_none(), "the batch rolled back");
    let paid = yocto(b0) - yocto(sim.balance(OWNER));
    let bburn = yocto(sim.global_storage_cost(b.len() as u64));
    println!("  owner paid {paid} yN: gas {}, burn of {} bytes {bburn}", yocto(o.effects().gas_paid()), b.len());
    assert_eq!(paid, yocto(o.effects().gas_paid()), "a failed batch burns gas only, not the {bburn} yN");

    // Short of the burn.
    sim.create_account("poor.near", near(1));
    let p0 = sim.balance("poor.near");
    let o = sim.tx("poor.near", "poor.near").deploy_global(a.clone(), GlobalContractDeployMode::AccountId).transact();
    println!("poor.near (1 N) publishes {n} bytes: {}", err(&o));
    assert!(err(&o).contains("LackBalanceForState"), "{o}");
    let paid = yocto(p0) - yocto(sim.balance("poor.near"));
    println!("  poor.near paid {paid} yN, gas {}", yocto(o.effects().gas_paid()));
    assert_eq!(paid, yocto(o.effects().gas_paid()), "gas only");
    let poor = GlobalContractIdentifier::AccountId("poor.near".parse().unwrap());
    assert!(sim.global_contract_code(poor).is_none());

    // Only the account itself.
    let o = sim.tx(ALICE, OWNER).deploy_global(b.clone(), GlobalContractDeployMode::AccountId).transact();
    println!("alice deploys a global contract on {OWNER}: {}", err(&o));
    assert!(err(&o).contains("ActorNoPermission"), "{o}");
}

/// G2: UseGlobalContract adds the identifier's bytes to the account's
/// storage (32 by hash, the owner id's length by account), after taking
/// off what the old contract counted (a local code's length, or the old
/// identifier); a local deploy over a global one does the reverse. A
/// missing identifier fails with GlobalContractDoesNotExist. The account's
/// state survives each switch. Fees: receipt + base + per identifier byte.
#[test]
fn use_global_storage() {
    let (a, _) = probe_wasm("probe");
    let mut sim = world();
    publish(&mut sim, &a, GlobalContractDeployMode::CodeHash);
    publish(&mut sim, &a, GlobalContractDeployMode::AccountId);
    let u = "u.near";
    sim.create_account(u, near(100));
    let u0 = usage(&sim, u);
    let len = a.len() as u64;

    // `state`: what the marks below add; the rest is the contract's.
    let (mut prev, mut state) = (u0, 0);
    for (what, g, code) in [
        ("use by hash", Some(by_hash(&a)), 32),
        ("use by account", Some(by_owner()), OWNER.len() as u64),
        ("local deploy", None, len),
        ("use by hash", Some(by_hash(&a)), 32),
    ] {
        let o = match &g {
            Some(g) => use_global(&mut sim, u, g.clone()),
            None => sim.tx(u, u).deploy(a.clone()).transact(),
        };
        o.assert_success();
        println!("{what}: usage {prev} -> {} = plain {u0} + state {state} + contract {code}", usage(&sim, u));
        assert_eq!(usage(&sim, u), u0 + state + code);
        let before = usage(&sim, u);
        mark(&mut sim, u, what).assert_success();
        prev = usage(&sim, u);
        state += prev - before;
        if let Some(g) = g {
            let n = g.len() as u64;
            let send = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
            let exec = own(&o, u).gas_burnt.as_gas();
            let (rs, re) = fee(&sim, ActionCosts::new_action_receipt);
            let (bs, be) = fee(&sim, ActionCosts::use_global_contract_base);
            let (ps, pe) = fee(&sim, ActionCosts::use_global_contract_byte);
            println!("  identifier {n} bytes: send {:.3} exec {:.3} Ggas", ggas(send), ggas(exec));
            assert_eq!((send, exec), (rs + bs + ps * n, re + be + pe * n));
        }
    }
    let marks = sim.view(u, "marks", json!({})).json::<String>();
    println!("u's marks across the switches: {marks:?}");
    assert_eq!(marks, "use by hash,use by account,local deploy,use by hash,");

    let o = use_global(&mut sim, u, GlobalContractIdentifier::AccountId(ALICE.parse().unwrap()));
    println!("use by account {ALICE} (never published): {}", err(&o));
    assert!(err(&o).contains("GlobalContractDoesNotExist"), "{o}");
    assert_eq!(usage(&sim, u), prev);
}

/// G3: a by-account global contract is resolved when each receipt runs, so
/// the owner's redeploy changes every by-account user at once; a by-hash
/// user keeps its code. Users' state and storage stay. The owner's deletion
/// leaves the code in place for its users; an owner created again under the
/// same id updates them. Two deploys whose receipts run in one block: the
/// later one wins.
#[test]
fn redeploy_updates_users() {
    let (a, _) = probe_wasm("probe");
    let (b, _) = probe_wasm("async_probe");
    let mut sim = world();
    publish(&mut sim, &a, GlobalContractDeployMode::CodeHash);
    publish(&mut sim, &a, GlobalContractDeployMode::AccountId);
    let users = ["u1.near", "u2.near"];
    let h = "h.near";
    for u in users {
        sim.create_account(u, near(100));
        use_global(&mut sim, u, by_owner()).assert_success();
    }
    sim.create_account(h, near(100));
    use_global(&mut sim, h, by_hash(&a)).assert_success();
    for x in users.iter().chain([&h]) {
        mark(&mut sim, x, "before").assert_success();
    }
    let usages: Vec<u64> = users.iter().map(|u| usage(&sim, u)).collect();

    publish(&mut sim, &b, GlobalContractDeployMode::AccountId);
    for u in users {
        let o = mark(&mut sim, u, "after");
        println!("{u} (by account) after the owner redeploys: {}", err(&o));
        assert!(not_found(&o), "{o}");
    }
    let o = mark(&mut sim, h, "after");
    println!("{h} (by hash) after the redeploy: {}", err(&o));
    o.assert_success();
    assert_eq!(users.iter().map(|u| usage(&sim, u)).collect::<Vec<_>>(), usages);

    publish(&mut sim, &a, GlobalContractDeployMode::AccountId);
    let marks = sim.view(users[0], "marks", json!({})).json::<String>();
    println!("{} after the owner deploys the probe again: marks {marks:?}", users[0]);
    assert_eq!(marks, "before,");

    // The owner deletes itself: users keep the code.
    let mut d = sim.clone();
    let del = DeleteAccountAction { beneficiary_id: ALICE.parse().unwrap() };
    d.tx(OWNER, OWNER).action(del).transact().assert_success();
    assert!(d.account(OWNER).is_none());
    let o = mark(&mut d, users[0], "orphan");
    println!("{} after the owner's deletion: {}", users[0], err(&o));
    o.assert_success();
    assert_eq!(d.global_contract_code(by_owner()), Some(a.clone()));
    d.create_account(OWNER, near(10_000));
    publish(&mut d, &b, GlobalContractDeployMode::AccountId);
    let o = mark(&mut d, users[0], "reborn");
    println!("{} after the owner is created again and deploys async_probe: {}", users[0], err(&o));
    assert!(not_found(&o), "{o}");

    // Two deploys whose receipts run in one block: b then a; a wins.
    let mut t = sim.clone();
    let t1 = t.tx(OWNER, OWNER).deploy_global(b.clone(), GlobalContractDeployMode::AccountId).submit();
    let t2 = t.tx(OWNER, OWNER).deploy_global(a.clone(), GlobalContractDeployMode::AccountId).submit();
    t.settle();
    let ran = |h: CryptoHash| own(&t.outcome(h), OWNER).block_height;
    println!("two deploys by account: their receipts ran in blocks {} and {}", ran(t1), ran(t2));
    assert_eq!(ran(t1), ran(t2));
    let won = if t.global_contract_code(by_owner()) == Some(a.clone()) { "the later (probe)" } else { "the earlier" };
    println!("two deploys by account in one block: {won} wins");
    assert_eq!(t.global_contract_code(by_owner()), Some(a.clone()));
}

/// G4: the 10 KB DeleteAccount rule takes off a by-account identifier's
/// bytes (the owner id's length), as it does a by-hash one's 32
/// (`lifecycle.rs`, delete_large_state). 10,000 passes, 10,001 fails.
#[test]
fn delete_large_state_by_account() {
    let (a, _) = probe_wasm("probe");
    let mut base = world();
    publish(&mut base, &a, GlobalContractDeployMode::AccountId);
    let u = "u.near";
    base.create_account(u, near(100));
    use_global(&mut base, u, by_owner()).assert_success();
    let minus = OWNER.len() as u64;
    println!("{u} uses {} bytes, {minus} of them the identifier", usage(&base, u));
    for (target, ok) in [(10_000u64, true), (10_001, false)] {
        let mut sim = base.clone();
        let now = usage(&sim, u) - minus;
        let value = target - now - 40 - 1;
        sim.set_state(u, b"k", Some(&vec![b'x'; value as usize]));
        let used = usage(&sim, u);
        let del = DeleteAccountAction { beneficiary_id: ALICE.parse().unwrap() };
        let o = sim.tx(u, u).action(del).transact();
        println!("  usage {used} (minus the identifier: {}): {}", used - minus, err(&o));
        if ok {
            o.assert_success();
            assert!(sim.account(u).is_none());
        } else {
            assert!(err(&o).contains("DeleteAccountWithLargeState"), "{o}");
        }
    }
}

/// u.chain([q.mark], then u.mark), with the callback held so it arrives
/// after the code change.
fn held_chain(sim: &mut Sim, u: &str) -> CryptoHash {
    let kids =
        json!([{ "receiver": Q, "method": "mark", "args": "{\"tag\":\"k\"}", "static_ggas": 10000, "weight": 1 }]);
    let cb = json!({ "method": "mark", "args": "{\"tag\":\"cb\"}", "static_ggas": 10000, "weight": 1 });
    let tx = sim
        .call(ALICE, u, "chain")
        .args_json(json!({ "kids": kids, "cb": cb }))
        .inject(Receipts::callback("mark"), Fault::Hold(12))
        .submit();
    sim.run_until(10, |s| s.outcome(tx).receipts.iter().any(|r| r.receiver_id.as_str() == Q)).unwrap();
    tx
}

fn cb_of(sim: &Sim, tx: CryptoHash, u: &str) -> Option<ReceiptOutcome> {
    sim.outcome(tx).receipts.into_iter().find(|r| r.receiver_id.as_str() == u && r.method_names == ["mark"])
}

/// G5: a callback runs the code its account has when the callback runs,
/// not the code that made the promise. With u.chain's callback in flight,
/// the owner's by-account redeploy (to async_probe, which has no `mark`)
/// fails the callback with MethodNotFound; a by-hash user's callback runs
/// the probe; a local redeploy on the account does what the by-account
/// update does. The same holds for a yield: its callback, run at timeout
/// after a by-account update, finds the new code.
#[test]
fn update_while_callback_in_flight() {
    let (a, _) = probe_wasm("probe");
    let (b, _) = probe_wasm("async_probe");
    let mut sim = world();
    publish(&mut sim, &a, GlobalContractDeployMode::CodeHash);
    publish(&mut sim, &a, GlobalContractDeployMode::AccountId);
    let (ua, uh, ul) = ("ua.near", "uh.near", "ul.near");
    for (u, g) in [(ua, by_owner()), (uh, by_hash(&a))] {
        sim.create_account(u, near(100));
        use_global(&mut sim, u, g).assert_success();
    }
    sim.deploy(ul, a.clone());

    for (what, u) in [("by account", ua), ("by hash", uh), ("local", ul)] {
        let mut s = sim.clone();
        let tx = held_chain(&mut s, u);
        s.step();
        assert!(cb_of(&s, tx, u).is_none(), "the callback is held");
        let h0 = s.height();
        if u == ul {
            s.tx(ul, ul).deploy(b.clone()).transact().assert_success();
        } else {
            publish(&mut s, &b, GlobalContractDeployMode::AccountId);
        }
        s.settle();
        let cb = cb_of(&s, tx, u).expect("the callback ran");
        println!("{what} user {u}: code changed after #{h0}, callback ran at #{}: {}", cb.block_height, rerr(&cb));
        if u == uh {
            assert!(cb.is_success(), "{}", rerr(&cb));
        } else {
            assert!(rerr(&cb).contains("MethodNotFound"), "{}", rerr(&cb));
        }
    }

    // A yield parked under async_probe, timed out under the probe.
    let mut s = world();
    publish(&mut s, &b, GlobalContractDeployMode::AccountId);
    let y = "y.near";
    s.create_account(y, near(100));
    use_global(&mut s, y, by_owner()).assert_success();
    let o = s.call(ALICE, y, "yield_create").args_json(json!({ "cb_ggas": 5000, "cb_weight": 1 })).transact();
    o.assert_success();
    let p = s.yields().into_iter().next().expect("parked");
    publish(&mut s, &a, GlobalContractDeployMode::AccountId);
    let o = s.expire(&p);
    let cb = o.receipts.iter().find(|r| r.method_names == ["on_yield"]).expect("the yield callback ran");
    println!("yield parked under async_probe, timed out after the update to the probe: {}", rerr(cb));
    assert!(rerr(cb).contains("MethodNotFound"), "{}", rerr(cb));
}
