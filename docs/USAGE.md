# Modelling a contract with near-tla

This guide walks through modelling a NEAR contract on the library. It covers:

- where your model lives, and a complete minimal model;
- choosing modules, setting constants, and writing handlers;
- calling and receiving tokens, and keys;
- gas, and calibration;
- replaying a counterexample in the sim;
- the runner.

It starts with the method that makes the results worth trusting.

Read [`SEMANTICS.md`](SEMANTICS.md) alongside it: that page says which runtime rule each
operator encodes, where it comes from in nearcore, and what is not modelled.

## Contents

- [The method](#the-method)
- [0. Where your model lives](#0-where-your-model-lives)
- [A complete minimal model](#a-complete-minimal-model)
- [1. Choose the modules](#1-choose-the-modules)
- [2. Constants and overridable definitions](#2-constants-and-overridable-definitions)
- [3. Variables and Init](#3-variables-and-init)
- [4. Receipts](#4-receipts)
- [5. Writing handlers](#5-writing-handlers)
- [6. The dispatcher and Next](#6-the-dispatcher-and-next)
- [7. Reading promise results](#7-reading-promise-results)
- [8. Calling tokens](#8-calling-tokens)
- [9. Receiving tokens](#9-receiving-tokens)
- [10. Signer and keys](#10-signer-and-keys)
- [11. Local-receipt priority](#11-local-receipt-priority)
- [12. Fault mode and gas mode](#12-fault-mode-and-gas-mode)
- [13. The forced-fault switch and labels](#13-the-forced-fault-switch-and-labels)
- [Calibrating](#calibrating)
- [Replaying a counterexample in the sim](#replaying-a-counterexample-in-the-sim)
- [The runner: `runs.toml`](#the-runner-runstoml)
- [Every invariant must be able to fail](#every-invariant-must-be-able-to-fail)
- [Print-only window invariants](#print-only-window-invariants)
- [Worked material](#worked-material)

## The method

These six habits separate a model that finds real bugs from one that produces confident
noise. The rest of this guide is the mechanics.

1. **Write the properties first.** Before any handler, write down what must hold: books
   balance, every refund is honoured, nothing is paid twice, a callback's cleanup always
   happens. Prefer per-user and per-operation obligations over one conservation total: a total
   cannot tell you that one user's money moved to another.
2. **Treat gas as a quantity.** A receipt runs out of gas because its need exceeds the gas it
   holds, and the leftover split decides who gets how much. "This call may fail" (fault mode)
   is the coarse tool: use it to explore, then use gas mode to find out at which prepaid
   amounts a failure is reachable.
3. **Calibrate before trusting windows.** A gas window is only as good as the burn table. Use
   measured burns, record their provenance, and check that the leftover split reproduces with
   zero mismatches before believing any gas-mode verdict.
4. **Replay every counterexample on real wasm.** The model over-approximates ordering and
   abstracts your contract. A trace is a hypothesis until the same receipt tree, with the same
   gas and faults, reproduces in near-contract-sim against the compiled contract.
5. **Make every invariant able to fail.** For each invariant, add a deliberately wrong
   variant that TLC must report, and confirm from the trace that it fails for the reason you
   intended. An invariant that has never failed may be vacuous.
6. **If you conjoin `LocalPriorityOK`, also run without it.** Local-receipt priority is
   opt-in, and off unless your model conjoins it ([section 11](#11-local-receipt-priority)).
   It holds only while the receiving chunk has room. A violation that appears only without it
   is real whenever the chunk is full, unless you can show the receiving shard is never at its
   limit.

**Steps 3 and 4 need the sim.** Calibrating and replaying run your wasm in near-contract-sim,
a private repository; see [Access to the sim](CONFORMANCE.md#access-to-the-sim). Without access:

- keep to fault mode for your conclusions;
- if you use gas mode, fill the tables by hand from your contract's declared static gas and
  weights and a rough burn estimate, and say so in the model;
- treat every gas window as illustrative, not as a finding;
- replay counterexamples by reading the contract's code path by path, and say that you did.

## 0. Where your model lives

A model is a directory with your spec (`MyContract.tla`) and a `runs.toml` that lists its TLC
runs. It does not have to be inside this repo.

- **Inside `examples/<name>/`** of this repo, the runner finds the library at
  `../../modules`, the default.
- **Anywhere else** (your own repo, a scratch directory), the runner falls back to the
  `modules/` directory of the near-tla checkout the runner itself lives in. Run it from your
  checkout: `python3 ~/src/near-tla/tools/run.py path/to/model/`.
- **To point at a specific library**, set `library = "path/to/modules"` in `runs.toml`
  (relative to the `runs.toml`). `--library DIR` and the environment variable
  `NEAR_TLA_LIBRARY` override it for every run.

The runner passes the library to TLC as `-DTLA-Library=<spec dir>:<library>`, so modules
beside your spec (a calibrated table, say) are found first. `python3 tools/run.py --help` is
the reference.

## A complete minimal model

[`examples/minimal/`](../examples/minimal/) is a complete model you can copy as a starting
point. CI runs it, so it keeps working.

User `U` calls `C.ping()`. `ping` calls `D.work()` and then its own callback `C.done()`. `D`
counts the works that committed; `C` counts, in `done`, the works it believes happened. The
property: once nothing is in flight, the two counts agree. The work can fail, but `done` runs
anyway and sees Failed, so `done` must look at its promise result. `Trusting = TRUE` is the
wrong contract, which counts without looking.

```tla
-------------------------------- MODULE Tally --------------------------------
EXTENDS NearAsync

CONSTANTS U, C, D,     \* account names
    MaxTx,             \* number of ping transactions
    InitU,             \* U's initial balance (pays the deposits)
    GasMenu,           \* prepaid gas U may attach (gas mode), Ggas
    Trusting           \* TRUE: done counts a work without checking its result

VARIABLES n, works, ntx, gas
mine == <<n, works, ntx, gas>>
vars == <<platformVars, mine>>

Accts   == {U, C, D}
TxIds   == 1..MaxTx
Near0   == [a \in Accts |-> IF a = U THEN InitU ELSE 0]
Floor0  == [a \in Accts |-> 0]
NoTable == [x \in {} |-> 0]
Menu    == {t * 100 : t \in 80..95} \cup {1000000}   \* 8.0-9.5 Tgas by 0.1, and the 1000 Tgas maximum

\* Gas tables (Ggas).  ILLUSTRATIVE numbers, not measured.
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
TGasCall == ("work" :> GC(<<5000>>, <<1>>, 300))     \* 5 Tgas static + all the leftover
         @@ ("done" :> GC(<<2000>>, <<0>>, 300))     \* 2 Tgas static, no share
TGasBurn == ("ping" :> [base |-> 1000, per |-> 0])
         @@ ("work" :> [base |-> 5500, per |-> 0])
         @@ ("done" :> [base |-> 600,  per |-> 0])

\* ping(): D.work().then(C.done()); returns done's result.
H_ping(r) ==
    LET w  == Rcpt(nid, r.tx, D, C, "work", r.a, 0, C, nid + 1)
        cb == Rcpt(nid + 1, r.tx, C, C, "done", r.a, 0, C, r.cb)
    IN Outcome({w}, {cb}, RProm, 0, 2)

\* done(): count the work only if it succeeded (Trusting: count it anyway).
H_done(r) == Outcome({}, {}, RVal(EMPTY), 0, 0)
NewN(r) == IF Trusting \/ ~IsFailed(r.res) THEN n + 1 ELSE n

RunC(r) ==
    LET O == IF r.m = "ping" THEN H_ping(r) ELSE H_done(r) IN
    /\ Exec(r, O)
    /\ n' = IF Ok(r, O) /\ r.m = "done" THEN NewN(r) ELSE n
    /\ UNCHANGED <<works, ntx, gas>>

RunD(r) ==
    LET O == Outcome({}, {}, RVal(EMPTY), 0, 0) IN
    /\ Exec(r, O)
    /\ works' = IF Ok(r, O) THEN works + 1 ELSE works
    /\ UNCHANGED <<n, ntx, gas>>

Step(r) ==
    CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine     \* Transfer, refund, Stake
      [] r.to = D     -> RunD(r)
      [] OTHER        -> RunC(r)

Ping ==
    /\ ntx < MaxTx
    /\ \E g \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
         /\ Submit(WithGas(Rcpt(nid, ntx + 1, C, U, "ping", [x |-> 0], 1, U, 0), g))
         /\ gas' = [gas EXCEPT ![ntx + 1] = g]
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<n, works>>

Init == /\ PlatformInit(Near0, TxIds)
        /\ n = 0 /\ works = 0 /\ ntx = 0
        /\ gas = [t \in TxIds |-> 0]

Next == \/ Ping
        \/ \E r \in Runnable : Step(r)
        \/ \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine
Spec == Init /\ [][Next]_vars

Counted == Idle => n = works
Sane == NearConserved(InitU) /\ GasBounded(LAMBDA t : gas[t]) /\ NoOrphans
WinCounted == (Idle /\ n # works) => PrintT(<<"WIN", "Counted", gas[ntx], oog>>)
=============================================================================
```

Its `runs.toml` sets every constant once and has five runs:

- `tally_ok`: fault mode, `work` may fail once; must pass.
- `tally_trusting`: the same with `Trusting = TRUE`; must fail `Counted`.
- `tally_gas_ok`: gas mode over the menu; must pass.
- `tally_gas_trusting`: gas mode with the trusting `done`; must fail `Counted`, because
  `work` runs out of gas below 9.1 Tgas.
- `tally_gas_win`: the same as a print-only window, which must be exactly 8.6-9.0 Tgas.

```toml
spec = "Tally"
workers = 2
library = "../../modules"
budget_s = 60
invariants = ["Counted", "Sane"]

# TLA+ expression text. Single quotes keep backslashes and double quotes literal.
[constants]
Accounts = 'Accts'
Exists = 'Accts'
StorageFloor = 'Floor0'
StakingAcct = '"c"'
MinStake = '1'
MaxEpoch = '0'
MaxReward = '0'
GasMode = '"fault"'
GasCall = 'NoTable'
GasBurn = 'NoTable'
MayFail = '{}'
MaxFails = '0'
LogOn = 'FALSE'
TrackSigner = 'FALSE'           # the model never reads the signer
U = '"u"'
C = '"c"'
D = '"d"'
MaxTx = '2'
InitU = '2'
GasMenu = '{0}'
Trusting = 'FALSE'

[[run]]
name = "tally_ok"
expect = "pass"
[run.constants]
MayFail = '{"work"}'
MaxFails = '1'

[[run]]
name = "tally_trusting"
expect = "violation"
invariant = "Counted"
[run.constants]
MayFail = '{"work"}'
MaxFails = '1'
Trusting = 'TRUE'

# ... tally_gas_ok, tally_gas_trusting, tally_gas_win: see examples/minimal/runs.toml
```

Run it:

```sh
python3 tools/run.py examples/minimal                                  # every run
python3 tools/run.py examples/minimal tally_gas_trusting --print-trace # one run, with its trace
```

The sections below explain each piece.

## 1. Choose the modules

Extend the highest module you need. Each module extends the ones below it.

| your contract... | `EXTENDS` |
|---|---|
| makes cross-contract calls, callbacks, Transfers, Stake | `NearAsync` |
| also reads or changes access keys, or cares which key signed | `NearKeys` |
| holds or moves NEP-141 tokens, or uses wNEAR | `Tokens` |
| talks to an external NEP-245 multi-token | `Nep245` (add `Tokens` if it also uses FTs) |
| needs both tokens and keys | `Tokens, NearKeys` |

`EXTENDS Tokens, NearKeys` is a diamond: both reach `NearAsync`. TLA+ allows it, and the
shared definitions are merged, so `Rcpt`, `Exec` and the platform variables exist once.
`examples/platform-selftest/SelfTest.tla` uses exactly this.

`NearFees` (the fee table) is already available inside `NearAsync` as the named instance
`NearFeeTable`, so its operators do not enter your namespace; write
`NearFeeTable!TransferFeeTotal(sir, kind)`. Extend `NearFees` yourself only if you want the
operators unqualified. `CalibStd` holds measured tables; instantiate it
(`Std == INSTANCE CalibStd`) where you build your gas tables.

The library exports many names (`Burn`, `Need`, `Share`, `ReserveShape`, `PathKey`, ...).
If SANY reports a "multiply-defined symbol", rename your own definition.

## 2. Constants and overridable definitions

### Constants you must set

`NearAsync` declares these. The runner takes their values from `runs.toml` as TLA+ expression
text (see [The runner](#the-runner-runstoml)).

| constant | meaning |
|---|---|
| `Accounts` | every account that holds native NEAR in the model |
| `Exists` | the accounts that exist initially (the rest can be created by an implicit-account Transfer, or never exist) |
| `StorageFloor` | `[Accounts -> Nat]`: what liquid + locked must cover after a function call (`LackBalanceForState`); 0 for an account under the zero-balance storage limit |
| `StakingAcct`, `MinStake`, `MaxEpoch`, `MaxReward` | the one staking account, its minimum stake, and the bounds on epoch ticks and rewards (`MaxEpoch = 0`: no epoch ticks) |
| `GasMode` | `"fault"` or `"gas"` ([section 12](#12-fault-mode-and-gas-mode)) |
| `GasCall`, `GasBurn` | the gas tables (gas mode); an empty function `[x \in {} \|-> 0]` in fault mode |
| `MayFail`, `MaxFails` | the forced-fault switch ([section 13](#13-the-forced-fault-switch-and-labels)) |
| `LogOn` | keep the per-receipt outcome log `rlog` (conformance runs; FALSE otherwise) |

`NearKeys` adds `KeyAccts` (accounts whose keys are modelled). The token modules add
`TokYocto` (1 to model the 1-yocto attachments, 0 to skip them), `TokenAccts`, `TokHolders`,
`TokStorageMin`, `TokDev`, `TokCallReserve` and `WNearAccts`; `Nep245` adds `MtAccts`,
`MtHolders`, `MtIds`, `MtDev` and `MtCallReserve`.

### Overridable definitions

These are definitions with a default, not constants. Leave them alone, or override them in
`runs.toml` like a constant (the runner turns the entry into TLC's `Name <- Def`).

| definition | default | override when |
|---|---|---|
| `Contracts` | `Accounts` | some accounts have no code: a function call to an account outside `Contracts` fails |
| `CallsNeedCode` | `TRUE` | never, unless you are keeping an older model's behaviour (calls run whatever the receiver) |
| `AcctKind` | every account `"named"` | an account is NEAR-implicit, eth-implicit, deterministic or universal; toy ids cannot match the real patterns, so you state the kind. `AcctKinds(eth, nearImp)` builds the common case |
| `UniversalOn` | `TRUE` (protocol 87+) | you model the rules before protocol 87, where a universal id is named and a Transfer to an absent one fails: `FALSE`. It is independent of `NearFees.FeeProtocol`, which selects fees only ([VERSIONING](VERSIONING.md#what-feeprotocol-does-and-does-not-change)) |
| `TrackSigner` | `TRUE` | the model never reads the signer: `FALSE` saves states. Do not read the signer with `FALSE`: with `PlatformInit` (`txsig` starts empty) that is a TLC error, but with an `Init` that pre-sizes `txsig` it silently returns the initial value |
| `BurnLostRefunds` | `TRUE` | never, unless keeping older behaviour (a refund to a missing account stays in flight) |
| `DefaultKey` | `"default"` | your key ids differ and you use `Submit` |
| `PooledGasOK` | `FALSE` | a receipt with several function calls and no `pa` should pool their gas: `TRUE` (otherwise an `Assert`) |
| `TokFtGasShape` | `"standard"` per token | the token is near-contract-standards 3.x/4.x style: `"reserve"`. This can change verdicts, not only gas windows; tokens built on 3.x/4.x (many older deployments) use the reserve shape, so check your token's version |
| `TokOnTransferStatic`, `TokOnTransferWeight` | -1 per token (the shape's default) | the token gives `ft_on_transfer` a different static or weight |
| `TokResolveStatic` | 5000 Ggas per token | the token's resolver has a different static gas |
| `TokResolveMaxLen` | 42 bytes per token (`FtMaxResultLen`) | the token is near-contract-standards 5.23.0 or older (3.x/4.x) and reads the receiver's result unbounded: -1. With 42, a longer result counts as all unused ([T2](SEMANTICS.md#t2-ft_resolve_transfer)) |
| `TokBatchPerAction` | `TRUE` | token batches should be one gas pool with the whole-batch key: `FALSE` (also set `PooledGasOK <- TRUE` if the batch has several gas entries) ([section 12](#per-action-gas-pa)) |

A value for an overridable definition is a definition in your spec, named in `runs.toml`.
Pick names the library does not export (`ReserveShape`, for example, is a `Nep141` operator):

```tla
Kinds  == AcctKinds({"0xe"}, {})                       \* "0xe" is eth-implicit
Code   == {"c", "d"}                                   \* only c and d have code
Shapes == [t \in {"ft"} |-> "reserve"]
```

```toml
[constants]
AcctKind = 'Kinds'
Contracts = 'Code'
TokFtGasShape = 'Shapes'
```

## 3. Variables and Init

The platform variables are `platformVars`; the token ledger is `tk` (`mtk` for `Nep245`); the
key state is `keyVars` (`keys`, `sigpaid`). Collect them with your own:

```tla
VARIABLES n, works, ntx, gas
mine == <<n, works, ntx, gas>>
vars == <<platformVars, mine>>                  \* add tk and keyVars if you extend those modules
```

Initialise every platform variable with one helper:

| helper | use |
|---|---|
| `PlatformInit(near0, txIds)` | `near0`: `[Accounts -> Nat]`; `txIds`: the transaction ids (the domain of the `paid` ghost) |
| `PlatformInitStaked(near0, locked0, txIds)` | the same, with `locked0` already staked on `StakingAcct` |
| `PlatformInitExtra` | for a model that initialises the older platform variables itself: only `txsig`, `created`, `burnt` (= `PlatformInitSigner /\ PlatformInitAccounts`) |
| `KeysInit(keys0)` | `NearKeys`: `keys0` maps each `KeyAccts` account to its key map |
| `tk = [t \in {FT} \|-> Ledger(balances, registered)]` | tokens: balances on `TokHolders[t]` and the registered set |

TLC's "The variable txsig was not initialized" means the platform part of `Init` is missing a
helper.

Every step must say what it leaves unchanged. The library's steps (`Exec`, `Submit`,
`ExecBuiltin`, ...) set every platform variable. Your steps conjoin `UNCHANGED` for your own
variables, for `tk` if the step is not a token step, and for `keyVars` if it is not a key step.
A step that touches no platform state writes `UNCHANGED platformVars`.

## 4. Receipts

Every receipt is a record built by

```tla
Rcpt(id, tx, to, fr, m, a, dep, rto, cb)
```

| field | meaning |
|---|---|
| `id` | a fresh id: `nid`, `nid + 1`, ... (the handler reports how many it used) |
| `tx` | the transaction id; children inherit their parent's `r.tx` |
| `to`, `fr` | receiver and predecessor |
| `m` | the method name, or a built-in kind: `XFER`, `STAKE`, `ADDK`, `DELK` (`REFND` is the system's) |
| `a` | the arguments: any record, but use one shape for all receipts in a model (with the token modules, `TA0`-based: `[TA0 EXCEPT !.amt = x]` or `CxArgs(v)`) |
| `dep` | the attached deposit |
| `rto` | the refund target for a failed deposit (normally the predecessor) |
| `cb` | the id of the callback waiting on this receipt's result, or 0 |

`Rcpt` also fills the gas fields from the tables: `gs` (static gas per function call), `gw`
(weights), `gf` (the fee the child costs its creator) and `g` (attached gas, filled by the
split). It sets `res` to `NoRes` and `loc` to FALSE (`Submit` marks a local receipt).

Per-child overrides: `WithStatic(r, s)`, `WithWeight(r, w)`, `WithCall(r, s, w)` (one entry
per function-call action), `WithFee(r, f)`. A transaction's first receipt gets its prepaid gas
with `WithGas(r, p)`.

**Callbacks.** To call `D.work()` and then `C.done()`: the call's `cb` is the callback's id,
the callback goes into the postponed set, and the callback's own `cb` is the caller's `r.cb`
(so its result flows on to whoever waits on the caller):

```tla
H_ping(r) ==
    LET w  == Rcpt(nid, r.tx, D, C, "work", r.a, 0, C, nid + 1)
        cb == Rcpt(nid + 1, r.tx, C, C, "done", r.a, 0, C, r.cb)
    IN Outcome({w}, {cb}, RProm, 0, 2)
```

`RProm` returns the promise: the caller's result is the callback's. `examples/pay/Pay.tla`
does the same through a token.

## 5. Writing handlers

A handler is a TLA+ operator that returns an **outcome record**. The platform decides, from
the outcome and the gas, whether the receipt commits; your step applies your own state change
only if it did.

```tla
Outcome(ready, post, ret, out, ids)
```

| field | meaning |
|---|---|
| `ready` | new receipts that can run (calls, Transfers, key actions) |
| `post` | new postponed callbacks |
| `ret` | the return value: `RVal(v)`, `RValSz(v, n)` (a value of `n` KB), `RValLen(v, b)` (a value of `b` bytes), or `RProm` |
| `out` | the total deposit attached to new receipts (debited from the receiver) |
| `ids` | how many fresh ids the handler used |

Adjust an outcome with:

- `OErr(O, msg)`: the handler panics. The receipt fails, reverts and refunds its deposit; a
  waiting callback sees Failed. The first error wins.
- `OKey(O, k)`: the burn key for gas mode (default: the method name). Use a different key per
  path that burns differently: `OKey(O, "withdraw/refund")`.
- `OSz(O, n)`: the size (KB) the burn grows with, for a key with a per-KB slope.
- `OPanicKey(O, k)`: the burn key of a failing outcome's panic path, so a panic the gas could
  not reach is labelled out of gas ([section 12](#12-fault-mode-and-gas-mode)). Per action:
  `OPanicAt(O, i, k)`.

Return values carry a size in KB, rounded up (1 KB = 1000 bytes): `RValSz(v, n)`. The callback
that reads it sees `r.res.sz = n` and can pass it on as its burn size with `OSz`. Sizes in KB
are a model unit; the fee operators in `NearFees` take bytes ([Units](SEMANTICS.md#units)).
When a byte count matters, use `RValLen(v, b)`: it sets `r.res.len = b` and `sz` to `b` in KB,
rounded up. A reader with a byte bound (near-sdk's `promise_result_checked`) treats a longer
result as unreadable: `NumOrChecked(r.res, max, dflt)` is `NumOr` after such a read, and
`ResTooLong(r.res, max)` tests the bound. The standard FT resolver reads with a 42-byte bound,
so a receiver that pads a valid `"0"` past 42 bytes gets the whole amount refunded
([T2](SEMANTICS.md#t2-ft_resolve_transfer)).

Run the handler with `Exec(r, O)`. It computes the verdict and does the platform part:

- on success, it creates the children, credits the deposit and sends the result;
- on failure, it creates nothing, refunds the deposit and tells the callback Failed. For a
  real out-of-gas it also updates the `oog` ghost.

You conjoin your own state change, guarded by `Ok(r, O)`:

```tla
RunC(r) ==
    LET O == IF r.m = "ping" THEN H_ping(r) ELSE H_done(r) IN
    /\ Exec(r, O)
    /\ n' = IF Ok(r, O) /\ r.m = "done" THEN NewN(r) ELSE n
    /\ UNCHANGED <<works, ntx, gas>>
```

The guard must be the same verdict the platform used. With key actions bundled into the
receipt, that is `OkWithKeys`, not `Ok` ([section 10](#10-signer-and-keys)).

When a handler also computes new state, return both: `<<O, newState>>`, as `Pay.tla` does.

`Exec` fails a call without running it when the receiver is missing or has no code
(`Contracts`). After the call it checks the receiver's balance and storage floor. The verdict
order is in `Verdict`.

## 6. The dispatcher and Next

Pick a runnable receipt and route it:

```tla
Step(r) ==
    CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine        \* Transfer, refund, Stake
      [] r.to = D     -> RunD(r)
      [] OTHER        -> RunC(r)

Next == \/ Ping                                                  \* submit transactions
        \/ \E r \in Runnable : Step(r)
        \/ \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine
```

- `Runnable` is every ready receipt plus every postponed callback whose data has arrived (with
  `r.res` filled in). `Schedulable` is the same with local-receipt priority applied
  ([section 11](#11-local-receipt-priority)).
- With `NearKeys`, route `IsKeyRcpt(r)` to `ExecKeyAct(r, k, p)` ([section 10](#10-signer-and-keys)).
- With tokens, route `IsTokRcpt(r)` to the token step ([section 8](#8-calling-tokens)).
- Route refunds through `ExecBuiltin`: a refund to a missing account is burnt there.
- Transactions are submitted by your own actions, bounded by a counter. Record each
  transaction's prepaid gas in a ghost if the model runs in gas mode:

```tla
Ping ==
    /\ ntx < MaxTx
    /\ \E g \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
         /\ Submit(WithGas(Rcpt(nid, ntx + 1, C, U, "ping", [x |-> 0], 1, U, 0), g))
         /\ gas' = [gas EXCEPT ![ntx + 1] = g]
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<n, works>>
```

Useful predicates for invariants:

- `Idle`: nothing is in flight.
- `TxSettled(t)`: transaction `t` has nothing left in flight.
- `NoOrphans`: every postponed callback can still receive its data.

Check the library's two sanity invariants in every model:

- **`NearConserved(total0)`**: the total native NEAR (liquid, locked and in flight) equals
  `total0` plus rewards minus burnt refunds. `total0` is the **sum of the initial balances**
  (plus any initial `locked`). `NearConserved(0)` is right only when every account starts at
  0; `examples/revert-scope` uses `NearConserved(InitU)` because its user starts with
  `InitU`.
- **`GasBounded(prepaidOf)`**: no receipt holds more gas than its transaction's prepaid gas.
  Pass each transaction's **real** prepaid gas, from a ghost set at submission (as `gas` above,
  or `gT[t].gas` in `examples/pay`). A constant such as `LAMBDA t : 300000` checks almost
  nothing. It is trivially true in fault mode.

```tla
Counted == Idle => n = works
Sane    == NearConserved(InitU) /\ GasBounded(LAMBDA t : gas[t]) /\ NoOrphans
```

## 7. Reading promise results

A callback sees `r.res = [ok, v, sz]`:

| value | meaning | test |
|---|---|---|
| `ok = FALSE` | `PromiseResult::Failed` | `IsFailed(r.res)` |
| `v >= 0` | a well-formed JSON number | `IsNum(r.res)` |
| `v = EMPTY` | empty bytes (a Transfer, a `()` return) | `IsEmpty(r.res)` |
| `v = MAL` | bytes the reader cannot parse | `r.res.v = MAL` |
| `v = NONEMPTY` | other bytes (an object, `null`, `true`) | `r.res.v = NONEMPTY` |
| `v = NOPR` | the receipt has no promise results at all | `NoResults(r.res)` |

`NumOr(r.res, d)` is the common "parse a U128, else fall back to `d`" pattern: it returns
`r.res.v` for a number and `d` for anything else, Failed included.

Decide explicitly what your contract does for each case, as the real code does. A callback
that treats "not a number" as success, or Failed as "nothing happened", is where the bugs are.
`TokenCommon.RecvOutcome(amt, resp)` produces every shape from an arbitrary receiver, so TLC
tries them all.

## 8. Calling tokens

With `EXTENDS Tokens`, token accounts run the standard implementation inside the model. You
only create receipts to them:

```tla
ftc == Rcpt(nid, r.tx, FT, C, "ft_transfer_call", FtArgs(RX, amt, ""), TokYocto, C, nid + 1)
cb  == Rcpt(nid + 1, r.tx, C, C, "on_paid", [TA0 EXCEPT !.amt = amt], 0, C, r.cb)
```

Argument builders:

- `FtArgs(rc, amt, msg)`: `ft_transfer` and `ft_transfer_call`;
- `SdArgs(acct)`: `storage_deposit`;
- `SuArgs(force)`: `storage_unregister`;
- `NwArgs(amt)`: `near_withdraw`;
- `BatchArgs(nd, sd, sdAcct, xf, rc, amt, msg)`: one atomic `"batch"` receipt of
  `near_deposit`, `storage_deposit` and a transfer;
- `MtArgs(rc, tid, amt, msg)`: NEP-245.

Remember the 1-yocto deposits: `TokYocto` on `ft_transfer`, `ft_transfer_call`,
`near_withdraw` and `storage_unregister`.

Run token receipts with the module's step:

```tla
RunTok(r) ==
    \E ch \in TokChoices(r) :
        LET O == TokHandle(r, ch) IN TokStep(r, O) /\ UNCHANGED mine
```

`O.ev` says what the token did (amounts moved, refunded, registered, unregistered), for your
own ghost variables. Add `TokSupplyOK` and `TokTypeOK` to your invariants.

What the callback sees:

- `ft_transfer_call` returns its resolver's value, the amount the receiver kept (a number),
  or Failed if `ft_transfer_call` itself panicked;
- `ft_transfer` returns `EMPTY`;
- `storage_deposit` returns `NONEMPTY` (a JSON object).

See [Tokens](SEMANTICS.md#tokens) for each method's rules. `TokDev` selects non-standard
behaviours per token: `resolveIgnoresResult`, `resolveNoCap`, `retBytes`,
`sdRefundToAccount` and `autoRegister`.

## 9. Receiving tokens

When your contract is the receiver of `ft_transfer_call`, the token creates
`ft_on_transfer` on your account with `OnArgs(sender, receiver, amount, msg)`: read `r.a.s`,
`r.a.amt`, `r.a.msg`. Return the amount you did **not** use: `RVal(unused)`. The resolver
refunds `min(unused, amount)`, capped by your balance; a panic or an unparsable value refunds
everything.

For an account you do not control (any receiver), use the arbitrary receiver instead of a
handler: `RecvOutcome(r.a.amt, resp)` for `resp \in RecvResps`, as `RunRx` in `Pay.tla` does.

In gas mode:

- Give `ft_on_transfer` a `GasCall` entry for its exec fee (`fee`), with empty `st`/`wt`. The
  token sets its static and weight from `TokFtGasShape`. In the standard shape that is
  static 0 and weight 1, so it receives the token's leftover gas.
- Give it a burn key. `OKey(O, "rx.ft_on_transfer")` keeps one receiver's burn apart from
  another's.

## 10. Signer and keys

Three ways to submit a transaction, all on its first receipt:

| operator | signer | key |
|---|---|---|
| `Submit(r)` | `r.fr` | `DefaultKey` |
| `SubmitAs(r, a, k)` | `a` | `k` |
| `SubmitSigned(r, a, k)` (`NearKeys`) | `a` | `k`, which must be able to sign it if `a \in KeyAccts` (`KeyCanSign`) |

Every receipt of the transaction sees the signer: `Signer(r)` (`env::signer_account_id()`),
`SignerKey(r)` (`env::signer_account_pk()`), `SignerOf(tx)`. Use `r.fr` for the predecessor.
A contract that authorises on the signer instead of the predecessor is a classic bug;
`examples/signer-propagation` shows it.

`SubmitSigned` checks the key's permission. It also counts signed transactions per account in
`sigpaid`.

- A full-access key signs anything.
- A function-call key (`Perm(receiver, methods, all)`) signs only a single zero-deposit
  function call to its receiver, with a permitted method. An empty method set allows every
  method.

### Key actions as child receipts

Your contract can change its own keys with child receipts built by
`AddKeyRcpt(id, tx, acct, a, perm, cb)` and `DelKeyRcpt(id, tx, acct, a, cb)`.

- Route them in the dispatcher with `ExecKeyAct(r, k, p)`, decoding the key id `k` and the
  permission `p` from your own `r.a`.
- Key actions succeed only on the predecessor's own account.
- Adding a key that is present, or deleting one that is absent, fails the receipt.
- In gas mode, these constructors give the receipt its fee-table fee (`KeyFee`). A key-action
  receipt built with plain `Rcpt(..., ADDK, ...)` costs its creator nothing unless you add
  `WithFee`.

### Key actions bundled with a call: guard on `OkWithKeys`

A receipt such as `[DeleteKey(k), FunctionCall(m)]` is atomic in nearcore:

- if a key action fails, the call does not run and nothing commits;
- if the call fails, the key actions roll back too.

Run it with `ExecWithKeys(r, acts, O)`, with the key actions in order
(`<<DelKeyAct(k), AddKeyAct(k2, p)>>`).

**Guard your own state on `OkWithKeys(r, acts, O)`, not on `Ok(r, O)`.** `Ok` sees only the
call's outcome. If a key action fails, `Ok` can still be TRUE: your state would change while
the platform rolled the receipt back, and the model would no longer be atomic. From
`examples/deletekey-atomicity/Revoker.tla`:

```tla
RunA(r) ==
    ...
    ELSE LET O == Outcome({}, {}, RVal(0), 0, 0) IN
         /\ ExecWithKeys(r, Acts(r), O)
         /\ revoked' = IF OkWithKeys(r, Acts(r), O) THEN revoked + 1 ELSE revoked
         /\ UNCHANGED ntx
```

A model that signs such a receipt must also require a full-access key itself (`IsFull`),
because `KeyCanSign` cannot see bundled key actions.

## 11. Local-receipt priority

A transaction whose signer is its receiver produces a **local** receipt, which nearcore runs
in the same chunk before delayed and incoming receipts. Only a transaction's first receipt is
local; everything it creates goes out normally.

The model does not apply this rule unless you ask. By default every causally enabled order is
explored. To apply it, conjoin `LocalPriorityOK(r)` to the receipt step (or draw receipts from
`Schedulable`). A constant makes both settings easy to run:

```tla
CONSTANT LocalOn
Run == \E r \in Runnable : (LocalOn => LocalPriorityOK(r)) /\ Step(r)
```

`LocalPriorityOK(r)` forbids running a non-local receipt on an account while a local receipt
on that account is pending.

- **With the rule**, the model assumes the receiving chunk has room. When the chunk is at its
  compute or storage-proof limit, nearcore puts the local receipt at the back of the delayed
  queue, and every receipt already delayed runs first: exactly the order the rule forbids. So
  with the rule the model is an **under-approximation** under congestion and can hide a bug.
- **Without the rule**, the model explores every causally enabled order, including those a full
  chunk makes reachable. It can show orders an idle shard would not produce.

If you conjoin the rule, run your safety properties without it as well. If a violation
appears only without the rule, it is reachable whenever the receiving shard is congested.
That is a matter of load, which any user (or an attacker willing to pay for gas) can create.
Dismiss it only with a concrete argument that the receiving chunk cannot be full at that
moment. `examples/local-priority` is a pair of runs that differ only in this switch.

## 12. Fault mode and gas mode

`GasMode` picks how receipts fail for lack of gas.

**Fault mode (`"fault"`).** Gas is abstract. A receipt fails only if:

- your handler panics;
- an action fails (missing account, balance, storage, key);
- or the forced-fault switch fires.

Use it first: it is fast, it needs no gas tables, and it answers "what if this call fails?"
for every call you list in `MayFail`.

**Gas mode (`"gas"`).** Gas is a bounded quantity in Ggas (1 Tgas = 1000). Use it when the
question is *at which prepaid gas* something breaks, or whether an attacker who picks the gas
can make a callback run out while its call succeeded. In gas mode:

- a transaction's first receipt carries its prepaid gas (`WithGas(r, p)`, with `p` drawn
  from a menu). Let the menu reach the protocol maximum, 1000 Tgas (`1000000` Ggas), as well
  as the region around each edge: a failure can exist only at high gas;
- a receipt needs `Burn + Σ over its children (fee + static)`. `Burn` comes from
  `GasBurn[key] = [base, per]` (`base + per * size`); each child's static, weight and exec fee
  come from `GasCall[key] = [st, wt, fee]`, looked up as `"acct.method"`, then `"method"`;
- if the need exceeds the attached gas, the receipt runs out of gas and fails like any
  failure. A panic whose outcome names its panic-path burn key (`OPanicKey(O, k)`) is
  labelled out of gas when that burn plus the children created before the panic exceeds the
  attached gas; without a panic key a panic is always a plain failure;
- otherwise the leftover is split over the children's function-call actions by weight; the
  last weighted action also gets the remainder;
- a child function call left with 0 gas fails its creator; one with no static gas at all
  (no `GasCall` entry, no `WithCall`) is a TLC assertion;
- action-only children cost their creator the fee table's send + exec fee by default
  (`XFER`: `TransferFeeTotal` by the receiver's account kind; `STAKE`: `OneActionReceiptFee`).
  Key-action receipts get `KeyFee` only through `AddKeyRcpt` / `DelKeyRcpt`. A `GasCall`
  entry wins: `"XFER" :> NoGas` makes Transfers free.

Every key you burn must be in `GasBurn`: a missing key is a TLC assertion naming it.

### Per-action gas (`pa`)

nearcore gives each function-call action of a receipt its own gas, and splits only that
action's leftover over the children *it* created. By default the model treats a receipt as one
action. For a receipt with several function calls (a batch), add a `pa` field to the outcome,
one record per action:

```tla
WithPA(O, pa) == ("pa" :> pa) @@ O
O2 == WithPA(O, << [gk |-> "c.first",  sz |-> 0, kids |-> {nid}],
                   [gk |-> "c.second", sz |-> 0, kids |-> {nid + 1}] >>)
```

Apply `WithPA` after `OErr`, `OKey` and `OSz`. Rules:

- Each action is checked against its own gas `r.g[k]` with its own burn key, and its children
  share only its leftover.
- The creator must give such a receipt one static/weight entry per action
  (`WithCall(r, <<s1, s2>>, <<w1, w2>>)`).
- `pa` must have exactly that many records, with disjoint `kids`. Both are assertions.
- A receipt with several gas entries and no `pa` is an assertion unless
  `PooledGasOK <- TRUE`.
- For a panic in action `i`, `OPanicAt(O, i, k)` names the panic-path burn key.

The token modules emit `pa` for batches by default (`TokBatchPerAction`, default `TRUE`).
Their burn keys are:

- a multi-call batch: `"<acct>.batch/<shape>#<method>"`, one per call;
- a single-call batch: `"<acct>.batch/<shape>"`.

## 13. The forced-fault switch and labels

`ForcedFail(r)` fails a receipt whose method is in `MayFail`, at most `MaxFails` times per
behaviour, with the same revert scope as a real failure. Add it as its own disjunct of `Next`
(see [section 6](#6-the-dispatcher-and-next)). It works in both modes, so you can layer "this
callee may also fail" on a gas-mode run.

Every counterexample carries a label (`Label`):

- `"forced"`: the switch fired. Ask whether the network can cause that failure (a callee that
  panics or does not exist, an untrusted receiver).
- `"caller-gas"`: a real out-of-gas in gas mode. The `oog` ghost lists `<<tx, method>>` of what
  ran out. Reachable by choosing the prepaid gas.
- `"no-fault"`: neither. The bug needs no failure at all, only an order.

Put the label in your printed output when you triage. `LogOn = TRUE` keeps a per-receipt log
in `rlog` (`[tx, id, m, to, st, g]`), which is what conformance runs compare.

## Calibrating

A gas-mode verdict is only as good as its `GasBurn` and `GasCall` tables. Illustrative numbers
are fine for learning the model, and the examples say so in comments. For a real question,
measure.

**This needs the sim.** The `calibrate` tool runs your wasm in near-contract-sim, a private
repository; see [Access to the sim](CONFORMANCE.md#access-to-the-sim). Without access, keep
gas windows illustrative and base conclusions on fault mode and hand-checked tables (see
[The method](#the-method)).

### Your own contract

The `calibrate` tool in `conformance/` runs your compiled contract over a grid of prepaid gas
and writes a TLA+ table.

1. **Copy the template into `conformance/flows/`**:
   `cp conformance/flows/example.toml conformance/flows/my.toml`. Contract wasm paths in a
   spec are relative to the spec file, and the template's other contracts point at
   `../probes/res/`, so the copy must sit beside the original.
2. **Describe the world.** List the accounts and other contracts, and add `[[setup]]` calls
   that give your contract **realistic state**: registered users, non-empty maps, balances
   like production. Burns grow with storage reads and writes, so a burn measured on an empty
   contract is too low.
3. **Declare the gas.** Give the static gas and weight of every call your contract makes
   (`[[static]]`), and what each burn grows with (`[[size]]`).
4. **Write the flows.** One `[[flow]]` per path you want a burn key for.
5. **Run it** from `conformance/`. `--wasm` is relative to `conformance/`, and so is `--tla`:

   ```sh
   cd conformance
   cargo run --release --bin calibrate -- --flows flows/my.toml \
       --wasm path/to/contract.wasm \
       --tla MyCalib.tla --prefix My --params app
   mv MyCalib.tla path/to/your/model/      # beside your spec, where the runner finds it
   ```

The tool writes the table only if every check passed:

- nearcore's leftover split reproduces from your declared statics and weights at every point;
- every child has a declared static;
- every action-only fee is priced.

The table's header records the wasm sha256, the crate version, the sim and nearcore revisions
and the protocol version. The details, including every option and the flow-spec format, are in
[Calibrating your own contract](../conformance/README.md#calibrating-your-own-contract).

Use the result as an instance:

```tla
Mine == INSTANCE MyCalib
PGasBurn == Mine!MyGasBurn(C) @@ Std!StdFtGasBurn(FT)
PGasCall == Mine!MyGasCall(C) @@ Std!StdFtGasCall(FT)
```

### The standard tokens: `CalibStd`

`CalibStd` ships measured tables for a plain near-contract-standards 5.29.1 FT
(`StdFtGasBurn(ft)`, `StdFtGasCall(ft)`) and a wNEAR-like token (`StdWNearGasBurn`,
`StdWNearGasCall`). The parameter is the token's model account. `examples/pay`'s `pay_gas_std`
run uses them. Caveats:

- They were measured on the repo's probe builds of those contracts, in the sim's world, at the
  pinned nearcore and protocol 88. A deployed token's build, version and state differ.
- Where a burn depends on the path, the modules look up a path key first and fall back to
  the method key: `storage_deposit/registered|new`, `near_deposit/registered|new`,
  `ft_resolve_transfer/refund|norefund` (e.g. `"ft.storage_deposit/new"`). A method key
  alone holds the largest burn seen, which over-charges the cheaper paths, so an out-of-gas
  the model reports near an edge may not happen on the cheaper path.
- Batches are per action by default. A multi-call batch reads the per-call keys
  `"<acct>.batch/<shape>#<method>"`: each is that call's burn at its position in the batch,
  which differs from the standalone method's burn. A single-call batch reads
  `"<acct>.batch/<shape>"`. The whole-batch keys of multi-call shapes are only for
  `TokBatchPerAction <- FALSE`.
- `ft_on_transfer`'s exec fee belongs to the **receiver's** `GasCall` entry, not the token's.
- Your contract's own entries are still yours to measure.

### Recalibrating for a real deployment

Burns depend on the contract's code, its state and the protocol. Before you rely on a window
for a deployed contract, recalibrate against **the exact wasm that is deployed**, with state
shaped like production (registered accounts, map sizes), and check its hash against the
table's header. Recalibrate again after any contract upgrade, any change of
near-contract-standards version, and any protocol bump ([`VERSIONING.md`](VERSIONING.md)).
Even then, treat edges as accurate only to the rounding bound in
[N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs).

## Replaying a counterexample in the sim

A TLC counterexample is a hypothesis about your contract. Confirm it on real wasm in
near-contract-sim before you report it. **This needs sim access**
([Access to the sim](CONFORMANCE.md#access-to-the-sim)). Without it, walk the trace against
the contract's source by hand, receipt by receipt, and say in your write-up that it was not
replayed.

The sim's own docs describe its API; the steps below use its names.

1. **Read the trace.** `python3 tools/run.py <path> <run> --print-trace` prints a summary of
   the violating behaviour. `python3 tools/tlctrace.py <log>` does the same for a log kept with
   `--keep` (in `build/` beside the `runs.toml`). Each step names its action and the
   variables it changed.
2. **List the transactions.** Every `Submit` / `SubmitAs` / `SubmitSigned` step is one sim
   transaction: `sim.call(signer, receiver, method)` with the same arguments and deposit. If the
   model pinned prepaid gas (`WithGas(r, p)`, `p` in Ggas), pin the same amount with `.gas(..)`:
   `p` Ggas is `p × 10^9` gas, or `Gas::from_teragas(p / 1000)` when `p` is whole Tgas.
3. **Map receipts to sim receipts.** Each model receipt is a sim receipt with the same
   receiver and method. Callbacks are the receipts that wait on a result
   (`Receipts::callback(m)`). Repeated calls are told apart with
   `Receipts::occurrence(receiver, m, k)` or `.nth(k)`.
4. **Reproduce the failures.**
   - A `"forced"` failure of method `m` on `receiver`: `tx.inject(Receipts::call(receiver, m),
     Fault::OutOfGas)`. If the model failed the call a callback waits on, `Fault::PromiseFailed`
     on the callback (`Receipts::callback(cb)`) gives the callback a Failed result.
   - A `"caller-gas"` failure: reproduce it with the transaction's gas (`Tx::gas`), not with a
     fault. To pin one child's gas, use `Fault::Gas(g)`. `Tx::least_gas` finds the least gas
     at which the transaction still succeeds, a quick check of a predicted edge.
   - A receiver's answer the model chose (`MAL`, `NONEMPTY`, a number): deploy a stub
     receiver (`sim.deploy_stub`), or put `Fault::ReturnValue(bytes)` on the callback.
5. **Reproduce the order.** The model interleaves receipts freely. Where the trace runs one
   transaction's receipt before another's, delay the other with `Fault::Hold(n)` (a receipt
   leaves `n` blocks late) or `Fault::HoldResult(n)` (its result reaches the callback late).
   `submit()` the first transaction, `run_until` the hold is in place, then submit the second.
6. **Check the same property.** Assert on the outcome (statuses, `value()`, balances and token
   moves via `effects()`), and read `sim.findings()`. If the model's invariant breaks in the
   sim too, it is real.

If it does not reproduce, find out why before discarding it:

- the order needs timing a network does not produce (see the over-approximations in
  [Not modelled](SEMANTICS.md#over-approximations));
- the gas tables are wrong for this path ([Calibrating](#calibrating));
- your handler does not match the contract (re-read the source);
- or the library is wrong: open an issue with the trace and the sim test.

## The runner: `runs.toml`

Each model directory has a `runs.toml` listing TLC runs and the verdict each must give.
`python3 tools/run.py --help` is the reference; [A complete minimal model](#a-complete-minimal-model)
shows a full file.

**Values.** Each entry under `[constants]` or `[run.constants]` is TLA+ expression text. Write
it in TOML single quotes (`'[a \in Accts |-> 0]'`, `'"c"'`). Single-quoted TOML strings are
literal, so backslashes and double quotes need no escaping. In double quotes, every `\` must be
written `\\`. TOML integers and booleans are also accepted. Constants and overridable
definitions are set the same way.

**Keys.**

- `expect` is `"pass"`, `"violation"` (with `invariant` naming the one that must break),
  `"assert"` or `"deadlock"`.
- Most keys can also be given at the top level of the file, as a default for every run:
  `spec`, `workers`, `library`, `budget_s`, `init`, `next`, `specification`, `invariants`,
  `properties`, `deadlock`, `tags`, `[constants]`.
- These keys belong to one run only and cannot be given at the top level: `name`, `expect`,
  `invariant`, `expect_output`, `expect_window`, `window_step` and `allow_no_invariants`.
- `expect_output` (a regex on TLC's output) pins a detail, such as the gas value in the
  violating state.
- `deadlock = true` makes a stuck receipt an error. Add a terminal stutter step once the model
  is idle, or quiescence is reported too.

**Selecting runs.** Arguments are `runs.toml` files, directories (searched recursively), and
run names (globs work). Names filter the runs of the given paths. With names only, they are
looked up under this repo's `examples/`.

```sh
python3 tools/run.py examples/minimal                    # every run of one model
python3 tools/run.py path/to/model/ my_run --print-trace # one run of your own model
python3 tools/run.py 'pay_*'                             # runs by name, under examples/
python3 tools/run.py --list path/to/model/               # list without running
```

**Output.** The runner generates each run's wrapper and cfg in a fresh temporary directory
and runs TLC there. It keeps the wrapper, cfg and log in `build/` beside the `runs.toml` only
for runs whose verdict did not match, or for every run with `--keep`. `--peel` reruns a
violating run without the violated invariant until it is clean, and reports every invariant
that broke.

## Every invariant must be able to fail

An invariant that holds in every run might be true, or it might be vacuous: guarded by a
condition that is never reached, or checking a ghost that never changes. For every invariant:

1. Add a must-fail run that breaks it on purpose, for a reason you can state. Options: a
   constant that switches on a wrong variant of the handler (`Trusting = 'TRUE'` in the
   minimal model), a token deviation (`TokDev`), a forced fault, or a gas menu that reaches
   the edge.
2. Check the verdict names that invariant (`expect = "violation"`, `invariant = "..."`).
3. Read the trace (`--print-trace`) and confirm it fails **for the reason in the run's
   comment**, not for an unrelated one.
4. Keep the pair in `runs.toml`, with a comment on the must-fail run saying why it fails.
   Then a later change that makes the invariant vacuous turns a must-fail run into a pass,
   and the runner reports it.

A `pass` run must check at least one invariant or property; `allow_no_invariants = "why"` is
the explicit exception.

## Print-only window invariants

A normal invariant stops TLC at the first bad state. To map *every* prepaid amount at which
something breaks, use a print-only invariant: it is always true, and prints each bad state.

```tla
WinCounted == (Idle /\ n # works) => PrintT(<<"WIN", "Counted", gas[ntx], oog>>)
```

The tuple is:

- the literal `"WIN"`;
- a label, usually the real invariant's name;
- the transaction's prepaid gas in Ggas;
- then anything you want for debugging.

Run it as a `pass` run with `expect_window`, the expected Ggas intervals:

```toml
[[run]]
name = "tally_gas_win"
expect = "pass"
invariants = ["WinCounted", "Sane"]
expect_window = "8600-9000"
[run.constants]
GasMode = '"gas"'
GasCall = 'TGasCall'
GasBurn = 'TGasBurn'
GasMenu = 'Menu'                # 8.0-9.5 Tgas by 0.1, and 1000 Tgas
MaxTx = '1'
Trusting = 'TRUE'
```

The runner folds the printed values into intervals and checks them. Values at most
`window_step` apart (100 Ggas by default) join one interval, so the step must be at least
the menu's step. `python3 tools/windows.py --step 100 <log>` does the same for any TLC log
and prints the intervals in Tgas.

`expect_window` takes two forms:

- **A string** checks the union of all labels.
- **A table** (`expect_window = { Counted = "8600-9000" }`) checks each label separately, and
  fails if a label it does not list prints anything.

Windows inherit the precision of the tables: only trust a window that is wider than the
rounding bound summed over its path, and only on calibrated tables.

## Worked material

All examples are toy contracts written for this repo.

- **`examples/minimal`**: the complete minimal model above. Copy it to start.
- **`examples/pay`**: a contract that pays out of an internal balance through
  `ft_transfer_call` and reconciles in its callback.
  - fault-mode runs over every receiver behaviour and two token deviations;
  - gas-mode runs: the out-of-gas edge, a print-only window, and the same window on the
    measured `CalibStd` table.
- **`examples/platform-selftest`**: deterministic scenarios with known nearcore outcomes. They
  cover receipts, results, accounts, refunds, staking, storage, keys, gas and tokens. It checks
  the library, and it is a catalogue of how to drive each operator.
- **The semantic examples**, each a must-pass and a must-fail pair for one rule:

  | example | rule |
  |---|---|
  | `callback-after-failure` | callbacks always run and see Failed; a failing callback reverts only itself |
  | `revert-scope` | a failed receipt reverts only itself, not the transaction |
  | `signer-propagation` | the signer is inherited by children and callbacks |
  | `deletekey-atomicity` | `[DeleteKey, FunctionCall]` in one receipt is atomic |
  | `local-priority` | local-receipt priority on versus off |
  | `weight-split` | the split of unused gas by weight |
  | `eth-implicit-fee` | the Transfer fee to an eth-implicit receiver |
  | `nep141-refund-cap` | the NEP-141 resolver caps the refund at the amount |
  | `nep145-refund-to-predecessor` | `storage_deposit` refunds the excess to the predecessor |
  | `mt-smoke` | NEP-245 transfer and resolve |
