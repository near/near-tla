//! Account lifecycle, observed in the sim before the library models it:
//! CreateAccount (who may create what, the batch's atomicity, the bytes of
//! a new account), DeleteAccount (actor, staking, the 10 KB rule, the
//! beneficiary payout, what deletion leaves behind), receipts that reach a
//! deleted account, re-creation, DeployContract's storage delta and limits,
//! instant receipts, and the fees of these actions. Each test prints what
//! it observed; `cargo test --test lifecycle -- --nocapture` shows it.
//!
//! nearcore references are at the pinned rev (README, "Pins"):
//! `runtime/runtime/src/actions.rs` (action_create_account :166-209,
//! action_delete_account :330-406, check_actor_permissions :755-812,
//! check_account_existence :814-897), `core/store/src/utils/mod.rs`
//! (remove_account), `core/primitives/src/receipt.rs` (is_instant_receipt),
//! `runtime/runtime/src/lib.rs` (process_receipt_and_instant_receipts).
//!
//! Every test runs on the existing probe wasms (`probes/res/`); none needs a
//! new probe.
use near_contract_sim::nearcore::near_parameters::ActionCosts;
use near_contract_sim::nearcore::near_primitives::action::{DeleteAccountAction, StakeAction};
use near_contract_sim::prelude::*;
use near_contract_sim::{
    AccessKey, ActionErrorKind, GlobalContractDeployMode, GlobalContractIdentifier, InvalidTxError, ReceiptOutcome,
    Refund,
};
use near_tla_conformance::{probe_wasm, transfer_fees};
use serde_json::json;

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const RELAYER: &str = "relayer.near";
const P: &str = "p-probe.near";
const Q: &str = "q-probe.near";

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

fn yocto(b: Balance) -> i128 {
    b.as_yoctonear() as i128
}

fn world() -> Sim {
    let (wasm, _) = probe_wasm("probe");
    Fixture::new()
        .account(ALICE, near(1000))
        .account(BOB, near(100))
        .account(RELAYER, near(100))
        .contract(P, wasm.clone())
        .contract(Q, wasm)
        .build()
}

fn sk(seed: &str) -> SecretKey {
    SecretKey::from_seed(KeyType::ED25519, seed)
}

fn usage(sim: &Sim, id: &str) -> u64 {
    sim.account(id).unwrap().storage_usage
}

fn exists(sim: &Sim, id: &str) -> bool {
    sim.account(id).is_some()
}

fn del(beneficiary: &str) -> DeleteAccountAction {
    DeleteAccountAction { beneficiary_id: beneficiary.parse().unwrap() }
}

/// The outcome's failure, `Debug`-formatted (nearcore's error names).
fn err(o: &TxOutcome) -> String {
    format!("{:?}", o.failure())
}

fn rerr(r: &ReceiptOutcome) -> String {
    format!("{:?}", r.failure())
}

/// `parent` creates `id` with the CreateAccount action:
/// `[CreateAccount, Transfer(bal), AddKey(full, key seeded "<seed>")]`, and
/// `Deploy(wasm)` if given. The sim then signs for `id` with that key.
fn create(sim: &mut Sim, parent: &str, id: &str, bal: Balance, seed: &str, wasm: Option<&[u8]>) -> TxOutcome {
    let k = sk(seed);
    let mut tx = sim.tx(parent, id).create_account().transfer(bal).add_key(k.public_key(), AccessKey::full_access());
    if let Some(w) = wasm {
        tx = tx.deploy(w.to_vec());
    }
    let o = tx.transact();
    if o.failure().is_none() {
        sim.set_key(id, &k);
    }
    o
}

/// The account-deletion payout receipts (`Receipt::new_balance_refund`) of an outcome.
fn payouts(o: &TxOutcome) -> Vec<&ReceiptOutcome> {
    o.receipts.iter().filter(|r| r.refund == Some(Refund::AccountDeletion)).collect()
}

/// L2-L6. Run as transactions, so the predecessor is the signer.
/// actions.rs:175-197 (top-level and sub-account rules), :822-840
/// (existing and implicit ids), :202-208 (the new account: 0 balance, no
/// code, 100 bytes). `min_allowed_top_level_account_length` is 65 at
/// protocol 88 and ids are at most 64 characters, so every named top-level
/// id needs the creation config's privileged account (`registrar_account_id`,
/// created here as a fixture account).
#[test]
fn create_account_rules() {
    let mut sim = world();
    let rc = sim.config.runtime_config();
    let acc = &rc.account_creation_config;
    let creator = acc.registrar_account_id.clone();
    println!(
        "config: min_allowed_top_level_account_length {}, privileged creator {creator}",
        acc.min_allowed_top_level_account_length
    );
    assert_eq!(acc.min_allowed_top_level_account_length, 65);
    assert!(creator.is_top_level());

    // A child of the signer: 100 bytes, the deposit, no code, no keys.
    let o = sim.tx(ALICE, "c.alice.near").create_account().transfer(near(1)).transact();
    let a = sim.account("c.alice.near");
    println!("child c.alice.near: {}; {:?}", err(&o), a.as_ref().map(|a| (a.amount, a.storage_usage, a.code_hash)));
    o.assert_success();
    let a = a.unwrap();
    assert_eq!((a.amount, a.storage_usage, a.code_hash), (near(1), 100, CryptoHash::default()));
    assert!(sim.access_keys("c.alice.near").is_empty());
    // With a full-access key: 182 bytes. AddKey after CreateAccount passes the
    // actor check: the new account became the actor (L6).
    let o = create(&mut sim, ALICE, "k.alice.near", near(5), "k", None);
    println!("child k.alice.near with a key: {}; {} bytes", err(&o), usage(&sim, "k.alice.near"));
    o.assert_success();
    assert_eq!(usage(&sim, "k.alice.near"), 182);
    // Without CreateAccount the same AddKey on another account fails the actor check.
    let o = sim.tx(ALICE, "c.alice.near").add_key(sk("x").public_key(), AccessKey::full_access()).transact();
    println!("AddKey on c.alice.near by alice (no CreateAccount): {}", err(&o));
    assert!(err(&o).contains("ActorNoPermission"), "{o}");

    // Another account's child, and a grandchild: only the direct parent.
    for id in ["c.bob.near", "g.k.alice.near"] {
        let o = sim.tx(ALICE, id).create_account().transfer(near(1)).transact();
        println!("{id} by alice: {}", err(&o));
        assert!(err(&o).contains("CreateAccountNotAllowed"), "{o}");
        assert!(!exists(&sim, id));
    }
    let o = sim.tx("k.alice.near", "g.k.alice.near").create_account().transfer(near(1)).transact();
    println!("g.k.alice.near by k.alice.near (its parent): {}", err(&o));
    o.assert_success();

    // Named top-level ids: refused for alice, the 64-character one included;
    // the privileged account creates both.
    let long = "z".repeat(64);
    for id in ["top", long.as_str()] {
        let o = sim.tx(ALICE, id).create_account().transfer(near(1)).transact();
        println!("top-level {id} by alice: {}", err(&o));
        assert!(err(&o).contains("CreateAccountOnlyByRegistrar"), "{o}");
    }
    sim.create_account(&creator, near(100));
    for id in ["top", long.as_str()] {
        let o = sim.tx(&creator, id).create_account().transfer(near(1)).transact();
        println!("top-level {id} by {creator}: {}", err(&o));
        o.assert_success();
        assert_eq!(usage(&sim, id), 100);
    }

    // Implicit ids: never by CreateAccount (NEAR-implicit, eth-implicit,
    // deterministic `0s`). A universal `0u` id is implicit only with
    // `universal_accounts` on; otherwise it is a named top-level id.
    let near_imp = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    let eth_imp = "0x4444444444444444444444444444444444444444";
    let det = format!("0s{}", "5".repeat(40));
    for id in [near_imp, eth_imp, det.as_str()] {
        let o = sim.tx(ALICE, id).create_account().transfer(near(1)).transact();
        println!("implicit {id} by alice: {}", err(&o));
        assert!(err(&o).contains("OnlyImplicitAccountCreationAllowed"), "{o}");
        assert!(!exists(&sim, id));
    }
    let uni = format!("0u{}0", "a".repeat(51));
    let on = sim.config.runtime_config().wasm_config.universal_accounts;
    let o = sim.tx(ALICE, &uni).create_account().transfer(near(1)).transact();
    println!("universal {uni} by alice (universal_accounts {on}): {}", err(&o));
    let want = if on { "OnlyImplicitAccountCreationAllowed" } else { "CreateAccountOnlyByRegistrar" };
    assert!(err(&o).contains(want), "{o}");

    // An existing id: AccountAlreadyExists, checked before the parent rule
    // (L1: existence first), so bob.near by alice is not CreateAccountNotAllowed.
    for id in ["c.alice.near", BOB] {
        let o = sim.tx(ALICE, id).create_account().transfer(near(1)).transact();
        println!("existing {id} by alice: {}", err(&o));
        assert!(err(&o).contains("AccountAlreadyExists"), "{o}");
    }
}

/// L7, L8. A failure anywhere in the batch reverts all of it and the
/// deposit goes back to the predecessor; for a contract-made batch that is
/// the contract, not the user. The storage check runs after all actions and
/// is skipped when the account no longer exists (lib.rs:1008-1031).
#[test]
fn create_batch_atomic() {
    let mut sim = world();
    // [CreateAccount, Transfer, AddKey(k), AddKey(k)]: the second AddKey fails.
    let k = sk("dup");
    let before = sim.balance(ALICE);
    let o = sim
        .tx(ALICE, "d.alice.near")
        .create_account()
        .transfer(near(1))
        .add_key(k.public_key(), AccessKey::full_access())
        .add_key(k.public_key(), AccessKey::full_access())
        .transact();
    let refund: Vec<_> = o.receipts.iter().filter(|r| r.refund == Some(Refund::Deposit)).collect();
    println!(
        "duplicate AddKey: {}; account exists {}; deposit refunds {:?}",
        err(&o),
        exists(&sim, "d.alice.near"),
        refund.iter().map(|r| (r.executor_id.as_str(), r.deposit)).collect::<Vec<_>>()
    );
    assert!(err(&o).contains("AddKeyAlreadyExists"), "{o}");
    assert!(!exists(&sim, "d.alice.near"));
    assert_eq!(refund.len(), 1);
    assert_eq!((refund[0].executor_id.as_str(), refund[0].deposit), (ALICE, near(1)));
    let fail_cost = yocto(before) - yocto(sim.balance(ALICE));
    assert_eq!(fail_cost, yocto(o.effects().gas_paid()), "alice lost only gas");
    let fail_gas: u64 = o.transaction.as_ref().unwrap().gas_burnt.as_gas()
        + o.receipts.iter().filter(|r| r.refund.is_none()).map(|r| r.gas_burnt.as_gas()).sum::<u64>();
    println!(
        "failed batch burnt {:.3} Ggas (it failed at its last action, so every exec fee, create_account's 7200 included)",
        fail_gas as f64 / 1e9
    );
    assert_eq!(fail_cost, fail_gas as i128 * yocto(sim.config.gas_price), "no creation charge on failure");

    // The same shape succeeding: the account creation charge (85+,
    // N-gas-money), account_creation_charge less the create_account exec gas
    // already burnt, taken from the gas refund (lib.rs:1361-1397), on success only.
    let before = sim.balance(ALICE);
    let o = create(&mut sim, ALICE, "d.alice.near", near(1), "dup", None);
    o.assert_success();
    let ok_cost = yocto(before) - yocto(sim.balance(ALICE)) - yocto(near(1));
    let rc = sim.config.runtime_config();
    let price = yocto(sim.config.gas_price);
    let gas = |o: &TxOutcome| {
        let t = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
        let r: u64 = o.receipts.iter().filter(|r| r.refund.is_none()).map(|r| r.gas_burnt.as_gas()).sum();
        (t + r) as i128
    };
    let create_exec = rc.fees.fee(ActionCosts::create_account).exec_fee().gas.as_gas() as i128;
    let charge = yocto(rc.account_creation_charge);
    println!(
        "alice's cost besides the deposit: failed batch {fail_cost} yocto, successful batch {ok_cost} yocto \
         (tokens burnt by the successful one {}), difference {}",
        o.tokens_burnt().as_yoctonear(),
        ok_cost - fail_cost
    );
    println!(
        "account_creation_charge {charge} yocto, gas price {price}; successful batch = its gas + charge - create_account exec gas: {}",
        ok_cost == gas(&o) * price + charge - create_exec * price
    );
    assert_eq!(ok_cost, gas(&o) * price + charge - create_exec * price, "the charge on success");

    // Early failure: the same batch on the account that now exists fails at
    // its first action. nearcore stops at the failing action (lib.rs:1001-1003);
    // each attempted action burns its exec fee as it starts (lib.rs:588-592),
    // so the receipt burns its base exec fee (lib.rs:911) plus create_account's.
    // The Transfer's and AddKey's exec fees, never attempted, come back with
    // the gas refund (prepaid exec gas less gas_burnt, lib.rs:1299-1309).
    let o = sim
        .tx(ALICE, "d.alice.near")
        .create_account()
        .transfer(near(1))
        .add_key(sk("early").public_key(), AccessKey::full_access())
        .transact();
    let rcpt = o.receipts.iter().find(|r| r.executor_id.as_str() == "d.alice.near" && r.refund.is_none()).unwrap();
    let base_exec = rc.fees.fee(ActionCosts::new_action_receipt).exec_fee().gas.as_gas();
    println!(
        "[CreateAccount, Transfer, AddKey] on an existing account: {}; receipt burnt {:.3} Ggas = receipt base {:.3} + create_account {:.3}: {}",
        rerr(rcpt),
        rcpt.gas_burnt.as_gas() as f64 / 1e9,
        base_exec as f64 / 1e9,
        create_exec as f64 / 1e9,
        rcpt.gas_burnt.as_gas() == base_exec + create_exec as u64
    );
    assert!(rerr(rcpt).contains("AccountAlreadyExists"), "{o}");
    assert_eq!(rcpt.gas_burnt.as_gas(), base_exec + create_exec as u64, "only the attempted actions' exec fees");

    // A contract-made batch (p.spawn: [CreateAccount, Transfer, AddKey]) that
    // fails: the deposit goes back to p, the predecessor, not to alice.
    let pk = sk("s").public_key().to_string();
    let spawn = |sim: &mut Sim| {
        sim.call(ALICE, P, "spawn")
            .args_json(json!({ "name": "s", "pk": pk, "yocto": near(1).as_yoctonear().to_string() }))
            .transact()
    };
    spawn(&mut sim).assert_success();
    assert!(exists(&sim, "s.p-probe.near"));
    let p0 = sim.balance(P);
    let o = spawn(&mut sim);
    let child = o.receipts.iter().find(|r| r.executor_id.as_str() == "s.p-probe.near").unwrap();
    let refund: Vec<_> = o.receipts.iter().filter(|r| r.refund == Some(Refund::Deposit)).collect();
    println!(
        "p.spawn of an existing child: {}; deposit refunds {:?}; p's balance {} -> {}",
        rerr(child),
        refund.iter().map(|r| (r.executor_id.as_str(), r.deposit)).collect::<Vec<_>>(),
        p0.as_yoctonear(),
        sim.balance(P).as_yoctonear()
    );
    assert!(rerr(child).contains("AccountAlreadyExists"));
    assert_eq!(refund.len(), 1);
    assert_eq!((refund[0].executor_id.as_str(), refund[0].deposit), (P, near(1)));
    assert_eq!(sim.balance(P), p0, "p got its deposit back");

    // L8: [CreateAccount, AddKey x 9] with no Transfer is 100 + 9 x 82 = 838
    // bytes on 0 balance, past the 770-byte allowance: LackBalanceForState.
    // The same batch ending in DeleteAccount succeeds: no check on an account
    // that is gone. No payout: the balance is 0 (D3).
    fn keys(tx: Tx<'_>) -> Tx<'_> {
        (0..9).fold(tx, |t, i| t.add_key(sk(&format!("z{i}")).public_key(), AccessKey::full_access()))
    }
    let mut s2 = sim.clone();
    let o = keys(s2.tx(ALICE, "z.alice.near").create_account()).transact();
    println!("[CreateAccount, AddKey x9] on 0 balance: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::Action(ActionErrorKind::LackBalanceForState { .. }))), "{o}");
    let o = keys(sim.tx(ALICE, "z.alice.near").create_account()).action(del(ALICE)).transact();
    println!(
        "[CreateAccount, AddKey x9, DeleteAccount]: {}; exists {}; payouts {}",
        err(&o),
        exists(&sim, "z.alice.near"),
        payouts(&o).len()
    );
    o.assert_success();
    assert!(!exists(&sim, "z.alice.near"));
    assert!(payouts(&o).is_empty());
}

/// D3: the liquid balance goes to the beneficiary as a balance refund
/// (`Receipt::new_balance_refund`, from `system`) when it is > 0. A refund
/// never creates an account (actions.rs:929-933), so for an absent
/// beneficiary (an implicit id included) it fails and the amount is gone.
/// The deletes are relayed, so the deleted account pays no gas and the
/// payout is exactly its balance.
#[test]
fn delete_beneficiary() {
    let mut sim = world();
    let near_imp = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    let cases = [
        ("present", "dp.near", BOB),
        ("absent named", "dn.near", "ghost.near"),
        ("absent implicit", "di.near", near_imp),
        ("self", "ds.near", "ds.near"),
    ];
    for (what, id, b) in cases {
        sim.create_account(id, near(5));
        let bob0 = sim.balance(BOB);
        let o = sim.tx(id, id).action(del(b)).relay(RELAYER);
        o.assert_success();
        let ps = payouts(&o);
        println!(
            "{what}: {id} -> {b}: {id} exists {}; payouts {:?}; {b} exists {}",
            exists(&sim, id),
            ps.iter()
                .map(|r| (r.executor_id.as_str(), r.predecessor_id.as_str(), r.deposit.as_yoctonear(), rerr(r)))
                .collect::<Vec<_>>(),
            exists(&sim, b)
        );
        assert!(!exists(&sim, id));
        assert_eq!(ps.len(), 1);
        assert_eq!((ps[0].executor_id.as_str(), ps[0].predecessor_id.as_str(), ps[0].deposit), (b, "system", near(5)));
        if b == BOB {
            assert!(ps[0].is_success());
            assert_eq!(yocto(sim.balance(BOB)) - yocto(bob0), yocto(near(5)));
        } else {
            assert!(rerr(ps[0]).contains("AccountDoesNotExist"), "{o}");
            assert!(!exists(&sim, b), "a refund creates no account");
            // Nothing is sent on: a failed refund is burnt.
            let later: Vec<_> =
                o.receipts.iter().skip_while(|r| r.refund != Some(Refund::AccountDeletion)).skip(1).collect();
            println!(
                "  after it: {:?}",
                later.iter().map(|r| (r.executor_id.as_str(), r.refund, r.deposit.as_yoctonear())).collect::<Vec<_>>()
            );
            assert!(
                later.iter().all(|r| r.refund == Some(Refund::Gas) && r.executor_id.as_str() == RELAYER),
                "only the relayer's gas refund"
            );
        }
    }
    // A zero balance sends nothing.
    sim.create_account("d0.near", Balance::ZERO);
    let o = sim.tx("d0.near", "d0.near").action(del(BOB)).relay(RELAYER);
    println!("zero balance: {}; payouts {}", err(&o), payouts(&o).len());
    o.assert_success();
    assert!(!exists(&sim, "d0.near"));
    assert!(payouts(&o).is_empty());
    // Self-signed instead of relayed: the payout is the balance after the
    // transaction's gas was prepaid, and the unused-gas refund then finds the
    // signer gone.
    sim.create_account("dt.near", near(5));
    let bob0 = sim.balance(BOB);
    let o = sim.tx("dt.near", "dt.near").action(del(BOB)).transact();
    o.assert_success();
    let ps = payouts(&o);
    let gas: Vec<_> = o
        .receipts
        .iter()
        .filter(|r| r.refund == Some(Refund::Gas))
        .map(|r| (r.executor_id.as_str(), r.deposit.as_yoctonear(), rerr(r)))
        .collect();
    println!(
        "self-signed: payout {} yocto (5 NEAR less the prepaid gas {}); gas refunds {gas:?}",
        ps[0].deposit.as_yoctonear(),
        yocto(near(5)) - yocto(ps[0].deposit)
    );
    assert_eq!(yocto(sim.balance(BOB)) - yocto(bob0), yocto(ps[0].deposit));
    assert!(ps[0].deposit < near(5));
}

/// D1, D5, L1: DeleteAccount needs actor = account and no locked balance
/// (actions.rs:777-792); existence is checked first (lib.rs:599-610), and
/// DeleteAccount must be the last action (action_validation.rs:139-142).
#[test]
fn delete_actor_and_staking() {
    let mut sim = world();
    let o = sim.tx(ALICE, BOB).action(del(ALICE)).transact();
    println!("alice deletes bob: {}", err(&o));
    assert!(err(&o).contains("ActorNoPermission"), "{o}");
    assert!(exists(&sim, BOB));
    let o = sim.tx(ALICE, "ghost.near").action(del(ALICE)).transact();
    println!("alice deletes absent ghost.near: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");

    // Staked: locked > 0.
    let s = "locked.near";
    sim.create_account(s, near(100));
    let pk = sim.secret_key(s).public_key();
    let o = sim.tx(s, s).action(StakeAction { stake: near(10), public_key: pk }).transact();
    let a = sim.account(s).unwrap();
    println!("stake 10 NEAR: {}; amount {} locked {}", err(&o), a.amount, a.locked);
    o.assert_success();
    assert_eq!(a.locked, near(10));
    let o = sim.tx(s, s).action(del(ALICE)).transact();
    println!("delete while staked: {}", err(&o));
    assert!(err(&o).contains("DeleteAccountStaking"), "{o}");
    assert!(exists(&sim, s));

    // D5: nothing may follow DeleteAccount; the transaction is invalid.
    sim.create_account("df.near", near(5));
    let o = sim.tx("df.near", "df.near").action(del(ALICE)).transfer(Balance::from_yoctonear(1)).transact();
    println!("[DeleteAccount, Transfer]: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::InvalidTx(_))), "{o}");
    assert!(err(&o).contains("DeleteActionMustBeFinal"), "{o}");
}

/// Writes one data record of `n` bytes in all (key "k" + value + 40) so that
/// `usage - minus` becomes `target`. Returns the usage after.
fn fill_to(sim: &mut Sim, id: &str, minus: u64, target: u64) -> u64 {
    let now = usage(sim, id) - minus;
    let value = target - now - 40 - 1;
    sim.set_state(id, b"k", Some(&vec![b'x'; value as usize]));
    usage(sim, id)
}

/// D2: DeleteAccountWithLargeState iff storage minus the contract's own
/// bytes exceeds 10,000 (actions.rs:342-369, get_contract_storage_usage
/// :426-440: a local contract's code length, or a global contract's
/// identifier, FixDeleteAccountGlobalContractStorageUsage at 85). The
/// boundary is hit exactly: 10,000 passes, 10,001 fails.
#[test]
fn delete_large_state() {
    let (wasm, _) = probe_wasm("probe");
    let mut base = world();
    base.create_account("pub.near", near(10_000));
    let o = base.tx("pub.near", "pub.near").deploy_global(wasm.clone(), GlobalContractDeployMode::CodeHash).transact();
    o.assert_success();
    let hash = CryptoHash::hash_bytes(&wasm);
    // A plain account, a local contract (the probe, 179 KB) and a global one.
    base.create_account("plain.near", near(100));
    base.deploy("local.near", wasm.clone());
    base.create_account("global.near", near(100));
    base.tx("global.near", "global.near")
        .use_global(GlobalContractIdentifier::CodeHash(hash))
        .transact()
        .assert_success();
    let cases = [
        ("plain", "plain.near", 0u64),
        ("local contract", "local.near", wasm.len() as u64),
        ("global contract", "global.near", 32),
    ];
    for (what, id, minus) in cases {
        println!("{what}: {id} uses {} bytes, {} of them the contract's", usage(&base, id), minus);
        for (target, ok) in [(10_000u64, true), (10_001, false)] {
            let mut sim = base.clone();
            let u = fill_to(&mut sim, id, minus, target);
            let o = sim.tx(id, id).action(del(ALICE)).transact();
            println!("  usage {u} (minus the contract: {}): {}", u - minus, err(&o));
            if ok {
                o.assert_success();
                assert!(!exists(&sim, id));
            } else {
                assert!(err(&o).contains("DeleteAccountWithLargeState"), "{o}");
                assert!(exists(&sim, id));
            }
        }
    }
    // The local contract passes at usage far above 10,000: code is excluded.
    assert!(wasm.len() > 10_000);
}

/// D7: a receipt that reaches a deleted account. A call, a key action and a
/// Stake fail with AccountDoesNotExist (existence before the actor check);
/// a Transfer fails and its deposit is refunded, unless the id is implicit,
/// in which case it creates the account again; a refund to it fails and is
/// burnt (actions.rs:842-879).
#[test]
fn receipts_to_deleted() {
    let mut sim = world();
    let gone = "gone.near";
    sim.create_account(gone, near(5));
    let pk = sim.secret_key(gone).public_key();
    sim.tx(gone, gone).action(del(BOB)).relay(RELAYER).assert_success();
    assert!(!exists(&sim, gone));

    let a0 = sim.balance(ALICE);
    let o = sim.call(ALICE, gone, "mark").args_json(json!({ "tag": "x" })).deposit(near(1)).transact();
    let refunds: Vec<_> = o
        .receipts
        .iter()
        .filter(|r| r.refund == Some(Refund::Deposit))
        .map(|r| (r.executor_id.as_str(), r.deposit))
        .collect();
    println!("call with 1 NEAR to deleted {gone}: {}; deposit refunds {refunds:?}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");
    assert_eq!(refunds, [(ALICE, near(1))]);
    assert_eq!(yocto(a0) - yocto(sim.balance(ALICE)), yocto(o.effects().gas_paid()));

    let o = sim.tx(ALICE, gone).transfer(near(1)).transact();
    let refunds: Vec<_> = o
        .receipts
        .iter()
        .filter(|r| r.refund == Some(Refund::Deposit))
        .map(|r| (r.executor_id.as_str(), r.deposit))
        .collect();
    println!(
        "transfer of 1 NEAR to deleted {gone}: {}; deposit refunds {refunds:?}; exists {}",
        err(&o),
        exists(&sim, gone)
    );
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");
    assert_eq!(refunds, [(ALICE, near(1))]);
    assert!(!exists(&sim, gone));

    let o = sim.tx(ALICE, gone).add_key(sk("n").public_key(), AccessKey::full_access()).transact();
    println!("AddKey to deleted {gone} by alice: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");
    let o = sim.tx(ALICE, gone).action(StakeAction { stake: near(1), public_key: pk }).transact();
    println!("Stake on deleted {gone} by alice: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::AccountDoesNotExist(_))), "{o}");

    // A NEAR-implicit account: deleted, then a Transfer creates it again.
    let isk = sk("implicit-one");
    let imp: String = isk.public_key().key_data().iter().map(|b| format!("{b:02x}")).collect();
    sim.tx(ALICE, &imp).transfer(near(1)).transact().assert_success();
    sim.set_key(&imp, &isk);
    sim.tx(&imp, &imp).action(del(ALICE)).transact().assert_success();
    assert!(!exists(&sim, &imp));
    let o = sim.tx(ALICE, &imp).transfer(near(1)).transact();
    println!(
        "transfer to deleted implicit {}..: {}; exists {}; {} bytes; its key back {}",
        &imp[..8],
        err(&o),
        exists(&sim, &imp),
        usage(&sim, &imp),
        sim.access_key(&imp, &isk.public_key()).is_some()
    );
    o.assert_success();
    assert_eq!((sim.balance(&imp), usage(&sim, &imp)), (near(1), 182));
    assert!(sim.access_key(&imp, &isk.public_key()).is_some());

    // A refund to a deleted account: r calls p.fail with 1 NEAR, and deletes
    // itself (a local receipt) in the block where p.fail runs; the deposit
    // refund arrives a block later and fails.
    let r = "r.near";
    sim.create_account(r, near(10));
    let call = sim.call(r, P, "fail").args_json(json!({ "key": "x" })).deposit(near(1)).submit();
    sim.step();
    let d = sim.tx(r, r).action(del(BOB)).submit();
    sim.step();
    sim.settle();
    let (oc, od) = (sim.outcome(call), sim.outcome(d));
    od.assert_success();
    let hdel =
        od.receipts.iter().find(|x| x.actions.iter().any(|a| a.contains("DeleteAccount"))).map(|x| x.block_height);
    let failed = oc.receipt("fail").unwrap();
    let refund = oc.receipts.iter().find(|x| x.refund == Some(Refund::Deposit)).unwrap();
    println!(
        "r's delete at #{:?} (via conversion: {}); p.fail at #{}; deposit refund to {} at #{}: {}; later receipts with value {}",
        hdel,
        od.transaction.as_ref().map(|t| t.block_height).unwrap_or(0),
        failed.block_height,
        refund.executor_id,
        refund.block_height,
        rerr(refund),
        oc.receipts
            .iter()
            .skip_while(|x| x.refund != Some(Refund::Deposit))
            .skip(1)
            .filter(|x| !x.deposit.is_zero() && x.refund != Some(Refund::Gas))
            .count()
    );
    assert_eq!(refund.executor_id.as_str(), r);
    assert!(rerr(refund).contains("AccountDoesNotExist"));
    assert!(!exists(&sim, r));
}

/// Deletion removes the account, its code, keys and data
/// (core/store/src/utils/mod.rs remove_account); CreateAccount then makes a
/// fresh one: 100 bytes plus its key, no code, no old keys or data.
#[test]
fn recreate_clears_keys_and_data() {
    let (wasm, _) = probe_wasm("probe");
    let mut sim = world();
    let x = "x.alice.near";
    create(&mut sim, ALICE, x, near(10), "x1", Some(&wasm)).assert_success();
    sim.call(ALICE, x, "put").args_json(json!({ "key": "d", "value": "1" })).transact().assert_success();
    sim.tx(x, x).add_key(sk("x1b").public_key(), AccessKey::full_access()).transact().assert_success();
    println!(
        "before: {} bytes, {} keys, code {}, data {:?}",
        usage(&sim, x),
        sim.access_keys(x).len(),
        sim.account(x).unwrap().code_hash,
        sim.view_state(x, b"")
            .iter()
            .map(|(k, v)| (String::from_utf8_lossy(k).into_owned(), v.len()))
            .collect::<Vec<_>>()
    );
    sim.tx(x, x).action(del(ALICE)).transact().assert_success();
    assert!(!exists(&sim, x));
    let o = create(&mut sim, ALICE, x, near(1), "x2", None);
    o.assert_success();
    let a = sim.account(x).unwrap();
    let keys: Vec<String> = sim.access_keys(x).iter().map(|(k, _)| format!("{k:?}")).collect();
    println!(
        "after re-creation: {} bytes, keys {keys:?}, code {}, data {:?}",
        a.storage_usage,
        a.code_hash,
        sim.view_state(x, b"")
    );
    assert_eq!((a.amount, a.storage_usage, a.code_hash), (near(1), 182, CryptoHash::default()));
    assert_eq!(sim.access_keys(x).len(), 1);
    assert!(sim.access_key(x, &sk("x2").public_key()).is_some());
    assert!(sim.access_key(x, &sk("x1").public_key()).is_none());
    assert!(sim.access_key(x, &sk("x1b").public_key()).is_none());
    assert!(sim.view_state(x, b"").is_empty());
    let o = sim.call(ALICE, x, "get").args_json(json!({ "key": "d" })).transact();
    println!("a call to the re-created account: {}", err(&o));
    assert!(o.is_failure(), "no code");
}

/// p's `chain` on `x`: kid `q.mark("k")`, callback `x.mark("cb")`.
fn chain_tx<'a>(sim: &'a mut Sim, x: &str) -> Tx<'a> {
    let kids =
        json!([{ "receiver": Q, "method": "mark", "args": "{\"tag\":\"k\"}", "static_ggas": 10000, "weight": 1 }]);
    let cb = json!({ "method": "mark", "args": "{\"tag\":\"cb\"}", "static_ggas": 10000, "weight": 1 });
    sim.call(ALICE, x, "chain").args_json(json!({ "kids": kids, "cb": cb }))
}

/// The callback `x.mark` of transaction `tx`, if it ran.
fn cb_of(sim: &Sim, tx: CryptoHash, x: &str) -> Option<ReceiptOutcome> {
    sim.outcome(tx).receipts.into_iter().find(|r| r.executor_id.as_str() == x && r.method_names == ["mark"])
}

/// x deletes itself (local: runs in the block that converts it).
fn delete_now(sim: &mut Sim, x: &str) {
    let d = sim.tx(x, x).action(del(ALICE)).submit();
    sim.step();
    sim.outcome(d).assert_success();
    assert!(!exists(sim, x));
}

/// x is created again with the probe, without settling (two blocks).
fn recreate_now(sim: &mut Sim, x: &str, wasm: &[u8]) {
    let k = sk("again");
    let c = sim
        .tx(ALICE, x)
        .create_account()
        .transfer(near(10))
        .add_key(k.public_key(), AccessKey::full_access())
        .deploy(wasm.to_vec())
        .submit();
    sim.step();
    sim.step();
    sim.outcome(c).assert_success();
    sim.set_key(x, &k);
}

/// D4, postponed receipts: a callback waiting at x for its data survives
/// x's deletion. With x still deleted when the data arrives, it runs and
/// fails AccountDoesNotExist; with x created again, it runs on the new
/// account. The data is held by `Fault::HoldResult`.
#[test]
fn delete_leaves_postponed_callback() {
    let (wasm, _) = probe_wasm("probe");
    let mut sim = world();
    let x = "x.alice.near";
    create(&mut sim, ALICE, x, near(10), "x1", Some(&wasm)).assert_success();
    let tx = chain_tx(&mut sim, x).inject(Receipts::call(Q, "mark"), Fault::HoldResult(12)).submit();
    sim.run_until(10, |s| s.outcome(tx).receipts.iter().any(|r| r.executor_id.as_str() == Q)).unwrap();
    sim.step();
    assert!(cb_of(&sim, tx, x).is_none(), "the callback waits for q's result");
    delete_now(&mut sim, x);
    println!("x deleted at #{} with its callback postponed; pending: {}", sim.height(), sim.outcome(tx).pending.len());

    let mut a = sim.clone();
    a.settle();
    let cb = cb_of(&a, tx, x);
    println!("x still deleted when the data arrives: callback {:?}", cb.as_ref().map(|r| (r.block_height, rerr(r))));
    let cb = cb.expect("the postponed callback ran");
    assert!(matches!(cb.failure(), Some(Failure::AccountDoesNotExist(_))), "{}", rerr(&cb));

    let mut b = sim.clone();
    recreate_now(&mut b, x, &wasm);
    assert!(cb_of(&b, tx, x).is_none());
    b.settle();
    let cb = cb_of(&b, tx, x);
    let marks = b.view(x, "marks", json!({})).json::<String>();
    println!(
        "x created again before the data arrives: callback {:?}; x's marks {marks:?}",
        cb.as_ref().map(|r| (r.block_height, rerr(r)))
    );
    assert!(cb.expect("it ran").is_success());
    assert_eq!(marks, "cb,", "it ran on the new account");
}

/// D4, received data: q's result reaches x before the callback does
/// (`Fault::Hold` on the callback). The stored data survives x's deletion:
/// the callback, arriving later, finds it and runs: it fails while x is
/// deleted, and succeeds on a re-created x.
#[test]
fn delete_leaves_received_data() {
    let (wasm, _) = probe_wasm("probe");
    let mut sim = world();
    let x = "x.alice.near";
    create(&mut sim, ALICE, x, near(10), "x1", Some(&wasm)).assert_success();
    let tx = chain_tx(&mut sim, x).inject(Receipts::callback("mark"), Fault::Hold(12)).submit();
    sim.run_until(10, |s| s.outcome(tx).receipts.iter().any(|r| r.executor_id.as_str() == Q)).unwrap();
    sim.step();
    sim.step();
    assert!(cb_of(&sim, tx, x).is_none(), "the callback is held");
    delete_now(&mut sim, x);
    println!("x deleted at #{} with q's data delivered and the callback held", sim.height());

    let mut a = sim.clone();
    a.settle();
    let cb = cb_of(&a, tx, x);
    println!("x still deleted when the callback arrives: {:?}", cb.as_ref().map(|r| (r.block_height, r.held, rerr(r))));
    let cb = cb.expect("the callback ran: its data was there");
    assert!(matches!(cb.failure(), Some(Failure::AccountDoesNotExist(_))), "{}", rerr(&cb));

    let mut b = sim.clone();
    recreate_now(&mut b, x, &wasm);
    b.settle();
    let cb = cb_of(&b, tx, x);
    let marks = b.view(x, "marks", json!({})).json::<String>();
    println!(
        "x created again before the callback arrives: {:?}; x's marks {marks:?}",
        cb.as_ref().map(|r| (r.block_height, rerr(r)))
    );
    assert!(cb.expect("it ran on the old data").is_success());
    assert_eq!(marks, "cb,");
}

/// D4, yields: a parked yield survives its account's deletion. Its timeout
/// then runs the callback, which fails; after re-creation the new account
/// can resume it (by data id: the old one's storage is gone).
#[test]
fn delete_leaves_yield() {
    let (awasm, _) = probe_wasm("async_probe");
    let mut sim = world();
    let y = "y.alice.near";
    create(&mut sim, ALICE, y, near(10), "y1", Some(&awasm)).assert_success();
    let o = sim.call(ALICE, y, "yield_create").args_json(json!({ "cb_ggas": 5000, "cb_weight": 1 })).transact();
    o.assert_success();
    let [py] = <[_; 1]>::try_from(sim.yields()).expect("one parked yield");
    sim.tx(y, y).action(del(ALICE)).transact().assert_success();
    assert!(!exists(&sim, y));
    let left = sim.yields();
    println!(
        "after y's deletion: {} parked yield(s), expires at #{} (now #{})",
        left.len(),
        py.expires_at,
        sim.height()
    );
    assert_eq!(left.len(), 1, "the yield is still parked");
    assert_eq!(left[0].data_id, py.data_id);

    let mut a = sim.clone();
    let out = a.expire(&py);
    let cb = out.receipts.iter().find(|r| r.method_names == ["on_yield"]);
    println!("timeout with y deleted: on_yield {:?}", cb.map(|r| (r.block_height, rerr(r))));
    assert!(matches!(cb.expect("the callback ran").failure(), Some(Failure::AccountDoesNotExist(_))));

    let mut b = sim.clone();
    let k = sk("y2");
    b.tx(ALICE, y)
        .create_account()
        .transfer(near(10))
        .add_key(k.public_key(), AccessKey::full_access())
        .deploy(awasm.clone())
        .transact()
        .assert_success();
    let hex: String = py.data_id.as_ref().iter().map(|x| format!("{x:02x}")).collect();
    let r = b.call(ALICE, y, "resume").args_json(json!({ "bytes": 10, "data_id": hex })).transact();
    r.assert_success();
    let logs = b.outcome(py.tx).receipts.iter().find(|r| r.method_names == ["on_yield"]).map(|r| r.logs.clone());
    println!("re-created y resumes the old yield: {}; on_yield logs {logs:?}", r.json::<bool>());
    assert!(r.json::<bool>());
    assert_eq!(logs, Some(vec!["payload 10".to_owned()]));
}

/// P1: DeployContract needs actor = account; storage becomes usage - old
/// code + new code, data kept (actions.rs:290-311); at most 10 deploys per
/// receipt (max_deploy_actions_per_receipt, action_validation.rs:22-37);
/// code at most 4 MiB (max_contract_size).
#[test]
fn deploy_storage_delta() {
    let (wasm, _) = probe_wasm("probe");
    let (awasm, _) = probe_wasm("async_probe");
    let tiny = b"\0asm\x01\0\0\0".to_vec();
    let mut sim = world();
    let d = "d.alice.near";
    create(&mut sim, ALICE, d, near(10), "d", Some(&wasm)).assert_success();
    let u0 = usage(&sim, d);
    println!("created with the probe ({} bytes): {u0} bytes", wasm.len());
    assert_eq!(u0, 182 + wasm.len() as u64);
    sim.call(ALICE, d, "put").args_json(json!({ "key": "k", "value": "v" })).transact().assert_success();
    let u1 = usage(&sim, d);
    sim.tx(d, d).deploy(awasm.clone()).transact().assert_success();
    let u2 = usage(&sim, d);
    println!("with data {u1}; after deploying the async probe ({} bytes): {u2}", awasm.len());
    assert_eq!(u2, u1 - wasm.len() as u64 + awasm.len() as u64);
    assert!(sim.state(d, b"k").is_some(), "data kept");

    let o = sim.tx(ALICE, BOB).deploy(tiny.clone()).transact();
    println!("alice deploys to bob: {}", err(&o));
    assert!(err(&o).contains("ActorNoPermission"), "{o}");

    let deploys = |sim: &mut Sim, n: usize| (0..n).fold(sim.tx(d, d), |t, _| t.deploy(tiny.clone())).transact();
    let o = deploys(&mut sim, 10);
    println!("10 deploys in one receipt: {}; {} bytes", err(&o), usage(&sim, d));
    o.assert_success();
    assert_eq!(usage(&sim, d), u2 - awasm.len() as u64 + tiny.len() as u64);
    let o = deploys(&mut sim, 11);
    println!("11 deploys: {}", err(&o));
    assert!(matches!(o.failure(), Some(Failure::InvalidTx(InvalidTxError::ActionsValidation(_)))), "{o}");
    assert!(err(&o).contains("TotalNumberOfDeployActionsExceeded"), "{o}");

    // A factory batch whose deposit does not cover the code: the whole batch fails.
    let o = sim
        .tx(ALICE, "u.alice.near")
        .create_account()
        .transfer(near(1))
        .add_key(sk("u").public_key(), AccessKey::full_access())
        .deploy(wasm.clone())
        .transact();
    println!(
        "create with 1 NEAR and a {}-byte deploy (needs {} yocto): {}",
        wasm.len(),
        sim.storage_cost(182 + wasm.len() as u64).as_yoctonear(),
        err(&o)
    );
    assert!(matches!(o.failure(), Some(Failure::Action(ActionErrorKind::LackBalanceForState { .. }))), "{o}");
    assert!(!exists(&sim, "u.alice.near"));

    let lim = &sim.config.runtime_config().wasm_config.limit_config;
    println!(
        "limits: max_contract_size {}, max_transaction_size {}, max_deploy_actions_per_receipt {} \
         (a 4 MiB deploy does not fit in a transaction; only a contract could send one)",
        lim.max_contract_size, lim.max_transaction_size, lim.max_deploy_actions_per_receipt
    );
    assert_eq!(lim.max_contract_size, 4 * 1024 * 1024);
    assert_eq!(lim.max_deploy_actions_per_receipt, 10);
}

/// The position of each receipt in the order receipts ran.
fn pos(order: &[ReceiptOutcome], id: CryptoHash) -> usize {
    order.iter().position(|r| r.id == id).unwrap()
}

/// D6: a receipt holding one DeleteAccount and no inputs is instant: it
/// runs right after the receipt that made it, in the same chunk
/// (receipt.rs:468-491, lib.rs:1222-1224, :2747-2775). The only way the
/// probes can make one is a delegate whose inner action is the
/// DeleteAccount. Marks from other users land in the same block, after the
/// Delegate receipt: the delete runs before them. A delegate whose inner
/// action is a Transfer is the control: its inner receipt runs a block later.
#[test]
fn instant_delete_via_delegate() {
    let mut sim = world();
    let users = ["w0.near", "w1.near", "w2.near"];
    for u in users {
        sim.create_account(u, near(10));
    }
    for (what, sender, delete) in [("DeleteAccount", "d1.near", true), ("Transfer (control)", "d2.near", false)] {
        sim.create_account(sender, near(5));
        let h = sim.height();
        let first = sim.call(users[0], P, "mark").args_json(json!({ "tag": "first" })).submit();
        let inner = sim.tx(sender, sender);
        let inner = if delete { inner.action(del(BOB)) } else { inner.transfer(Balance::from_yoctonear(1)) };
        let signed = inner.sign_delegate(h + 100);
        let rel = sim.tx(RELAYER, sender).action(signed).submit();
        let after: Vec<CryptoHash> =
            users[1..].iter().map(|u| sim.call(*u, P, "mark").args_json(json!({ "tag": u })).submit()).collect();
        sim.settle();
        let order = sim.receipts_in(h + 1..);
        let o = sim.outcome(rel);
        o.assert_success();
        let outer = o.receipts.iter().find(|r| r.actions.iter().any(|a| a.contains("Delegate"))).unwrap();
        let kind = if delete { "DeleteAccount" } else { "Transfer" };
        let inner = o
            .receipts
            .iter()
            .find(|r| r.refund.is_none() && r.id != outer.id && r.actions.iter().any(|a| a.contains(kind)))
            .unwrap();
        let mark_of =
            |t: CryptoHash| sim.outcome(t).receipt("mark").map(|r| (r.block_height, pos(&order, r.id))).unwrap();
        println!(
            "{what}: Delegate on {sender} at #{} pos {}; inner at #{} pos {}; other marks (#, pos): first {:?}, after {:?}{}",
            outer.block_height,
            pos(&order, outer.id),
            inner.block_height,
            pos(&order, inner.id),
            mark_of(first),
            after.iter().map(|t| mark_of(*t)).collect::<Vec<_>>(),
            if delete {
                let p = &payouts(&o)[0];
                format!("; payout to {} at #{}", p.executor_id, p.block_height)
            } else {
                String::new()
            }
        );
        if delete {
            assert!(inner.is_success());
            assert!(!exists(&sim, sender));
            assert_eq!(inner.block_height, outer.block_height, "same block");
            assert_eq!(pos(&order, inner.id), pos(&order, outer.id) + 1, "right after its creator");
            for t in &after {
                let (hb, p) = mark_of(*t);
                assert_eq!(hb, outer.block_height, "the later marks share the block");
                assert!(p > pos(&order, inner.id), "and run after the delete");
            }
            assert!(payouts(&o)[0].block_height > outer.block_height, "the payout is not instant");
        } else {
            assert_eq!(inner.block_height, outer.block_height + 1, "a non-instant inner receipt waits a block");
        }
    }

    // The creator a local receipt: the sender relays its own delegate
    // (signed with a second key, so the two nonces are independent).
    let s = "d3.near";
    sim.create_account(s, near(5));
    let k2 = sk("d3-second");
    sim.tx(s, s).add_key(k2.public_key(), AccessKey::full_access()).transact().assert_success();
    let h = sim.height();
    let signed = sim.tx(s, s).action(del(BOB)).sign_with(&k2).sign_delegate(h + 100);
    let rel = sim.tx(s, s).action(signed).submit();
    sim.settle();
    let o = sim.outcome(rel);
    let order = sim.receipts_in(h + 1..);
    let conv = o.transaction.as_ref().unwrap().block_height;
    let outer = o.receipts.iter().find(|r| r.actions.iter().any(|a| a.contains("Delegate"))).unwrap();
    let inner = o
        .receipts
        .iter()
        .find(|r| r.refund.is_none() && r.actions.iter().any(|a| a.contains("DeleteAccount")) && r.id != outer.id)
        .unwrap();
    println!(
        "local: converted at #{conv}; Delegate at #{} pos {}; inner DeleteAccount at #{} pos {}: {}",
        outer.block_height,
        pos(&order, outer.id),
        inner.block_height,
        pos(&order, inner.id),
        rerr(inner)
    );
    o.assert_success();
    assert_eq!((outer.block_height, inner.block_height), (conv, conv));
    assert_eq!(pos(&order, inner.id), pos(&order, outer.id) + 1);
    assert!(!exists(&sim, s));
}

fn ggas(g: u64) -> f64 {
    g as f64 / 1e9
}

/// F1: the action fees at protocol 88 against what the sim burns. For a
/// transaction, the conversion burns the send fees and the receipt the
/// exec fees (the creator pays both). Printed in Ggas beside the design's
/// rounded-up figures.
#[test]
fn account_action_fees() {
    let (wasm, _) = probe_wasm("probe");
    let mut sim = world();
    let fees = sim.config.runtime_config().fees.clone();
    let f = |c: ActionCosts, sir: bool| (fees.fee(c).send_fee(sir).gas.as_gas(), fees.fee(c).exec_fee().gas.as_gas());
    for (name, c) in [
        ("receipt", ActionCosts::new_action_receipt),
        ("create_account", ActionCosts::create_account),
        ("delete_account", ActionCosts::delete_account),
        ("deploy_base", ActionCosts::deploy_contract_base),
        ("add_full_access_key", ActionCosts::add_full_access_key),
    ] {
        let (s, e) = f(c, false);
        println!("{name}: send {:.3} exec {:.3} Ggas", ggas(s), ggas(e));
    }
    let (bs, be) = f(ActionCosts::deploy_contract_byte, true);
    let (bn, _) = f(ActionCosts::deploy_contract_byte, false);
    println!(
        "deploy per KB: send same account {:.3}, other account {:.3}, exec {:.3} Ggas",
        ggas(bs * 1000),
        ggas(bn * 1000),
        ggas(be * 1000)
    );
    let up = |g: u64| g.div_ceil(1_000_000_000);
    assert_eq!(
        [f(ActionCosts::new_action_receipt, false).0, f(ActionCosts::new_action_receipt, false).1].map(up),
        [109, 109]
    );
    assert_eq!([f(ActionCosts::create_account, false).0, f(ActionCosts::create_account, false).1].map(up), [500, 7200]);
    assert_eq!([f(ActionCosts::delete_account, true).0, f(ActionCosts::delete_account, true).1].map(up), [148, 148]);
    assert_eq!(
        [f(ActionCosts::deploy_contract_base, true).0, f(ActionCosts::deploy_contract_base, true).1].map(up),
        [185, 185]
    );
    assert_eq!([bs, bn, be].map(|g| (g * 1000 + 50_000_000) / 100_000_000), [68, 477, 646], "per KB, in 0.1 Ggas");

    // [CreateAccount, Transfer, AddKey(full)] from alice to a new child (not sir).
    let c = "f.alice.near";
    let o = create(&mut sim, ALICE, c, near(1), "f", None);
    o.assert_success();
    let send = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
    let exec = o.receipts.iter().find(|r| r.executor_id.as_str() == c).unwrap().gas_burnt.as_gas();
    let (ts, te) = transfer_fees(&sim, false, c);
    let parts = [
        f(ActionCosts::new_action_receipt, false),
        f(ActionCosts::create_account, false),
        (ts, te),
        f(ActionCosts::add_full_access_key, false),
    ];
    let (ws, we) = parts.iter().fold((0, 0), |(a, b), (s, e)| (a + s, b + e));
    let rounded: u64 = parts.iter().map(|(s, e)| up(*s) + up(*e)).sum();
    println!(
        "[CreateAccount, Transfer, AddKey]: send {:.3} + exec {:.3} = {:.3} Ggas; table rounded up per part {rounded}",
        ggas(send),
        ggas(exec),
        ggas(send + exec)
    );
    assert_eq!((send, exec), (ws, we));
    assert_eq!(rounded, 8354);

    // A lone DeleteAccount, self-signed (sir).
    let o = sim.tx(c, c).action(del(ALICE)).transact();
    o.assert_success();
    let send = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
    let exec =
        o.receipts.iter().find(|r| r.executor_id.as_str() == c && r.refund.is_none()).unwrap().gas_burnt.as_gas();
    let parts = [f(ActionCosts::new_action_receipt, true), f(ActionCosts::delete_account, true)];
    let rounded: u64 = parts.iter().map(|(s, e)| up(*s) + up(*e)).sum();
    println!(
        "[DeleteAccount]: send {:.3} + exec {:.3} = {:.3} Ggas; rounded {rounded}",
        ggas(send),
        ggas(exec),
        ggas(send + exec)
    );
    assert_eq!((send, exec), (parts[0].0 + parts[1].0, parts[0].1 + parts[1].1));
    assert_eq!(rounded, 514);

    // Deploys: to itself (sir) and to a new child (not sir).
    let n = wasm.len() as u64;
    let g = "g.alice.near";
    let o = create(&mut sim, ALICE, g, near(10), "g", Some(&wasm));
    o.assert_success();
    let send = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
    let exec = o.receipts.iter().find(|r| r.executor_id.as_str() == g).unwrap().gas_burnt.as_gas();
    let (ts, te) = transfer_fees(&sim, false, g);
    let (ds, de) = f(ActionCosts::deploy_contract_base, false);
    let want_s = ws - transfer_fees(&sim, false, c).0 + ts + ds + bn * n;
    let want_e = we - transfer_fees(&sim, false, c).1 + te + de + be * n;
    println!(
        "[CreateAccount, Transfer, AddKey, Deploy({n} bytes)]: send {:.3} exec {:.3} Ggas",
        ggas(send),
        ggas(exec)
    );
    assert_eq!((send, exec), (want_s, want_e));
    let o = sim.tx(g, g).deploy(wasm.clone()).transact();
    o.assert_success();
    let send = o.transaction.as_ref().unwrap().gas_burnt.as_gas();
    let exec =
        o.receipts.iter().find(|r| r.executor_id.as_str() == g && r.refund.is_none()).unwrap().gas_burnt.as_gas();
    let (rs, re) = f(ActionCosts::new_action_receipt, true);
    let (ds, de) = f(ActionCosts::deploy_contract_base, true);
    println!("[Deploy({n} bytes)] to itself: send {:.3} exec {:.3} Ggas", ggas(send), ggas(exec));
    assert_eq!((send, exec), (rs + ds + bs * n, re + de + be * n));
}
