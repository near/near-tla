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
  `docs/VERSIONING.md`).
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
    [`CONFORMANCE.md`](CONFORMANCE.md)) agreed with the model. No rule is at this level yet.
    Rules that a conformance flow covers carry the marker `<!-- conformance -->` in the source
    of this page; the final conformance run upgrades them from "nearcore reading" to "sim"
    where its results agree (results: TBD-conformance).
  - **nearcore reading** means the rule was read in the nearcore source at b7b4737 and not
    exercised here.
  - **recalled** means it was neither read nor run. Treat it as an assumption.

## Units

- **Gas** is in **Ggas** (1 Tgas = 1000 Ggas), rounded to the nearest Ggas. The fee table is
  `modules/NearFees.tla`; its rounding error is under [N-precision](#under-approximations-unsound-they-can-hide-bugs).
- **Sizes have two units. Convert explicitly.**
  - `NearAsync` sizes (`r.res.sz`, `RValSz(v, n)`, `OSz(O, n)`, `DataOfSz`, and the burn size
    in `GasBurn[k].per * O.sz`) are in **KB, rounded up**, with **1 KB = 1000 bytes**. That
    matches the `NearFees` scaling and the calibrated tables, whose per-size slopes are per
    1000 bytes (`conformance/README.md`, "Units in the model").
  - `NearFees` per-byte operators (`DataBytesFee`, `FunctionCallBytesFee`, `AddKeyFcBytesFee`,
    `DeployBytesFee` and their send/exec parts) take **bytes**.
  - Bytes to model size: `sz = (n + 999) \div 1000`. Model size to bytes for a fee:
    `NearFees!DataBytesFee(sir, 1000 * r.res.sz)`. This overstates the bytes by up to 999, so it
    overstates the fee by up to about 65 Ggas per waiting receiver (cross-shard rate) or 34 Ggas
    (same account).

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
- **Validated:** nearcore reading.

### R2. A data receipt may arrive before or after the receipt that waits on it

- **Rule:** A receipt that waits on results runs only once every input has arrived. If data
  arrives first, it is stored. If the receipt arrives first, it is postponed and counts its
  missing inputs, and the last arriving input triggers execution.
- **nearcore:** `runtime/runtime/src/lib.rs:1647-1715` (`process_action_receipt`: postpone and
  count), `:1440-1528` (data arrival: store, decrement the count, and execute at zero).
- **Model:** `Runnable`: a callback is runnable only once its result is present.
- **Validated:** nearcore reading.

### R3. One atomic step per receipt

- **Rule:** Each action receipt executes as one step: all its actions, then a single commit or
  rollback of its state changes, then its outgoing receipts (children, data, refunds). No other
  receipt's effects interleave inside it.
- **nearcore:** `runtime/runtime/src/lib.rs:827-1274` (`apply_action_receipt`): state
  committed before start `:903-905`, the actions loop `:946-1005`, then commit `:1079-1083` or
  rollback `:1084-1087`.
- **Model:** `Exec(r, O)`, which takes the `Verdict` and dispatches to `Commit`, `FailOOG` or
  `FailP`. The contract conjoins its own state update.
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Validated:** nearcore reading. <!-- conformance -->

### C2. A callback can itself fail

- **Rule:** A callback that runs can still fail: out of gas, a panic, or a limit. Its own state
  changes revert (R4), its deposit is refunded (R5), and nothing undoes the receipts that ran
  before it. The hazard is a callback that runs and fails, not one that is skipped.
- **nearcore:** the same paths as R4/R5; there is no special case for callbacks in
  `apply_action_receipt` (`runtime/runtime/src/lib.rs:827-1274`).
- **Model:** the callback is an ordinary receipt for `Exec`. It can fail by gas (gas mode) or
  by `ForcedFail` (fault mode).
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Model:** `r.res = [ok, v, sz]` with `v` a number, `EMPTY`, `MAL` or `NONEMPTY`, built by
  `RVal`; helpers `IsNum`, `IsEmpty`, `IsFailed`, `NumOr`. No results: `NoRes` with
  `NoRes.v = NOPR` (`NoResults(r.res)`), and `IsNum(NoRes) = FALSE`.
- **Validated:** nearcore reading. <!-- conformance -->

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
  Handlers may use `r.res.sz` as the burn size. Fee: `NearFees!DataBytesFee(sir, bytes)`, which
  takes **bytes**.
- **Validated:** nearcore reading.

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
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Validated:** nearcore reading. <!-- conformance -->

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
  `runtime/near-vm-runner/src/logic/gas_counter.rs:126-150`, `:155-174`, `:205-213`;
  `runtime/runtime/src/action_validation.rs:350-351` (zero gas), applied at
  `runtime/runtime/src/lib.rs:968-978`.
- **Model:** `Need = Burn(r, O) + Σ_children (c.gf + Σ c.gs)` (`KidsCost`); `GasOK(r, O)` is
  `Need ≤ Σ r.g`. Otherwise the verdict is `"oog"` and `FailOOG` applies. A failing outcome
  (`err`) whose burn key exceeds the attached gas is labelled `"oog"` (`PanicOOG`; only the
  label differs). `ZeroGasKid` fails the creator when a child call gets 0 gas.
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Model:** `Give` assigns `g` to the children's weighted actions (`Share`, `FloorSum`), in
  (child id, action index) order. That matches host-call order whenever a handler builds each
  child completely before creating the next; a handler that interleaves appends across
  promises can see the remainder (at most `n − 1` gas units for `n` weighted actions, far below
  1 Ggas) go to a different action. **Per action:** each function-call action of a receipt has
  its own gas and its own promise manager, so only that action's leftover is split, over the
  children it created (`runtime/runtime/src/function_call.rs:61`, `:343-345`; the rest is
  refunded, `runtime/runtime/src/lib.rs:1311-1315`). An outcome with `pa` (one
  `[gk, sz, kids]` record per action) gets this per-action check and split (`PerAction`,
  `ActNeed`, `Alloc`); without `pa` a receipt is one action. Per-call defaults are
  `GasCall[key] = [st, wt, fee]`
  (`CallKey`/`CallDef2` look up `"acct.method"`, then `"method"`), overridden by `WithCall`,
  `WithStatic`, `WithWeight` and `WithFee`.
- **Validated:** nearcore reading. <!-- conformance -->

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
  `NearKeys` through `KeyFee`, which omits the per-byte part of a function-call AddKey (see
  N-keyfee).
- **Validated:** nearcore reading. <!-- conformance -->

### G5. Out-of-gas revert scope

- **Rule:** Running out of gas is an ordinary failure of that receipt. Its state reverts, it
  has no children, and its deposit is refunded (R5). Its callback, if any, gets `Failed` (C1).
  The gas burnt up to the failure stays burnt. The rest of the prepaid gas, `prepaid −
  gas_burnt` (not `gas_used`), is refunded to the signer.
- **nearcore:** `runtime/runtime/src/function_call.rs:100-138` (the abort becomes the action
  error); `runtime/runtime/src/lib.rs:535-541`, `:1304-1316` (failure refunds against
  `gas_burnt`, success against `gas_used`).
- **Model:** `FailOOG`, with the `oog` ghost recording `<<tx, method>>`.
- **Validated:** nearcore reading. <!-- conformance -->

---

## Accounts

### A1. Account existence

- **Rule:** Before each action the runtime checks the receiver account. `CreateAccount` needs it
  absent. A Transfer to an absent account fails unless implicit creation applies (A3). All other
  actions (FunctionCall, AddKey, DeleteKey, Stake, Deploy, DeleteAccount, ...) need it present.
  At 87+ the account must also be initialized; an uninitialised `0u` account counts as absent.
- **nearcore:** `runtime/runtime/src/actions.rs:814-895` (`check_account_existence`), called at
  `runtime/runtime/src/lib.rs:600-605`.
- **Model:** the `Exists` constant (initial accounts) and `AcctExists`.
- **Validated:** nearcore reading.

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
  `UniversalOn`, 87+) universal.
- **Validated:** nearcore reading. The fee-by-pattern rule: <!-- conformance -->

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
  action). A created account has no code (`HasCode`) unless it is eth-implicit, so calls to a
  created NEAR-implicit, deterministic or universal account fail; the NEAR-implicit key, the
  rest of the universal uninitialised state (N-universal) and the charge (N-gas-money) are not
  modelled.
- **Validated:** nearcore reading. <!-- conformance -->

### A4. Transfer to a missing named account fails and refunds

- **Rule:** A Transfer to an absent named account fails with `AccountDoesNotExist`, so the
  receipt fails and its deposit goes back to `refund_to` or the predecessor (R5). The same
  happens to a batched Transfer to an absent implicit id (A3).
- **nearcore:** `runtime/runtime/src/actions.rs:842-849`; refund as in R5.
- **Model:** `ExecTransferFail(r)`.
- **Validated:** nearcore reading. <!-- conformance -->

### A5. Function call to an account without code fails

- **Rule:** A FunctionCall to an existing account with no contract fails with
  `CompilationError(CodeDoesNotExist)`. Like any failure, the receipt reverts and refunds (R4,
  R5). A FunctionCall to an absent account fails earlier with `AccountDoesNotExist` (A1).
- **nearcore:** `runtime/runtime/src/function_call.rs:309-312` (`VMOutcome::nop_outcome` with
  `CodeDoesNotExist`); `runtime/runtime/src/actions.rs:874-887` (`AccountDoesNotExist`,
  `AccountNotInitialized`).
- **Model:** `Exec` fails a function call whose receiver is missing or has no code before the
  handler's outcome counts (`CallTargetOK`, `HasCode`); the accounts with code are the
  overridable definition `Contracts` (default `Accounts`). `CallsNeedCode <- FALSE` turns the
  rule off for older models. `NearKeys.FailNoCode` and `ExecNoCode` are the same rule as an
  explicit step.
- **Validated:** nearcore reading. <!-- conformance -->

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
- **Validated:** nearcore reading. <!-- conformance -->

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
  `:282-301` (`check_and_compute_new_allowance`), `:365-394` (call order in
  `verify_and_charge_tx_ephemeral`), `:177-194` (`AccessKeyNotFound`; bootstrap at `:184-186`),
  `:200-202` (`is_bootstrap`); `runtime/runtime/src/actions.rs:133-157` (`try_refund_allowance`).
- **Model:** `NearKeys`: `KeyAllows`, `KeyCanSign`, `SubmitSigned`, `Perm`, `FullPerm`. For a
  function-call key it checks the receiver, the method (an empty list allows every method,
  `verifier.rs:238`), zero deposit, and that the transaction is a single function call (no
  Transfer, Stake or key action, no multi-call receipt). It does not check allowances
  (N-allowance) or key actions a model bundles into a call receipt (N-fckey-one-action). There
  is no bootstrap path.
- **Validated:** nearcore reading. <!-- conformance -->

### K3. AddKey and DeleteKey

- **Rule:** AddKey, DeleteKey, Stake, Deploy and DeleteAccount need the actor to be the account
  itself. In practice that means a transaction signed by the account, or the account's own
  promise to itself; after a `CreateAccount` in the same receipt, the new account is the actor.
  AddKey of a key that already exists fails (`AddKeyAlreadyExists`). DeleteKey of a key that does
  not exist fails (`DeleteKeyDoesNotExist`). Either failure fails **the whole receipt** (M1).
- **nearcore:** `runtime/runtime/src/actions.rs:755-801` (`check_actor_permissions`), `:202`
  (CreateAccount sets the actor); `runtime/runtime/src/access_keys.rs:157-164` (AddKey exists),
  `:83-89` (DeleteKey absent).
- **Model:** `NearKeys`: `AddKeyRcpt`, `DelKeyRcpt`, `ExecKeyAct`, `KeyPresent`.
- **Validated:** nearcore reading. <!-- conformance -->

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
  is one pool unless `TokBatchPerAction <- TRUE` (G3, N-batch-oog).
- **Validated:** nearcore reading. <!-- conformance -->

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
  `forward_or_buffer_receipt`, except *instant* receipts (N-instant).
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
- **Validated:** nearcore reading. <!-- conformance --> (the self-call priority probe).

### S2. Ordering otherwise

- **Rule:** Beyond R2 (a callback waits for its inputs) and S1, the model lets any enabled
  receipt run next. nearcore is more constrained (see N-order).
- **nearcore:** `runtime/runtime/src/congestion_control.rs:292` (`forward_or_buffer_receipt`),
  `chain/chain/src/sharding.rs:13` (`shuffle_receipt_proofs`).
- **Model:** `\E r \in Runnable : ...` (or `Schedulable`) in `Next`.
- **Validated:** nearcore reading (as a description of what is over-approximated).

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
- **Validated:** nearcore reading. <!-- conformance --> The sim simplifies epochs (one validator,
  no minimum stake, flat rewards).

### B2. Balance must cover storage (`LackBalanceForState`)

- **Rule:** After a receipt's actions succeed, the receiver's **liquid + locked** balance must
  cover its storage (`storage_usage × storage_amount_per_byte`, 1e19 yocto per byte at 88). If
  not, the receipt fails with `LackBalanceForState` and everything reverts. **Exemption:** a
  zero-balance account, one using at most 770 bytes of storage (NEP-448), always passes.
  Transactions are checked the same way at conversion.
- **nearcore:** `runtime/runtime/src/lib.rs:1008-1030`; `runtime/runtime/src/verifier.rs:48-83`
  (`check_storage_stake`: `amount + locked` at `:64-73`, the zero-balance exemption at `:77-79`),
  `:25` (`ZERO_BALANCE_ACCOUNT_STORAGE_LIMIT = 770`), `:88-90`, `:375-387`;
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:7`.
- **Model:** the `StorageFloor` constant: what liquid + locked must cover after a function
  call (`Affordable`; locked counts for `StakingAcct`, `LockedOf`). Storage usage is not tracked
  byte by byte; give a zero-balance (exempt) account floor 0 (see N-storage).
- **Validated:** nearcore reading.

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
- **Validated:** NEP text and near-contract-standards source read. <!-- conformance -->

### T2. `ft_resolve_transfer`

- **Rule:** It must be callable only by the token itself. `unused` = `amount` if the result is
  Failed or does not parse as a U128, else `min(v, amount)`. `refund = min(unused, receiver
  balance)` moves back to the sender. If the sender has unregistered, the refund is burnt (total
  supply drops). It returns the amount used.

  **Private-ness is the integrator's job.** `FungibleToken::internal_ft_resolve_transfer` does
  no caller check. The `#[private]` attribute comes from the `impl_fungible_token_core!` macro
  (`macros.rs:46`); a contract that implements `FungibleTokenResolver` by hand must add it.
- **Sources:** NEP-141 `:306-325`; near-contract-standards 5.29.1 `core_impl.rs:169-235`,
  `macros.rs:46-56`. 5.24.0 and later read the result with
  `promise_result_checked(0, MAX_RESULT_LENGTH)`, so an oversized result counts as all unused;
  5.23.0 uses `promise_result(0)`.
- **Model:** `TokenCommon.ResolveRefund`, `NumOr`. The model's resolver accepts calls from the
  token only. The burn path is reached when the sender calls `storage_unregister(force)`
  between the transfer and the resolver (T4).
- **Validated:** near-contract-standards source read (5.23.0-5.29.1). <!-- conformance -->

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
  reserve panics, resolver gas from `GasCall`). `TokOnTransferStatic[t]` /
  `TokOnTransferWeight[t]` override the shape (-1 = its default); a `GasCall` entry for the
  resolver wins in both shapes. `Nep245` keeps the reserve shape. The measured values per
  version come from `conformance/` (`docs/CONFORMANCE.md`).
- **Validated:** 5.x read; the older behaviour is recalled. <!-- conformance -->

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
- **Model:** `Nep145`: `SdAct`, `SuAct` (`SuArgs(force)`; both booleans are `NONEMPTY` bytes,
  `ev.unreg` / `ev.unregBurnt` say what happened), `SbAct` (`Some` is the number `total` = min,
  `null` is `NONEMPTY`). Deviation `sdRefundToAccount` refunds to `account_id` instead.
- **Validated:** source read.

### T5. NEP-245 multi token

- **Rule:** The same transfer, resolve and refund rules as T1/T2, per token id. Every transfer
  needs 1 yocto.
- **Sources:** NEP-245 `:88`, `:124`, `:164-179`, `:304-330`.
- **Model:** `Nep245`. Single-id transfers only; no batch, no approvals, no storage management.
- **Validated:** NEP text read; no reference implementation checked.

### T6. wNEAR

- **Rule:** `near_deposit` registers the predecessor out of the deposit if needed and mints the
  rest; it returns nothing (`EMPTY`). `near_withdraw` needs 1 yocto, burns `amount`, and
  returns a Transfer of the amount to the caller (`RProm`).
- **Sources:** none local. Recalled.
- **Model:** `WNear`. The shipped gas keys come from the repo's wNEAR-like probe
  (`conformance/`); recalibrate for a real deployment.
- **Validated:** recalled. <!-- conformance --> The probe checks the probe, not a production
  deployment.

### T7. Token deviations

- **Rule:** These are non-standard behaviours, chosen per token account:
  - `retBytes`: `ft_transfer` returns non-empty bytes;
  - `resolveIgnoresResult`;
  - `resolveNoCap`;
  - `sdRefundToAccount`;
  - `autoRegister`.

  An unregistered receiver is a scenario (the initial registration set), not a deviation.
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
- **Validated:** gas mode: nearcore reading. <!-- conformance --> Fault mode is an abstraction by
  design.

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

- **N-order. Per-sender-receiver ordering.** nearcore delivers receipts from one shard to
  another in order per route (outgoing buffers drain in order,
  `runtime/runtime/src/congestion_control.rs:292`), and keeps group order when it shuffles
  incoming receipt proofs (`chain/chain/src/sharding.rs:13`). The model lets any enabled receipt
  run next. It can show a reordering between two receipts of the same pair that nearcore would
  not produce.
- **N-shards. Shards and cross-shard latency.** There are no shards, no blocks and no
  latency; any causally enabled order is allowed. This covers every real schedule **with the
  local-priority switch OFF** (with it ON, see N-local-congested), but some model schedules need
  timing a network does not produce.
- **N-congestion. Congestion control, bandwidth scheduler, delayed receipts.** These delay
  receipts. With the local-priority switch **OFF**, the model's free ordering covers every delay.
  With it **ON**, it does not: see N-local-congested. A finding about latency bounds needs the
  real scheduler. Congestion can also reject new transactions, which the model treats as "not
  submitted".
- **N-instant. Instant receipts.** A receipt holding a single `DeleteAccount` with no inputs,
  and a `PromiseYield` receipt, run immediately after their creator in the same chunk
  (`core/primitives/src/receipt.rs:467-491`, `runtime/runtime/src/lib.rs:1222-1224`,
  `:2748-2775`). The model lets other receipts interleave.
- **N-local-off.** With the local-priority switch (S1) off, a self-signed first receipt may run
  after receipts that nearcore, on an uncongested chunk, would run later. Such orders are
  reachable under congestion (S1), so a violation found this way is not a false positive unless
  the receiving chunk provably cannot be at its limit.
- **N-local-per-account.** With the switch on, `LocalPriorityOK` orders local receipts first
  only per receiving account; nearcore's rule is chunk-wide. Other accounts' receipts may still
  overtake a pending local receipt in the model.
- **N-tx-validity. Nonces and transaction validity.** Nonce rules (`verify_nonce`,
  `runtime/runtime/src/verifier.rs:254-280`), expiry (`runtime/runtime/src/lib.rs:2031-2034`),
  balance-for-cost and signature checks are absent. `Submit` always succeeds, so real
  executions are a subset (nonce reuse, replay protection and gas-key nonces are not modelled).
- **N-allowance. Access-key allowance.** Not tracked (K2). A transaction nearcore refuses for a
  short allowance is accepted by the model.
- **N-fckey-one-action. Function-call keys and bundled key actions.** nearcore refuses a
  transaction signed by a function-call key unless it has exactly one action
  (`runtime/runtime/src/verifier.rs:213-217`). `KeyCanSign` refuses Transfer, Stake, key
  actions and multi-call receipts, but cannot see key actions a model bundles into a call
  receipt with `WithKeyActs`; such a model must require a full-access key itself.
- **N-create-account. CreateAccount restrictions.** There is no `CreateAccount` action in the
  modules. Its rules (a short top-level id only by one privileged account, a sub-account only by its
  parent, no explicit creation of implicit ids; `runtime/runtime/src/actions.rs:166-202`,
  `:822-839`) are not enforced. A model that puts accounts into existence by fiat allows
  creations nearcore refuses.
- **N-time. Block and epoch timing.** There are no heights or timestamps; epochs are an
  abstract tick. Contracts reading `block_timestamp` or `epoch_height` need their own
  abstraction. A time-based guard modelled as free nondeterminism is an over-approximation.

### Under-approximations (unsound: they can hide bugs)

- **N-local-congested. Local priority under chunk limits.** With the switch ON, the model
  assumes the receiving chunk is below its compute and storage-proof limits. When it is not, the
  local receipt goes to the back of the delayed queue and every receipt already delayed runs
  first (`runtime/runtime/src/lib.rs:2513-2521`, `:2800-2813`,
  `runtime/runtime/src/congestion_control.rs:864`). `LocalPriorityOK` forbids that order, so a
  bug that needs it is missed. Mitigation: run with the switch OFF as well (S1).
- **N-precision. Rounding of fees and burns.** Fees (`NearFees`) and calibrated burns are
  rounded to the nearest Ggas. Error bounds:
  - at most 0.5 Ggas per base fee entry;
  - per-byte terms at most `0.5 + 0.001 + 0.5e-6 × n` Ggas for `n` bytes (≤ 0.51 Ggas up to
    20 KB, ≤ 2.6 Ggas at 4 MiB);
  - roughly **3 Ggas per receipt** in total (receipt base and one action, send and exec, plus
    the burn).

  The error can go either way, so a predicted gas edge is accurate only to that bound summed
  over the receipts on the path. Window edges closer together than that, and windows narrower
  than it, are not trustworthy. Conformance compares gas at 0.1 Tgas resolution. The KB
  rounding of sizes ([Units](#units)) adds to this when sizes feed fees or burns.
- **N-batch-oog. Per-action out-of-gas in batches.** nearcore checks each function-call action
  against its own gas and splits only that action's leftover (G3). `NearAsync` does the same
  for an outcome with `pa`; the token batch emits it with `TokBatchPerAction <- TRUE`. By default
  (and with the whole-receipt `batch/<shape>` keys `CalibStd` measures) a batch is one pool: a
  batch where one action is starved while another has slack fails in nearcore but not in the
  model, and the leftover split can differ.
- **N-burn. Trie and storage gas variation.** Burns are constants per (method, path), affine in
  one size variable at most, measured in one sim world. Real burns move with trie shape, key
  count, argument length and network (trie-node pricing). A real out-of-gas at a prepaid amount
  the model calls safe is possible near any calibrated edge. Treat windows as approximate. They
  are tied to the calibration's provenance (`docs/VERSIONING.md`).
- **N-keyfee. AddKey per-byte fee.** `NearKeys.KeyFee` charges a function-call AddKey only its
  base fee and drops the per-byte part (`NearFees!AddKeyFcBytesFee`, about 3.9 Ggas per KB of method
  names to the same account, 49.6 Ggas per KB cross-shard). The creator's need is under-charged, so an out-of-gas at creation can be
  missed.
- **N-burn-fail. Burn of a failing receipt.** Only the verdict is modelled, not how much a
  failing receipt burnt. Gas-griefing amounts are not computed.
- **N-storage. Storage staking details.** `storage_usage` is not tracked per byte, so a write
  that exceeds the balance's storage cover (`LackBalanceForState`, B2) appears only through the
  floor you configure (liquid + locked must cover it; a zero-balance account takes floor 0). A
  contract that runs out of storage stake mid-flow may fail in nearcore and not in the model.
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
  "when idle" are never checked on that path. A `DeleteAccount` beneficiary payment
  (`runtime/runtime/src/actions.rs:382-386`) is not modelled.
- **N-universal. Universal accounts are created uninitialised.** nearcore creates a `0u`
  account from a Transfer without code, keys or data; every action but Transfer and its own state
  init then fails with `AccountNotInitialized` (`runtime/runtime/src/actions.rs:276-282`,
  `:880-887`). The model fails function calls to it (`HasCode`); other actions on it (key
  actions, Stake) are not checked for initialisation.
- **N-reward. Gas rewards.** Up to 86, a contract earned 30% of the gas its function calls
  burnt; 87 sets that to 0 (`core/parameters/res/runtime_configs/87.yaml:1-7`,
  `runtime/runtime/src/lib.rs:1108-1137`). At 84-86 a contract's balance grows in a way the model
  does not track.
- **N-validator. Validator rewards beyond the abstract tick.** Seat price, kickouts, slashing,
  reward shares and the exact release epoch are absent (`runtime/runtime/src/lib.rs:1717`).
  A staking contract's share-price arithmetic over real rewards is not checked.
- **N-limits. Protocol limits.** At 88: 100 actions per receipt, 1024 promises per call, 128
  input dependencies, 4 MiB arguments and return data, 4 MiB receipt size, 256-byte method names
  (`core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:244-256`).
  Also the per-receipt storage-proof limit (feature at 86, all actions at 87;
  `runtime/runtime/src/lib.rs:925-948`, `:987-999`). Exceeding any of them fails the receipt in
  nearcore; the model does not fail for them.
- **N-one-yocto. `one_yocto_on_promise` (85+).** A contract with zero balance may attach
  exactly 1 yocto to a promise function call without having it
  (`runtime/near-vm-runner/src/logic/host.rs:3579-3593`;
  `core/parameters/res/runtime_configs/85.yaml:1`). A model that requires a balance for that
  attachment refuses an execution nearcore allows.
- **N-input-87. Promise-input size limit at 87.** At 87 a callback whose inputs exceed 4,194,944
  bytes fails without running (C4). Unless the model's sized results trigger this, it is
  missed. At 88 it cannot happen.
- **N-delete-account. DeleteAccount details.** Large-state refusal, the staking check, gas-key
  burning and the beneficiary transfer (`runtime/runtime/src/actions.rs:330-410`, `:777-792`) are
  not modelled.

### Scope limits

- **N-and. `promise_and` (joint promises).** Callbacks with several inputs
  (`runtime/near-vm-runner/src/logic/host.rs:2486-2535`) are not modelled: one callback waits
  on one result. The ordering and partial-failure combinations of joint inputs are unexplored.
- **N-yield. Yield/resume** (`promise_yield_create` / `promise_yield_resume`,
  `runtime/near-vm-runner/src/logic/host.rs:4245`, `:4473`; NEP-519). The timeout after
  `yield_timeout_length_in_blocks` = 200 blocks resumes with `Failed`
  (`runtime/runtime/src/lib.rs:3113`; `.snap:274`). This path is absent; a yield modelled as
  a plain callback misses the timeout branch.
- **N-delegate. Delegate actions / meta-transactions** (NEP-366;
  `runtime/runtime/src/actions.rs:453`). With a relayer, the signer is the relayer and the
  predecessor is the delegating user. Contracts that use `signer_account_id` for authorisation
  behave differently.
- **N-global. Global contracts** (NEP-591; `runtime/runtime/src/global_contracts.rs:25`, `:65`).
  Code shared by hash or by account and updated in place is absent. An eth-implicit account's
  code is a global contract (A3), but only its existence matters to the model.
- **N-deterministic. Deterministic and universal account ids, state init** (NEP-616;
  `runtime/runtime/src/deterministic_account_id.rs`, `runtime/runtime/src/universal_account_id.rs`).
  The fee kinds exist in `NearFees`; the state-init actions, their fees and the no-key bootstrap
  transaction (K2) do not.
- **N-gas-keys. Gas keys** (85+: `TransferToGasKey`, `WithdrawFromGasKey`, gas-key nonces;
  `core/primitives-core/src/version.rs:615`). Absent.
- **N-deploy. DeployContract and code upgrades mid-flow.** Code is the TLA+ handler; it does
  not change during a run.
- **N-compute. Compute costs versus gas.** Some actions charge more compute than gas (for
  example deploy, `core/parameters/res/runtime_configs/84.yaml`). This affects chunk packing,
  that is timing only, which the free ordering covers with the local-priority switch OFF.
- **N-wasm. Contract semantics.** The model's handlers are hand-written abstractions of the
  contract. Wasm-level behaviour (panics on overflow, serialization, unexpected host errors) is
  covered only by replaying counterexamples in the sim.
- **N-events. Logs and events (NEP-297).** Not modelled. A failed receipt keeps its logs
  (`runtime/runtime/src/lib.rs:535-541`), so a log is not proof of a committed write.
- **N-views. View calls.** Views are pure reads outside receipts (`ProhibitedInView` for every
  promise host function). `ft_balance_of`/`ft_total_supply` are modelled as reads of the
  ledger.
- **N-resharding. Resharding and missing chunks.** The model assumes a fixed layout and a
  finalized history.
