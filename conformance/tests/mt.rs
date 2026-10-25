//! The NEP-245 multi token on the `mt` probe, a plain
//! near-sdk-contract-tools 4.0.0 `Nep245` (conformance/probes/mt), observed
//! in the sim for docs/SEMANTICS.md T5: the transfers' requirements, batch
//! moves, the gas `mt_[batch_]transfer_call` gives its two calls, and
//! `mt_resolve_transfer`'s per-id arithmetic (the wrong-length result, the
//! cap at the amount and at the receiver's balance). The receiver is the
//! `mtrecv` probe, whose `mt_on_transfer` answers as `msg` says. Each test
//! prints what it observed; `cargo test --test mt -- --nocapture` shows it.
//!
//! These are near-sdk-contract-tools rules, not nearcore's. References:
//! near-sdk-contract-tools-macros 4.0.0 `src/standard/nep245/mod.rs` (the
//! generated methods; "macros" below), near-sdk-contract-tools 4.0.0
//! `src/standard/nep245/mod.rs` ("core"), near-sdk 5.29.1
//! `src/utils/mod.rs:84-89` (`assert_one_yocto`).
use near_contract_sim::prelude::*;
use near_tla_conformance::probe_wasm;
use serde_json::json;

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const MT: &str = "mt-probe.near";
const RX: &str = "mr-probe.near";
const SUPPLY: u128 = 1000;
const ONE: &str = "Requires attached deposit of exactly 1 yoctoNEAR";

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

/// alice holds `SUPPLY` of each of t1, t2 and t3; bob and the receiver
/// hold none.
fn world() -> Sim {
    let (mt, _) = probe_wasm("mt");
    let (rx, _) = probe_wasm("mtrecv");
    Fixture::new()
        .account(ALICE, near(100))
        .account(BOB, near(100))
        .contract(MT, mt)
        .init("new", json!({ "owner_id": ALICE, "token_ids": ["t1", "t2", "t3"], "supply": SUPPLY.to_string() }))
        .contract(RX, rx)
        .build()
}

fn bal(sim: &Sim, who: &str, id: &str) -> u128 {
    sim.view(MT, "mt_balance_of", json!({ "account_id": who, "token_id": id })).json::<String>().parse().unwrap()
}

fn bals(sim: &Sim, who: &str) -> [u128; 3] {
    [bal(sim, who, "t1"), bal(sim, who, "t2"), bal(sim, who, "t3")]
}

fn err(o: &TxOutcome) -> String {
    format!("{:?}", o.failure())
}

fn panics(o: &TxOutcome, msg: &str) -> bool {
    o.failure() == Some(Failure::Panic(msg.to_string()))
}

fn strs(v: &[u128]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

fn batch<'a>(sim: &'a mut Sim, from: &str, to: &str, ids: &[&str], amounts: &[u128], yocto: u128) -> Tx<'a> {
    sim.call(from, MT, "mt_batch_transfer")
        .args_json(json!({ "receiver_id": to, "token_ids": ids, "amounts": strs(amounts) }))
        .deposit(Balance::from_yoctonear(yocto))
}

fn batch_call<'a>(sim: &'a mut Sim, from: &str, ids: &[&str], amounts: &[u128], msg: &str, yocto: u128) -> Tx<'a> {
    sim.call(from, MT, "mt_batch_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_ids": ids, "amounts": strs(amounts), "msg": msg }))
        .deposit(Balance::from_yoctonear(yocto))
}

/// T5, the transfers. Every transfer method needs exactly 1 yocto (macros
/// :84, :113, :151, :188); a batch whose `token_ids` and `amounts` differ
/// in length panics (macros :116-126, core :110-142); a batch moves every
/// id, in order, and a short balance on any id panics, so none moves (core
/// :791-822, :763-772); `mt_[batch_]transfer_call` needs at least 30 Tgas
/// prepaid, checked before the deposit (macros :146-149, :183-186; core
/// :45-49).
#[test]
fn mt_transfer_requirements() {
    let mut sim = world();
    let single = |sim: &mut Sim, m: &str, yocto: u128| {
        sim.call(ALICE, MT, m)
            .args_json(json!({ "receiver_id": BOB, "token_id": "t1", "amount": "5", "msg": "keep" }))
            .deposit(Balance::from_yoctonear(yocto))
            .transact()
    };
    for m in ["mt_transfer", "mt_transfer_call"] {
        for y in [0, 2] {
            let o = single(&mut sim, m, y);
            println!("{m} with {y} yocto: {}", err(&o));
            assert!(panics(&o, ONE), "{o}");
        }
    }
    for y in [0, 2] {
        let o = batch(&mut sim, ALICE, BOB, &["t1", "t2"], &[1, 1], y).transact();
        println!("mt_batch_transfer with {y} yocto: {}", err(&o));
        assert!(panics(&o, ONE), "{o}");
        let o = batch_call(&mut sim, ALICE, &["t1", "t2"], &[1, 1], "keep", y).transact();
        println!("mt_batch_transfer_call with {y} yocto: {}", err(&o));
        assert!(panics(&o, ONE), "{o}");
    }
    let lens = "Input arrays have inconsistent lengths.";
    let o = batch(&mut sim, ALICE, BOB, &["t1", "t2"], &[1], 1).transact();
    println!("mt_batch_transfer, 2 ids and 1 amount: {}", err(&o));
    assert!(panics(&o, lens), "{o}");
    let o = batch_call(&mut sim, ALICE, &["t1"], &[1, 1], "keep", 1).transact();
    println!("mt_batch_transfer_call, 1 id and 2 amounts: {}", err(&o));
    assert!(panics(&o, lens), "{o}");
    assert_eq!(bals(&sim, BOB), [0, 0, 0], "nothing moved");

    // A batch moves each id.
    batch(&mut sim, ALICE, BOB, &["t1", "t3"], &[10, 30], 1).transact().assert_success();
    println!("batch t1:10, t3:30 to bob: bob holds {:?}", bals(&sim, BOB));
    assert_eq!(bals(&sim, BOB), [10, 0, 30]);
    assert_eq!(bals(&sim, ALICE), [SUPPLY - 10, SUPPLY, SUPPLY - 30]);
    // The same id twice: two moves.
    batch(&mut sim, ALICE, BOB, &["t2", "t2"], &[2, 3], 1).transact().assert_success();
    assert_eq!(bal(&sim, BOB, "t2"), 5);
    // Short on the second id: the whole batch fails, the first id stays.
    let o = batch(&mut sim, BOB, ALICE, &["t1", "t3"], &[10, 31], 1).transact();
    println!("bob sends t1:10, t3:31 holding 10 and 30: {}", err(&o));
    assert!(err(&o).contains("Balance of the sender is insufficient"), "{o}");
    assert_eq!(bals(&sim, BOB), [10, 5, 30], "nothing moved");

    // The gas floor of the _call methods: 30 Tgas, checked before the deposit.
    let insufficient = "Insufficient gas attached.";
    let o = batch_call(&mut sim, ALICE, &["t1"], &[1], "keep", 0).gas(Gas::from_gigagas(29_900)).transact();
    println!("mt_batch_transfer_call at 29.9 Tgas, no deposit: {}", err(&o));
    assert!(panics(&o, insufficient), "{o}");
    let o = sim
        .call(ALICE, MT, "mt_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_id": "t1", "amount": "1", "msg": "keep" }))
        .deposit(Balance::from_yoctonear(1))
        .gas(Gas::from_gigagas(29_900))
        .transact();
    println!("mt_transfer_call at 29.9 Tgas: {}", err(&o));
    assert!(panics(&o, insufficient), "{o}");
    let o = batch_call(&mut sim, ALICE, &["t1"], &[1], "keep", 1).gas(Gas::from_teragas(30)).transact();
    println!("mt_batch_transfer_call at 30 Tgas: {:?}", o.failure());
    o.assert_success();
    let o = sim
        .call(ALICE, MT, "mt_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_id": "t1", "amount": "1", "msg": "keep" }))
        .deposit(Balance::from_yoctonear(1))
        .gas(Gas::from_teragas(30))
        .transact();
    println!("mt_transfer_call at 30 Tgas: {:?}", o.failure());
    o.assert_success();
    assert_eq!(bal(&sim, RX, "t1"), 2, "both 30 Tgas calls delivered");
}

/// T5, what near-sdk-contract-tools 4.0.0 does not check (N-mt): a zero
/// amount is skipped, not refused (core :796, :758-760), and nothing
/// compares the sender with the receiver. `transfer_unchecked` (core
/// :745-789) reads both balances before writing either, so a transfer to
/// oneself writes the receiver's `balance + amount` last: the sender's
/// balance grows by the amount.
#[test]
fn mt_zero_and_self_transfers() {
    let mut sim = world();
    let one = |sim: &mut Sim, to: &str, amount: u128| {
        sim.call(ALICE, MT, "mt_transfer")
            .args_json(json!({ "receiver_id": to, "token_id": "t1", "amount": amount.to_string() }))
            .deposit(Balance::from_yoctonear(1))
            .transact()
    };
    let o = one(&mut sim, BOB, 0);
    println!("mt_transfer of 0 to bob: {:?}; bob {:?}", o.failure(), bals(&sim, BOB));
    o.assert_success();
    assert_eq!(bals(&sim, BOB), [0, 0, 0]);
    let o = batch(&mut sim, ALICE, BOB, &["t1", "t2"], &[5, 0], 1).transact();
    println!("batch t1:5, t2:0 to bob: {:?}; bob {:?}", o.failure(), bals(&sim, BOB));
    o.assert_success();
    assert_eq!(bals(&sim, BOB), [5, 0, 0]);
    let o = one(&mut sim, ALICE, 0);
    println!("mt_transfer of 0 to alice herself: {:?}; alice {:?}", o.failure(), bals(&sim, ALICE));
    o.assert_success();
    assert_eq!(bal(&sim, ALICE, "t1"), SUPPLY - 5, "a zero entry is dropped before anything else");
    let o = one(&mut sim, ALICE, 10);
    println!("mt_transfer of 10 to alice herself: {:?}; alice {:?}", o.failure(), bals(&sim, ALICE));
    o.assert_success();
    assert_eq!(bal(&sim, ALICE, "t1"), SUPPLY - 5 + 10, "the self-transfer credits the amount");
    let o = one(&mut sim, ALICE, SUPPLY + 6);
    println!("mt_transfer of more than alice holds to herself: {}", err(&o));
    assert!(err(&o).contains("Balance of the sender is insufficient"), "{o}");
}

/// T5, `mt_[batch_]transfer_call`'s receipts and gas (core :264-287): the
/// receiver's `mt_on_transfer(sender_id, previous_owner_ids, token_ids,
/// amounts, msg)` with static 0 and weight 10, then the token's
/// `mt_resolve_transfer(sender_id, receiver_id, token_ids, amounts)` with
/// static 5 Tgas and weight 1 (GAS_FOR_MT_RESOLVE_TRANSFER, core :45),
/// for any number of ids. The call returns the resolver's value, the
/// amounts used.
#[test]
fn mt_transfer_call_receipts() {
    // At the default 300 Tgas prepaid, (mt_on_transfer, mt_resolve_transfer)
    // in whole Ggas, for 1, 2 and 3 ids: each id costs the call about 0.4
    // Tgas of burn, which comes out of the leftover both calls share.
    let attached = [(265_023, 31_502), (264_644, 31_464), (264_265, 31_426)];
    for (ids, want) in [vec!["t1"], vec!["t1", "t2"], vec!["t1", "t2", "t3"]].into_iter().zip(attached) {
        let mut sim = world();
        let amounts: Vec<u128> = (1..=ids.len() as u128).map(|i| 10 * i).collect();
        let o = batch_call(&mut sim, ALICE, &ids, &amounts, "keep", 1).transact();
        o.assert_success();
        let calls: Vec<_> = o.receipts.iter().filter(|r| !r.is_refund()).collect();
        let order: Vec<String> = calls.iter().map(|r| format!("{}::{}", r.executor_id, r.method_names.join("+"))).collect();
        assert_eq!(order, [format!("{MT}::mt_batch_transfer_call"), format!("{RX}::mt_on_transfer"), format!("{MT}::mt_resolve_transfer")]);
        let on = calls[1].attached_gas.as_gas() as i128;
        let res = calls[2].attached_gas.as_gas() as i128;
        let five = Gas::from_teragas(5).as_gas() as i128;
        println!("{} ids: mt_on_transfer {} Ggas, mt_resolve_transfer {} Ggas; returns {:?}",
                 ids.len(), on / 1_000_000_000, res / 1_000_000_000, o.json::<Vec<String>>());
        // The leftover L splits 10 : 1, the resolver getting 5 Tgas besides
        // (and the few gas of the floor's remainder, as the last weighted call).
        let d = (res - five) * 10 - on;
        assert!((0..=1000).contains(&d), "weights 10 and 1, static 5 Tgas: {on} vs {res}");
        assert_eq!(((on / 1_000_000_000) as u64, (res / 1_000_000_000) as u64), want, "attached gas, Ggas");
        assert_eq!(o.json::<Vec<String>>(), strs(&amounts), "all used");
        assert_eq!(bal(&sim, RX, "t1"), 10);
    }
    // The single-id call: the same receipts, vectors of one.
    let mut sim = world();
    let o = sim
        .call(ALICE, MT, "mt_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_id": "t2", "amount": "7", "msg": "return" }))
        .deposit(Balance::from_yoctonear(1))
        .transact();
    let order: Vec<String> = o.receipts.iter().filter(|r| !r.is_refund()).map(|r| format!("{}::{}", r.executor_id, r.method_names.join("+"))).collect();
    println!("mt_transfer_call t2:7, receiver returns all: {order:?}; returns {:?}", o.json::<Vec<String>>());
    assert_eq!(order, [format!("{MT}::mt_transfer_call"), format!("{RX}::mt_on_transfer"), format!("{MT}::mt_resolve_transfer")]);
    assert_eq!(o.json::<Vec<String>>(), ["0"]);
    assert_eq!(bal(&sim, ALICE, "t2"), SUPPLY);
}

/// T5, end to end: `mt_batch_transfer_call` of t1:10, t2:20 to the
/// receiver, for each answer of the receiver. Per id, unused = min(answer,
/// amount); a Failed, malformed or wrong-length answer is all unused; the
/// refund goes back to the sender (core :544-602).
#[test]
fn mt_batch_transfer_call_answers() {
    let cases: [(&str, [u128; 2]); 9] = [
        ("keep", [10, 20]),
        ("return", [0, 0]),
        ("over", [0, 0]),
        ("vec:3,25", [7, 0]),
        ("short", [0, 0]),
        ("long", [0, 0]),
        ("mal", [0, 0]),
        ("empty", [0, 0]),
        ("panic", [0, 0]),
    ];
    for (msg, used) in cases {
        let mut sim = world();
        let o = batch_call(&mut sim, ALICE, &["t1", "t2"], &[10, 20], msg, 1).transact();
        let got: Vec<String> = o.json();
        println!("receiver answers {msg}: returns {got:?}; receiver holds {:?}", bals(&sim, RX));
        assert_eq!(got, strs(&used));
        assert_eq!(bals(&sim, RX), [used[0], used[1], 0]);
        assert_eq!(bals(&sim, ALICE), [SUPPLY - used[0], SUPPLY - used[1], SUPPLY]);
    }
}

/// `mt_resolve_transfer(sender, receiver, token_ids, amounts)` delivered as
/// the token's callback on `result` (`Tx::promise_results`: nearcore's
/// callback path, predecessor the token, so `#[private]` passes).
fn resolve(sim: &mut Sim, receiver: &str, ids: &[&str], amounts: &[u128], result: PromiseResult) -> TxOutcome {
    sim.call(ALICE, MT, "mt_resolve_transfer")
        .args_json(json!({ "sender_id": ALICE, "receiver_id": receiver, "token_ids": ids, "amounts": strs(amounts) }))
        .promise_results([result])
        .transact()
}

/// T5, `mt_resolve_transfer` (macros :272-299, core :544-602). The result
/// is read unbounded (`env::promise_result(0)`, macros :283) as a
/// `Vec<U128>`; Failed, unparsable or of a length other than the ids' is
/// all unused (core :552-564). Per id, unused = min(answer, amount); the
/// refund is min(unused, the receiver's balance), the balance taken as it
/// stands after the refunds of earlier entries of the same id (core
/// :566-596), moved back to the sender. It returns the amounts used. Only
/// the token may call it.
#[test]
fn mt_resolve_transfer_rules() {
    let mut base = world();
    batch(&mut base, ALICE, BOB, &["t1", "t2"], &[100, 100], 1).transact().assert_success();
    let vec = |v: &[u128]| PromiseResult::json(&strs(v));
    let cases: Vec<(&str, PromiseResult, [u128; 2])> = vec![
        ("Failed", PromiseResult::Failed, [0, 0]),
        ("[\"20\", \"10\"]", vec(&[20, 10]), [30, 20]),
        ("[\"80\", \"10\"], over the amount on t1", vec(&[80, 10]), [0, 20]),
        ("[\"0\", \"0\"]", vec(&[0, 0]), [50, 30]),
        ("[\"20\"], one short", vec(&[20]), [0, 0]),
        ("[\"20\", \"10\", \"5\"], one long", vec(&[20, 10, 5]), [0, 0]),
        ("[], empty vector", vec(&[]), [0, 0]),
        ("\"20\", a number, not a vector", PromiseResult::json("20"), [0, 0]),
        ("not JSON", PromiseResult::Successful(b"x".to_vec()), [0, 0]),
        ("no bytes", PromiseResult::Successful(vec![]), [0, 0]),
    ];
    for (what, result, used) in cases {
        let mut sim = base.clone();
        let o = resolve(&mut sim, BOB, &["t1", "t2"], &[50, 30], result);
        let got: Vec<String> = o.json();
        println!("t1:50, t2:30, result {what}: returns {got:?}; bob {:?}", bals(&sim, BOB));
        assert_eq!(got, strs(&used));
        assert_eq!(bals(&sim, BOB), [100 - (50 - used[0]), 100 - (30 - used[1]), 0], "the refunds came from bob");
        assert_eq!(bals(&sim, ALICE), [SUPPLY - 100 + 50 - used[0], SUPPLY - 100 + 30 - used[1], SUPPLY], "and went to alice");
    }

    // The refund is capped at the receiver's balance, per id.
    let mut sim = world();
    batch(&mut sim, ALICE, BOB, &["t1", "t2"], &[5, 100], 1).transact().assert_success();
    let o = resolve(&mut sim, BOB, &["t1", "t2"], &[50, 30], PromiseResult::Failed);
    println!("bob holding t1:5, t2:100, result Failed: returns {:?}; bob {:?}", o.json::<Vec<String>>(), bals(&sim, BOB));
    assert_eq!(o.json::<Vec<String>>(), ["45", "0"]);
    assert_eq!(bals(&sim, BOB), [0, 70, 0]);

    // The same id twice shares the receiver's balance: t1:3 then t1:4 with
    // bob holding 5 refunds 3, then min(4, 2).
    let mut sim = world();
    batch(&mut sim, ALICE, BOB, &["t1"], &[5], 1).transact().assert_success();
    let o = resolve(&mut sim, BOB, &["t1", "t1"], &[3, 4], PromiseResult::Failed);
    println!("bob holding t1:5, t1:3 and t1:4, result Failed: returns {:?}; bob {:?}", o.json::<Vec<String>>(), bals(&sim, BOB));
    assert_eq!(o.json::<Vec<String>>(), ["0", "2"]);
    assert_eq!(bal(&sim, BOB, "t1"), 0);

    // token_ids and amounts of different lengths (a direct call; the
    // transfer methods refuse them): the answer's length is compared with
    // amounts' (core :552-553), and the ids, the bounded answers and the
    // amounts are zipped, so the shortest decides how many entries are
    // refunded and returned (core :585-589).
    let zip: Vec<(&[&str], &[u128], PromiseResult, &[u128], [u128; 2])> = vec![
        (&["t1", "t2"], &[50], vec(&[20]), &[30], [80, 100]),
        (&["t1"], &[50, 30], vec(&[20, 10]), &[30], [80, 100]),
        (&["t1"], &[50, 30], vec(&[20]), &[0], [50, 100]),
    ];
    for (ids, amounts, result, used, bob) in zip {
        let mut sim = base.clone();
        let o = resolve(&mut sim, BOB, ids, amounts, result);
        let got: Vec<String> = o.json();
        println!("ids {ids:?}, amounts {amounts:?}: returns {got:?}; bob {:?}", bals(&sim, BOB));
        assert_eq!(got, strs(used));
        assert_eq!(bals(&sim, BOB), [bob[0], bob[1], 0]);
    }

    // One id twice, refunded to the sender itself (sender = receiver): the
    // caps come from the balance read before any refund (5, then 0), and
    // the refunds are applied afterwards, each crediting (core :573-599).
    let mut sim = world();
    batch(&mut sim, ALICE, BOB, &["t1"], &[5], 1).transact().assert_success();
    let o = sim
        .call(ALICE, MT, "mt_resolve_transfer")
        .args_json(json!({ "sender_id": BOB, "receiver_id": BOB, "token_ids": ["t1", "t1"], "amounts": ["5", "5"] }))
        .promise_results([PromiseResult::Failed])
        .transact();
    println!("bob to bob, holding t1:5, t1:5 twice, result Failed: returns {:?}; bob {:?}", o.json::<Vec<String>>(), bals(&sim, BOB));
    assert_eq!(o.json::<Vec<String>>(), ["0", "5"]);
    assert_eq!(bal(&sim, BOB, "t1"), 10);

    // Only the token may call it.
    let o = sim
        .call(ALICE, MT, "mt_resolve_transfer")
        .args_json(json!({ "sender_id": ALICE, "receiver_id": BOB, "token_ids": ["t1"], "amounts": ["1"] }))
        .transact();
    println!("alice calls it: {}", err(&o));
    assert!(panics(&o, "Method mt_resolve_transfer is private"), "{o}");
}


/// `n` distinct token ids of `len` bytes each: a common prefix of `p`s and
/// two distinct trailing characters, so every comparison of two ids reads
/// all `len` bytes (the worst case for the resolver's `position`).
fn ids_of(n: usize, len: usize) -> Vec<String> {
    const A: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    assert!(len >= 2 && n <= A.len() * A.len());
    (0..n).map(|i| format!("{}{}{}", "p".repeat(len - 2), A[i / A.len()] as char, A[i % A.len()] as char)).collect()
}

/// `world` with alice holding `SUPPLY` of each of `ids`. `new` mints with
/// one event per id, so it can create at most 100 ids (and 16384 bytes of
/// events) per call: the ids past the first call's are created in other
/// sims and their storage entries copied in.
fn world_ids(ids: &[String]) -> Sim {
    let (mt, _) = probe_wasm("mt");
    let (rx, _) = probe_wasm("mtrecv");
    let per = (16000 / (ids[0].len() + 180)).min(100);
    let init = |sim: Fixture, chunk: &[String]| sim.contract(MT, mt.clone()).init("new", json!({ "owner_id": ALICE, "token_ids": chunk, "supply": SUPPLY.to_string() }));
    let mut chunks = ids.chunks(per);
    let mut sim = init(Fixture::new().account(ALICE, near(100)).account(BOB, near(100)), chunks.next().unwrap())
        .contract(RX, rx)
        .build();
    for chunk in chunks {
        let other = init(Fixture::new().account(ALICE, near(100)), chunk).build();
        for (k, v) in other.view_state(MT, b"") {
            if sim.state(MT, &k).is_none() {
                sim.set_state(MT, &k, Some(&v));
            }
        }
    }
    sim
}

/// A receipt's own burn, as the calibrator counts it: what it burnt less
/// its prepaid exec fees.
fn own_burn(r: &near_contract_sim::ReceiptOutcome) -> Option<u64> {
    r.failure().is_none().then(|| (r.gas_burnt.as_gas() - r.prepaid_exec_fees.as_gas()) / 1_000_000_000)
}

/// `(base, per)` of CalibStdMt's burn key for `method`, in Ggas, read from
/// modules/CalibStdMt.tla.
fn calib_std_mt(method: &str) -> (u64, u64) {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../modules/CalibStdMt.tla");
    let text = std::fs::read_to_string(path).expect("modules/CalibStdMt.tla");
    let tag = format!("\".{method}\" :> [base |-> ");
    let rest = &text[text.find(&tag).unwrap_or_else(|| panic!("no key {method} in CalibStdMt")) + tag.len()..];
    let num = |s: &str| s.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse::<u64>().unwrap();
    let base = num(rest);
    let per = num(&rest[rest.find("per |-> ").unwrap() + "per |-> ".len()..]);
    (base, per)
}

/// The per-id slope of `b` between consecutive sizes of `ns`, Ggas.
fn slopes(ns: &[usize], b: &[Option<u64>]) -> Vec<f64> {
    (1..ns.len()).filter_map(|k| Some((b[k]? as f64 - b[k - 1]? as f64) / (ns[k] - ns[k - 1]) as f64)).collect()
}

/// T5 gas, the burn per id at batch sizes past the calibration's 1-3 ids,
/// for ids of 2, 16 and 64 bytes (the longer ones sharing all but two
/// bytes). The batch methods burn linearly in the number of ids, at a slope
/// that grows with the ids' length (each id is parsed, hashed into its
/// storage keys and logged). The resolver does not: it looks each entry's
/// id up in `token_ids` with `position` inside its per-entry loops (core
/// :569-576), so it compares n² / 2 pairs of ids twice, and its burn grows
/// faster than linearly, the more so the longer the ids' common prefix
/// (both paths: refunding every id, Failed; refunding none, all used).
/// CalibStdMt fits one line per method to 1-3 ids of 2 bytes; Nep245's
/// MtGasIds (3) and MtGasIdLen (2) refuse other calls in gas mode, and the
/// two overruns that justify them are asserted against the table. No
/// model comparison: the observations are printed (Ggas; "-" out of gas
/// at 300 Tgas), with the shape asserted.
#[test]
fn mt_burn_per_id() {
    for len in [2usize, 16, 64] {
        // 256 ids of 64 bytes log an event over 16384 bytes.
        let ns: &[usize] = if len < 64 { &[1, 2, 4, 8, 16, 32, 64, 128, 256] } else { &[1, 2, 4, 8, 16, 32, 64, 128] };
        let (mut bt, mut bc, mut rr, mut rn) = (vec![], vec![], vec![], vec![]);
        for &n in ns {
            let ids = ids_of(n, len);
            let idr: Vec<&str> = ids.iter().map(|s| s.as_str()).collect();
            let amts = vec![5u128; n];
            let base = world_ids(&ids);
            // mt_batch_transfer alice -> bob, every id.
            let mut sim = base.clone();
            let o = batch(&mut sim, ALICE, BOB, &idr, &amts, 1).transact();
            o.assert_success();
            bt.push(own_burn(&o.receipts[0]));
            // mt_batch_transfer_call to the receiver, which keeps them.
            let mut call = base.clone();
            let o = batch_call(&mut call, ALICE, &idr, &amts, "keep", 1).transact();
            bc.push(own_burn(&o.receipts[0]));
            // The resolver, bob holding every id: Failed refunds them all;
            // an answer of zeros (all used) refunds none.
            let mut refund = sim.clone();
            rr.push(own_burn(&resolve(&mut refund, BOB, &idr, &amts, PromiseResult::Failed).receipts[0]));
            rn.push(own_burn(&resolve(&mut sim, BOB, &idr, &amts, PromiseResult::json(&strs(&vec![0; n]))).receipts[0]));
        }
        let show = |b: &[Option<u64>]| b.iter().map(|x| x.map_or("-".to_string(), |g| g.to_string())).collect::<Vec<_>>().join(" ");
        println!("ids of {len} bytes, n = {ns:?}:");
        println!("  mt_batch_transfer       {}", show(&bt));
        println!("  mt_batch_transfer_call  {}", show(&bc));
        println!("  mt_resolve_transfer, refunding all  {}", show(&rr));
        println!("  mt_resolve_transfer, refunding none {}", show(&rn));
        // The batch methods: linear, every slope from 2 ids on within 5%
        // of every other.
        for (what, b) in [("mt_batch_transfer", &bt), ("mt_batch_transfer_call", &bc)] {
            let s = slopes(&ns[1..], &b[1..]);
            let (lo, hi) = s.iter().fold((f64::MAX, 0f64), |(l, h), &x| (l.min(x), h.max(x)));
            println!("  {what}: Ggas per id {lo:.1}-{hi:.1}");
            assert!(s.len() == ns.len() - 2 && hi <= lo * 1.05, "{what} at {len}-byte ids is not linear: {s:?}");
        }
        // The resolver: the slope grows, by at least 10% from 8-16 ids to
        // the largest size measured, on the path that refunds nothing.
        for (what, b) in [("refunding all", &rr), ("refunding none", &rn)] {
            let s = slopes(ns, b);
            println!("  mt_resolve_transfer, {what}: Ggas per id {:?}", s.iter().map(|x| x.round() as i64).collect::<Vec<_>>());
            let (first, last) = (s[3], *s.last().unwrap());
            assert!(last >= first, "resolver ({what}) at {len}-byte ids: slope {first:.1} at 8-16 ids, {last:.1} at the top");
            if what == "refunding none" {
                assert!(last >= first * 1.1, "resolver ({what}) at {len}-byte ids grows faster than linearly: {s:?}");
            }
        }
        // Against CalibStdMt's keys (base + per * n, read from the table),
        // the two facts Nep245's gas-mode guards rest on: at 2-byte ids a
        // resolver refunding 4 ids burns more than the resolver key
        // (MtGasIds = 3), and at 64-byte ids one id burns more than the
        // batch methods' keys (MtGasIdLen = 2).
        let line = |m: &str, n: usize| {
            let (b, p) = calib_std_mt(m);
            b + p * n as u64
        };
        println!("  CalibStdMt: {}", ns.iter().map(|&n| format!("{}/{}/{}", line("mt_batch_transfer", n), line("mt_batch_transfer_call", n), line("mt_resolve_transfer", n))).collect::<Vec<_>>().join(" "));
        if len == 2 {
            let four = rr[2].unwrap();
            assert!(four > line("mt_resolve_transfer", 4), "a refund of 4 ids burns {four}, within the resolver key's {}", line("mt_resolve_transfer", 4));
        }
        if len == 64 {
            for (m, b) in [("mt_batch_transfer", &bt), ("mt_batch_transfer_call", &bc)] {
                let one = b[0].unwrap();
                assert!(one > line(m, 1), "{m} of one 64-byte id burns {one}, within the key's {}", line(m, 1));
            }
        }
    }
}
