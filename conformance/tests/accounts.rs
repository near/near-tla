//! Accounts, keys and stake, observed in the sim for the docs/SEMANTICS.md
//! rules the conformance comparison cannot see: account existence and
//! uninitialised universal accounts (A1), fees by account pattern for
//! deterministic and universal ids (A2), what an implicit Transfer creates
//! and when (A3, A4), a call to an account without code (A5), function-call
//! keys (K2), AddKey and DeleteKey failures (K3), Stake's checks and the
//! result a callback reads after a Stake (B1) and the locked balance in the
//! storage check (B2). Each test prints what it observed; `cargo test
//! --test accounts -- --nocapture` shows it.
//!
//! nearcore references are at the pinned rev b7b4737 (README, "Pins").
//! Every test runs on the committed probe wasms (`probes/res/`); the
//! contract-created Stake is on `probe2` (on `z-probe.near`).
use near_contract_sim::nearcore::near_parameters::ActionCosts;
use near_contract_sim::nearcore::near_primitives::action::StakeAction;
use near_contract_sim::prelude::*;
use near_contract_sim::{
    AccessKey, AccessKeyPermission, ActionErrorKind, FunctionCallPermission, GlobalContractIdentifier, InvalidTxError, Refund,
};
use near_tla_conformance::{probe_wasm, transfer_fees};
use serde_json::json;

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const P: &str = "p-probe.near";
const Z: &str = "z-probe.near";

/// Ids of each implicit kind (near-account-id 3.0.0 `src/validation.rs:96-132`):
/// 64 hex (`nimp()`); `0x` + 40 hex; `0s` + 40 hex; `0u` + 52 Crockford
/// base32 ending in `0` or `g`.
const ETH: &str = "0x4444444444444444444444444444444444444444";
const DET: &str = "0s5555555555555555555555555555555555555555";
const UNI: &str = "0uaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0";

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

fn yocto(b: Balance) -> i128 {
    b.as_yoctonear() as i128
}

fn world() -> Sim {
    let (wasm, _) = probe_wasm("probe");
    Fixture::new().account(ALICE, near(1000)).account(BOB, near(100)).contract(P, wasm).build()
}

/// A NEAR-implicit id: the hex of an ed25519 key.
fn nimp() -> (String, PublicKey) {
    let pk = sk("implicit").public_key();
    (pk.key_data().iter().map(|b| format!("{b:02x}")).collect(), pk)
}

fn sk(seed: &str) -> SecretKey {
    SecretKey::from_seed(KeyType::ED25519, seed)
}

fn err(o: &TxOutcome) -> String {
    format!("{:?}", o.failure())
}

fn usage(sim: &Sim, id: &str) -> u64 {
    sim.account(id).unwrap().storage_usage
}

/// (conversion, receipt) gas burnt of a one-receipt transaction.
fn burns(o: &TxOutcome) -> (u64, u64) {
    (o.transaction.as_ref().unwrap().gas_burnt.as_gas(), o.first_call().unwrap().gas_burnt.as_gas())
}

/// A1, A5. The receiver's existence is checked before the actor
/// (runtime/runtime/src/actions.rs:814-895 `check_account_existence`,
/// called at runtime/runtime/src/lib.rs:600-605). CreateAccount needs it
/// absent, a Transfer may create it (A3), and DeterministicStateInit and
/// UniversalStateInit pass either way (:851-861; not exercised here: the
/// test builds no state init). Every other action needs it to exist
/// (:862-882), and an uninitialised universal account counts as absent for
/// them (:883-888).
/// A FunctionCall to an existing account without code fails with
/// CodeDoesNotExist (runtime/runtime/src/function_call.rs:309-312), and its
/// deposit is refunded.
#[test]
fn existence_and_code() {
    let mut sim = world();
    let o = sim.call(ALICE, "nobody.near", "mark").args_json(json!({ "tag": "x" })).transact();
    println!("call to absent nobody.near: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");
    // Existence before the actor: AddKey by alice on an absent account.
    let o = sim.tx(ALICE, "nobody.near").add_key(sk("n").public_key(), AccessKey::full_access()).transact();
    println!("AddKey by alice on absent nobody.near: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");

    // bob exists and has no code.
    let o = sim.call(ALICE, BOB, "mark").args_json(json!({ "tag": "x" })).deposit(near(1)).transact();
    let refunds: Vec<_> = o.receipts.iter().filter(|r| r.refund == Some(Refund::Deposit)).map(|r| (r.executor_id.to_string(), r.deposit)).collect();
    println!("call with 1 N to bob.near (no code): {}; deposit refunds {refunds:?}", err(&o));
    assert!(err(&o).contains("CodeDoesNotExist"), "{o}");
    assert_eq!(refunds, [(ALICE.to_string(), near(1))]);

    // A universal id funded by a Transfer: uninitialised.
    sim.tx(ALICE, UNI).transfer(near(1)).transact().assert_success();
    let a = sim.account(UNI).unwrap();
    println!("universal {}..: {} bytes, balance {}", &UNI[..8], a.storage_usage, a.amount);
    let o = sim.call(ALICE, UNI, "mark").args_json(json!({ "tag": "x" })).transact();
    println!("call to it: {}", err(&o));
    assert!(err(&o).contains("AccountNotInitialized"), "{o}");
    let o = sim.tx(ALICE, UNI).add_key(sk("u").public_key(), AccessKey::full_access()).transact();
    println!("AddKey by alice on it: {}", err(&o));
    assert!(err(&o).contains("AccountNotInitialized"), "{o}");
    let o = sim.tx(ALICE, UNI).transfer(near(1)).transact();
    println!("another Transfer to it: {}; balance {}", err(&o), sim.balance(UNI));
    o.assert_success();
    assert_eq!(sim.balance(UNI), near(2));
}

/// A3, A4. A Transfer to an absent implicit id creates the account only if
/// it is the receipt's only action, except a universal id, which a batched
/// Transfer creates too (runtime/runtime/src/actions.rs:929-946
/// `implicit_creation_allowed`; otherwise AccountDoesNotExist, :842-849).
/// What is created (:221-287): NEAR-implicit 182 bytes and a full-access key
/// derived from the id; eth-implicit 132 bytes and a global-contract
/// reference by hash, the eth-wallet contract's in nearcore (:255-269); deterministic 100 bytes, no key; universal 100
/// bytes, uninitialised (:276-282).
#[test]
fn implicit_creation_by_kind() {
    let base = world();
    let (nimp, nimp_key) = nimp();
    for id in [nimp.as_str(), ETH, DET, UNI] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, id).transfer(near(1)).transfer(near(1)).transact();
        let batched = (err(&o), sim.account(id).is_some());
        let o = sim.tx(ALICE, id).transfer(near(1)).transact();
        let a = sim.account(id);
        let keys = sim.access_keys(id).len();
        println!(
            "{}..: [Transfer, Transfer] {:?}, created {}; lone Transfer {}, {:?} bytes, {keys} keys, global code {:?}",
            &id[..6],
            batched.0,
            batched.1,
            err(&o),
            a.as_ref().map(|a| a.storage_usage),
            a.as_ref().and_then(|a| a.global_contract_hash)
        );
        if id == UNI {
            assert_eq!(batched, ("None".to_string(), true), "a universal id is created even when batched");
            assert_eq!(sim.balance(id), near(3));
        } else {
            assert!(batched.0.contains("AccountDoesNotExist") && !batched.1, "only a lone Transfer creates it");
            assert_eq!(sim.balance(id), near(1));
        }
        o.assert_success();
        let a = a.unwrap();
        match id {
            _ if id == nimp => {
                assert_eq!((a.storage_usage, keys), (182, 1));
                let k = sim.access_key(id, &nimp_key).expect("the key is the id");
                assert!(matches!(k.permission, AccessKeyPermission::FullAccess));
            }
            ETH => {
                assert_eq!((a.storage_usage, keys), (132, 0));
                // A global-contract reference by hash. That it is the
                // eth-wallet contract's hash is not checked: the sim does
                // not expose the expected hash.
                assert!(a.global_contract_hash.is_some(), "a global-contract reference");
            }
            _ => assert_eq!((a.storage_usage, keys), (100, 0)),
        }
    }
    // eth-implicit: the record names the eth-wallet global contract
    // (runtime/runtime/src/actions.rs:255-269),
    // and a call resolves the account's code through it
    // (runtime/runtime/src/lib.rs:684-694). The sim's chain has not published
    // that code, so here the call finds none: on such a chain it fails with
    // CodeDoesNotExist; it runs the wallet only where the code is published.
    let mut sim = base.clone();
    sim.tx(ALICE, ETH).transfer(near(1)).transact().assert_success();
    let h = sim.account(ETH).unwrap().global_contract_hash.unwrap();
    let published = sim.global_contract_code(GlobalContractIdentifier::CodeHash(h)).is_some();
    let o = sim.call(ALICE, ETH, "mark").args_json(json!({ "tag": "x" })).transact();
    println!("eth-wallet code {h} published in the sim: {published}; a call to the eth-implicit account: {}", err(&o));
    assert!(!published);
    assert!(err(&o).contains("CodeDoesNotExist"), "{o}");
}

/// A2. A Transfer's fee follows the receiver id's pattern, whether or not
/// the account exists: deterministic and universal ids pay transfer +
/// create_account, as eth-implicit does, and NEAR-implicit also
/// add_full_access_key (core/parameters/src/cost.rs:774-848, callers pass
/// `receiver_id.get_account_type()` with no existence check:
/// runtime/runtime/src/config.rs:120-128, :360-368). The conversion burns
/// the send fees, the receipt the exec fees.
#[test]
fn transfer_fee_by_pattern() {
    let mut sim = world();
    let rc = sim.config.runtime_config();
    let ca = rc.fees.fee(ActionCosts::create_account).clone();
    let ak = rc.fees.fee(ActionCosts::add_full_access_key).clone();
    let (ca_s, ca_e, ak_s, ak_e) = (ca.send_fee(false).gas.as_gas(), ca.exec_fee().gas.as_gas(), ak.send_fee(false).gas.as_gas(), ak.exec_fee().gas.as_gas());
    let named = burns(&sim.tx(ALICE, BOB).transfer(near(1)).transact());
    println!("named: conversion {} gas, receipt {} gas", named.0, named.1);
    let (nimp, _) = nimp();
    for id in [nimp.as_str(), ETH, DET, UNI] {
        let new = burns(&sim.tx(ALICE, id).transfer(near(1)).transact());
        let again = burns(&sim.tx(ALICE, id).transfer(near(1)).transact());
        let (ds, de) = (new.0 - named.0, new.1 - named.1);
        println!("{}..: absent {new:?}, existing {again:?}; over named: send +{ds}, exec +{de}", &id[..6]);
        assert_eq!(new, again, "the same fee once the account exists");
        if id == nimp {
            assert_eq!((ds, de), (ca_s + ak_s, ca_e + ak_e));
        } else {
            assert_eq!((ds, de), (ca_s, ca_e));
        }
        assert_eq!((new.0 - named.0 + transfer_fees(&sim, false, BOB).0), transfer_fees(&sim, false, id).0);
    }
}

/// A3, the account creation charge (85+, `AccountCostIncrease`): a
/// successful receipt that created an account pays `account_creation_charge`
/// (0.007 N, core/parameters/res/runtime_configs/85.yaml:43) less the
/// create_account exec gas at the burn price, taken from the price-surplus
/// part of the gas refund and burnt (runtime/runtime/src/lib.rs:1361-1397,
/// `created_new_account` at :1057-1058). The sim's surplus covers it, so
/// the whole charge shows: a Transfer creating a deterministic account
/// costs its signer that much more than the same Transfer once it exists.
#[test]
fn account_creation_charge() {
    let mut sim = world();
    let rc = sim.config.runtime_config();
    let exec = rc.fees.fee(ActionCosts::create_account).exec_fee().gas.as_gas() as u128;
    let want = yocto(rc.account_creation_charge) - yocto(sim.config.gas_price.checked_mul(exec).unwrap());
    let paid = |sim: &mut Sim| {
        let a = sim.balance(ALICE);
        let o = sim.tx(ALICE, DET).transfer(near(1)).transact();
        o.assert_success();
        (yocto(a) - yocto(sim.balance(ALICE)) - yocto(near(1)), yocto(o.tokens_burnt()))
    };
    let (created, burnt) = paid(&mut sim);
    let (again, _) = paid(&mut sim);
    println!(
        "charge {}, gas price {}; alice paid {created} yocto over the deposit creating {}.. (tokens burnt {burnt}), {again} once it exists: {} more, expected {want}",
        rc.account_creation_charge,
        sim.config.gas_price.as_yoctonear(),
        &DET[..6],
        created - again
    );
    assert_eq!(created - again, want);
    assert_eq!(created, burnt, "the charge is burnt");
}

/// K2. A function-call key signs only a transaction of one FunctionCall
/// with no deposit, to its receiver and, if it lists methods, one of them
/// (runtime/runtime/src/verifier.rs:209-251 `verify_function_call_permission`);
/// otherwise the transaction is invalid and nothing runs. Its allowance
/// pays the transaction's cost (:282-301; NotEnoughAllowance when short),
/// and the gas refund adds back to it (runtime/runtime/src/actions.rs:133-157
/// `try_refund_allowance`).
#[test]
fn function_call_key_scope() {
    let mut sim = world();
    let fck = sk("alice-fc");
    let perm = |allowance: Option<Balance>, ms: &[&str]| AccessKey {
        nonce: 0,
        permission: AccessKeyPermission::FunctionCall(FunctionCallPermission {
            allowance,
            receiver_id: P.into(),
            method_names: ms.iter().map(|m| m.to_string()).collect(),
        }),
    };
    let allowance = near(1);
    sim.tx(ALICE, ALICE).add_key(fck.public_key(), perm(Some(allowance), &["mark"])).transact().assert_success();
    let left = |sim: &Sim| match sim.access_key(ALICE, &fck.public_key()).unwrap().permission {
        AccessKeyPermission::FunctionCall(p) => p.allowance.unwrap(),
        _ => unreachable!(),
    };
    fn mark<'a>(sim: &'a mut Sim, tag: &str, key: &SecretKey) -> Tx<'a> {
        sim.call(ALICE, P, "mark").args_json(json!({ "tag": tag })).sign_with(key)
    }
    let o = mark(&mut sim, "a", &fck).transact();
    let spent = yocto(allowance) - yocto(left(&sim));
    let prepaid = yocto(sim.config.gas_price.checked_mul(Gas::from_teragas(300).as_gas() as u128).unwrap());
    println!("in scope: {}; allowance spent {spent} yocto, tokens burnt {}, 300 Tgas costs {prepaid}", err(&o), o.tokens_burnt().as_yoctonear());
    o.assert_success();
    assert_eq!(spent, yocto(o.tokens_burnt()), "charged the cost, the gas refund added back");
    assert!(spent < prepaid);

    let a = serde_json::to_vec(&json!({ "tag": "b" })).unwrap();
    let cases: Vec<(&str, TxOutcome, &str)> = vec![
        ("a deposit", mark(&mut sim, "b", &fck).deposit(Balance::from_yoctonear(1)).transact(), "DepositWithFunctionCall"),
        ("another receiver", sim.call(ALICE, BOB, "mark").args(a.clone()).sign_with(&fck).transact(), "ReceiverMismatch"),
        ("another method", sim.call(ALICE, P, "put").args(a.clone()).sign_with(&fck).transact(), "MethodNameMismatch"),
        ("two calls", sim.tx(ALICE, P).call("mark").args(a.clone()).call("mark").args(a.clone()).sign_with(&fck).transact(), "RequiresFullAccess"),
        ("a Transfer", sim.tx(ALICE, P).transfer(Balance::from_yoctonear(1)).sign_with(&fck).transact(), "RequiresFullAccess"),
    ];
    for (what, o, want) in &cases {
        println!("{what}: {}", err(o));
        assert!(matches!(o.failure(), Some(Failure::InvalidTx(InvalidTxError::InvalidAccessKeyError(_)))), "{o}");
        assert!(err(o).contains(want), "{o}");
        assert!(o.receipts.is_empty(), "nothing runs");
    }
    // An empty method list allows every method of the receiver.
    let any = sk("alice-any");
    sim.tx(ALICE, ALICE).add_key(any.public_key(), perm(None, &[])).transact().assert_success();
    let o = sim.call(ALICE, P, "put").args_json(json!({ "key": "k", "value": "v" })).sign_with(&any).transact();
    println!("empty method list, put: {}", err(&o));
    o.assert_success();
    // An allowance below the transaction's cost.
    let poor = sk("alice-poor");
    sim.tx(ALICE, ALICE).add_key(poor.public_key(), perm(Some(Balance::from_yoctonear(1)), &[])).transact().assert_success();
    let o = sim.call(ALICE, P, "mark").args_json(json!({ "tag": "c" })).sign_with(&poor).transact();
    println!("allowance of 1 yocto: {}", err(&o));
    assert!(err(&o).contains("NotEnoughAllowance"), "{o}");
    assert_eq!(sim.view(P, "marks", json!({})).json::<String>(), "a,");
}

/// K3. AddKey of a present key fails with AddKeyAlreadyExists and DeleteKey
/// of an absent one with DeleteKeyDoesNotExist (runtime/runtime/src/access_keys.rs:83-89,
/// :157-164); key actions need the account itself as actor
/// (runtime/runtime/src/actions.rs:755-801, ActorNoPermission). Either
/// failure fails the whole receipt: an AddKey before it is undone.
#[test]
fn key_action_failures() {
    let mut sim = world();
    let k1 = sk("k1").public_key();
    sim.tx(ALICE, ALICE).add_key(k1.clone(), AccessKey::full_access()).transact().assert_success();
    let k2 = sk("k2").public_key();
    let o = sim.tx(ALICE, ALICE).add_key(k2.clone(), AccessKey::full_access()).add_key(k1.clone(), AccessKey::full_access()).transact();
    println!("[AddKey(new), AddKey(present)]: {}; the new key added: {}", err(&o), sim.access_key(ALICE, &k2).is_some());
    assert!(err(&o).contains("AddKeyAlreadyExists"), "{o}");
    assert!(sim.access_key(ALICE, &k2).is_none());
    let o = sim.tx(ALICE, ALICE).add_key(k2.clone(), AccessKey::full_access()).delete_key(sk("absent").public_key()).transact();
    println!("[AddKey(new), DeleteKey(absent)]: {}; the new key added: {}", err(&o), sim.access_key(ALICE, &k2).is_some());
    assert!(err(&o).contains("DeleteKeyDoesNotExist"), "{o}");
    assert!(sim.access_key(ALICE, &k2).is_none());
    let bob_key = sim.secret_key(BOB).public_key();
    for (what, o) in [
        ("AddKey", sim.tx(ALICE, BOB).add_key(k2.clone(), AccessKey::full_access()).transact()),
        ("DeleteKey", sim.tx(ALICE, BOB).delete_key(bob_key).transact()),
    ] {
        println!("{what} on bob by alice: {}", err(&o));
        assert!(err(&o).contains("ActorNoPermission"), "{o}");
    }
}

/// B1. Stake (runtime/runtime/src/actions.rs:58-108 `action_stake`): more
/// than liquid + locked fails with TriesToStake; 0 with nothing locked
/// fails with TriesToUnstake; an increase moves the difference from liquid
/// to locked at once; a decrease changes nothing now (the release comes
/// from epoch processing). Only the account itself may stake (:755-801).
/// InsufficientStake (`minimum_stake`, :76-86) is not reachable: the sim
/// has no minimum stake.
#[test]
fn stake_rules() {
    let mut sim = world();
    let pk = sim.secret_key(BOB).public_key();
    let stake = |sim: &mut Sim, signer: &str, n: u128| {
        sim.tx(signer, BOB).action(StakeAction { stake: near(n), public_key: pk.clone() }).transact()
    };
    let o = stake(&mut sim, BOB, 0);
    println!("stake 0, nothing locked: {}", err(&o));
    assert!(err(&o).contains("TriesToUnstake"), "{o}");
    let o = stake(&mut sim, BOB, 200);
    println!("stake 200 N with ~100 N: {}", err(&o));
    assert!(err(&o).contains("TriesToStake"), "{o}");
    let o = stake(&mut sim, ALICE, 10);
    println!("stake on bob by alice: {}", err(&o));
    assert!(err(&o).contains("ActorNoPermission"), "{o}");

    let a = sim.account(BOB).unwrap();
    let (liq, locked) = (a.amount, a.locked);
    let o = stake(&mut sim, BOB, 40);
    let a = sim.account(BOB).unwrap();
    println!("stake 40 N: {}; liquid {} -> {}, locked {} -> {}", err(&o), liq, a.amount, locked, a.locked);
    o.assert_success();
    assert_eq!(a.locked, near(40));
    assert_eq!(yocto(liq) - yocto(a.amount), yocto(near(40)) + yocto(o.tokens_burnt()), "40 N moved, plus gas");
    let (liq, h) = (a.amount, sim.height());
    let o = stake(&mut sim, BOB, 10);
    let a = sim.account(BOB).unwrap();
    println!("stake 10 N (a decrease) at #{h}: {}; liquid {} -> {}, locked {}", err(&o), liq, a.amount, a.locked);
    o.assert_success();
    assert_eq!(a.locked, near(40), "nothing released now");
    assert_eq!(yocto(liq) - yocto(a.amount), yocto(o.tokens_burnt()));
}

/// B1, the result. A successful Stake receipt returns no value, so a
/// callback on it reads `Successful` with empty bytes; a failed one
/// (`TriesToStake`) gives `Failed` (runtime/runtime/src/lib.rs:1172-1176,
/// `Ok(_)` sends empty data, an error none; :861-899). z stakes itself
/// (`promise_batch_action_stake`, near-vm-runner logic/host.rs:3923-3953),
/// then `z.on_at(0)` reads result 0: its size, -1 for `Failed`.
#[test]
fn callback_after_stake() {
    let (wasm, _) = probe_wasm("probe2");
    let base = Fixture::new().account(ALICE, near(1000)).contract(Z, wasm).build();
    let pk = sk("validator").public_key();
    for (n, want) in [(10u128, (0i64, "result 0 of 1: 0 bytes")), (1_000_000, (-1, "result 0 of 1: failed"))] {
        let mut sim = base.clone();
        let o = sim
            .call(ALICE, Z, "stake_then")
            .args_json(json!({ "amount": near(n).as_yoctonear().to_string(), "pk": pk.to_string(), "cb_ggas": 10000 }))
            .transact();
        let st = o.receipts.iter().find(|r| r.actions == ["Stake"]).unwrap();
        let cb = o.expect_receipt("on_at");
        let read = cb.value().map(|v| serde_json::from_slice::<i64>(v).unwrap());
        let locked = sim.account(Z).unwrap().locked;
        println!("z stakes {n} N: {:?}; on_at(0) read {read:?}, logged {:?}; locked {locked}", st.failure(), cb.logs);
        assert_eq!((read, cb.logs[0].as_str()), (Some(want.0), want.1));
        if n == 10 {
            assert_eq!(st.value(), Some(&[][..]), "no return value: empty bytes");
            assert_eq!(locked, near(10));
        } else {
            assert!(format!("{:?}", st.failure()).contains("TriesToStake"), "{:?}", st.failure());
            assert_eq!(locked, Balance::ZERO);
        }
    }
}

/// B2, the locked part. The storage check counts liquid + locked
/// (runtime/runtime/src/verifier.rs:64-74 in `check_storage_stake`): past
/// the 770-byte allowance, an account whose liquid balance alone does not
/// cover its bytes still grows if liquid + locked does; the same account
/// without the stake fails with LackBalanceForState.
#[test]
fn storage_counts_locked_balance() {
    let base = world();
    let z = "zed.near";
    let grow = |sim: &mut Sim, seed: &str| sim.tx(z, z).add_key(sk(seed).public_key(), AccessKey::full_access()).transact();
    let mut sim = base.clone();
    sim.create_account(z, near(10));
    for i in 0..7 {
        grow(&mut sim, &format!("z{i}")).assert_success();
    }
    let after = usage(&sim, z) + 82;
    let cover = sim.storage_cost(after);
    assert!(after > 770, "past the zero-balance allowance");
    let (mut staked, mut plain) = (sim.clone(), sim);
    let pk = staked.secret_key(z).public_key();
    staked.tx(z, z).action(StakeAction { stake: near(5), public_key: pk }).transact().assert_success();
    // The liquid part: half the cover of the bytes after one more key.
    for s in [&mut staked, &mut plain] {
        s.set_balance(z, cover.checked_div(2).unwrap());
    }
    for (what, s) in [("with 5 N locked", &mut staked), ("with nothing locked", &mut plain)] {
        let a = s.account(z).unwrap();
        let o = grow(s, "last");
        println!("{what}: liquid {}, locked {}, the cover of {after} bytes {}; AddKey: {}", a.amount, a.locked, cover, err(&o));
        assert!(a.amount < cover);
        if a.locked.is_zero() {
            assert!(matches!(o.failure(), Some(Failure::Action(ActionErrorKind::LackBalanceForState { .. }))), "{o}");
            assert_eq!(usage(s, z), after - 82);
        } else {
            o.assert_success();
            assert_eq!(usage(s, z), after);
        }
    }
}
