//! The standard fungible token (NEP-141, NEP-145) on the ft probe, a plain
//! near-contract-standards 5.29.1 `FungibleToken`, observed in the sim for
//! the docs/SEMANTICS.md rules the conformance comparison cannot see (it
//! sees no balances, panics or refunds): `ft_transfer` and
//! `ft_transfer_call`'s requirements (T1), `ft_resolve_transfer`'s refund
//! arithmetic, its 42-byte bound and its burn (T2), and NEP-145 storage
//! management (T4). Each test prints what it observed; `cargo test --test
//! tokens -- --nocapture` shows it.
//!
//! These are near-contract-standards rules, not nearcore's: the references
//! are its 5.29.1 source (`src/fungible_token/core_impl.rs`,
//! `src/fungible_token/storage_impl.rs`) and near-sdk 5.29.1
//! (`src/utils/mod.rs:84-89`, `assert_one_yocto`). Every test runs on the
//! existing probe wasms (`probes/res/`); none needs a new probe.
use near_contract_sim::prelude::*;
use near_contract_sim::{ReceiptOutcome, Token};
use near_tla_conformance::probe_wasm;
use serde_json::{Value, json};

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const CAROL: &str = "carol.near";
const DAVE: &str = "dave.near";
const ERIN: &str = "erin.near";
const P: &str = "p-probe.near";
const FT: &str = "ft-probe.near";
const SUPPLY: u128 = 1_000_000;

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

/// alice holds the supply; bob and p are registered; carol, dave and erin
/// are not.
fn world() -> Sim {
    let (probe, _) = probe_wasm("probe");
    let (ft, _) = probe_wasm("ft");
    let mut fx = Fixture::new();
    for a in [ALICE, BOB, CAROL, DAVE, ERIN] {
        fx = fx.account(a, near(100));
    }
    fx.contract(P, probe)
        .contract(FT, ft)
        .init("new").args_json(json!({ "owner_id": ALICE, "total_supply": SUPPLY.to_string() }))
        .ft_register(FT, [BOB, P])
        .token(Token::nep141(FT))
        .build()
}

fn bal(sim: &Sim, who: &str) -> u128 {
    sim.view(FT, "ft_balance_of", json!({ "account_id": who })).json::<String>().parse().unwrap()
}

fn supply(sim: &Sim) -> u128 {
    sim.view(FT, "ft_total_supply", json!({})).json::<String>().parse().unwrap()
}

fn err(o: &TxOutcome) -> String {
    format!("{:?}", o.failure())
}

fn panics(o: &TxOutcome, msg: &str) -> bool {
    o.failure() == Some(Failure::Panic(msg.to_string()))
}

fn transfer<'a>(sim: &'a mut Sim, from: &str, to: &str, amount: u128, yocto: u128) -> Tx<'a> {
    sim.call(from, FT, "ft_transfer")
        .args_json(json!({ "receiver_id": to, "amount": amount.to_string() }))
        .deposit(Balance::from_yoctonear(yocto))
}

/// T1. `ft_transfer` and `ft_transfer_call` need exactly 1 yocto
/// (core_impl.rs:123, :136); `internal_transfer` panics on sender =
/// receiver, a zero amount (:101-102), an unregistered side (:59-66) and a
/// short balance (:81-91). `ft_transfer_call` then calls the receiver's
/// `ft_on_transfer` and the resolver after it, and returns the resolver's
/// value (:129-155).
#[test]
fn ft_transfer_requirements() {
    let mut sim = world();
    let one = "Requires attached deposit of exactly 1 yoctoNEAR";
    for (what, o, msg) in [
        ("no deposit", transfer(&mut sim, ALICE, BOB, 10, 0).transact(), one.to_string()),
        ("2 yocto", transfer(&mut sim, ALICE, BOB, 10, 2).transact(), one.to_string()),
        ("to itself", transfer(&mut sim, ALICE, ALICE, 10, 1).transact(), "Sender and receiver should be different".into()),
        ("amount 0", transfer(&mut sim, ALICE, BOB, 0, 1).transact(), "The amount should be a positive number".into()),
        ("to unregistered carol", transfer(&mut sim, ALICE, CAROL, 10, 1).transact(), format!("The account {CAROL} is not registered")),
        ("from unregistered carol", transfer(&mut sim, CAROL, BOB, 10, 1).transact(), format!("The account {CAROL} is not registered")),
        ("bob, holding 0", transfer(&mut sim, BOB, ALICE, 1, 1).transact(), "The account doesn't have enough balance".into()),
    ] {
        println!("ft_transfer {what}: {}", err(&o));
        assert!(panics(&o, &msg), "{o}");
    }
    assert_eq!((bal(&sim, ALICE), bal(&sim, BOB)), (SUPPLY, 0));
    transfer(&mut sim, ALICE, BOB, 10, 1).transact().assert_success();
    assert_eq!((bal(&sim, ALICE), bal(&sim, BOB)), (SUPPLY - 10, 10));

    let call = |sim: &mut Sim, yocto: u128| {
        sim.call(ALICE, FT, "ft_transfer_call")
            .args_json(json!({ "receiver_id": P, "amount": "7", "msg": "keep" }))
            .deposit(Balance::from_yoctonear(yocto))
            .transact()
    };
    let o = call(&mut sim, 0);
    println!("ft_transfer_call with no deposit: {}", err(&o));
    assert!(panics(&o, one), "{o}");
    let o = call(&mut sim, 1);
    let order: Vec<String> = o.receipts.iter().filter(|r| !r.is_refund()).map(|r| format!("{}::{}", r.receiver_id, r.method_names.join("+"))).collect();
    println!("ft_transfer_call: {order:?}; returns {}", o.json::<String>());
    assert_eq!(order, [format!("{FT}::ft_transfer_call"), format!("{P}::ft_on_transfer"), format!("{FT}::ft_resolve_transfer")]);
    assert_eq!(o.json::<String>(), "7", "the resolver's value: the amount used");
    assert_eq!(bal(&sim, P), 7);
}

/// `ft_resolve_transfer(sender, receiver, amount)` delivered as the token's
/// callback on `result` (`Tx::promise_results`: nearcore's callback path,
/// predecessor the token, so `#[private]` passes; no node makes this
/// receipt, but what the callback reads and does is the same).
fn resolve(sim: &mut Sim, sender: &str, receiver: &str, amount: u128, result: PromiseResult) -> TxOutcome {
    sim.call(ALICE, FT, "ft_resolve_transfer")
        .args_json(json!({ "sender_id": sender, "receiver_id": receiver, "amount": amount.to_string() }))
        .promise_results([result])
        .transact()
}

/// T2 (core_impl.rs:169-235). `unused` is `amount` if the receiver's result
/// is Failed, longer than 42 bytes or not a U128, else min(v, amount)
/// (:175-183, the bound `promise_result_checked(0, 42)`); the refund is
/// min(unused, receiver's balance), moved back to the sender (:186-210); an
/// unregistered sender's refund is burnt, and total supply drops
/// (:211-226). It returns the amount used. Only the token may call it
/// (`#[private]` on the probe's resolver, conformance/probes/ft/src/lib.rs:63).
/// Bob holds 100 of a 50-token transfer from alice in each case.
#[test]
fn ft_resolve_transfer_rules() {
    let mut base = world();
    transfer(&mut base, ALICE, BOB, 100, 1).transact().assert_success();
    let spaces = |n: usize| [b"\"0\"".to_vec(), vec![b' '; n]].concat();
    let cases: Vec<(&str, PromiseResult, u128)> = vec![
        ("Failed", PromiseResult::Failed, 0),
        ("\"20\"", PromiseResult::json("20"), 30),
        ("\"80\", over the amount", PromiseResult::json("80"), 0),
        ("\"0\" + 39 spaces (42 bytes)", PromiseResult::Successful(spaces(39)), 50),
        ("\"0\" + 40 spaces (43 bytes)", PromiseResult::Successful(spaces(40)), 0),
        ("not a number", PromiseResult::Successful(b"\"x\"".to_vec()), 0),
        ("empty", PromiseResult::Successful(vec![]), 0),
    ];
    for (what, result, used) in cases {
        let mut sim = base.clone();
        let o = resolve(&mut sim, ALICE, BOB, 50, result);
        let got: String = o.json();
        println!("result {what}: returns {got}; bob {} -> {}", 100, bal(&sim, BOB));
        assert_eq!(got, used.to_string());
        assert_eq!(bal(&sim, BOB), 100 - (50 - used), "the refund came from bob");
        assert_eq!(bal(&sim, ALICE), SUPPLY - 100 + (50 - used), "and went to alice");
    }

    // The refund is capped at the receiver's balance.
    let mut sim = world();
    transfer(&mut sim, ALICE, BOB, 5, 1).transact().assert_success();
    let o = resolve(&mut sim, ALICE, BOB, 50, PromiseResult::Failed);
    println!("bob holding 5, result Failed: returns {}; bob {}", o.json::<String>(), bal(&sim, BOB));
    assert_eq!(o.json::<String>(), "45");
    assert_eq!(bal(&sim, BOB), 0);

    // An unregistered sender: the refund is burnt.
    let mut sim = base.clone();
    let s0 = supply(&sim);
    let o = resolve(&mut sim, CAROL, BOB, 50, PromiseResult::Failed);
    println!("sender carol unregistered: returns {}; bob {}; supply {s0} -> {}; logs {:?}", o.json::<String>(), bal(&sim, BOB), supply(&sim), o.logs());
    assert_eq!(o.json::<String>(), "50");
    assert_eq!(bal(&sim, BOB), 50);
    assert_eq!(supply(&sim), s0 - 50);

    // Only the token may call it.
    let o = sim.call(ALICE, FT, "ft_resolve_transfer").args_json(json!({ "sender_id": ALICE, "receiver_id": BOB, "amount": "1" })).transact();
    println!("alice calls it: {}", err(&o));
    assert!(panics(&o, "Method ft_resolve_transfer is private"), "{o}");
}

/// The Transfers a transaction's receipts made from the token: (receiver, amount).
fn payouts(o: &TxOutcome) -> Vec<(String, Balance)> {
    o.receipts
        .iter()
        .filter(|r: &&ReceiptOutcome| r.predecessor_id.as_str() == FT && r.actions == ["Transfer"])
        .map(|r| (r.receiver_id.to_string(), r.deposit))
        .collect()
}

/// T4 (storage_impl.rs). `storage_deposit(account_id?)`: below `min` it
/// panics (:66-69); an unregistered account is registered and `deposit −
/// min` goes back to the predecessor (:70-76); a registered one gets the
/// whole deposit back, to the predecessor (:60-64); min = max for the FT.
/// `storage_balance_of` gives the balance or null. `storage_unregister`
/// needs 1 yocto; an unregistered caller gets false; a positive balance
/// without `force` panics; otherwise the account goes, its tokens are
/// burnt and `min` + 1 yocto is sent to it (:8-36).
#[test]
fn storage_deposit_and_unregister() {
    let mut sim = world();
    let bounds: Value = sim.view(FT, "storage_balance_bounds", json!({})).json();
    let min: u128 = bounds["min"].as_str().unwrap().parse().unwrap();
    println!("bounds {bounds}");
    assert_eq!(bounds["min"], bounds["max"]);
    let deposit = |sim: &mut Sim, from: &str, acct: Option<&str>, amount: u128| {
        sim.call(from, FT, "storage_deposit").args_json(json!({ "account_id": acct })).deposit(Balance::from_yoctonear(amount)).transact()
    };
    let o = deposit(&mut sim, CAROL, None, min - 1);
    println!("carol deposits min - 1: {}", err(&o));
    assert!(panics(&o, "The attached deposit is less than the minimum storage balance"), "{o}");
    let o = deposit(&mut sim, CAROL, None, min + near(1).as_yoctonear());
    println!("carol deposits min + 1 N: {:?}; payouts {:?}", o.json::<Value>(), payouts(&o));
    o.assert_success();
    assert_eq!(payouts(&o), [(CAROL.to_string(), near(1))]);
    assert_eq!(o.json::<Value>(), json!({ "total": min.to_string(), "available": "0" }));
    // dave pays for erin: erin is registered, the excess goes to dave.
    let o = deposit(&mut sim, DAVE, Some(ERIN), min + 5);
    println!("dave deposits min + 5 for erin: payouts {:?}", payouts(&o));
    assert_eq!(payouts(&o), [(DAVE.to_string(), Balance::from_yoctonear(5))]);
    // Registered already: all of it back, to the predecessor.
    let o = deposit(&mut sim, DAVE, Some(ERIN), near(1).as_yoctonear());
    println!("dave deposits 1 N for registered erin: payouts {:?}; logs {:?}", payouts(&o), o.logs());
    assert_eq!(payouts(&o), [(DAVE.to_string(), near(1))]);
    let of = |sim: &Sim, a: &str| sim.view(FT, "storage_balance_of", json!({ "account_id": a })).json::<Value>();
    println!("storage_balance_of carol {}, erin {}, dave {}", of(&sim, CAROL), of(&sim, ERIN), of(&sim, DAVE));
    let registered = json!({ "total": min.to_string(), "available": "0" });
    assert_eq!(of(&sim, CAROL), registered);
    assert_eq!(of(&sim, ERIN), registered, "registered by dave's deposit");
    assert_eq!(of(&sim, DAVE), Value::Null);

    let unregister = |sim: &mut Sim, who: &str, force: Option<bool>, yocto: u128| {
        sim.call(who, FT, "storage_unregister").args_json(json!({ "force": force })).deposit(Balance::from_yoctonear(yocto)).transact()
    };
    let o = unregister(&mut sim, BOB, None, 0);
    println!("bob unregisters without 1 yocto: {}", err(&o));
    assert!(panics(&o, "Requires attached deposit of exactly 1 yoctoNEAR"), "{o}");
    let o = unregister(&mut sim, DAVE, None, 1);
    println!("unregistered dave unregisters: {:?}", o.json::<bool>());
    assert!(!o.json::<bool>());
    transfer(&mut sim, ALICE, BOB, 30, 1).transact().assert_success();
    let o = unregister(&mut sim, BOB, None, 1);
    println!("bob holding 30 unregisters without force: {}", err(&o));
    assert!(panics(&o, "Can't unregister the account with the positive balance without force"), "{o}");
    let s0 = supply(&sim);
    let o = unregister(&mut sim, BOB, Some(true), 1);
    println!("with force: {:?}; supply {s0} -> {}; payouts {:?}; bob registered {}", o.json::<bool>(), supply(&sim), payouts(&o), of(&sim, BOB));
    assert!(o.json::<bool>());
    assert_eq!(supply(&sim), s0 - 30, "bob's tokens are burnt");
    assert_eq!(payouts(&o), [(BOB.to_string(), Balance::from_yoctonear(min + 1))]);
    assert_eq!(of(&sim, BOB), Value::Null);
}
