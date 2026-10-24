# Changelog

All notable changes to the `modules/` library are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
`docs/VERSIONING.md`.

The entries below are relative to the pre-release module set that existing
models were written against (NearAsync, TokenCommon, Nep145, Nep141, WNear,
Tokens, Nep245, plus a separate NearKeys).

## [Unreleased]

```
nearcore: 2.14.0-rc.5 (b7b4737)   behaviour: protocol 88   fees: FeeProtocol 88, covered 84-88
near-contract-sim: 29e909033bb59eab792dee136e9d02870488bc3e
near-contract-standards (token gas defaults): 5.x (measured on 5.29.1)
```

### Breaking

Each entry ends with its migration.

- **New platform variable `blk` in `NearAsync`** (the block height, advanced only by the new
  `BlockTick`; it stays 0 unless a model sets `MaxBlk > 0`). It is in `platformVars`, and
  `PlatformInit`, `PlatformInitStaked` and `PlatformInitExtra` initialise it, so models that
  use those and write `UNCHANGED platformVars` need no change (every example is such a
  model). A step that lists platform variables one by one in `UNCHANGED` must add `blk`
  (in the library: `NearKeys.ExecKeyAct`), a hand-written `Init` must set it, and so must a
  hand-written full-state tuple: if the `vars` of `[][Next]_vars` lists platform variables
  by name, `blk` is missing from it and unconstrained by its stuttering steps (TLC only
  warns). State counts of models without yields or a clock are unchanged. Migration: write
  `UNCHANGED platformVars` or add `blk` to the list; conjoin `PlatformInitClock`
  (`blk = 0`) to a hand-written `Init` that does not use `PlatformInitExtra`; in a
  hand-written `vars`, replace the platform variables with `platformVars`
  (`vars == <<platformVars, mine>>`) or add `blk`.
- **`RemD` and `NoOrphans` cover several inputs per receipt** (`InIds`): a joint callback
  consumes all its inputs, a yield every resume addressed to it, and a pending yield is never
  an orphan. Results for receipts without the new fields are unchanged. Migration: none,
  unless a model hand-wired several data receipts to one callback; use `AndThen` instead.

- **New platform variables `txsig` and `created` in `NearAsync`** (the transaction
  signer per tx id, and accounts created at run time by an implicit-account
  Transfer). A model must initialise them, and any step that lists platform
  variables one by one in `UNCHANGED` must add them. Migration: add
  `/\ PlatformInitExtra` to `Init` (or replace the platform part of `Init` with
  `PlatformInit(near0, txIds)` / `PlatformInitStaked(near0, locked0, txIds)`), and
  write `UNCHANGED platformVars` rather than the individual names. The helpers
  compose: `PlatformInitExtra` is `PlatformInitSigner /\ PlatformInitAccounts`; a
  model that keeps its own (e.g. pre-sized) `txsig` initialiser conjoins
  `PlatformInitAccounts` alone (`created = {}`, `burnt = 0`). The `pay` and
  `mt-smoke` examples were migrated this way, to `/\ PlatformInit([a \in Accts |-> 0], TxIds)`.
  State cost: settled transactions keep their `txsig` entry, which grew the state
  space by up to about 17% in models that never read the signer;
  `TrackSigner <- FALSE` leaves `txsig` unchanged in `SubmitAs`. Do not read the
  signer then: with `txsig` initialised empty (`PlatformInit`) that is a TLC
  error, but with a pre-sized `txsig` it silently returns the initial value.
- **`txsig` moved from `NearKeys` to `NearAsync`; `keyVars` is now `<<keys, sigpaid>>`.**
  `SignerOf(t)` is unchanged. Migration: initialise `txsig` once, either with
  `PlatformInitSigner` (`txsig = <<>>`) or with your existing function, plus
  `PlatformInitAccounts` for the other new variables. `Submit`
  overrides the entry of the submitted tx with `@@`, so no pre-sized domain is needed.
  Initialise `keys` and `sigpaid` with `KeysInit(keys0)` or as before.
- **`NoRes.v` is now `NOPR` (-4), not 0.** A ready receipt has no promise results,
  and `IsNum(NoRes)` is now FALSE. Migration: code that read `r.res` on a
  receipt that is not a callback must test `NoResults(r.res)` (or `r.res.v = NOPR`)
  instead of expecting `Successful(0)`.
- **Result records have size fields `sz` (KB) and `len` (bytes, 0 = not
  stated)**: `r.res`, data records, `RVal(v)` and `RProm`. `RVal(v)` keeps both
  0. Migration: code that compares whole result records
  (`r.res = [ok |-> .., v |-> ..]`) must compare `.ok` and `.v`. Hand-built `ret`
  records without `sz` or `len` still work (`RetSz` / `RetLen` count them as 0).
- **The NEP-141 resolver applies the 42-byte read bound of near-contract-standards
  5.24.0 and later** (5.29.1 `fungible_token/core_impl.rs:175-183`): a receiver
  result longer than 42 bytes counts as all unused, so the transfer is refunded
  up to the receiver's balance even when the bytes are a valid number (a `"0"`
  padded with 40 spaces). A result's length is `r.res.len` when stated
  (`RValLen`), else what `r.res.sz` implies (`sz >= 2` is over 1000 bytes). The
  resolver used to honour any number whatever its size. `Nep245` keeps an
  unbounded read. Migration: for a token on near-contract-standards 5.23.0 or
  older (3.x/4.x), set `TokResolveMaxLen <- Unbounded` with
  `Unbounded == [t \in TokenAccts |-> -1]`; a model whose receiver returns a
  number as `RValSz(v, n)` with `n >= 2` must do the same, or state the real
  length with `RValLen`.
- **Receipt records have a field `loc`** (TRUE for a local receipt, set by
  `Submit`). Migration: code that compares a whole receipt in `rq` with a value
  built by `Rcpt(...)` for a submitted receipt must compare by `id`.
- **`TA0` has a payload slot `cx |-> <<>>`.** Migration: argument records built
  by hand instead of from `TA0` must add `cx |-> <<>>`.
- **Gas mode: action-only children default their creator-side fee `gf` to the
  fee table** (`XFER`: `NearFees.TransferFeeTotal` by receiver type; `STAKE`:
  `OneActionReceiptFee("stake", ...)`) when `GasCall` has no entry for the
  receiver/method. It was 0. Fault mode is unchanged. Migration: to keep the old
  zero fee, add `"XFER" :> NoGas` (and `"STAKE" :> NoGas`) to `GasCall`.
  Calibrations made under the new convention subtract both send and exec fees of
  these children from the creator's burn.
- **`Tokens` `"batch"`: a total deposit that differs from `nd + sd + TokYocto` now
  fails the receipt** ("Requires attached deposit of exactly 1 yoctoNEAR") instead
  of an `Assert`. Migration: a run that expected `assert` for that case now sees
  an ordinary failed receipt; change its expectation.
- **Storage check uses liquid + locked; `StakeFails` no longer checks the floor.**
  After a function call, `near[a] + locked` (locked counts for `StakingAcct`)
  must cover `StorageFloor[a]` (`runtime/runtime/src/verifier.rs:48-79`; an
  account under the zero-balance threshold is exempt, `:75-77`, so give it floor
  0). A Stake fails only for TriesToStake (liquid below the increment),
  TriesToUnstake and InsufficientStake (`actions.rs:66-100`). Migration: none for
  most models; a model that relied on Stake failing at the floor adds that
  guard to its own step.
- **Function calls to a missing account or one without code fail in
  `NearAsync`** (`actions.rs:874-887`, `function_call.rs:309-312`): `Exec` fails
  them before the handler's outcome counts. `Contracts` (accounts with code) is
  now an overridable `NearAsync` definition, default `Accounts`, so `NearKeys` no
  longer declares it as a CONSTANT; a cfg `Contracts = {...}` or
  `Contracts <- Def` still sets it. Migration: `CallsNeedCode <- FALSE` restores
  the old behaviour; otherwise add called accounts to `Exists`. Check this: with
  `CallsNeedCode` TRUE and an `Exists` that omits the contracts a model calls,
  every call to them fails, and safety invariants can then pass vacuously.
- **`NearKeys.FailNoCode(r)` is `IsCall(r) /\ ~HasCode(r.to) /\ FailP(r, FALSE)`**:
  it now also fails calls to missing accounts and to accounts created by a
  Transfer (except eth-implicit ones); it tested `r.to \notin Contracts`.
  `Exec` already applies the rule. Migration: list every called account in
  `Exists` (and in `Contracts`).
- **A Stake receipt's result is empty bytes (`EMPTY`), not 0** (`lib.rs:1172-1176`).
  Migration: callbacks on a Stake test `IsEmpty(r.res)` instead of `IsNum`.
- **Only the account itself may stake** (`actions.rs:755-801`, ActorNoPermission):
  a Stake receipt whose predecessor is not `StakingAcct` fails. Migration: emit
  the Stake from `StakingAcct`'s own receipt.
- **A refund to a missing account is burnt** (`lib.rs:1046-1054`): it used to
  stay pending. New ghost variable `burnt` (in `platformVars`), and
  `NearConserved(total0)` now reads `... = total0 + minted - burnt`.
  Migration: initialise `burnt = 0` (`PlatformInit*` and `PlatformInitExtra` do);
  steps that list platform variables one by one add `burnt` to `UNCHANGED`;
  `BurnLostRefunds <- FALSE` restores the pending refund. The burn is a step of
  `ExecTransferFail` (part of `ExecBuiltin`): a model that runs `REFND`
  receipts with its own step, or only with `ExecTransfer`, keeps such a refund
  pending; route them through `ExecBuiltin`.
- **Gas mode: a function-call child left with 0 gas fails its creator**
  (`action_validation.rs:350-351`, applied at `lib.rs:968-978`). Migration: give
  such a child static gas or an unused-gas weight; there is no switch.
- **Gas mode: a panic the receipt could not reach can be labelled out of gas**
  (`gas_counter.rs:136-141`, `:155-174`, `:205-213`): when the outcome names its
  panic-path burn key with `OPanicKey(O, k)` (per action: `OPanicAt(O, i, k)`) and
  that burn plus the static gas and fees of the children created before the panic
  exceeds the attached gas (per action: an action before `i` exceeds its own gas,
  or action `i` cannot reach the panic), `oog` and `rlog` record "oog" instead of
  "fail". Without a panic key a panic is "fail", as before; the success-path key
  (`gk`) is never used for this. The state change is the same either way.
  Migration: none (labels only); to get the label, put the panic path's key in
  `GasBurn` and mark the outcome with `OPanicKey`. Like a success-path key, the
  panic key's burn excludes the fees of the children created before the panic
  (send fees are burnt in nearcore, but the model adds them through `KidsCost`).
- **Verdict order: a receipt that is both out of gas and over its balance or
  storage is "oog"** (gas is checked during the call, the balance and storage
  after it: `gas_counter.rs:155-174`, `lib.rs:1008-1023`). It was "fail".
  Migration: none (labels only).
- **Gas mode: a function-call child without static gas is an `Assert`**
  (`GasListsOK`): an empty static list gave it no gas and skipped the zero-gas
  check. Migration: add a `GasCall` entry for the child's `"acct.method"` or
  `"method"`, or build it with `WithCall(c, <<s>>, <<w>>)`.
- **Gas mode: per-action `pa` is checked** (`PAOK`): `Len(O.pa)` must equal
  `Len(r.g)` and the `kids` sets must be disjoint, else an `Assert`. Migration:
  give the receipt one gas entry per function-call action, and attribute each
  child to one action.
- **Gas mode: a receipt with several gas entries and no `pa` is an `Assert`**
  (`PoolCheck`) unless `PooledGasOK <- TRUE`: nearcore gives each function-call
  action its own gas (`function_call.rs:61`, `:343-345`), so pooling them is
  approximate. A failing outcome without a panic key is exempt. Migration:
  add `pa` to the outcome, or `PooledGasOK <- TRUE` to keep pooling.
- **Token batches are accounted per action by default** (`TokBatchPerAction`
  is now TRUE; `function_call.rs:61`, `:343-345`). Each call of a `"batch"`
  receipt is checked against its own entry of `r.g` with the burn key
  `"<acct>.batch/<shape>#<method>"` (`BatchCallKey`), because a call burns
  differently by its position in the batch; a single-call batch is one action
  with the whole-batch key `"<acct>.batch/<shape>"`. Migration:
  `TokBatchPerAction <- FALSE` (and `PooledGasOK <- TRUE` if the batch receipt
  has several gas entries) restores one pool with the whole-batch keys
  `"<acct>.batch/<shape>"` in `GasBurn`.
- **Reserve-shape resolver without a `GasCall` entry gets `TokResolveStatic`**
  (static 5 Tgas, weight 0) instead of an empty static list, which gave it no
  gas (and is now an `Assert`). Migration: a `GasCall["t.ft_resolve_transfer"]`
  entry still wins; add one with the old values.
- **`ExecStake` asserts that the receipt is for `StakingAcct`**. The model has
  one staking account; a Stake to another account used to update `locked`
  anyway. Migration: route Stake receipts only to `StakingAcct`.
- **Token gas defaults follow near-contract-standards 5.x**
  (`fungible_token/core_impl.rs:13`, `:142-151`): `ft_on_transfer` gets static 0
  and unused-gas weight 1, with no reserve check; `ft_resolve_transfer` gets
  static 5 Tgas (`TokResolveStatic`) and weight 0 unless `GasCall` has an entry
  for it. `TokOnTransferWeight` now defaults to -1 (the shape's default);
  explicit values keep their meaning. **This can change verdicts, not only gas
  windows**: under the 5.x shape `ft_on_transfer` takes the leftover gas, so an
  out-of-gas path that the reserve shape has can disappear. Tokens built on
  near-contract-standards 3.x/4.x (many older deployments) use the reserve shape;
  check your token's version and set `TokFtGasShape` to "reserve" for those.
  Migration: `TokFtGasShape <- Shapes` with
  `Shapes == [t \in TokenAccts |-> "reserve"]` restores the 3.x shape (static
  prepaid - `TokCallReserve`, weight 0, prepaid <= reserve panics, resolver gas
  from `GasCall`). `Nep245` keeps the reserve shape.
- **Function-call access keys: one action only, and an empty method list allows
  every method** (`verifier.rs:209-250`, `:213`, `:238`). `SubmitSigned` with a
  function-call key now also requires a single function call (no Transfer, Stake,
  key action or multi-call receipt). Migration: a key meant to allow nothing
  names a method set, e.g. `Perm(rcv, {"none"}, FALSE)`; `Perm(rcv, ms, all)` is
  unchanged otherwise.
- **`TA0` has a field `force |-> FALSE`** (storage_unregister). Migration:
  argument records built by hand instead of from `TA0` add `force |-> FALSE`.
- **New exported names may clash with names a model defines** (SANY reports a
  "multiply-defined symbol"). New in `NearAsync`: `NOPR`, `IsFailed`, `NoResults`,
  `RValSz`, `RetSz`, `OSz`, `DataOfSz`, `RValLen`, `RetLen`, `DataOfLen`,
  `ResMinBytes`, `ResTooLong`, `NumOrChecked`, `HasCallDef`, `XferFee`, `StakeFee`,
  `BuiltinFee`, `DefaultFee`, `IsBuiltin`, `ExecBuiltin`, `AcctKind`, `AcctKinds`,
  `KindOf`, `IsImplicit`, `AcctExists`, `DefaultKey`, `SignerOf`, `Signer`,
  `SignerKey`, `SubmitAs`, `LocalPriorityOK`, `Schedulable`, `PlatformInit`,
  `PlatformInitStaked`, `PlatformInitExtra`, `PlatformInitSigner`,
  `PlatformInitAccounts`, `TrackSigner`, `NearFeeTable`. New in token modules:
  `CxArgs`, `FtBalanceOfAct`, `FtTotalSupplyAct`, `TokOnTransferWeight`,
  `TokOnTransferStatic`, `OnTransferWeight`. New in `NearKeys`: `FullPerm`, `IsFull`,
  `KeysInit`, `KeyFee`, `AddKeyRcpt`, `DelKeyRcpt`, `KAct`, `AddKeyAct`,
  `DelKeyAct`, `KeysFold`, `KeyActsOK`, `KeysAfter`, `WithKeyActs`, `OkWithKeys`,
  `ExecWithKeys`, `IsMultiCall`, `KeyCanSign`. Also new in `NearAsync`:
  `burnt` (a variable), `Contracts`, `CallsNeedCode`, `BurnLostRefunds`,
  `UniversalOn`, `ADDK`, `DELK`, `IsKeyRcpt`, `IsCall` (the last four moved from
  `NearKeys`), `HasCode`, `CallTargetOK`, `ExecNoCode`, `LockedOf`, `RefundBurn`,
  `PerAction`, `ActGas`, `ActBurn`, `ActKids`, `ActNeed`, `ActOf`, `PanicOOG`,
  `GasListsOK`, `EntriesOf`, `Alloc`, `ZeroGasKid`, `NoOrphans`, `OPanicKey`,
  `OPanicAt`, `HasPanicKey`, `PanicBurn`, `PanicAct`, `PAOK`, `PoolCheck`,
  `PooledGasOK`; for v0.2: `blk` (a variable), `MaxBlk`, `YieldTicks`, `TickAnytime`,
  `TsOf`, `IsJoint`, `IsYield`, `InIds`, `DRes`, `Arrived`, `JointRes`, `JOINTRES`,
  `JointMark`, `FailedRes`, `TimedOut`, `NRes`, `ResAt`, `AndThen`, `YieldRcpt`,
  `CanResume`, `PendingYields`, `PendingYieldRcpts`, `PendingYieldsAt`, `OResume`, `Rsm`,
  `ResumeData`, `BlockTick`, `BlockTs`, `PlatformInitClock`, `YieldDeadlinesInBound`,
  `ClockHorizonOK`; and in the token modules: `OnTransferStatic`, `ReserveShort`,
  `TokFtGasShape`, `TokResolveStatic`, `FtShape`, `ReserveShape`, `TokKnob`,
  `FtMaxResultLen`, `ResolveUnusedLim`, `ResolveRefundLim`, `TokResolveMaxLen`,
  `ResolveMaxLen`,
  `ResolveGas`, `SuAct`, `SuArgs`, `TokBatchPerAction`, `BatchPA`, `MtOnStatic`,
  `MtReserveShort`, `BatchCallKey`, `PathKey`.
  Migration: rename the model's own definition. A model-local local-receipt rule
  is not always replaceable by `LocalPriorityOK`: a rule that lets **every**
  top-level receipt skip the wait admits more interleavings than the library
  rule, which lets only local receipts (signer = receiver) skip it. Switching
  removes those interleavings; the library rule is the more faithful one, but
  re-check verdicts that depended on them.

### Added

- **Joint promises** (`promise_and(..).then(..)`, SEMANTICS C6): `AndThen(ks, c, d0)` wires
  input receipts to fresh data ids and returns the callback with the optional field `ins`.
  The callback runs once, after all inputs, in any arrival order; `NRes(r)` and `ResAt(r, i)`
  read its results in `promise_and` order, each Successful or Failed on its own. On a joint
  callback `r.res` is `JointMark` (`ok = FALSE`, `v = JOINTRES`), so a single-input handler
  takes its Failed branch instead of silently reading one result. `ResAt` past the last
  result is an `Assert`.
- **Yield/resume** (NEP-519, SEMANTICS C7): `YieldRcpt(id, r, m, a, dep, cb)` (optional field
  `ydl`), `OResume(O, y, v, n)` (outcome field `rsm`), `CanResume(r, y)` (the host's return
  value: TRUE for every resume until the callback runs), `PendingYieldRcpts(r, ps)` /
  `PendingYieldsAt(r, ps)` (the yields of `r.to` still pending as `r`'s handler sees them:
  without `r`, plus `ps`, the yields the handler created so far), `PendingYields(a)` (the
  same as a state view, for invariants; not for handlers), `Rsm`, `ResumeData`. The callback
  runs with the first resume to arrive or times out with `Failed`; a resume in flight beats
  the timeout; extra resumes are dropped; only the yielding account can resume.
  `promise_yield_create_with_id`'s duplicate check and deposit are the handler's: test the
  custom id, kept in the yield's args, against `PendingYieldRcpts(r, ps)`, so that a callback
  may re-create its own id and a second create of one id in a call is a duplicate
  (platform-selftest `yield_id_*`; the mutant runs `selftest_yield_id_old_*` show that
  `PendingYields(r.to)` gets both wrong). Not checked: the payload limit (N-yield-payload).
- **Block clock** (SEMANTICS S3): the variable `blk`, `BlockTick`, `BlockTs`, and the
  overridable `MaxBlk` (default 0: no clock, every pending yield may time out at any moment),
  `YieldTicks`, `TickAnytime` (default TRUE; FALSE ticks only while a yield's deadline is
  ahead) and `TsOf`. `PlatformInitClock`. `BlockTick` is independent of `EpochTick`.
  `MaxBlk` is a bound, so a model that reads the clock passes only up to it (an
  under-approximation, SEMANTICS N-clock-horizon). Two checks to list as invariants:
  `YieldDeadlinesInBound` (no pending deadline past `MaxBlk`, so no timeout in the run is
  premature; it says nothing about coverage; `ClockBoundOK` in the pre-release tree) and
  `ClockHorizonOK(n, T)` (`MaxBlk >= n * max(T, YieldTicks)`, with `T` the largest number of
  blocks a clock comparison counts and `n` the most clock-relevant steps per behaviour: then
  the bound covers every behaviour).
- Examples `joint-promise` (`Pair`), `yield-resume` (`Oracle`, the double-resume trap) and
  `yield-clock` (`Deadline`: early timeouts at a too small bound, `cancel_trusts_timeout`,
  `cancel_after_answer`, and `horizon_*`: a double refund that passes at `MaxBlk = 2`, is
  flagged by `ClockHorizonOK` and found at `MaxBlk = 3`), with must-pass and must-fail runs.
- `examples/platform-selftest`: `selftest_async` and `selftest_async_gas`, 10 scenarios for
  joint callbacks (result order, a starved input, a callback with no gas) and yields (a second
  resume, two resumes in the yielding call, timeout then resume, a resume in flight at the
  deadline, another account's resume, a returned yield, a yield callback with no gas). The
  script item `BTick` is one block.

- `NearFees.tla`: action fees in Ggas per protocol version (84-88), with
  `FeeProtocol` as the single default. `NearAsync` uses it through the named
  instance `NearFeeTable`, so its helper names stay out of models.
- Transaction signer in `NearAsync`: `SubmitAs(r, a, k)`; `Submit(r)` is
  `SubmitAs(r, r.fr, DefaultKey)`. `SignerOf(tx)`, `Signer(r)` and
  `SignerKey(r)` are visible in every receipt of the tree, callbacks included.
- Local-receipt priority: `LocalPriorityOK(r)` and `Schedulable`. Opt-in: a
  model conjoins `LocalPriorityOK(r)` to its receipt step (or draws `r` from
  `Schedulable`). Models that do not conjoin it keep exploring every
  causally enabled order, as before. The rule is per account (weaker than
  nearcore's chunk-wide order).
- Account types: `AcctKind` (an overridable definition, default all `"named"`),
  `AcctKinds(eth, nearImplicit)`, `KindOf`, `IsImplicit`, `AcctExists`. A
  Transfer to a missing implicit account creates it (`created`); a Transfer to a
  missing named account fails and refunds, as before.
- Result size: `RValSz(v, n)`, `DataOfSz`, `OSz(O, n)`; `r.res.sz` can be used as
  the burn size. Byte length: `RValLen(v, b)` (sets `len = b` and `sz` rounded
  up), `DataOfLen`, `RetLen`.
- Bounded result reads (near-sdk `promise_result_checked`, `env.rs:129-137` and
  `:1833-1837` in near-sdk 5.28.1): `ResTooLong(res, max)`, `ResMinBytes(res)`,
  `NumOrChecked(res, max, dflt)`. Token side: `FtMaxResultLen` (42),
  `ResolveUnusedLim` / `ResolveRefundLim` (the resolver arithmetic with a bound;
  `ResolveUnused` / `ResolveRefund` are the unbounded forms), and the per-token
  overridable `TokResolveMaxLen` (default 42, -1 = unbounded). The arbitrary
  receiver has a response `"keepbig"`: a valid `"0"` of 43 bytes.
- `NOPR` and `NoResults(res)`, `IsFailed(res)`.
- `ExecBuiltin(r)` / `IsBuiltin(r)`: Transfer, refund and Stake receipts as one step.
- Init helpers `PlatformInit(near0, txIds)`, `PlatformInitStaked(near0, locked0, txIds)`,
  `PlatformInitExtra` (= `PlatformInitSigner /\ PlatformInitAccounts`);
  `KeysInit(keys0)` in `NearKeys`.
- `TrackSigner` (overridable, default TRUE): FALSE skips recording the signer.
- `NearKeys`: full-access keys (`FullPerm`); key-action receipt constructors
  `AddKeyRcpt` / `DelKeyRcpt` that charge the fee-table fee in gas mode; key
  actions inside a function-call receipt (`AddKeyAct`, `DelKeyAct`,
  `WithKeyActs`, `OkWithKeys`, `ExecWithKeys`), atomic with the call.
- `Tokens`: `ft_balance_of(account_id)` and `ft_total_supply()` views.
- `TokenCommon`: `CxArgs(v)` for a model's own receipts.
- Per-token gas of `ft_transfer_call`: `TokFtGasShape[t]` ("standard" or
  "reserve"), `TokOnTransferWeight[t]`, `TokOnTransferStatic[t]` (-1 = the
  shape's default) and `TokResolveStatic[t]`, all overridable definitions. A
  `GasCall["t.ft_resolve_transfer"]` entry wins for the resolver.
- Per-action gas accounting (`function_call.rs:61`, `:343-345`): an outcome may
  carry `pa`, one `[gk, sz, kids]` record per function-call action; with two or
  more, gas is checked and the leftover split per action. Without `pa` a receipt
  is one action, as before. `Tokens` batches use it by default (see Breaking).
- `OPanicKey(O, k)` / `OPanicAt(O, i, k)`: the burn key of a failing outcome's
  panic path (and the panicking action), for the out-of-gas label.
- Path-specific burn keys with fallback to the method key (`PathKey`):
  `"<t>.storage_deposit/registered"` / `"/new"`, `"<t>.near_deposit/registered"` /
  `"/new"`, `"<t>.ft_resolve_transfer/refund"` / `"/norefund"`. Without the path
  key the method key `"<t>.<method>"` is used, as before.
- `PooledGasOK` (overridable, default FALSE): allow a multi-call receipt without
  `pa` to pool its gas.
- `storage_unregister(force)` in `Nep145` / `Tokens` (near-contract-standards
  5.29.1 `fungible_token/storage_impl.rs:8-36`), which makes the NEP-141
  resolver's burn path reachable. `SuArgs(force)`; `ev.unreg` / `ev.unregBurnt`.
- Universal and deterministic account kinds (`AcctKind` values `"universal"`,
  `"deterministic"`): a Transfer may create them (`actions.rs:929-946`;
  universal from protocol 87, also inside a batch). An account created by a
  Transfer has no code unless it is eth-implicit (`actions.rs:221-290`; universal
  ones are also uninitialised, `:880-887`), so calls to it fail. Whether
  universal accounts exist is `UniversalOn`, an overridable definition, default
  TRUE (88's rule). It does not follow `NearFees.FeeProtocol`, which selects fees
  only: `FeeProtocol == 86` keeps the creation and charges 86's fee;
  `UniversalOn <- FALSE` gives the rule before 87 (`actions.rs:918-924`).
- `NoOrphans` (no callback waits on nothing, no data without a waiting
  callback) and `ExecNoCode(r)`.
- `examples/platform-selftest`: 49 deterministic scenarios (plus the 10 v0.2 scenarios above; receipts, results,
  accounts, refunds, staking, storage, keys, tokens, gas) with their expected
  nearcore end state. `NearConserved` is now checked in every example except
  `mt-smoke`, and `GasBounded` in the gas-mode examples (`pay`, `weight-split`,
  `eth-implicit-fee`); `eth-implicit-fee` pins the Transfer fees as literals (8146 / 446
  Ggas); `pay` has `pay_gas_std` with the measured `CalibStd` token table.
- Examples with must-pass and must-fail runs: `revert-scope`,
  `callback-after-failure`, `weight-split`, `local-priority`,
  `signer-propagation`, `deletekey-atomicity`, `eth-implicit-fee`,
  `nep141-refund-cap`, `nep145-refund-to-predecessor`. `nep141-refund-cap` also
  covers the oversized result: `refund_cap_oversized` (a 43-byte `"0"` is fully
  refunded) and `refund_cap_oversized_unbounded` (an unbounded resolver honours
  it; `OversizedRefunded` fails).
- `examples/minimal`: the walkthrough model from `docs/USAGE.md` (`Tally`), in
  fault and gas mode, with a must-fail variant and a printed gas window.
- Conformance: joint promises (`promise_and(..).then`) are covered by 8 flows (`and2_*`,
  `and3_mixed`): `AndThen` in `ProbeConf`, joined chains with their own burn keys; inputs ok,
  failing and out of gas, result order (a callback that fails iff its first result failed), and
  zero-gas inputs and callbacks.
- Conformance: yield/resume is covered by a separate `async-probe` contract (on
  `y-probe.near`) and 7 flows (`yield_*`): resume from a later transaction, timeout, a late
  resume, a double resume, a resume in the yielding call, a callback out of gas, a zero-gas
  callback. Flow specs gain `[[flow.after]]` steps (another transaction, or `expire = true`);
  sweeps hold every transaction's receipts (new JSONL field `tx`).
- Conformance: the yield resume payload limit is measured at 1024 bytes, not KiB
  (`tests/semantics.rs`), with semantics tests for two resumes in one block, a resume after
  the timeout and a resume of another account's yield. Totals: 73 flows, 95,849 points,
  222,918 receipts, 0 mismatches; C6 and C7 are validated in the sim for the parts the flows
  observe.
- Conformance: `conform.py` requires each sweep to hold its flow's declared grid exactly
  once and to match a `.meta.json` bound to it by sha256 and point count; empty,
  truncated or duplicated sweeps and model points outside the grid fail. Status and
  attached gas are compared jointly per receipt (label, status and gas, with
  multiplicity). `calibrate` removes the old provenance before sweeping, writes the
  JSONL atomically and the provenance last, and `--from-data` checks the data against
  its provenance. The checker's self-tests (`conformance/scripts/test_conform.py`) run
  in CI.
  Every provenance field is required (`{}` does not pass), repeated model reports of a
  point must agree in every field, the TLC log is read once, and `calibrate` publishes
  each sweep/provenance pair under a per-flow lock with unique temp files, hashing the
  bytes it writes.

### Changed

- `NearKeys.SubmitSigned(r, a, k)` now calls `SubmitAs`; its
  key check also accepts full-access keys (which may attach a deposit).
- `IsTokRcpt` / `IsMtRcpt` are `IsCall(r)` on a token account (no Transfer,
  refund, Stake or key action).
- `NearKeys.KeyAllows` / `KeyCanSign` use `IF` for their cases, so they no longer
  overlap (a key with `all` and an empty method list, or a full-access key signing
  a call, made TLC generate the same successor twice). Verdicts and distinct
  states are unchanged; generated-state counts drop.
- `Tokens` `"batch"`: when the deposit mismatch is not about the 1-yocto action
  (`xf = ""` or `TokYocto = 0`) the error now says so.
- Token outcomes (`TokOut`) always carry `pa` (`<<>>` unless `TokBatchPerAction`);
  `TEv0` has two more fields, `unreg` and `unregBurnt` (storage_unregister).
- `LocalPriorityOK` and the `local-priority` example: ON assumes no congestion;
  OFF is the conservative setting (the `local_off` order is reachable under
  congestion, `lib.rs:2513-2520`).
- Comments now state semantics with nearcore citations (`path:line @ b7b4737`).
- `ResMinBytes`: a result with `len = 0` and `sz = 1` is at least 1 byte (it was
  0), so `ResTooLong(res, 0)` is TRUE for it. Only a bound below 1 byte sees the
  difference; with any positive bound (the resolver's 42) `sz <= 1` stays short.
