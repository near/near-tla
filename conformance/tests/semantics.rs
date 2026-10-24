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
//! function-call-key checks on either side.
//! `cargo test --test semantics -- --nocapture` prints what was observed.
use near_contract_sim::prelude::*;
use near_contract_sim::{AccessKey, AccessKeyPermission, CryptoHash, FunctionCallPermission, ReceiptOutcome, TxOutcome};
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
/// sim's own tests/order.rs:400-433, on the probe contracts; nothing is
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
