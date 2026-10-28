//! Protocol limits (docs/SEMANTICS.md, R6), observed in the sim at the
//! boundary, each the last value nearcore accepts and the first it refuses:
//! actions per receipt, for a transaction and for a receipt a contract
//! creates; promises per function-call action; the method-name bytes of a
//! function-call AddKey; logs per function-call action. The other limits the model encodes have their
//! boundary tests elsewhere: 128 joint inputs (`receipts.rs`,
//! `joint_promise_input_limit`), 4 MiB of returned data (`receipts.rs`,
//! `result_size_limit_and_per_receiver_fee`), 10 deploys per receipt
//! (`lifecycle.rs`, `deploy_storage_delta`). Each test prints what it
//! observed; `cargo test --test limits -- --nocapture` shows it.
//!
//! nearcore references are at the pinned rev bc4e9e8 (README, "Pins"); the
//! values are protocol 88's
//! (core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:241-256).
//! The batches run on the committed `probe` wasm; the promise count needs
//! a contract that creates promises with no actions (a function-call
//! child costs about 1.2 Tgas, so 1025 of them do not fit in 1 PGas), the
//! WAT module `MANY` below, which also writes logs of a chosen count.
use near_contract_sim::prelude::*;
use near_contract_sim::{AccessKey, AccessKeyPermission, ActionErrorKind, FunctionCallPermission, InvalidTxError, ReceiptOutcome};
use near_tla_conformance::probe_wasm;
use serde_json::json;

const ALICE: &str = "alice.near";
const BOB: &str = "bob.near";
const P: &str = "p-probe.near";
const Q: &str = "q-probe.near";
const W: &str = "w-many.near";

/// `many`: creates as many promises as its input has bytes, each
/// `promise_batch_create("bob.near")` with no action (an empty action
/// receipt to bob, 216 Ggas of receipt creation fees). `logs` and
/// `log_split` write logs of a chosen count and total length.
const MANY: &str = r#"
(module
  (import "env" "input" (func $input (param i64)))
  (import "env" "register_len" (func $register_len (param i64) (result i64)))
  (import "env" "promise_batch_create" (func $create (param i64 i64) (result i64)))
  (import "env" "read_register" (func $read_register (param i64 i64)))
  (import "env" "log_utf8" (func $log (param i64 i64)))
  (memory 1)
  (export "memory" (memory 0))
  (data (i32.const 0) "bob.near")
  ;; `logs`: as many one-byte logs ("b") as the input has bytes.
  (func (export "logs")
    (local $n i64) (local $i i64)
    (call $input (i64.const 0))
    (local.set $n (call $register_len (i64.const 0)))
    (block $done (loop $next
      (br_if $done (i64.ge_u (local.get $i) (local.get $n)))
      (call $log (i64.const 1) (i64.const 0))
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br $next))))
  ;; `log_split`: the input, read to offset 1024, logged as two logs, its
  ;; first half and the rest.
  (func (export "log_split")
    (local $n i64) (local $h i64)
    (call $input (i64.const 0))
    (local.set $n (call $register_len (i64.const 0)))
    (call $read_register (i64.const 0) (i64.const 1024))
    (local.set $h (i64.div_u (local.get $n) (i64.const 2)))
    (call $log (local.get $h) (i64.const 1024))
    (call $log (i64.sub (local.get $n) (local.get $h)) (i64.add (i64.const 1024) (local.get $h))))
  (func (export "many")
    (local $n i64) (local $i i64)
    (call $input (i64.const 0))
    (local.set $n (call $register_len (i64.const 0)))
    (block $done (loop $next
      (br_if $done (i64.ge_u (local.get $i) (local.get $n)))
      (drop (call $create (i64.const 8) (i64.const 0)))
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br $next)))))
"#;

fn near(n: u128) -> Balance {
    Balance::from_near(n)
}

fn err(o: &TxOutcome) -> String {
    format!("{:?}", o.failure())
}

fn rerr(r: &ReceiptOutcome) -> String {
    format!("{:?}", r.failure())
}

fn world() -> Sim {
    let (wasm, _) = probe_wasm("probe");
    Fixture::new()
        .account(ALICE, near(1000))
        .account(BOB, near(100))
        .contract(P, wasm.clone())
        .contract(Q, wasm)
        .contract(W, wat::parse_str(MANY).unwrap())
        .build()
}

/// 100 actions per receipt (`max_actions_per_receipt`,
/// runtime/runtime/src/action_validation.rs:104-109). A transaction with
/// more is invalid at conversion (runtime/runtime/src/verifier.rs:92-104,
/// InvalidTx ActionsValidation TotalNumberOfActionsExceeded): no receipt, no
/// charge. A receipt a contract creates with more fails its creator after
/// the call has run (runtime/runtime/src/lib.rs:968-979, ActionError
/// NewReceiptValidationError), which then creates nothing; the host
/// function does not check it. p's `batch` puts every call in one receipt.
#[test]
fn actions_per_receipt() {
    let base = world();
    let lim = base.config.runtime_config().wasm_config.limit_config.max_actions_per_receipt;
    assert_eq!(lim, 100);
    for n in [lim, lim + 1] {
        let mut sim = base.clone();
        let before = sim.balance(ALICE);
        let o = (0..n).fold(sim.tx(ALICE, BOB), |t, _| t.transfer(Balance::from_yoctonear(1))).transact();
        println!("a transaction of {n} Transfers: {}; {} receipts", err(&o), o.receipts.len());
        if n == lim {
            o.assert_success();
        } else {
            assert!(matches!(o.failure(), Some(Failure::InvalidTx(InvalidTxError::ActionsValidation(_)))), "{o}");
            assert!(err(&o).contains("TotalNumberOfActionsExceeded"), "{o}");
            assert!(o.receipts.is_empty(), "nothing runs");
            assert_eq!(sim.balance(ALICE), before, "nothing charged");
        }
    }
    for n in [lim, lim + 1] {
        let mut sim = base.clone();
        let calls: Vec<_> = (0..n).map(|_| json!({ "method": "burn", "args": "{\"ggas\":0}", "static_ggas": 0, "weight": 1 })).collect();
        let o = sim.call(ALICE, P, "batch").args_json(json!({ "receiver": Q, "calls": calls })).transact();
        let first = o.first_call().unwrap();
        let kids: Vec<_> = o.receipts.iter().filter(|r| r.executor_id.as_str() == Q).map(|r| r.actions.len()).collect();
        println!("p creates one receipt of {n} calls: p {}; receipts on q with {kids:?} actions", rerr(first));
        if n == lim {
            assert!(first.is_success(), "{o}");
            assert_eq!(kids, [lim as usize]);
        } else {
            assert!(matches!(first.failure(), Some(Failure::Action(ActionErrorKind::NewReceiptValidationError(_)))), "{o}");
            assert!(rerr(first).contains("TotalNumberOfActionsExceeded"), "{}", rerr(first));
            assert!(kids.is_empty(), "the failed creator made no receipt");
        }
    }
}

/// 1024 promises per function-call action
/// (`max_promises_per_function_call_action`; runtime/near-vm-runner/src/logic/host.rs:610-622
/// `checked_push_promise`, which every host function that makes a promise
/// calls: :2534 `promise_and`, :2581 `promise_batch_create`, :2645
/// `promise_batch_then`, :4297, :4407 the yields). The 1025th fails the call
/// there (HostError NumberPromisesExceeded), as a panic would, and the call
/// creates nothing. The count is per function-call action, not per receipt:
/// each action runs the VM afresh, with its own promise list
/// (runtime/runtime/src/function_call.rs:76, :281; runtime/near-vm-runner/src/logic/host.rs:96).
/// A receipt of two `many` calls, 600 promises each, succeeds; 1024 then
/// 1025 fails the receipt, and the first call's 1024 receipts are not sent
/// either.
#[test]
fn promises_per_function_call_action() {
    let base = world();
    let lim = base.config.runtime_config().wasm_config.limit_config.max_promises_per_function_call_action;
    assert_eq!(lim, 1024);
    for n in [lim, lim + 1] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, W).call("many").args(vec![b'x'; n as usize]).transact();
        let first = o.first_call().unwrap();
        let kids = o.receipts.iter().filter(|r| r.executor_id.as_str() == BOB && r.actions.is_empty()).count();
        println!("w makes {n} promises: {}, {} gas burnt; {kids} empty receipts ran on bob", rerr(first), first.gas_burnt);
        if n == lim {
            assert!(first.is_success(), "{o}");
            assert_eq!(kids, lim as usize);
        } else {
            assert!(rerr(first).contains("The number of promises within a FunctionCall 1025 exceeds the limit 1024"), "{}", rerr(first));
            assert_eq!(kids, 0, "the failed call created nothing");
        }
    }
    for (a, b) in [(600, 600), (lim, lim + 1)] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, W).call("many").args(vec![b'x'; a as usize]).call("many").args(vec![b'x'; b as usize]).transact();
        let first = o.first_call().unwrap();
        assert_eq!(first.actions.len(), 2, "one receipt of two function calls");
        let kids = o.receipts.iter().filter(|r| r.executor_id.as_str() == BOB && r.actions.is_empty()).count();
        println!("w makes {a} then {b} promises in one receipt: {}; {kids} empty receipts ran on bob", rerr(first));
        if b <= lim {
            assert!(first.is_success(), "{o}");
            assert_eq!(kids, (a + b) as usize, "more than 1024 in the receipt, at most 1024 per call");
        } else {
            assert!(rerr(first).contains("The number of promises within a FunctionCall 1025 exceeds the limit 1024"), "{}", rerr(first));
            assert_eq!(kids, 0, "the failed receipt sent nothing, the first call's receipts included");
        }
    }
}

/// A function-call AddKey's method names may total 2000 bytes, each name
/// counting its length + 1 (`max_number_bytes_method_names`;
/// runtime/runtime/src/action_validation.rs:456-474, AddKeyMethodNamesNumberOfBytesExceeded),
/// the same count as the AddKey per-byte fee (NearKeys `MethodBytes`). In a
/// transaction it is invalid at conversion; in a receipt a contract creates
/// it fails the creator (lib.rs:968-979), as for the action count.
#[test]
fn add_key_method_name_bytes() {
    let base = world();
    let lim = base.config.runtime_config().wasm_config.limit_config.max_number_bytes_method_names;
    assert_eq!(lim, 2000);
    // Eight names of 249 bytes: 8 x 250 = 2000; one byte more on the last.
    for extra in [0usize, 1] {
        let mut sim = base.clone();
        let names: Vec<String> = (0..8).map(|i| format!("{i}{}", "x".repeat(248 + if i == 7 { extra } else { 0 }))).collect();
        let bytes: usize = names.iter().map(|m| m.len() + 1).sum();
        let key = AccessKey {
            nonce: 0,
            permission: AccessKeyPermission::FunctionCall(FunctionCallPermission { allowance: None, receiver_id: P.into(), method_names: names }),
        };
        let pk = SecretKey::from_seed(KeyType::ED25519, "names").public_key();
        let o = sim.tx(ALICE, ALICE).add_key(pk.clone(), key).transact();
        println!("AddKey with {bytes} bytes of method names: {}", err(&o));
        if bytes as u64 <= lim {
            o.assert_success();
            assert!(sim.access_key(ALICE, &pk).is_some());
        } else {
            assert!(matches!(o.failure(), Some(Failure::InvalidTx(InvalidTxError::ActionsValidation(_)))), "{o}");
            assert!(err(&o).contains("AddKeyMethodNamesNumberOfBytesExceeded"), "{o}");
            assert!(sim.access_key(ALICE, &pk).is_none());
        }
    }
}

/// Logs, per function-call action: at most 100 (`max_number_logs`,
/// runtime/near-vm-runner/src/logic/logic.rs:81-88, checked before each log
/// by `log_utf8` / `log_utf16`, host.rs:4792-4800, :4816-4825) and 16384
/// bytes in all (`max_total_log_length`; a message longer than what is left
/// fails as it is read, host.rs:486-512, and `checked_push_log` checks the
/// total, logic.rs:90-101). Either fails the call as a panic would
/// (HostError NumberOfLogsExceeded, TotalLogLengthExceeded). The single log
/// is the `probe`'s `record`, which logs "record " and the JSON it returns,
/// so its length is set by the tag; `w`'s `log_split` writes two logs and
/// `logs` one-byte logs. Both limits are per function-call action, not per
/// receipt (each action runs the VM afresh, runtime/runtime/src/function_call.rs:76,
/// :281, with no logs yet, runtime/near-vm-runner/src/logic/logic.rs:45-54):
/// a receipt of two calls may log 120 logs, or 18000 bytes, in all, and
/// fails only when one call goes over.
#[test]
fn logs_per_function_call_action() {
    let base = world();
    let lc = &base.config.runtime_config().wasm_config.limit_config;
    let (max_logs, max_len) = (lc.max_number_logs, lc.max_total_log_length);
    assert_eq!((max_logs, max_len), (100, 16384));
    let record = |sim: &mut Sim, tag: &str| sim.call(ALICE, P, "record").args_json(json!({ "tag": tag })).transact();

    // One log: "record " + the returned JSON, 7 + len(JSON) bytes.
    let o = record(&mut base.clone(), "");
    o.assert_success();
    let fixed = 7 + o.json::<String>().len();
    for len in [max_len as usize, max_len as usize + 1] {
        let mut sim = base.clone();
        let o = record(&mut sim, &"a".repeat(len - fixed));
        let first = o.first_call().unwrap();
        let logged: usize = first.logs.iter().map(|l| l.len()).sum();
        println!("p.record logging {len} bytes: {}; {} log(s), {logged} bytes", rerr(first), first.logs.len());
        if len as u64 <= max_len {
            assert!(first.is_success(), "{o}");
            assert_eq!(logged, len);
        } else {
            assert!(rerr(first).contains(&format!("The length of a log message {len} exceeds the limit {max_len}")), "{}", rerr(first));
        }
    }

    // Two logs that together reach the total.
    for len in [max_len as usize, max_len as usize + 1] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, W).call("log_split").args(vec![b'c'; len]).transact();
        let first = o.first_call().unwrap();
        println!("w.log_split of {len} bytes: {}; logs {:?}", rerr(first), first.logs.iter().map(|l| l.len()).collect::<Vec<_>>());
        if len as u64 <= max_len {
            assert!(first.is_success(), "{o}");
            assert_eq!(first.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [len / 2, len - len / 2]);
        } else {
            assert!(rerr(first).contains(&format!("The length of a log message {len} exceeds the limit {max_len}")), "{}", rerr(first));
            assert_eq!(first.logs.iter().map(|l| l.len()).collect::<Vec<_>>(), [len / 2], "the failed call keeps its first log");
        }
    }

    // The count.
    for n in [max_logs, max_logs + 1] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, W).call("logs").args(vec![b'x'; n as usize]).transact();
        let first = o.first_call().unwrap();
        println!("w writes {n} logs: {}; {} logs", rerr(first), first.logs.len());
        if n == max_logs {
            assert!(first.is_success(), "{o}");
            assert_eq!(first.logs.len(), n as usize);
        } else {
            assert!(rerr(first).contains(&format!("The number of logs will exceed the limit {max_logs}")), "{}", rerr(first));
            assert_eq!(first.logs.len(), max_logs as usize, "the failed call keeps the logs it wrote");
        }
    }

    // Per action: one receipt of two `logs` calls, then of two `log_split` calls.
    for (a, b) in [(60, 60), (max_logs, max_logs + 1)] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, W).call("logs").args(vec![b'x'; a as usize]).call("logs").args(vec![b'x'; b as usize]).transact();
        let first = o.first_call().unwrap();
        assert_eq!(first.actions.len(), 2, "one receipt of two function calls");
        println!("w writes {a} then {b} logs in one receipt: {}; {} logs", rerr(first), first.logs.len());
        if b <= max_logs {
            assert!(first.is_success(), "{o}");
            assert_eq!(first.logs.len(), (a + b) as usize, "more than 100 in the receipt, at most 100 per call");
        } else {
            assert!(rerr(first).contains(&format!("The number of logs will exceed the limit {max_logs}")), "{}", rerr(first));
            assert_eq!(first.logs.len(), (a + max_logs) as usize, "the failed receipt keeps the first call's logs and the second's 100");
        }
    }
    for (a, b) in [(9000usize, 9000usize), (max_len as usize, max_len as usize + 1)] {
        let mut sim = base.clone();
        let o = sim.tx(ALICE, W).call("log_split").args(vec![b'c'; a]).call("log_split").args(vec![b'c'; b]).transact();
        let first = o.first_call().unwrap();
        assert_eq!(first.actions.len(), 2, "one receipt of two function calls");
        let logged: usize = first.logs.iter().map(|l| l.len()).sum();
        println!("w.log_split of {a} then {b} bytes in one receipt: {}; {} logs, {logged} bytes", rerr(first), first.logs.len());
        if b as u64 <= max_len {
            assert!(first.is_success(), "{o}");
            assert_eq!(logged, a + b, "more than 16384 bytes in the receipt, at most 16384 per call");
        } else {
            assert!(rerr(first).contains(&format!("The length of a log message {b} exceeds the limit {max_len}")), "{}", rerr(first));
            assert_eq!(
                first.logs.iter().map(|l| l.len()).collect::<Vec<_>>(),
                [a / 2, a - a / 2, b / 2],
                "the failed receipt keeps the first call's two logs and the second's first"
            );
        }
    }
}
