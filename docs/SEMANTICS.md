# Semantics and trust

This page lists every runtime rule the library models. For each rule it gives the nearcore code
the rule comes from, the model operator that encodes it, and how far the rule has been checked.
After that comes everything the library does **not** model, and what each omission could hide.

## Reference revision

- **nearcore:** 2.14.0-rc.5, commit `b7b4737cab46f17a6daa2ed694d7aebbd204363a`. This is the
  revision near-contract-sim pins. Every `path:line` below is at this revision.
- **Protocol version:** 88, unless a rule says otherwise. 88 is `STABLE_PROTOCOL_VERSION`
  (`core/primitives-core/src/version.rs:694` @ b7b4737), the version a non-nightly rc.5 binary
  and the sim run. Mainnet runs 86 (at the time of writing). At 86 the fee table is the same as 85's, because there is no
  `86.yaml` (`core/parameters/src/config_store.rs:238-246` @ b7b4737). The rule changes between
  84 and 88 are noted where they matter.
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
  module is named. The platform modules are still being written, so these names may still
  change; `TBD(WS1)` marks an encoding that is not settled yet.
- **Validated:** one of these levels:
  - **sim** means a per-receipt conformance run against near-contract-sim agreed with the model.
    "sim (prior)" means it was checked during the library's development, before this repo
    existed, and still has to be re-run by `conformance/` (see `docs/CONFORMANCE.md`).
    "sim (planned)" means a probe is planned but has not run yet.
  - **nearcore** means the rule was read in the nearcore source at b7b4737 and not exercised.
  - **recalled** means it was neither read nor run. Treat it as an assumption.

Units: gas is in **Ggas** (1 Tgas = 1000 Ggas), rounded to the nearest Ggas. The fee table is
`modules/NearFees.tla`.

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
  `m`, arguments `a`, deposit, refund target `rto`, callback link `cb`, gas fields
  `gs`/`gw`/`gf`/`g`). Data results arrive in the callback's `r.res` (`DataOf`).
- **Validated:** nearcore.

### R2. A data receipt may arrive before or after the receipt that waits on it

- **Rule:** A receipt that waits on results runs only once every input has arrived. If data
  arrives first, it is stored. If the receipt arrives first, it is postponed and counts its
  missing inputs, and the last arriving input triggers execution.
- **nearcore:** `runtime/runtime/src/lib.rs:1647-1715` (`process_action_receipt`: postpone and
  count), `:1440-1528` (data arrival: store, decrement the count, and execute at zero).
- **Model:** `Runnable`: a callback is runnable only once its result is present.
- **Validated:** nearcore.

### R3. One atomic step per receipt

- **Rule:** Each action receipt executes as one step: all its actions, then a single commit or
  rollback of its state changes, then its outgoing receipts (children, data, refunds). No other
  receipt's effects interleave inside it.
- **nearcore:** `runtime/runtime/src/lib.rs:827-1210` (`apply_action_receipt`): state
  committed before start `:903-905`, the actions loop `:949-1004`, then commit `:1079-1083` or
  rollback `:1084-1087`.
- **Model:** `Exec(r, O)`, which takes the `Verdict` and dispatches to `Commit`, `FailOOG` or
  `FailP`. The contract conjoins its own state update.
- **Validated:** nearcore; sim (prior) for function-call receipts.

### R4. Revert scope: only the failing receipt

- **Rule:** When a receipt fails, nearcore rolls back that receipt's state changes and drops
  the receipts it would have created. It also drops its validator proposals and burnt or
  subsidised amounts, but keeps gas burnt and logs. Receipts that already committed, earlier in
  the same transaction, stay committed. Nothing is "transaction-atomic".
- **nearcore:** `runtime/runtime/src/lib.rs:535-541` (`ActionResult::set_error` clears
  `new_receipts`, `validator_proposals`, `tokens_burnt` and `subsidized_amount`), `:525`
  (`merge` routes an error to `set_error`), `:1084-1087` (rollback); in function calls,
  children exist only if the VM did not abort (`runtime/runtime/src/function_call.rs:100-138`
  sets the error, `:151-234` builds children only when `execution_succeeded`).
- **Model:** `FailP` / `FailOOG` create no children; the contract keeps its own variables
  unchanged when `~Ok(r, O)`.
- **Validated:** sim (prior); nearcore.

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
  `runtime/runtime/src/lib.rs:1046-1053`.
- **Model:** the refund target field `rto` (default the predecessor) and a refund receipt
  (`REFND`) executed by `ExecTransfer`. Refund-to-missing-account burning: TBD(WS1), probably
  not modelled (see N-refund-burn under [Not modelled](#not-modelled)).
- **Validated:** sim (prior) for the refund to `rto`; nearcore for the burn.

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
- **Validated:** nearcore; sim (prior).

### C2. A callback can itself fail

- **Rule:** A callback that runs can still fail: out of gas, a panic, or a limit. Its own state
  changes revert (R4), its deposit is refunded (R5), and nothing undoes the receipts that ran
  before it. The hazard is a callback that runs and fails, not one that is skipped.
- **nearcore:** the same paths as R4/R5; there is no special case for callbacks in
  `apply_action_receipt` (`runtime/runtime/src/lib.rs:827-1210`).
- **Model:** the callback is an ordinary receipt for `Exec`. It can fail by gas (gas mode) or
  by `ForcedFail` (fault mode).
- **Validated:** sim (prior); nearcore.

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
- **Model:** `r.res = [ok, v]` with `v` a number, `EMPTY`, `MAL` or `NONEMPTY`, built by
  `RVal`; helpers `IsNum`, `IsEmpty`, `IsFailed`, `NumOr`. No results: `NoRes` with
  `NoRes.v = NOPR`, and `IsNum(NoRes) = FALSE` (D4).
- **Validated:** nearcore; sim (prior) for `EMPTY`/`NONEMPTY` shapes of token methods.

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
- **Model:** a size field on data receipts and `r.res.sz` (D3): `RVal(v)` has size 0 and
  `RValSz(v, n)` carries `n` (also `DataOfSz`, `RetSz`, `OSz`). Handlers may use `r.res.sz` as
  the burn size. Fee: `DataBytesFee(sir, n)` in `NearFees`.
- **Validated:** nearcore. The size unit is documented in `NearAsync`.

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
- **Validated:** nearcore; sim (prior) for token resolver chains.

---

## Gas

### G1. Prepaid gas

- **Rule:** A transaction's function call carries prepaid gas `g`, at most
  `max_total_prepaid_gas` = 1000 Tgas (protocol 83+). The call can use up to `g`: its burnt gas
  plus what it reserves for children may not exceed `g`. `env::prepaid_gas()` is the gas
  attached to this function-call action.
- **nearcore:** `runtime/runtime/src/function_call.rs:274` (`prepaid_gas: function_call.gas`);
  `runtime/near-vm-runner/src/logic/gas_counter.rs:126-150` (`deduct_gas`: fails with
  `GasExceeded` when `burnt + promises_gas > prepaid_gas`);
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:243`,
  `core/parameters/res/runtime_configs/83.yaml:8`.
- **Model:** `WithGas(r, p)` on the first receipt (`Submit(WithGas(...))`); `LastGas(r)` is
  what the receipt sees as `env::prepaid_gas()`.
- **Validated:** sim (prior).

### G2. Static gas, checked at promise creation

- **Rule:** Attaching static gas `s` to a child function call reserves `s` from the creator at
  once. The child's send fee is burnt and its exec fee prepaid at the same moment. If the
  reservation does not fit, the creating call fails right there (`GasExceeded`), so neither it
  nor any child commits (R4). This is the safe case: nothing is half-created.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:3578` (`prepay_gas(gas)` in
  `promise_batch_action_function_call_weight`), `:3564-3577` (base and per-byte fees first);
  `runtime/near-vm-runner/src/logic/gas_counter.rs:126-150`.
- **Model:** `Need = Burn(r, O) + Σ_children (c.gf + Σ c.gs)` (`KidsCost`); `GasOK(r, O)` is
  `Need ≤ Σ r.g`. Otherwise the verdict is `"oog"` and `FailOOG` applies.
- **Validated:** sim (prior).

### G3. Weight and the leftover split (`distribute_gas`)

- **Rule:** After a successful call, its unused gas `U = prepaid − used` is split among the
  function-call actions it created that have weight > 0, in creation order (receipt, then action
  index). Each gets `⌊U·w/W⌋` and the last weighted action gets the remainder. If `W = 0` (or
  `U = 0`), nothing is distributed and the leftover is refunded to the signer as gas.
- **nearcore:** `runtime/runtime/src/receipt_manager.rs:679-719` (`distribute_gas`);
  `runtime/runtime/src/function_call.rs:343-347` (called with
  `unused_gas = function_call.gas − outcome.used_gas`, skipped for views). NEP-264.
- **Model:** `Give` assigns `g` to the children's weighted actions (`Share`, `FloorSum`).
  Per-call defaults are `GasCall[key] = [st, wt, fee]` (`CallKey`/`CallDef2` look up
  `"acct.method"`, then `"method"`), overridden by `WithCall`, `WithStatic`, `WithWeight` and
  `WithFee`.
- **Validated:** sim (prior): the split reproduced with 0 mismatches.

### G4. Who pays action send and exec fees

- **Rule:** The account that *creates* a receipt pays for it out of its own gas, at creation:
  the receipt base fee (send burnt, exec prepaid), and each action's send fee (burnt) and exec
  fee (prepaid). A `.then` also burns a data receipt's send and exec base fee for each
  dependency. A Transfer's fee depends on the receiver's account type (A2). For a transaction's
  first receipt the signer pays in the same way, at conversion. The child's exec fee is then
  burnt when the child executes, from the gas the creator prepaid.
- **nearcore:** `runtime/near-vm-runner/src/logic/host.rs:3621-3661`
  (`promise_batch_action_transfer`: `burn = send_fee`, `use = send_fee + exec_fee`, both via
  `pay_action_accumulated` on the creator's counter), `:2345-2365` (`pay_gas_for_new_receipt`:
  receipt base plus a data-receipt base per dependency), `:5379-5410` (`pay_action_base`,
  `pay_action_per_byte`); `runtime/runtime/src/lib.rs:911-914`, `:588-592` (exec fees burnt at
  execution); `runtime/runtime/src/config.rs:86-224` (`total_send_fees`, transactions).
- **Model:** fee values in `modules/NearFees.tla` (`ReceiptFee`, `SendFee`, `ExecFee`,
  `ActionFee`, `TransferFeeTotal`, `DataDepFee`, `DataBytesFee`, per-byte operators).
  Accounting (D6): function-call children have `c.gf` = their prepaid exec fee, and their send
  fee sits inside the creator's calibrated burn. Action-only children (Transfer, CreateAccount,
  AddKey, DeleteKey, Stake, ...) have `c.gf` = send + exec from the table, so one burn key works
  for named and implicit receivers. `NearAsync` reads the table through
  `NearFeeTable == INSTANCE NearFees` (`XferFee`, `StakeFee`, `BuiltinFee`).
- **Validated:** nearcore for the fee values and who pays; sim (prior) for the Transfer and
  Stake exec fees landing on the creator.

### G5. Out-of-gas revert scope

- **Rule:** Running out of gas is an ordinary failure of that receipt. Its state reverts, it
  has no children, and its deposit is refunded (R5). Its callback, if any, gets `Failed` (C1).
  The gas burnt up to the failure stays burnt. The rest of the prepaid gas, `prepaid −
  gas_burnt` (not `gas_used`), is refunded to the signer.
- **nearcore:** `runtime/runtime/src/function_call.rs:100-138` (the abort becomes the action
  error); `runtime/runtime/src/lib.rs:535-541`, `:1304-1310` (failure refunds against
  `gas_burnt`, success against `gas_used`).
- **Model:** `FailOOG`, with the `oog` ghost recording `<<tx, method>>`.
- **Validated:** sim (prior).

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
- **Validated:** nearcore.

### A2. Account types (by id pattern)

- **Rule:** The account type comes from the id string alone: `0x` + 40 hex is eth-implicit;
  64 hex is NEAR-implicit; `0s` + 40 hex is deterministic (NEP-616); `0u` + 52 Crockford base32
  is universal (87+); anything else is named. Fees use the pattern **even if the account
  already exists**, so a Transfer to an existing eth-implicit account still pays the
  create_account fee.
- **nearcore:** near-account-id 3.0.0 (the version in nearcore's `Cargo.lock:3890-3892`),
  `src/account_id_ref.rs:246-260` and `src/validation.rs:96-132`. Feature flags:
  `runtime/runtime/src/actions.rs:899-927` (`get_account_type`: eth-implicit and deterministic
  need `eth_implicit_accounts`, TRUE at 84-88; universal needs `universal_accounts`, 87+).
  Fees by pattern: `core/parameters/src/cost.rs:775-810`, `:812-848`, with callers passing
  `receiver_id.get_account_type()` and no existence check
  (`runtime/near-vm-runner/src/logic/host.rs:3641-3653`; `runtime/runtime/src/config.rs:120-128`,
  `:360-368`).
- **Model:** `NearFees.RcvKinds` = `{"named", "near_implicit", "eth_implicit",
  "deterministic", "universal"}`. `AcctKinds`, `AcctKind`/`KindOf` and `IsImplicit` assign kinds
  to model accounts; the model creates only NEAR-implicit and eth-implicit accounts.
- **Validated:** nearcore. The fee-by-pattern rule: sim (planned).

### A3. Implicit-account creation on Transfer

- **Rule:** A Transfer to an absent NEAR-implicit, eth-implicit or deterministic id creates the
  account, but **only if the Transfer is the receipt's only action** and the receipt is not a
  refund. Universal (87+) ids may be created even when batched. What is created:
  - NEAR-implicit: an account holding the deposit, with one full-access key derived from the id.
  - eth-implicit: an account holding the deposit whose code is nearcore's global eth-wallet
    contract (`AccountContract::Global`). A function call to it therefore runs that contract;
    it does not fail with "no code".
  - deterministic / universal: an account with no keys; its state arrives with a state-init
    action.

  From 85 (`AccountCostIncrease`), creating an account also takes `account_creation_charge`
  (0.007 NEAR) out of the gas refund.
- **nearcore:** `runtime/runtime/src/actions.rs:929-946` (`implicit_creation_allowed`;
  `is_the_only_action` from `runtime/runtime/src/lib.rs:597`), `:221-287`
  (`action_implicit_account_creation_transfer`; eth-implicit at `:253-266`),
  `runtime/runtime/src/lib.rs:3016-3062` (`action_transfer_or_implicit_account_creation`),
  `:1361-1398` (account creation charge), `core/parameters/res/runtime_configs/85.yaml`
  (`account_creation_charge`).
- **Model:** `ExecTransfer` (creates a missing implicit receiver; D7). The fee part:
  `NearFees.TransferFeeTotal(sir, kind)`. The "only action" condition: TBD(WS1).
- **Validated:** nearcore; sim (planned).

### A4. Transfer to a missing named account fails and refunds

- **Rule:** A Transfer to an absent named account fails with `AccountDoesNotExist`, so the
  receipt fails and its deposit goes back to `refund_to` or the predecessor (R5). The same
  happens to a batched Transfer to an absent implicit id (A3).
- **nearcore:** `runtime/runtime/src/actions.rs:842-849`; refund as in R5.
- **Model:** `ExecTransferFail(r)`.
- **Validated:** nearcore; sim (prior) for the refund.

### A5. Function call to an account without code fails

- **Rule:** A FunctionCall to an existing account with no contract fails with
  `CompilationError(CodeDoesNotExist)`. Like any failure, the receipt reverts and refunds (R4,
  R5). A FunctionCall to an absent account fails earlier with `AccountDoesNotExist` (A1).
- **nearcore:** `runtime/runtime/src/function_call.rs:309-312` (`VMOutcome::nop_outcome` with
  `CodeDoesNotExist`); `runtime/runtime/src/actions.rs:862-891`.
- **Model:** `NearKeys.FailNoCode`.
- **Validated:** nearcore; sim (planned).

---

## Signer and access keys

### K1. Signer and signer public key propagate

- **Rule:** Every receipt a transaction spawns, at any depth and including callbacks and
  refunds, carries the transaction's `signer_id` and `signer_public_key`. A contract sees them as
  `signer_account_id` / `signer_account_pk`. They are distinct from `predecessor_account_id`, the
  immediate caller.
- **nearcore:** `runtime/runtime/src/function_call.rs:172-173` (copied into every child receipt),
  `:258-260` (exposed in `VMContext`), `:262` (predecessor).
- **Model:** `SignerOf(tx)` / `Signer(r)` / `SignerKey(r)`, set by `Submit` / `SubmitAs(r, a, k)`
  (D1). `Submit(r)` with no key info uses signer = `r.fr` and `DefaultKey`.
- **Validated:** nearcore; sim (planned).

### K2. Full-access versus function-call keys

- **Rule:** A transaction is signed with an access key of the signer. A full-access key allows
  any actions. A function-call key allows only a transaction with **exactly one action**, a
  FunctionCall, with **zero deposit**, to the key's `receiver_id`, and, if the key's method list
  is non-empty, to one of those methods. Anything else is an invalid transaction: no receipt is
  created. A function-call key may carry an allowance: the transaction's full cost (gas plus
  deposit) is taken from it, the transaction is invalid if the allowance is short, and gas
  refunds to that key add back to it.
- **nearcore:** `runtime/runtime/src/verifier.rs:209-250` (`verify_function_call_permission`),
  `:282-301` (`check_and_compute_new_allowance`), `:365-394` (call order in
  `verify_and_charge_tx_ephemeral`), `:177-194` (`AccessKeyNotFound`);
  `runtime/runtime/src/actions.rs:133-157` (`try_refund_allowance`).
- **Model:** `NearKeys`: `KeyAllows`, `SubmitSigned`, `Perm`, `FullPerm`.
- **Validated:** nearcore. Allowance: TBD(WS1), probably not modelled.

### K3. AddKey and DeleteKey

- **Rule:** AddKey, DeleteKey, Stake, Deploy and DeleteAccount need the actor to be the account
  itself. In practice that means a transaction signed by the account, or the account's own
  promise to itself; after a `CreateAccount` in the same receipt, the new account is the actor.
  AddKey of a key that already exists fails (`AddKeyAlreadyExists`). DeleteKey of a key that does
  not exist fails (`DeleteKeyDoesNotExist`). Either failure fails **the whole receipt** (M1).
- **nearcore:** `runtime/runtime/src/actions.rs:755-800` (`check_actor_permissions`), `:202`
  (CreateAccount sets the actor); `runtime/runtime/src/access_keys.rs:157-164` (AddKey exists),
  `:79-85` (DeleteKey absent; the error is at `:84`).
- **Model:** `NearKeys`: `AddKeyRcpt`, `DelKeyRcpt`, `ExecKeyAct`, `KeyPresent`.
- **Validated:** nearcore; sim (planned).

### M1. Multi-action receipts are atomic

- **Rule:** The actions of one receipt run in order, and the first failure stops the loop
  (later actions do not run). Then the receipt's whole state change rolls back, including the
  earlier actions' effects, and none of their receipts are sent. If any action fails, nothing
  from that receipt survives except gas burnt, logs and the deposit refund.
- **nearcore:** `runtime/runtime/src/lib.rs:949-1004` (loop; `break` at `:1001-1003`), `:1084-1087`
  (rollback), `:535-541`.
- **Model:** `NearKeys`: `ExecWithKeys`, `KeyActsOK`, `WithKeyActs`. Token batches: `"batch"`
  in the token modules is one atomic receipt (a deposit mismatch fails the receipt, D8).
- **Validated:** nearcore; sim (prior) for token batches.

---

## Scheduling

### S1. Local receipts first: the exact rule

- **Rule:** A chunk first converts its transactions, each into exactly one receipt. If that
  receipt's **receiver equals the transaction's signer**, it is a *local receipt* and executes
  in the **same** chunk, before any delayed or incoming receipt. Otherwise it is sent out and
  runs in a later chunk. Local receipts run in transaction order; one that finds the chunk's
  compute or storage-proof limit already reached goes to the delayed queue instead. The rule
  covers only a transaction's **first** receipt. Receipts created while executing a receipt
  (self-calls, callbacks, refunds) are never local: they go out through
  `forward_or_buffer_receipt`, except *instant* receipts (N-instant).

  Model reading: in a one-shard untimed model, a self-signed transaction's first receipt
  executes before every receipt that was already pending when the transaction was included.
- **nearcore:** `runtime/runtime/src/lib.rs:2317-2324` (`if receipt.receiver_id() == signer_id
  { local_receipts.push_back(receipt) } else { forward_or_buffer_receipt }`), `:2787-2826`
  (`process_receipts`: local `:2800`, then delayed `:2808`, then incoming `:2816`, then yield
  timeouts `:2825`), `:2513-2520` (limit reached: push to delayed), `:1222-1230` (receipts
  created by a receipt: instant or outgoing).
- **Model:** `LocalOK(r)` / `Schedulable` (D2), an operator the contract conjoins (or it draws
  receipts from `Schedulable`). Default ON in new examples. A model that does not use it
  explores every causally enabled order, which is an over-approximation; models written before
  the switch existed behave that way. `LocalOK` orders local receipts first only per receiver
  account, which is weaker than nearcore's chunk-wide rule, so it also over-approximates.
- **Validated:** nearcore; sim (planned: the self-call priority probe).

### S2. Ordering otherwise

- **Rule:** Beyond R2 (a callback waits for its inputs) and S1, the model lets any enabled
  receipt run next. nearcore is more constrained (see N-order).
- **nearcore:** `runtime/runtime/src/congestion_control.rs:292` (`forward_or_buffer_receipt`),
  `chain/chain/src/sharding.rs:13` (`shuffle_receipt_proofs`).
- **Model:** `\E r \in Runnable : ...` (or `Schedulable`) in `Next`.
- **Validated:** nearcore (as a description of what is over-approximated).

---

## Staking and balance

### B1. Stake action failures

- **Rule:** `Stake(amount, key)` on an account:
  - fails with `TriesToStake` if `amount − locked` exceeds the liquid balance;
  - fails with `TriesToUnstake` if nothing is locked and `amount = 0`;
  - fails with `InsufficientStake` if `0 < amount < minimum stake`.

  Otherwise it records a validator proposal. An increase moves the difference from liquid to
  locked immediately. A decrease (unstake) changes nothing now; the release comes from epoch
  processing later. A failed Stake fails its receipt, which drops the proposal.
- **nearcore:** `runtime/runtime/src/actions.rs:58-108` (`action_stake`);
  `runtime/runtime/src/lib.rs:1717` (`update_validator_accounts`, epoch-side release and
  rewards).
- **Model:** `ExecStake`, `StakeFails`, `EpochTick`; constants `StakingAcct`, `MinStake`,
  `MaxEpoch` and `MaxReward`.
- **Validated:** nearcore; sim (prior) for the Stake exec fee only. The sim simplifies epochs
  (one validator, no minimum stake, flat rewards).

### B2. Balance must cover storage (`LackBalanceForState`)

- **Rule:** After a receipt's actions succeed, the receiver's balance must cover its storage
  (`storage_usage × storage_amount_per_byte` = 1e19 yocto per byte at 88). If not, the receipt
  fails with `LackBalanceForState` and everything reverts. Transactions are checked the same way
  at conversion.
- **nearcore:** `runtime/runtime/src/lib.rs:1008-1030`; `runtime/runtime/src/verifier.rs:48`
  (`check_storage_stake`), `:375-387`;
  `core/parameters/src/snapshots/near_parameters__config_store__tests__88.json.snap:7`.
- **Model:** the `StorageFloor` constant (a per-account liquid floor). Storage usage is not
  tracked byte by byte (see N-storage).
- **Validated:** nearcore.

---

## Tokens

Sources: `neps/nep-0141.md` (fungible token core; `ft_resolve_transfer` requirements at
`:292-330`), `neps/nep-0145.md` (storage management; interface at `:378-410`),
`neps/nep-0245.md` (multi token; `mt_resolve_transfer` at `:304-330`), and NEP-297 (events, not
modelled). The reference implementation is near-contract-standards, in
`fungible_token/core_impl.rs` and `fungible_token/storage_impl.rs`. near-contract-standards has
no NEP-245 implementation, and no wNEAR source is available locally.

### T1. NEP-141 `ft_transfer` / `ft_transfer_call`

- **Rule:** Both require exactly 1 yoctoNEAR attached. They panic if sender = receiver, if
  `amount = 0`, if either side is unregistered, or if the balance is short. `ft_transfer_call`
  moves the tokens, calls `receiver.ft_on_transfer(sender, amount, msg)`, then
  `.then(self.ft_resolve_transfer(sender, receiver, amount))`, and returns the resolver's
  promise (C5).
- **Sources:** NEP-141 `:203`, `:234-240`; near-contract-standards 5.29.1
  `fungible_token/core_impl.rs:94-112` (`internal_transfer`), `:121-155`.
- **Model:** `Nep141` / `Tokens` modules (WS1): `TokHandle`, `TokStep`; arguments `FtArgs`.
- **Validated:** NEP text and near-contract-standards source were read; sim (prior) for return
  shapes.

### T2. `ft_resolve_transfer`

- **Rule:** It is private (self only). `unused` = `amount` if the result is Failed or does not
  parse as a U128, else `min(v, amount)`. `refund = min(unused, receiver balance)` moves back to
  the sender. If the sender has unregistered, the refund is burnt (total supply drops). It
  returns the amount used.
- **Sources:** NEP-141 `:306-325`; near-contract-standards 5.29.1 `core_impl.rs:169-235`.
  5.24.0 and later read the result with `promise_result_checked(0, MAX_RESULT_LENGTH)`, so an
  oversized result counts as all unused; 5.23.0 uses `promise_result(0)`.
- **Model:** `TokenCommon.ResolveRefund`, `NumOr` (WS1).
- **Validated:** near-contract-standards source read (5.23.0-5.29.1); sim (planned).

### T3. Gas behaviour of `ft_transfer_call` (version-dependent)

- **Rule:** It differs by near-contract-standards version.
  - **5.23.0-5.29.1** (all locally available): `ft_on_transfer` gets static 0 and weight 1, so
    it takes all the leftover gas. `ft_resolve_transfer` gets static 5 Tgas and weight 0
    (`core_impl.rs:13`, `:141-151`).
  - **Older versions** (recalled, not read): `ft_on_transfer` gets static = prepaid − a fixed
    reserve, with weight 0. The call panics when prepaid ≤ reserve. The resolver gets a fixed
    static gas.
- **Model:** per-token configuration (D8): the reserve (`TokCallReserve`), the receiver's
  static gas and weight, and the resolver's static gas and weight. **The default reproduces the
  older reserve-based behaviour.** For a 5.x token, configure weight-based forwarding. The
  measured values per version come from `conformance/` (`docs/CONFORMANCE.md`).
- **Validated:** 5.x read; the older behaviour is recalled. WS2 measures the pinned version.

### T4. NEP-145 `storage_deposit`

- **Rule:** `storage_deposit(account_id?)` (default: the predecessor):
  - an already registered account gets the whole deposit back, refunded to the
    **predecessor**;
  - a deposit below `min` panics;
  - otherwise the account is registered and `deposit − min` is refunded to the predecessor.

  The FT implementation ignores `registration_only` and has `min = max`. It returns a
  `StorageBalance` object.
- **Sources:** NEP-145 `:378-410`; near-contract-standards 5.29.1
  `fungible_token/storage_impl.rs:51-78`, `:81-111`.
- **Model:** `Nep145` (WS1). Deviation `sdRefundToAccount` refunds to `account_id` instead.
- **Validated:** source read.

### T5. NEP-245 multi token

- **Rule:** The same transfer, resolve and refund rules as T1/T2, per token id. Every transfer
  needs 1 yocto.
- **Sources:** NEP-245 `:88`, `:124`, `:164-179`, `:304-330`.
- **Model:** `Nep245` (WS1). Single-id transfers only; no batch, no approvals, no storage
  management.
- **Validated:** NEP text read; no reference implementation checked.

### T6. wNEAR

- **Rule:** `near_deposit` registers the predecessor out of the deposit if needed and mints the
  rest; it returns nothing (`EMPTY`). `near_withdraw` needs 1 yocto, burns `amount`, and
  returns a Transfer of the amount to the caller (`RProm`).
- **Sources:** none local. Recalled.
- **Model:** `WNear` (WS1). The shipped gas keys come from the repo's wNEAR-like probe
  (`conformance/`); recalibrate for a real deployment.
- **Validated:** recalled; the probe checks the probe, not a production deployment.

### T7. Token deviations

- **Rule:** These are non-standard behaviours, chosen per token account:
  - `retBytes`: `ft_transfer` returns non-empty bytes;
  - `resolveIgnoresResult`;
  - `resolveNoCap`;
  - `sdRefundToAccount`;
  - `autoRegister`.

  An unregistered receiver is a scenario (the initial registration set), not a deviation.
- **Model:** `TokenCommon.Deviations`, `TokDev`, `MtDev` (WS1).
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
- **Validated:** sim (prior) for gas mode's verdicts and split; fault mode is an abstraction by
  design.

---

## Not modelled

Each item says what it is, why it matters, and what leaving it out could hide.

- **Over-approximation:** the model allows more behaviour than nearcore. That is sound for
  safety (no real bug is missed), but it can produce counterexamples no network can reach.
  Replay every counterexample in the sim.
- **Under-approximation:** the model allows less behaviour than nearcore. That is **unsound**:
  a real bug can be missed.
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
  latency; any causally enabled order is allowed. This covers every real schedule, but some
  model schedules need timing a network does not produce.
- **N-congestion. Congestion control, bandwidth scheduler, delayed receipts.** These only delay
  receipts, which the model's free ordering already covers. A finding about latency bounds
  needs the real scheduler. Congestion can also reject new transactions, which the model treats
  as "not submitted".
- **N-instant. Instant receipts.** A receipt holding a single `DeleteAccount` with no inputs,
  and a `PromiseYield` receipt, run immediately after their creator in the same chunk
  (`core/primitives/src/receipt.rs:467-491`, `runtime/runtime/src/lib.rs:1222-1224`,
  `:2748-2775`). The model lets other receipts interleave.
- **N-local-off.** With the local-receipt switch (S1) off, a self-signed first receipt may run
  after receipts that nearcore would run later.
- **N-tx-validity. Nonces and transaction validity.** Nonce rules (`verify_nonce`,
  `runtime/runtime/src/verifier.rs:254-280`), expiry (`runtime/runtime/src/lib.rs:2031-2034`),
  balance-for-cost and signature checks are absent. `Submit` always succeeds, so real
  executions are a subset (nonce reuse, replay protection and gas-key nonces are not modelled).
- **N-time. Block and epoch timing.** There are no heights or timestamps; epochs are an
  abstract tick. Contracts reading `block_timestamp` or `epoch_height` need their own
  abstraction. A time-based guard modelled as free nondeterminism is an over-approximation.

### Under-approximations (unsound: they can hide bugs)

- **N-batch-oog. Per-action out-of-gas in batches.** nearcore checks each function-call action
  against its own gas. The model checks the batch's total burn against its total gas. A batch
  where one action is starved while another has slack fails in nearcore but not in the model.
- **N-burn. Trie and storage gas variation.** Burns are constants per (method, path), affine in
  one size variable at most, measured in one sim world. Real burns move with trie shape, key
  count, argument length and network (trie-node pricing). A real out-of-gas at a prepaid amount
  the model calls safe is possible near any calibrated edge. Treat windows as approximate. They
  are tied to the calibration's provenance (`docs/VERSIONING.md`).
- **N-burn-fail. Burn of a failing receipt.** Only the verdict is modelled, not how much a
  failing receipt burnt. Gas-griefing amounts are not computed.
- **N-storage. Storage staking details.** `storage_usage` is not tracked per byte, so the
  failure where a write exceeds the balance's storage cover (`LackBalanceForState`, B2) appears
  only through the floor you configure. A contract that runs out of storage stake mid-flow may
  fail in nearcore and not in the model.
- **N-gas-money. Gas price and gas money.** Gas is a quantity, not NEAR. Purchase, the price
  floor (`min_gas_purchase_price`), price changes between blocks, and burning are absent
  (`runtime/runtime/src/config.rs:481` `calculate_tx_cost`; `runtime/runtime/src/lib.rs:1032-1044`).
  Properties about NEAR balances that include gas costs cannot be stated.
- **N-gas-refund. Refunds of unused gas as NEAR.** Gas refunds go to the signer
  (`runtime/runtime/src/lib.rs:1407-1415`), minus the NEP-536 penalty
  (`core/parameters/src/cost.rs:736-746`) and, from 85, the account-creation charge (A3). The
  model refunds no NEAR for gas, so signer-balance properties are not covered.
- **N-reward. Gas rewards.** Up to 86, a contract earned 30% of the gas its function calls
  burnt; 87 sets that to 0 (`core/parameters/res/runtime_configs/87.yaml:1-7`,
  `runtime/runtime/src/lib.rs:1108-1137`). At 84-86 a contract's balance grows in a way the model
  does not track.
- **N-validator. Validator rewards beyond the abstract tick.** Seat price, kickouts, slashing,
  reward shares and the exact release epoch are absent (`runtime/runtime/src/lib.rs:1717`).
  A staking contract's share-price arithmetic over real rewards is not checked.
- **N-refund-burn. Refunds and beneficiaries that no longer exist.** A deposit refund or a
  `DeleteAccount` beneficiary payment to an absent account is burnt
  (`runtime/runtime/src/lib.rs:1046-1053`, `runtime/runtime/src/actions.rs:382-386`). If the
  model's refunds always land, it misses that loss.
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
- **N-allowance. Access-key allowance.** Not tracked (K2). A transaction refused for low
  allowance is modelled as accepted (over), and allowance top-up by gas refunds is absent.
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
  The fee kinds exist in `NearFees`; the state-init actions do not.
- **N-gas-keys. Gas keys** (85+: `TransferToGasKey`, `WithdrawFromGasKey`, gas-key nonces;
  `core/primitives-core/src/version.rs:615`). Absent.
- **N-deploy. DeployContract and code upgrades mid-flow.** Code is the TLA+ handler; it does
  not change during a run.
- **N-compute. Compute costs versus gas.** Some actions charge more compute than gas (for
  example deploy, `core/parameters/res/runtime_configs/84.yaml`). This affects chunk packing,
  that is timing only, which is already covered by the free ordering above.
- **N-wasm. Contract semantics.** The model's handlers are hand-written abstractions of the
  contract. Wasm-level behaviour (panics on overflow, serialization, unexpected host errors) is
  covered only by replaying counterexamples in the sim.
- **N-events. Logs and events (NEP-297).** Not modelled. A failed receipt keeps its logs
  (`runtime/runtime/src/lib.rs:535-541`), so a log is not proof of a committed write.
- **N-views. View calls.** Views are pure reads outside receipts (`ProhibitedInView` for every
  promise host function). `ft_balance_of`/`ft_total_supply` are modelled as reads of the
  ledger (D8).
- **N-resharding. Resharding and missing chunks.** The model assumes a fixed layout and a
  finalized history.
