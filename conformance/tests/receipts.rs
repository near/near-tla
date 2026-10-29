//! Receipts, promise results and gas, observed in the sim on the probe
//! contracts, for the docs/SEMANTICS.md rules the conformance comparison
//! cannot see (it sees each receipt's status and attached gas, not state,
//! balances, what a callback reads or when it runs): data receipts (R1, R2),
//! the atomic step and its revert scope (R3, R4), refunds (R5, G5),
//! callbacks reading `Failed` and the result shapes (C1, C3), the result
//! size and its per-receiver fee (C4), a returned promise forwarding its
//! result (C5), joint promises flattened, forwarding, read by index,
//! limited to 128 inputs and not returnable, appendable or given a
//! `refund_to` (C5, C6), `refund_to` (R5), the prepaid-gas ceiling (G1),
//! the per-action panic label (G2), the floor-and-remainder split and its
//! order across interleaved appends (G3) and the block clock (S3). Each
//! test prints what it observed; `cargo test --test receipts --
//! --nocapture` shows it.
//!
//! nearcore references are at the pinned rev bc4e9e8 (README, "Pins").
//! Every test runs on the committed probe wasms (`probes/res/`); the host
//! calls the first probes do not make are on `probe2` (on `z-probe.near`).
use near_contract_sim::nearcore::near_parameters::ActionCosts;
use near_contract_sim::prelude::*;
use near_contract_sim::{InvalidTxError, ReceiptOutcome, Refund};
use near_tla_conformance::probe_wasm;
use serde_json::{Value, json};

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const P: &str = "p-probe.near";
const Q: &str = "q-probe.near";
const Y: &str = "y-probe.near";
const FT: &str = "ft-probe.near";
const Z: &str = "z-probe.near";

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

fn yocto(b: Balance) -> i128 {
    b.as_yoctonear() as i128
}

/// alice and bob; the generic probe on p and q, the async probe on y,
/// probe2 on z, the standard FT on ft-probe with p holding the supply and
/// q registered.
fn world() -> Sim {
    let (probe, _) = probe_wasm("probe");
    let (async_probe, _) = probe_wasm("async_probe");
    let (probe2, _) = probe_wasm("probe2");
    let (ft, _) = probe_wasm("ft");
    Fixture::new()
        .account(ALICE, near(1000))
        .account(BOB, near(100))
        .contract(P, probe.clone())
        .contract(Q, probe)
        .contract(Y, async_probe)
        .contract(Z, probe2)
        .contract(FT, ft)
        .init("new").args_json(json!({ "owner_id": P, "total_supply": "1000000" }))
        .ft_register(FT, [Q])
        .build()
}

/// One function call of p's `chain` (static and weight in Ggas).
fn call(receiver: &str, method: &str, args: Value, static_ggas: u64, weight: u64) -> Value {
    json!({ "receiver": receiver, "method": method, "args": args.to_string(), "static_ggas": static_ggas, "weight": weight })
}

fn chain<'a>(sim: &'a mut Sim, kids: Value, cb: Option<Value>) -> Tx<'a> {
    sim.call(ALICE, P, "chain").args_json(json!({ "kids": kids, "cb": cb }))
}

/// The receipt's return value as JSON.
fn val(r: &ReceiptOutcome) -> Value {
    serde_json::from_slice(r.value().unwrap_or_else(|| panic!("no value: {:?}", r.status))).unwrap()
}

fn rerr(r: &ReceiptOutcome) -> String {
    format!("{:?}", r.failure())
}

fn get(sim: &Sim, acct: &str, k: &str) -> Option<String> {
    sim.view(acct, "get", json!({ "key": k })).json::<Option<String>>()
}

/// A joint callback's results, read three ways on the same `kids`:
/// `y.on_yield` returns the size of result 0 (it reads only index 0),
/// `p.on_read` the total size, `p.on_count` the number of results. With
/// two results, index 1's size is the total less index 0's.
fn joint_reads(base: &Sim, kids: &Value) -> (u64, u64, u64) {
    let cbs = [
        json!({ "receiver": Y, "method": "on_yield", "static_ggas": 10000, "weight": 1 }),
        json!({ "method": "on_read", "static_ggas": 10000, "weight": 1 }),
        json!({ "method": "on_count", "static_ggas": 10000, "weight": 1 }),
    ];
    let [i0, total, count] = cbs.map(|cb| {
        let m = cb["method"].as_str().unwrap().to_string();
        let mut sim = base.clone();
        let o = chain(&mut sim, kids.clone(), Some(cb)).transact();
        val(o.expect_receipt(&m)).as_u64().unwrap()
    });
    (i0, total, count)
}

/// R1, C1, C3. A data receipt carries one promise result to the one
/// receipt that waits on it: the callback reads a result of the size its
/// input returned (the probes report sizes, not contents), one per input
/// at that input's index (runtime/runtime/src/lib.rs:1146-1189 sends one data receipt
/// per output receiver, :1172-1176 builds its `data`; :861-899 collects the
/// inputs in `input_data_ids` order, `None` as `Failed`, :894-895). The
/// shapes (near-vm-runner logic/host.rs:4583 `promise_results_count`,
/// :4616-4646 `promise_result`): a call that returned nothing gives
/// `Successful([])`, not `Failed`; a failed input gives `Failed`, and the
/// callback still runs; a receipt with no inputs counts 0.
#[test]
fn data_receipt_carries_one_result() {
    let mut sim = world();
    let on = |m: &str| json!({ "method": m, "static_ggas": 10000, "weight": 1 });
    let on_order = json!({ "receiver": Y, "method": "on_order", "static_ggas": 10000, "weight": 1 });

    // One input of 7 bytes: the callback reads 7.
    let o = chain(&mut sim, json!([call(Q, "ret", json!({ "bytes": 7 }), 10000, 1)]), Some(on("on_read"))).transact();
    let cb = o.expect_receipt("on_read");
    println!("q.ret(7) then p.on_read: read {} bytes (callback at #{}, ret at #{})", val(cb), cb.block_height, o.expect_receipt("ret").block_height);
    assert_eq!(val(cb), 7);
    // Two inputs of distinct sizes, in both orders: one result each, at
    // its input's index (`promise_and` order).
    for [x, y] in [[3u64, 4], [4, 3]] {
        let kids = json!([x, y].map(|n| call(Q, "ret", json!({ "bytes": n }), 10000, 1)));
        let (i0, total, count) = joint_reads(&sim, &kids);
        println!("q.ret({x}) & q.ret({y}): {count} results; index 0 has {i0} bytes, index 1 {} (total {total})", total - i0);
        assert_eq!(count, 2);
        assert_eq!((i0, total - i0), (x, y), "each result at its input's index");
    }
    // Three, joined pairwise ((a & b) & c): flattened to three results,
    // the first input's at index 0 (indices 1 and 2 one by one:
    // `joint_result_by_index`).
    for sizes in [[1u64, 2, 4], [4, 1, 2]] {
        let kids = json!(sizes.map(|n| call(Q, "ret", json!({ "bytes": n }), 10000, 1)));
        let (i0, total, count) = joint_reads(&sim, &kids);
        println!("(q.ret({}) & q.ret({})) & q.ret({}): {count} results, {total} bytes; index 0 has {i0}", sizes[0], sizes[1], sizes[2]);
        assert_eq!((i0, total, count), (sizes[0], 7, 3));
    }
    // No inputs: promise_results_count() = 0.
    let o = sim.call(ALICE, P, "on_count").transact();
    println!("p.on_count as a plain call: {}", o.json::<u64>());
    assert_eq!(o.json::<u64>(), 0);

    // A call that returned nothing (q.put): Successful(empty), not Failed.
    let put = call(Q, "put", json!({ "key": "k", "value": "v" }), 10000, 1);
    let o = chain(&mut sim, json!([put.clone()]), Some(on("on_read"))).transact();
    let read = val(o.expect_receipt("on_read"));
    let o = chain(&mut sim, json!([put]), Some(on_order.clone())).transact();
    let cb = o.expect_receipt("on_order");
    println!("q.put (returns nothing) then on_read: {read} bytes; then y.on_order (panics iff Failed): {}", rerr(cb));
    assert_eq!(read, 0);
    assert!(cb.is_success(), "empty bytes are Successful: {}", rerr(cb));

    // A failed input (q.fail panics): the callback runs and reads Failed.
    let fail = call(Q, "fail", json!({ "key": "f" }), 10000, 1);
    let o = chain(&mut sim, json!([fail]), Some(on_order)).transact();
    let (f, cb) = (o.expect_receipt("fail"), o.expect_receipt("on_order"));
    println!("q.fail ({}) then y.on_order: {}", rerr(f), rerr(cb));
    assert!(f.failure().is_some());
    assert_eq!(cb.failure(), Some(Failure::Panic("first result failed".into())), "it ran and read Failed");
}

/// R2. A receipt that waits on a result runs once the result is in,
/// whichever arrives first (runtime/runtime/src/lib.rs:1647-1715: a
/// receipt arriving first is postponed and counts its missing inputs;
/// :1440-1528: data arriving first is stored, and the last input to arrive
/// runs the receipt). `Fault::HoldResult` keeps q's result back, so the
/// callback arrives first; `Fault::Hold` keeps the callback back, so the
/// data arrives first. Both are orders a full outgoing buffer gives.
#[test]
fn callback_waits_for_its_data_either_order() {
    let base = world();
    let kids = json!([call(Q, "ret", json!({ "bytes": 7 }), 10000, 1)]);
    let cb = json!({ "method": "on_read", "static_ggas": 10000, "weight": 1 });

    // The callback first: postponed until q's data arrives.
    let mut sim = base.clone();
    let tx = chain(&mut sim, kids.clone(), Some(cb.clone())).inject(Receipts::call(Q, "ret"), Fault::HoldResult(5)).submit();
    sim.run_until(10, |s| s.outcome(tx).receipt("ret").is_some()).unwrap();
    sim.step();
    sim.step();
    let waiting = sim.outcome(tx).pending.len();
    let ran_early = sim.outcome(tx).receipt("on_read").is_some();
    sim.settle();
    let o = sim.outcome(tx);
    let (ret, cbr) = (o.expect_receipt("ret"), o.expect_receipt("on_read"));
    println!(
        "result held: ret at #{}, its result held {:?}; two blocks later the callback had run: {ran_early} ({waiting} pending); it ran at #{} and read {}",
        ret.block_height,
        cbr.result_held,
        cbr.block_height,
        val(cbr)
    );
    assert_eq!(cbr.result_held, Some(5), "the fault held q's result");
    assert!(!ran_early, "postponed while its input is missing");
    assert_eq!(waiting, 1, "the callback waits, pending");
    assert!(cbr.block_height > ret.block_height + 2);
    assert_eq!(val(cbr), 7);

    // The data first: stored, and the callback runs when it arrives.
    let mut sim = base.clone();
    let o = chain(&mut sim, kids, Some(cb)).inject(Receipts::callback("on_read"), Fault::Hold(5)).transact();
    let (ret, cbr) = (o.expect_receipt("ret"), o.expect_receipt("on_read"));
    println!("callback held {:?}: ret at #{}, callback at #{}, read {}", cbr.held, ret.block_height, cbr.block_height, val(cbr));
    assert_eq!(cbr.held, Some(5));
    assert!(cbr.block_height > ret.block_height + 2, "the data waited for the callback");
    assert_eq!(val(cbr), 7);
}

/// R3, R4. A receipt's actions run, then one commit or one rollback
/// (runtime/runtime/src/lib.rs:946-1005 the actions loop, :1079-1083
/// commit, :1084-1087 rollback); a failure clears the receipts it would
/// have created (:535-541 `set_error`) but keeps its logs and gas burnt.
/// Receipts that already committed stay committed.
#[test]
fn failed_receipt_reverts_and_drops_children() {
    let mut sim = world();
    let a = |v: Value| serde_json::to_vec(&v).unwrap();
    let kids = json!([call(Q, "mark", json!({ "tag": "x" }), 10000, 1)]);
    // [put(a), chain(q.mark), record, fail(b)]: the fourth action panics.
    let o = sim
        .tx(ALICE, P)
        .call("put")
        .args(a(json!({ "key": "a", "value": "1" })))
        .gas(Gas::from_teragas(20))
        .call("chain")
        .args(a(json!({ "kids": kids })))
        .gas(Gas::from_teragas(40))
        .call("record")
        .args(a(json!({ "tag": "t" })))
        .gas(Gas::from_teragas(20))
        .call("fail")
        .args(a(json!({ "key": "b" })))
        .gas(Gas::from_teragas(20))
        .transact();
    let first = o.first_call().unwrap();
    let on_q = o.receipts.iter().filter(|r| r.receiver_id.as_str() == Q).count();
    println!(
        "[put, chain(q.mark), record, fail]: {}; receipts on q: {on_q}; a = {:?}, b = {:?}; logs kept: {:?}; gas burnt {}",
        rerr(first),
        get(&sim, P, "a"),
        get(&sim, P, "b"),
        o.all_logs(),
        first.gas_burnt
    );
    assert_eq!(first.failure(), Some(Failure::Panic("probe fail".into())));
    assert_eq!(on_q, 0, "the child it created is dropped");
    assert_eq!((get(&sim, P, "a"), get(&sim, P, "b")), (None, None), "both writes rolled back");
    assert!(o.all_logs().iter().any(|l| l.starts_with("record ")), "the log survives");
    assert!(o.logs().is_empty());
    assert!(first.gas_burnt > Gas::from_teragas(1));

    // q.put commits; its callback p.fail then fails: q's write stays.
    let put = call(Q, "put", json!({ "key": "k", "value": "1" }), 10000, 1);
    let cb = json!({ "method": "fail", "args": json!({ "key": "c" }).to_string(), "static_ggas": 10000, "weight": 1 });
    let o = chain(&mut sim, json!([put]), Some(cb)).transact();
    println!("q.put then p.fail: callback {}; q's k = {:?}, p's c = {:?}", rerr(o.expect_receipt("fail")), get(&sim, Q, "k"), get(&sim, P, "c"));
    assert!(o.expect_receipt("fail").failure().is_some());
    assert_eq!(get(&sim, Q, "k").as_deref(), Some("1"), "the earlier receipt stays committed");
    assert_eq!(get(&sim, P, "c"), None);
}

/// The deposit refunds of a transaction (amount, receiver, predecessor).
fn deposit_refunds(o: &TxOutcome) -> Vec<(String, String, Balance)> {
    o.receipts
        .iter()
        .filter(|r| r.refund == Some(Refund::Deposit))
        .map(|r| (r.receiver_id.to_string(), r.predecessor_id.to_string(), r.deposit))
        .collect()
}

/// R5, G5, A4. A failed receipt's deposit goes back to its predecessor in
/// a refund receipt from `system` (runtime/runtime/src/lib.rs:1303 deposit
/// refund only on error, :1402-1406 `new_balance_refund` to
/// `balance_refund_receiver`; core/primitives/src/receipt.rs:428-430,
/// :496-509). An out-of-gas receipt's unburnt gas goes back to the signer,
/// prepaid − burnt (lib.rs:1304-1316; the NEP-536 penalty is 0 at 88), so
/// the signer is out exactly the gas burnt. A Transfer to a missing named
/// account fails and refunds its sender (runtime/runtime/src/actions.rs:842-849).
#[test]
fn deposit_and_gas_refunds() {
    let mut sim = world();
    // [Transfer(1 N), burn(400 Tgas) with 20 Tgas]: out of gas.
    let (a0, p0) = (sim.balance(ALICE), sim.balance(P));
    let o = sim
        .tx(ALICE, P)
        .transfer(near(1))
        .call("burn")
        .args_json(json!({ "ggas": 400000 }))
        .gas(Gas::from_teragas(20))
        .transact();
    let first = o.first_call().unwrap();
    let refunds = deposit_refunds(&o);
    let gas_refunds: Vec<_> = o.receipts.iter().filter(|r| r.refund == Some(Refund::Gas)).map(|r| (r.receiver_id.to_string(), r.deposit)).collect();
    let lost = yocto(a0) - yocto(sim.balance(ALICE));
    println!(
        "[Transfer(1 N), burn] out of gas: {}; deposit refunds {refunds:?}; gas refunds {gas_refunds:?}; alice lost {lost} yocto, tokens burnt {}",
        rerr(first),
        o.tokens_burnt().as_yoctonear()
    );
    assert_eq!(first.failure(), Some(Failure::OutOfGas));
    assert_eq!(refunds, [(ALICE.to_string(), "system".to_string(), near(1))]);
    assert_eq!(gas_refunds.len(), 1);
    assert_eq!(gas_refunds[0].0, ALICE);
    assert_eq!(lost, yocto(o.tokens_burnt()), "alice paid exactly the gas burnt");
    assert_eq!(sim.balance(P), p0, "p kept nothing");

    // A contract's Transfer to a missing named account: refunded to p.
    let p0 = sim.balance(P);
    let o = sim.call(ALICE, P, "send").args_json(json!({ "to": "nobody.near", "yocto": near(1).as_yoctonear().to_string() })).transact();
    let t = o.receipts.iter().find(|r| r.actions == ["Transfer"] && r.refund.is_none()).unwrap();
    let refunds = deposit_refunds(&o);
    println!("p sends 1 N to nobody.near: {}; deposit refunds {refunds:?}; p's balance change {}", rerr(t), yocto(sim.balance(P)) - yocto(p0));
    assert!(matches!(t.failure(), Some(Failure::AccountDoesNotExist(_))));
    assert_eq!(refunds, [(P.to_string(), "system".to_string(), near(1))]);
    assert_eq!(sim.balance(P), p0);
}

/// R5, `refund_to`. A failed receipt's deposit goes back to its
/// `refund_to` if set, else to its predecessor
/// (core/primitives/src/receipt.rs:428-430 `balance_refund_receiver`;
/// runtime/runtime/src/lib.rs:1303, :1402-1406), from `system`. z creates
/// `z.paid` (2 N, panics) with and without `promise_set_refund_to(bob)`
/// (near-vm-runner logic/host.rs:2660-2694); the call reads the target as
/// `refund_to_account_id`, its predecessor when unset
/// (runtime/runtime/src/function_call.rs:263).
#[test]
fn refund_to_receives_the_deposit_refund() {
    let base = world();
    let two = near(2).as_yoctonear();
    let paid = json!({ "receiver": Z, "method": "paid", "args": json!({ "fail": true }).to_string(), "static_ggas": 10000, "weight": 1, "deposit": two.to_string() });
    for (rto, want) in [(None, Z), (Some(BOB), BOB)] {
        let mut sim = base.clone();
        let (b0, z0) = (sim.balance(BOB), sim.balance(Z));
        let o = sim.call(ALICE, Z, "refund_call").args_json(json!({ "c": paid, "refund_to": rto })).transact();
        let r = o.expect_receipt("paid");
        let refunds = deposit_refunds(&o);
        let gained = yocto(sim.balance(BOB)) - yocto(b0);
        let z_moved = yocto(sim.balance(Z)) - yocto(z0);
        println!("refund_to {rto:?}: paid logged {:?}, {}; deposit refunds {refunds:?}; bob gained {gained}, z moved {z_moved}", r.logs, rerr(r));
        assert_eq!(r.logs, [format!("paid {two} refund_to {want} predecessor {Z}")]);
        assert_eq!(r.failure(), Some(Failure::Panic("paid fail".into())));
        assert_eq!(refunds, [(want.to_string(), "system".to_string(), near(2))]);
        // the deposit leaves z (the predecessor) and comes back to z or bob:
        // exact, as protocol 88 gives contracts no gas reward
        assert_eq!(gained, if want == BOB { two as i128 } else { 0 });
        assert_eq!(z_moved, if want == BOB { -(two as i128) } else { 0 });
    }
}

/// C4. A returned value may be up to `max_length_returned_data` = 4 MiB
/// (core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:249);
/// one byte more fails the call (near-vm-runner logic/host.rs:4711-4717).
/// The returning receipt pays `new_data_receipt_byte` send + exec per byte
/// for each receiver waiting on it, the send fee by whether the receiver
/// is the returning account (:4718-4741).
#[test]
fn result_size_limit_and_per_receiver_fee() {
    let mut sim = world();
    let limit = sim.config.runtime_config().wasm_config.limit_config.max_length_returned_data;
    let ret = |sim: &mut Sim, n: u64| sim.call(ALICE, Q, "ret").args_json(json!({ "bytes": n })).transact();
    let o = ret(&mut sim, limit);
    println!("limit {limit} bytes; q.ret({limit}): {} ({} bytes)", rerr(o.first_call().unwrap()), o.value().map_or(0, |v| v.len()));
    assert_eq!(limit, 4 * 1024 * 1024);
    o.assert_success();
    assert_eq!(o.value().unwrap().len() as u64, limit);
    let o = ret(&mut sim, limit + 1);
    let f = rerr(o.first_call().unwrap());
    println!("q.ret({}): {f}", limit + 1);
    assert!(f.contains(&format!("The length of a returned value {} exceeds the limit {limit}", limit + 1)), "{f}");

    // The same q.ret(n) with no receiver, one other account, and q itself.
    let n = 100_000u64;
    let kid = json!([call(Q, "ret", json!({ "bytes": n }), 30000, 1)]);
    let burnt = |sim: &mut Sim, cb: Option<Value>| chain(sim, kid.clone(), cb).transact().expect_receipt("ret").gas_burnt.as_gas();
    let none = burnt(&mut sim, None);
    let other = burnt(&mut sim, Some(json!({ "method": "on_count", "static_ggas": 10000, "weight": 1 })));
    let own = burnt(&mut sim, Some(json!({ "receiver": Q, "method": "on_count", "static_ggas": 10000, "weight": 1 })));
    let f = sim.config.runtime_config().fees.fee(ActionCosts::new_data_receipt_byte).clone();
    let (s_other, s_own, e) = (f.send_fee(false).gas.as_gas(), f.send_fee(true).gas.as_gas(), f.exec_fee().gas.as_gas());
    println!(
        "q.ret({n}) burns {none} with no waiting receiver, +{} with p waiting, +{} with q waiting; per byte: send {s_other} (other) / {s_own} (same), exec {e}",
        other - none,
        own - none
    );
    assert_eq!(other - none, n * (s_other + e));
    assert_eq!(own - none, n * (s_own + e));
}

/// C5. A call that returns a promise sends no data itself: its waiting
/// receiver is moved onto the returned receipt and gets that receipt's
/// result, later (near-vm-runner logic/host.rs:4659-4678 `promise_return`;
/// runtime/runtime/src/lib.rs:1151-1170). p's callback on
/// `ft_transfer_call` reads a result the size of the resolver's value
/// (4 bytes for "10", 3 for "0"; not the empty result of the call itself),
/// and runs after it.
#[test]
fn returned_promise_forwards_its_result() {
    for (msg, used) in [("keep", "10"), ("return", "0")] {
        let mut sim = world();
        let args = json!({ "receiver_id": Q, "amount": "10", "msg": msg });
        let kid = json!([{ "receiver": FT, "method": "ft_transfer_call", "args": args.to_string(), "static_ggas": 60000, "weight": 1, "deposit": "1" }]);
        let cb = json!({ "method": "on_read", "static_ggas": 10000, "weight": 0 });
        let o = chain(&mut sim, kid, Some(cb)).transact();
        let (call, res, cbr) = (o.expect_receipt("ft_transfer_call"), o.expect_receipt("ft_resolve_transfer"), o.expect_receipt("on_read"));
        let rv = String::from_utf8(res.value().unwrap().to_vec()).unwrap();
        println!(
            "msg {msg}: ft_transfer_call at #{} returned {:?}; resolver at #{} returned {rv}; p.on_read at #{} read {} bytes",
            call.block_height,
            call.status,
            res.block_height,
            cbr.block_height,
            val(cbr)
        );
        assert!(call.is_success() && call.value().is_none(), "it returned a promise, not a value");
        assert_eq!(rv, format!("\"{used}\""));
        assert_eq!(val(cbr), rv.len(), "the callback read the resolver's value");
        assert!(cbr.block_height > res.block_height);
    }
    // C6: a joint input that returns a promise forwards its position: the
    // joint callback reads the resolver's value at ft_transfer_call's place
    // (runtime/runtime/src/lib.rs:1151-1170 on each input).
    // In both orders: the resolver's 4-byte "10" sits at ft_transfer_call's
    // index, q.ret(5)'s 5 bytes at the other.
    let base = world();
    let args = json!({ "receiver_id": Q, "amount": "10", "msg": "keep" });
    let ftc = json!({ "receiver": FT, "method": "ft_transfer_call", "args": args.to_string(), "static_ggas": 60000, "weight": 1, "deposit": "1" });
    let ret5 = call(Q, "ret", json!({ "bytes": 5 }), 10000, 1);
    for (what, kids, want) in [("ft_transfer_call & q.ret(5)", json!([ftc, ret5]), (4, 5)), ("q.ret(5) & ft_transfer_call", json!([ret5, ftc]), (5, 4))] {
        let (i0, total, count) = joint_reads(&base, &kids);
        println!("{what}: {count} results; index 0 has {i0} bytes, index 1 {}", total - i0);
        assert_eq!(count, 2);
        assert_eq!((i0, total - i0), want, "the forwarded result at its input's index");
    }
    // The joint callback runs after the resolver.
    let mut sim = base.clone();
    let o = chain(&mut sim, json!([ftc, ret5]), Some(json!({ "method": "on_read", "static_ggas": 10000, "weight": 0 }))).transact();
    let (res, cbr) = (o.expect_receipt("ft_resolve_transfer"), o.expect_receipt("on_read"));
    println!("joint callback at #{}, the resolver at #{}", cbr.block_height, res.block_height);
    assert!(cbr.block_height > res.block_height);
}

/// C6, the input limit: `promise_and` fails the call once its flattened
/// inputs exceed `max_number_input_data_dependencies` = 128
/// (near-vm-runner logic/host.rs:2523-2532; nested joint promises are
/// flattened first, :2519-2521). p's chain joins its children pairwise.
#[test]
fn joint_promise_input_limit() {
    let base = world();
    let limit = base.config.runtime_config().wasm_config.limit_config.max_number_input_data_dependencies;
    assert_eq!(limit, 128);
    for n in [limit, limit + 1] {
        let mut sim = base.clone();
        let kids: Vec<Value> = (0..n).map(|_| call(Q, "ret", json!({ "bytes": 1 }), 0, 1)).collect();
        let o = chain(&mut sim, json!(kids), Some(json!({ "method": "on_count", "static_ggas": 5000, "weight": 0 }))).transact();
        let first = o.first_call().unwrap();
        let rets = o.receipts.iter().filter(|r| r.method_names == ["ret"]).count();
        println!("{n} inputs: chain {}; {rets} children ran; callback {:?}", rerr(first), o.receipt("on_count").map(val));
        if n == limit {
            assert!(first.is_success(), "{o}");
            assert_eq!(val(o.expect_receipt("on_count")), json!(n));
        } else {
            assert!(rerr(first).contains("input data dependencies 129 exceeds the limit 128"), "{}", rerr(first));
            assert_eq!(rets, 0, "the failed creator made no children");
        }
    }
}

/// z.join's callback `z.on_at(i)` on `kids` joined as `nest`, with the
/// result of the `hold`th q.ret held back 3 blocks if given: what it
/// returned (the size of result i, -1 for Failed) and its log.
fn result_at(base: &Sim, kids: &Value, nest: &str, i: u64, hold: Option<usize>) -> (TxOutcome, Option<(i64, String)>) {
    let mut sim = base.clone();
    let cb = json!({ "receiver": Z, "method": "on_at", "args": json!({ "i": i }).to_string(), "static_ggas": 10000, "weight": 1 });
    let mut tx = sim.call(ALICE, Z, "join").args_json(json!({ "kids": kids, "nest": nest, "cb": cb }));
    if let Some(k) = hold {
        tx = tx.inject(Receipts::occurrence(Q, "ret", k), Fault::HoldResult(3));
    }
    let o = tx.transact();
    let got = o.receipt("on_at").filter(|r| r.is_success()).map(|r| (val(r).as_i64().unwrap(), r.logs[0].clone()));
    if hold.is_some() {
        assert_eq!(o.expect_receipt("on_at").result_held, Some(3), "the fault held an input");
    }
    (o, got)
}

/// C6, one result by index. A joint callback sees one result per input in
/// `promise_and` order, nested joins flattened in argument order, an inner
/// join's inputs where it stands (near-vm-runner logic/host.rs:2486-2535;
/// runtime/runtime/src/lib.rs:861-899), each `Successful` or `Failed` on
/// its own, whichever arrives last; an index past the end is
/// `InvalidPromiseResultIndex` (host.rs:4616-4646). z.on_at(i) reads result
/// i only. Inputs q.ret(1), q.ret(2), q.ret(4) (k0, k1, k2) give sizes that
/// name them; `Fault::HoldResult` makes each input in turn arrive last.
#[test]
fn joint_result_by_index() {
    let base = world();
    let kids = json!([1, 2, 4].map(|n| call(Q, "ret", json!({ "bytes": n }), 10000, 1)));
    for (nest, what, want) in [
        ("flat", "k0 & k1 & k2", [1i64, 2, 4]),
        ("left", "(k0 & k1) & k2", [1, 2, 4]),
        ("right", "k0 & (k1 & k2)", [1, 2, 4]),
        ("inner", "(k1 & k2) & k0", [2, 4, 1]),
    ] {
        for hold in [None, Some(0), Some(1), Some(2)] {
            let got: Vec<(i64, String)> = (0..3).map(|i| result_at(&base, &kids, nest, i, hold).1.unwrap()).collect();
            let held = hold.map_or("none held".to_string(), |k| format!("k{k} held 3 blocks"));
            println!("{what}, {held}: results 0, 1, 2 have {:?} bytes", got.iter().map(|g| g.0).collect::<Vec<_>>());
            for (i, (n, log)) in got.iter().enumerate() {
                assert_eq!((*n, log.as_str()), (want[i], format!("result {i} of 3: {} bytes", want[i]).as_str()), "{what}, index {i}");
            }
        }
        let (o, got) = result_at(&base, &kids, nest, 3, None);
        let f = rerr(o.expect_receipt("on_at"));
        println!("{what}: index 3: {f}");
        assert_eq!(got, None);
        assert!(f.contains("Accessed invalid promise result index: 3"), "{f}");
    }
    // A failed input in the middle: Failed at its index only.
    let kids = json!([call(Q, "ret", json!({ "bytes": 1 }), 10000, 1), call(Q, "fail", json!({ "key": "f" }), 10000, 1), call(Q, "ret", json!({ "bytes": 4 }), 10000, 1)]);
    let got: Vec<i64> = (0..3).map(|i| result_at(&base, &kids, "flat", i, None).1.unwrap().0).collect();
    println!("q.ret(1) & q.fail & q.ret(4): results 0, 1, 2 read {got:?} (-1: Failed)");
    assert_eq!(got, [1, -1, 4]);
}

/// C5, C6, the restrictions. A joint promise cannot be returned
/// (near-vm-runner logic/host.rs:4659-4678, `CannotReturnJointPromise`),
/// have an action appended (:2699-2715, `CannotAppendActionToJointPromise`)
/// or be given a `refund_to` (:2660-2694, `CannotSetRefundToOnJointPromise`).
/// Each is a host error: the creating call fails, so the inputs it made
/// before do not exist (R4). With no misuse and no `.then`, `promise_and`
/// adds nothing: only the inputs run.
#[test]
fn joint_promise_restrictions() {
    let base = world();
    let kids = json!(["j0", "j1"].map(|t| call(Q, "mark", json!({ "tag": t }), 10000, 1)));
    let marks = |o: &TxOutcome| o.receipts.iter().filter(|r| r.method_names == ["mark"]).count();
    for (misuse, want) in [
        ("return", "Returning joint promise is currently prohibited."),
        ("append", "Actions can only be appended to non-joint promise."),
        ("refund_to", "Setting refund_to on a joint promise is prohibited."),
    ] {
        let mut sim = base.clone();
        let o = sim.call(ALICE, Z, "join").args_json(json!({ "kids": kids, "misuse": misuse })).transact();
        let f = rerr(o.expect_receipt("join"));
        println!("join, then {misuse} on the joint promise: {f}; inputs run: {}", marks(&o));
        assert_eq!(o.expect_receipt("join").failure(), Some(Failure::Host(want.into())));
        assert_eq!(marks(&o), 0, "the failed creator made no inputs");
    }
    let mut sim = base.clone();
    let o = sim.call(ALICE, Z, "join").args_json(json!({ "kids": kids })).transact();
    let ran: Vec<String> = o.receipts.iter().filter(|r| r.refund.is_none() && !r.method_names.is_empty()).map(|r| format!("{}.{}", r.receiver_id, r.method_names.join("+"))).collect();
    println!("join with no misuse and no .then: {ran:?}");
    o.assert_success();
    assert_eq!(ran, [format!("{Z}.join"), format!("{Q}.mark"), format!("{Q}.mark")]);
}

/// G1. One transaction's prepaid gas is at most `max_total_prepaid_gas` =
/// 1000 Tgas (core/parameters/res/runtime_configs/83.yaml:8); more is an
/// invalid transaction (runtime/runtime/src/action_validation.rs:153-160,
/// summed over its actions). The call gets its
/// prepaid gas as attached gas (runtime/runtime/src/function_call.rs:274).
#[test]
fn prepaid_gas_ceiling() {
    let mut sim = world();
    let cap = sim.gas_ceiling();
    let o = sim.call(ALICE, P, "burn").args_json(json!({ "ggas": 1 })).gas(cap).transact();
    println!("ceiling {cap}; burn with it: {:?}, attached {}", o.failure(), o.first_call().unwrap().attached_gas);
    assert_eq!(cap, Gas::from_teragas(1000));
    o.assert_success();
    assert_eq!(o.first_call().unwrap().attached_gas, cap);
    let o = sim.call(ALICE, P, "burn").args_json(json!({ "ggas": 1 })).gas(Gas::from_gas(cap.as_gas() + 1)).transact();
    println!("one gas more: {:?}", o.failure());
    assert!(matches!(o.failure(), Some(Failure::InvalidTx(InvalidTxError::ActionsValidation(_)))), "{o}");
    // Two calls of one transaction share the ceiling.
    let a = serde_json::to_vec(&json!({ "ggas": 1 })).unwrap();
    let o = sim.tx(ALICE, P).call("burn").args(a.clone()).gas(Gas::from_teragas(600)).call("burn").args(a).gas(Gas::from_teragas(401)).transact();
    println!("600 + 401 Tgas in one transaction: {:?}", o.failure());
    assert!(matches!(o.failure(), Some(Failure::InvalidTx(_))), "{o}");
    assert!(o.receipts.is_empty());
}

/// G2, per action. Each function call of a receipt runs on its own
/// attached gas (runtime/runtime/src/function_call.rs:274); a call that
/// cannot reach its panic fails with GasExceeded, one that can fails with
/// the panic (near-vm-runner logic/gas_counter.rs:126-150). Either way the
/// receipt reverts the earlier action's write (lib.rs:1001-1003, :1084-1087).
#[test]
fn per_action_gas_and_panic_label() {
    let base = world();
    let a = |v: Value| serde_json::to_vec(&v).unwrap();
    for (ggas, expect) in [(1u64, Failure::OutOfGas), (20000, Failure::Panic("probe fail".into()))] {
        let mut sim = base.clone();
        let o = sim
            .tx(ALICE, P)
            .call("put")
            .args(a(json!({ "key": "a", "value": "1" })))
            .gas(Gas::from_teragas(20))
            .call("fail")
            .args(a(json!({ "key": "b" })))
            .gas(Gas::from_gas(ggas * 1_000_000_000))
            .transact();
        let r = o.first_call().unwrap();
        println!("[put (20 Tgas), fail ({ggas} Ggas)]: {}; burnt {}; a = {:?}", rerr(r), r.gas_burnt, get(&sim, P, "a"));
        assert_eq!(r.failure(), Some(expect));
        assert_eq!(get(&sim, P, "a"), None);
    }
}

/// The attached gas of p.chain's three q.mark children, by tag, and the
/// leftover U computed without them: p.chain's attached gas less what it
/// used, which is its burn (gas burnt less its own exec fees, burnt
/// before it ran) plus the exec fees it prepaid for its children (their
/// statics are 0). This is the calibration's split formula (src/calib.rs,
/// `check_split`).
fn shares(sim: &mut Sim, prepaid: Gas) -> ([u64; 3], u64) {
    let kids: Vec<Value> = (1..=3).map(|i| call(Q, "mark", json!({ "tag": i.to_string() }), 0, 1)).collect();
    let o = chain(sim, json!(kids), None).gas(prepaid).transact();
    o.assert_success();
    let kid = |tag: &str| {
        o.receipts
            .iter()
            .find(|r| r.receiver_id.as_str() == Q && r.args_json::<Value>().map(|a| a["tag"] == tag).unwrap_or(false))
            .unwrap()
    };
    let p = o.expect_receipt("chain");
    let kid_exec: u64 = ["1", "2", "3"].iter().map(|t| kid(t).prepaid_exec_fees.as_gas()).sum();
    let used = p.gas_burnt.as_gas() - p.prepaid_exec_fees.as_gas() + kid_exec;
    ([kid("1"), kid("2"), kid("3")].map(|r| r.attached_gas.as_gas()), p.attached_gas.as_gas() - used)
}

/// G3. The leftover U is split by weight, each weighted call getting
/// ⌊U·w/W⌋ and the last one appended also the remainder
/// (runtime/runtime/src/receipt_manager.rs:679-719 `distribute_gas`,
/// :414-419 `gas_weights` pushed at append time). Three children of weight
/// 1 and static 0; U is derived from the parent's burn and fees (see
/// `shares`), not from the shares; the prepaid gas goes up one gas unit at
/// a time, and so does U.
#[test]
fn leftover_split_floor_and_remainder() {
    let base = world();
    let p0 = Gas::from_teragas(100).as_gas();
    let mut rems = Vec::new();
    let mut last_u = None;
    for d in 0..3u64 {
        let mut sim = base.clone();
        let ([a, b, c], u) = shares(&mut sim, Gas::from_gas(p0 + d));
        println!("prepaid 100 Tgas + {d} gas: U = {u}; shares {a}, {b}, {c} (sum {}); the last gets {} more", a + b + c, c - a);
        assert_eq!(a + b + c, u, "the children share exactly U");
        assert_eq!((a, b, c), (u / 3, u / 3, u / 3 + u % 3), "the floor each, the remainder to the last");
        if let Some(t) = last_u {
            assert_eq!(u, t + 1, "one more prepaid gas, one more leftover gas");
        }
        last_u = Some(u);
        rems.push(c - a);
    }
    rems.sort();
    assert_eq!(rems, [0, 1, 2]);
}

/// z.interleave's two q.mark children, A's (tag "a") and B's ("b"), by
/// attached gas, and the leftover U, as in `shares`.
fn interleaved(sim: &mut Sim, prepaid: Gas, order: &str) -> ([u64; 2], u64) {
    let o = sim.call(ALICE, Z, "interleave").args_json(json!({ "receiver": Q, "method": "mark", "order": order })).gas(prepaid).transact();
    o.assert_success();
    let kid = |tag: &str| {
        o.receipts
            .iter()
            .find(|r| r.receiver_id.as_str() == Q && r.args_json::<Value>().map(|a| a["tag"] == tag).unwrap_or(false))
            .unwrap()
    };
    let z = o.expect_receipt("interleave");
    let used = z.gas_burnt.as_gas() - z.prepaid_exec_fees.as_gas() + kid("a").prepaid_exec_fees.as_gas() + kid("b").prepaid_exec_fees.as_gas();
    ([kid("a").attached_gas.as_gas(), kid("b").attached_gas.as_gas()], z.attached_gas.as_gas() - used)
}

/// G3, "last" across promises. z creates A then B (both to q) and appends
/// one weight-1 call to each: the remainder goes to the action appended
/// last, whichever promise it is on (runtime/runtime/src/receipt_manager.rs:414-419
/// pushes `gas_weights` at append time; :679-719 gives the last entry the
/// remainder). In order "ba" that is A's, the earlier receipt; in "ab",
/// B's. Two consecutive prepaid amounts give U odd once.
#[test]
fn remainder_goes_to_last_appended() {
    let base = world();
    let p0 = Gas::from_teragas(100).as_gas();
    for order in ["ab", "ba"] {
        let mut rems = Vec::new();
        for d in 0..2u64 {
            let mut sim = base.clone();
            let ([a, b], u) = interleaved(&mut sim, Gas::from_gas(p0 + d), order);
            let (first, last) = if order == "ab" { (a, b) } else { (b, a) };
            println!("appended {order}, prepaid 100 Tgas + {d} gas: U = {u}; A gets {a}, B {b}; the last appended gets {} more", last - first);
            assert_eq!(a + b, u, "the children share exactly U");
            assert_eq!((first, last), (u / 2, u / 2 + u % 2), "the floor each, the remainder to the last appended");
            rems.push(last - first);
        }
        rems.sort();
        assert_eq!(rems, [0, 1]);
    }
}

/// S3. Every receipt of a chunk sees the block's height (near-vm-runner
/// logic/host.rs:827 `block_index`; the probe logs it); its outcome records
/// the block's height and timestamp. A receipt created by a receipt runs in
/// a later block (runtime/runtime/src/lib.rs:1222-1234: not instant, so
/// outgoing). The timestamp a contract reads (:837 `block_timestamp`):
/// `block_timestamp_read_by_contract`.
#[test]
fn block_height_and_timestamp() {
    let mut sim = world();
    let txs: Vec<CryptoHash> =
        [ALICE, BOB].iter().map(|u| sim.call(*u, P, "mark").args_json(json!({ "tag": u })).submit()).collect();
    sim.settle();
    let rs: Vec<ReceiptOutcome> = txs.iter().map(|t| sim.outcome(t).expect_receipt("mark").clone()).collect();
    for r in &rs {
        let logged: u64 = r.logs[0].rsplit(' ').next().unwrap().parse().unwrap();
        println!("{}'s mark ran at #{} (ts {}), logged block {logged}", r.predecessor_id, r.block_height, r.block_timestamp_ns);
        assert_eq!(logged, r.block_height, "env::block_height() is the block's");
    }
    assert_eq!((rs[0].block_height, rs[0].block_timestamp_ns), (rs[1].block_height, rs[1].block_timestamp_ns), "one chunk, one height and time");

    let kids = json!([call(P, "mark", json!({ "tag": "child" }), 10000, 1)]);
    let o = chain(&mut sim, kids, None).transact();
    let (parent, child) = (o.expect_receipt("chain"), o.expect_receipt("mark"));
    println!("p.chain at #{} (ts {}), its child p.mark at #{} (ts {})", parent.block_height, parent.block_timestamp_ns, child.block_height, child.block_timestamp_ns);
    assert_eq!(child.block_height, parent.block_height + 1, "a created receipt runs in a later block");
    assert!(child.block_timestamp_ns > parent.block_timestamp_ns);
    assert!(parent.block_height > rs[0].block_height && parent.block_timestamp_ns > rs[0].block_timestamp_ns);
}

/// S3, the timestamp a contract reads (near-vm-runner logic/host.rs:837
/// `block_timestamp`, from the apply state:
/// runtime/runtime/src/function_call.rs:267). z.clock logs the height and
/// timestamp it read. Two receipts of one chunk read the same timestamp,
/// the one their outcomes record; the child alice's clock creates runs a
/// block later and reads a larger one.
#[test]
fn block_timestamp_read_by_contract() {
    let mut sim = world();
    let txs: Vec<CryptoHash> = [(ALICE, true), (BOB, false)]
        .iter()
        .map(|(u, kid)| sim.call(*u, Z, "clock").args_json(json!({ "tag": u, "kid": kid })).submit())
        .collect();
    sim.settle();
    let mut seen = Vec::new();
    for t in &txs {
        for r in sim.outcome(t).receipts.iter().filter(|r| r.method_names == ["clock"]) {
            let w: Vec<&str> = r.logs[0].split(' ').collect();
            let (h, ts): (u64, u64) = (w[2].parse().unwrap(), w[3].parse().unwrap());
            println!("{} ran at #{} (outcome ts {}), read height {h}, timestamp {ts}", w[1], r.block_height, r.block_timestamp_ns);
            assert_eq!((h, ts), (r.block_height, r.block_timestamp_ns), "it reads the block's height and timestamp");
            seen.push((w[1].to_string(), h, ts));
        }
    }
    let at = |tag: &str| seen.iter().find(|s| s.0 == tag).map(|s| (s.1, s.2)).unwrap();
    let (a, b, kid) = (at(ALICE), at(BOB), at(&format!("{ALICE}+")));
    assert_eq!(seen.len(), 3);
    assert_eq!(a, b, "one chunk, one height and timestamp");
    assert_eq!(kid.0, a.0 + 1, "the child runs a block later");
    assert!(kid.1 > a.1, "and reads a larger timestamp");
}
