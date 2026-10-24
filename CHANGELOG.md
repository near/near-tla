# Changelog

All notable changes to the `modules/` library are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
`docs/VERSIONING.md`.

The entries below are relative to the pre-release module set that existing
models were written against (NearAsync, TokenCommon, Nep145, Nep141, WNear,
Tokens, Nep245, plus a separate NearKeys).

## [Unreleased]

```
nearcore: 2.14.0-rc.5 (b7b4737)   behaviour: protocol 88   fees: FeeProtocol 88, rounded up, covered 84-88
near-contract-sim: 29e909033bb59eab792dee136e9d02870488bc3e
near-contract-standards (token gas defaults): 5.x (measured on 5.29.1)
```

### Breaking

Each entry ends with its migration.

- **`NearFees` rounds fees up by default** (`FeeRounding == "up"`; it rounded to the nearest
  Ggas). Every table entry is rounded up on its own, so no fee is understated and the parts
  still add up: a named Transfer costs its creator 450 Ggas (was 446; exact 446.37), an
  eth-implicit one 8150 (was 8146), near-implicit 8354 (8350), a Stake receipt 463 (460),
  DeleteKey 408 (406), full-access AddKey 422 (420), function-call AddKey 424 (420). Gas-mode
  verdicts and windows move by less than 4 Ggas per action-only receipt (a Transfer or Stake
  child, a key action), always towards "needs more gas": a budget that was a few Ggas short
  in nearcore but passed in the model now fails (`examples/fee-edge`). Models that compare
  `XferFee`, `StakeFee`, `KeyFee` or `NearFeeTable!...` results with literals, or whose gas
  windows sit within that margin of an edge, change verdict. In the repo only
  `eth-implicit-fee` pinned literals; its `FeesPinned` now reads them by mode. No other
  example run changed verdict or state count. Migration: `"NearFees!FeeRounding" =
  '"nearest"'` in a run's `[constants]` (or `[constants]` of the file) restores the old
  behaviour exactly (every table entry, and `Bytes(n, u)` for all `n` up to 3000 and at 20 KB,
  1, 4 and 16 MiB, were checked equal); or update the literals (450, 8150, ...). A model that
  `EXTENDS NearFees` can write `FeeRounding <- FeeNearest` unqualified in its cfg. In a
  hand-written cfg the right of `<-` must be a definition, not a literal (TLC rejects
  `FeeRounding <- [NearFees] "nearest"` as an undefined identifier): define
  `FeeNearest == "nearest"` in the spec and write `FeeRounding <- [NearFees] FeeNearest`.
- **Under `FeeRounding = "up"` (the default) the unused-gas split hands out no whole-Ggas
  remainder.** Every weighted function-call child gets `floor(U * w / W)` Ggas, the last one
  included; it used to get the remainder too, up to `n - 1` Ggas for `n` weighted children,
  which nearcore splits in gas units (`receipt_manager.rs:679-719`), so the last child could
  get more than in nearcore (six equal weights, a model leftover of 1001 Ggas against
  nearcore's 1009.84: 1171 against 1168.31 Ggas, and a burn of 1170 passed in the model
  only). No child now gets more than in nearcore, provided the model's leftover is at most
  nearcore's: burns that are upper bounds and no pooled gas (SEMANTICS N-precision lists the
  exceptions). A static-0 child whose share may be 0 gas keeps both outcomes of its creator
  (next entry). `"nearest"` is
  unchanged (the conformance side, pinned to it, is byte-identical: 73 flows, 0 mismatches).
  Every example run keeps its verdict, state counts (compared at one worker; `selftest_gas`
  grows only by its new scenario) and windows; `weight-split`'s `SplitExact` reads the
  expected split by mode. In other models the last weighted child of a split gets up to
  `n - 1` Ggas less, so verdicts and windows within that margin of an edge can move, towards
  "needs more gas". Migration: `"NearFees!FeeRounding" = '"nearest"'` restores the old split together with the
  old fees; a model that checks a child's gas against the remainder rule reads it by mode
  (`NearFeeTable!FeeRounding`).
- **Gas mode, `"up"`: a static-0 child whose gas may be 0 in nearcore keeps both outcomes
  of its creator.** The model's leftover `U` is a lower bound of nearcore's in whole Ggas, so
  it cannot always tell whether such a child ends up with 0 gas (which fails the creator,
  `action_validation.rs:350-351`, applied at `lib.rs:968-978`). The earlier rule (fail only
  for weight 0 or `U = 0`) was wrong both ways: with a model `U` of 0 nearcore may have
  0.5 Ggas left, and the creator commits; with 1 Ggas over weights `[1, 10^9]` nearcore gives
  `[0, 10^9]` gas units (`receipt_manager.rs:701-716`, `host.rs:3501-3503`), and the
  creator fails. Now weight 0 fails the creator (`ZeroGasKid`); a weight with
  `U * 10^9 * w >= W` certainly gets at least one gas unit (`SureShare`), and the creator
  commits; any other weighted static-0 child makes the verdict `"either"`
  (`ZeroGasMaybe`): `Exec` fails the creator in one successor and commits it in the other,
  where the child runs with 0 Ggas and runs out of gas. `Ok(r, O)` tells which successor the
  step took from the primed platform state, so it must be conjoined after `Exec` in the same
  action (every example does; placed before, TLC stops with an error). `"nearest"` is
  unchanged (conformance byte-identical). New `platform-selftest` scenarios
  `zero_gas_left0` and `zero_gas_heavy`, with runs `selftest_zero_*` that reach both
  outcomes of each (with the old rule one of each is unreachable). `selftest_gas` grows from
  77 to 96 distinct states: the two new scenarios, and `zero_gas_split`, whose first
  transaction (model leftover 0) may now also commit (its `Expect` accepts both);
  `selftest_gas_share_nearest` also runs those three under `"nearest"`, which still fails the
  creators. No other example run changes verdict or state count. Migration: a model with a
  static-0 weighted child and a small or zero model leftover gets the extra successor; an
  invariant that assumed the creator fails (or commits) must accept both, or the model must
  give the child static gas. A model that reads `Verdict` itself must handle `"either"` by
  taking both branches, as `Exec` does: a test like `IF Verdict(..) = "commit" THEN .. ELSE`
  silently turns it into a failure, and TLC reports nothing.
- **Gas mode: `NearKeys.KeyFee` charges a function-call AddKey its per-byte fee**
  (`AddKeyFcBytesFee`, self-directed) on `Σ (len(name) + 1)` bytes over the permission's method
  names (`utils.rs:4-6`; `host.rs:4078-4091`); it used to charge only the base fee (2,000
  bytes: 424 Ggas against nearcore's 428.26; now 432). The names are counted as written, one
  byte per character (nearcore counts UTF-8 bytes);
  `WithMethodBytes(p, n)` states a real byte count (it adds an `mb` field to the permission,
  which the added key keeps: compare permission fields, not whole records). Only `AddKeyRcpt` uses `KeyFee`; no
  example or conformance flow does. Migration: a model whose `AddKeyRcpt` budgets sat within
  a few Ggas of an edge may now run out of gas at creation; give the real byte count with
  `WithMethodBytes` if the names are placeholders or not ASCII.
- **The fee table's self-checks now run for every model.** TLC ignores the `ASSUME`s of an
  INSTANCEd module, so `NearFees`' own checks never ran for models that reach it through
  `NearAsync`'s `NearFeeTable`. `NearAsync` now carries `ASSUME NearFeeTable!FeeSelfChecks`:
  a `FeeRounding` other than `"nearest"` or `"up"`, a `FeeProtocol` outside 84-88, or an
  edited table that no longer reproduces the pinned totals stops TLC before it explores.
  Migration: none for an unedited library.

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
  (`blk = 0`) to a hand-written `Init` that does not use `PlatformInitExtra` (without it TLC
  stops with "current state is not a legal state", `blk = null`, on the initial state); in a
  hand-written `vars`, replace the platform variables with `platformVars`
  (`vars == <<platformVars, mine>>`) or add `blk`.
- **New platform variable `stor` in `NearAsync`** (each account's storage usage in bytes, for
  per-byte storage staking; SEMANTICS B2). It stays `StorageInit` (0 bytes for every account by
  default) unless a model sets `StoragePerByte <- TRUE`, so models that do not are unchanged:
  every example run kept its verdict and its generated, distinct and depth counts (all 97
  runs compared at one worker, the pass runs also at two). It is in `platformVars`, and
  `PlatformInit`, `PlatformInitStaked` and `PlatformInitExtra` initialise it. Like `blk`: a
  step that lists platform variables one by one in `UNCHANGED` must add `stor` (in the
  library: `NearKeys.ExecDelegate`; `ExecKeyAct` now sets it), a hand-written `Init` must set
  it, and a hand-written `vars` must include it. Two more changes come with it, inert without
  `StoragePerByte`: outcome records may carry a field `sb` (bytes written, `OStor`), which
  `TokOut` now always has, so a model whose own outcome field is called `sb` must rename it;
  and `SubmitAs` is guarded by the new `CanSubmit(r, a)`, the same `near[a] >= r.dep` test as
  before plus, with `StoragePerByte`, the signer's storage cover. Migration: write
  `UNCHANGED platformVars` or add `stor` to the list; conjoin `PlatformInitStorage`
  (`stor = StorageInit`) to a hand-written `Init` that does not use `PlatformInitExtra`; in a
  hand-written `vars`, use `platformVars` or add `stor`. With `StoragePerByte`, a hand-written
  `Init` should also list the invariant `StorageCovered`, since only the `PlatformInit`
  helpers check the initial cover.
- **New platform variable `deleted` in `NearAsync`** (the accounts deleted by DeleteAccount and
  not created again since; SEMANTICS A7). `AcctExists` now excludes it, and a deleted account
  fails calls (`CallTargetOK`, even with `CallsNeedCode = FALSE`), Stake, key actions
  (`NearKeys.ExecKeyAct` now checks `AcctExists`) and signing (`CanSubmit`). It stays `{}`
  unless a model runs a DeleteAccount, so models that do not are unchanged: every example run kept its verdict and its generated,
  distinct and depth counts (all 109 runs compared at one worker). It is
  in `platformVars`, and `PlatformInit`, `PlatformInitStaked`, `PlatformInitAccounts` and
  `PlatformInitExtra` initialise it. Like `blk` and `stor`: a step that lists platform
  variables one by one in `UNCHANGED` must add `deleted` (in the library:
  `NearKeys.ExecKeyAct`, `ExecDelegate`), a hand-written `Init` must set it, and a
  hand-written `vars` must include it. Migration: write `UNCHANGED platformVars` or add
  `deleted` to the list; conjoin `PlatformInitAccounts` (`created = {} /\ burnt = 0 /\
  deleted = {}`) to a hand-written `Init` that does not use `PlatformInitExtra`; in a
  hand-written `vars`, use `platformVars` or add `deleted`.
- **New platform variable `code` in `NearAsync`** (the code tag deployed to each account at
  run time, a partial function; SEMANTICS A9). It stays empty unless a model deploys, so
  models that do not are unchanged: every example run kept its verdict and its generated,
  distinct and depth counts (all 132 runs compared at one worker). It is in `platformVars`,
  and `PlatformInit`, `PlatformInitStaked`, `PlatformInitAccounts` and `PlatformInitExtra`
  initialise it. Like `blk`, `stor` and `deleted`: a step that lists platform variables one
  by one in `UNCHANGED` must add `code` (in the library: `NearKeys.ExecKeyAct`,
  `ExecDelegate`), a hand-written `Init` must set it, and a hand-written `vars` must include
  it. Migration: write `UNCHANGED platformVars` or add `code` to the list; conjoin
  `PlatformInitAccounts` (now `created = {} /\ burnt = 0 /\ deleted = {} /\ code = [x \in
  {} |-> NoCode]`) to a hand-written `Init` that does not use `PlatformInitExtra`; in a
  hand-written `vars`, use `platformVars` or add `code`. `NearKeys.FailNoCode(r)` is now
  `IsCall(r) /\ ~CodeSeen(r) /\ FailP(r, FALSE)`: it sees the code a receipt's own
  CreateAccount and DeployContract leave (it used `HasCode(r.to)`).
- **`CallsNeedCode = FALSE` no longer lets a call reach a missing account** (nor an
  uninitialised universal one): `CallTargetOK` requires `AcctExists` and not
  `UninitUniversal` whatever the switch says, as nearcore does (`AccountDoesNotExist`,
  `AccountNotInitialized`, `actions.rs:874-887`); the switch now turns off the code check
  only. Every example run kept its verdict and its generated, distinct and depth counts (all
  130 runs compared at one worker on this change alone); new run `selftest_code_off_missing`.
  Migration: add every account a model calls to `Exists` (or have the model create it).
- **`RemD` and `NoOrphans` cover several inputs per receipt** (`InIds`): a joint callback
  consumes all its inputs, a yield every resume addressed to it, and a pending yield is never
  an orphan. Results for receipts without the new fields are unchanged. Migration: none,
  unless a model hand-wired several data receipts to one callback; use `AndThen` instead.
- **Method name `"DELEGATE"` is reserved for delegate actions** (NEP-366, SEMANTICS K4).
  `IsCall(r)` is FALSE for a receipt with `m = "DELEGATE"` (`DELEG`), and `Exec` and its
  variants stop with an `Assert` on one: a Delegate receipt runs no code, so route it to
  `NearKeys`' `ExecDelegate` in the dispatcher, before the handlers. Once a delegate has run,
  the sender's key record carries a `nonce` field (`KeyNonce`); a model that compares a whole
  key record (`keys[a][k] = FullPerm`) after a delegate must compare its permission fields
  instead, or use `IsFull`. Migration: rename a contract method called `"DELEGATE"`; nothing
  else changes for models without delegates.

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
  `Contracts <- Def` still sets it. Migration: `CallsNeedCode <- FALSE` switches
  the code check off (a missing receiver still fails: the "`CallsNeedCode = FALSE`
  no longer lets a call reach a missing account" entry above); add called accounts to
  `Exists`. Check this: with
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
  `ClockHorizonOK`, `DELEG`, `IsDeleg`, and for per-byte storage `stor` (a variable),
  `StoragePerByte`, `StorageInit`, `StorageByteCost`, `ZeroBalanceBytes`, `AccountBytes`,
  `RecordExtraBytes`, `RecordBytes`, `FullKeyBytes`, `CreatedBytes`, `OStor`, `StorDelta`,
  `StorageCovers`, `StorAfter`, `CanSubmit`, `StorageInitOK`, `PlatformInitStorage`,
  `StorageCovered`; in `NearKeys`, for v0.2: `NoExpiry`, `KeyNonce`,
  `KeysWithNonce`, `SignedDelegate`, `DelegRcpt`, `SubmitDelegate`, `DelegMayExpire`,
  `DelegMustExpire`, `DelegInner`, `DelegErr`, `ExecDelegate`, `IdBytes`, `KeyBytes`,
  `KeyMapBytes`, `KeyActBytes`, `KeyActsBytes`; and in the token modules: `TokRegBytes`,
  `StdRegBytes`, `RegBytes`, `RegBytesSum`, `TokBytes`,
  `OnTransferStatic`, `ReserveShort`,
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
- **`tools/run.py`: an `expect = "pass"` run needs at least one invariant.** Properties alone
  no longer count: a run with an empty INVARIANTS section can pass without looking at a state.
  No run in the repo was affected. Migration: add an invariant, or set
  `allow_no_invariants = "<why>"` on the run.

### Added

- **Account actions in a call receipt** (SEMANTICS A8; docs/USAGE.md section 16). A call
  receipt can carry the `ac` field (`HasAc`, `AcCall`): `WithCreate(r)` puts
  `[CreateAccount, Transfer(r.dep)]` before its call (a factory's batch on the new account;
  the Transfer goes to `ac.xfer` and the call's own deposit `r.dep` becomes 0, what nearcore
  gives the call, `function_call.rs:273`; `DepTotal` is the receipt's NEAR, used for credit,
  refunds, signing and `InflightDeposits`),
  `WithDeleteTo(r, b)` now also accepts a call receipt (a DeleteAccount after its call; a
  second one is an Assert), and `NearKeys.WithAcctKeys` adds key actions. `Exec` runs it:
  `Verdict` has a new first branch for the account actions' checks (`AcCallErr`, the delete's
  large-state check on the bytes after the call), `CallTargetOK` sees the account after the
  create (no code: the call fails unless `CallsNeedCode <- FALSE`), `Affordable`
  (`AcAffordable`) starts a new account at 0 balance and 100 bytes and skips the storage half
  after a delete, and `Commit` (`CommitAc`) applies the account actions with the call (payout
  after the call's children; after a DeleteAccount the callback gets empty bytes, and a
  returned promise's children are kept, unforwarded). With key actions: `NearKeys.ExecK` / `OkK` (plain `Exec`
  asserts). `gf` adds `AcctActsFee` (`AcctFee` without the receipt base) to the call's fee.
  `KeyCanSign` refuses a function-call key for such a receipt. Receipts without `ac` are
  unchanged: every example run kept its verdict and its generated, distinct and depth counts
  (all 123 runs compared at one worker). New `platform-selftest` runs `selftest_accall`,
  `selftest_accall_code_off` and `selftest_accall_storage` (11 scenarios, and a fee check in
  `acct_fee`); new example `account-lifecycle/factory` (`factory_cb_refunds` passes;
  `factory_no_reserve`, `factory_assumes_created` and `factory_not_parent` must fail; with
  witnesses and mutants); `selftest_accall_prom` (a promise-returning call before a
  DeleteAccount), init's attached deposit in `accall_init`, and three library mutants in
  `platform-selftest`. Sim: `promise_call_then_delete`, `batch_call_sees_own_deposit`. A
  factory's `init` finds code once its batch deploys it (the DeployContract entry below).
- **SEMANTICS N-upgrade** (contract upgrades mid-flow: a handler runs the new code only if it
  branches on `CodeOf(r.to)`), and the `NearAsync` / `NearKeys` header comments now list
  DeployContract, instant receipts and DeleteAccount as modelled and point to SEMANTICS "Not
  modelled".
- **`BalSeen(r)`: the balance a handler sees** (`env::account_balance`, SEMANTICS A8):
  `near[r.to]` after the receipt's earlier actions (0 for an account the receipt creates,
  plus a factory batch's Transfer) plus the call's attached deposit
  (`function_call.rs:269`, near-vm-runner `logic.rs:45-49`). Reading `near[r.to]` in a
  handler gives the balance before the receipt, which in a factory batch misses the
  Transfer. `platform-selftest`'s `seebal` and `init` use it (`accall_init` checks 2 NEAR);
  library mutant `lib_balseen_no_transfer`.
- **DeployContract** (SEMANTICS A9; docs/USAGE.md section 16). A code is a tag with
  `CodeLen[t]` bytes (overridable, default 0); the new platform variable `code` maps an
  account to the tag deployed at run time, `CodeOf(a)` falls back to `InitCode` (overridable,
  default `"code"`) for the accounts in `Contracts`, and `HasCode` is `AcctExists(a) /\
  CodeOf(a) # NoCode`, equal to the old definition while nothing is deployed.
  `WithDeploy(r, t)` adds DeployContract(t) to an ACCOUNT or call receipt (after its
  CreateAccount and Transfer, before its call and DeleteAccount; a second one, or a tag over
  4 MiB, is an Assert) with its fee, deploy_base plus deploy_byte per byte (`d0.gf = 660`
  Ggas for 1000 bytes on the same account); `DeployRcpt(id, tx, acct, a, t, cb)` is a lone
  deploy. The checks are `AcctErr`'s (existence, initialised, actor = the account); the bytes
  lose the old code and gain the new (`CodeBytes` reads `code`, `DplDelta`, `AcctBytes`), so
  the storage check and the DeleteAccount's 10,000-byte check see them; on success `code`
  changes (`CodeNext`: a delete, or a create without a deploy, drops the entry). A call sees
  the code its receipt leaves (`CodeAfter`, `CodeSeen`, used by `CallTargetOK` and
  `NearKeys.FailNoCode`, which ignored account actions before). An eth-implicit account
  created at run time (also again, after a deletion) has `EthWalletCode` (overridable,
  `"eth_wallet"`), not its initial tag (`selftest_eth_recreate`), and gets it whether or not
  the model lists it in `Contracts` (it had code only if listed; `selftest_eth_wallet`; no
  example run changed, all 138 compared at one worker on this change alone). Every example run kept its
  verdict and its generated, distinct and depth counts (all 132 runs compared at one worker),
  `account-lifecycle/factory` included, whose batch now deploys its child's code and no
  longer sets `CallsNeedCode <- FALSE`. New runs `selftest_deploy`, `selftest_deploy_storage`
  (9 scenarios, a fee check in `acct_fee`, five library mutants), `factory_underfunds_code`
  (must fail: a 300 KB child contract that the batch's 2 NEAR does not cover) and
  `factory_funds_code`; `Served` checks that the account exists, not only its owner label
  (`factory_owner_label`, must fail: the label written on a failed batch). N-deploy is gone; N-limits states the 10-deploy and 4 MiB limits.
- **Instant receipts** (SEMANTICS S5; docs/USAGE.md section 16). A lone DeleteAccount
  (`IsInstantShape`) that a receipt creates, in its outcome's ready set, as a joint callback
  with no inputs in its postponed set (`.then` on an empty `promise_and`, `InstantTagP`) or as
  a delegate's inner receipt, is tagged `inst` (`InstantTag`, by `Commit` and
  `NearKeys.ExecDelegate`).
  While one is pending (`InstantPending`), `Runnable` holds only tagged receipts (no yield
  timeout either; the earlier set is `RunnableAll`), `SubmitAs`, `BlockTick` and `EpochTick`
  are disabled, and `LocalPriorityOK` never holds a tagged receipt back. Models conjoin
  `~InstantPending` to their own steps outside receipts; forgetting it only adds
  interleavings. `InstantFirst` (overridable, default `TRUE`) switches it off, an
  over-approximation (N-instant, rewritten). The payout of a delete stays a later receipt.
  Models that create no such receipt are unchanged: every example run kept its verdict and
  its generated, distinct and depth counts (all 116 runs compared at one worker). New
  `platform-selftest` runs `selftest_instant` (a contract's self-delete, a delegate's inner delete relayed by another
  account and by the user itself, a transaction's delete that is not instant),
  `selftest_instant_off` and `selftest_payout_before` / `_after` (the payout runs in either
  order); new example `account-lifecycle/instant` (`instant_on_passes`,
  `instant_empty_join_passes`, `instant_off_spurious`, with witnesses and mutants).
- **CreateAccount and DeleteAccount** (SEMANTICS A6, A7; docs/USAGE.md section 16). A new
  receipt kind, ACCOUNT (`ACCT`, `IsAcctRcpt`), holds `[CreateAccount]? [Transfer]? [key
  actions]* [DeleteAccount]?` in an optional field `ac`: constructors `CreateAcctRcpt`,
  `DeleteAcctRcpt`, `WithDeleteTo` and `NearKeys.WithAcctKeys`; `ExecAcct` (and
  `NearKeys.ExecAcctK`, with key actions) runs it with nearcore's checks in order (`AcctErr`:
  existing account, implicit id, top-level id only by `TopCreator`, sub-account only by its
  parent in `AcctParent` / `Parents`, actor, staking, large state with `MaxDeleteBytes` and
  `CodeSize`), an atomic failure that refunds the creator, and the storage check after the
  actions. A delete pays the balance out in a later refund receipt (burnt for an absent
  beneficiary), clears `near`, `stor` and keys and adds the account to `deleted`; postponed
  callbacks, data and yields survive it and run on the account if it is created again.
  `DeletesAcct(r)` tells a model to reset its own state. In gas mode `AcctFee` puts the
  receipt's whole send + exec fee in `gf`: the prepaid reservation, whatever the outcome
  (nearcore stops a failed receipt at its failing action and refunds the exec fees of the
  actions after it as gas, which is not modelled). An uninitialised universal account
  (`UninitUniversal`, which needs `UniversalOn`) fails key actions, DeleteAccount and the
  delegates it signs with `AccountNotInitialized`; with `UniversalOn <- FALSE` a `0u` id is
  an ordinary named account. `ExecTransfer` takes a deleted implicit account
  out of `deleted` when it creates it again, and `NearKeys.ExecTransferK` / `ExecBuiltinK`
  give a NEAR-implicit account a Transfer creates its full-access key (`ImplicitKeyId`).
  Validated against the sim (`conformance/tests/lifecycle.rs`, 14 tests: creation rules,
  atomic batches, payouts, the actor and staking checks, the 10,000-byte limit at its
  boundary, receipts to a deleted account, re-creation, postponed callbacks, data and yields
  surviving deletion, deploy storage, an instant delete via a delegate, fees, the empty
  result of a call followed by DeleteAccount). New `platform-selftest` runs
  `selftest_lifecycle`, `selftest_lifecycle_gas`, `selftest_lifecycle_storage` and
  `selftest_universal_off` (18 scenarios), and a new example `account-lifecycle`
  (`escrow_pays_deleted` must fail, `escrow_pays_cb` passes, `refund_to_deleted_burns` must
  fail; with witnesses and mutants). SEMANTICS: N-create-account and N-delete-account are
  gone; new N-acct-ids, N-delete-large and N-wipe; N-refund-stuck, N-storage, N-universal,
  N-gas-keys and N-delegate-rekey updated.
- **`tools/run.py --anti-vacuity`: witnesses and mutants.** Two new tables in `runs.toml`.
  A `[[witness]]` is a situation that must be reachable: the runner checks `Wit_<id>` alone
  and requires a violation; a pass fails as `vacuous: witness <id> never reached`
  (`expect = "unreachable"` with a `reason` documents an exception). A `[[mutant]]` patches a
  copy of the spec or library directory (`find`, `replace`, `count`, checked before any TLC
  process starts) and must be killed by a listed run's invariant (`killed_by` names the
  invariants, or `"assert"` / `"deadlock"`, that count; an Assert or deadlock alone fails
  otherwise; a library module shadowed by one beside `runs.toml` is refused), a survivor fails unless marked `equivalent = "<why>"`, and a timeout is its own
  result. Each job has its run's budget. Off by default; CI runs it in a separate job. The
  tables are validated on every run. Conventions: docs/USAGE.md, Witnesses and mutants. The
  method comes from a mutation audit of the examples, in which a dropped `.then` left a result
  with nothing to consume it, so `Idle` never held and `Idle => P` passed vacuously.
- **Examples: witnesses in every example except `platform-selftest`, and mutants wherever a
  correct pass run exists** (not in `yield-clock/final-observation`), and the
  invariants that kill the mutants: `NoOrphans` in every `Sane`; per-term `>= 0` beside
  conservation sums (`NoOverdraft`, `NoNegCredit`); effect invariants (`CallbackRan`,
  `RevokeTakesEffect`, `OpenApplied`, `WorkFits`, `Forgotten`); checks against the
  counterparty's recorded answer instead of a handler ghost (`ResolvedAsAsked`,
  `SenderCredited` in `nep141-refund-cap`); the cancel-window ghost of `yield-clock`
  (`NoEarlyCancel`, `CancelHonoured`); `VaultCovered` in `storage-stake`; `meta-tx`'s
  `Credited` counts good claims only. Runs with asymmetric constants where symmetric ones hid
  a mutant: `weight_split_123` (weights `<<1, 2, 3>>`), `yield_ok_tx4` (four transactions),
  `vault_per_byte_atomic_room` (room for two payouts). `mt-smoke` gains a `Sane`.
- **`tools/tlcparse.py`**: a violated invariant that reads no variable ("The invariant of X is
  equal to FALSE", evaluated before the search) is a violation of X, not an error.

- **Per-byte storage staking** (SEMANTICS B2), opt-in with `StoragePerByte <- TRUE`. The
  library keeps each account's storage usage in bytes (`stor`, from `StorageInit`) and, after
  every receipt that can lose its cover, checks that liquid + locked covers it at
  `StorageByteCost` (1e19 yocto per byte at 88), with the 770-byte zero-balance exemption
  (NEP-448). A shortfall fails the whole receipt with `LackBalanceForState`. Handlers declare
  their bytes with `OStor(O, d)` (`RecordBytes(k, v)` = key + value + 40); key actions
  (`NearKeys.KeyBytes`: 82 bytes for a full-access key, the borsh formula for a function-call
  key with `IdBytes` for the receiver and the AddKey fee's method-name bytes), bundled key actions (`WithKeyActs`), implicit-account creation
  (`CreatedBytes`: 182, 132 or 100) and token registrations (`Nep145.TokRegBytes`, per token and holder:
  `StdRegBytes(len(id))` = 61 + the id's length for near-contract-standards) are counted by the library. A transaction that would leave its
  signer uncovered cannot be submitted (`CanSubmit`). The fixed `StorageFloor` stays the
  default and is not checked with `StoragePerByte`: both encode the same rule. The invariant
  `StorageCovered` holds from a covered initial state, which `PlatformInit` asserts.
- **`examples/storage-stake`**: a vault that pays a user and records the payout in a callback.
  Under the fixed floor it passes (`vault_floor_misses_it`, a false pass); per byte, the second
  record no longer fits after the payout, so the callback fails and a user is paid but not
  recorded (`vault_per_byte_unrecorded`, must fail). Recording in the paying receipt passes
  (`vault_per_byte_atomic_ok`), and pays someone (`vault_per_byte_atomic_pays`, must fail on
  `NobodyPaid`).
- **`platform-selftest`: run `selftest_storage`**, nine per-byte scenarios: growth within the
  balance (the boundary inclusive, a deposit counted), growth beyond it (the receipt reverted, a
  callback seeing Failed), shrinking, the 770-byte allowance, locked balance, key bytes,
  implicit-account bytes, the signer check and token registrations. Each one fails without
  `StoragePerByte`. `Sane` gains `StorageCovered`.
- **Conformance: seven storage tests** in `conformance/tests/semantics.rs`: the bytes of a
  write and an overwrite, `LackBalanceForState` one yocto short (reverted) and passing with
  exactly enough, a callback failing for storage after its payout, the 770-byte allowance,
  full-access and function-call key bytes, the signer refused at conversion, and the bytes of
  created implicit accounts.

- **`NearFees.FeeRounding`** (`"up"`, the default, or `"nearest"`), `FeeRoundingModes`,
  `FeeRoundM` / `FeeRoundU`, the source tables `BaseRowM` (mGgas, rounded up) and `ByteRowG`
  (exact gas per byte), and `FeeSelfChecks` (the self-checks, pinned per mode, as one
  operator; `FeePin(nearest, up)` picks the value). Error bounds per mode are in the module
  header and SEMANTICS N-precision.
- **`tools/run.py`: module-qualified constants.** A key `Mod!Name` in `[constants]` or
  `[run.constants]` becomes TLC's `Name <- [Mod] const_Mod_Name`, which overrides a definition
  of a module the spec reaches through EXTENDS or INSTANCE, so `"NearFees!FeeRounding" =
  '"nearest"'` also reaches `NearAsync`'s `NearFeeTable`. The runner checks that `Mod` is
  reachable and defines `Name` as a zero-arity definition. A `Name` that is a CONSTANT of
  `Mod` is rejected: TLC's `[Mod]` substitution overrides definitions only and would leave
  the CONSTANT unassigned ("not assigned a value by the configuration file"). The error says
  to assign it unqualified (when the spec or a module it EXTENDS declares it) or to bind it
  with `INSTANCE Mod WITH Name <- ...`.
- **`examples/weight-split/remainder`**: the split's remainder, directionally. Six calls of
  weight 1 share a model leftover of 1001 Ggas; nearcore's is taken as 1009.84 Ggas.
  `remainder_up_ok` (the default) checks that no call gets more than nearcore's share
  (`SharesLeNearcore`) and that the last, burning 1169.9 Ggas (1170 in the table), runs out of
  gas as in nearcore (`NoFalseOk`); under `"nearest"` both fail (`remainder_nearest_over`,
  `remainder_nearest_false_ok`). `weight-split` gains `weight_split_ok_nearest`, and
  `platform-selftest` the scenario `zero_gas_share` (two static-0 calls sharing 1 Ggas: the
  creator commits under `"up"`, fails under `"nearest"`; run `selftest_gas_share_nearest`).
- **`examples/fee-edge`**: a Transfer budget 0.37 Ggas short of nearcore's fee passes under
  `"nearest"` (`edge_nearest_misses`, a false pass) and fails under `"up"`
  (`edge_up_catches`); the must-pass `edge_up_ok`, and `edge_up_tight_false_cex`, the price of
  "up" (a budget nearcore accepts, within the margin, fails).
- **`examples/pair-order`**: two messages from one contract to another, the second sent only
  after the first was created. A receiver that assumes they arrive in order is left open
  (`pair_assumes_fifo`, must fail); one that keeps the highest sequence number seen passes
  (`pair_seqno_ok`).
- **`eth-implicit-fee`: run `eth_fee_ok_nearest`**, the same model under `"nearest"`.
- **Conformance: `later_receipt_overtakes_buffered`** in `conformance/tests/semantics.rs`: in
  the sim, with no fault injected, three ~1.2 MB receipts `p-probe` made for `q-probe` are
  overtaken by a small one `p-probe` made after them in the same block (SEMANTICS S4).

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
  `ClockHorizonOK(n, T)` (`MaxBlk >= (n + 1) * max(T, YieldTicks)`, with `T` the largest
  number of blocks a clock comparison counts and `n` the most clock-relevant steps per
  behaviour; the `+ 1` is the gap after the last step, where an invariant still reads the
  clock: then the bound covers every behaviour).
- Examples `joint-promise` (`Pair`), `yield-resume` (`Oracle`, the double-resume trap) and
  `yield-clock` (`Deadline`: early timeouts at a too small bound, `cancel_trusts_timeout`,
  `cancel_after_answer`, and `horizon_*`: a double refund that passes at `MaxBlk = 2`, is
  flagged by `ClockHorizonOK` and found at `MaxBlk = 3`; `final-observation` (`Arm`):
  `final_obs_*`, an invariant that fails only in the gap after the last clock-relevant step),
  with must-pass and must-fail runs.
- `examples/platform-selftest`: `selftest_async` and `selftest_async_gas`, 10 scenarios for
  joint callbacks (result order, a starved input, a callback with no gas) and yields (a second
  resume, two resumes in the yielding call, timeout then resume, a resume in flight at the
  deadline, another account's resume, a returned yield, a yield callback with no gas). The
  script item `BTick` is one block.
- **Delegate actions** (NEP-366 meta transactions, SEMANTICS K4), in `NearKeys`:
  `SignedDelegate(s, k, n, mbh, c)` (the user's signature over nonce `n`, expiry height
  `mbh` or `NoExpiry`, and the inner receipt `c`), `SubmitDelegate(id, tx, rl, k, sd)` (the
  relayer's transaction, signed with its key `k`), and `ExecDelegate(r)`, which checks the
  delegate on the user's account (existence, sender, key, nonce, function-call key scope,
  expiry) and emits the inner receipt with predecessor the user and signer the relayer. The
  relayer pays the deposit; it is refunded to the relayer if the delegate fails and to the
  user if the inner call fails. Delegate nonces live in the key record (`KeyNonce`); expiry
  reads `blk` (`DelegMayExpire`, `DelegMustExpire`; with no clock a delegate with an expiry
  may expire at any time). Helpers: `DelegRcpt`, `DelegInner`, `DelegErr`, `KeysWithNonce`;
  in `NearAsync`, `DELEG` and `IsDeleg`.
- **`examples/meta-tx`** (`MetaTx`): a contract that credits `env::signer_account_id()` pays
  the relayer instead of the user (`meta_trusts_signer`, must fail on `Credited`; the same
  contract without relayed calls passes); one that credits the predecessor passes
  (`meta_predecessor_ok`), also on a clock with expiring delegates (`meta_expiry_clock`). A
  failing inner call refunds the relayer's deposit to the user (`meta_deposit_refund_to_user`,
  must fail on `NoUserProfit`), and a mutant runtime without the nonce check lets the
  relayer's replays credit a claim twice (`meta_no_nonce_check`, must fail on `Credited`).
  Without a clock a delegate with an expiry may fail at any time (`meta_expiry_anytime`).
- `examples/platform-selftest`: `selftest_deleg` and `selftest_deleg_gas`, 7 scenarios for
  delegates: who the inner call sees, replays and nonce gaps, expiry on the clock, the refund
  of a failed delegate (to the relayer) and of a failed inner call (to the user),
  function-call key scope on the user's and on the relayer's side, and the outer checks (a
  key deleted before the delegate runs, a missing sender account). The script item `Dl` is a
  delegate.
- **Conformance: delegate tests** in `conformance/tests/semantics.rs` (signer and predecessor
  of the inner call, nonce replay, inclusive expiry and the relayer's refund, the user's
  refund on inner failure, the key checked at execution, function-call key scope), and the
  probe flow `relay_chain1`: `chain1` as a delegate relayed by `dave.near`, compared
  receipt by receipt like the others. Flows take an optional `relay` key (the relayer
  account); `ProbeConf` runs such a flow through `SubmitDelegate` / `ExecDelegate`. The
  calibrator takes a child's exec fee only from a function-call parent, since a Delegate
  receipt pays none.

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
- Conformance: receipts are matched by transaction. A receipt's label carries its
  transaction number (the sweep's `tx` + 1; `ProbeConf` numbers only transactions, so an
  `expire` step no longer shifts the next one: `yield_resume_late`'s resume is transaction 2
  on both sides, it was 3 in the model), so outcomes swapped between two transactions fail
  the statuses, the gas pairing and the edges.
- `tools/run.py` and `conformance/scripts/tlc.sh` give each TLC process a private
  `java.io.tmpdir`. TLC unpacks its standard modules there, and concurrent runs sharing one
  directory could read each other's half-written copies (spurious parse errors or a stalled run).
- Conformance: `crate_dir()` prefers the run-time `CARGO_MANIFEST_DIR` (set by `cargo run` /
  `cargo test`) over the compile-time one, so a `calibrate` binary built in another checkout of
  the repo (shared `CARGO_TARGET_DIR` or build cache) no longer reads and writes that
  checkout's `data/`.
- Conformance: `ProbeConf` checks `NotStuck`: a branch that has run every step and can do
  nothing more must be `Done` (no data or non-yield receipt left over). Such a branch prints
  no report, so before this another branch at the same prepaid point could hide it.
- Conformance: the yields still parked once a point's last step has run are compared. Sweeps
  gain a per-line field `yields` (`Sim::yields()`; re-sweep: a line without it is
  unreadable), `ProbeConf`'s report prints `Parked` (`<<"CONF", pp, Parked, rlog>>`), and the
  count is part of the status vector. Every point of the 73 flows ends with none, on both
  sides; the totals and the calibrated tables are unchanged.

### Changed

- Docs: SEMANTICS N-order and N-resume-order were wrong. nearcore keeps no per-pair order at
  protocol 88: a new receipt bypasses the link's outgoing buffer whenever it fits
  (`congestion_control.rs:292-325`, `:451`), and missed chunks reverse the order across heights
  (`chunk_validation.rs:478-480`). They are replaced by S4 ("No per-pair order"), which states
  what nearcore does order (S2: per chunk, not per pair). Same-pair reorders are reachable,
  so one alone does not make a counterexample spurious, though not every order the model
  allows is (receipts in one receipt proof keep their order); the planned opt-in pair-order
  switch is dropped, as it would only hide real reorderings.
- Docs: N-precision, Units, USAGE and the `NearFees` header describe both rounding modes.
- Conformance calibrator (`conformance/src/calib.rs`, `fit`): the burn line is an upper
  envelope. `per` is still the least-squares slope rounded to the nearest Ggas, but `base` is
  now the smallest value that puts every measured burn at or below `base + per × size` (it was
  the least-squares intercept, rounded up, which could sit below a measurement). "max
  residual" in a table's comments is now the most the line overstates one measurement.
  `CalibStd` is regenerated: no number changed (all its keys have `per = 0`, where the fit was
  already the largest burn); only its header gained a line on the envelope.
  `conformance/tla/CalibProbes.tla`: `p.on_read` base 268 → 270 and `q.burn` base 0 → 1 Ggas.

- Docs: S2, S4 and the README no longer claim that the model's unrestricted per-pair order
  is exact. Same-pair overtaking is reachable, so a reorder alone does not make a
  counterexample spurious, but receipts in one receipt proof keep their order
  (`chunk_validation.rs:510-514`): a counterexample that reverses them can be spurious, and
  its schedule must still be shown reachable.
- Docs: C6 and C7 no longer claim that the sim validates execution order (the callback
  after the last input, after the resume or the timeout): the comparison is per receipt and
  unordered, and a yield callback is listed under the yielding transaction on both sides, so
  the transaction gives no order either.
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
