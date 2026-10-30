//! NEP-297 event logs of the standard tokens, observed in the sim for
//! docs/SEMANTICS.md T8: the byte length of every `EVENT_JSON:` log the
//! `ft` probe (near-contract-standards 5.29.1) and the `mt` probe
//! (near-sdk-contract-tools 4.0.0) write equals the length the model
//! computes from the event's content (`TokenCommon`'s `EvLen`, `FtXferItem`,
//! `FtOwnerItem`, `MtXferItem`, `MtOwnerItem`), and the plain logs of
//! near-contract-standards' core have their fixed text. The formulas are
//! restated below (`ev_len` and the item functions) with the model's
//! constants; `examples/event-logs` (`EventLens.tla`) checks the model's
//! operators on the lengths these tests print. Each test prints what it
//! observed; `cargo test --test events -- --nocapture` shows it.
//!
//! Serialization (cited at the crates' versions above):
//! - near-contract-standards `src/event.rs:5-30`: `serde_json::to_string` of
//!   `{"standard", "version", "event", "data"}` (the tag `standard`, then
//!   `Nep141Event`'s `version` and the flattened `event`/`data` pair,
//!   `fungible_token/events.rs:98-123`), prefixed with `EVENT_JSON:` and
//!   logged with `log_str`, one log per `emit`. The items:
//!   `FtTransfer {old_owner_id, new_owner_id, amount, memo?}` and
//!   `FtMint`/`FtBurn {owner_id, amount, memo?}` (`events.rs:21-96`), the
//!   amount a JSON string (`U128`), `memo` omitted when `None`.
//! - near-sdk-contract-tools `src/standard/nep297.rs:41-89` (`EventLog
//!   {standard, version, event, data}`, `EVENT_JSON:` + `serde_json`), the
//!   variant name snake-cased by the `event` macro (macros
//!   `src/standard/event.rs:41-45`, `src/standard/nep297.rs:98-127`);
//!   `data` is the variant's `Vec`, always of one item here
//!   (`src/standard/nep245/mod.rs:809-817`, `:835-841`, `:858-865`). The
//!   items: `MtTransferData {authorized_id?, old_owner_id, new_owner_id,
//!   token_ids, amounts, memo?}`, `MtMintData {owner_id, token_ids, amounts,
//!   memo?}`, `MtBurnData {authorized_id?, owner_id, token_ids, amounts,
//!   memo?}` (`src/standard/nep245/event.rs:39-90`); `authorized_id` is
//!   always `None` in the core (`mod.rs:810`, `:859`).
//!
//! JSON strings are escaped (`"` and `\` take two bytes, control characters
//! more), so a length here is the escaped UTF-8 length (`esc`).
use near_contract_sim::prelude::*;
use near_contract_sim::Token;
use near_tla_conformance::probe_wasm;
use serde_json::json;

const ALICE: &str = "alice.near";
const BO: &str = "bo.near";
const LONG: &str = "a-fairly-long-account-name-for-event-length-checks.near";
const CAROL: &str = "carol.near";
const P: &str = "p-probe.near";
const FT: &str = "ft-probe.near";
const MT: &str = "mt-probe.near";
const RX: &str = "mr-probe.near";

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

/// The escaped length of a JSON string's content.
fn esc(s: &str) -> usize {
    serde_json::to_string(s).unwrap().len() - 2
}

fn digits(x: u128) -> usize {
    x.to_string().len()
}

/// `EvLen(std, ev, items)`: `EVENT_JSON:` (11) `{"standard":"` (13) std
/// `","version":"` (13) `1.0.0` (5) `","event":"` (11) ev `","data":[` (10)
/// the items, comma-separated, `]}` (2).
fn ev_len(std: &str, ev: &str, items: &[usize]) -> usize {
    11 + 13 + std.len() + 13 + 5 + 11 + ev.len() + 10 + items.iter().sum::<usize>() + items.len().saturating_sub(1) + 2
}

/// `,"memo":"` (9) memo `"` (1), or nothing.
fn memo_len(m: Option<&str>) -> usize {
    m.map_or(0, |m| 10 + esc(m))
}

/// `{"old_owner_id":"` o `","new_owner_id":"` n `","amount":"` d `"` memo `}`: 49 + ...
fn ft_xfer_item(o: &str, n: &str, amount: u128, m: Option<&str>) -> usize {
    49 + o.len() + n.len() + digits(amount) + memo_len(m)
}

/// `{"owner_id":"` o `","amount":"` d `"` memo `}`: 27 + ...
fn ft_owner_item(o: &str, amount: u128, m: Option<&str>) -> usize {
    27 + o.len() + digits(amount) + memo_len(m)
}

/// A JSON array of strings, without its brackets: each entry quoted, commas between.
fn list(lens: &[usize]) -> usize {
    if lens.is_empty() { 0 } else { lens.iter().sum::<usize>() + 3 * lens.len() - 1 }
}

/// `{"old_owner_id":"` o `","new_owner_id":"` n `","token_ids":[` ids `],"amounts":[` amounts `]` memo `}`: 65 + ...
fn mt_xfer_item(o: &str, n: &str, ids: &[&str], amounts: &[u128], m: Option<&str>) -> usize {
    65 + o.len() + n.len() + list(&ids.iter().map(|i| esc(i)).collect::<Vec<_>>())
        + list(&amounts.iter().map(|a| digits(*a)).collect::<Vec<_>>()) + memo_len(m)
}

/// `{"owner_id":"` o `","token_ids":[` ids `],"amounts":[` amounts `]` memo `}`: 43 + ...
fn mt_owner_item(o: &str, ids: &[&str], amounts: &[u128], m: Option<&str>) -> usize {
    43 + o.len() + list(&ids.iter().map(|i| esc(i)).collect::<Vec<_>>())
        + list(&amounts.iter().map(|a| digits(*a)).collect::<Vec<_>>()) + memo_len(m)
}

fn event_logs(r: &near_contract_sim::ReceiptOutcome) -> Vec<&String> {
    r.logs.iter().filter(|l| l.starts_with("EVENT_JSON:")).collect()
}

/// The non-refund receipt that ran `method`.
fn receipt<'a>(o: &'a TxOutcome, method: &str) -> &'a near_contract_sim::ReceiptOutcome {
    o.receipts.iter().find(|r| !r.is_refund() && r.method_names.iter().any(|m| m == method)).unwrap()
}

fn ft_world() -> Sim {
    let (probe, _) = probe_wasm("probe");
    let (ft, _) = probe_wasm("ft");
    let mut fx = Fixture::new();
    for a in [ALICE, BO, LONG, CAROL] {
        fx = fx.account(a, near(100));
    }
    fx.contract(P, probe)
        .contract(FT, ft)
        .init("new").args_json(json!({ "owner_id": ALICE, "total_supply": u128::MAX.to_string() }))
        .ft_register(FT, [BO, LONG, P])
        .token(Token::nep141(FT))
        .build()
}

/// T8, NEP-141. `ft_transfer` and `ft_transfer_call` emit one `ft_transfer`
/// event (core_impl.rs:94-112); the resolver's refund one `ft_transfer`
/// from the receiver with memo "refund" (:204-210); a burn for an
/// unregistered sender the plain log "The account of the sender was
/// deleted" and then an `ft_burn` with memo "refund" (:221-227).
/// `storage_deposit` for a registered account logs "The account is already
/// registered, refunding the deposit" (storage_impl.rs:61), and
/// `storage_unregister` by an unregistered caller "The account <id> is not
/// registered" (:33).
#[test]
fn ft_event_lengths() {
    let mut sim = ft_world();
    let quote = "say \"hi\"\\";
    let long_memo = "m".repeat(500);
    let cases: Vec<(&str, &str, u128, Option<&str>)> = vec![
        (ALICE, BO, 1, None),
        (ALICE, BO, 12_345, Some("")),
        (ALICE, LONG, 10u128.pow(24), Some("a memo")),
        (ALICE, LONG, u128::MAX / 4, Some(quote)),
        (ALICE, BO, 7, Some(long_memo.as_str())),
    ];
    for (from, to, amount, memo) in cases {
        let mut args = json!({ "receiver_id": to, "amount": amount.to_string() });
        if let Some(m) = memo {
            args["memo"] = json!(m);
        }
        let o = sim.call(from, FT, "ft_transfer").args_json(args).deposit(Balance::from_yoctonear(1)).transact();
        o.assert_success();
        let r = receipt(&o, "ft_transfer");
        assert_eq!(r.logs.len(), 1, "{:?}", r.logs);
        let want = ev_len("nep141", "ft_transfer", &[ft_xfer_item(from, to, amount, memo)]);
        println!("ft_transfer {} -> {} ({} -> {} bytes), {} digits, memo {:?} ({:?} bytes escaped): log {} bytes, formula {want}",
                 from, to, from.len(), to.len(), digits(amount), memo.map(|m| m.len()), memo.map(esc), r.logs[0].len());
        assert_eq!(r.logs[0].len(), want, "{}", r.logs[0]);
    }

    // ft_transfer_call: the transfer's event in the call.
    let o = sim
        .call(ALICE, FT, "ft_transfer_call")
        .args_json(json!({ "receiver_id": P, "amount": "99", "memo": "pay", "msg": "keep" }))
        .deposit(Balance::from_yoctonear(1))
        .transact();
    o.assert_success();
    let r = receipt(&o, "ft_transfer_call");
    let want = ev_len("nep141", "ft_transfer", &[ft_xfer_item(ALICE, P, 99, Some("pay"))]);
    println!("ft_transfer_call alice -> p 99 memo pay: logs {:?} bytes, formula {want}", r.logs.iter().map(|l| l.len()).collect::<Vec<_>>());
    assert_eq!(r.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want]);
    assert!(receipt(&o, "ft_resolve_transfer").logs.is_empty(), "nothing refunded, nothing logged");

    // The resolver's refund: bo holds 1 + 12345 + 7; a Failed result refunds 50.
    let resolve = |sim: &mut Sim, sender: &str, receiver: &str, amount: u128| {
        sim.call(ALICE, FT, "ft_resolve_transfer")
            .args_json(json!({ "sender_id": sender, "receiver_id": receiver, "amount": amount.to_string() }))
            .promise_results([PromiseResult::Failed])
            .transact()
    };
    let o = resolve(&mut sim, ALICE, BO, 50);
    let r = o.first_call().unwrap();
    let want = ev_len("nep141", "ft_transfer", &[ft_xfer_item(BO, ALICE, 50, Some("refund"))]);
    println!("ft_resolve_transfer refund bo -> alice 50: logs {:?}, formula {want}", r.logs);
    assert_eq!(r.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want]);

    // The burn: carol is not registered. The probe's own resolver adds a
    // third log ("Account @.. burned .."), not the core's.
    let o = resolve(&mut sim, CAROL, BO, 50);
    let r = o.first_call().unwrap();
    let want = ev_len("nep141", "ft_burn", &[ft_owner_item(BO, 50, Some("refund"))]);
    println!("ft_resolve_transfer burn of bo's 50: logs {:?}, formula {want}", r.logs);
    assert_eq!(r.logs[0], "The account of the sender was deleted");
    assert_eq!(r.logs[0].len(), 37);
    assert_eq!(r.logs[1].len(), want, "{}", r.logs[1]);
    assert_eq!(event_logs(r).len(), 1);

    // NEP-145's plain logs.
    let o = sim.call(CAROL, FT, "storage_deposit").args_json(json!({ "account_id": BO })).deposit(near(1)).transact();
    let r = o.first_call().unwrap();
    println!("storage_deposit for registered bo: logs {:?}", r.logs);
    assert_eq!(r.logs, ["The account is already registered, refunding the deposit"]);
    assert_eq!(r.logs[0].len(), 56);
    let o = sim.call(CAROL, FT, "storage_unregister").args_json(json!({})).deposit(Balance::from_yoctonear(1)).transact();
    let r = o.first_call().unwrap();
    println!("storage_unregister by unregistered carol: logs {:?}", r.logs);
    assert_eq!(r.logs, [format!("The account {CAROL} is not registered")]);
    assert_eq!(r.logs[0].len(), 30 + CAROL.len());
}

/// The `mt` probe deployed without its init, so a test calls `new` itself
/// and sees its `mt_mint` logs.
fn mt_bare() -> Sim {
    let (mt, _) = probe_wasm("mt");
    let (rx, _) = probe_wasm("mtrecv");
    Fixture::new()
        .account(ALICE, near(100))
        .account(BO, near(100))
        .account(LONG, near(100))
        .contract(MT, mt)
        .contract(RX, rx)
        .build()
}

/// T8, NEP-245. `mint` emits one `mt_mint` per call (core :824-845; the
/// probe's `new` mints each id alone); `transfer` one `mt_transfer` listing
/// the entries of nonzero amount, in order, a repeated id once per entry,
/// with the call's memo, and none when every amount is 0 (:791-822); the
/// resolver's refunds are one `mt_transfer` from the receiver back to the
/// sender, without memo, listing the ids it refunds (:580-599).
#[test]
fn mt_event_lengths() {
    let mut sim = mt_bare();
    let ids = ["t1", "a-longer-token-id:0042", "x", "q\"u"];
    let supply: u128 = 10u128.pow(30);
    let o = sim
        .call(ALICE, MT, "new")
        .args_json(json!({ "owner_id": ALICE, "token_ids": ids, "supply": supply.to_string() }))
        .transact();
    o.assert_success();
    let r = o.first_call().unwrap();
    let lens: Vec<usize> = r.logs.iter().map(|l| l.len()).collect();
    let want: Vec<usize> = ids.iter().map(|i| ev_len("nep245", "mt_mint", &[mt_owner_item(ALICE, &[i], &[supply], None)])).collect();
    println!("new mints {ids:?} at {supply}: logs {lens:?}, formula {want:?}");
    assert_eq!(lens, want);

    let batch = |sim: &mut Sim, from: &str, to: &str, ids: &[&str], amounts: &[u128], memo: Option<&str>| {
        let mut args = json!({ "receiver_id": to, "token_ids": ids, "amounts": amounts.iter().map(|a| a.to_string()).collect::<Vec<_>>() });
        if let Some(m) = memo {
            args["memo"] = json!(m);
        }
        sim.call(from, MT, "mt_batch_transfer").args_json(args).deposit(Balance::from_yoctonear(1)).transact()
    };
    let cases: Vec<(&str, Vec<&str>, Vec<u128>, Option<&str>)> = vec![
        (BO, vec!["t1"], vec![5], None),
        (LONG, vec!["t1", "a-longer-token-id:0042"], vec![1, 10u128.pow(24)], Some("batch")),
        (BO, vec!["x", "x", "q\"u"], vec![3, 30, 300], Some("a \"quoted\" memo")),
        (BO, vec!["t1", "x", "t1"], vec![0, 7, 0], None),
    ];
    for (to, ids, amounts, memo) in cases {
        let o = batch(&mut sim, ALICE, to, &ids, &amounts, memo);
        o.assert_success();
        let r = o.first_call().unwrap();
        let (nz_ids, nz_amts): (Vec<&str>, Vec<u128>) = ids.iter().zip(&amounts).filter(|(_, a)| **a != 0).map(|(i, a)| (*i, *a)).unzip();
        let want = ev_len("nep245", "mt_transfer", &[mt_xfer_item(ALICE, to, &nz_ids, &nz_amts, memo)]);
        println!("mt_batch_transfer alice -> {to} {ids:?} {amounts:?} memo {memo:?}: logs {:?}, formula {want}",
                 r.logs.iter().map(|l| l.len()).collect::<Vec<_>>());
        assert_eq!(r.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want]);
    }
    // Every amount 0: no event.
    let o = batch(&mut sim, ALICE, BO, &["t1", "x"], &[0, 0], Some("nothing"));
    o.assert_success();
    println!("mt_batch_transfer of zeros: logs {:?}", o.first_call().unwrap().logs);
    assert!(o.first_call().unwrap().logs.is_empty());
    // mt_transfer: the same event, one id.
    let o = sim
        .call(ALICE, MT, "mt_transfer")
        .args_json(json!({ "receiver_id": LONG, "token_id": "a-longer-token-id:0042", "amount": "123456789", "memo": "single" }))
        .deposit(Balance::from_yoctonear(1))
        .transact();
    o.assert_success();
    let want = ev_len("nep245", "mt_transfer", &[mt_xfer_item(ALICE, LONG, &["a-longer-token-id:0042"], &[123_456_789], Some("single"))]);
    println!("mt_transfer: logs {:?}, formula {want}", o.first_call().unwrap().logs.iter().map(|l| l.len()).collect::<Vec<_>>());
    assert_eq!(o.first_call().unwrap().logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want]);

    // mt_batch_transfer_call, the receiver answering [3, 25] (unused) for
    // t1:10, x:20: the call's event lists both, the resolver's refund event
    // t1:3 and x:20 (unused capped at the amount).
    let o = sim
        .call(ALICE, MT, "mt_batch_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_ids": ["t1", "x"], "amounts": ["10", "20"], "memo": "m", "msg": "vec:3,25" }))
        .deposit(Balance::from_yoctonear(1))
        .transact();
    o.assert_success();
    let call = receipt(&o, "mt_batch_transfer_call");
    let res = receipt(&o, "mt_resolve_transfer");
    let want_call = ev_len("nep245", "mt_transfer", &[mt_xfer_item(ALICE, RX, &["t1", "x"], &[10, 20], Some("m"))]);
    let want_res = ev_len("nep245", "mt_transfer", &[mt_xfer_item(RX, ALICE, &["t1", "x"], &[3, 20], None)]);
    println!("mt_batch_transfer_call t1:10, x:20, answer [3, 25]: call logs {:?} (formula {want_call}), resolver logs {:?} (formula {want_res})",
             call.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), res.logs.iter().map(|l| l.len()).collect::<Vec<_>>());
    assert_eq!(call.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want_call]);
    assert_eq!(res.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want_res]);
    // Answer [10, 0]: t1 refunded alone.
    let o = sim
        .call(ALICE, MT, "mt_batch_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_ids": ["t1", "x"], "amounts": ["10", "20"], "msg": "vec:10,0" }))
        .deposit(Balance::from_yoctonear(1))
        .transact();
    o.assert_success();
    let res = receipt(&o, "mt_resolve_transfer");
    let want_res = ev_len("nep245", "mt_transfer", &[mt_xfer_item(RX, ALICE, &["t1"], &[10], None)]);
    println!("answer [10, 0]: resolver logs {:?} (formula {want_res})", res.logs.iter().map(|l| l.len()).collect::<Vec<_>>());
    assert_eq!(res.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [want_res]);
    // Answer "keep": nothing refunded, no resolver log.
    let o = sim
        .call(ALICE, MT, "mt_batch_transfer_call")
        .args_json(json!({ "receiver_id": RX, "token_ids": ["t1", "x"], "amounts": ["1", "2"], "msg": "keep" }))
        .deposit(Balance::from_yoctonear(1))
        .transact();
    o.assert_success();
    assert!(receipt(&o, "mt_resolve_transfer").logs.is_empty());
}

/// T8 and R6 together: a batch whose one event grows with its entries. A
/// batch of k entries of one 64-byte id (amounts of 30 digits) logs one
/// `mt_transfer` of `ev_len` bytes; the first k whose event is over 16384
/// bytes fails the call with `TotalLogLengthExceeded`, and nothing moves.
#[test]
fn mt_event_crosses_log_limit() {
    let mut base = mt_bare();
    let id = format!("token-{}", "0".repeat(58));
    let supply: u128 = 10u128.pow(36);
    base.call(ALICE, MT, "new")
        .args_json(json!({ "owner_id": ALICE, "token_ids": [id.as_str()], "supply": supply.to_string() }))
        .transact()
        .assert_success();
    let amount: u128 = 10u128.pow(29) + 1;
    let bytes = |k: usize| ev_len("nep245", "mt_transfer", &[mt_xfer_item(ALICE, BO, &vec![id.as_str(); k], &vec![amount; k], None)]);
    let edge = (1..2000).find(|&k| bytes(k) > 16384).unwrap();
    println!("entries of a {}-byte id at {} digits: {} bytes per entry; k = {} logs {} bytes, k = {edge} {} bytes",
             id.len(), digits(amount), bytes(2) - bytes(1), edge - 1, bytes(edge - 1), bytes(edge));
    for k in [edge - 1, edge] {
        let mut sim = base.clone();
        let o = sim
            .call(ALICE, MT, "mt_batch_transfer")
            .args_json(json!({ "receiver_id": BO, "token_ids": vec![id.as_str(); k], "amounts": vec![amount.to_string(); k] }))
            .deposit(Balance::from_yoctonear(1))
            .gas(Gas::from_teragas(300))
            .transact();
        let r = o.first_call().unwrap();
        let held: String = sim.view(MT, "mt_balance_of", json!({ "account_id": BO, "token_id": id })).json();
        println!("k = {k}: {:?}; logs {:?}; bo holds {held}", o.failure(), r.logs.iter().map(|l| l.len()).collect::<Vec<_>>());
        if k < edge {
            o.assert_success();
            assert_eq!(r.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [bytes(k)]);
            assert_eq!(held, (amount * k as u128).to_string());
        } else {
            let e = format!("{:?}", o.failure());
            assert!(e.contains(&format!("The length of a log message {} exceeds the limit 16384", bytes(k))), "{e}");
            assert!(r.logs.is_empty());
            assert_eq!(held, "0", "nothing moved");
        }
    }
}

/// T8, the two events no probe emits (the `ft` probe mints nothing after its
/// init, which mints without an event, and the `mt` probe burns nothing):
/// `ft_mint` and `mt_burn`, checked against the crates' own test strings
/// (near-contract-standards 5.29.1 `src/fungible_token/events.rs:137`,
/// `:156`; near-sdk-contract-tools 4.0.0 `src/standard/nep245/event.rs:168`),
/// the `mt_burn` one with its owner and token ids replaced by generic ids of
/// the same lengths (15, 6 and 16 bytes). Their items have the shapes of
/// `ft_burn` and `mt_mint`, which the sim tests above cover. No sim.
#[test]
fn mint_and_burn_fixtures() {
    let ft_mint = r#"EVENT_JSON:{"standard":"nep141","version":"1.0.0","event":"ft_mint","data":[{"owner_id":"bob","amount":"100"}]}"#;
    assert_eq!(ft_mint.len(), ev_len("nep141", "ft_mint", &[ft_owner_item("bob", 100, None)]));
    let ft_mints = r#"EVENT_JSON:{"standard":"nep141","version":"1.0.0","event":"ft_mint","data":[{"owner_id":"bob","amount":"100"},{"owner_id":"alice","amount":"200","memo":"has memo"}]}"#;
    assert_eq!(ft_mints.len(), ev_len("nep141", "ft_mint", &[ft_owner_item("bob", 100, None), ft_owner_item("alice", 200, Some("has memo"))]));
    let mt_burn = r#"EVENT_JSON:{"standard":"nep245","version":"1.0.0","event":"mt_burn","data":[{"owner_id":"holder-one.near","token_ids":["tok-aa","token-sixteen-bb"],"amounts":["1","100"]}]}"#;
    assert_eq!(mt_burn.len(), ev_len("nep245", "mt_burn", &[mt_owner_item("holder-one.near", &["tok-aa", "token-sixteen-bb"], &[1, 100], None)]));
    println!("ft_mint {} bytes, two ft_mints {} bytes, mt_burn {} bytes", ft_mint.len(), ft_mints.len(), mt_burn.len());
}
