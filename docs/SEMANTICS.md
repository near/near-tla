# Semantics and trust

This page lists every runtime rule the library models. For each rule it gives the nearcore code
the rule comes from, the model operator that encodes it, and how far the rule has been checked.
After that comes everything the library does **not** model, and what each omission could hide.

## Reference revision

- **nearcore:** 2.14.0-rc.5, commit `b7b4737cab46f17a6daa2ed694d7aebbd204363a`. This is the
  revision near-contract-sim pins. Every `path:line` below is at this revision.
- **Protocol version:** 88, unless a rule says otherwise. 88 is `STABLE_PROTOCOL_VERSION`
  (`core/primitives-core/src/version.rs:694` @ b7b4737), the version a non-nightly rc.5 binary
  and the sim run. Mainnet ran 86 as of 2026-10-23. At 86 the fee table is the same as 85's,
  because there is no `86.yaml` (`core/parameters/src/config_store.rs:238-246` @ b7b4737).
  The rule changes between 84 and 88 are noted where they matter. `NearFees.FeeProtocol`
  selects fees only; the behaviour encoded in `NearAsync`/`NearKeys` is protocol 88's (see
  `docs/VERSIONING.md`). The one behaviour switch for those versions, `UniversalOn` (A2), is
  separate from `FeeProtocol`.
- **Token standards:** the NEP texts at `neps/nep-0141.md`, `nep-0145.md` and `nep-0245.md` in
  the NEPs repo, and near-contract-standards. The locally available versions of
  near-contract-standards are 5.23.0, 5.24.0, 5.25.0, 5.28.1, 5.29.0 and 5.29.1. See
  [Tokens](#tokens) for which behaviour the defaults encode.

## How to read the entries

Each rule has four fields:

- **Rule:** the behaviour, in one or two sentences.
- **nearcore:** where it lives. The rev is always b7b4737, and paths are relative to the
  nearcore root.
- **Model:** the operator or constant that encodes it, in `modules/NearAsync.tla` unless another
  module is named. The names are the current code's.
- **Validated:** one of these levels:
  - **sim** means a per-receipt conformance run in this repo (`conformance/`, see
    [`CONFORMANCE.md`](CONFORMANCE.md)) agreed with the model. Rules the conformance flows were
    written to cover carry the marker `<!-- conformance -->` in the source of this page, and
    each such entry says what the sim checked, if anything. The run on the current library
    (74 flows, 97,162 prepaid points, 227,922 sim receipts; and the flow set `probes2`, 28 flows,
    36,764 points, 122,825 receipts) found no status, window-edge, attached-gas or deposit
    mismatch ([results](../conformance/README.md#results-at-the-pins)). The comparison sees
    each receipt's status and attached gas (in `probes2` its deposit too), by transaction, the
    yields still parked at the end, and the window edges, but not the order in which receipts
    run; the calibration checks the leftover split and the action-only fees. A rule is "sim"
    where a flow exercises it and that comparison would show a difference. Where a flow covers
    only part of a rule, the entry says which part; the rest keeps its earlier level.

    "sim" also covers a named test in `conformance/tests/` that runs the rule's case in the
    sim and asserts what nearcore did, with no model run ("sim (`conformance/tests/<file>.rs`,
    `<test>`)"). Such a test checks nearcore against the rule as written here, not the
    model's encoding of it; `examples/platform-selftest` checks the encoding. These tests run
    on the committed probe wasms and print what they observed (`--nocapture`).
  - **nearcore reading** means the rule was read in the nearcore source at b7b4737 and not
    exercised here.
  - **recalled** means it was neither read nor run. Treat it as an assumption.

## Units

- **Gas** is in **Ggas** (1 Tgas = 1000 Ggas). The fee table is `modules/NearFees.tla`. It
  rounds each entry **up** to a whole Ggas by default (`FeeRounding`; `"nearest"` restores the
  earlier rounding); the error bounds are under [N-precision](#under-approximations-unsound-they-can-hide-bugs).
- **Sizes have two units. Convert explicitly.**
  - `NearAsync` sizes (`r.res.sz`, `RValSz(v, n)`, `OSz(O, n)`, `DataOfSz`, and the burn size
    in `GasBurn[k].per * O.sz`) are in **KB, rounded up**, with **1 KB = 1000 bytes**. That
    matches the `NearFees` scaling and the calibrated tables, whose per-size slopes are per
    1000 bytes (`conformance/README.md`, "Units in the model").
  - `NearFees` per-byte operators (`DataBytesFee`, `FunctionCallBytesFee`, `AddKeyFcBytesFee`,
    `DeployBytesFee` and their send/exec parts) take **bytes**.
  - Bytes to model size: `sz = (n + 999) \div 1000`. Model size to bytes for a fee:
    `NearFeeTable!DataBytesFee(sir, 1000 * r.res.sz)`. This overstates the bytes by up to 999, so it
    overstates the fee by up to about 65 Ggas per waiting receiver (cross-shard rate) or 34 Ggas
    (same account).
- **Storage** (with `StoragePerByte`, B2) is in **bytes**: `stor`, `StorageInit`, `OStor`,
  `KeyBytes`, `TokRegBytes`. `StorageByteCost = <<num, den>>` prices a byte at `num/den` of the
  model's NEAR unit; nearcore's 1e19 yocto per byte is `<<1, 100000>>` when 1 unit = 1 NEAR.

---

## Receipts

### R1. Action receipts and data receipts

- **Rule:** Work moves between accounts as receipts. An *action receipt* carries a list of
  actions plus the signer, the signer's public key, an optional `refund_to`, the gas price,
  `input_data_ids` (the results it waits for) and `output_data_receivers` (who gets its result).
  A *data receipt* carries one promise result (`data: Option<Vec<u8>>`) to one waiting receipt.
- **nearcore:** `core/primitives/src/receipt.rs:566-574` (`ReceiptEnum`), `:622-641`
  (`ActionReceiptV2` fields); dispatch in `runtime/runtime/src/lib.rs:1421-1560`
  (`process_receipt`).
- **Model:** the `Rcpt(...)` record (transaction `tx`, receiver `to`, predecessor `fr`, method
  `m`, arguments `a`, deposit `dep`, refund target `rto`, callback link `cb`, gas fields
  `gs`/`gw`/`gf`/`g`, and `loc` for a local receipt, set by `SubmitAs`). Data results arrive
  in the callback's `r.res` (`DataOf`, `DataOfSz`).
- **Validated:** a data receipt carrying one result to the receipt waiting on it: sim
  (`conformance/tests/receipts.rs`, `data_receipt_carries_one_result`: a callback reads a
  result of the size its input returned, and a joint callback of two inputs one result per
  input, each at its input's index, in both orders). The contents are not compared: the
  probes report sizes. The action
  receipt's other fields: nearcore reading (the signer and its key: K1).

### R2. A data receipt may arrive before or after the receipt that waits on it

- **Rule:** A receipt that waits on results runs only once every input has arrived. If data
  arrives first, it is stored. If the receipt arrives first, it is postponed and counts its
  missing inputs, and the last arriving input triggers execution.
- **nearcore:** `runtime/runtime/src/lib.rs:1647-1715` (`process_action_receipt`: postpone and
  count), `:1440-1528` (data arrival: store, decrement the count, and execute at zero).
- **Model:** `Runnable`: a callback is runnable only once its result is present.
- **Validated:** sim (`conformance/tests/receipts.rs`, `callback_waits_for_its_data_either_order`:
  with its input's result held back, the callback is postponed and runs once the data
  arrives; with the callback held back, the data waits and the callback runs when it
  arrives, and reads it). The sim's `Fault::HoldResult` and `Fault::Hold` delay a receipt as
  a full outgoing buffer would.

### R3. One atomic step per receipt

- **Rule:** Each action receipt executes as one step: all its actions, then a single commit or
  rollback of its state changes, then its outgoing receipts (children, data, refunds). No other
  receipt's effects interleave inside it.
- **nearcore:** `runtime/runtime/src/lib.rs:827-1274` (`apply_action_receipt`): state
  committed before start `:903-905`, the actions loop `:946-1005`, then commit `:1079-1083` or
  rollback `:1084-1087`.
- **Model:** `Exec(r, O)`, which takes the `Verdict` and dispatches to `Commit`, `FailOOG` or
  `FailP`, or for `"either"` (a child's gas may be 0 or not, G3) to both `Commit` and `FailP`.
  The contract conjoins its own state update after it, guarded by `Ok(r, O)`, which for
  `"either"` reads which of the two the step took.
- **Validated:** the single commit or rollback: sim (`conformance/tests/receipts.rs`,
  `failed_receipt_reverts_and_drops_children`: a `[put, chain, record, fail]` receipt that
  panics in its last action keeps no write and sends no child). That no other receipt's
  effects interleave: nearcore reading. <!-- conformance --> The comparison checked each
  receipt's verdict (ok, out of gas, failed) on every flow, but it does not see state or
  interleaving, so the atomicity itself is not checked there.

### R4. Revert scope: only the failing receipt

- **Rule:** When a receipt fails, nearcore rolls back that receipt's state changes and drops
  the receipts it would have created. It also drops its validator proposals and burnt or
  subsidised amounts, but keeps gas burnt and logs. Receipts that already committed, earlier in
  the same transaction, stay committed. Nothing is "transaction-atomic".
- **nearcore:** `runtime/runtime/src/lib.rs:535-541` (`ActionResult::set_error` clears
  `new_receipts`, `validator_proposals`, `tokens_burnt` and `subsidized_amount`), `:525`
  (`merge` routes an error to `set_error`), `:1084-1087` (rollback); in function calls,
  children exist only if the VM did not abort (`runtime/runtime/src/function_call.rs:100-138`
  sets the error, `:151-227` builds children only when `execution_succeeded`).
- **Model:** `FailP` / `FailOOG` create no children; the contract keeps its own variables
  unchanged when `~Ok(r, O)`.
- **Validated:** a failed receipt creates none of its children: sim (the `chain*`, `ret*`
  and `send_*_cb` flows below their window edge, e.g. `chain1` below 12.9 Tgas; `chain_s0`).
  The state rollback, the logs and burnt gas that stay, and the survival of earlier
  receipts' effects: sim (`conformance/tests/receipts.rs`,
  `failed_receipt_reverts_and_drops_children`: the failing receipt's writes roll back, its
  log stays; a committed `q.put` stays after its callback fails). The validator proposals
  and burnt amounts it clears: nearcore reading. The comparison sees no state.
  <!-- conformance -->

### R5. Deposit refund on failure

- **Rule:** If a receipt fails, the sum of its actions' deposits goes back in a new refund
  receipt to `refund_to` if set, else to the predecessor. A refund receipt has the system
  account as its predecessor. If the refund target does not exist, the refund cannot create it
  and the amount is burnt.
- **nearcore:** `runtime/runtime/src/lib.rs:1303` (deposit refund only when the result is an
  error), `:1402-1406` (`Receipt::new_balance_refund(receipt.balance_refund_receiver(), ...)`);
  `core/primitives/src/receipt.rs:428-430` (`balance_refund_receiver` = `refund_to` or
  predecessor); `refund_to` set with `promise_set_refund_to`
  (`runtime/near-vm-runner/src/logic/host.rs:2660-2694`) and visible to contracts as
  `refund_to_account_id` (`runtime/runtime/src/function_call.rs:263`). A refund never creates an
  account: `runtime/runtime/src/actions.rs:929-933`. A failed refund is burnt:
  `runtime/runtime/src/lib.rs:1046-1054`.
- **Model:** the refund target field `rto` (default the predecessor) and a refund receipt
  (`REFND`, predecessor `"system"`) executed by `ExecTransfer`. A refund to an absent account
  is burnt by `ExecTransferFail` (`RefundBurn`): it is consumed, its callback (if any) sees
  Failed, and the amount goes to the ghost `burnt`, which `NearConserved` subtracts.
  `BurnLostRefunds <- FALSE` restores the older behaviour (the refund stays in flight).
- **Validated:** sim (`conformance/tests/receipts.rs`, `deposit_and_gas_refunds`: a failed
  receipt's deposit comes back in a refund receipt from `system` to its predecessor, a user
  or a contract; `conformance/tests/lifecycle.rs`, `receipts_to_deleted`: a refund to a
  deleted account fails and is burnt). `refund_to`: sim (`conformance/tests/receipts.rs`,
  `refund_to_receives_the_deposit_refund`: a contract's call with a 2 N deposit that panics
  is refunded from `system` to the account `promise_set_refund_to` named, which gains exactly
  2 N while the predecessor ends exactly 2 N down, and without it to the predecessor, whose
  balance ends where it started; the call reads the target as `refund_to_account_id`, the
  predecessor when unset). <!-- conformance --> sim, flows (`probes2`: `refund_to_bob`,
  `refund_to_none`): that set compares deposit refunds by receiver and every receipt's deposit
  amount (in the model's unit, 1 mNEAR), and the model's refund of the failed call's 2 N
  deposit goes, as 2 N, to `refund_to` when set, else to the predecessor, as in nearcore. The
  `probes` set leaves refund receipts and deposit amounts out on both sides.

### R6. Protocol limits

- **Rule:** At 88 nearcore enforces, among others, these limits:
  - **Actions per receipt: 100.** A transaction with more is invalid
    (`TotalNumberOfActionsExceeded`), and so is a delegate with more inner actions. A
    contract call that creates a receipt with more fails after it has run
    (`NewReceiptValidationError`), and none of its receipts are sent.
  - **Promises per function-call action: 1024.** Every host function that makes a promise
    counts one: each receipt, each `promise_and`, each yield. The 1025th fails the call
    (`NumberPromisesExceeded`).
  - **Inputs of a joint promise: 128**, counted after flattening nested ones. More fail the
    call in `promise_and` (`NumberInputDataDependenciesExceeded`).
  - **Returned value: 4 MiB** (4,194,304 bytes). More fail the call in `value_return`
    (`ReturnedValueLengthExceeded`).
  - **Deploys: 10 per receipt** (DeployGlobalContract counts as one), **4 MiB of code**.
  - **AddKey method names: 2000 bytes**, each name counting its length plus 1, and 256 bytes
    per name. A transaction with more is invalid; a call that creates such an AddKey fails
    after it has run.
  - **Logs per function-call action: 100, and 16384 bytes in all** (UTF-8 bytes of the
    messages). The 101st log, or a log longer than what is left of the 16384, fails the call
    (`NumberOfLogsExceeded`, `TotalLogLengthExceeded`); the logs written before it are kept.

  The others (arguments, receipt and transaction size, method-name length, storage keys and
  values, the storage proof) are in N-limits.
- **nearcore:** the values: `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:241-256`.
  Actions: `runtime/runtime/src/action_validation.rs:104-109`, the delegate's `:266-272`,
  checked for a transaction at `runtime/runtime/src/verifier.rs:92-104` and for a new receipt
  at `runtime/runtime/src/lib.rs:968-979`. Promises: `runtime/near-vm-runner/src/logic/host.rs:610-622`
  (`checked_push_promise`), called by `promise_and` (`:2534`), `promise_batch_create`
  (`:2581`), `promise_batch_then` (`:2645`) and the yields (`:4297`, `:4407`). Joint inputs:
  `host.rs:2523-2532`; `runtime/runtime/src/verifier.rs:749-754` for a receipt. Returned
  value: `host.rs:4711-4717`. Deploys: `action_validation.rs:21-37`, `:128-129`, `:305-318`.
  Method names: `action_validation.rs:456-474` (`method_name.len()`, UTF-8 bytes). Per
  function call: each action runs the VM afresh (`runtime/runtime/src/function_call.rs:76`,
  `:281`), with no promises yet (`runtime/near-vm-runner/src/logic/host.rs:96`, in `HostCtx::new`) and
  no logs (`runtime/near-vm-runner/src/logic/logic.rs:45-54`);
  `promise_and` pushes one promise (`host.rs:2486-2535`). Logs: `log_utf8` and `log_utf16`
  (`host.rs:4792-4800`, `:4816-4825`) check the count first
  (`runtime/near-vm-runner/src/logic/logic.rs:81-88`), then the message against what is left
  as it is read (`host.rs:486-512`, `:548-578`), then the total (`logic.rs:90-101`).
- **Model:** `NearAsync` holds the values (`MaxActionsPerReceipt`, `MaxPromisesPerCall`,
  `MaxJointInputs`, `MaxReturnedData`, `MaxLogs`, `MaxLogBytes`). Where the model can count,
  it fails as nearcore does:
  - `NActs(r)` counts a receipt's actions: its function calls (one per static or gas entry,
    at least one) and the account actions it carries (A8); an account receipt's deposit is
    its Transfer. `CanSubmit` refuses a transaction of more than 100, or a delegate whose
    inner receipt has more; `TxErr` gives `TotalNumberOfActionsExceeded` first (K5).
    `Verdict` fails a call that creates a receipt of more than 100 (`NewRcptLimitErr`),
    after the call, as for a zero-gas child (G2).
  - `HostLimitErr(r, O)` fails the call as a panic does when the outcome creates a joint
    callback with more than 128 inputs, more than 1024 promises in one function call, or
    returns more than 4 MiB. The promise count (`PromisesOver`) is the receipts a call
    creates plus its `promise_and` calls, nested ones included. The handler states those
    with `OJoins(O, n)` (for a receipt of several calls, a field `nj` in each `pa` record),
    which must be at least the call's joint callbacks, each the `.then` of one
    `promise_and` or more (an `Assert` below that, or below 0: `JoinsFieldOK`); without
    it the model counts one per joint callback (`NJoins`, exact when each
    `promise_and` feeds one callback directly), and asserts where nesting could cross the
    limit: a joint callback on `n` inputs stands for up to `n − 1` nested `promise_and`
    calls (`MaxJoins`, assuming each joins two promises or more). A `promise_and` no
    callback uses, or one of a single promise, is beyond that bound and must be stated. In a
    receipt of several function calls the count is per call, as `pa` partitions the
    children (`Partitioned`), in fault mode as in gas mode; without `pa`, a receipt whose
    total could cross 1024 is an `Assert`. Outcomes that cannot reach 1024 even at the
    upper bound are decided without looking further. A returned value is measured in
    bytes when the outcome states them (`RValLen`); from its KB size, 4196 KB fails and
    4195 KB, which may be either, is an `Assert`.
  - Logs: a handler declares each log it writes with `OLog(O, b)` (b bytes), and
    `HostLimitErr` fails the call past 100 logs or 16384 bytes. Undeclared logs count
    nothing. The limits are per function-call action, and the outcome's logs are the
    receipt's, so logs over a limit in a receipt of several function calls are an `Assert`.
    The model keeps no logs, so the ones a failed call keeps are not represented (N-events).

  Where it cannot, it asserts, so a model never passes over a refusal:
  - Deploys: a receipt has at most one deploy and one global deploy (`WithDeploy` and
    `WithDeployGlobal` assert on a second), and `CodeLen` asserts beyond 4 MiB (A9, A10).
  - Method names: `NearKeys` asserts (`MethodBytesOK`) on a function-call AddKey of more than
    2000 bytes (`MethodBytes`) in `AddKeyAct`, `AddKeyRcpt` and `ExecKeyAct`. nearcore refuses
    it where it is created, a transaction or the call whose new receipt carries it, and the
    model sees the key only where the action is built or run. nearcore counts UTF-8 bytes
    and TLC's `Len` counts characters, so `MethodBytes` counts a name as written only when
    every character is printable ASCII (`AsciiName`; the backquote excepted, SANY takes no
    backquote in a string) and asserts otherwise; `WithMethodBytes(p, n)` states the bytes
    instead (N-keyfee).
- **Validated:** sim (`conformance/tests/limits.rs`, `actions_per_receipt`: a transaction of
  100 Transfers succeeds and one of 101 is refused with `TotalNumberOfActionsExceeded`, no
  receipt and no charge; a contract's batch of 100 function calls arrives as one receipt of
  100 actions, and one of 101 fails its creator with
  `NewReceiptValidationError(TotalNumberOfActionsExceeded)` and no child;
  `promises_per_function_call_action`: 1024 promises in one call succeed and send 1024
  receipts, and 1025 fail the call with `NumberPromisesExceeded` and send none; one receipt
  of two function calls making 600 promises each succeeds and sends 1200 receipts, and one
  making 1024 then 1025 fails with `NumberPromisesExceeded` and sends none, the first call's
  included;
  `add_key_method_name_bytes`: 2000 bytes of method names are accepted and 2001 refused with
  `AddKeyMethodNamesNumberOfBytesExceeded`, the key not added; `conformance/tests/receipts.rs`,
  `joint_promise_input_limit`: 128 inputs pass and 129 fail the call, which creates no child;
  `result_size_limit_and_per_receiver_fee`: 4 MiB returned, one byte more fails the call;
  `conformance/tests/lifecycle.rs`, `deploy_storage_delta`: 10 deploys in one receipt pass
  and 11 are refused with `TotalNumberOfDeployActionsExceeded`;
  `conformance/tests/limits.rs`, `logs_per_function_call_action`: one log of exactly 16384
  bytes, the `probe`'s `record`, passes and one of 16385 fails the call with
  `TotalLogLengthExceeded`; two logs of 8192 bytes pass, 8192 and 8193 fail on the second,
  which is not kept while the first is; 100 one-byte logs pass, and the 101st fails the call
  with `NumberOfLogsExceeded`, the 100 kept; one receipt of two function calls writing 60
  logs each succeeds with 120 logs, and one of two calls writing 9000 bytes each, in two
  logs per call, succeeds with 18000 bytes, so both limits are per call; 100 then 101 logs
  fails with `NumberOfLogsExceeded`, keeping 200 logs, and 16384 then 16385 bytes fails
  with `TotalLogLengthExceeded`, keeping the first call's two logs and the second's first).
  Each test reads the value from the sim's config and asserts protocol 88's. The
  delegate's inner actions, 4 MiB of code, the yields' promises and the count of nested
  `promise_and` calls: nearcore reading. `examples/limits` checks the model's side at each
  boundary, a nested `promise_and` (`limit_nest_*`, a stated count below the joint
  callbacks included) and a receipt of two calls
  (`limit_multi_*`) included. <!-- conformance --> No flow reaches a limit.

---

## Callbacks and promise results

### C1. Callbacks always run

- **Rule:** A `.then` callback always executes once its inputs are in. A failed dependency is
  delivered as `PromiseResult::Failed`; it does not cancel the callback. That is why cleanup
  belongs in the callback.
- **nearcore:** `runtime/runtime/src/lib.rs:1172-1176` (a failed receipt sends a data receipt
  with `data = None`), `:894-895` (`None => PromiseResult::Failed` when inputs are collected).
- **Model:** a failed receipt's data is `DataOf(r, FALSE, ...)`, which the callback sees as
  `IsFailed(r.res)`.
- **Validated:** the callback runs after its dependency fails: sim (`send_named_missing_cb`,
  `ft_call_panic`, and the window just above 8.4 Tgas in `ft_call_*` and `wnear_call*`, where
  `ft_on_transfer` runs out of gas). That it reads `Failed`: sim (`conformance/tests/receipts.rs`,
  `data_receipt_carries_one_result`: `y.on_order`, which panics iff its first result is
  `Failed`, panics after `q.fail`); the comparison does not see what a callback reads.
  <!-- conformance -->

### C2. A callback can itself fail

- **Rule:** A callback that runs can still fail: out of gas, a panic, or a limit. Its own state
  changes revert (R4), its deposit is refunded (R5), and nothing undoes the receipts that ran
  before it. The hazard is a callback that runs and fails, not one that is skipped.
- **nearcore:** the same paths as R4/R5; there is no special case for callbacks in
  `apply_action_receipt` (`runtime/runtime/src/lib.rs:827-1274`).
- **Model:** the callback is an ordinary receipt for `Exec`. It can fail by gas (gas mode) or
  by `ForcedFail` (fault mode).
- **Validated:** sim for both failure kinds <!-- conformance -->: a joint callback that
  panics (`and2_order_ff`) and a yield callback that runs out of gas (`yield_cb_oog`, between
  1.9 and 2.1 Tgas). The comparison sees the callback's status, not what it reverts; the rest
  is nearcore reading.

### C3. Promise result shapes

- **Rule:** A callback sees one `PromiseResult` per input: `Successful(bytes)` or `Failed`.
  `promise_result` returns 1 or 2 for these. A receipt with no inputs has
  `promise_results_count() = 0`, which is distinct from either. A successful call that returned
  nothing yields `Successful([])` (empty bytes), not Failed. Bytes can be well-formed or
  malformed for the reader; that is the contract's business. `NotReady` (returns 0) exists in
  the ABI but the runtime path never supplies it.
- **nearcore:** `runtime/runtime/src/lib.rs:1172-1176` (`Ok(Value(data))` gives `Some(data)`,
  any other `Ok` gives `Some(vec![])`, `Err` gives `None`), `:894-895`;
  `runtime/near-vm-runner/src/logic/host.rs:4616-4646` (`promise_result`), `:4583`
  (`promise_results_count`).
- **Model:** `r.res = [ok, v, sz, len]` with `v` a number, `EMPTY`, `MAL` or `NONEMPTY`, built by
  `RVal`; helpers `IsNum`, `IsEmpty`, `IsFailed`, `NumOr`, and for a bounded read
  (`promise_result_checked`, C4) `ResTooLong` and `NumOrChecked`. No results: `NoRes` with
  `NoRes.v = NOPR` (`NoResults(r.res)`), and `IsNum(NoRes) = FALSE`.
- **Validated:** sim (`conformance/tests/receipts.rs`, `data_receipt_carries_one_result`: a
  result of the size an input returned; `Successful` with empty bytes, not `Failed`, for a call that
  returned nothing; `Failed` for a failed input; a count of 0 with no inputs, and of `n` with
  `n` joined inputs). `NotReady`: nearcore reading (the runtime never supplies it).
  <!-- conformance --> The flows produce every shape (empty, numeric, non-numeric, failed), but
  the comparison does not see what a callback reads, and no status or attached gas in them
  depends on it.

### C4. Result size

- **Rule:** A returned value can be up to `max_length_returned_data` = 4 MiB (88). The
  returning receipt pays a per-byte data fee for every receiver waiting on it. At protocol 87
  only, a receipt whose combined inputs exceed `max_receipt_total_input_size` (4,194,944 bytes)
  fails immediately with `TotalPromiseInputSizeExceeded`, without running; its inputs are
  discarded. 88 restores the limit to `u32::MAX`, which no receipt can reach.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:4695-4746` (`value_return`: length
  check and per-receiver `data_receipt_creation_per_byte` charge);
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:249`
  (limit); `runtime/runtime/src/lib.rs:845-871` (input-size check, protocol feature
  `ReceiptPromiseInputSizeLimit` at 87, `core/primitives-core/src/version.rs:636`), `:916-924`
  (the receipt fails without running its actions); `core/parameters/res/runtime_configs/87.yaml`
  and `88.yaml` (limit set, then lifted).
- **Model:** a size field on data receipts and `r.res.sz`, **in KB** (see [Units](#units)):
  `RVal(v)` has size 0 and `RValSz(v, n)` carries `n` KB (also `DataOfSz`, `RetSz`, `OSz`).
  Handlers may use `r.res.sz` as the burn size. Fee: `NearFeeTable!DataBytesFee(sir, bytes)`, which
  takes **bytes**. A second field, `len`, holds the size in **bytes** when the model states it:
  `RValLen(v, b)` sets `len = b` and `sz = ⌈b / 1000⌉` (also `DataOfLen`, `RetLen`); `RVal` and
  `RValSz` leave `len = 0` (not stated).

  **Bounded reads (SDK, not nearcore).** near-sdk's `env::promise_result_checked(idx, max_len)`
  returns `Err(PromiseError::TooLong)` when the result is longer than `max_len` bytes (strictly
  longer, so a result of exactly `max_len` bytes is read). `ResTooLong(res, max)` models that
  test with the smallest length the record allows (`ResMinBytes`): `len` when stated, else
  `1000 × (sz − 1) + 1` for `sz ≥ 1` (so `sz = 1` is at least 1 byte), else 0. So `len = 0`,
  `sz ≤ 1` counts as too long only for a bound of 0 bytes, and is assumed short for any positive
  bound such as the resolver's 42; use `RValLen` when a sub-KB bound matters. `NumOrChecked(res, max, dflt)` is `NumOr` after such a
  read (a too-long result gives `dflt`); `max < 0` is an unbounded read.
- **SDK source:** near-sdk 5.28.1 (the closest locally available version to the `~5.29.1` that
  near-contract-standards 5.29.1 requires; as read) `src/environment/env.rs:1833-1837`
  (`promise_result_checked`), `:129-137` (`read_register_bounded`: `len > max_len` is an error).
  The same code is in 5.24.0 and 5.25.0.
- **Validated:** sim (`conformance/tests/receipts.rs`, `result_size_limit_and_per_receiver_fee`:
  a 4 MiB value is returned and one byte more fails the call; the returning receipt burns
  `new_data_receipt_byte` send + exec per byte for a waiting receiver, at the other-account
  or the same-account send rate, to the gas). The protocol-87 input-size limit: nearcore
  reading; not sim-testable, since the sim runs 88. The bounded read: SDK source read; a
  near-contract-standards resolver's 42-byte bound is checked in the sim under T2.

### C5. Returning a promise forwards its result

- **Rule:** If a function call ends with `promise_return(p)`, it sends no data itself. Its
  waiting receivers are moved onto the receipt `p`, so they get `p`'s eventual result,
  possibly much later and through further hops. Joint promises (`promise_and`) cannot be
  returned. Only the last action of a batch produces the receipt's result.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:4659-4678` (`promise_return`;
  `CannotReturnJointPromise`); `runtime/runtime/src/lib.rs:1151-1170` (the output data
  receivers are appended to the returned receipt); `runtime/runtime/src/function_call.rs:249-254`
  (output receivers only for the last action).
- **Model:** `ret = RProm`, with the tail receipt's `cb` wired to `r.cb`.
- **Validated:** sim (`conformance/tests/receipts.rs`, `returned_promise_forwards_its_result`:
  p's callback on `ft_transfer_call` reads a result the size of the resolver's value, 4 bytes
  for `"10"` and 3 for `"0"`, not the call's own empty result, and runs after the resolver). The last action's result: sim under A8. `CannotReturnJointPromise`:
  sim (`conformance/tests/receipts.rs`, `joint_promise_restrictions`: returning a joint promise
  fails the call with that host error, and none of the inputs it created runs).
  <!-- conformance --> In the flows,
  `ft_transfer_call` and `near_withdraw` return promises only to the transaction, which the
  comparison does not see; no receipt there waits on a forwarded result.

### C6. Joint promises (`promise_and`)

- **Rule:** `promise_and(p1, ..., pn).then(cb)` makes one callback receipt with one fresh data id
  per input, and adds a data receiver to each input. The callback runs exactly once, when the
  last input has arrived, in whatever order they arrive. It sees `n` results in `promise_and`
  order (not arrival order); each is `Successful` or `Failed` on its own, so they mix freely. A
  failed input (panic, out of gas) gives `Failed` at its position only. An input that returns a
  promise forwards its position to the returned receipt (C5). If the creating receipt fails,
  neither the inputs nor the callback exist (R4). A joint promise cannot be returned, have
  actions appended or carry `refund_to`; `promise_and` without `.then` creates nothing.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:2486-2535` (`promise_and`, flattening
  nested joint promises, the 128-input check at `:2522-2532`), `:2605-2654`
  (`promise_batch_then` on a joint promise: one dependency per input), `:4583-4593`
  (`promise_results_count`), `:4616-4646` (`promise_result`, `InvalidPromiseResultIndex` past
  the end); `runtime/runtime/src/ext.rs:346-355` (one fresh data id per input);
  `runtime/runtime/src/receipt_manager.rs:112-140` (a data receiver on each input);
  `runtime/runtime/src/lib.rs:1646-1712` (the callback counts its missing inputs and runs at
  once if none), `:1440-1530` (each arriving data receipt decrements the count; the last one
  runs the callback), `:861-899` (results built in `input_data_ids` order, `None` is
  `Failed`), `:1146-1189` (each input sends its own result).
- **Model:** `AndThen(ks, c, d0)` wires the inputs `ks` to the fresh data ids `d0 ..
  d0 + Len(ks) - 1` and returns the callback with the optional field `ins` (those ids, in
  order). `Runnable` offers a joint callback once every id in `ins` has data
  (`Arrived`), with `rs` = the results in order (`JointRes`). The handler reads them with
  `NRes(r)` and `ResAt(r, i)` (1-based; an index past the end is an `Assert`). On a joint
  callback `r.res` is not a result: it is `JointMark` (`ok = FALSE`, `v = JOINTRES`, not a
  number), so a handler written for one input takes its `Failed` branch whatever the inputs
  were, which the model's invariants then expose. `RemD` consumes all inputs; `NoOrphans`
  checks each input. Gas: inputs and callback are ordinary children (`KidsCost`, `Give`,
  `ZeroGasKid`); the per-input data-receipt base fee and the `promise_and` fees are in the
  creator's calibrated burn, which therefore needs its own key per input count (G4).
- **Validated:** sim for these parts (`conformance/`, flows `and2_*` and `and3_mixed`; see
  [Async patterns](../conformance/README.md#async-patterns-joint-promises-and-yieldresume)):
  the callback runs exactly once, also when an input panics (`and2_fail`) or runs out of gas
  (`and2_oog`, below its window edge); the callback's attached gas, the inputs' and the
  creator's window edges with two and three inputs, same- and cross-account (`and2_ok`,
  `and3_mixed`; the creator's burn calibrated per input count); the order of the results
  (`and2_order_ff` / `and2_order_fs`: a callback that fails iff its first result is `Failed`
  fails with the failing input first and succeeds with it second); an input or a joint
  callback with 0 gas fails the creator (`and2_s0`, `and2_cb0`). The comparison is per receipt
  and unordered, so that the callback runs after the last input, rather than at some other
  time, is not compared (nearcore reading; every receipt of these flows is in one
  transaction, so the transaction says nothing about it either). It does not see what the
  callback reads otherwise, and the sim gives one arrival order. Nested joins flattened
  (three inputs joined pairwise give three results, the first input's at index 0), an input
  that returns a promise forwarding the result to its index (with two inputs, in both
  orders, each index's size asserted), and the 128-input limit: sim
  (`conformance/tests/receipts.rs`, `data_receipt_carries_one_result`,
  `returned_promise_forwards_its_result`, `joint_promise_input_limit`). One result read by index, past index 0 too: sim
  (`joint_result_by_index`: a callback reading only index i of three inputs of distinct sizes
  gets input i's, joined flat, as `(a & b) & c` and as `a & (b & c)`, and `(b & c) & a` gives
  b, c, a; the same with each input in turn held back to arrive last; a failed middle input
  gives `Failed` at index 1 only; index 3 fails the callback with `InvalidPromiseResultIndex`).
  One result by index is also sim against the model, flows (`probes2`, `idx_*`): a callback
  that fails unless result i has the size the flow names (`on_expect`) agrees at every point
  at each of indexes 0, 1 and 2 for joins flat, `(a & b) & c`, `a & (b & c)` and
  `(b & c) & a`, and flat with a failed middle input, `Failed` at index 1 (the handler
  flattens the nesting; `AndThen` and `ResAt` do the rest). The restrictions on joint
  promises: sim (`joint_promise_restrictions`: returning one,
  appending an action to one and setting its `refund_to` each fail the creating call with its
  own host error, and none of the inputs it created runs; `promise_and` with no `.then` adds
  no receipt beyond its inputs). `examples/platform-selftest` checks the order with the failing input first
  (`and_order`), a starved input (`and_starved_leg`) and a joint callback with no gas
  (`and_zero_cb`). <!-- conformance -->

### C7. Yield and resume (NEP-519)

- **Rule:** `promise_yield_create` makes a callback on the current account that waits on one
  data id (the resume token). `promise_yield_resume(id, payload)` returns 1 and sends the
  payload if the yield's callback has not run yet, whether or not another resume was already
  sent; otherwise (the callback ran, by resume or by timeout, or the id is not this account's
  yield) it returns 0 and sends nothing. The callback runs once, with the payload of the first
  resume to arrive; later resumes are dropped. If no resume is sent, the yield times out:
  from `yield_timeout_length_in_blocks` = 200 blocks after the creating block, a timeout
  delivers `Failed`, and it is dropped if a resume was sent first. The timeout fires late,
  never early. The callback's predecessor is the contract itself and its signer the yielding
  transaction's. Its gas is a child's: static gas and a weighted share of the creator's
  leftover; with 0 gas it fails the creator. A failing creator leaves no yield, a failing
  resumer sends nothing. A yield can be returned (the caller's result is the callback's) or be
  an input of a `.then` or `promise_and`. A resume in the same call that yielded works.
  `promise_yield_create_with_id` returns `u64::MAX` and creates nothing while the account has a
  pending yield with the same custom id, including one created earlier in the same call; the
  call goes on. A yield callback is no longer pending when it runs, so it may re-create its
  own custom id.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:4245-4327` (`promise_yield_create`:
  receipt with one same-account dependency, weight, data id to a register), `:4330-4440`
  (`promise_yield_create_with_id`: a caller-chosen id, `u64::MAX` on a duplicate at
  `:4391-4399`, may carry a deposit), `:4473-4518` (`promise_yield_resume`, the payload limit
  at `:4505-4510`); `runtime/runtime/src/ext.rs:365-370` (the status is written at creation),
  `:375-385` (duplicate check of the `_with_id` form, which sees the ids written earlier in
  the same call), `:406-430` (`submit_promise_resume_data`: TRUE while the yield receipt or
  its status exists for this account); `runtime/runtime/src/lib.rs:1549-1553` (the
  `PromiseYield` receipt is stored), `:1554-1563` (a timeout resume is dropped after a payload
  resume), `:1564-1615` (the first resume removes the yield and its status, `:1572-1575`, and
  its custom-id mapping, `:1576-1591`, then runs the callback, `:1602-1604`; `:903` commits
  the removals before the callback's code runs), `:1616-1622` (later resumes are ignored),
  `:3113-3221` (`resolve_promise_yield_timeouts`, `expires_at <= block_height` at `:3146`, an
  early stop at the compute limit at `:3130-3132`), `:1151-1168` (a returned yield forwards
  the caller's receivers); `runtime/runtime/src/function_call.rs:151-170` (the timeout is
  enqueued only when the call succeeds, deadline = block height + 200), `:171-189` (signer and
  predecessor);
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:274` (200
  blocks).
- **Model:** `YieldRcpt(id, r, m, a, dep, cb)`, a receipt with the optional field `ydl` (the
  height from which it may time out, `blk + YieldTicks`), placed in the outcome's `post`.
  `OResume(O, y, v, n)` records a resume in the outcome (`rsm`); `Commit` adds
  `ResumeData(r, O)`, one data receipt per resume of a yield of `r.to` that is pending in
  `post` or created by the same outcome. `CanResume(r, y)` is the host's return value. `Runnable` offers the
  yield with each resume in flight (the first to arrive wins), and with `FailedRes` when
  `TimedOut`: no resume in flight and `blk >= ydl` (or `blk = MaxBlk`). The timeout's trigger
  and its arrival are one step; that is exact, because a resume sent before the timeout's
  `PromiseResume` arrives wins in nearcore too. `RemD` drops the extra resumes.
  `PendingYieldRcpts(r, ps)` lists the yields of `r.to` still pending as `r`'s handler sees
  them: without `r` itself (a running yield callback is no longer pending) and with `ps`, the
  yields the handler has created so far; `PendingYieldsAt(r, ps)` is their ids.
  `PendingYields(a)` lists a's waiting yields as a state view (for invariants, not handlers).
  `examples/platform-selftest` checks a callback re-creating its own custom id
  (`yield_id_recreate`, `yield_id_recreate_timeout`) and a duplicate in one call
  (`yield_id_same_call`); the runs `selftest_yield_id_old_*` show that the state view would
  get both wrong. Gas: the yield callback is an ordinary child (`KidsCost`, `Give`,
  `ZeroGasKid`); the `yield_create_*` fees and the receipt and data-receipt base fees are in
  the creator's calibrated burn, the `yield_resume_*` fees in the resumer's
  (`host.rs:4256-4310`, `:4481-4489`).
- **Left to the handler:** `promise_yield_create_with_id`'s duplicate check (keep the custom
  id in the yield's args, test it against `PendingYieldRcpts(r, ps)`, and create nothing on a
  duplicate; a plain `promise_yield_create` has no custom id, so mark which yields carry one)
  and its deposit (`YieldRcpt(.., dep, ..)` with `dep` in the outcome's `out`).
- **Validated:** sim for these parts (`conformance/`, flows `yield_*` on a separate async probe
  contract; see
  [Async patterns](../conformance/README.md#async-patterns-joint-promises-and-yieldresume)):
  the callback runs exactly once in a flow whose later transaction resumes it (`yield_resume`)
  and in one with no resume whose yield times out (`yield_timeout`), and no yield is left
  parked at the end of either; a resume sent after the callback has run, by timeout
  (`yield_resume_late`) or by an earlier resume (`yield_resume_twice`), sends nothing (still
  one callback, and the resuming transactions' own receipts compared under their transaction
  numbers); two resumes in the yielding call give one callback (`yield_self_resume2`); the
  callback's gas is a child's (static and weighted share: `yield_cb_oog` runs out of gas
  between the creator's edge at 1.9 Tgas and its own at 2.1 Tgas, and the split check covers
  every yield callback), and with 0 gas it fails the creator (`yield_cb0`), although the
  yield is stored, not sent. The flows run the model on a one-tick clock, so the 200-block
  deadline and the race at it are not checked there (near-contract-sim's own tests cover the
  race, `tests/yields.rs:70-92` at its rev 29e9090), and what the callback reads is not
  compared. Nor is the order in which receipts run: that the callback runs after the resume
  or the timeout follows from how the flows run (each step once the chain is idle; the sim's
  `transact()` returns with the yield parked) and from the nearcore reading, not from the
  comparison. The transaction gives no order either: the sim lists a yield callback under the
  transaction that yielded, whichever one resumed it, and the model does the same.
  `conformance/tests/semantics.rs` observes in the sim, without a model comparison: two
  resumes that run in one block both return 1 and the first payload wins; a resume after the
  timeout returns 0; a resume of another account's yield returns 0 and leaves it parked; the
  payload limit ([N-yield-payload](#under-approximations-unsound-they-can-hide-bugs)); and
  (`yield_times_out_at_200_blocks`) the timeout of a yield made at h: still parked at
  h + 199, resolved at h + 200, and its callback run at exactly h + 201, reading `Failed`,
  with the yielding account as its predecessor. On the
  `probe2` contract, also without a model comparison: the `_with_id` form
  (`yield_with_id_duplicates_and_reuse`: a create with a custom id that is pending, in the
  same call or a later one, returns `u64::MAX` and parks no yield, and the call succeeds;
  `promise_yield_resume_with_yield_id` returns 1, then 0; once the callback has run the id
  parks a new yield, also when the callback re-creates it itself); a deposit
  (`yield_deposit`: 2 N leaves the yielding account at creation, the callback receives it,
  and the account's balance is back once the callback has run); a returned yield
  (`returned_yield_forwards_its_result`: the caller's callback runs after the yield callback
  and reads its result, exactly the resumed bytes, or, on a timeout, an empty success, not
  `Failed`); the callback's signer
  (`yield_callback_signer_is_the_yielding_signer`: alice yields, and the callback's signer is
  alice whether bob resumes it or it times out; its predecessor is the yielding account).
  Against the model, flows (`probes2`): the `_with_id` duplicate check in the same call
  (`yid_twice`) and a later one (`yid_dup_later`), a resume by id (`yid_dup_later`,
  `yid_again`) or of no pending id (`yid_resume_none`), the id free in a later call once its
  callback ran (`yid_reuse`: yield, resume and, once that callback has run, the same id parks a
  new yield, all in one run) and from the callback itself (`yid_again`), as handlers that keep
  the custom id in the yield's payload (`PendingYieldRcpts`); a deposit (`yid_deposit`: the
  callback's receipt carries the 2 N, amounts compared) and one over the balance, which fails
  the creating call (`yid_deposit_over`); a returned yield whose caller's callback reads the yield
  callback's result, the payload or an empty success (`yret_resume`, `yret_timeout`). The
  signer is not compared. `examples/platform-selftest` checks a second resume (`resume_twice`), two
  resumes in the yielding call (`resume_same_call`), a timeout then a resume
  (`timeout_then_resume`), a resume in flight at the deadline (`resume_beats_timeout`), a
  resume by another account (`resume_other_acct`), a returned yield (`yield_returned`) and a
  yield callback with no gas (`yield_zero_cb`). <!-- conformance -->

---

## Gas

### G1. Prepaid gas

- **Rule:** A transaction's function call carries prepaid gas `g`, at most
  `max_total_prepaid_gas` = 1000 Tgas (protocol 83+). The call can use up to `g`: its burnt gas
  plus what it reserves for children may not exceed `g`. `env::prepaid_gas()` is the gas
  attached to this function-call action.
- **nearcore:** `runtime/runtime/src/function_call.rs:274` (`prepaid_gas: function_call.gas`);
  `runtime/near-vm-runner/src/logic/gas_counter.rs:126-150` (`deduct_gas`: fails with
  `GasExceeded` when `burnt + promises_gas > prepaid_gas`), `:205-213`;
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:243`,
  `core/parameters/res/runtime_configs/83.yaml:8`.
- **Model:** `WithGas(r, p)` on the first receipt (`Submit(WithGas(...))`); `LastGas(r)` is
  what the receipt sees as `env::prepaid_gas()`.
- **Validated:** sim (every flow: the first receipt's gas is the prepaid at 1313 points from
  0.5 to 300 Tgas, and its out-of-gas edge matches); the 1000 Tgas cap, for a transaction's
  calls together: sim (`conformance/tests/receipts.rs`, `prepaid_gas_ceiling`).
  <!-- conformance -->

### G2. Static gas, checked at promise creation

- **Rule:** Attaching static gas `s` to a child function call reserves `s` from the creator at
  once. The child's send fee is burnt and its exec fee prepaid at the same moment. If the
  reservation does not fit, the creating call fails right there (`GasExceeded`), so neither it
  nor any child commits (R4). This is the safe case: nothing is half-created.

  A call that panics after burning less than its gas fails with the panic; one that would run
  out of gas before reaching the panic fails with `GasExceeded`. A function-call child that
  ends up with 0 attached gas (static 0 and no share of the leftover) fails the **creating**
  receipt: new receipts are validated after the call (`FunctionCallZeroAttachedGas`).
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:3578` (`prepay_gas(gas)` in
  `promise_batch_action_function_call_weight`), `:3564-3577` (base and per-byte fees first);
  `runtime/near-vm-runner/src/logic/gas_counter.rs:126-150`, `:136-141` (the burn limit is
  prepaid − promises gas), `:155-174`, `:205-213`;
  `runtime/runtime/src/action_validation.rs:350-351` (zero gas), applied at
  `runtime/runtime/src/lib.rs:968-978`.
- **Model:** `Need = Burn(r, O) + Σ_children (c.gf + Σ c.gs)` (`KidsCost`); `GasOK(r, O)` is
  `Need ≤ Σ r.g`. Otherwise the verdict is `"oog"` and `FailOOG` applies. A failing outcome
  with an explicit panic-path burn key (`OPanicKey(O, k)`; per action `OPanicAt(O, i, k)`) is
  labelled `"oog"` when that burn plus the children created before the panic exceeds the
  attached gas (`PanicOOG`; per action: the actions before `i` against their own need, and
  action `i` against the panic burn). Only the label differs. Without a panic key a panic is
  always `"fail"`: the success-path burn says nothing about where the panic happens.
  `ZeroGasKid` fails the creator when a child call gets 0 gas, ready or callback; under
  `"up"`, where the model cannot always tell 0 gas from a little, it keeps both outcomes
  (`ZeroGasMaybe`, G3). In gas mode a
  function-call child must have one static (and weight) per call, from `GasCall` or `WithCall`;
  an empty list is an `Assert` (`GasListsOK`).
- **Validated:** sim (`chain1`, `chain3w`, `chain_w0`, `ret*`: the creator fails until its
  children's statics and fees fit; `chain_s0`: a 0-gas child fails its creator;
  `ft_call_panic`: out of gas before the panic, then the panic). The per-action panic label
  (`OPanicAt`), which no flow reaches: nearcore's side in the sim
  (`conformance/tests/receipts.rs`, `per_action_gas_and_panic_label`: the second call of a
  `[put, fail]` receipt runs out of gas on 1 Ggas and panics on 20 Tgas, on its own gas);
  no comparison with the model's label. <!-- conformance -->

### G3. Weight and the leftover split (`distribute_gas`)

- **Rule:** After a successful call, its unused gas `U = prepaid − used` is split among the
  function-call actions it created that have weight > 0. Each gets `⌊U·w/W⌋`, and the **last**
  weighted action gets the remainder. "Last" is in **host-call order**: `gas_weights` is pushed
  each time a weighted function-call action is appended, so an action appended later to an
  earlier promise comes after one appended earlier to a later promise. If `W = 0` (or `U = 0`),
  nothing is distributed and the leftover is refunded to the signer as gas.
- **nearcore:** `runtime/runtime/src/receipt_manager.rs:679-719` (`distribute_gas`), `:414-419`
  (`gas_weights.push` at append time); `runtime/runtime/src/function_call.rs:343-347` (called
  with `unused_gas = function_call.gas − outcome.used_gas`, skipped for views). NEP-264.
- **Model:** `Give` assigns `g` to the children's weighted actions (`Share`). The model's `U`
  is in whole Ggas, and what happens to its remainder depends on `NearFees.FeeRounding`:
  - **`"up"` (the default):** every weighted action gets `⌊U·w/W⌋` Ggas, the last one
    included; the model's remainder (up to `n − 1` Ggas for `n` weighted actions) goes to no
    one. A whole-Ggas floor of a smaller amount never exceeds the gas-unit floor of a larger
    one, so every share is at most nearcore's **where the model's `U` is at most nearcore's**.
    That holds when the attached gas is at most nearcore's (a stated prepaid amount, or itself
    an `"up"` share) and the need is an upper bound (fees rounded up, burns an upper
    envelope). N-precision lists where these premises fail: pooled gas (N-batch-oog), burns
    from hand-written tables, past a calibrated table's measured sizes, or off its measured
    paths (N-burn). There a share can exceed nearcore's. A share falls short of
    nearcore's by less than 1 Ggas plus its weight's part of the two leftovers' difference, and
    the last action also by nearcore's remainder. Which action is last no longer matters.

    **Zero gas under `"up"`.** Since the model's `U` is only a lower bound (in whole Ggas),
    it cannot always tell whether a static-0 action ends up with 0 gas in nearcore, which
    fails the creator (G2). Weight 0: certainly 0 (it is not in `gas_weights`, so it gets
    neither a share nor the remainder, `receipt_manager.rs:414-419`), so the creator fails
    (`ZeroGasKid`). Weight `w > 0` with `U·10⁹·w ≥ W`: nearcore's share is at least
    `⌊U·10⁹·w/W⌋ ≥ 1` gas unit, certainly nonzero (`SureShare`), so the creator commits.
    Otherwise (`U = 0`, or a small weight against a large sum, which floors to 0 gas units
    even with 1 Ggas left; nearcore's own documentation notes this,
    `runtime/near-vm-runner/src/logic/host.rs:3501-3503`) both are possible (`ZeroGasMaybe`):
    the verdict is `"either"`, and the creator fails in one successor and commits in the
    other. In the commit the child runs with its floor of 0 Ggas and runs out of gas. Examples
    (`examples/platform-selftest`): a model leftover of 0 with one weight-1 child
    (`zero_gas_left0`; nearcore's leftover may be 0.5 Ggas, and the creator commits), and
    1 Ggas over weights 1 and 10⁹ (`zero_gas_heavy`; nearcore gives exactly 1 Ggas as
    `[0, 10⁹]` gas units, and the creator fails). The runs `selftest_zero_*` reach both
    outcomes of each.
  - **`"nearest"`:** the last weighted action in (child id, action index) order also gets the
    remainder (`FloorSum`), in Ggas, so it can get up to `n − 1` Ggas more than nearcore
    gives it, and a burn within that margin passes in the model and runs out of gas in
    nearcore (`examples/weight-split/remainder`: six equal weights, a model leftover of 1001
    Ggas against nearcore's 1009.84; the last child gets 1171 Ggas against 1168.31). The order
    matches host-call order whenever a handler builds each child completely before creating
    the next; a handler that interleaves appends across promises can see the remainder go to a
    different action. A share that floors to 0 Ggas on a static-0 action fails its creator,
    whatever nearcore's gas-unit share (the conformance comparison is pinned to this mode).

  **Per action:** each function-call action of a receipt has
  its own gas and its own promise manager, so only that action's leftover is split, over the
  children it created (`runtime/runtime/src/function_call.rs:61`, `:343-345`; the rest is
  refunded, `runtime/runtime/src/lib.rs:1311-1315`). An outcome with `pa` (one
  `[gk, sz, kids]` record per action) gets this per-action check and split (`PerAction`,
  `ActNeed`, `Alloc`); `pa` must have one record per entry of `r.g`, with disjoint kid sets
  (`PAOK`, an `Assert`). Without `pa` a receipt is one action; a receipt with several gas
  entries and no `pa` would pool them, which is an `Assert` unless `PooledGasOK <- TRUE`
  (`PoolCheck`; a plain panic is exempt). Per-call defaults are
  `GasCall[key] = [st, wt, fee]`
  (`CallKey`/`CallDef2` look up `"acct.method"`, then `"method"`), overridden by `WithCall`,
  `WithStatic`, `WithWeight` and `WithFee`.
- **Validated:** sim within 5 Ggas: the split by weight (`chain1`, `chain3w`), `W = 0`
  (`chain_w0`), `ft_on_transfer`'s leftover (`ft_call_*`, `wnear_call*`) and the per-action
  split of a multi-call receipt (`ft_batch_SC`, `wnear_batch_SC`, `wnear_batch_DC`,
  `wnear_batch_DSC`). The floor-and-remainder rule (a few gas) is below that tolerance: sim
  (`conformance/tests/receipts.rs`, `leftover_split_floor_and_remainder`: three weight-1
  children get `⌊U/3⌋`, `⌊U/3⌋` and `⌊U/3⌋ + U mod 3`, U derived from the parent's attached
  gas, burn and fees, not from the shares, the last appended taking the
  remainder, and one more prepaid gas gives one more leftover gas); the calibration's split
  check confirms it to the gas on every flow, against the formula rather than the model, and
  `examples/weight-split` covers it in the model under both modes. "Last" in host-call order
  when appends interleave across promises: sim (`remainder_goes_to_last_appended`: a contract
  creates promises A then B and appends one weight-1 call to each; appended B then A, A's
  call, on the earlier receipt, gets `⌊U/2⌋ + U mod 2` and B's `⌊U/2⌋`, appended A then B the
  reverse, each at two consecutive prepaid amounts, one with U odd; each receipt holds one
  call). The tolerance is symmetric and cannot see the direction. In a
  one-off measurement against the sweep data (not a check `conform.py` runs), against the
  sim's unrounded attached gas with `"up"` substituted, the model's is at or
  below the sim's for every paired receipt of the 73 flows; with the remainder still handed
  out it was above by up to 0.17 Ggas in `and3_mixed` (as under `"nearest"`).
  `examples/weight-split/remainder` checks the direction on a remainder of 5 Ggas
  (`remainder_up_ok`; under `"nearest"`, `remainder_nearest_over` and
  `remainder_nearest_false_ok` fail). <!-- conformance -->

### G4. Who pays action send and exec fees

- **Rule:** The account that *creates* a receipt pays for it out of its own gas, at creation:
  the receipt base fee (send burnt, exec prepaid), and each action's send fee (burnt) and exec
  fee (prepaid). A `.then` also burns a data receipt's send and exec base fee for each
  dependency. A Transfer's fee depends on the receiver's account type (A2). For a transaction's
  first receipt the signer pays in the same way, at conversion (`sir` = signer is receiver). The
  child's exec fee is then burnt when the child executes, from the gas the creator prepaid.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:3621-3661`
  (`promise_batch_action_transfer`: `burn = send_fee`, `use = send_fee + exec_fee`, both via
  `pay_action_accumulated` on the creator's counter), `:2345-2365` (`pay_gas_for_new_receipt`:
  receipt base plus a data-receipt base per dependency), `:5379-5410` (`pay_action_base`,
  `pay_action_per_byte`); `runtime/runtime/src/lib.rs:911-914`, `:588-592` (exec fees burnt at
  execution); `runtime/runtime/src/config.rs:489` (`calculate_tx_cost`:
  `sender_is_receiver = receiver_id == signer_id`), `:86-224` (`total_send_fees`).
- **Model:** fee values in `modules/NearFees.tla` (`ReceiptFee`, `SendFee`, `ExecFee`,
  `ActionFee`, `TransferFeeTotal`, `DataDepFee`, `DataBytesFee`, per-byte operators).
  Accounting: function-call children have `c.gf` = their prepaid exec fee, and their send
  fee sits inside the creator's calibrated burn. Action-only children (Transfer, AddKey,
  DeleteKey, Stake, ...) have `c.gf` = send + exec of the whole single-action receipt, receipt
  base included, so one burn key works for named and implicit receivers. `NearAsync` reads the
  table through `NearFeeTable == INSTANCE NearFees` (`XferFee`, `StakeFee`, `BuiltinFee`);
  `NearKeys` through `KeyFee`, which charges a function-call AddKey its per-byte part too
  (`MethodBytes`; see N-keyfee).
- **Validated:** for action-only Transfer children, sim: the creator pays the whole receipt's
  fees from its own gas, by receiver kind (`send_*` edges; `ft_storage_again`,
  `wnear_storage_again` and `wnear_withdraw` for a contract's Transfer to a named account), and
  the calibration found every action-only exec fee equal to the fee table (AddKey,
  CreateAccount and DeleteAccount too, from `flows/actions.toml`, with no model run). For
  function-call children the send fee and the data-receipt fees sit inside calibrated burns
  and the exec fee is calibrated, so the sim does not check them against the table: nearcore
  reading. <!-- conformance -->

### G5. Out-of-gas revert scope

- **Rule:** Running out of gas is an ordinary failure of that receipt. Its state reverts, it
  has no children, and its deposit is refunded (R5). Its callback, if any, gets `Failed` (C1).
  The gas burnt up to the failure stays burnt. The rest of the prepaid gas, `prepaid −
  gas_burnt` (not `gas_used`), is refunded to the signer.
- **nearcore:** `runtime/runtime/src/function_call.rs:100-138` (the abort becomes the action
  error); `runtime/runtime/src/lib.rs:535-541`, `:1304-1316` (failure refunds against
  `gas_burnt`, success against `gas_used`).
- **Model:** `FailOOG`, with the `oog` ghost recording `<<tx, method>>`.
- **Validated:** an out-of-gas receipt has status out of gas and no children, and its
  callback still runs: sim (the flows that create children, below their window edge, e.g.
  `chain1` below 12.9 Tgas; `ft_call_*` and `wnear_call*` just above 8.4 Tgas). The deposit
  and gas refunds: sim (`conformance/tests/receipts.rs`, `deposit_and_gas_refunds`: an
  out-of-gas `[Transfer, call]` receipt refunds the deposit, and its signer is out exactly the
  gas burnt); the comparison leaves refunds out. <!-- conformance -->

---

## Accounts

### A1. Account existence

- **Rule:** Before each action the runtime checks the receiver account. `CreateAccount` needs it
  absent. A Transfer to an absent account fails unless implicit creation applies (A3). The
  NEP-616 state inits (`DeterministicStateInit`, `UniversalStateInit`) pass whether the account
  exists or not: they create a missing one. All other actions (FunctionCall, AddKey, DeleteKey,
  Stake, Deploy, DeleteAccount, ...) need it present. At 87+ the account must also be
  initialized for them: an uninitialised `0u` account counts as absent, except to a Transfer
  and its own state init (N-universal).
- **nearcore:** `runtime/runtime/src/actions.rs:814-895` (`check_account_existence`; the state
  inits at `:851-861`, the uninitialised check at `:883-888`), called at
  `runtime/runtime/src/lib.rs:600-605`.
- **Model:** the `Exists` constant (initial accounts) and `AcctExists`: an account exists if
  it is in `Exists` or `created` and not in `deleted` (A7).
- **Validated:** sim (`conformance/tests/accounts.rs`, `existence_and_code`: a call or an
  AddKey to an absent account fails with `AccountDoesNotExist`, existence checked before the
  actor; an uninitialised universal account refuses both with `AccountNotInitialized` and
  takes a Transfer). A deleted account: sim (`conformance/tests/lifecycle.rs`,
  `receipts_to_deleted`); CreateAccount on an existing id: A6. The state inits: nearcore
  reading (no test builds one; state init is [not modelled](#not-modelled)).

### A2. Account types (by id pattern)

- **Rule:** The account type comes from the id string alone: `0x` + 40 hex is eth-implicit;
  64 hex is NEAR-implicit; `0s` + 40 hex is deterministic (NEP-616); `0u` + 52 Crockford
  base32 characters whose last character is `0` or `g` is universal (87+); anything else is
  named. Fees use the pattern **even if the account already exists**, so a Transfer to an
  existing eth-implicit account still pays the create_account fee.
- **nearcore:** near-account-id 3.0.0 (the version in nearcore's `Cargo.lock:3890-3892`),
  `src/account_id_ref.rs:246-260` and `src/validation.rs:96-132` (universal's last character:
  `:123`). Runtime flags: `runtime/runtime/src/actions.rs:899-927` (`get_account_type`:
  eth-implicit and deterministic need `eth_implicit_accounts`, TRUE at 84-88; universal needs
  `universal_accounts`, 87+). On the **fee** side only universal is flag-gated: deterministic is
  charged transfer + create_account unconditionally (`core/parameters/src/cost.rs:805-807`,
  `:844-846`). Fees by pattern: `core/parameters/src/cost.rs:775-810`, `:812-848`, with callers
  passing `receiver_id.get_account_type()` and no existence check
  (`runtime/near-vm-runner/src/logic/host.rs:3639-3651`; `runtime/runtime/src/config.rs:120-128`,
  `:360-368`).
- **Model:** `NearFees.RcvKinds` = `{"named", "near_implicit", "eth_implicit",
  "deterministic", "universal"}`. `AcctKinds`, `AcctKind`/`KindOf` and `IsImplicit` assign kinds
  to model accounts; `IsImplicit` covers NEAR-implicit, eth-implicit, deterministic and (when
  `UniversalOn`) universal. `UniversalOn` is an overridable definition, default TRUE (protocol
  87+, so the pinned 88). It does not follow `NearFees.FeeProtocol`: set `UniversalOn <- FALSE`
  for the rules before 87, where a universal id is named (`get_account_type`,
  `runtime/runtime/src/actions.rs:918-924`), so a Transfer to an absent one fails. The fee
  table gates universal fees on the fee version on its own (`NearFees.UniversalAccountsOn`), so
  `FeeProtocol == 86` with the default `UniversalOn` creates the account but charges 86's fee
  for a named receiver (see `docs/VERSIONING.md`).
- **Validated:** nearcore reading. The fee-by-pattern rule for named, NEAR-implicit and
  eth-implicit receivers, existing and absent: sim (`send_named`, `send_nimp`, `send_nimp_new`,
  `send_eth`, `send_eth_new`; an existing eth-implicit receiver puts the edge at 8.5 Tgas, as
  an absent one does, against 0.8 for a named one). Every implicit kind, deterministic and
  universal included, absent and existing: sim (`conformance/tests/accounts.rs`,
  `transfer_fee_by_pattern`: the conversion and the receipt burn create_account's send and
  exec fees over a named receiver's, NEAR-implicit also add_full_access_key's, the same once
  the account exists). `UniversalOn <- FALSE` (before 87): nearcore reading; the sim runs 88.
  <!-- conformance -->

### A3. Implicit-account creation on Transfer

- **Rule:** A Transfer to an absent NEAR-implicit, eth-implicit or deterministic id creates the
  account, but **only if the Transfer is the receipt's only action** and the receipt is not a
  refund. Universal (87+) ids may be created even when batched. What is created:
  - NEAR-implicit: an account holding the deposit, with one full-access key derived from the id.
  - eth-implicit: an account holding the deposit whose code is nearcore's global eth-wallet
    contract (`AccountContract::Global`). A function call to it therefore runs that contract;
    it does not fail with "no code".
  - deterministic: an account with no keys; its state arrives with a state-init action.
  - universal: an **uninitialised** account (balance only). Until its state init runs, every
    action other than Transfer and its own state init fails with `AccountNotInitialized` (A1).

  **Account creation charge (85+, `AccountCostIncrease`):** when a receipt ends with an account
  that did not exist before and the receipt succeeded, the runtime takes
  `account_creation_charge` (0.007 NEAR at 85-88) minus what the create_account exec gas already
  cost at the burn price, out of the price-difference part of the gas refund only (it is capped
  by that part), and burns it.

  **Fee:** the creator pays the single-action receipt total `NearFees.TransferFeeTotal(sir,
  kind)`, which **includes the receipt base fee** (108 + 108 Ggas), plus the create_account (and,
  for NEAR-implicit, add_full_access_key) parts by pattern.
- **nearcore:** `runtime/runtime/src/actions.rs:929-946` (`implicit_creation_allowed`;
  `is_the_only_action` from `runtime/runtime/src/lib.rs:597`), `:221-287`
  (`action_implicit_account_creation_transfer`; eth-implicit at `:255-269`, universal
  `Account::new_uninitialized` at `:276-282`), `runtime/runtime/src/lib.rs:3016-3062`
  (`action_transfer_or_implicit_account_creation`), `:1057-1058` (`created_new_account`),
  `:1361-1397` (account creation charge), `core/parameters/res/runtime_configs/85.yaml`
  (`account_creation_charge`).
- **Model:** `ExecTransfer` creates a missing implicit receiver as an existing account (in
  `created`); it does not check the "only action" condition (built-in Transfer receipts hold one
  action). A created account has no code (`HasCode`) unless it is eth-implicit (the wallet
  contract, `EthWalletCode`, whether or not the account is in `Contracts`), so calls to a
  created NEAR-implicit, deterministic or universal account fail. The NEAR-implicit key is
  added by `NearKeys.ExecTransferK` (key id `ImplicitKeyId`) for an account in `KeyAccts`;
  `ExecTransfer` alone leaves keys to the model. The rest of the universal uninitialised state
  (N-universal) and the charge (N-gas-money) are not modelled. A Transfer to a deleted implicit
  id creates it again the same way (A7). With `StoragePerByte` the created account's bytes are counted (`CreatedBytes`, B2),
  the NEAR-implicit key's included.
- **Validated:** a lone Transfer to an absent NEAR-implicit or eth-implicit id succeeds and
  its creator pays the creation fees: sim (`send_nimp_new`, `send_eth_new`, `send_eth_new_cb`).
  The only-action condition (a universal id created even when batched), what each kind
  creates (182, 132, 100 and 100 bytes; the NEAR-implicit key derived from the id; a
  global-contract reference by hash for eth-implicit; an uninitialised universal account) and the account
  creation charge (0.007 N less the create_account exec gas, burnt): sim
  (`conformance/tests/accounts.rs`, `implicit_creation_by_kind`, `account_creation_charge`).
  That the reference is the eth-wallet contract's hash: nearcore reading (the sim does not
  expose the expected hash). That a call to an eth-implicit account runs the wallet contract:
  not sim-testable, because
  the sim's chain has not published the wallet code, so there the call fails with
  `CodeDoesNotExist`; the rule holds on a chain that has published it (nearcore reading).
  The comparison sees no balances. <!-- conformance -->

### A4. Transfer to a missing named account fails and refunds

- **Rule:** A Transfer to an absent named account fails with `AccountDoesNotExist`, so the
  receipt fails and its deposit goes back to `refund_to` or the predecessor (R5). The same
  happens to a batched Transfer to an absent implicit id (A3).
- **nearcore:** `runtime/runtime/src/actions.rs:842-849`; refund as in R5.
- **Model:** `ExecTransferFail(r)`.
- **Validated:** the Transfer fails: sim (`send_named_missing`, `send_named_missing_cb`). The
  refund to the sender and the batched implicit case: sim (`conformance/tests/receipts.rs`,
  `deposit_and_gas_refunds`; `conformance/tests/accounts.rs`, `implicit_creation_by_kind`);
  the comparison leaves refunds out. <!-- conformance -->

### A5. Function call to an account without code fails

- **Rule:** A FunctionCall to an existing account with no contract fails with
  `CompilationError(CodeDoesNotExist)`. Like any failure, the receipt reverts and refunds (R4,
  R5). A FunctionCall to an absent account fails earlier with `AccountDoesNotExist` (A1).
- **nearcore:** `runtime/runtime/src/function_call.rs:309-312` (`VMOutcome::nop_outcome` with
  `CodeDoesNotExist`); `runtime/runtime/src/actions.rs:874-887` (`AccountDoesNotExist`,
  `AccountNotInitialized`).
- **Model:** `Exec` fails a function call whose receiver is missing or has no code before the
  handler's outcome counts (`CallTargetOK`, `HasCode`); the accounts with code at the start
  are the overridable definition `Contracts` (default `Accounts`), and a DeployContract gives
  an account code at run time (A9; the call sees the code its receipt's earlier actions leave,
  `CodeSeen`). `CallsNeedCode <- FALSE` turns the code half of the rule off for older models;
  a missing, deleted or uninitialised receiver still fails the call. `NearKeys.FailNoCode`
  and `ExecNoCode` are the same rule as an
  explicit step.
- **Validated:** sim (`conformance/tests/accounts.rs`, `existence_and_code`: a call to an
  account without code fails with `CodeDoesNotExist` and its deposit is refunded; to an
  absent one with `AccountDoesNotExist`). <!-- conformance --> No flow calls an account
  without code, so the comparison does not check this rule.

### A6. CreateAccount

- **Rule:** `CreateAccount` makes a new named account; the actions after it in the receipt
  (Transfer, AddKey, DeleteAccount) act as the new account. Checked in this order, before each
  action existence, then the actor, then the action (A1):
  - the account must not exist (`AccountAlreadyExists`);
  - the id must not be implicit (`OnlyImplicitAccountCreationAllowed`; NEAR-implicit,
    eth-implicit, deterministic and, at 87+, universal ids are created only by a Transfer, A3);
  - a top-level id shorter than `min_allowed_top_level_account_length` only by the creation
    config's `registrar_account_id` (`CreateAccountOnlyByRegistrar`). That length is 65 from
    64 on and ids have at most 64 characters, so at 88 **every** named top-level id needs that
    account;
  - a sub-account only by its **direct** parent (`CreateAccountNotAllowed`): `a.b.near` by
    `b.near`, not by `near`.

  The new account has 0 balance, no code, no keys and 100 bytes; the Transfer that follows
  funds it. The receipt is atomic: a failure anywhere (a duplicate key, a failed storage check)
  reverts it all, the deposit goes back to `refund_to` or the predecessor (for a factory, the
  factory, not its user), and a waiting callback gets Failed (R4, R5). The storage check runs
  once, after all actions. The account creation charge (A3) applies on success only.
  **Fee:** the creator pays the receipt base plus each action's send and exec fee
  (create_account 500 + 7,200 Ggas at 88, "up"). The model charges the whole sum, the
  prepaid reservation, whatever the outcome. nearcore burns less on failure: it stops at
  the failing action and burns the receipt's exec fee plus the exec fees of the actions it
  attempted, refunding the rest as gas (gas money, N-gas-money); a CreateAccount on an
  existing account burns 7,308 Ggas of the batch's exec fees (measured: the receipt's
  108.06 plus create_account's 7,200).
  `[CreateAccount, Transfer, AddKey(full)]` costs what a Transfer creating a NEAR-implicit
  account costs.
- **nearcore:** `runtime/runtime/src/actions.rs:166-209` (`action_create_account`; top-level
  `:175-186`, sub-account `:190-197`, the new account `:202-208`), `:822-840` (existence and
  implicit ids); order `runtime/runtime/src/lib.rs:595-610`; atomicity and storage
  `lib.rs:946-1031`; `core/parameters/res/runtime_configs/64.yaml:2`; near-account-id 3.0.0
  `src/validation.rs:6-8`, `src/account_id_ref.rs:153-155`, `:216-221`. Fees
  `runtime/runtime/src/config.rs:98-108`, `:143`; on failure `lib.rs:588-592` (each action
  burns its exec fee as it starts), `:1001-1003` (the loop stops), `:1299-1309` (the gas
  refund).
- **Model:** an ACCOUNT receipt (`m = ACCT`, `IsAcctRcpt`) holds `[CreateAccount]?
  [Transfer(dep)]? [key actions]* [DeleteAccount]?`, recorded in its `ac` field.
  `CreateAcctRcpt(id, tx, new, fr, a, dep, cb)` builds a create; `NearKeys.WithAcctKeys` adds
  key actions; `ExecAcct` (or `NearKeys.ExecAcctK`, with keys) runs it, in the rule's order
  (`AcctErr`, then `AcctStorOK`). Toy ids carry no structure, so the model states it:
  `AcctParent` (overridable; `Parents({<<child, parent>>, ...})`, default every account
  top-level) and `TopCreator` (the `registrar_account_id`, overridable) (N-acct-ids). The
  receipt's `gf` is its whole send + exec fee, the reservation (`AcctFee`). An ACCOUNT receipt
  never creates an implicit account: a batched Transfer to an absent id fails (A4;
  N-universal). A call receipt can carry a CreateAccount too, the factory batch (A8), and
  either kind of receipt a DeployContract (A9).
- **Validated:** sim (`conformance/tests/lifecycle.rs`: `create_account_rules`,
  `create_batch_atomic`, with the early-failure burn, `account_action_fees`);
  `examples/platform-selftest` (the `acct_` scenarios).

### A7. DeleteAccount

- **Rule:** `DeleteAccount(beneficiary)` must be the receipt's last action. It needs the
  account to exist, the actor to be the account itself (`ActorNoPermission`; so only the
  account's own transactions and receipts, or a CreateAccount earlier in the batch), no locked
  balance (`DeleteAccountStaking`), and storage minus the contract code (from 85 also minus a
  global contract's identifier) at most 10,000 bytes (`DeleteAccountWithLargeState`). Then:
  - the liquid balance, if > 0, goes to the beneficiary as a balance refund, a **separate
    receipt** from `system` that runs later. A refund never creates an account: if the
    beneficiary is absent (an implicit id included), or is the deleted account itself, the
    amount is **burnt**;
  - the account record, its code, keys and contract data are removed, and the storage check is
    skipped;
  - **not removed:** postponed receipts, received data and yields addressed to the account,
    which are keyed by account id. While the account is deleted they fail when they run
    (`AccountDoesNotExist`); once it is created again they run against the **new** account.

  A receipt made of this one action, created by a receipt (a contract deleting itself, a
  delegate's inner action), is instant: it runs right after its creator (S5).

  Receipts that reach a deleted account: a call, a key action and a Stake fail with
  `AccountDoesNotExist`; a Transfer fails and its deposit is refunded to its sender, unless
  the id is implicit, in which case the Transfer creates it again (A3, a NEAR-implicit one
  with its key); a refund to it is burnt. A deleted account cannot sign
  (`SignerDoesNotExist`). An account created again is a new account: no code (unless
  eth-implicit), no keys, no data.
- **nearcore:** `runtime/runtime/src/actions.rs:330-406` (`action_delete_account`; large
  state `:342-369`, payout `:380-386`), `:776-790` (actor, staking),
  `runtime/runtime/src/action_validation.rs:139-142` (last action);
  `core/primitives-core/src/account.rs:248`; `core/store/src/utils/mod.rs:504-575`
  (`remove_account`); refund burn `runtime/runtime/src/lib.rs:1046-1054`; signer
  `runtime/runtime/src/verifier.rs:170-175`.
- **Model:** `DeleteAcctRcpt(id, tx, acct, a, b, cb)` (or `WithDeleteTo(r, b)` on an ACCOUNT
  receipt or, after its call, on a call receipt, A8; a second DeleteAccount is an Assert), run by `ExecAcct` / `NearKeys.ExecAcctK`. On success the account joins the
  platform variable `deleted` (a later creation removes it again); `near` and `stor` become 0,
  `NearKeys` clears its keys, and a `REFND` receipt from `"system"` carries the payout
  (`ExecTransfer` credits a present beneficiary, `RefundBurn` burns it otherwise).
  `CallTargetOK`, `ExecStake`, `ExecKeyAct`, `CanSubmit` and `DelegErr` refuse a deleted
  account even with `CallsNeedCode = FALSE`. The large-state check reads `stor`, so it needs
  `StoragePerByte` and the code bytes: `CodeSize` for the code at the start, `CodeLen` for
  deployed code (A9, N-delete-large). A deleted account loses its deployed code (`code`). The library wipes only its own state; the
  model resets its own variables for the account, using `DeletesAcct(r)` (N-wipe).
- **Validated:** sim (`conformance/tests/lifecycle.rs`: `delete_beneficiary`,
  `delete_actor_and_staking`, `delete_large_state`, `receipts_to_deleted`,
  `recreate_clears_keys_and_data`, `delete_leaves_postponed_callback`,
  `delete_leaves_received_data`, `delete_leaves_yield`); `examples/platform-selftest` (the
  `del_`, `recreate` and `stale_cb_recreate` scenarios); `examples/account-lifecycle`.

### A8. Account actions in a call receipt

- **Rule:** A receipt may hold account actions and function calls together: a factory sends
  `[CreateAccount, Transfer, AddKey?, FunctionCall(init)]` to the new account, and a contract
  may end a call to itself with `DeleteAccount`. The actions run in order, each checked as in
  A6 and A7, so a failing CreateAccount or AddKey stops the receipt before the call starts,
  and the DeleteAccount's checks (actor, staking, 10,000 bytes) see the state the call left.
  The call runs on the account the earlier actions left: after a CreateAccount that is a new
  account with **no code**, so `init` fails (`CodeDoesNotExist`) unless the batch deploys code
  first (DeployContract, A9). The receipt is atomic (A6): a failure anywhere reverts
  all of it and the deposit goes back to the predecessor, the factory. The storage check runs
  once, after all actions, and is skipped if the receipt deleted the account. The receipt's
  result is its **last action's**: after a `DeleteAccount` that is empty bytes, whatever the
  call returned; a returned promise is then not the result either (its receipt is still
  created and runs, but the receipt's callback gets the empty bytes, not the promise's
  result). The call's attached deposit is its own (often 0), not the batch's Transfer.
- **nearcore:** `runtime/runtime/src/lib.rs:946-1005` (the actions in order, the loop stops at
  the first failure, `:1001-1003`), `:507-513` (`ActionResult::merge` keeps the last action's
  result), `:1172-1175` (a result other than a value or a promise gives the callback empty
  bytes), `:1245` (`ReturnData::None` is `SuccessValue([])`), `:1008-1031` (the storage check,
  skipped at `:1010`); `runtime/runtime/src/actions.rs:202-208` (the new account has no code);
  `runtime/runtime/src/verifier.rs:213-217` (a function-call key signs one FunctionCall only);
  `runtime/runtime/src/function_call.rs:273` (the call's attached deposit is the
  FunctionCall's own); `lib.rs:1146-1189` (output receivers are forwarded only to a returned
  promise that is the result).
- **Model:** `WithCreate(r)` puts a CreateAccount (and, if `r.dep > 0`, a Transfer of `r.dep`)
  before the call of a call receipt `r`; `WithDeleteTo(r, b)` puts a DeleteAccount after it;
  `NearKeys.WithAcctKeys` adds key actions. Such a receipt has the `ac` field (`HasAc`,
  `AcCall`) and is run by `Exec` (with key actions by `NearKeys.ExecK`, read with `OkK`; plain
  `Exec` asserts on key actions). `WithCreate` moves `r.dep` into the Transfer (`ac.xfer`) and
  sets the call's own deposit `r.dep` to 0, which is what a handler reading `r.dep` sees; set
  `r.dep` after `WithCreate` for a call deposit as well. The receipt carries both
  (`DepTotal`): credited at once, refunded together on failure, paid by the signer of a
  transaction, counted by `NearConserved`. `near[r.to]` is the balance before the receipt;
  the balance the call sees (`env::account_balance`) is `BalSeen(r)`: that balance after the
  earlier actions (0 for a new account, plus the Transfer) plus the call's attached deposit
  (`function_call.rs:269`; `runtime/near-vm-runner/src/logic/logic.rs:45-49`). `Verdict` gets a first branch: the
  account actions' checks (`AcCallErr`, which is `AcctErr` with the call's and the keys' bytes
  for the delete's large-state check) fail the receipt before anything else; then
  `CallTargetOK` on the account after the create and the deploy (`CodeSeen`: no code, the
  call fails unless `CallsNeedCode <- FALSE`, also when the id was deleted before); then the
  usual order. Without either, `CallTargetOK` fails a call to a missing, deleted or
  uninitialised receiver whatever `CallsNeedCode` says. This
  branch is deterministic, so it never yields "either", and `Ok` / `Committed` read the commit
  as before (a delete's payout is not one of the call's children). `Affordable`
  (`AcAffordable`): a new account starts at 0 balance and 100 bytes, plus the keys' and the
  call's bytes, and the storage half is skipped when the receipt deletes the account.
  `Commit` (`CommitAc`) applies the call's effects and the account actions' together: the new
  account joins `created` with the deposit and bytes, a deleted one joins `deleted` with its
  payout as a `REFND` receipt after the call's children, and the callback gets empty bytes
  after a DeleteAccount; a call that returns a promise there keeps its children, and a child
  it wired to `r.cb` (`tail.cb := r.cb`) gets `cb` 0 instead (the callback already has its
  empty bytes). `gf`: the call's
  fee (`GasCall`, the receipt base included) plus the account actions' send and exec fees
  (`AcctActsFee`, and the key actions'); a calibrated burn for such a flow must leave those
  out. A function-call key cannot sign a transaction with account actions (`KeyCanSign`).
  A `[FunctionCall, DeleteAccount]` receipt is not instant (S5).
- **Validated:** sim (`conformance/tests/lifecycle.rs`, `call_then_delete_result`: `[get,
  DeleteAccount]` returns empty bytes where `get` alone returns the value;
  `promise_call_then_delete`: `[near_withdraw, DeleteAccount]`, whose call returns a Transfer
  promise, succeeds with empty bytes and the Transfer still runs;
  `batch_call_sees_own_deposit`: `near_deposit` after `[CreateAccount, Transfer(5 NEAR),
  DeployContract]` with deposit 0 panics "Requires positive attached deposit");
  `examples/platform-selftest` (`selftest_accall`, `selftest_accall_code_off`,
  `selftest_accall_storage`, and `acct_fee` in `selftest_lifecycle_gas`);
  `examples/account-lifecycle/factory`.

### A9. DeployContract

- **Rule:** `DeployContract(code)` sets the account's code. The account must exist and be
  initialised, and the actor must be the account itself (`ActorNoPermission`): its own
  transactions and receipts, or a CreateAccount earlier in the receipt, the factory batch
  `[CreateAccount, Transfer, DeployContract, FunctionCall(init)]`. The old code's bytes leave
  the storage usage and the new code's bytes join it; the contract's data stays. A
  FunctionCall later in the receipt runs the new code. The storage check runs once, after all
  actions (A6), so a deposit that does not cover the code fails the whole receipt
  (`LackBalanceForState`). A DeleteAccount after it subtracts the new code from its
  10,000-byte check (A7); the deleted account loses its code, and an account created again
  has none. At most 10 deploys per receipt and 4 MiB per contract (R6).
  **Fee:** `deploy_contract_base` (185 + 185 Ggas at 88, "up") plus `deploy_contract_byte`
  per byte (send 6.8 Mgas on the same account, 47.7 on another; exec 64.6).
- **nearcore:** `runtime/runtime/src/actions.rs:290-328` (`action_deploy_contract`: the old
  code's bytes cleared at `:300`, the new length added at `:302-310`), `:426-451`
  (`get_contract_storage_usage`, `clear_account_contract_storage_usage`), `:755-776` (actor),
  `:862-887` (existence, initialised); dispatch `runtime/runtime/src/lib.rs:624-636`; fees
  `runtime/runtime/src/config.rs:99-108` (send), `:343-350` (exec); limits
  `runtime/runtime/src/action_validation.rs:21-37`, `:128-129` (deploys per receipt, new
  receipts only), `:305-318` (`max_contract_size`),
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:245`,
  `:250`; the code removed with the account `core/store/src/utils/mod.rs:504-510`.
- **Model:** a code is a tag (a string), its size `CodeLen[t]` (overridable, default 0
  bytes). The platform variable `code` is a partial function from account to the tag deployed
  at run time; `CodeOf(a)` reads it, else the code at the start (`InitCode`, default
  `"code"`, for the accounts in `Contracts`), and `HasCode` is unchanged while nothing is
  deployed. An eth-implicit account created at run time by a Transfer, also one created
  again after a deletion, has the protocol's wallet contract, `EthWalletCode` (overridable,
  default `"eth_wallet"`; `actions.rs:255-268`), not its initial or deployed code, and
  whether or not it is in `Contracts`. `WithDeploy(r, t)` adds DeployContract(t) to an
  ACCOUNT receipt or a call receipt, after its CreateAccount and Transfer and before its
  call and DeleteAccount, and adds its fee to `gf`; `DeployRcpt(id, tx, acct, a, t, cb)` is a lone deploy. The checks are
  `AcctErr`'s (existence, initialised, actor); the bytes are `stor` less the old code
  (`CodeBytes`: the deployed tag's `CodeLen`, else `CodeSize`) plus the new one (`DplDelta`),
  checked by `AcctStorOK` / `AcAffordable`; on success `code` maps the account to `t`
  (`CodeNext`; a delete or a create without a deploy removes it). The call sees `CodeAfter(r)`
  (`CodeSeen`), and so does `NearKeys.FailNoCode`. The handler is still the model's TLA+
  code: a model whose contract changes at run time branches on `CodeOf(r.to)`. A receipt has
  at most one deploy (a second `WithDeploy` is an Assert); a tag whose `CodeLen` exceeds
  4 MiB is an Assert.
- **Validated:** sim (`conformance/tests/lifecycle.rs`, `deploy_storage_delta`: usage less
  the old code plus the new, data kept, ActorNoPermission, 10 deploys pass and 11 are refused,
  a factory batch whose deposit does not cover the code fails); `examples/platform-selftest`
  (`selftest_deploy`, `selftest_deploy_storage`, the deploy fees in `acct_fee`);
  `examples/account-lifecycle/factory` (`factory_underfunds_code`, `factory_funds_code`).

### A10. Global contracts (NEP-591)

- **Rule:** `DeployGlobalContract(code, mode)` publishes code for other accounts to run, by
  its hash (`CodeHash`) or under the deploying account's id (`AccountId`). Only the account
  itself may send it (`ActorNoPermission`). It burns 0.0001 NEAR per code byte (ten times the
  storage rate) from the account's balance, `LackBalanceForState` if the balance is short, and
  adds nothing to the account's storage or code. The code is published by a separate
  distribution receipt the deploy emits: until that receipt runs, the identifier does not
  resolve (or still resolves to the previous code). Each deploy bumps the identifier's nonce
  stored on the deployer's shard, and a shard applies a distribution only if its nonce is not
  below the one it stores, so the later of two deploys wins; on the deployer's shard an
  earlier distribution arriving after a later deploy is dropped at once. `UseGlobalContract(identifier)` switches the account to a
  published global contract (`GlobalContractDoesNotExist` otherwise): the old contract's bytes
  (a local code's length, or the old identifier) leave its storage usage and the identifier's
  bytes join it, 32 for a hash and the owner id's length for an account id; a local
  DeployContract later does the reverse; the account's data stays. A by-account identifier is
  resolved when each receipt runs, so the owner's redeploy reaches every user at once, a
  callback already in flight included; a by-hash user keeps its code. The DeleteAccount
  10,000-byte check subtracts the identifier as it does local code (A7). The owner's deletion
  leaves the published code in place for its users; an owner created again under the same id
  publishes over it. A failed batch burns nothing (the burn is part of the reverted state).
  **Fee:** `deploy_global_contract` base (185 + 185 Ggas, "up") plus per byte (send 6.8 Mgas
  on the same account, 47.7 on another; exec 70); `use_global_contract` base (185 + 185) plus
  per identifier byte (send 6.8 / 47.7, exec 64.6). The distribution's compute (20 Tgas plus
  250 Mgas per byte) is chunk-level, not gas (N-compute).
- **nearcore:** `runtime/runtime/src/global_contracts.rs:25-63` (`action_deploy_global_contract`:
  the burn `:35-51`), `:76-109` (`use_global_contract`: existence `:83-90`, the old contract
  cleared `:91-94`, the identifier's bytes `:99-106`), `:143-189` (`initiate_distribution`,
  the nonce bumped at `:175-189`), `:191-246` (`apply_distribution_current_shard`),
  `:251-269` (`check_and_update_nonce`: older nonces dropped), `:288-333` (forwarded shard by
  shard); the distribution receipt `core/primitives/src/receipt.rs:538-548`; identifier bytes
  `core/primitives-core/src/account.rs:182-188`; the delete check
  `runtime/runtime/src/actions.rs:342-369` (the identifier's bytes subtracted, `:426-440`); actor `:755-812`; dispatch
  `runtime/runtime/src/lib.rs:637-660`, the call's contract resolved at `:684-700`; fees
  `runtime/runtime/src/config.rs:171-191` (send), `:380-395` (exec),
  `core/parameters/res/runtime_configs/77.yaml:2-50`; compute `84.yaml:39-40`; validation
  (size, deploys per receipt) `runtime/runtime/src/action_validation.rs:21-37`, `:319-335`.
- **Model:** identifiers are `GHash(t)` (a code tag's hash: a function of the tag) and
  `GAcct(a)`; `IdLen` gives their bytes (32, or `Len(a)`: toy ids give toy lengths). Three
  platform variables: `gcode` (identifier to published tag), `guse` (account to the identifier
  it runs) and `gnonce` (identifier to the nonce of the last distribution applied).
  `CodeOf(a)` reads `code`, then `GCodeOf(guse[a])` (resolved in the current state, so a
  callback sees the code published when it runs), then `InitCode`; `CodeBytes` counts the
  identifier. `WithDeployGlobal(r, t, md)` (`md` is `"hash"` or `"acct"`) adds the deploy to an
  ACCOUNT receipt; `WithUseGlobal(r, g)` adds the use to an ACCOUNT receipt or a call receipt
  (the factory batch `[CreateAccount, Transfer, UseGlobalContract, FunctionCall(init)]`: the
  call sees the global code, `CodeAfter`); `DeployGlobalRcpt` and `UseGlobalRcpt` are lone
  ones. `AcctErr` checks existence, actor, the burn (`LackBalanceForState`) and, for a use,
  that `gcode` has the identifier now. The burn is `GlobalBurn(CodeLen[t])` at
  `GlobalByteCost` (default `<<1, 10000>>`: 0.0001 per byte at 1 unit = 1 NEAR; exact, an
  Assert if it is not a whole number of units); it leaves the balance at commit and joins the
  ghost `burnt`, so `NearConserved` holds. The deploy emits a `GDIST` receipt (a built-in:
  `ExecBuiltin` runs it, `ExecGDist`) whose id is its nonce; it sets `gcode` if its nonce is
  above `gnonce`'s. The model's network has no order, so two distributions of one identifier
  arrive either way: the later deploy wins, and the earlier code may be published briefly
  first (as on a shard other than the deployer's). `gnonce` moves only when a distribution
  is applied, not at the deploy as on the deployer's shard: an over-approximation, since the
  model can publish the earlier code briefly where nearcore drops it. `InitGCode` and `InitUses` (overridable)
  set what is published, and who uses it, at the start. `GlobalInstant <- TRUE` publishes at
  the deploy's commit, without the receipt (unsound: N-global-instant). A receipt has at most
  one of each global action, and not a DeployContract together with a UseGlobalContract
  (Asserts). The handler is the model's TLA+ (N-upgrade): a contract that changes under a user
  must dispatch on `CodeOf(r.to)`.
- **Validated:** sim (`conformance/tests/global.rs`: `deploy_global`, `use_global_storage`,
  `redeploy_updates_users`, `delete_large_state_by_account`, `update_while_callback_in_flight`);
  `examples/platform-selftest` (`selftest_global`, the global fees in `acct_fee`);
  `examples/account-lifecycle/factory` (`factory_global`); `examples/account-lifecycle/global-upgrade`.

---

## Signer and access keys

### K1. Signer and signer public key propagate

- **Rule:** Every receipt a transaction spawns, at any depth and including callbacks, carries
  the transaction's `signer_id` and `signer_public_key`. A contract sees them as
  `signer_account_id` / `signer_account_pk`. They are distinct from `predecessor_account_id`, the
  immediate caller.

  **Carve-out: refunds.** Refund receipts are created by the runtime, not copied from the parent.
  A deposit (balance) refund has signer `"system"` and an empty ED25519 key. A gas refund has the
  refund's receiver (the original signer) as signer, with the original signer key, so that it
  can top up that key's allowance. Neither runs contract code, so no contract can observe the
  difference.
- **nearcore:** `runtime/runtime/src/function_call.rs:172-174` (copied into every child receipt),
  `:258-260` (exposed in `VMContext`), `:262` (predecessor); refunds:
  `core/primitives/src/receipt.rs:496-509` (`new_balance_refund`), `:518-536`
  (`new_gas_refund`).
- **Model:** `SignerOf(tx)` / `Signer(r)` / `SignerKey(r)`, set by `Submit` / `SubmitAs(r, a, k)`
  `Submit(r)` with no key info uses signer = `r.fr` and `DefaultKey`. `TrackSigner <- FALSE`
  stops recording it, for models that never read the signer (smaller state space). `Signer(r)` is
  per transaction, so on a `REFND` receipt it returns the transaction's signer, not
  `"system"`. That is harmless because refunds run no contract code; do not use `Signer(r)` of a
  refund in an invariant.
- **Validated:** sim (`conformance/tests/semantics.rs`, `signer_propagates_to_children_and_callbacks`:
  a cross-contract child and a callback see the signer and the key that signed, and their
  own creator as predecessor). The refunds' signer: nearcore reading (refunds run no code).
  <!-- conformance --> The comparison does not see the signer.

### K2. Full-access versus function-call keys

- **Rule:** A transaction is signed with an access key of the signer. A full-access key allows
  any actions. A function-call key allows only a transaction with **exactly one action**, a
  FunctionCall, with **zero deposit**, to the key's `receiver_id`, and, if the key's method list
  is non-empty, to one of those methods. Anything else is an invalid transaction: no receipt is
  created. A function-call key may carry an allowance: the transaction's full cost (gas plus
  deposit) is taken from it, the transaction is invalid if the allowance is short, and gas
  refunds to that key add back to it.

  **Exception (no key):** a self-signed state-init transaction on an uninitialised account
  (the universal-account bootstrap) is accepted without any access key.
- **nearcore:** `runtime/runtime/src/verifier.rs:209-250` (`verify_function_call_permission`),
  `:282-303` (`check_and_compute_new_allowance`: `checked_sub`, so an allowance equal to the
  cost is enough), `:365-394` (call order in `verify_and_charge_tx_ephemeral`), `:402` (the new
  allowance), `:177-194` (`AccessKeyNotFound`; bootstrap at `:184-186`), `:200-202`
  (`is_bootstrap`); `runtime/runtime/src/config.rs:515-536` (`total_cost`);
  `runtime/runtime/src/actions.rs:133-157` (`try_refund_allowance`), called for each gas
  refund at `runtime/runtime/src/lib.rs:3041-3047`.
- **Model:** `NearKeys`: `KeyAllows`, `KeyCanSign`, `SubmitSigned`, `Perm`, `FullPerm`. For a
  function-call key it checks the receiver, the method (an empty list allows every method,
  `verifier.rs:238`), zero deposit, and that the transaction is a single function call (no
  Transfer, Stake or key action, no multi-call receipt). An allowance is opt-in:
  `WithAllowance(p, n)` gives a function-call key one. `SubmitSigned` and `SubmitTx` (K5)
  refuse a transaction whose cost exceeds it (`AllowanceOK`; `TxErr` gives
  `NotEnoughAllowance`) and charge the cost with the refund added back at once (`Charged`).
  `WithTxCost(r, c, f)` states a transaction's cost `c > 0` and refund `0 ≤ f ≤ c`; a
  transaction signed with a key that has an allowance must carry it (`TxCost` is an `Assert`
  otherwise), since nearcore's cost is never 0. An AddKey of a key with an allowance under a
  key id that has signed a transaction, and still there after its receipt, is an `Assert`
  (`AllowanceAddOK`): nearcore would add the old transactions' late refunds to the new key. The refund's timing is in N-allowance. It does not check key actions a model bundles into a call
  receipt (N-fckey-one-action). There is no bootstrap path.
- **Validated:** sim (`conformance/tests/accounts.rs`, `function_call_key_scope`: one
  zero-deposit FunctionCall to the key's receiver and methods, an empty list allowing every
  method; a deposit, another receiver or method, two calls or a Transfer refused at
  conversion with no receipt; the allowance charged the transaction's cost with the gas
  refund added back, and `NotEnoughAllowance` when it is short;
  `allowance_charge_refund_and_boundary`: conversion lowers the allowance by exactly the
  transaction's cost, the conversion gas at the gas price plus the prepaid gas and the
  receipt's exec fees at `max(gas price, min_gas_purchase_price)`; once the transaction
  settles the allowance is its start less the tokens burnt; an allowance equal to the cost
  passes, and one yocto less is refused with `NotEnoughAllowance`, no receipt, and the key's
  nonce and allowance unchanged; a key with an allowance stores 16 bytes more). The bootstrap
  exception: nearcore reading (no test sends a state-init transaction).
  `examples/session-key` checks the model's side of the allowance, and its two `Assert`s
  (`session_cost_unstated`, `session_rekey_same_id`). The re-added key's refund: nearcore
  reading. <!-- conformance --> No
  flow signs with a function-call key, so the comparison does not check this rule.

### K3. AddKey and DeleteKey

- **Rule:** AddKey, DeleteKey, Stake, Deploy and DeleteAccount need the actor to be the account
  itself. In practice that means a transaction signed by the account, or the account's own
  promise to itself; after a `CreateAccount` in the same receipt, the new account is the actor.
  AddKey of a key that already exists fails (`AddKeyAlreadyExists`). DeleteKey of a key that does
  not exist fails (`DeleteKeyDoesNotExist`). Either failure fails **the whole receipt** (M1).
- **nearcore:** `runtime/runtime/src/actions.rs:755-801` (`check_actor_permissions`), `:202`
  (CreateAccount sets the actor); `runtime/runtime/src/access_keys.rs:157-164` (AddKey exists),
  `:83-89` (DeleteKey absent).
- **Model:** `NearKeys`: `AddKeyRcpt`, `DelKeyRcpt`, `ExecKeyAct`, `KeyPresent`. A key's
  storage bytes (`KeyBytes`, with `StoragePerByte`) are in B2.
- **Validated:** sim (`conformance/tests/accounts.rs`, `key_action_failures`:
  `AddKeyAlreadyExists`, `DeleteKeyDoesNotExist` and `ActorNoPermission`, each failing the
  whole receipt; `conformance/tests/semantics.rs`, `delete_key_batch_is_atomic`; the new
  account as actor after CreateAccount: A6). <!-- conformance --> `flows/actions.toml` only
  prices AddKey and DeleteKey (G4), and no probe flow has a key action.

### K4. Delegate actions (NEP-366, meta transactions)

- **Rule:** A relayer R sends a transaction to a user U carrying a delegate that U signed: the
  inner receiver C, the inner actions, a nonce, `max_block_height`, and U's public key. R signs
  the transaction and pays for it: its gas at conversion, and the deposits of the inner actions.
  The outer receipt (predecessor R, signer R and R's key) runs on U and checks, in order:
  - U exists and is initialised;
  - U's signature;
  - expiry: `block_height > max_block_height` fails, so the bound is inclusive;
  - the delegate's sender is U;
  - U's key exists;
  - the nonce is above the key's (any gap is fine) and below `block_height × 1e6`;
  - a function-call key allows only one zero-deposit FunctionCall to its receiver and
    methods, the same rule as for a transaction (K2). Its allowance is neither checked nor
    charged.

  A failed check is an action error of the outer receipt: no inner receipt, the key's nonce
  unchanged, and the deposit refunded to the outer receipt's predecessor, **R**. On success
  the key's nonce becomes the delegate's and the inner receipt is created:
  - its predecessor is **U** and its receiver C;
  - its signer and signer key are **R**'s, so the inner call and every receipt it spawns see
    `signer_account_id = R` (`runtime/runtime/src/function_call.rs:173-174` copies the signer
    into each child), and `predecessor_account_id = U` in the inner call only: a receipt it
    spawns sees its creator as predecessor (`:188`), so for U → C → D, D sees C;
  - it is a new outgoing receipt, never local, and has no `refund_to`;
  - if it fails, its deposit is refunded to its predecessor, **U**, not to R, who paid it.

  The relayer's transaction reports success even when the inner call fails. A function-call
  key of R cannot sign R's transaction, since a Delegate is not a FunctionCall. A receipt holds
  at most one Delegate, and a delegate cannot carry one. `DelegateV2` (gas-key nonces) is
  refused for new transactions from 87.

  Comment check: `config.rs:657-658` says a failed delegate's deposit "is refunded to Sender of
  DelegateAction". That holds only when the inner receipt fails; when the outer one fails,
  the refund (`lib.rs:1295-1303`, the same `total_deposit`) goes to the outer predecessor, R.
- **nearcore:** `runtime/runtime/src/actions.rs:453-535` (`apply_delegate_action`: signature
  `:474-477`, expiry `:479-482`, sender `:483-490`, the inner receipt `:500-512`, the deposit
  comment `:514-519`), `:579-746` (`validate_delegate_action_key`: key `:587-602`, nonce
  `:648-657`, upper bound `:659-666`, function-call key `:670-727`, nonce update `:729-733`),
  `:862-887` (account existence; Delegate at `:868`); `runtime/runtime/src/config.rs:652-668`
  (`total_deposit`: the relayer pays the inner deposits); `runtime/runtime/src/lib.rs:1295-1303`,
  `:1402-1406` (deposit refund to `balance_refund_receiver`), `:1222-1234` (new receipts are
  outgoing); `core/primitives/src/receipt.rs:343-364` (`from_tx`: the outer predecessor is the
  signer), `:428-430` (`balance_refund_receiver`: the predecessor when there is no
  `refund_to`); `runtime/runtime/src/function_call.rs:172-174` (the signer is copied to every
  child); `runtime/runtime/src/verifier.rs:213-222` (a function-call key signs one
  FunctionCall); `runtime/runtime/src/action_validation.rs:136-151` (one Delegate per
  receipt); `core/primitives/src/action/delegate.rs:371-433` (`NonDelegateAction`);
  `core/primitives-core/src/version.rs:612` (`FixDelegateActionDepositWithFunctionCallError`,
  85: the deposit check returns at once); `runtime/runtime/src/access_keys.rs:46-49`, `:240`
  (a new key's nonce is `(height − 1) × 1e6`).
- **Model:** `NearKeys`: `SignedDelegate(s, k, n, mbh, c)` (the user's signature; `c` the inner
  receipt, built with `Rcpt`, and `WithGas` in gas mode), `DelegRcpt`, `SubmitDelegate(id, tx,
  rl, k, sd)` (through `SubmitSigned`, so the relayer pays the deposit and its key is checked),
  `ExecDelegate(r)`, `DelegErr`, `DelegMayExpire` / `DelegMustExpire`, `KeyNonce`,
  `KeysWithNonce`, `NoExpiry`. `NearAsync`: the receipt kind `DELEG` and `IsDeleg`; `IsCall`
  is FALSE for it, and `Exec` on it is an `Assert`. The inner receipt stays in R's transaction,
  so `Signer` and `SignerKey` give R with no new mechanism; its predecessor and refund account
  are U, its `loc` FALSE. The outer receipt fails through `FailP`, which refunds its deposit to
  `r.rto` = R. Expiry follows the block clock (`blk > mbh`) when `MaxBlk > 0`; without a clock
  a delegate with an expiry may fail at any time. Nonces are abstract integers per key, in the
  key record, shared with the key's transactions submitted by `SubmitTx` (K5); `SubmitSigned`
  neither checks nor sets them (N-delegate-nonce). The upper bound is the model input of K5
  (`NonceTooLarge`, off by default), checked at the height the outer receipt runs. For a user outside `KeyAccts` there is no
  key, nonce or permission check. The
  signature is the modelling rule that only U's own step builds U's `SignedDelegate`.
- **Validated:** sim (`conformance/tests/semantics.rs`, `delegate_*`: the signer and
  predecessor the inner call and its children see, a replay failing on the nonce, the
  inclusive expiry with the refund to the relayer, the refund to the sender when the inner
  call fails, the key checked when the outer receipt runs, and the function-call-key checks
  on both sides; `delegate_signature_sender_and_nonce_bound`: an absent sender, a signature
  that no longer verifies, a sender other than the transaction's receiver, the nonce bound
  to the unit, `H × 1e6` failing and `H × 1e6 − 1` passing for the height H the outer receipt
  runs at, and two Delegates in one transaction; `conformance/tests/accounts.rs`,
  `transaction_nonces`: a delegate signed at nonce 8 fails with `DelegateActionInvalidNonce`
  once a direct transaction of the key at nonce 9 has been accepted). `DelegateV2` and a delegate
  carrying a delegate: nearcore reading (the action types cannot express the second).
  <!-- conformance --> The probe flow
  `relay_chain1` (`chain1` relayed by `dave.near`) compares the model with the sim receipt by
  receipt over the standard grid: the Delegate receipt, then the inner call tree, with
  statuses, attached gas and edges equal (the same edges as `chain1`). It exercises only the
  success path, and its statuses cannot show who the signer is.
  `examples/platform-selftest` (`selftest_deleg`, `selftest_deleg_gas`) checks the model's
  side.

### K5. Transaction nonces

- **Rule:** Each access key has a nonce. A transaction carries one, which must be above its
  key's (`InvalidNonce`; any gap is fine) and below `block_height × 1e6` (`NonceTooLarge`).
  Accepting the transaction sets the key's nonce to it, so the same transaction submitted
  again, or one with a nonce at or below one already accepted, is refused: no receipt, no
  charge. A refused transaction leaves the nonce unchanged, so its nonce stays free. Each key
  has its own nonce, and the key's delegates are checked against the same one (K4). The
  checks run in this order: the actions (R6), the signer and its key, the nonce (first
  `InvalidNonce`, then `NonceTooLarge`), the balance, the allowance (K2), the storage (B2),
  the function-call key's scope (K2); the first that fails names the error.
- **nearcore:** `runtime/runtime/src/verifier.rs:254-280` (`verify_nonce`: `:261-264`
  `InvalidNonce`, then `:271-278` `NonceTooLarge` against `block_height ×
  ACCESS_KEY_NONCE_RANGE_MULTIPLIER`, 1e6 at `core/primitives-core/src/account.rs:812`), `:92-104` (the actions), `:164-195` (signer and
  key), `:343-393` (nonce, balance, allowance, storage, permission), `:402` (the new nonce,
  applied at `runtime/runtime/src/lib.rs:350-352`); `runtime/runtime/src/actions.rs:648-657`
  (a delegate against the same nonce).
- **Model:** `NearKeys`: `SignedTx(a, k, n, r)` is a signed transaction as a value, which any
  step may submit any number of times. `TxErr(st)` is the first check that refuses it, in
  nearcore's order, or `""`: `TotalNumberOfActionsExceeded`, `SignerDoesNotExist`,
  `AccessKeyNotFound`, `InvalidNonce`, `NonceTooLarge`, `NotEnoughBalance`, `NotEnoughAllowance`,
  `LackBalanceForState`, `AccessKeyError` (the scope); the balance covers the deposits
  only, as in `CanSubmit` (N-gas-money). `SubmitTx(st)` requires `TxErr(st) =
  ""`, submits `st.r` signed by `a` with `k`, sets the key's nonce to `n` and charges its
  allowance. A model branches on `TxErr` to see a refusal (`examples/tx-nonce`). Nonces are
  abstract integers in the key record (`KeyNonce`, 0 for a new key). The model's heights
  (`blk`, from 0) and nonces are not on nearcore's scale, so the upper bound is a model
  input: `NonceTooLarge(n)` is `n ≥ NonceCeiling(blk) = (NonceHeight0 + blk) ×
  NoncePerHeight`, and the default `NonceHeight0 = −1` turns it off (`NoncePerHeight` is
  nearcore's 1e6 unless a model scales it down). `Submit` and `SubmitSigned` check no
  nonce, and a signer outside `KeyAccts` has none (N-tx-validity).
- **Validated:** sim (`conformance/tests/accounts.rs`, `transaction_nonces`: a nonce 5 above
  the key's is accepted and becomes the key's nonce; the same transaction again, and an
  unused lower nonce, are refused with `InvalidNonce`, no receipt and the nonce unchanged; a
  transaction refused for its balance leaves its nonce free, and the next one with it is
  accepted; a second key of the account keeps its own nonce; a delegate below a direct
  transaction's nonce fails, K4). The order of the checks and `NonceTooLarge` for a
  transaction: nearcore reading (the delegate's bound is sim, K4). `examples/tx-nonce`
  checks the model's side, the ceiling included (`nonce_below_ceiling`,
  `nonce_too_large`). <!-- conformance --> No flow sets a nonce.

### M1. Multi-action receipts are atomic

- **Rule:** The actions of one receipt run in order, and the first failure stops the loop
  (later actions do not run). Then the receipt's whole state change rolls back, including the
  earlier actions' effects, and none of their receipts are sent. What survives a failed receipt:
  - the gas it burnt;
  - its logs;
  - the deposit refund receipt (R5);
  - the gas refund receipt to the signer (`prepaid − burnt`, G5);
  - a `Failed` data receipt to each waiting callback (C1).
- **nearcore:** `runtime/runtime/src/lib.rs:946-1005` (loop; `break` at `:1001-1003`),
  `:1084-1087` (rollback), `:535-541`; survivors: `:1402-1415` (refunds), `:1171-1189` (data
  receipts are built after rollback from the error).
- **Model:** `NearKeys`: `ExecWithKeys`, `KeyActsOK`, `WithKeyActs`. Token batches: `"batch"`
  in the token modules is one atomic receipt (a deposit mismatch fails the receipt); its gas
  is accounted per action, with burn keys `"<acct>.batch/<shape>#<method>"` (G3); a
  single-call batch uses `"<acct>.batch/<shape>"`. `TokBatchPerAction <- FALSE` makes it one
  pool with the whole-batch key (N-batch-oog).
- **Validated:** the per-action gas of a token batch: sim (`ft_batch_*`, `wnear_batch_*`; it
  shows in the batches ending in `ft_transfer_call`, whose `ft_on_transfer` gets only that
  call's leftover: mismatch 4 in the conformance log). No flow fails a batch part way. The
  atomicity, the loop stopping at the first failure and what survives: sim
  (`conformance/tests/semantics.rs`, `delete_key_batch_is_atomic`: DeleteKey with a call, both
  orders; `conformance/tests/accounts.rs`, `key_action_failures`;
  `conformance/tests/receipts.rs`, `failed_receipt_reverts_and_drops_children` for the logs
  and burnt gas, `deposit_and_gas_refunds` for the refunds, `data_receipt_carries_one_result`
  for the `Failed` data). <!-- conformance -->

---

## Scheduling

### S1. Local receipts first: the exact rule

- **Rule:** A chunk first converts its transactions, each into exactly one receipt. If that
  receipt's **receiver equals the transaction's signer**, it is a *local receipt*. Local
  receipts run in the same chunk, in transaction order, before any delayed or incoming receipt.
  Otherwise the receipt is sent out and runs in a later chunk.

  **Unless the chunk is full.** A local receipt that finds the chunk's compute limit or
  storage-proof limit already reached is pushed to the **back of the delayed queue**. Delayed
  receipts run before new work in later chunks, so every receipt already in the delayed queue
  runs **before** it.

  The rule covers only a transaction's **first** receipt. Receipts created while executing a
  receipt (self-calls, callbacks, refunds) are never local: they go out through
  `forward_or_buffer_receipt`, except *instant* receipts, which run before all of them (S5).
- **nearcore:** `runtime/runtime/src/lib.rs:2317-2324` (`if receipt.receiver_id() == signer_id
  { local_receipts.push_back(receipt) } else { forward_or_buffer_receipt }`), `:2787-2826`
  (`process_receipts`: local `:2800`, then delayed `:2808`, then incoming `:2816`, then yield
  timeouts `:2825`), `:2513-2521` (limit reached: push to delayed),
  `runtime/runtime/src/congestion_control.rs:864` (`queue.push_back`), `:1222-1230` of
  `lib.rs` (receipts created by a receipt: instant or outgoing).
- **Model:** `LocalPriorityOK(r)` / `Schedulable`, an opt-in operator the contract conjoins
  (or it draws receipts from `Schedulable`). It forbids running a non-local receipt to account
  `a` while a local receipt to `a` is pending. It assumes the chunk is never full.
- **Trade-off and recommended practice:**
  - **Switch ON** encodes the uncongested case. It is an **under-approximation** when the
    receiving chunk is at its compute or proof limit: nearcore then runs already-delayed
    receipts before the local one, and `LocalPriorityOK` forbids exactly that order (see
    N-local-congested). Use it to rule out orders that cannot happen on an idle shard.
  - **Switch OFF** is the conservative setting: it explores every causally enabled order,
    including the ones congestion makes reachable. A stale-key ordering (a receipt running
    against an access key that a self-signed key change would already have replaced on an idle
    shard) is one of them: it cannot happen on an idle shard, but it can when the local
    receipt is delayed.
  - Run safety properties **with the switch OFF as well**. A violation that appears only with
    the switch OFF is real under congestion unless you can argue the receiving chunk cannot be
    at its limit; do not dismiss it without that argument.
- **Validated:** sim (`conformance/tests/semantics.rs`: `local_receipt_runs_before_incoming`,
  `contract_self_call_is_not_local`; and `local_receipt_delayed_when_chunk_full`: with the
  1000 Tgas chunk full, the local receipts past the limit go behind the receipts already
  delayed, which run first a block later, the order `LocalPriorityOK` forbids,
  N-local-congested). The storage-proof limit: nearcore reading. <!-- conformance --> The
  comparison does not see order.

### S2. Ordering otherwise

- **Rule:** Beyond R2 (a callback waits for its inputs) and S1, the model lets any enabled
  receipt run next. nearcore's order at protocol 88 is about chunks, not accounts:
  - a chunk runs local receipts (S1), then the delayed queue, then the incoming receipts, then
    yield timeouts;
  - the delayed queue is one strict FIFO per shard, and incoming receipts never overtake it:
    once a chunk reaches its compute or proof limit, every remaining incoming receipt goes to
    the back of the queue, in order;
  - incoming receipts run in the order of the chunk's incoming list. Within one receipt proof
    (one source chunk to one destination shard) they keep their order; proofs from different
    source shards in one block are shuffled, and a chunk after missed chunks takes the
    receipts of the newest source block first.

  None of this orders receipts by sender and receiver: there is no per-pair FIFO (S4). The
  model has no chunks or shards, so it encodes none of these rules. Some same-pair reorders
  are reachable (S4), but not every order the model allows: receipts in one receipt proof
  keep their order, for one. What the model allows beyond nearcore, within a pair or not, is
  the over-approximation N-shards.
- **nearcore:** `runtime/runtime/src/lib.rs:2787-2826` (`process_receipts`: local `:2800`,
  delayed `:2808`, incoming `:2816`, timeouts `:2825`), `:2694-2711` (incoming in list order;
  over the limit, pushed to the delayed queue), `core/store/src/trie/receipts_column_helper.rs:83-119`
  (`push_back` / `pop_front`), `chain/chain/src/sharding.rs:13-21` (`shuffle_receipt_proofs`),
  `chain/chain/src/stateless_validation/chunk_validation.rs:478-480` ("from the newest blocks
  to the oldest") and `:509-514` (shuffle per block, then each proof in order),
  `runtime/runtime/src/congestion_control.rs:292-325` (`forward_or_buffer_receipt`, S4).
- **Model:** `\E r \in Runnable : ...` (or `Schedulable`) in `Next`.
- **Validated:** nearcore reading. The per-pair part is observed in the sim (S4), and, in a full
  chunk, the delayed receipts running before local ones that overflowed it (S1,
  `local_receipt_delayed_when_chunk_full`).
  The rest is not sim-testable: the sim has one shard, so no proofs from several source
  shards, and it misses no chunks.

### S3. Block clock

- **Rule:** Every receipt in a chunk sees that block's height (`env::block_height()`) and
  timestamp (`env::block_timestamp()`, nanoseconds); both only grow. A receipt created by a
  receipt runs in a later block, except instant receipts. The epoch height is separate, set
  by the epoch manager outside the runtime.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:827` (`block_index` returns
  `block_height`), `:837` (`block_timestamp`), `:847` (`epoch_height`);
  `runtime/runtime/src/lib.rs:1222-1234` (created receipts are instant or outgoing).
- **Model:** the platform variable `blk`, advanced only by `BlockTick` (which a model adds to
  `Next`), bounded by `MaxBlk` (default 0: no clock, `blk` stays 0). `BlockTs == TsOf(blk)`,
  with `TsOf` an overridable strictly increasing function (default the identity). Any number
  of receipts may run at one height, a callback even at its creator's height, and any number
  of blocks may pass between two receipts (no latency bound). `TickAnytime` (default TRUE)
  lets a block pass at any time; FALSE only while some yield's deadline is ahead, which is
  exact only when no handler reads `blk` or `BlockTs`. `BlockTick` is independent of
  `EpochTick`. The bound has two consequences, each with its own check (invariants to add):
  - **Premature timeouts (an over-approximation).** At `blk = MaxBlk` every pending yield
    may time out, so a deadline beyond the bound is still reachable, but early.
    `YieldDeadlinesInBound` fails when a pending yield's deadline exceeds `MaxBlk`; while it
    holds no timeout in the run is premature, so a violation the run finds is not an artefact
    of the bound. It says nothing about coverage. With `TickAnytime = TRUE` it fails whenever
    a yield can be created within `YieldTicks` blocks of the bound.
  - **Missing later behaviour (an under-approximation, N-clock-horizon).** The clock stops at
    `MaxBlk`, so nothing that needs a later height is explored: a guard of the model that
    opens past the bound, or a timeout delayed past it (nearcore can process a timeout late,
    `runtime/runtime/src/lib.rs:3129-3147`, and it then sends an outgoing resume receipt,
    `:3163-3201`). A pass is a pass up to `MaxBlk` only. `ClockHorizonOK(n, T)` holds when
    `MaxBlk >= (n + 1) * max(T, YieldTicks)`. `T` is the largest number of blocks any
    comparison with the clock counts (in handlers, guards or invariants; `blk > h + c` and
    `blk = h + c` count `c + 1`, a comparison with a yield's deadline counts
    `YieldTicks + c`); `n` is the most clock-relevant steps in one behaviour (steps that read
    or record `blk` or `BlockTs`, yield creations, yield callbacks). If every comparison is
    `x - h >= c` or its negation, with `h <= x` each 0, `blk` or a height recorded earlier in
    the behaviour, that bound covers every behaviour. Argument: an invariant fails in the last
    state of some behaviour on an unbounded clock. Its `n` clock-relevant steps and that last
    state split the heights into `n + 1` gaps: from 0 to the first step, between steps, and from
    the last step to the final observation. Cut each gap to `K = max(T, YieldTicks)` blocks,
    dropping the ticks at its end. `x - h` is a sum of whole gaps, so it is unchanged if no
    gap was cut and at least `K >= c` otherwise: every handler, guard, timeout and invariant
    sees the same values, and with `TickAnytime = FALSE` each kept tick keeps its offset in
    its gap, so the deadline it waits for is still ahead. The cut behaviour ends at or below
    `(n + 1) * K`. Without the final gap the bound is too small for an invariant that reads
    the clock (`final_obs_*` below). It is sufficient, not necessary; a smaller `MaxBlk` needs
    its own argument. `MaxBlk > T + YieldTicks` is not enough on its own, because windows
    chain: a step that needs one window to have passed can open the next (a request sent only
    after an earlier one timed out, then its own cancel window). Without a clock
    (`MaxBlk = 0`) every gap is 0, which changes no comparison if `T = 0`; every yield may
    then time out at any moment (more behaviours, not fewer). With `TickAnytime = FALSE`, no
    handler reading the clock and at most `k` yields per behaviour, `MaxBlk >= k * YieldTicks`
    suffices: the clock never passes the last deadline, so that bound cuts nothing.
- **Validated:** sim (`conformance/tests/receipts.rs`, `block_height_and_timestamp`: the
  receipts of one chunk read its height, which the probe logs; their outcomes record one height
  and one timestamp; a created receipt runs a block later, and both only grow). The
  timestamp a contract reads: sim (`block_timestamp_read_by_contract`: two receipts of one
  chunk log the same `env::block_timestamp()`, which is the one their outcomes record, and a
  child of one of them, a block later, logs a larger one). The epoch height: nearcore
  reading. `examples/yield-clock` shows
  `YieldDeadlinesInBound` and
  an early timeout failing at a too small bound, a bug that `TickAnytime = FALSE` hides, and
  the horizon: with `MaxBlk = 2` a double refund passes unnoticed (`horizon_short_passes`),
  `ClockHorizonOK` flags that bound (`horizon_short_flagged`), one more block finds the bug
  (`horizon_bug_found`), and the correct handler passes at a justified bound
  (`horizon_justified`). `examples/yield-clock/final-observation` shows why the bound counts
  the gap after the last step: one step that arms at height 1 or later, and an invariant that
  fails once a block passes after it. At `MaxBlk = 1` the invariant passes
  (`final_obs_short_passes`); `ClockHorizonOK(1, 1)` flags that bound
  (`final_obs_short_flagged`), where `n * max(T, YieldTicks)` did not; at `MaxBlk = 2` the
  invariant fails (`final_obs_bug_found`).

### S4. No per-pair order

- **Rule:** nearcore does not keep the receipts from one account to another in the order they
  were created, not even when both accounts sit on one shard or are the same account. Two
  mechanisms reorder them at protocol 88:
  - **A new receipt can bypass the outgoing buffer.** A receipt created by a receipt goes to
    `forward_or_buffer_receipt`, which forwards it at once whenever it fits the link's
    remaining gas and size limits, without checking whether that link's outgoing buffer
    already holds earlier receipts; only if it does not fit is it buffered. Draining the
    buffer stops at the first receipt that does not fit, and the rest of the allowance stays
    usable. So an earlier, larger receipt (in bytes, or in attached gas under gas congestion)
    waits in the buffer while a later, smaller one to the same receiver goes out and runs
    first. A shard's route to itself has a bandwidth grant too, so this holds for same-shard
    pairs and self-calls.
  - **Missed chunks reverse the order across heights.** After the destination shard misses
    chunks, its next chunk collects incoming receipts from the newest source block to the
    oldest, so a pair's receipts sent at height `h + 2` run before those sent at `h + 1`.

  Resumes of one yield (C7) are no exception: each `PromiseResume` leaves through the same
  path, so a later resume can arrive first, and whichever arrives first wins; the others are
  dropped by a status check, not by their order. Refunds, receipts from different source
  shards, local against non-local receipts, and receipts waiting on data are not ordered
  either. (Earlier versions of this page listed per-pair order as an over-approximation,
  N-order, and the resume order as N-resume-order. Both were wrong: those reorderings are
  reachable.)
- **nearcore:** `runtime/runtime/src/lib.rs:1222-1234` (a created receipt is instant or goes to
  `forward_or_buffer_receipt`), `runtime/runtime/src/congestion_control.rs:292-325`
  (`forward_or_buffer_receipt`: `try_forward` first, buffer only on failure), `:451`
  (`try_forward` admits a receipt if `forward_limit.gas >= admission_gas &&
  forward_limit.size >= size`), `:379-381` (draining stops at the first misfit);
  `runtime/runtime/src/bandwidth_scheduler/scheduler.rs:427-435` (grants cover every shard
  pair, a shard to itself included);
  `chain/chain/src/stateless_validation/chunk_validation.rs:478-480` and
  `chain/chain/src/chain.rs:3648-3659` (`[new_receipts, old_receipts]`); resumes:
  `runtime/runtime/src/lib.rs:1554-1622` (the first `PromiseResume` runs the yield, `:1616-1620`
  ignores the rest).
- **Model:** no constraint: any enabled receipt may run next (S2), whatever its sender,
  receiver and creation order, and any resume in flight may be the one that wins (C7).
  nearcore can reorder a pair, so a same-pair reorder alone does not make a counterexample
  spurious. That does not make every order the model allows reachable: receipts that leave
  one source chunk for one destination shard travel in one receipt proof and run in their
  order (`chain/chain/src/stateless_validation/chunk_validation.rs:510-514`, S2), and the
  buffer bypass needs the earlier receipt not to fit the link's remaining limits. A
  counterexample that reverses such receipts can still be spurious, so its particular
  schedule must still be shown reachable (N-shards; replay it in the sim). The library offers
  no switch that imposes a pair order, because no such order
  holds for all shard layouts and loads; a contract that needs one must enforce it itself
  (sequence numbers, or one message in flight at a time). `examples/pair-order` shows both:
  a receiver that assumes in-order delivery fails (`pair_assumes_fifo`), and one that keeps
  the highest sequence number seen passes (`pair_seqno_ok`).
- **Validated:** the buffer bypass: sim (`conformance/tests/semantics.rs`,
  `later_receipt_overtakes_buffered`: six ~1.2 MB calls from `p-probe` to `q-probe` fill the
  single shard's grant to itself; a small call `p-probe` makes after three of them, in the
  same block, runs a block before them). This is the sim's own `tests/order.rs:400-433`
  (near-contract-sim `29e9090`) on the probe contracts, with no fault injected. Missed
  chunks: nearcore reading; not sim-testable (the sim misses no chunks).
  <!-- conformance --> The comparison does not see order.

### S5. Instant receipts

- **Rule:** A receipt that holds a single `DeleteAccount` and no input data, created while
  another receipt runs, is **instant**: it is not sent out, but runs right after the receipt
  that created it, in the same chunk, whatever the chunk's gas limit. No other receipt runs in
  between, local ones included, and no transaction, block or epoch can come between: the
  chunk's transactions were converted before its receipts ran. This holds for local, delayed
  and incoming creators alike, and for a delegate's inner receipt. Not instant: a
  transaction's own first receipt (it is converted, not created by a receipt); any receipt
  with another action, such as `[Transfer, DeleteAccount]` or `[CreateAccount, ...,
  DeleteAccount]`; a `DeleteAccount` waiting on a callback's inputs (but a joint callback
  with no inputs, `.then` on an empty `promise_and`, waits on none and is instant); and the
  delete's payout to the beneficiary, an ordinary refund receipt that runs later (A7). A
  `PromiseYield` receipt is instant too; processing it only stores the yield.
- **nearcore:** `core/primitives/src/receipt.rs:468-491` (`is_instant_receipt`),
  `runtime/runtime/src/lib.rs:1222-1234` (instant receipts are queued, not forwarded),
  `:2747-2775` (`process_receipt_and_instant_receipts`, called for local, delayed and incoming
  receipts at `:2538`, `:2642`, `:2727`), `runtime/runtime/src/actions.rs:500-512` (the
  delegate's inner receipt is a new receipt); `runtime/near-vm-runner/src/logic/host.rs:2486-2534`
  (`promise_and` accepts no promises), `:2631-2643` (`.then` keeps the empty dependency list).
- **Model:** `Commit` (on the outcome's ready children, and on a postponed one that is a joint
  callback with no inputs, `InstantTagP`) and `NearKeys.ExecDelegate` tag a
  receipt of that shape (`IsInstantShape`: an ACCOUNT receipt with only a DeleteAccount, no
  deposit) with the field `inst` (`InstantTag`). While one is pending (`InstantPending`),
  `Runnable` holds only tagged receipts (no timeout either), and `SubmitAs`, `BlockTick` and
  `EpochTick` are disabled; `LocalPriorityOK` never holds a tagged receipt back. A model
  conjoins `~InstantPending` to its own steps that change state outside receipts; forgetting
  it only adds interleavings. Tagged receipts run in any order among themselves (nearcore:
  creation order). `InstantFirst` (overridable, default `TRUE`) is the switch;
  `InstantFirst <- FALSE` is the earlier behaviour, an over-approximation (N-instant).
- **Validated:** sim (`conformance/tests/lifecycle.rs`, `instant_delete_via_delegate`: the inner
  `[DeleteAccount]` runs right after the Delegate receipt, in the same block, before marks
  submitted after it, also when the relayer is the user itself, a local creator; the payout
  runs in a later block; an inner Transfer, the control, waits a block).
  `examples/platform-selftest` (`selftest_instant`, `selftest_instant_off`,
  `selftest_payout_*`), `examples/account-lifecycle/instant`. A contract's own self-delete
  (not through a delegate): nearcore reading; the probe contract cannot emit one.

---

## Staking and balance

### B1. Stake action failures

- **Rule:** `Stake(amount, key)` on an account needs the actor to be the account itself (K3);
  then it:
  - fails with `TriesToStake` if `amount − locked` exceeds the liquid balance;
  - fails with `TriesToUnstake` if nothing is locked and `amount = 0`;
  - fails with `InsufficientStake` if `0 < amount < minimum stake`.

  Otherwise it records a validator proposal. An increase moves the difference from liquid to
  locked immediately. A decrease (unstake) changes nothing now; the release comes from epoch
  processing later. A failed Stake fails its receipt, which drops the proposal. A successful
  Stake receipt has no return value, so a callback sees empty bytes (C3). There is no storage
  test inside the action; the receipt's storage check (B2) counts liquid + locked, which a
  Stake does not change.
- **nearcore:** `runtime/runtime/src/actions.rs:58-108` (`action_stake`; the checks at
  `:66-100`), `:755-801` (actor); `runtime/runtime/src/lib.rs:1172-1176` (result);
  `runtime/runtime/src/lib.rs:1717` (`update_validator_accounts`, epoch-side release and
  rewards).
- **Model:** `ExecStake` (actor check, then `StakeFails`; result `EMPTY`), `EpochTick`;
  constants `StakingAcct`, `MinStake`,
  `MaxEpoch` and `MaxReward`.
- **Validated:** sim (`conformance/tests/accounts.rs`, `stake_rules`: `TriesToStake`,
  `TriesToUnstake`, `ActorNoPermission`; an increase locked at once, a decrease changing
  nothing yet). `InsufficientStake`: not sim-testable (the sim has no minimum stake). The
  epoch-side release and rewards: nearcore reading (the sim simplifies epochs: one
  validator, flat rewards). A callback on a Stake: sim (`callback_after_stake`: a contract
  stakes itself, then a callback reads result 0: `Successful` with 0 bytes after a Stake that
  locked the amount, `Failed` after one that failed with `TriesToStake`). <!-- conformance -->
  Against the model, flows (`probes2`: `stake_ok`, `stake_too_much`, with `StakingAcct` the
  staking contract): the Stake's status and a callback that fails unless it reads empty bytes,
  or `Failed`, agree at every point.

### B2. Balance must cover storage (`LackBalanceForState`)

- **Rule:** After a receipt's actions succeed, the receiver's **liquid + locked** balance must
  cover its storage: `storage_usage × storage_amount_per_byte`, 1e19 yocto per byte at 88, so
  100 KB costs 1 NEAR. The balance is the one after the receipt: the deposit it brought is in,
  the deposits it attached to new receipts are out. The check runs once, after all of the
  receipt's actions, for every action receipt on an existing account (not only function
  calls). If the balance falls short, the **whole receipt** fails with `LackBalanceForState`:
  its writes, key changes and new receipts are reverted (R4), and its deposit is refunded (R5).
  **Exemption:** a zero-balance account, one using at most 770 bytes (NEP-448), always passes.
  A transaction is checked the same way at conversion: one whose cost leaves its signer
  uncovered is invalid (`InvalidTxError::LackBalanceForState`), and nothing runs.

  Storage usage counts:
  - the account record, 100 bytes (`storage_num_bytes_account`);
  - each trie record as its key + value + 40 bytes (`storage_num_extra_bytes_record`): a write
    of a new key adds key + value + 40, an overwrite adds the length difference, a removal
    frees key + value + 40;
  - each access key as its trie id (33 bytes for ed25519) + its borsh `AccessKey` + 40. A
    full-access key is 82 bytes. A function-call key is 33 + 8 (nonce) + 1 (tag) + 1 (no
    allowance) or 17 (an allowance) + 4 + the receiver's length + 4 + the sum over its method
    names of 4 + the name's length, + 40. DeleteKey frees what AddKey added;
  - contract code, its length in bytes;
  - an account created by a Transfer (A3): NEAR-implicit 182 bytes (100 + its key), eth-implicit
    132 (100 + the 32-byte global contract hash), deterministic and universal 100. All are
    under 770.
- **nearcore:** `runtime/runtime/src/lib.rs:1008-1031` (in `apply_action_receipt`);
  `runtime/runtime/src/verifier.rs:48-84` (`check_storage_stake`: `amount + locked` at
  `:64-74`, the exemption at `:77-79`), `:25` (`ZERO_BALANCE_ACCOUNT_STORAGE_LIMIT = 770`),
  `:88-90`, `:375-386` (the signer, in `verify_and_charge_tx_ephemeral`);
  `runtime/near-vm-runner/src/logic/host.rs:5041-5070` (`storage_write`), `:5198-5208`
  (`storage_remove`); `runtime/runtime/src/function_call.rs:221-222` (the call's usage written
  to the account); `runtime/runtime/src/access_keys.rs:17-29` (`access_key_storage_usage`),
  `:136-147` (DeleteKey), `:240-252` (AddKey); `core/crypto/src/signature.rs:332-338`
  (`trie_id_len`); `core/primitives-core/src/account.rs:801-809`, `:959-978` (`AccessKey`,
  `FunctionCallPermission`); `runtime/runtime/src/actions.rs:203-208` (CreateAccount),
  `:221-287` (implicit creation), `:303-304` (DeployContract);
  `core/parameters/res/runtime_configs/parameters.yaml:35-37`;
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:7`, `:96-97`.
- **Model:** two encodings of the one check, chosen by the overridable `StoragePerByte`:
  - `FALSE` (the default, the 0.1.0 rule): the `StorageFloor` constant, what liquid + locked
    must cover after a function call (`Affordable`; locked counts for `StakingAcct`,
    `LockedOf`). Give a zero-balance (exempt) account floor 0. Bytes are not tracked
    (N-storage).
  - `TRUE`: the platform variable `stor` holds each account's bytes, from `StorageInit`.
    Handlers declare what they write with `OStor(O, d)` (the outcome field `sb`; helper
    `RecordBytes(k, v)`), or read it from a measured table with `OStorKey(O, key, size)`:
    `StorBytes`, overridable like `GasBurn` (default empty), maps a key
    `"acct.method[/path]"` to `[base, per]`, the bytes being `base + per * size`, and a
    missing key is an `Assert`; without `StoragePerByte` `OStorKey` reads nothing. The
    calibrator writes such tables (`calibrate --stor`); `StorStd` holds the standard FT's and
    wNEAR's (a registration `61 + len(id)`, an unregistration its negative, transfers 0).
    `Affordable` checks `StorageCovers` (an exact integer comparison at
    `StorageByteCost`, and the 770-byte exemption `ZeroBalanceBytes`) and `Commit` updates
    `stor`. `NearKeys` counts `KeyBytes(p)` in `ExecKeyAct` (an AddKey the balance cannot cover
    fails) and folds the key bytes into the call's in `WithKeyActs`, so a bundled receipt is
    checked once, at its end. `ExecTransfer` gives a created account `CreatedBytes`.
    `CanSubmit` refuses a transaction that would leave its signer uncovered. `Nep145`'s
    `TokRegBytes` adds a holder's bytes per registration at a token. `StorageFloor` is not checked.
    `PlatformInit` asserts that every initial balance covers its bytes, and the library checks
    every step that can lower liquid + locked or raise bytes: function calls, AddKey,
    submission. Transfers, refunds, Stake, Delegate and DeleteKey receipts never do, so
    nearcore's check on them cannot fail while every account is covered (the invariant
    `StorageCovered`).
- **Validated:** sim (no model comparison).
  `conformance/tests/semantics.rs` observes: the bytes of a new key and of an overwrite
  (`storage_write_bytes`); a write one yocto short failing with `LackBalanceForState` and
  reverted, the same write passing with exactly enough or with one yocto brought by the receipt
  (`storage_lack_balance_fails_and_reverts`); a callback failing for storage after the payout
  it records was made, the sim twin of `examples/storage-stake`
  (`storage_callback_fails_after_payout`); the 770-byte allowance with a balance below the
  cover, on an account growing by full-access keys (`storage_zero_balance_allowance`); the
  byte counts of full-access and function-call keys, with and without an allowance
  (`storage_key_bytes`); the signer refused at conversion
  (`storage_signer_checked_at_conversion`); 182 / 132 bytes for created NEAR-implicit and
  eth-implicit accounts (`storage_implicit_account_bytes`); a near-contract-standards
  registration at holder ids of 8 and 64 bytes, `61 + len(id)` (`StdRegBytes`; the
  `storage_balance_bounds` minimum is the price of 125 bytes), nothing on a repeat, and its
  bytes freed by `storage_unregister` (`storage_std_registration_bytes`); and the locked part
  of the balance (`conformance/tests/accounts.rs`, `storage_counts_locked_balance`: past 770
  bytes, a liquid balance below the cover passes with 5 N locked and fails without). The calibrator's storage table is nearcore's
  `storage_usage` before and after each successful receipt of `conformance/flows/storage.toml`
  (each flow run at all 1313 points of the standard gas grid, its bytes the same at every
  point): every sized key lies exactly on its line over at least 3 sizes, every unsized key is
  one constant, no receipt changes another account's storage or fails with a change, and the
  receipts' changes add up to each account's change over the flow (`tests/smoke.rs`
  `storage_bytes_table` checks the lines `StorStd` and `examples/storage-stake`'s `StorKv`
  hold). <!-- conformance --> No probe flow compares the model's storage with the sim's: every
  sweep is bound to the sha256 of `flows/probes.toml`, so adding one means sweeping and
  recalibrating all of them; `flows/storage.toml` is a separate file, with no sweep in `data/`.

---

## Tokens

Sources: `neps/nep-0141.md` (fungible token core; `ft_resolve_transfer` requirements at
`:292-330`), `neps/nep-0145.md` (storage management; interface at `:378-415`),
`neps/nep-0245.md` (multi token; `mt_resolve_transfer` at `:304-330`), and NEP-297 (events, not
modelled). The reference implementation is near-contract-standards, in
`fungible_token/core_impl.rs`, `fungible_token/storage_impl.rs` and `fungible_token/macros.rs`.
near-contract-standards has no NEP-245 implementation, and no wNEAR source is available
locally.

### T1. NEP-141 `ft_transfer` / `ft_transfer_call`

- **Rule:** Both require exactly 1 yoctoNEAR attached. They panic if sender = receiver, if
  `amount = 0`, if either side is unregistered, or if the balance is short. `ft_transfer_call`
  moves the tokens, calls `receiver.ft_on_transfer(sender, amount, msg)`, then
  `.then(self.ft_resolve_transfer(sender, receiver, amount))`, and returns the resolver's
  promise (C5).
- **Sources:** NEP-141 `:203`, `:234-240`; near-contract-standards 5.29.1
  `fungible_token/core_impl.rs:94-112` (`internal_transfer`), `:121-155`.
- **Model:** `Nep141` / `Tokens` modules: `TokHandle`, `TokStep`; arguments `FtArgs`.
- **Validated:** NEP text and near-contract-standards source read. For 5.29.1, the panics
  (not exactly 1 yocto, sender = receiver, amount 0, an unregistered side, a short balance)
  and `ft_transfer_call`'s receipts and result: sim (`conformance/tests/tokens.rs`,
  `ft_transfer_requirements`). <!-- conformance --> For
  5.29.1, the receipts each call creates and their gas: sim (`ft_transfer` and `wnear_transfer`
  create none; `ft_call_*` and `wnear_call*` create `ft_on_transfer`, then the resolver as its
  callback). The flows reach no panic (every flow's transfer is valid) and
  the comparison sees no balances.

### T2. `ft_resolve_transfer`

- **Rule:** It must be callable only by the token itself. `unused` = `amount` if the result is
  Failed, longer than 42 bytes, or does not parse as a U128, else `min(v, amount)`.
  `refund = min(unused, receiver balance)` moves back to the sender. If the sender has
  unregistered, the refund is burnt (total supply drops). It returns the amount used.

  **The 42-byte bound is version-dependent.** 5.24.0 and later read the receiver's result with
  `env::promise_result_checked(0, MAX_RESULT_LENGTH)`, where `MAX_RESULT_LENGTH` is the length
  of `"+340282366920938463463374607431768211455"` with its quotes (u128::MAX with a sign): 42
  bytes. A longer result is an error, and `.ok()` then falls back to `amount`: the whole amount
  counts as unused, even if the bytes are valid JSON. So a receiver that keeps the tokens but
  returns `"0"` followed by 40 or more spaces (43+ bytes) gets them refunded (up to its
  balance). 5.23.0 reads with the unbounded `env::promise_result(0)` and honours the `"0"`.

  **Private-ness is the integrator's job.** `FungibleToken::internal_ft_resolve_transfer` does
  no caller check. The `#[private]` attribute comes from the `impl_fungible_token_core!` macro
  (`macros.rs:46`); a contract that implements `FungibleTokenResolver` by hand must add it.
- **Sources:** NEP-141 `:306-325`; near-contract-standards 5.29.1 `core_impl.rs:169-235`
  (the bound: `:175-183`), `macros.rs:46-56`. The bounded read is the same in 5.24.0, 5.25.0,
  5.28.1, 5.29.0, 5.29.1 and 5.30.0-rc.1 (`core_impl.rs:175-183` in each); 5.23.0 uses
  `promise_result(0)` (`core_impl.rs:177`). The SDK's overflow test: C4.
- **Model:** `TokenCommon.ResolveRefundLim(res, amt, rcvBal, dev, max)`, `NumOrChecked`,
  `FtMaxResultLen` (42). The bound is per token, `TokResolveMaxLen[t]` (an overridable
  definition, default 42 for every token, wNEAR accounts included); set it to -1 (unbounded)
  for a token built on 5.23.0 or older (3.x/4.x). It is independent of `TokFtGasShape` (T3):
  5.23.0 has the standard gas shape and no bound. A result's byte length is `r.res.len` when
  stated (`RValLen`), else what `r.res.sz` implies (C4), so `RValSz(0, 2)` already counts as
  too long. The receiver response `"keepbig"` (`RecvOutcome`) is `RValLen(0, 43)`.
  `ResolveRefund` (4 arguments) is the unbounded form. The model's resolver accepts calls from
  the token only. The burn path is reached when the sender calls `storage_unregister(force)`
  between the transfer and the resolver (T4).
- **Validated:** near-contract-standards source read (5.23.0-5.30.0-rc.1). For 5.29.1, sim
  (`conformance/tests/tokens.rs`, `ft_resolve_transfer_rules`: `unused` for a `Failed`,
  numeric, over-amount, non-numeric and empty result; the 42-byte bound, `"0"` padded to 42
  bytes honoured and to 43 refunded in full; the refund capped at the receiver's balance; the
  burn for an unregistered sender; the caller check). The resolver there is delivered with
  near-contract-sim's `Tx::promise_results`, which runs nearcore's callback path on a result
  the test picks: no node makes that receipt, but what the callback reads and does is the
  same. The oversized result in the model:
  `examples/nep141-refund-cap` (`refund_cap_oversized` must pass,
  `refund_cap_oversized_unbounded` must fail), model only; no conformance flow returns an
  oversized numeric result. <!-- conformance -->
  The flows run the resolver after every receiver outcome (keep, return, over, panic, out of
  gas, a non-numeric result), but the comparison sees only its status and gas, not the refund.

### T3. Gas behaviour of `ft_transfer_call` (version-dependent)

- **Rule:** It differs by near-contract-standards version.
  - **5.23.0-5.29.1** (all locally available): `ft_on_transfer` gets static 0 and weight 1, so
    it takes all the leftover gas. `ft_resolve_transfer` gets static 5 Tgas and weight 0
    (`core_impl.rs:13`, `:141-151`).
  - **Older versions** (recalled, not read): `ft_on_transfer` gets static = prepaid − a fixed
    reserve, with weight 0. The call panics when prepaid ≤ reserve. The resolver gets a fixed
    static gas.
- **Model:** per-token `TokFtGasShape[t]`: `"standard"` (the default, 5.x: `ft_on_transfer`
  static 0 and weight 1, no reserve check, resolver static `TokResolveStatic[t]` = 5 Tgas and
  weight 0) or `"reserve"` (older: static prepaid − `TokCallReserve[t]`, weight 0, prepaid ≤
  reserve panics, resolver gas from `GasCall`, else `TokResolveStatic[t]` and weight 0).
  The resolver's burn key is `"<t>.ft_resolve_transfer/refund"` when it refunds and
  `"/norefund"` when not, each falling back to `"<t>.ft_resolve_transfer"`.
  `TokOnTransferStatic[t]` /
  `TokOnTransferWeight[t]` override the shape (-1 = its default); a `GasCall` entry for the
  resolver wins in both shapes. `Nep245` keeps the reserve shape. The measured values per
  version come from `conformance/` (`docs/CONFORMANCE.md`). The shape can change verdicts,
  not only gas windows: under `"standard"` `ft_on_transfer` takes the leftover gas, so an
  out-of-gas path of the reserve shape can disappear. Tokens built on
  near-contract-standards 3.x/4.x (many older deployments) use the reserve shape; check your
  token's version and set `TokFtGasShape` to "reserve" for those.
- **Validated:** 5.29.1 (the probes' version): sim (`ft_call_*`, `wnear_call*`, and the
  batches ending in `ft_transfer_call`: `ft_on_transfer`'s leftover, the resolver's 5 Tgas,
  the edge at 8.4 Tgas). 5.23.0-5.29.0 read; the older behaviour is recalled.
  <!-- conformance -->

### T4. NEP-145 `storage_deposit`

- **Rule:** `storage_deposit(account_id?)` (default: the predecessor):
  - an already registered account gets the whole deposit back, refunded to the
    **predecessor**;
  - a deposit below `min` panics;
  - otherwise the account is registered and `deposit − min` is refunded to the predecessor.

  The FT implementation ignores `registration_only` and has `min = max`. It returns a
  `StorageBalance` object.

  `storage_unregister(force)` needs 1 yocto. An unregistered caller gets `false`. A registered
  caller with a positive balance and no `force` panics. Otherwise the account is removed, its
  balance burnt (total supply drops), `min + 1 yocto` transferred to it, and it gets `true`.
  `storage_balance_of(account_id)` returns the `StorageBalance` or `null`.
- **Sources:** NEP-145 `:378-415`; near-contract-standards 5.29.1
  `fungible_token/storage_impl.rs:8-36` (`internal_storage_unregister`), `:51-78`, `:81-116`.
- **Model:** `Nep145`: `SdAct` (burn key `"<t>.storage_deposit/registered"` or `"/new"`,
  falling back to `"<t>.storage_deposit"`), `SuAct` (`SuArgs(force)`; both booleans are `NONEMPTY` bytes,
  `ev.unreg` / `ev.unregBurnt` say what happened), `SbAct` (`Some` is the number `total` = min,
  `null` is `NONEMPTY`). Deviation `sdRefundToAccount` refunds to `account_id` instead. With
  `StoragePerByte`, every token receipt declares `TokRegBytes[t][h]` bytes per holder `h` it
  registers and frees as many when `h` unregisters (`TokBytes`; balances are fixed-width, so a
  registration is the only change). near-contract-standards stores `StdRegBytes(len(id))` = 1 + 4
  + len(id) + 16 + 40 bytes per holder and prices `min` at a 64-character id, 125 bytes
  (1.25e21 yocto, `fungible_token/core_impl.rs:41-57`, `storage_impl.rs:107-111`).
  `TokStorageMin` is that price for every holder, while a shorter id's registration takes fewer
  bytes, so the bytes must follow the holder's real id: a token whose balance just covers its
  bytes can fail a `storage_unregister` that frees fewer bytes than the minimum it repays. `Nep245` has no storage management: its bytes are the
  model's.
- **Validated:** source read; for 5.29.1, sim (`conformance/tests/tokens.rs`,
  `storage_deposit_and_unregister`: the panic below `min`, the excess and a registered
  account's whole deposit back to the predecessor, `storage_balance_of` (`min` total and 0
  available once registered, null before), and
  `storage_unregister`'s 1 yocto, `false`, the panic without `force`, the burn and the
  `min` + 1 yocto payout).

### T5. NEP-245 multi token

- **Rule:** The same transfer, resolve and refund rules as T1/T2, per token id. Every transfer
  needs 1 yocto.
- **Sources:** NEP-245 `:88`, `:124`, `:164-179`, `:304-330`; for the result read,
  near-sdk-contract-tools-macros 4.0.0 `src/standard/nep245/mod.rs:283-289`.
- **Model:** `Nep245`. Single-id transfers only; no batch, no approvals, no storage management.
  The resolver reads the receiver's result **unbounded** (`ResolveRefund`): unlike T2 there is
  no byte limit, because the one NEP-245 implementation read (near-sdk-contract-tools 4.0.0)
  uses `env::promise_result(0)`.
- **Validated:** NEP text read; the result read: near-sdk-contract-tools 4.0.0 source read.
  Other implementations may bound the read. Not sim-tested: the conformance crate has no
  NEP-245 probe.

### T6. wNEAR

- **Rule:** `near_deposit` registers the predecessor out of the deposit if needed and mints the
  rest; it returns nothing (`EMPTY`). `near_withdraw` needs 1 yocto, burns `amount`, and
  returns a Transfer of the amount to the caller (`RProm`).
- **Sources:** none local. Recalled.
- **Model:** `WNear` (`near_deposit` burn key `"<t>.near_deposit/registered"` or `"/new"`,
  falling back to `"<t>.near_deposit"`). The shipped gas keys come from the repo's wNEAR-like probe
  (`conformance/`); recalibrate for a real deployment.
- **Validated:** recalled. <!-- conformance --> The probe checks the probe, not a production
  deployment. For the repo's wNEAR-like probe, the receipts of `near_deposit` (registered and
  registering) and `near_withdraw` (with the Transfer it returns), and their gas: sim
  (`wnear_deposit`, `wnear_deposit_new`, `wnear_withdraw`, `wnear_batch_D*`). The comparison
  sees no balances.

### T7. Token deviations

- **Rule:** These are non-standard behaviours, chosen per token account:
  - `retBytes`: `ft_transfer` returns non-empty bytes;
  - `resolveIgnoresResult`;
  - `resolveNoCap`;
  - `sdRefundToAccount`;
  - `autoRegister`.

  An unregistered receiver is a scenario (the initial registration set), not a deviation.
  With `StoragePerByte` and `TokRegBytes`, `autoRegister` adds a registration's bytes with no
  deposit, so a token whose spare balance runs out fails transfers with `LackBalanceForState`
  (B2).
- **Model:** `TokenCommon.Deviations`, `TokDev`, `MtDev`.
- **Validated:** model-only (they are deliberate departures from the standard).

---

## Failure modes in the model

### F1. Forced-fault switch versus gas mode

- **Rule (model-only):** `GasMode` picks how receipts fail.
  - **`"fault"`:** a receipt whose method is in `MayFail` may fail at most `MaxFails` times,
    nondeterministically (`ForcedFail(r)`). This stands for "this call can fail for some
    reason" without saying why. Findings are labelled `forced`.
  - **`"gas"`:** a receipt fails when its calibrated need exceeds its gas (G1-G3), and the
    prepaid gas comes from a menu. `MayFail` can still be layered on top. A finding with no
    forced fault is a gas finding, reachable by choosing the prepaid gas.

  Both modes use the same revert scope (R4, R5, C1).
- **nearcore:** no counterpart for the switch itself. Gas mode encodes G1-G5.
- **Model:** `GasMode`, `MayFail`, `MaxFails`, `ForcedFail`, `GasCall`, `GasBurn`, `FailOOG`,
  `Label`, plus the ghosts `oog` and `rlog`.
- **Validated:** gas mode: sim as far as G1-G5 are (every flow runs the model in gas mode).
  <!-- conformance --> Fault mode is an abstraction by design and has no sim counterpart.

---

## Not modelled

Each item says what it is, why it matters, and what leaving it out could hide. Items are written
against the current module code; some may be fixed in the modules later.

- **Over-approximation:** the model allows more behaviour than nearcore. That is sound for
  safety (no real bug is missed), but it can produce counterexamples no network can reach.
  Replay every counterexample in the sim.
- **Under-approximation:** the model allows less behaviour than nearcore, or replaces a
  nearcore outcome with a different one. That is **unsound**: a real bug can be missed.
- **Scope limit:** the feature is simply absent. A contract that uses it cannot be modelled
  faithfully with this library.

### Over-approximations

- **N-shards. Shards and cross-shard latency.** There are no shards, no blocks and no
  latency; any causally enabled order is allowed. This covers every real schedule **with the
  local-priority switch OFF** (with it ON, see N-local-congested), but some model schedules need
  timing a network does not produce.
- **N-congestion. Congestion control, bandwidth scheduler, delayed receipts.** These delay
  receipts. With the local-priority switch **OFF**, the model's free ordering covers every delay.
  With it **ON**, it does not: see N-local-congested. A finding about latency bounds needs the
  real scheduler. Congestion can also reject new transactions, which the model treats as "not
  submitted".
- **N-instant. Instant receipts off.** With `InstantFirst <- FALSE` an instant receipt (S5)
  is an ordinary one: other receipts, transactions and blocks may come between a receipt and
  the lone `DeleteAccount` it creates, which nearcore never allows. A contract that relies on
  its self-delete being immediate then shows spurious counterexamples
  (`examples/account-lifecycle/instant`, `instant_off_spurious`). With the default the rule is
  exact, a joint callback with no inputs included (`instant_empty_join_passes`), except that
  tagged receipts run in any order among themselves. A `PromiseYield`
  receipt is instant too, but processing it only stores it (`lib.rs:1549-1553`); the model puts
  the yield in `post` at its creator's commit, which is the same.
- **N-local-off.** With the local-priority switch (S1) off, a self-signed first receipt may run
  after receipts that nearcore, on an uncongested chunk, would run later. Such orders are
  reachable under congestion (S1), so a violation found this way is not a false positive unless
  the receiving chunk provably cannot be at its limit.
- **N-local-per-account.** With the switch on, `LocalPriorityOK` orders local receipts first
  only per receiving account; nearcore's rule is chunk-wide. Other accounts' receipts may still
  overtake a pending local receipt in the model.
- **N-tx-validity. Transaction validity outside K5.** Nonces are checked only for a
  transaction submitted with `SubmitTx` by a signer in `KeyAccts` (K5). `Submit` and
  `SubmitSigned` check none, so with them a replayed or out-of-order transaction runs again.
  The nonce's upper bound (`NonceTooLarge`, `runtime/runtime/src/verifier.rs:271-278`) is
  off unless the model sets `NonceHeight0` (K5): the model's nonces are abstract, so by
  default a transaction whose nonce runs ahead of the chain is accepted. Also absent:
  expiry (`runtime/runtime/src/lib.rs:2031-2034`), the gas part of the balance check
  (N-gas-money), signatures and gas-key nonces. A key added again after a DeleteKey starts
  at nonce 0, where nearcore starts it at `(h − 1) × 1e6` (N-delegate-rekey), so a
  transaction signed for the old key can run again. Each hides a refusal: a model that
  relies on one must replay its counterexamples in the sim.
- **N-allowance. The allowance's cost and refund.** The model charges an allowance (K2) its
  transaction's stated cost (`WithTxCost`) and adds the stated refund back at once; nearcore
  adds each gas refund only when its refund receipt runs, so while refunds are in flight the
  model's allowance is higher and accepts transactions nearcore refuses. There is no default
  cost: nearcore's is never 0 (the conversion gas at the gas price plus the prepaid gas and
  the receipt's exec fees at `max(gas price, min_gas_purchase_price)`,
  `runtime/runtime/src/config.rs:515-536`), so a transaction signed with a key that has an
  allowance and no `WithTxCost` is an `Assert`, and so is a cost of 0. A refund stated above
  nearcore's over-approximates further. A refund stated below nearcore's is an
  under-approximation: `examples/session-key`, `session_naive_no_refund_hides`, passes with
  `Refund = 0` while the same allowance lets more plays through with the refund. The
  credit at conversion keeps the modelled allowance at or above nearcore's only while the
  key stays: nearcore credits a late refund to whatever key holds the public key when the
  refund runs (`runtime/runtime/src/actions.rs:133-157`), so a key deleted and added again
  under the same public key gets the old key's refunds, which the model credited to the
  old key. Refunds are not receipts in the model, so it cannot tell when the last one has
  landed: an AddKey of a key with an allowance under a key id that has signed any
  transaction (`txsig`; every such AddKey when `TrackSigner = FALSE`) is an `Assert`
  (`AllowanceAddOK`; `examples/session-key`, `session_rekey_same_id`), when the key is
  still there after its receipt (a DeleteKey of it, or a DeleteAccount, later in the same
  receipt leaves nothing for a refund to reach: `session_rekey_batch_deleted`). Give a new
  key a fresh id (`session_rekey_fresh_id`).
- **N-fckey-one-action. Function-call keys and bundled key actions.** nearcore refuses a
  transaction signed by a function-call key unless it has exactly one action
  (`runtime/runtime/src/verifier.rs:213-217`). `KeyCanSign` refuses Transfer, Stake, key
  actions and multi-call receipts, but cannot see key actions a model bundles into a call
  receipt with `WithKeyActs`; such a model must require a full-access key itself.
- **N-delegate-rekey. A re-added key's delegate nonce starts at 0.** Delegate nonces live in the
  key record (K4), so a DeleteKey followed by an AddKey of the same key id resets them, and a
  delegate signed for the old key can run again. nearcore starts a new key at
  `(h − 1) × 1e6`, where `h` is the AddKey's block height (`runtime/runtime/src/access_keys.rs:46-49`,
  `:240`), which kills most old delegates: every one with a nonce at or below that. Not all of
  them: a delegate may carry a nonce up to `h' × 1e6 − 1` at the height `h'` it runs at
  (`runtime/runtime/src/actions.rs:659-666`), so one that ran in block `h` itself, before the
  AddKey, can still be above the new key's nonce and run again later. The model allows every
  such replay, which is sound. A per-key high-water mark that survives a re-add would forbid
  that last replay, which nearcore allows: an under-approximation, so the model does not keep
  one. A model that deletes and re-adds a key id may see replays nearcore refuses; replay
  them in the sim. The same holds for an account deleted and created again (A7): its keys, and
  their nonces, start afresh.
- **N-delegate-expiry. Delegate expiry without a clock.** With `MaxBlk = 0` a delegate that has
  an expiry (`mbh # NoExpiry`) may fail at any time (`DelegMayExpire`). This also stands in for
  the outer-receipt failures the model leaves out (`DelegateActionNonceTooLarge` with no
  nonce ceiling set, K5; a racing
  direct transaction of the same key; see N-delegate-nonce). With the clock it fails exactly
  when `blk > mbh`; the outer receipt may then still run in its transaction's own block,
  which nearcore allows only for a local receipt (N-time).
- **N-delegate-unkeyed. Delegates from accounts without modelled keys.** For a user outside
  `KeyAccts`, `ExecDelegate` checks no key, nonce or permission, as `SubmitSigned` checks no
  key for such a signer. Every replay of such a user's delegate succeeds. Put delegating users
  in `KeyAccts`.
- **N-delegate-forgery. The user's signature is a modelling rule.** `SignedDelegate` can be built
  for any account. A model must build a user's delegate only in that user's own step; a
  relayer step that builds one for another account models a forgery, which nearcore rejects
  (`DelegateActionInvalidSignature`, `runtime/runtime/src/actions.rs:474-477`).
- **N-time. Block timing.** The block clock (S3) is a bounded counter: any number of receipts
  may run at one height, a callback even at its creator's height (nearcore: at least one block
  later), and any number of blocks may pass while a receipt is in flight. There is no latency
  bound, so the model can show that a race exists (a resume against a timeout) but cannot
  prove that a receipt sent within N blocks always arrives in time. Timestamps are `TsOf(blk)`,
  one fixed increasing function; nearcore's step per block varies. Saturation at `MaxBlk`
  lets pending yields time out early; `YieldDeadlinesInBound` reports it. The bound itself is
  an under-approximation: see N-clock-horizon.
- **N-epoch-clock. Epochs and blocks are independent.** `EpochTick` and `BlockTick` are
  separate steps: an epoch may change without a block passing and the other way round (an
  epoch is 43,200 blocks on mainnet). A staking model that also yields, and depends on how
  many blocks an epoch lasts, should couple them in its own step (for example an epoch tick
  allowed only when `blk` is at a multiple of an epoch length in ticks).
- **N-timeout-order. Yield timeouts in any order.** nearcore pops the timeout queue in creation
  order (`runtime/runtime/src/lib.rs:3129-3207`, entries ordered by `expires_at`); the model
  lets pending yields past their deadline time out in any order. With the default untimed
  clock a yield may time out right after it is created, which nearcore never does before 200
  blocks; use the clock (S3) when "not before the deadline" matters.

### Under-approximations (unsound: they can hide bugs)

- **N-global-instant. Global contracts published at once.** With `GlobalInstant <- TRUE` a
  DeployGlobalContract publishes its code when it commits, with no distribution receipt (A10).
  That removes the window in which a UseGlobalContract of the identifier fails and its users
  still run the old code (sim: `conformance/tests/global.rs`, `deploy_global`), so a bug that
  needs the window is missed (`examples/account-lifecycle/global-upgrade`,
  `upgrade_use_race_instant` passes where `upgrade_use_races_deploy` fails). Use it only for
  state-count relief, and run the default as well.

- **N-local-congested. Local priority under chunk limits.** With the switch ON, the model
  assumes the receiving chunk is below its compute and storage-proof limits. When it is not, the
  local receipt goes to the back of the delayed queue and every receipt already delayed runs
  first (`runtime/runtime/src/lib.rs:2513-2521`, `:2800-2813`,
  `runtime/runtime/src/congestion_control.rs:864`). `LocalPriorityOK` forbids that order, so a
  bug that needs it is missed; the sim reaches it with a full chunk
  (`conformance/tests/semantics.rs`, `local_receipt_delayed_when_chunk_full`). Mitigation:
  run with the switch OFF as well (S1).
- **N-clock-horizon. The block clock stops at `MaxBlk`.** No behaviour that needs a later
  height is explored: a guard that opens past the bound never fires, and a timeout cannot be
  delayed past it (nearcore can process it any number of blocks late,
  `runtime/runtime/src/lib.rs:3129-3147`). A model whose handlers, guards or invariants read
  the clock therefore passes only up to `MaxBlk`. Example (`examples/yield-clock`,
  `horizon_*`): a cancel window that opens 3 blocks after a request, a yield deadline of 2,
  and an `on_answer` that refunds on a timeout even when the request was cancelled. With
  `MaxBlk = 2` the cancel never opens and `NoNegEscrow` passes, as does
  `YieldDeadlinesInBound`; with `MaxBlk = 3` the timeout is delayed past the cancel and the
  escrow goes negative. Mitigation: choose `MaxBlk` so that `ClockHorizonOK(n, T)` holds,
  i.e. `MaxBlk >= (n + 1) * max(T, YieldTicks)` (S3: `T` the largest number of blocks any
  clock comparison counts, `n` the most clock-relevant steps per behaviour, and one more gap
  for the state an invariant reads after the last step) and list it as an invariant, or give
  your own argument that a smaller bound covers the model; otherwise report the result as
  bounded.
- **N-precision. Rounding of fees and burns.**
  - **Fees (`NearFees`), by `NearFees.FeeRounding`.** Each table entry is rounded on its own,
    so the parts still add up (send + exec = action).
    - `"up"` (the default): never understated. A base entry is over by less than 1 Ggas, a
      per-byte term by less than `1.001 + 1e-6 × n` Ggas for `n` bytes, a single-action
      receipt (receipt base and one action, send and exec) by less than **4 Ggas** (a named
      Transfer: 450 against 446.37). As far as the fee table goes, a prepaid amount the model
      finds enough is enough in nearcore, and so, under the premises of the split below, is
      the gas it gives a child. The price is a false out-of-gas within that margin.
    - `"nearest"` (the earlier rounding; set `"NearFees!FeeRounding" = '"nearest"'` in a run's constants):
      at most 0.5 Ggas per base entry, `0.5 + 0.001 + 0.5e-6 × n` Ggas per per-byte term
      (≤ 0.51 Ggas up to 20 KB, ≤ 2.6 Ggas at 4 MiB), roughly 3 Ggas per receipt, **either
      way**: a budget up to that much short can pass in the model and run out of gas in
      nearcore.
    - `examples/fee-edge` shows both: a budget 0.37 Ggas short of a Transfer passes under
      `"nearest"` (`edge_nearest_misses`) and fails under `"up"` (`edge_up_catches`), and
      under `"up"` a budget that is enough by 0.63 Ggas fails too
      (`edge_up_tight_false_cex`).
  - **The unused-gas split (G3), by the same switch.** `"up"`: every weighted child gets
    `⌊U·w/W⌋` Ggas of the model's leftover `U` and the remainder goes to no one. No child then
    gets more than in nearcore **provided the model's `U` is at most nearcore's**, which
    needs the creator's attached gas to be at most nearcore's and its need to be an upper
    bound. Neither follows from `"up"` alone. The exceptions:
    - `GasBurn` burns or `GasCall` exec fees (`fee`, the child's prepaid exec fee, part of
      the need) that are not upper bounds: hand-written tables (such as the examples'), and
      calibrated ones past their largest measured size or on a path or trie shape they did
      not measure (the burn bullet below, N-burn);
    - a receipt that pools several function calls' gas (`PooledGasOK`, N-batch-oog): its one
      leftover can exceed the leftover of the action that created a child;
    - `FeeRounding = "nearest"`, which understates fees.

    Where the premise fails, a child's share, and the attached gas of everything below it, can
    exceed nearcore's. Where it holds, a child's share is short by less than 1 Ggas plus its
    part of the leftovers' difference. The same premise makes `SureShare` (G3, zero gas under
    `"up"`) sound.
    `"nearest"`: the last weighted child also gets the remainder, up to `n − 1` Ggas for `n`
    weighted children, which can exceed nearcore's share by about that much
    (`examples/weight-split/remainder`).
  - **Calibrated burns** (`CalibStd`, and tables from `conformance`'s `calibrate`). `base` and
    exec fees are rounded up, and `base` is fitted as an upper envelope: every burn measured
    is at or below `base + per × size`. `per` is the fitted slope rounded to the nearest whole
    Ggas per KB, so past the largest size measured a burn is understated by up to
    `(per_exact − per) × (size − largest size measured)` when `per` was rounded down. A table
    says nothing about paths or sizes its flows did not measure.
  - **Function-call AddKey per-byte fee** (`KeyFee`): charged since this release, from the
    model's method names or a byte count given with `WithMethodBytes` (N-keyfee).
  - **Overstated:** the KB rounding of sizes ([Units](#units)) when sizes feed fees or burns.

  A predicted gas edge is accurate only to these bounds summed over the receipts on the path.
  Window edges closer together than that, and windows narrower than it, are not trustworthy.
  Conformance compares gas at 0.1 Tgas resolution with `FeeRounding` pinned to `"nearest"`,
  since it measures accuracy. Under `"up"` (with the split above) the same comparison differs
  only where it should: 2 of 74 flows (`ft_storage_again`, `wnear_storage_again`, whose
  `storage_deposit` refunds the excess by a Transfer) move their edge one grid point up, from
  1.0 to 1.1 Tgas. At 1.0 Tgas nearcore succeeds with 0.8 and 1.3 Ggas to spare, and the
  model, 3.6 Ggas over on the Transfer, runs out of gas. No other status or edge changes;
  attached gas moves within the 5 Ggas tolerance, never above the sim's (G3).
- **N-delegate-nonce. Delegate nonces against direct transactions, and their upper bound.**
  A user's direct transactions share the key's nonce with its delegates in nearcore
  (`runtime/runtime/src/verifier.rs:254-280`). `SubmitTx` sets it (K5), but `SubmitSigned`
  neither checks nor advances it (N-tx-validity). So in a model whose direct transactions go
  through `SubmitSigned`, a delegate that a later-nonce direct transaction of the same key
  would invalidate still runs. Likewise `DelegateActionNonceTooLarge` (a nonce at
  or above `block_height × 1e6`, `runtime/runtime/src/actions.rs:657-665`) is off unless the
  model sets the nonce ceiling (`NonceHeight0`, K5): the model's nonces are abstract. Both
  hide a failure of the outer receipt (whose deposit goes
  back to the relayer). Mitigation: give such delegates a finite expiry and run without a
  clock (N-delegate-expiry), or submit the direct transactions with `SubmitTx`.
- **N-batch-oog. Per-action out-of-gas in batches.** nearcore checks each function-call action
  against its own gas and splits only that action's leftover (G3). `NearAsync` does the same
  for an outcome with `pa`, and the token batch emits it by default (`TokBatchPerAction`). A
  model's own multi-call receipt without `pa`, or a token batch with `TokBatchPerAction <- FALSE`
  (and `PooledGasOK <- TRUE`), is one pool: a batch where one action is starved while another
  has slack fails in nearcore but not in the model, and the leftover split can differ.
- **N-burn. Trie and storage gas variation.** Burns are constants per (method, path), affine in
  one size variable at most, measured in one sim world. Real burns move with trie shape, key
  count, argument length and network (trie-node pricing). A real out-of-gas at a prepaid amount
  the model calls safe is possible near any calibrated edge. Treat windows as approximate. They
  are tied to the calibration's provenance (`docs/VERSIONING.md`).
- **N-keyfee. AddKey per-byte fee from the model's method names.** `NearKeys.KeyFee` charges
  a function-call AddKey its base fee and its per-byte part (`NearFeeTable!AddKeyFcBytesFee`,
  about 3.9 Ggas per KB on the creator's own account) for `Σ (len(name) + 1)` bytes over the
  permission's method names (`runtime/near-vm-runner/src/logic/utils.rs:4-6`, charged at
  `host.rs:4078-4091`). The model's names are counted as written, one byte per character,
  which is nearcore's `name.as_bytes().len()` for ASCII only: TLC's `Len` counts characters,
  so a name with any character outside printable ASCII is an `Assert` (`AsciiName`). A model
  whose names stand for longer real ones still under-charges the creator, which the model
  cannot detect, so an out-of-gas at creation can be missed and a weighted sibling's share
  can exceed nearcore's. State the real count with `WithMethodBytes(p, n)`; the same count
  feeds the 2000-byte limit (R6) and the key's storage bytes. Before this release the per-byte part was dropped altogether (a
  self-directed AddKey with 2,000 bytes of method names: 424 Ggas against nearcore's
  428.26; now 432).
- **N-burn-fail. Burn of a failing receipt.** Only the verdict is modelled, not how much a
  failing receipt burnt. Gas-griefing amounts are not computed.
- **N-storage. Storage staking details.** With the default `StoragePerByte = FALSE`, storage
  usage is not tracked per byte: a write that exceeds the balance's storage cover
  (`LackBalanceForState`, B2) appears only through the floor you configure, so a contract whose
  storage grows may fail in nearcore and not in the model (`examples/storage-stake`,
  `vault_floor_misses_it`). With `StoragePerByte` the rule is exact, but:
  - the byte counts are the model's: a handler that understates its `OStor` bytes, or a
    `StorageInit` below the real usage (code included), hides failures. A measured table
    (`OStorKey`, `StorBytes`) takes the counting out of the model, not the choices: which key
    and path a handler's outcome reads, and its size (TLC has no string length, so an id's or
    a value's length is a constant the model states). A table holds only the paths its flows
    ran, under their state: bytes that depend on state the flows did not set up (a collection's
    first insert writing a length record, an overwrite by a value of another length, a
    removal) are measured only if a flow covers them, and are hand counts otherwise;
  - function-call key bytes take the receiver id's length from `IdBytes` (default 10), count
    method names as written (or as `WithMethodBytes` states) and assume no allowance (16 bytes
    more with one): override `IdBytes` or `KeyBytes`;
  - the signer's check at submission (`CanSubmit`) counts the deposit but not the gas money
    (N-gas-money), so a transaction nearcore refuses because gas plus deposit leave its signer
    uncovered is accepted. Receivers pay no gas, and from 87 earn no share of it
    (`burnt_gas_reward` 0, `core/parameters/res/runtime_configs/87.yaml:1-7`), so their check is
    not affected;
  - the bytes of global contracts and gas-key nonces are absent with those features (Scope
    limits). CreateAccount, DeleteAccount and DeployContract bytes are counted (A6, A7, A9).
- **N-gas-money. Gas price and gas money.** Gas is a quantity, not NEAR. Purchase, the price
  floor (`min_gas_purchase_price`), price changes between blocks, the account-creation charge
  (A3) and burning are absent (`runtime/runtime/src/config.rs:481` `calculate_tx_cost`;
  `runtime/runtime/src/lib.rs:1032-1044`). Properties about NEAR balances that include gas costs
  cannot be stated.
- **N-gas-refund. Refunds of unused gas as NEAR.** Gas refunds go to the signer
  (`runtime/runtime/src/lib.rs:1407-1415`). The NEP-536 refund penalty is
  `gas_refund_penalty` = 0/100 and `min_gas_refund_penalty` = 0 at 84-88, so it is zero
  (`core/parameters/res/runtime_configs/parameters.yaml:14-18`, unchanged by any version yaml;
  formula `core/parameters/src/cost.rs:736-746`). From 85 the account-creation charge comes out
  of the refund (A3). If the signer account no longer exists (deleted in flight), the gas refund
  cannot create it and is burnt (`runtime/runtime/src/lib.rs:1046-1053`). The model refunds no
  NEAR for gas, so signer-balance properties are not covered.
- **N-refund-stuck. Refunds to an absent account.** A deposit refund to an absent account is
  burnt in nearcore (`runtime/runtime/src/lib.rs:1046-1054`) and in the model (R5). Only with
  `BurnLostRefunds <- FALSE` does such a `REFND` stay in flight, and then invariants guarded by
  "when idle" are never checked on that path. With account deletion (A7) a refund meets an
  absent account in three ways: its predecessor deleted itself before the refund arrived
  (`examples/account-lifecycle`, `refund_to_deleted_burns`); a `DeleteAccount` payout to an
  absent beneficiary, or to the account itself; a yield's deposit on a deleted account (its
  `refund_to` is the account).
- **N-universal. Universal accounts are created uninitialised.** nearcore creates a `0u`
  account from a Transfer without code, keys or data; every action but Transfer and its own state
  init then fails with `AccountNotInitialized` (`runtime/runtime/src/actions.rs:276-282`,
  `:883-888`). The model fails function calls to it (`HasCode`), the key actions and
  DeleteAccount of an ACCOUNT receipt (`AccountNotInitialized`, A6) and a delegate it signs
  (`NearKeys.DelegErr`), all through `UninitUniversal`, which needs `UniversalOn` (without it
  a `0u` id is named and its account an ordinary one); `ExecKeyAct` and Stake do not check
  initialisation. A batched Transfer to an absent universal id creates it in nearcore
  (A3); in an ACCOUNT receipt it fails.
- **N-reward. Gas rewards.** Up to 86, a contract earned 30% of the gas its function calls
  burnt; 87 sets that to 0 (`core/parameters/res/runtime_configs/87.yaml:1-7`,
  `runtime/runtime/src/lib.rs:1108-1137`). At 84-86 a contract's balance grows in a way the model
  does not track.
- **N-validator. Validator rewards beyond the abstract tick.** Seat price, kickouts, slashing,
  reward shares and the exact release epoch are absent (`runtime/runtime/src/lib.rs:1717`).
  A staking contract's share-price arithmetic over real rewards is not checked.
- **N-limits. Protocol limits the model does not count.** R6 lists the limits the model
  enforces or asserts on. These it does not see: arguments over 4 MiB and method names over
  256 bytes (`runtime/runtime/src/action_validation.rs:361-373`), a new receipt over 4 MiB
  (`runtime/runtime/src/verifier.rs:681-697`), a transaction over 1.5 MiB
  (`core/primitives/src/transaction.rs:380-387`), storage keys over 2 KiB and values over
  4 MiB (`core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:244-256`),
  logs a handler does not declare with `OLog`, and the per-receipt storage-proof limit (feature at 86, all actions at 87;
  `runtime/runtime/src/lib.rs:925-948`, `:987-999`). Exceeding one fails the receipt or
  refuses the transaction in nearcore and not in the model. The promise count of R6 relies on
  the handler for `promise_and` calls: unstated (`OJoins`), they are counted one per joint
  callback and bounded by nesting (an `Assert` where nesting could cross 1024), but a
  `promise_and` that no callback uses, or that joins a single promise, is past that bound,
  so a call nearcore fails at 1024 may pass. A model near a limit should keep its counts
  well inside it, state them, or fail the call itself (`OErr`).
- **N-one-yocto. `one_yocto_on_promise` (85+).** A contract with zero balance may attach
  exactly 1 yocto to a promise function call without having it
  (`runtime/near-vm-runner/src/logic/host.rs:3579-3593`;
  `core/parameters/res/runtime_configs/85.yaml:1`). A model that requires a balance for that
  attachment refuses an execution nearcore allows.
- **N-input-87. Promise-input size limit at 87.** At 87 a callback whose inputs exceed 4,194,944
  bytes fails without running (C4). Unless the model's sized results trigger this, it is
  missed. At 88 it cannot happen.
- **N-yield-payload. Resume payload limit.** `promise_yield_resume` fails the resumer when the
  payload exceeds `max_yield_payload_size`
  (`runtime/near-vm-runner/src/logic/host.rs:4504-4511`, `HostError::YieldPayloadLength`); the
  yield stays parked and then times out. The limit is **1024 bytes**: the value is 1024
  (`.snap:275`), the field is a number of bytes (`core/parameters/src/vm.rs:197-198`) and the
  check compares it with the payload length in bytes; the `# kiB` annotation in
  `core/parameters/res/runtime_configs/parameters.yaml:321` is wrong. The sim confirms it
  (`conformance/tests/semantics.rs`, `yield_payload_limit_is_1024_bytes`): a 1024-byte payload
  is delivered, while 1025 bytes, and 1 MiB, fail the resumer with "Yield resume payload is 1025
  bytes which exceeds the 1024 byte limit" and the callback later times out. The model does not
  check it (`OResume` sizes are in KB, which cannot express the bound), so a resume nearcore
  rejects succeeds in the model. A handler whose payloads can exceed 1024 bytes should fail
  on an oversized one itself (`OErr`), and so model the resumer's failure.
- **N-acct-ids. Account-id structure is a modelling input.** Toy ids carry no structure, so
  the parent of each account (`AcctParent`, `Parents`) and the account allowed to create
  top-level ids (`TopCreator`) are constants the model states (A6). A wrong map refuses
  creations nearcore allows or allows ones it refuses. The default makes every account
  top-level and `TopCreator` an id outside the model, so every CreateAccount fails until the
  model states its parents. Testnet has no top-level restriction
  (`min_allowed_top_level_account_length` 0, `core/parameters/res/runtime_configs/parameters_testnet.yaml:27`).
- **N-delete-large. The large-state refusal needs per-byte storage.** Without
  `StoragePerByte` the model has no byte counts, so `DeleteAccountWithLargeState` (A7) never
  happens and a delete nearcore refuses succeeds. Put `ACCT` in `MayFail` to explore the
  failure anyway. With `StoragePerByte`, `CodeSize` must state each contract's code bytes
  (counted in its `StorageInit`), or the deletes of large contracts fail falsely; deployed
  code counts its `CodeLen` (A9), a global contract its identifier (A10).
- **N-wipe. A deleted account's model state.** The library removes the account's balance,
  bytes and keys (A7); the model's own variables for it (a contract's ledger, flags) are not
  touched. A model whose accounts can be deleted and created again must reset them, with
  `DeletesAcct(r)` after `ExecAcct`; otherwise the new account runs on the old one's state,
  which can both hide bugs and report false ones.

### Scope limits

- **N-multi-receiver. One receipt feeding several callbacks.** A receipt's `cb` is one id, so a
  receipt that nearcore gives several output data receivers cannot be expressed:
  `promise_and([p, p])`, or `p.then(A)` together with `promise_and([p, q]).then(B)`. nearcore
  sends `p`'s result to each receiver (`runtime/runtime/src/receipt_manager.rs:118-124`,
  `runtime/runtime/src/lib.rs:1146-1189`). A contract using either pattern cannot be modelled.
- **N-delegate. Delegate actions: what K4 leaves out.** The gas money of a meta transaction
  (the relayer's NEAR spent on gas, and the inner actions' send fees, which the relayer pays
  twice: `calculate_tx_cost`, `runtime/runtime/src/config.rs:481`, and `runtime/runtime/src/actions.rs:521-531`) is
  not modelled (N-gas-money); for a fee estimate use `NearFeeTable!ActionFee("delegate", sir,
  kind)`. `DelegateV2` and gas-key nonces (N-gas-keys), the ML-DSA signature-verification
  surcharge, and the relayer's transaction status (a success even when the inner call fails)
  are absent. The model's inner receipt is one receipt record: a delegate whose inner actions
  bundle key actions with a call needs `WithKeyActs`, and `KeyCanSign` cannot see those
  (N-fckey-one-action).
- **N-global. Global contracts: what A10 leaves out.** Distribution across shards
  (`runtime/runtime/src/global_contracts.rs:288-333`): nearcore publishes shard by shard, so
  users on different shards can see a redeploy at different times; the model has one global
  table, updated once per distribution. The distribution's compute cost (N-compute). A
  DeployGlobalContract only in an ACCOUNT receipt, at most one per receipt, and no
  DeployContract with a UseGlobalContract in one receipt (nearcore allows each; the model
  asserts). The eth wallet: an eth-implicit account's code is a global contract
  (`actions.rs:255-268`); the model gives it the tag `EthWalletCode` (A9), not a `guse` entry.
- **N-upgrade. Contract upgrades mid-flow.** A DeployContract changes the account's code tag
  (A9), and nearcore runs every later receipt on the account, a callback in flight included,
  with the code deployed when that receipt executes (the account's contract is read as the
  action runs, `runtime/runtime/src/lib.rs:684-700`). The model's handler, though, is the
  model's TLA+: it runs the new code only if it branches on `CodeOf(r.to)`, and nothing
  makes a model do that. A by-account global contract's redeploy is the same, for every user
  at once (A10; `examples/account-lifecycle/global-upgrade`, `upgrade_assumes_old_code`). A model of an upgradable contract must dispatch on `CodeOf(r.to)`
  and migrate its own state for the account; otherwise callbacks after an upgrade run the old
  logic in the model.
- **N-deterministic. Deterministic and universal account ids, state init** (NEP-616;
  `runtime/runtime/src/deterministic_account_id.rs`, `runtime/runtime/src/universal_account_id.rs`).
  The fee kinds exist in `NearFees`; the state-init actions, their fees and the no-key bootstrap
  transaction (K2) do not.
- **N-gas-keys. Gas keys** (85+: `TransferToGasKey`, `WithdrawFromGasKey`, gas-key nonces;
  `core/primitives-core/src/version.rs:615`). Absent, and with them DeleteAccount's
  `GasKeyBalanceTooHigh` refusal and its burn of the gas keys' balance
  (`runtime/runtime/src/actions.rs:370-379`, `:388-391`).
- **N-compute. Compute costs versus gas.** Some actions charge more compute than gas (for
  example deploy, `core/parameters/res/runtime_configs/84.yaml`). This affects chunk packing,
  that is timing only, which the free ordering covers with the local-priority switch OFF.
- **N-wasm. Contract semantics.** The model's handlers are hand-written abstractions of the
  contract. Wasm-level behaviour (panics on overflow, serialization, unexpected host errors) is
  covered only by replaying counterexamples in the sim.
- **N-events. Logs and events (NEP-297).** Not modelled, apart from their count and bytes
  against the protocol limits (`OLog`, R6). A failed receipt keeps its logs
  (`runtime/runtime/src/lib.rs:535-541`), so a log is not proof of a committed write.
- **N-views. View calls.** Views are pure reads outside receipts (`ProhibitedInView` for every
  promise host function). `ft_balance_of`/`ft_total_supply` are modelled as reads of the
  ledger.
- **N-resharding. Resharding and missing chunks.** The model assumes a fixed layout and a
  finalized history.
