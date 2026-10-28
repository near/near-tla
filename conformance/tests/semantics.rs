//! Receipt semantics the library encodes, observed in the sim on the probe
//! contracts: local-receipt priority, signer propagation and the atomicity
//! of a `[DeleteKey, FunctionCall]` receipt (docs/SEMANTICS.md: "Local
//! receipts first", "Signer and signer public key propagate", "Multi-action
//! receipts are atomic"), and yield/resume on the async probe: the resume
//! payload limit, two resumes in one block, a resume after the timeout and
//! a resume of another account's yield ("Yield and resume (NEP-519)",
//! "N-yield-payload"); and a later receipt overtaking an earlier one on
//! the same sender-receiver pair ("No per-pair order"); and delegate
//! actions (NEP-366, "Delegate actions"): the signer and predecessor the
//! inner call sees, replay, expiry, the deposit refund paths, and the
//! function-call-key checks on either side; and per-byte storage staking
//! ("Balance must cover storage", B2): the bytes a write, a key and an
//! implicit account add, `LackBalanceForState` on growth (the boundary
//! inclusive, the deposit counted, the whole receipt reverted, a callback
//! failing after a payout), the 770-byte zero-balance allowance, and the
//! signer's check at conversion; a local receipt that finds the chunk full
//! queued behind the delayed receipts ("Local receipts first"); the yield
//! deadline of 200 blocks; on `probe2`, the `_with_id` yield's duplicate
//! check and reuse, a yield's deposit, a returned yield and the callback's
//! signer; and the delegate's signature, sender, nonce bound and
//! one-per-transaction checks.
//! `cargo test --test semantics -- --nocapture` prints what was observed.
use near_contract_sim::prelude::*;
use near_contract_sim::{
    AccessKey, AccessKeyPermission, ActionErrorKind, CryptoHash, FunctionCallPermission, InvalidTxError, ReceiptOutcome,
    TxOutcome,
};
use near_tla_conformance::probe_wasm;
use serde_json::{Value, json};

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const P: &str = "p-probe.near";
const Q: &str = "q-probe.near";

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

/// Local receipts: a transaction whose signer is its receiver becomes a local receipt
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
    println!("local receipt: alice's mark ran at #{ha}, p's self-signed mark at #{hp}; marks = {}", marks(&sim));
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
    println!("self-call: chain's self-call mark at #{hc}, bob's at #{hb}, p's self-signed at #{hp}; marks = {}", marks(&sim));
    assert_eq!((hc, hb), (hp, hp), "all three run in one block");
    // p's transaction receipt is local and runs first; bob's receipt and
    // chain's self-call arrive as incoming receipts, in that order.
    assert_eq!(marks(&sim), "p,b,c,", "only the transaction's own receipt is local");
}

fn records(o: &TxOutcome) -> Vec<Value> {
    o.receipts
        .iter()
        .flat_map(|r| r.logs.iter())
        .filter_map(|l| l.strip_prefix("record "))
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// Signer propagation: every receipt of a transaction sees its signer and the key that
/// signed it, callbacks and cross-contract children included; the
/// predecessor is the immediate creator. alice holds two full-access keys
/// and signs with the second.
#[test]
fn signer_propagates_to_children_and_callbacks() {
    let mut sim = world();
    let first = sim.secret_key(ALICE).public_key();
    let second = SecretKey::from_seed(KeyType::ED25519, "alice-second");
    sim.tx(ALICE, ALICE).add_key(second.public_key(), AccessKey::full_access()).transact().assert_success();
    let kids = json!([{ "receiver": Q, "method": "record", "args": "{\"tag\":\"child\"}", "static_ggas": 10000, "weight": 1 }]);
    let cb = json!({ "method": "record", "args": "{\"tag\":\"cb\"}", "static_ggas": 10000, "weight": 1 });
    let o = sim.call(ALICE, P, "chain").args_json(json!({ "kids": kids, "cb": cb })).sign_with(&second).transact();
    o.assert_success();
    let rs = records(&o);
    println!("records: {rs:?}");
    assert_eq!(rs.len(), 2);
    let pk = second.public_key().to_string();
    assert_ne!(pk, first.to_string());
    for r in &rs {
        assert_eq!(r["signer"], ALICE);
        assert_eq!(r["signer_pk"], pk.as_str(), "the signing key, not alice's first key");
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

const Y: &str = "y-probe.near";
const Y2: &str = "y2-probe.near";

fn yield_world() -> Sim {
    let (wasm, _) = probe_wasm("async_probe");
    Fixture::new()
        .account(ALICE, Balance::from_near(100))
        .account(BOB, Balance::from_near(100))
        .contract(Y, wasm.clone())
        .contract(Y2, wasm)
        .build()
}

/// y.yield_create (callback static 5 Tgas, weight 1), left parked.
fn park(sim: &mut Sim) -> CryptoHash {
    let o = sim.call(ALICE, Y, "yield_create").args_json(json!({ "cb_ggas": 5000, "cb_weight": 1 })).transact();
    o.assert_success();
    assert_eq!(sim.yields().len(), 1);
    o.hash
}

fn resume<'a>(sim: &'a mut Sim, signer: &str, bytes: u32) -> Tx<'a> {
    sim.call(signer, Y, "resume").args_json(json!({ "bytes": bytes }))
}

/// The logs of the yield callback of transaction `tx`, if it ran.
fn on_yield_logs(sim: &Sim, tx: CryptoHash) -> Option<Vec<String>> {
    sim.outcome(tx).receipts.iter().find(|r| r.method_names == ["on_yield"]).map(|r| r.logs.clone())
}

/// The resume payload limit is 1024 bytes (not KiB): 1024 is delivered; 1025,
/// and 1 MiB, fail the resumer with a host error, and the yield stays
/// parked (it then times out). nearcore: host.rs:4505-4510 compares the
/// payload's length in bytes with max_yield_payload_size = 1024.
#[test]
fn yield_payload_limit_is_1024_bytes() {
    let mut base = yield_world();
    let tx = park(&mut base);
    let mut sim = base.clone();
    let r = resume(&mut sim, ALICE, 1024).transact();
    println!("resume 1024 bytes: {:?}, callback logs {:?}", r.failure(), on_yield_logs(&sim, tx));
    r.assert_success();
    assert!(r.json::<bool>());
    assert_eq!(on_yield_logs(&sim, tx), Some(vec!["payload 1024".to_owned()]));
    for n in [1025u32, 1024 * 1024] {
        let mut sim = base.clone();
        let r = resume(&mut sim, ALICE, n).transact();
        let f = format!("{:?}", r.failure());
        println!("resume {n} bytes: {f}");
        assert!(r.is_failure());
        assert!(f.contains(&format!("Yield resume payload is {n} bytes which exceeds the 1024 byte limit")), "{f}");
        assert_eq!(sim.yields().len(), 1, "the yield stays parked");
        assert_eq!(on_yield_logs(&sim, tx), None);
        let y = sim.yields().pop().unwrap();
        sim.expire(&y);
        assert_eq!(on_yield_logs(&sim, tx), Some(vec!["timeout".to_owned()]));
    }
}

/// Two resumes that run in one block: both return true, the callback runs
/// once, with the first payload (runtime/runtime/src/lib.rs:1616-1622
/// drops the later one).
#[test]
fn two_resumes_in_one_block() {
    let mut sim = yield_world();
    let tx = park(&mut sim);
    let a = resume(&mut sim, ALICE, 10).submit();
    let b = resume(&mut sim, BOB, 20).submit();
    sim.settle();
    let (oa, ob) = (sim.outcome(a), sim.outcome(b));
    let h = |o: &TxOutcome| o.receipts.iter().find(|r| r.method_names == ["resume"]).unwrap().block_height;
    println!("resumes at #{} and #{}: {} {}; callback logs {:?}", h(&oa), h(&ob), oa.json::<bool>(), ob.json::<bool>(), on_yield_logs(&sim, tx));
    assert_eq!(h(&oa), h(&ob), "one block");
    assert!(oa.json::<bool>() && ob.json::<bool>(), "both return true");
    let n = sim.outcome(tx).receipts.iter().filter(|r| r.method_names == ["on_yield"]).count();
    assert_eq!(n, 1, "one callback");
    assert_eq!(on_yield_logs(&sim, tx), Some(vec!["payload 10".to_owned()]), "with the first payload");
}

/// After the timeout ran the callback (with `Failed`), a resume returns
/// false and sends nothing (runtime/runtime/src/ext.rs:406-430).
#[test]
fn resume_after_timeout_returns_false() {
    let mut sim = yield_world();
    let tx = park(&mut sim);
    let y = sim.yields().pop().unwrap();
    sim.expire(&y);
    let r = resume(&mut sim, ALICE, 10).transact();
    println!("late resume: {}; callback logs {:?}", r.json::<bool>(), on_yield_logs(&sim, tx));
    r.assert_success();
    assert!(!r.json::<bool>());
    assert_eq!(on_yield_logs(&sim, tx), Some(vec!["timeout".to_owned()]));
    assert!(sim.is_idle());
}

/// Only the yielding account can resume: another contract resuming the
/// same data id gets false, and the yield stays parked.
#[test]
fn resume_by_another_account_returns_false() {
    let mut sim = yield_world();
    let tx = park(&mut sim);
    let y = sim.yields().pop().unwrap();
    let hex: String = y.data_id.as_ref().iter().map(|b| format!("{b:02x}")).collect();
    let r = sim.call(ALICE, Y2, "resume").args_json(json!({ "bytes": 10, "data_id": hex })).transact();
    println!("resume by {Y2}: {}", r.json::<bool>());
    r.assert_success();
    assert!(!r.json::<bool>());
    assert_eq!(sim.yields().len(), 1, "still parked");
    assert_eq!(on_yield_logs(&sim, tx), None);
}

/// No FIFO per sender-receiver pair (docs/SEMANTICS.md, S4): a receipt
/// that p-probe makes for q-probe can run before one p-probe made for
/// q-probe earlier. A new receipt is forwarded whenever it fits the link's
/// limits, without looking at that link's outgoing buffer
/// (runtime/runtime/src/congestion_control.rs:292-325, :451). Six ~1.2 MB
/// calls fill the grant of the route the (single) shard has to itself, so
/// some wait a block in the buffer; a small call p-probe makes after them,
/// in the same block, goes out at once and runs first. The same as the
/// sim's own tests/order.rs:402-435, on the probe contracts; nothing is
/// injected, this is nearcore's congestion control.
#[test]
fn later_receipt_overtakes_buffered() {
    let (wasm, _) = probe_wasm("probe");
    let users = [ALICE, BOB, "w1.near", "w2.near", "w3.near", "w4.near"];
    let small_user = "w0.near";
    let mut fx = Fixture::new();
    for u in users.iter().chain([&small_user]) {
        fx = fx.account(*u, Balance::from_near(100));
    }
    let mut sim = fx.contract(P, wasm.clone()).contract(Q, wasm).build();
    // q.marks takes no arguments, so it ignores the 1.2 MB and stores nothing.
    let kid = |method: &str, args: String| json!([{ "receiver": Q, "method": method, "args": args, "static_ggas": 30000, "weight": 0 }]);
    let chain = |sim: &mut Sim, user: &str, kids: Value| -> CryptoHash {
        sim.call(user, P, "chain").args_json(json!({ "kids": kids })).gas(Gas::from_teragas(300)).submit()
    };
    let bigs: Vec<CryptoHash> = users.iter().map(|u| chain(&mut sim, u, kid("marks", "x".repeat(1_200_000)))).collect();
    let small = chain(&mut sim, small_user, kid("mark", r#"{"tag":"small"}"#.to_owned()));
    sim.settle();
    // Execution order of every receipt that ran.
    let order: Vec<CryptoHash> = sim.receipts_in(..).iter().map(|r| r.id).collect();
    let at = |id: &CryptoHash| order.iter().position(|x| x == id).expect("it ran");
    // (height, position) of tx's p.chain receipt, and of the q receipt it made.
    let link = |sim: &Sim, tx: CryptoHash| {
        let o = sim.outcome(tx);
        o.assert_success();
        let r = |acct: &str| o.receipts.iter().find(|r| r.executor_id.as_str() == acct && !r.is_refund()).unwrap();
        let (p, q) = (r(P), r(Q));
        assert_eq!(q.predecessor_id.as_str(), P);
        ((p.block_height, at(&p.id)), (q.block_height, at(&q.id)))
    };
    let (sp, sq) = link(&sim, small);
    println!("small: p.chain at #{} (pos {}), its q receipt at #{} (pos {})", sp.0, sp.1, sq.0, sq.1);
    let mut overtaken = 0;
    for h in &bigs {
        let (bp, bq) = link(&sim, *h);
        let made_first = bp.1 < sp.1;
        let ran_later = bq.1 > sq.1;
        println!(
            "big:   p.chain at #{} (pos {}), its q receipt at #{} (pos {}){}",
            bp.0,
            bp.1,
            bq.0,
            bq.1,
            if made_first && ran_later { "  <- made before the small one, ran after it" } else { "" }
        );
        overtaken += usize::from(made_first && ran_later);
    }
    // The three made in the small one's block, before it (as in the sim's test).
    assert_eq!(overtaken, 3, "p -> q receipts made earlier and run later");
}

const RELAYER: &str = "relayer.near";

/// The probe world plus a relayer.
fn deleg_world() -> Sim {
    let (wasm, _) = probe_wasm("probe");
    Fixture::new()
        .account(ALICE, Balance::from_near(100))
        .account(BOB, Balance::from_near(100))
        .account(RELAYER, Balance::from_near(100))
        .contract(P, wasm.clone())
        .contract(Q, wasm)
        .build()
}

/// The transaction's status, `Debug`-formatted (the nearcore error names).
fn status(o: &TxOutcome) -> String {
    format!("{:?}", o.status)
}

/// The Delegate receipt (the relayer's first receipt, run on the sender).
fn outer(o: &TxOutcome) -> &ReceiptOutcome {
    o.receipts.iter().find(|r| r.actions.iter().any(|a| a.contains("Delegate"))).expect("a Delegate receipt")
}

fn yocto(b: Balance) -> i128 {
    b.as_yoctonear() as i128
}

/// Delegate actions: the inner call and everything it spawns see the
/// relayer as signer, with the relayer's key; the inner call's predecessor
/// is the sender (runtime/runtime/src/actions.rs:500-512: the new receipt
/// copies the outer receipt's signer_id and signer_public_key, predecessor
/// = sender_id). The outer receipt runs on the sender with the relayer as
/// predecessor (core/primitives/src/receipt.rs:343-364).
#[test]
fn delegate_signer_is_relayer_predecessor_is_sender() {
    let mut sim = deleg_world();
    let relayer_pk = sim.secret_key(RELAYER).public_key().to_string();
    let kids = json!([{ "receiver": Q, "method": "record", "args": "{\"tag\":\"child\"}", "static_ggas": 10000, "weight": 1 }]);
    let cb = json!({ "method": "record", "args": "{\"tag\":\"cb\"}", "static_ggas": 10000, "weight": 1 });
    let o = sim.call(ALICE, P, "chain").args_json(json!({ "kids": kids, "cb": cb })).relay(RELAYER);
    o.assert_success();
    let d = outer(&o);
    println!("outer: on {} from {}", d.executor_id, d.predecessor_id);
    assert_eq!((d.executor_id.as_str(), d.predecessor_id.as_str()), (ALICE, RELAYER));
    let chain = o.receipt("chain").unwrap();
    println!("inner: on {} from {}", chain.executor_id, chain.predecessor_id);
    assert_eq!((chain.executor_id.as_str(), chain.predecessor_id.as_str()), (P, ALICE));
    let rs = records(&o);
    println!("records: {rs:?}");
    assert_eq!(rs.len(), 2);
    for r in &rs {
        assert_eq!(r["signer"], RELAYER);
        assert_eq!(r["signer_pk"], relayer_pk.as_str());
        assert_eq!(r["predecessor"], P);
    }
    // The relayed call itself: predecessor alice, signer the relayer.
    let o = sim.call(ALICE, P, "record").args_json(json!({ "tag": "direct" })).relay(RELAYER);
    let rs = records(&o);
    println!("records: {rs:?}");
    assert_eq!((rs[0]["predecessor"].as_str(), rs[0]["signer"].as_str()), (Some(ALICE), Some(RELAYER)));
}

/// A replayed delegate fails on the nonce (actions.rs:648-657); the first
/// run set the key's nonce to the delegate's (:729-733).
#[test]
fn delegate_replay_fails_on_the_nonce() {
    let mut sim = deleg_world();
    let pk = sim.secret_key(ALICE).public_key();
    let h = sim.height();
    let signed = mark(&mut sim, ALICE, "a").sign_delegate(h + 100);
    let n = signed.delegate_action.nonce;
    sim.tx(RELAYER, ALICE).action(signed.clone()).transact().assert_success();
    assert_eq!(sim.access_key(ALICE, &pk).unwrap().nonce, n);
    let o = sim.tx(RELAYER, ALICE).action(signed).transact();
    println!("replay: {}", status(&o));
    assert!(status(&o).contains("DelegateActionInvalidNonce"), "{}", status(&o));
    assert_eq!(marks(&sim), "a,", "the inner call ran once");
}

/// Expiry: the outer receipt fails when its block height exceeds
/// max_block_height (actions.rs:479-482), so the bound is inclusive. The
/// deposit of a failed outer receipt goes back to the relayer, its
/// predecessor (runtime/runtime/src/lib.rs:1295-1303, :1402-1406;
/// receipt.rs:428-430), and the sender pays nothing.
#[test]
fn delegate_expiry_inclusive_and_outer_refund_to_relayer() {
    let base = deleg_world();
    let h = base.height();
    // Valid through the height it runs at.
    let mut sim = base.clone();
    let signed = mark(&mut sim, ALICE, "a").sign_delegate(h + 2);
    let o = sim.tx(RELAYER, ALICE).action(signed).transact();
    println!("max_block_height {}: outer ran at #{}: {}", h + 2, outer(&o).block_height, status(&o));
    o.assert_success();
    assert_eq!(outer(&o).block_height, h + 2);
    assert_eq!(marks(&sim), "a,");
    // One block less: expired. With a deposit, which the relayer gets back.
    let mut sim = base.clone();
    let (alice, relayer) = (sim.balance(ALICE), sim.balance(RELAYER));
    let signed = sim.call(ALICE, P, "fail").args_json(json!({ "key": "x" })).deposit(Balance::from_near(1)).sign_delegate(h + 1);
    let o = sim.tx(RELAYER, ALICE).action(signed).transact();
    println!("max_block_height {}: outer ran at #{}: {}", h + 1, outer(&o).block_height, status(&o));
    assert!(status(&o).contains("DelegateActionExpired"), "{}", status(&o));
    assert_eq!(outer(&o).block_height, h + 2);
    assert!(o.receipt("fail").is_none(), "no inner receipt");
    assert_eq!(sim.balance(ALICE), alice);
    assert_eq!(yocto(relayer) - yocto(sim.balance(RELAYER)), yocto(o.tokens_burnt()), "the relayer lost only gas");
}

/// The inner call fails: its deposit, which the relayer paid
/// (runtime/runtime/src/config.rs:652-668), is refunded to the sender, the
/// inner receipt's predecessor (actions.rs:514-519; receipt.rs:428-430).
/// The relayer's transaction still succeeds.
#[test]
fn delegate_inner_failure_refunds_sender() {
    let mut sim = deleg_world();
    let (alice, relayer) = (sim.balance(ALICE), sim.balance(RELAYER));
    let one = Balance::from_near(1);
    let o = sim.call(ALICE, P, "fail").args_json(json!({ "key": "x" })).deposit(one).relay(RELAYER);
    println!("relayed fail with 1 NEAR: tx {}; inner {:?}", status(&o), o.receipt("fail").and_then(|r| r.failure()));
    o.assert_success();
    assert!(o.receipt("fail").unwrap().failure().is_some());
    assert_eq!(yocto(sim.balance(ALICE)) - yocto(alice), yocto(one), "alice gains the deposit");
    assert_eq!(yocto(relayer) - yocto(sim.balance(RELAYER)), yocto(one) + yocto(o.tokens_burnt()));
}

/// The key is checked when the outer receipt runs on the sender's shard,
/// not when the delegate is signed or relayed (actions.rs:587-602): alice
/// deletes the key in the same block as the relay, and the outer receipt,
/// a block later, finds no key.
#[test]
fn delegate_key_checked_at_execution() {
    let mut sim = deleg_world();
    let second = SecretKey::from_seed(KeyType::ED25519, "alice-second");
    sim.tx(ALICE, ALICE).add_key(second.public_key(), AccessKey::full_access()).transact().assert_success();
    let h = sim.height();
    let signed = mark(&mut sim, ALICE, "a").sign_with(&second).sign_delegate(h + 100);
    let del = sim.tx(ALICE, ALICE).delete_key(second.public_key()).submit();
    let rel = sim.tx(RELAYER, ALICE).action(signed).submit();
    sim.settle();
    let (od, or) = (sim.outcome(del), sim.outcome(rel));
    od.assert_success();
    let hd = od.receipts.iter().find(|r| r.actions.iter().any(|a| a.contains("DeleteKey"))).unwrap().block_height;
    println!("DeleteKey at #{hd}, outer at #{}: {}", outer(&or).block_height, status(&or));
    assert!(hd < outer(&or).block_height);
    assert!(status(&or).contains("AccessKeyNotFound"), "{}", status(&or));
    assert_eq!(marks(&sim), "");
}

/// A function-call key may sign a delegate for one zero-deposit call to
/// its receiver and methods (actions.rs:670-727), and its allowance is not
/// charged: the relayer pays. A function-call key of the relayer cannot
/// sign the relayer's transaction: a Delegate is not a function call
/// (runtime/runtime/src/verifier.rs:213-222).
#[test]
fn delegate_function_call_key_scope() {
    let mut sim = deleg_world();
    let fck = SecretKey::from_seed(KeyType::ED25519, "alice-fc");
    let allowance = Balance::from_near(1);
    let perm = FunctionCallPermission { allowance: Some(allowance), receiver_id: P.into(), method_names: vec!["mark".into()] };
    let key = AccessKey { nonce: 0, permission: AccessKeyPermission::FunctionCall(perm) };
    sim.tx(ALICE, ALICE).add_key(fck.public_key(), key).transact().assert_success();
    let allowance_of = |sim: &Sim| match sim.access_key(ALICE, &fck.public_key()).unwrap().permission {
        AccessKeyPermission::FunctionCall(p) => p.allowance,
        _ => unreachable!(),
    };
    // In scope.
    mark(&mut sim, ALICE, "a").sign_with(&fck).relay(RELAYER).assert_success();
    assert_eq!(marks(&sim), "a,");
    assert_eq!(allowance_of(&sim), Some(allowance), "the allowance is untouched");
    // A deposit, another receiver, another method.
    let o = mark(&mut sim, ALICE, "b").deposit(Balance::from_yoctonear(1)).sign_with(&fck).relay(RELAYER);
    println!("with a deposit: {}", status(&o));
    assert!(status(&o).contains("DepositWithFunctionCall"), "{}", status(&o));
    let o = sim.call(ALICE, Q, "mark").args_json(json!({ "tag": "c" })).sign_with(&fck).relay(RELAYER);
    println!("to {Q}: {}", status(&o));
    assert!(status(&o).contains("ReceiverMismatch"), "{}", status(&o));
    let o = sim.call(ALICE, P, "record").args_json(json!({ "tag": "d" })).sign_with(&fck).relay(RELAYER);
    println!("method record: {}", status(&o));
    assert!(status(&o).contains("MethodNameMismatch"), "{}", status(&o));
    assert_eq!(marks(&sim), "a,");
    // The relayer's own function-call key (receiver alice, any method).
    let rk = SecretKey::from_seed(KeyType::ED25519, "relayer-fc");
    let perm = FunctionCallPermission { allowance: None, receiver_id: ALICE.into(), method_names: vec![] };
    sim.tx(RELAYER, RELAYER)
        .add_key(rk.public_key(), AccessKey { nonce: 0, permission: AccessKeyPermission::FunctionCall(perm) })
        .transact()
        .assert_success();
    let h = sim.height();
    let signed = mark(&mut sim, ALICE, "e").sign_delegate(h + 100);
    let o = sim.tx(RELAYER, ALICE).action(signed).sign_with(&rk).transact();
    println!("relayer's function-call key: {}", status(&o));
    assert!(status(&o).contains("RequiresFullAccess"), "{}", status(&o));
    assert!(o.receipts.is_empty(), "an invalid transaction: no receipt");
}

/// Storage usage in bytes, as `view_account` shows it.
fn usage(sim: &Sim, id: &str) -> u64 {
    sim.account(id).unwrap().storage_usage
}

fn put<'a>(sim: &'a mut Sim, signer: &str, k: &str, v: &str) -> Tx<'a> {
    sim.call(signer, P, "put").args_json(json!({ "key": k, "value": v }))
}

/// p's first mutating call also writes the contract state (near-sdk's
/// `STATE` record), so the byte tests start after one.
fn storage_world() -> Sim {
    let mut sim = deleg_world();
    put(&mut sim, ALICE, "warm", "").transact().assert_success();
    sim
}

/// A new key adds key + value + 40 bytes; an overwrite adds the length
/// difference (runtime/near-vm-runner/src/logic/host.rs:5041-5070; the 40
/// is storage_num_extra_bytes_record,
/// core/parameters/res/runtime_configs/parameters.yaml:37). The model's
/// RecordBytes(k, v).
#[test]
fn storage_write_bytes() {
    let mut sim = deleg_world();
    let u0 = usage(&sim, P);
    put(&mut sim, ALICE, "warm", "").transact().assert_success();
    let u1 = usage(&sim, P);
    println!("first put(\"warm\", \"\"): +{} bytes (STATE record and the key)", u1 - u0);
    put(&mut sim, ALICE, "k1", "abc").transact().assert_success();
    let u2 = usage(&sim, P);
    println!("put(\"k1\", \"abc\") on a new key: +{}", u2 - u1);
    assert_eq!(u2 - u1, 2 + 3 + 40);
    put(&mut sim, ALICE, "k1", "abcdef").transact().assert_success();
    let u3 = usage(&sim, P);
    println!("put(\"k1\", \"abcdef\") overwriting: +{}", u3 - u2);
    assert_eq!(u3 - u2, 3);
    put(&mut sim, ALICE, "k1", "a").transact().assert_success();
    assert_eq!(u3 - usage(&sim, P), 5, "a shorter value frees the difference");
}

/// After a receipt, liquid + locked must cover storage_usage x 1e19 yocto
/// (runtime/runtime/src/lib.rs:1008-1031; check_storage_stake,
/// runtime/runtime/src/verifier.rs:48-84). One yocto short: the receipt
/// fails with LackBalanceForState and its write is reverted. Exactly
/// enough passes (`>=`, :74). A deposit the receipt brings counts: it is
/// in the balance the check sees (here a `[Transfer(1 yocto), put]`
/// batch, since `put` takes no deposit).
#[test]
fn storage_lack_balance_fails_and_reverts() {
    let mut sim = storage_world();
    let u = usage(&sim, P);
    let need = sim.storage_cost(u + 2 + 3 + 40);
    sim.set_balance(P, need.checked_sub(Balance::from_yoctonear(1)).unwrap());
    let o = put(&mut sim, ALICE, "k1", "abc").transact();
    println!("one yocto short: {:?}", o.failure());
    assert!(matches!(o.failure(), Some(Failure::Action(ActionErrorKind::LackBalanceForState { .. }))), "{o}");
    assert_eq!(get(&sim, "k1"), None, "the write is reverted");
    assert_eq!(usage(&sim, P), u);
    // The deposit counts: one yocto attached covers the shortfall.
    sim.set_balance(P, need.checked_sub(Balance::from_yoctonear(1)).unwrap());
    let args = serde_json::to_vec(&json!({ "key": "k1", "value": "abc" })).unwrap();
    let o = sim.tx(ALICE, P).transfer(Balance::from_yoctonear(1)).call("put").args(args).transact();
    println!("one yocto short, one attached: {:?}", o.failure());
    assert!(o.failure().is_none(), "{o}");
    assert_eq!(get(&sim, "k1").as_deref(), Some("abc"));
    // Exactly enough.
    let u = usage(&sim, P);
    sim.set_balance(P, sim.storage_cost(u + 2 + 3 + 40));
    let o = put(&mut sim, ALICE, "k2", "abc").transact();
    println!("exactly enough: {:?}", o.failure());
    assert!(o.failure().is_none(), "{o}");
}

/// The sim twin of examples/storage-stake `vault_per_byte_unrecorded`:
/// p.chain([p.send(bob, x)]).then(p.put(rec, 2000 bytes)). The payout
/// leaves p covering its bytes; the callback's record does not fit, so it
/// fails with LackBalanceForState while the Transfer stands.
#[test]
fn storage_callback_fails_after_payout() {
    let mut sim = storage_world();
    let x = Balance::from_near(1).checked_div(10).unwrap();
    let value = "x".repeat(2000);
    let rec = 3 + 2000 + 40;
    let u = usage(&sim, P);
    // After the payout: the cover of today's bytes plus half the record's.
    let after = sim.storage_cost(u).checked_add(sim.storage_cost(rec).checked_div(2).unwrap()).unwrap();
    sim.set_balance(P, after.checked_add(x).unwrap());
    let bob = sim.balance(BOB);
    let send = json!({ "method": "send", "args": json!({ "to": BOB, "yocto": x.as_yoctonear().to_string() }).to_string(),
                       "static_ggas": 20000, "weight": 1 });
    let cb = json!({ "method": "put", "args": json!({ "key": "rec", "value": value }).to_string(),
                     "static_ggas": 20000, "weight": 1 });
    let o = sim.call(ALICE, P, "chain").args_json(json!({ "kids": [send], "cb": cb })).transact();
    let (s, c) = (o.receipt("send").unwrap(), o.receipt("put").unwrap());
    println!("payout: {:?}; record: {:?}", s.failure(), c.failure());
    assert!(s.failure().is_none());
    assert!(matches!(c.failure(), Some(Failure::Action(ActionErrorKind::LackBalanceForState { .. }))));
    assert_eq!(yocto(sim.balance(BOB)) - yocto(bob), yocto(x), "bob was paid");
    assert_eq!(get(&sim, "rec"), None, "and not recorded");
    assert_eq!(usage(&sim, P), u);
}

/// NEP-448: an account using at most 770 bytes passes the check whatever
/// its balance (verifier.rs:25, :77-79, :88-90). A new account is
/// 100 + its full-access key (82: 33-byte ed25519 trie id, borsh AccessKey
/// 9, + 40; runtime/runtime/src/access_keys.rs:17-29) = 182 bytes. With a
/// balance below the cover of 700 bytes, keys up to 756 bytes are added;
/// the next (838) fails with LackBalanceForState and is not added.
#[test]
fn storage_zero_balance_allowance() {
    let mut sim = deleg_world();
    let z = "zed.near";
    let bal = sim.storage_cost(700);
    sim.create_account(z, bal);
    assert_eq!(usage(&sim, z), 100 + 82);
    for i in 0..7 {
        let k = key(&format!("zk{i}"));
        sim.tx(z, z).add_key(k, AccessKey::full_access()).transact().assert_success();
    }
    let u = usage(&sim, z);
    let b = sim.balance(z);
    println!("{u} bytes with {} yocto: the cover would be {}", b.as_yoctonear(), sim.storage_cost(u).as_yoctonear());
    assert_eq!(u, 182 + 7 * 82);
    assert!(b < sim.storage_cost(u), "below the cover, passing only by the allowance");
    let k = key("zk7");
    let o = sim.tx(z, z).add_key(k.clone(), AccessKey::full_access()).transact();
    println!("one more key ({} bytes): {:?}", u + 82, o.failure());
    assert!(matches!(o.failure(), Some(Failure::Action(ActionErrorKind::LackBalanceForState { .. }))), "{o}");
    assert!(sim.access_key(z, &k).is_none());
    assert_eq!(usage(&sim, z), u);
}

/// Key bytes (NearKeys KeyBytes): trie id 33 + borsh(AccessKey) + 40
/// (access_keys.rs:17-29; core/primitives-core/src/account.rs:959-978).
/// Full access: 33 + 9 + 40 = 82. Function call: 33 + 8 (nonce) + 1 (tag)
/// + allowance (1 for None, 17 for Some) + 4 + len(receiver) + 4 +
/// sum(4 + len(method)) + 40. DeleteKey frees the same (:136-147).
#[test]
fn storage_key_bytes() {
    let mut sim = deleg_world();
    let delta = |sim: &mut Sim, seed: &str, ak: AccessKey| {
        let u = usage(sim, ALICE);
        sim.tx(ALICE, ALICE).add_key(key(seed), ak).transact().assert_success();
        let d = usage(sim, ALICE) - u;
        sim.tx(ALICE, ALICE).delete_key(key(seed)).transact().assert_success();
        assert_eq!(usage(sim, ALICE), u, "DeleteKey frees what AddKey added");
        d
    };
    let fc = |allowance: Option<Balance>, ms: &[&str]| AccessKey {
        nonce: 0,
        permission: AccessKeyPermission::FunctionCall(FunctionCallPermission {
            allowance,
            receiver_id: P.to_string(),
            method_names: ms.iter().map(|m| m.to_string()).collect(),
        }),
    };
    let full = delta(&mut sim, "kb-full", AccessKey::full_access());
    let one = delta(&mut sim, "kb-fc1", fc(None, &["mark"]));
    let two = delta(&mut sim, "kb-fc2", fc(Some(Balance::from_near(1)), &["mark", "get"]));
    let any = delta(&mut sim, "kb-any", fc(None, &[]));
    println!("full {full}, fc(None, [mark]) {one}, fc(Some, [mark, get]) {two}, fc(None, []) {any}");
    let rcv = P.len() as u64;
    assert_eq!(full, 82);
    assert_eq!(one, 33 + 8 + 1 + 1 + 4 + rcv + 4 + (4 + 4) + 40);
    assert_eq!(two, 33 + 8 + 1 + 17 + 4 + rcv + 4 + (4 + 4) + (4 + 3) + 40);
    assert_eq!(any, 33 + 8 + 1 + 1 + 4 + rcv + 4 + 40);
}

/// A transaction whose cost leaves its signer below the storage cover is
/// refused at conversion: InvalidTxError::LackBalanceForState
/// (runtime/runtime/src/verifier.rs:375-386, in
/// verify_and_charge_tx_ephemeral). The model's CanSubmit (without gas
/// money).
#[test]
fn storage_signer_checked_at_conversion() {
    let mut sim = storage_world();
    let spare = Balance::from_near(1).checked_div(100).unwrap();
    sim.set_balance(P, sim.storage_cost(usage(&sim, P)).checked_add(spare).unwrap());
    let o = sim.tx(P, BOB).transfer(spare.checked_mul(2).unwrap()).transact();
    println!("deposit above the spare balance: {:?}", o.failure());
    assert!(matches!(o.failure(), Some(Failure::InvalidTx(InvalidTxError::LackBalanceForState { .. }))), "{o}");
    let o = sim.tx(P, BOB).transfer(spare.checked_div(2).unwrap()).transact();
    println!("deposit within it: {:?}", o.failure());
    assert!(o.failure().is_none(), "{o}");
}

/// An account created by a Transfer: NEAR-implicit 100 + its full-access
/// key 82 = 182, eth-implicit 100 + the 32-byte global-contract hash = 132
/// (runtime/runtime/src/actions.rs:234-269). The model's CreatedBytes.
#[test]
fn storage_implicit_account_bytes() {
    let mut sim = deleg_world();
    let near_imp = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    let eth_imp = "0x3333333333333333333333333333333333333333";
    for id in [near_imp, eth_imp] {
        sim.tx(ALICE, id).transfer(Balance::from_near(1)).transact().assert_success();
    }
    println!("near-implicit {}, eth-implicit {}", usage(&sim, near_imp), usage(&sim, eth_imp));
    assert_eq!(usage(&sim, near_imp), 182);
    assert_eq!(usage(&sim, eth_imp), 132);
}

/// S1, a full chunk: a local receipt that finds the chunk's compute limit
/// reached goes to the back of the delayed queue
/// (runtime/runtime/src/lib.rs:2513-2521), so every receipt already
/// delayed runs before it (:2800 local, :2808 delayed, :2816 incoming).
/// Block A converts eight alice -> p calls burning 240 Tgas each; at A + 1
/// the 1000 Tgas chunk runs some and delays the rest. Block A + 2 converts
/// six of p's own (local) calls: the chunk runs locals until it is full and
/// delays the others behind the earlier ones, which run first at A + 3.
/// The opt-in `LocalPriorityOK` forbids that order (N-local-congested).
#[test]
fn local_receipt_delayed_when_chunk_full() {
    let mut sim = world();
    sim.set_balance(P, Balance::from_near(100));
    let burn = |sim: &mut Sim, signer: &str| {
        sim.call(signer, P, "burn").args_json(json!({ "ggas": 240_000 })).gas(Gas::from_teragas(250)).submit()
    };
    let incoming: Vec<CryptoHash> = (0..8).map(|_| burn(&mut sim, ALICE)).collect();
    sim.step();
    let a = sim.height();
    sim.step();
    let local: Vec<CryptoHash> = (0..6).map(|_| burn(&mut sim, P)).collect();
    sim.step();
    sim.settle();
    let order: Vec<CryptoHash> = sim.receipts_in(..).iter().map(|r| r.id).collect();
    let run = |tx: &CryptoHash| {
        let r = sim.outcome(tx).expect_receipt("burn").clone();
        assert!(r.failure().is_none(), "{:?}", r.status);
        (r.block_height, order.iter().position(|x| *x == r.id).unwrap())
    };
    let inc: Vec<(u64, usize)> = incoming.iter().map(run).collect();
    let loc: Vec<(u64, usize)> = local.iter().map(run).collect();
    let conv = sim.outcome(local[0]).transaction.as_ref().unwrap().block_height;
    println!("block A = #{a}; alice's calls ran at {:?}", inc.iter().map(|x| x.0).collect::<Vec<_>>());
    println!("p's local calls, converted at #{conv}, ran at {:?}", loc.iter().map(|x| x.0).collect::<Vec<_>>());
    let delayed: Vec<&(u64, usize)> = inc.iter().filter(|x| x.0 > a + 1).collect();
    let pushed: Vec<&(u64, usize)> = loc.iter().filter(|x| x.0 > conv).collect();
    assert_eq!(conv, a + 2);
    assert!(!delayed.is_empty() && delayed.iter().all(|x| x.0 >= conv), "some of alice's calls were delayed past A + 2");
    assert!(loc.iter().any(|x| x.0 == conv), "locals run first in their block while the chunk has room");
    assert!(!pushed.is_empty(), "some locals found the chunk full");
    let last_delayed = delayed.iter().map(|x| x.1).max().unwrap();
    let first_pushed = pushed.iter().map(|x| x.1).min().unwrap();
    println!("{} of alice's calls were delayed; {} of p's locals were pushed behind them", delayed.len(), pushed.len());
    assert!(last_delayed < first_pushed, "every receipt delayed before runs before the pushed local ones");
}

/// C7, the deadline: a yield made at height h times out at h + 200
/// (`yield_timeout_length_in_blocks`,
/// core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:274;
/// runtime/runtime/src/function_call.rs:151-170 enqueues the deadline).
/// The chunk at h + 200 resolves it (runtime/runtime/src/lib.rs:3113-3221,
/// `expires_at <= block_height` at :3146) by sending a PromiseResume
/// receipt with no data to the yielding account (:3161-3172, forwarded as
/// an outgoing receipt at :3196-3200), so the callback runs at h + 201 and
/// reads Failed. Its predecessor is the yielding account
/// (function_call.rs:171-189).
#[test]
fn yield_times_out_at_200_blocks() {
    let mut sim = yield_world();
    let tx = park(&mut sim);
    let h = sim.outcome(tx).expect_receipt("yield_create").block_height;
    let y = sim.yields().pop().unwrap();
    println!("yield made at #{h}; expires_at {}", y.expires_at);
    assert_eq!(y.expires_at, h + 200);
    sim.advance_to(h + 199);
    let parked_199 = sim.yields().len();
    println!("at #{}: {parked_199} parked, callback logs {:?}", sim.height(), on_yield_logs(&sim, tx));
    assert_eq!(sim.height(), h + 199);
    assert_eq!((parked_199, on_yield_logs(&sim, tx)), (1, None), "parked and not run before h + 200");
    sim.step();
    let parked_200 = sim.yields().len();
    println!("at #{}: {parked_200} parked, callback logs {:?}", sim.height(), on_yield_logs(&sim, tx));
    assert_eq!(sim.height(), h + 200);
    assert_eq!((parked_200, on_yield_logs(&sim, tx)), (0, None), "resolved at h + 200; the callback has not run yet");
    sim.settle();
    // The callback, checked on its own: the exact height, what it read and
    // who sent it.
    let cb = sim.outcome(tx).expect_receipt("on_yield").clone();
    println!("callback at #{}, from {}: logs {:?}", cb.block_height, cb.predecessor_id, cb.logs);
    assert_eq!(cb.block_height, h + 201, "the timeout resolved at h + 200 runs the callback at h + 201");
    assert_eq!(cb.logs, ["timeout"]);
    assert_eq!(cb.predecessor_id.as_str(), Y);
}

const Z: &str = "z-probe.near";

/// alice and bob; the generic probe on p, probe2 on z.
fn z_world() -> Sim {
    let (probe, _) = probe_wasm("probe");
    let (probe2, _) = probe_wasm("probe2");
    Fixture::new()
        .account(ALICE, Balance::from_near(100))
        .account(BOB, Balance::from_near(100))
        .contract(P, probe)
        .contract(Z, probe2)
        .build()
}

fn z_yield<'a>(sim: &'a mut Sim, args: Value) -> Tx<'a> {
    sim.call(ALICE, Z, "yield_id").args_json(args)
}

/// z.resume by custom id `id`, or the stored data id.
fn z_resume<'a>(sim: &'a mut Sim, signer: &str, id: Option<&str>, bytes: u32) -> Tx<'a> {
    sim.call(signer, Z, "resume").args_json(json!({ "id": id, "bytes": bytes }))
}

/// The logs of every `on_yield` of transaction `tx` that ran.
fn z_callbacks(sim: &Sim, tx: CryptoHash) -> Vec<Vec<String>> {
    sim.outcome(tx).receipts.iter().filter(|r| r.method_names == ["on_yield"]).map(|r| r.logs.clone()).collect()
}

/// What z.on_yield logs, signed by alice, with no deposit.
fn on_yield_log(what: &str) -> String {
    format!("on_yield signer {ALICE} predecessor {Z} deposit {:040} {what}", 0)
}

/// C7, `promise_yield_create_with_id` (near-vm-runner
/// logic/host.rs:4330-4440): while a yield with the custom id is pending,
/// another create with it returns `u64::MAX` (:4391-4399) and creates
/// nothing, the call going on. That holds for a second create in the same
/// call (runtime/runtime/src/ext.rs:375-385 sees the mapping the first
/// wrote) and in a later call. `promise_yield_resume_with_yield_id`
/// resumes it once (host.rs:4522-4567; ext.rs:432-444 maps the id to the
/// data id, then as `promise_yield_resume`, :406-430). Once its callback has run, the id is
/// free (runtime/runtime/src/lib.rs:1576-1591 removes the mapping): a new
/// create succeeds, also from the callback itself.
#[test]
fn yield_with_id_duplicates_and_reuse() {
    let base = z_world();
    let mut sim = base.clone();
    let o = z_yield(&mut sim, json!({ "id": "k", "cb_ggas": 5000, "twice": true })).transact();
    let ys = sim.yields();
    println!("two creates of id k in one call: {:?}; logs {:?}; {} parked", o.failure(), o.expect_receipt("yield_id").logs, ys.len());
    o.assert_success();
    assert_eq!(o.expect_receipt("yield_id").logs, ["yield created", "yield duplicate"]);
    assert_eq!(ys.len(), 1);
    let first = ys[0].data_id;

    let o2 = z_yield(&mut sim, json!({ "id": "k", "cb_ggas": 5000 })).transact();
    println!("a later create of k while pending: {:?}; logs {:?}; parked {:?}", o2.failure(), o2.expect_receipt("yield_id").logs, sim.yields().len());
    o2.assert_success();
    assert_eq!(o2.expect_receipt("yield_id").logs, ["yield duplicate"]);
    assert_eq!(sim.yields().iter().map(|y| y.data_id).collect::<Vec<_>>(), [first]);

    let r = z_resume(&mut sim, BOB, Some("k"), 3).transact();
    let r2 = z_resume(&mut sim, BOB, Some("k"), 3).transact();
    println!("resume k: {}, again: {}; callbacks {:?}", r.json::<bool>(), r2.json::<bool>(), z_callbacks(&sim, o.hash));
    assert!(r.json::<bool>() && !r2.json::<bool>(), "true once, then false");
    assert_eq!(z_callbacks(&sim, o.hash), [[on_yield_log("payload 3")]]);
    assert!(sim.yields().is_empty());

    let o3 = z_yield(&mut sim, json!({ "id": "k", "cb_ggas": 5000 })).transact();
    let ys = sim.yields();
    println!("create k after its callback ran: logs {:?}; {} parked", o3.expect_receipt("yield_id").logs, ys.len());
    assert_eq!(o3.expect_receipt("yield_id").logs, ["yield created"]);
    assert_eq!(ys.len(), 1);
    assert_ne!(ys[0].data_id, first, "a new yield");

    // The callback re-creates its own custom id.
    let mut sim = base.clone();
    let o = z_yield(&mut sim, json!({ "id": "r", "cb_ggas": 20000, "again": true })).transact();
    let d1 = sim.yields()[0].data_id;
    z_resume(&mut sim, BOB, Some("r"), 2).transact().assert_success();
    let ys = sim.yields();
    println!("the callback of r re-creates r: logs {:?}; {} parked", z_callbacks(&sim, o.hash), ys.len());
    assert_eq!(z_callbacks(&sim, o.hash), [[on_yield_log("payload 2"), "again created".to_string()]]);
    assert_eq!(ys.len(), 1);
    assert_ne!(ys[0].data_id, d1);
    assert_eq!(ys[0].callback_args, [br#"{"id":"r","again":false}"#.to_vec()]);
    let r = z_resume(&mut sim, BOB, Some("r"), 1).transact();
    println!("resume the re-created r: {}; parked {}", r.json::<bool>(), sim.yields().len());
    assert!(r.json::<bool>());
    assert!(sim.yields().is_empty());
}

/// C7, a yield's deposit. `promise_yield_create_with_id` takes a deposit
/// from the yielding account at creation (near-vm-runner
/// logic/host.rs:4423-4434 `deduct_balance`) and attaches it to the
/// callback (:4435-4442), which receives it when it runs. At protocol 88 a
/// contract earns no share of the gas it burns (`burnt_gas_reward` 0/1,
/// core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:99-102)
/// and the signer pays the gas, so z's balance moves by deposits only: the
/// same yield with deposit 0 and 2 N leaves z 0 and 2 N lower while
/// parked, and as it was once the callback, which read the deposit, has
/// run.
#[test]
fn yield_deposit() {
    let base = z_world();
    for dep in [0u128, Balance::from_near(2).as_yoctonear()] {
        let mut sim = base.clone();
        let z0 = sim.balance(Z);
        let o = z_yield(&mut sim, json!({ "id": "d", "deposit": dep.to_string(), "cb_ggas": 5000 })).transact();
        o.assert_success();
        let parked = yocto(sim.balance(Z)) - yocto(z0);
        z_resume(&mut sim, ALICE, Some("d"), 3).transact().assert_success();
        let after = yocto(sim.balance(Z)) - yocto(z0);
        let out = sim.outcome(o.hash);
        let cb = out.expect_receipt("on_yield");
        println!("deposit {dep}: z changed {parked} while parked, {after} after; callback received {}, logged {:?}", cb.deposit, cb.logs);
        assert_eq!(cb.logs, [format!("on_yield signer {ALICE} predecessor {Z} deposit {dep:040} payload 3")]);
        assert_eq!(cb.deposit.as_yoctonear(), dep);
        assert_eq!((parked, after), (-(dep as i128), 0));
    }
}

/// C7, a returned yield: the caller's waiting receivers move onto the
/// yield callback (runtime/runtime/src/lib.rs:1151-1168), so p's callback
/// on z.yield_id reads the yield callback's result, after it ran: the
/// resume's payload (z.on_yield returns it; the call's own result would be
/// empty), or, on a timeout, an empty value that is a success, not
/// `Failed` (z.on_yield runs and returns nothing). The callback is
/// z.on_expect, which panics unless result 0 is exactly the given bytes or
/// size (-1 for `Failed`); the wrong bytes and sizes are controls.
#[test]
fn returned_yield_forwards_its_result() {
    let base = z_world();
    let payload = "x".repeat(7);
    let resumed = [(json!({ "i": 0, "bytes": payload }), None), (json!({ "i": 0, "bytes": "xxxxxxy" }), Some("result 0 is other bytes")), (json!({ "i": 0, "len": 0 }), Some("result 0 is 7 bytes"))];
    let timed_out = [(json!({ "i": 0, "bytes": "" }), None), (json!({ "i": 0, "len": -1 }), Some("result 0 is 0 bytes")), (json!({ "i": 0, "bytes": payload }), Some("result 0 is other bytes"))];
    for (resume, expects) in [(Some(7u32), resumed), (None, timed_out)] {
        for (expect, fails) in expects {
            let mut sim = base.clone();
            let kid = json!([{ "receiver": Z, "method": "yield_id", "args": json!({ "cb_ggas": 5000, "ret": true }).to_string(), "static_ggas": 30000, "weight": 1 }]);
            let cb = json!({ "receiver": Z, "method": "on_expect", "args": expect.to_string(), "static_ggas": 10000, "weight": 1 });
            let o = sim.call(ALICE, P, "chain").args_json(json!({ "kids": kid, "cb": cb })).transact();
            o.assert_success();
            assert!(o.receipt("on_expect").is_none(), "p's callback waits for the yield");
            match resume {
                Some(n) => {
                    z_resume(&mut sim, BOB, None, n).transact().assert_success();
                }
                None => {
                    let y = sim.yields().pop().unwrap();
                    sim.expire(&y);
                }
            }
            let out = sim.outcome(o.hash);
            let (yc, ex, yi) = (out.expect_receipt("on_yield"), out.expect_receipt("on_expect"), out.expect_receipt("yield_id"));
            println!("resume {resume:?}, expect {expect}: yield_id returned {:?}; on_yield at #{} logged {:?}; on_expect at #{}: {:?}", yi.status, yc.block_height, yc.logs, ex.block_height, ex.status);
            assert!(yi.is_success() && yi.value().is_none(), "it returned a promise, not a value");
            assert!(yc.is_success());
            match fails {
                None => assert_eq!(ex.value(), Some(&resume.unwrap_or(0).to_string().into_bytes()[..])),
                Some(msg) => assert_eq!(ex.failure(), Some(Failure::Panic(msg.into()))),
            }
            assert!(ex.block_height > yc.block_height);
        }
    }
}

/// C7, the callback's signer and predecessor: the yielding transaction's
/// signer, whoever resumes it, and the yielding account
/// (runtime/runtime/src/function_call.rs:171-189). Alice yields; bob
/// resumes, or the yield times out.
#[test]
fn yield_callback_signer_is_the_yielding_signer() {
    let base = z_world();
    for (how, resumer) in [("resumed by bob", Some(BOB)), ("timed out", None)] {
        let mut sim = base.clone();
        let o = z_yield(&mut sim, json!({ "id": "s", "cb_ggas": 5000 })).transact();
        o.assert_success();
        match resumer {
            Some(b) => {
                z_resume(&mut sim, b, Some("s"), 2).transact().assert_success();
            }
            None => {
                let y = sim.yields().pop().unwrap();
                sim.expire(&y);
            }
        }
        let cb = sim.outcome(o.hash).expect_receipt("on_yield").clone();
        println!("{how}: callback from {}: {:?}", cb.predecessor_id, cb.logs);
        assert_eq!(cb.logs, [on_yield_log(if resumer.is_some() { "payload 2" } else { "timeout" })]);
        assert_eq!(cb.predecessor_id.as_str(), Z);
    }
}

/// K4, the remaining checks of the outer receipt
/// (runtime/runtime/src/actions.rs:453-535 `apply_delegate_action`):
/// the sender must exist (:862-887), the signature must verify (:474-477),
/// the delegate's sender must be the transaction's receiver (:483-490), and
/// the nonce must be below H x 1e6, H the height the outer receipt runs at
/// (:656-666, `>=` fails): H x 1e6 fails, H x 1e6 - 1 passes. A transaction
/// holds at most one Delegate (runtime/runtime/src/action_validation.rs:136-151).
#[test]
fn delegate_signature_sender_and_nonce_bound() {
    let base = deleg_world();
    let alice = base.secret_key(ALICE);
    let h = base.height();
    let check = |sim: &mut Sim, what: &str, o: TxOutcome, want: &str| {
        println!("{what}: {}", status(&o));
        assert!(status(&o).contains(want), "{}", status(&o));
        assert_eq!(marks(sim), "", "no inner call");
    };

    let mut sim = base.clone();
    let signed = mark(&mut sim, ALICE, "a").sign_delegate(h + 100);
    let o = sim.tx(RELAYER, "nobody.near").action(signed).transact();
    check(&mut sim, "to an absent sender", o, "AccountDoesNotExist");

    let mut sim = base.clone();
    let mut signed = mark(&mut sim, ALICE, "a").sign_delegate(h + 100);
    signed.delegate_action.max_block_height += 1;
    let o = sim.tx(RELAYER, ALICE).action(signed).transact();
    check(&mut sim, "altered after signing", o, "DelegateActionInvalidSignature");

    let mut sim = base.clone();
    let signed = mark(&mut sim, ALICE, "a").sign_delegate(h + 100);
    let o = sim.tx(RELAYER, BOB).action(signed).transact();
    check(&mut sim, "alice's delegate sent to bob", o, "DelegateActionSenderDoesNotMatchTxReceiver");

    // The nonce bound, at the height H the outer receipt runs at (the same
    // in every clone of `base`): found with a nonce far above it, then
    // H x 1e6 fails and H x 1e6 - 1 passes.
    let with_nonce = |nonce: u64| {
        let mut sim = base.clone();
        let mut signed = mark(&mut sim, ALICE, "a").sign_delegate(h + 100);
        signed.delegate_action.nonce = nonce;
        signed.signature = alice.sign(signed.delegate_action.get_nep461_hash().as_ref());
        let o = sim.tx(RELAYER, ALICE).action(signed).transact();
        let at = outer(&o).block_height;
        (sim, o, at)
    };
    let (mut sim, o, big) = with_nonce((h + 1000) * 1_000_000);
    check(&mut sim, "nonce (h + 1000) x 1e6", o, "DelegateActionNonceTooLarge");
    let bound = big * 1_000_000;
    let (mut sim, o, at) = with_nonce(bound);
    assert_eq!(at, big);
    assert!(status(&o).contains(&format!("upper_bound: {bound}")), "{}", status(&o));
    check(&mut sim, &format!("nonce H x 1e6 = {bound} (H = #{at})"), o, "DelegateActionNonceTooLarge");
    let (sim, o, at) = with_nonce(bound - 1);
    println!("nonce H x 1e6 - 1 (H = #{at}): {}; marks {:?}", status(&o), marks(&sim));
    assert_eq!(at, big);
    assert_eq!(marks(&sim), "a,", "one below the bound passes");

    let mut sim = base.clone();
    let one = mark(&mut sim, ALICE, "a").sign_delegate(h + 100);
    let two = mark(&mut sim, ALICE, "b").sign_delegate(h + 100);
    let o = sim.tx(RELAYER, ALICE).action(one).action(two).transact();
    assert!(o.receipts.is_empty(), "an invalid transaction");
    check(&mut sim, "two delegates in one transaction", o, "DelegateActionMustBeOnlyOne");
}

/// A near-contract-standards 5.29.1 registration stores the holder's
/// balance under prefix + borsh(AccountId) as a u128: 1 + 4 + len(id) + 16
/// + 40 = 61 + len(id) bytes (fungible_token/core_impl.rs:41-57; the 40
/// is storage_num_extra_bytes_record), Nep145's StdRegBytes. Measured on
/// the wNEAR-like probe at two holder-id lengths, 8 and 64 bytes; the
/// storage_balance_bounds minimum is the price of the longest id,
/// StdRegBytes(64) = 125 bytes x 1e19 yocto (storage_impl.rs:107-111).
/// A repeat registers nothing, and storage_unregister frees as many bytes.
#[test]
fn storage_std_registration_bytes() {
    const W: &str = "wnear-probe.near";
    let (wasm, _) = probe_wasm("wrap");
    let mut sim = Fixture::new()
        .account(ALICE, Balance::from_near(100))
        .account(BOB, Balance::from_near(100))
        .account(W, Balance::from_near(10))
        .contract(W, wasm)
        .init("new", json!({}))
        .build();
    let min: Value = sim.view(W, "storage_balance_bounds", json!({})).json();
    let min: u128 = min["min"].as_str().unwrap().parse().unwrap();
    println!("storage_balance_bounds min: {min} yocto");
    assert_eq!(min, 125 * 10u128.pow(19));
    let reg = |sim: &mut Sim, id: &str| -> i64 {
        let u = usage(sim, W) as i64;
        sim.call(ALICE, W, "storage_deposit")
            .args_json(json!({ "account_id": id }))
            .deposit(Balance::from_yoctonear(min))
            .transact()
            .assert_success();
        usage(sim, W) as i64 - u
    };
    let long = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    for id in [BOB, long] {
        let d = reg(&mut sim, id);
        println!("storage_deposit({id}, {} bytes): +{d} bytes", id.len());
        assert_eq!(d, 61 + id.len() as i64, "StdRegBytes({})", id.len());
        assert_eq!(reg(&mut sim, id), 0, "a repeat registers nothing");
    }
    let u = usage(&sim, W) as i64;
    sim.call(BOB, W, "storage_unregister").args_json(json!({})).deposit(Balance::from_yoctonear(1)).transact().assert_success();
    println!("storage_unregister by {BOB}: {} bytes", usage(&sim, W) as i64 - u);
    assert_eq!(usage(&sim, W) as i64 - u, -(61 + BOB.len() as i64));
}
