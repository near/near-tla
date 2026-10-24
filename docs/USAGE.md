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
- [14. Joint callbacks, yield/resume and the block clock](#14-joint-callbacks-yieldresume-and-the-block-clock)
- [15. Storage staking per byte](#15-storage-staking-per-byte)
- [16. Creating and deleting accounts](#16-creating-and-deleting-accounts)
- [Calibrating](#calibrating)
- [Replaying a counterexample in the sim](#replaying-a-counterexample-in-the-sim)
- [The runner: `runs.toml`](#the-runner-runstoml)
- [Every invariant must be able to fail](#every-invariant-must-be-able-to-fail)
- [Witnesses and mutants](#witnesses-and-mutants)
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
4. **Replay every counterexample on real wasm.** The model over-approximates some ordering
   (it has no chunks or shards) and abstracts your contract. Do not dismiss a counterexample
   only because two receipts from one account to another run in the opposite order to their
   creation: nearcore can do that ([S4](SEMANTICS.md#s4-no-per-pair-order)). A trace is a hypothesis until the same receipt tree, with the same
   gas and faults, reproduces in near-contract-sim against the compiled contract.
5. **Make every invariant able to fail.** For each invariant, add a deliberately wrong
   variant that TLC must report, and confirm from the trace that it fails for the reason you
   intended. An invariant that has never failed may be vacuous. Then show that each
   invariant's situation is reached and that small bugs are caught
   ([Witnesses and mutants](#witnesses-and-mutants)).
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
WorkFits == (Idle /\ \A t \in 1..ntx : gas[t] = 1000000) => works = ntx
Sane == NearConserved(InitU) /\ GasBounded(LAMBDA t : gas[t]) /\ NoOrphans
WinCounted == (Idle /\ n # works) => PrintT(<<"WIN", "Counted", gas[ntx], oog>>)
=============================================================================
```

Its `runs.toml` sets every constant once and has five runs:

- `tally_ok`: fault mode, `work` may fail once; must pass.
- `tally_trusting`: the same with `Trusting = TRUE`; must fail `Counted`.
- `tally_gas_ok`: gas mode over the menu; must pass, with `WorkFits` too: at the 1000 Tgas
  maximum every `work` commits.
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

# Counted's antecedent is reached: the system settles again after a ping.
[[witness]]
id = "ping_settles"
expr = '~(Idle /\ ntx > 0)'
runs = ["tally_ok", "tally_gas_ok"]

# A dropped .then must be caught (here by NoOrphans, in Sane).
[[mutant]]
id = "dropped_then"
file = "Tally.tla"
find = 'IN Outcome({w}, {cb}, RProm, 0, 2)'
replace = 'IN Outcome({w}, {}, RProm, 0, 2)'
class = "dropped .then"
runs = ["tally_ok"]
```

The file also lists witnesses for both arms of `done` and mutants for the other bug classes
([Witnesses and mutants](#witnesses-and-mutants)).

Run it:

```sh
python3 tools/run.py examples/minimal                                  # every run
python3 tools/run.py examples/minimal tally_gas_trusting --print-trace # one run, with its trace
python3 tools/run.py examples/minimal --anti-vacuity                   # and its witnesses and mutants
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
| `StorageFloor` | `[Accounts -> Nat]`: what liquid + locked must cover after a function call (`LackBalanceForState`); 0 for an account under the zero-balance storage limit. Not checked with `StoragePerByte` ([section 15](#15-storage-staking-per-byte)) |
| `StakingAcct`, `MinStake`, `MaxEpoch`, `MaxReward` | the one staking account, its minimum stake, and the bounds on epoch ticks and rewards (`MaxEpoch = 0`: no epoch ticks) |
| `GasMode` | `"fault"` or `"gas"` ([section 12](#12-fault-mode-and-gas-mode)) |
| `GasCall`, `GasBurn` | the gas tables (gas mode); an empty function `[x \in {} \|-> 0]` in fault mode |
| `MayFail`, `MaxFails` | the forced-fault switch ([section 13](#13-the-forced-fault-switch-and-labels)) |
| `LogOn` | keep the per-receipt outcome log `rlog` (conformance runs; FALSE otherwise) |

`NearKeys` adds `KeyAccts` (accounts whose keys are modelled). The token modules add
`TokYocto` (1 to model the 1-yocto attachments, 0 to skip them), `TokenAccts`, `TokHolders`,
`TokStorageMin`, `TokDev`, `TokCallReserve` and `WNearAccts`; `Nep245` adds `MtAccts`,
`MtHolders`, `MtIds`, `MtDev` and `MtCallReserve` (and the overridable `MtGasShape`, see
[section 9](#9-receiving-tokens)).

### Overridable definitions

These are definitions with a default, not constants. Leave them alone, or override them in
`runs.toml` like a constant (the runner turns the entry into TLC's `Name <- Def`).

| definition | default | override when |
|---|---|---|
| `Contracts` | `Accounts` | some accounts have no code: a function call to an account outside `Contracts` fails |
| `CallsNeedCode` | `TRUE` | never, unless you are keeping an older model's behaviour (calls run whatever code the receiver has; a missing receiver still fails them) |
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
| `MaxBlk` | `0` (no clock) | the model uses the block clock: the bound on `blk` ([section 14](#14-joint-callbacks-yieldresume-and-the-block-clock)) |
| `YieldTicks` | `0` | the model uses the clock: a yield's timeout in ticks (nearcore: 200 blocks) |
| `TickAnytime` | `TRUE` | no handler reads `blk` or `BlockTs`: `FALSE` lets blocks pass only while a yield's deadline is ahead, which saves states |
| `StoragePerByte` | `FALSE` | the model tracks storage in bytes: `TRUE` replaces the fixed `StorageFloor` with `stor` priced per byte ([section 15](#15-storage-staking-per-byte)) |
| `StorageInit` | 0 bytes for every account | with `StoragePerByte`: each account's storage usage at the start (record, keys, code, data). An entry of at most 770 bytes is exempt |
| `StorBytes` | empty | handlers read measured bytes with `OStorKey(O, key, size)`: the calibrator's table, `[key -> [base, per]]` keyed like `GasBurn` (a missing key is an `Assert`; unread without `StoragePerByte`) ([section 15](#bytes-from-the-calibrator)) |
| `InstantFirst` | `TRUE` | never, unless you want the over-approximation without instant receipts ([S5](SEMANTICS.md#s5-instant-receipts)): `FALSE` lets other receipts, transactions and blocks run between a receipt and the lone DeleteAccount it creates |
| `AcctParent` | every account top-level | the model creates sub-accounts: each account's direct parent, `Parents({<<"s.c", "c">>})` ([section 16](#16-creating-and-deleting-accounts)) |
| `TopCreator` | `"top-creator"` (no model account) | the model creates top-level accounts: the account standing for the protocol's `registrar_account_id` |
| `CodeSize` | 0 bytes for every account | with `StoragePerByte` and DeleteAccount: the code bytes in each contract's `StorageInit`, which the 10,000-byte delete limit leaves out |
| `CodeLen` | 0 bytes for every code tag | with `StoragePerByte` and DeployContract: the bytes of each code tag a model deploys, `("child" :> 300000)` ([section 16](#16-creating-and-deleting-accounts)) |
| `EthWalletCode` | `"eth_wallet"` | a model reads `CodeOf`: the tag of the eth wallet contract an eth-implicit account gets when a Transfer creates it (again) |
| `InitCode` | `"code"` for every account | a model reads `CodeOf` and its contracts start with different code: each account's tag at the start (only the accounts in `Contracts` have code) |
| `InitGCode` | nothing published | global contracts published at the start: a function from identifiers (`GHash(t)`, `GAcct(a)`) to code tags, `(GHash("child") :> "child")` ([section 16](#global-contracts)) |
| `InitUses` | no account uses one | accounts that run a global contract at the start: account to identifier; it wins over `InitCode`. With `StoragePerByte`, count the identifier's bytes (`IdLen`) in `StorageInit` |
| `GlobalByteCost` | `<<1, 10000>>` (0.0001 NEAR per byte) | your NEAR unit is not 1 NEAR, as for `StorageByteCost`: the burn of a DeployGlobalContract per code byte, `num/den` units; the burn of a deploy must be a whole number of units (an `Assert`) |
| `GlobalInstant` | `FALSE` | state counts only: `TRUE` publishes a global deploy at its commit, without the distribution receipt. Unsound: it hides the window in which a use fails or users still run the old code ([N-global-instant](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)) |
| `StorageByteCost` | `<<1, 100000>>` (1 unit = 1 NEAR) | your NEAR unit is not 1 NEAR: one byte costs `num/den` units, `<<1, 100>>` for 1 unit = 1 milliNEAR |
| `IdBytes(s)`, `KeyBytes(p)` | 10; the borsh formula | `NearKeys`, with `StoragePerByte`: the real length of the receiver id a model id stands for (method names count as written, or as `WithMethodBytes` states); another key type (a key with an allowance, `WithAllowance`, already counts its 16 bytes) |
| `TokRegBytes` | 0 per token and holder | with `StoragePerByte`: `TokRegBytes[t][h]`, the bytes holder `h`'s registration adds to token `t`, for every `h` in `TokHolders[t]` (near-contract-standards: `StdRegBytes(len(id))` = 61 + the real id's length, measured; `TokStorageMin` stays the price of the longest id, `StdRegBytes(64)` = 125 bytes) |
| `TokBatchPerAction` | `TRUE` | token batches should be one gas pool with the whole-batch key: `FALSE` (also set `PooledGasOK <- TRUE` if the batch has several gas entries) ([section 12](#per-action-gas-pa)) |
| `NearFees!FeeRounding` | `"up"` | you want the fee table's earlier rounding to the nearest Ggas, closer to nearcore's figures but able to understate a fee by a few Ggas: `"nearest"`. A definition inside the `NearFeeTable` instance, so the key is module-qualified: `"NearFees!FeeRounding" = '"nearest"'`, which the runner turns into a generated definition and TLC's `FeeRounding <- [NearFees] <that definition>`. In a hand-written cfg, define the value in your spec (`FeeNearest == "nearest"`) and write `FeeRounding <- [NearFees] FeeNearest`: TLC rejects a string literal on the right of `<-` as an undefined identifier. `"up"` also keeps the unused-gas split from handing out its whole-Ggas remainder ([N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs), [G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)). A module-qualified key overrides definitions only; the runner rejects one that names a `CONSTANT` |

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
| `PlatformInitExtra` | for a model that initialises the older platform variables itself: only `txsig`, `created`, `burnt`, `deleted`, `code`, `gcode`, `guse`, `gnonce`, `blk`, `stor` (= `PlatformInitSigner /\ PlatformInitAccounts /\ PlatformInitClock /\ PlatformInitStorage`) |
| `KeysInit(keys0)` | `NearKeys`: `keys0` maps each `KeyAccts` account to its key map |
| `tk = [t \in {FT} \|-> Ledger(balances, registered)]` | tokens: balances on `TokHolders[t]` and the registered set |

TLC's "current state is not a legal state" while working on the initial state, with a platform
variable such as `txsig` or `blk` shown as `null`, means the platform part of `Init` is
missing a helper.

Every step must say what it leaves unchanged. The library's steps (`Exec`, `Submit`,
`ExecBuiltin`, ...) set every platform variable. Your steps conjoin `UNCHANGED` for your own
variables, for `tk` if the step is not a token step, and for `keyVars` if it is not a key step.
A step that touches no platform state writes `UNCHANGED platformVars`.

Build `vars` (the tuple in `Spec == Init /\ [][Next]_vars`) from `platformVars` as above, not
from a hand-written list of platform variables. A variable missing from `vars` is unconstrained
by the stuttering steps of `[][Next]_vars`, and TLC only warns. When the library adds a
platform variable (`blk` and `stor` in 0.2, `deleted`, `code`, `gcode`, `guse` and `gnonce`
later), a hand-written list goes stale silently.

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
| `dep` | the attached deposit (of the call; a factory batch's Transfer is in `ac.xfer`, section 16) |
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

Conjoin the guard **after** `Exec`, in the same action. In gas mode under the default
`FeeRounding = "up"` the verdict can be `"either"`: a child's gas may be 0 in nearcore or not,
so `Exec` has two successors, one where the receipt commits and one where it fails
([G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)). `Ok` then tells which one
the step took by reading the primed platform state (did the receipt's children appear in
`rq'` or `post'`?). Placed before `Exec`, it stops TLC with an error in that case.

When a handler also computes new state, return both: `<<O, newState>>`, as `Pay.tla` does.

`Exec` fails a call without running it when the receiver is missing or has no code
(`Contracts`). After the call it checks the receiver's balance and storage floor. The verdict
order is in `Verdict`.

`Exec` also fails a call that breaks a protocol limit ([R6](SEMANTICS.md#r6-protocol-limits)):
more than 1024 promises from one function-call action (its receipts and its `promise_and`
calls), a joint callback on more than 128 results, a returned value over 4 MiB (state its bytes with `RValLen` near
the limit; 4195 KB is an `Assert`), or a child receipt of more than 100 actions. A handler
that splits a large batch keeps each receipt at 100 actions or fewer; `examples/limits` shows
each limit at its boundary. Deploys (one per receipt) and AddKey method names (2000 bytes)
are `Assert`s.

The model sees receipts, not `promise_and` calls. It counts one per joint callback, which is
right when each `promise_and` feeds one `.then` directly. A nested one,
`promise_and(promise_and(a, b), c)`, is two promises; state the count with
`OJoins(O, n)`, at least one per joint callback the call creates (fewer is an `Assert`). Near the limit an unstated count that nesting could take past 1024 is an
`Assert`. The limit is per function call: in a receipt of several calls give the outcome
`pa` ([section 12](#per-action-gas-pa)), in fault mode too, with `nj` in each record for
its `promise_and` calls. Without `pa`, a receipt whose children could pass 1024 in all is an
`Assert`.

Logs count only if the handler declares them: `OLog(O, b)` adds one log of `b` bytes (UTF-8)
to the outcome (`OLogs(O, b, n)` adds `n` of them), and more than 100 logs or 16384 bytes of them fail the call, as in nearcore.
Declare them when a handler's logs grow with its input (an event per item, say); a model
that declares none never hits the limit.

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

A joint callback (`promise_and`) has several results: read them with `NRes(r)` and
`ResAt(r, i)`, not `r.res` ([section 14](#14-joint-callbacks-yieldresume-and-the-block-clock)).
`ResAt` also works on an ordinary callback (`ResAt(r, 1) = r.res`).

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
- `MtArgs(rc, tid, amt, msg)`: NEP-245 `mt_transfer` and `mt_transfer_call`;
- `MtBatchArgs(rc, tids, amts, msg)`: NEP-245 `mt_batch_transfer` and
  `mt_batch_transfer_call`, with `tids` and `amts` sequences of one length (a different
  length panics, as the token does).

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

**NEP-245.** A multi token (`Nep245`) creates `mt_on_transfer` with the vectors `r.a.tids`
and `r.a.amts` (a single-id call has vectors of one, and also sets `r.a.tid` and `r.a.amt`).
The receiver returns a `Vec<U128>`, one unused amount per id: return `MtRet(<<u1, u2>>)`.
The resolver refunds, per id, `min(unused_i, amount_i)` capped by your balance of that id; a
panic, a malformed result or a vector of another length refunds everything. It returns the
used amounts as a vector; `MtVecOf(r.res)` decodes it (`.ok`, `.v`), since a vector travels
as one integer (`["v"]` is the number `v`). The arbitrary receiver is
`MtRecvOutcome(r.a.amts, resp)` for `resp \in MtRecvResps`, or `MtRecvVecOutcome(vec)` for
any vector, for instance every `vec \in MtAnswers(Len(r.a.amts), 0..3)` (lengths n - 1 to
n + 1, so wrong lengths and over-amount answers too), as `RunRx` in
`examples/mt-batch/MtBatch.tla` does. Write it as a disjunction of `Exec` steps, not as
`\E O \in {...}`: TLC cannot put outcomes with different fields in one set.

In gas mode, `MtGasShape[t]` selects the token's gas: `"reserve"` (the default; static
prepaid − `MtCallReserve[t]`, weight 0) or `"tools"` (near-sdk-contract-tools 4.0.0: a
30 Tgas floor, `mt_on_transfer` static 0 and weight 10, the resolver 5 Tgas and weight 1).
Override it like `TokFtGasShape`, e.g. `MtGasShape = '[t \in {"mt"} |-> "tools"]'` in
`runs.toml`. The batch methods and the resolver burn with size = the number of ids.

In gas mode:

- Give `ft_on_transfer` a `GasCall` entry for its exec fee (`fee`), with empty `st`/`wt`. The
  token sets its static and weight from `TokFtGasShape`. In the standard shape that is
  static 0 and weight 1, so it receives the token's leftover gas.
- Give it a burn key. `OKey(O, "rx.ft_on_transfer")` keeps one receiver's burn apart from
  another's.

## 10. Signer and keys

Four ways to submit a transaction, all on its first receipt:

| operator | signer | key |
|---|---|---|
| `Submit(r)` | `r.fr` | `DefaultKey` |
| `SubmitAs(r, a, k)` | `a` | `k` |
| `SubmitSigned(r, a, k)` (`NearKeys`) | `a` | `k`, which must be able to sign it if `a \in KeyAccts` (`KeyCanSign`, and its allowance) |
| `SubmitTx(st)` (`NearKeys`) | `st.sgn` | `st.k`, as for `SubmitSigned`, and the nonce `st.n` must be above the key's ([below](#nonces-signedtx-submittx-txerr)) |

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

A transaction of more than 100 actions is invalid
([R6](SEMANTICS.md#r6-protocol-limits)): `CanSubmit` and `TxErr` refuse it.

### Allowances

`WithAllowance(Perm(...), n)` gives a function-call key an allowance of `n`
([K2](SEMANTICS.md#k2-full-access-versus-function-call-keys)). `SubmitSigned` and `SubmitTx`
refuse a transaction that costs more than the key's allowance (`AllowanceOK`; equal is
enough), and charge the cost less its gas refund. State both on the first receipt of every
transaction such a key signs, with `WithTxCost(r, cost, refund)`, in the allowance's units
(`cost > 0`, `0 ≤ refund ≤ cost`); without it the library asserts, since nearcore's cost is
never 0:

```tla
PlayTx(id, t) == WithTxCost(Rcpt(id, t, G, U, "play", 0, 0, U, 0), Cost, Refund)
Play == SubmitSigned(PlayTx(nid, ntx + 1), U, "s") /\ ...
```

The refund comes back at once, not when nearcore's refund receipt runs. Do not state a
refund lower than nearcore's: that hides transactions nearcore lets through
([N-allowance](SEMANTICS.md#over-approximations)). `examples/session-key` sizes an
allowance for a number of plays. `KeyAllowance(a, k)` reads what is left.

To replace a key that has an allowance, add the new one under a fresh key id. Adding a key
with an allowance under an id that has already signed a transaction is an `Assert` if the key
is still there when the receipt ends: nearcore would add the old transactions' late gas
refunds to the new key, which the model cannot.

### Nonces: `SignedTx`, `SubmitTx`, `TxErr`

`SubmitSigned` checks no nonce, so a model where a transaction can be submitted twice, or
signed transactions can land out of order, needs `SubmitTx`
([K5](SEMANTICS.md#k5-transaction-nonces)):

- `SignedTx(a, k, n, r)` is a signed transaction, a value your model can keep, hand to an
  attacker or submit again.
- `TxErr(st)` is nearcore's first refusal of it, or `""`: `"InvalidNonce"` when `n` is not
  above the key's nonce, `"NonceTooLarge"` at or above the nonce ceiling (below), and the
  others in nearcore's order (K5).
- `SubmitTx(st)` submits it if `TxErr(st) = ""` and sets the key's nonce to `n`.

Branch on `TxErr` rather than letting `SubmitTx` disable the step, so the refusal is a state
your invariants can see. From `examples/tx-nonce/Nonces.tla`:

```tla
ELSE IF TxErr(s) = ""
THEN /\ SubmitTx(s)
     /\ landed' = landed \cup {st.n} /\ ntx' = ntx + 1
     /\ UNCHANGED <<signed, nn, lost, credits>>
ELSE /\ TxErr(s) = "InvalidNonce" /\ st.n \notin landed \cup lost
     /\ lost' = lost \cup {st.n}
     /\ UNCHANGED <<platformVars, keyVars, signed, nn, landed, credits, ntx>>
```

Nonces are abstract integers, from 0 for a new key; the key's delegates share them (K4).
nearcore also refuses a nonce at or above `block_height × 1e6`. The model's heights and
nonces are not on that scale, so the ceiling is off by default. A model whose nonces can run
ahead of the chain sets it in `runs.toml`: the first refused nonce at model height `blk` is
`(NonceHeight0 + blk) × NoncePerHeight` (`examples/tx-nonce`, `nonce_too_large`):

```toml
"NearKeys!NonceHeight0" = "1"
"NearKeys!NoncePerHeight" = "2"
```

### Key actions as child receipts

Your contract can change its own keys with child receipts built by
`AddKeyRcpt(id, tx, acct, a, perm, cb)` and `DelKeyRcpt(id, tx, acct, a, cb)`.

- Route them in the dispatcher with `ExecKeyAct(r, k, p)`, decoding the key id `k` and the
  permission `p` from your own `r.a`.
- Key actions succeed only on the predecessor's own account.
- Adding a key that is present, or deleting one that is absent, fails the receipt.
- In gas mode, these constructors give the receipt its fee-table fee (`KeyFee`). For a
  function-call permission that includes the per-byte fee on its method names, counted as
  written (`Σ (len + 1)`, one byte per character). A name with a character outside
  printable ASCII is an `Assert` (TLC counts characters, nearcore UTF-8 bytes); for such
  names, or placeholders for longer ones, give the real byte count with
  `WithMethodBytes(perm, n)` ([N-keyfee](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)).
  A key-action receipt built with plain `Rcpt(..., ADDK, ...)` costs its creator nothing
  unless you add `WithFee`.

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

### Delegate actions (meta transactions)

In a meta transaction (NEP-366) a user signs a delegate and a relayer submits it, paying the
gas and any deposit ([K4](SEMANTICS.md#k4-delegate-actions-nep-366-meta-transactions)). The
inner call sees the **user as predecessor** (`r.fr`) and the **relayer as signer**
(`Signer(r)`, `SignerKey(r)`). Only the signer and its key carry over to the receipts it
spawns: each of those sees its immediate creator as predecessor, so for user → C → D, D sees
C as predecessor and the relayer as signer. A contract that pays or authorises
`env::signer_account_id()` serves the relayer here.

- `SignedDelegate(s, k, n, mbh, c)` is user `s`'s signature with its key `k`: nonce `n`,
  expiry height `mbh` (or `NoExpiry`), inner receipt `c` (built with `Rcpt`; its id, tx and
  predecessor are filled in when it runs).
- `SubmitDelegate(id, tx, rl, k, sd)` is relayer `rl`'s transaction, signed with its key `k`
  (a full-access key: a function-call key cannot sign a Delegate).
- `ExecDelegate(r)` runs the relayer's first receipt on the user's account. It fails it on a
  missing account, a missing key, a nonce at or below the key's (`KeyNonce`), a
  function-call key that could not sign `c`, or expiry; else it records the nonce and emits
  the inner receipt. A failed delegate refunds the deposit to the relayer; a failed inner
  call refunds it to the user, not to the relayer who paid it.

From `examples/meta-tx/MetaTx.tla`:

```tla
\* The user's own step: its signature over the next nonce.
Sign == \E u \in Users, bad \in BOOLEAN :
          /\ nn[u] < MaxSign
          /\ signed' = signed \cup {SignedDelegate(u, "k0", nn[u] + 1, Mbh, Claim(u, bad))}
          /\ nn' = [nn EXCEPT ![u] = @ + 1]
          ...

\* The relayer submits any signed delegate, as often as it likes.
Relay == /\ ntx < MaxTx
         /\ \E sd \in signed : SubmitDelegate(nid, ntx + 1, RL, "r0", sd)
         ...

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<keyVars, mine>>
           [] IsDeleg(r)   -> ExecDelegate(r) /\ UNCHANGED mine
           [] OTHER        -> RunL(r)
```

What the model must do:

- **Build a `SignedDelegate` only in a step of the user itself.** The model does not check
  signatures: a relayer step that signs for a user is a forgery nearcore rejects
  ([N-delegate-forgery](SEMANTICS.md#over-approximations)). Let the relayer replay what it
  holds, as `Relay` does: replays are what the nonce check is for.
- **Route `IsDeleg(r)` to `ExecDelegate` in the dispatcher, before the handlers.** `Exec`
  stops with an `Assert` on a Delegate receipt.
- **Put users in `KeyAccts`** with the key they sign with. For a user outside `KeyAccts`
  there is no key, nonce or permission check, so replays succeed
  ([N-delegate-unkeyed](SEMANTICS.md#over-approximations)).
- **Expiry needs the clock.** With `MaxBlk = 0` a delegate with an expiry height may fail at
  any time ([N-delegate-expiry](SEMANTICS.md#over-approximations)). With the clock it fails
  when `blk > mbh`; for `ClockHorizonOK` that comparison counts `T = mbh + 1`
  ([section 14](#14-joint-callbacks-yieldresume-and-the-block-clock)). That is the general
  bound. An absolute expiry height saturates: if no other comparison reads the clock, every
  height above `mbh` behaves alike, so `MaxBlk = mbh + 1` covers every behaviour
  (`meta_expiry_clock` in `examples/meta-tx`).
- Delegate nonces are tracked per key and do not see the nonces of direct transactions with
  the same key, and a re-added key starts again at 0
  ([N-delegate-nonce](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs),
  [N-delegate-rekey](SEMANTICS.md#over-approximations)).

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
on that account is pending. An instant receipt ([section 16](#16-creating-and-deleting-accounts))
is exempt: it runs before local ones.

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
- otherwise the leftover is split over the children's function-call actions by weight, each
  getting `floor(U * w / W)` Ggas. With the default `FeeRounding = "up"` the whole-Ggas
  remainder goes to no one, so no child gets more than in nearcore as long as the model's
  leftover is at most nearcore's (burns that are upper bounds, no pooled gas: N-precision in
  [SEMANTICS](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)); with `"nearest"` the last
  weighted action also gets it
  ([G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas));
- a child function call left with 0 gas fails its creator. Under `"up"` the model's leftover
  is a lower bound of nearcore's, so it cannot always tell 0 gas from a little: static 0 and
  weight 0 fails the creator; static 0 and a weight whose share is certainly at least one gas
  unit commits it; otherwise (a model leftover of 0, or a tiny weight against a large sum)
  both happen (verdict `"either"`), and in the commit the child runs with 0 Ggas and runs out
  of gas. One with no static gas at all (no `GasCall` entry, no `WithCall`) is a TLC
  assertion;
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
- The promise limit (1024 per call, R6) is counted per record. In fault mode `pa` serves
  only that, so its records need only `kids` (and `nj`, the call's `promise_and` count, if
  any); the model reads it only when the receipt's children could pass 1024 in all.

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

## 14. Joint callbacks, yield/resume and the block clock

The rules are [C6](SEMANTICS.md#c6-joint-promises-promise_and),
[C7](SEMANTICS.md#c7-yield-and-resume-nep-519) and [S3](SEMANTICS.md#s3-block-clock). Worked
examples: [`joint-promise`](../examples/joint-promise/), [`yield-resume`](../examples/yield-resume/),
[`yield-clock`](../examples/yield-clock/).

**Joint callbacks.** `AndThen(ks, c, d0)` builds `promise_and(ks).then(c)`: it wires the input
receipts `ks` to `Len(ks)` fresh data ids starting at `d0` and returns `[kids, cb]`. Count the
data ids in `O.ids` as well as the receipts. Put the callback in `post`, never in `ready`:

```tla
\* split(): promise_and(a.take(), b.take()).then(self.on_both); r.cb: returned to our caller
LET j == AndThen(<<Rcpt(nid, r.tx, A, r.to, "take", args, 0, r.to, 0),
                   Rcpt(nid + 1, r.tx, B, r.to, "take", args, 0, r.to, 0)>>,
                 Rcpt(nid + 2, r.tx, r.to, r.to, "on_both", args, 0, r.to, r.cb), nid + 3)
IN Outcome({j.kids[1], j.kids[2]}, {j.cb}, RProm, 0, 5)    \* 3 receipts + 2 data ids

\* on_both: one result per input, in promise_and order, each Failed or not on its own
LET failed == {i \in 1..NRes(r) : IsFailed(ResAt(r, i))} IN ...
```

On a joint callback `r.res` is `JointMark` (`ok = FALSE`, `v = JOINTRES`), not the first
result: a handler written for one input sees `Failed` every time, so the bug shows in your
invariants instead of passing silently. A receipt cannot feed two callbacks (`cb` is one id), so
`promise_and([p, p])` and `p` used by two `.then`s are out of scope.

**Yield and resume.** `YieldRcpt(nid, r, m, args, 0, cb)` is `promise_yield_create` on `r`'s
account; put it in `post`. Its id is the resume token. Pass `cb = r.cb` and `RProm` to return
it. A resume is `OResume(O, y, v, n)` (payload value `v`, `n` KB); the host's return value is
`CanResume(r, y)`, which is TRUE for **every** resume until the callback runs, not only the
first. The callback sees `r.res.v = v`, or `Failed` on a timeout.

```tla
\* request(): yield on_answer and return it
Outcome({}, {YieldRcpt(nid, r, "on_answer", Arg(nid), 0, r.cb)}, RProm, 0, 1)
\* answer(y): resume; pay once, guarded by your own state, not by CanResume alone
[O |-> OResume(Out0, y, 7, 0), pay |-> CanResume(r, y) /\ reqs[y] = "open"]
```

`promise_yield_create_with_id` is the same receipt; its duplicate check and its deposit
(`dep`, also in `out`) are the handler's job. Keep the custom id in the yield's args and test
it against `PendingYieldRcpts(r, ps)`, with `ps` the yields this handler has already created:
a yield callback may re-create its own id (it is no longer pending when it runs), and a second
create of one id in the same call is a duplicate. `PendingYields(r.to)` is wrong here: it is
the state view, which still lists the running callback and misses the current call's yields.

```tla
\* create_with_id(k) for on_answer: on a duplicate the host returns u64::MAX and creates nothing
IF \E p \in PendingYieldRcpts(r, {}) : p.m = "on_answer" /\ p.a.k = k THEN Out0
ELSE Outcome({}, {YieldRcpt(nid, r, "on_answer", [k |-> k], 0, 0)}, RVal(0), 0, 1)
```

The payload limit is not checked ([N-yield-payload](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)).

**The block clock.** Without it (`MaxBlk = 0`) every pending yield may time out at any
moment, which is sound for yields; but `blk` stays 0, so a handler that reads it never sees
time pass. To model "not before the deadline", set `MaxBlk` and `YieldTicks` and add the step
to `Next`:

```tla
Next == Send \/ Run \/ (BlockTick /\ UNCHANGED mine)
```

A handler reads the height as `blk` and the timestamp as `BlockTs` (`TsOf(blk)`; `TsOf` takes
an argument, so the runner cannot override it: compute your own function of `blk` instead).

`MaxBlk` is a bound, not an abstraction of later time, and it has two consequences
([S3](SEMANTICS.md#s3-block-clock)). Add a check for each to the invariants:

- `YieldDeadlinesInBound` fails if a pending yield's deadline passed `MaxBlk`, where yields
  may time out early. While it holds, no timeout in the run is premature, so a violation is
  real. It says nothing about what the bound leaves out.
- `ClockHorizonOK(n, T)` fails if `MaxBlk < (n + 1) * max(T, YieldTicks)`. Nothing past
  `MaxBlk` is explored: a window your model opens later, or a timeout delayed past the bound,
  is missing, and a pass is a pass up to `MaxBlk` only
  ([N-clock-horizon](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)). Take `T`
  = the largest number of blocks any comparison with the clock counts (`blk >= at + CancelAt`
  counts `CancelAt`; `>` and `=` count one more; a comparison with a yield's deadline counts
  `YieldTicks` more), and `n` = the most steps in one behaviour that read or record `blk` or
  `BlockTs`, create a yield or run a yield callback. The `+ 1` is the state an invariant
  reads after the last of them; do not count it in `n`. Define it in your module
  (`HorizonOK == ClockHorizonOK(2 * MaxTx, CancelAt)`) and list it. If you choose a smaller
  `MaxBlk`, write down why it still covers your model, or report the result as bounded.
  `horizon_*` in `yield-clock` shows a double refund that passes at `MaxBlk = 2`, is flagged
  by `HorizonOK` and found at `MaxBlk = 3`; `yield-clock/final-observation` shows an
  invariant that fails only in the gap after the last step.

With `TickAnytime <- FALSE`, no handler reading the clock and at most `k` yields per
behaviour, `MaxBlk = k * YieldTicks` is enough. Keep `TickAnytime` TRUE whenever a handler reads
`blk` or `BlockTs`: with FALSE the clock stops when no yield is pending, which can hide a bug
(`cancel_after_answer` in `yield-clock` passes with it). `BlockTick` and `EpochTick` are
independent.

TLC errors on comparing values of different types inside one set (a number with a string, a
tuple with a number). If your ghosts store results or receipts, keep each field one type.

## 15. Storage staking per byte

The rule is [B2](SEMANTICS.md#b2-balance-must-cover-storage-lackbalanceforstate). Worked
example: [`storage-stake`](../examples/storage-stake/). By default the library checks a fixed
`StorageFloor` after each function call. That misses a contract whose storage grows: each new
record raises what the balance must cover. Set `StoragePerByte <- TRUE` and the library keeps
every account's storage usage in bytes (`stor`). After each receipt the receiver's liquid +
locked must then cover `stor[a]` at `StorageByteCost`, unless `stor[a]` is at most 770 bytes. If
it does not, the receipt fails with `LackBalanceForState` and reverts. `StorageFloor` is then
not checked: both encode the same rule.

Your handlers declare the bytes they write with `OStor(O, d)`. `d` is the number of bytes
added, negative when freed. Count them with nearcore's rule (`RecordBytes(k, v)` = key + value
+ 40 for a new key; an overwrite adds the length difference; a removal frees key + value + 40):

```tla
\* deposit(): a new entry under "d" + borsh(AccountId) (4 + 64 bytes) holding a u128 (16)
IF u \notin DOMAIN book
THEN OStor(Outcome({}, {}, RVal(0), 0, 0), RecordBytes(1 + 4 + 64, 16))
ELSE Outcome({}, {}, RVal(0), 0, 0)                     \* an overwrite of the same length: 0
```

Or measure them and read them from a table with `OStorKey`
([Bytes from the calibrator](#bytes-from-the-calibrator)).

The library adds the rest itself:

- AddKey (`KeyBytes(p)`: 82 for a full-access key) and DeleteKey, in `ExecKeyAct` and, for
  `WithKeyActs`, folded into the call's bytes. Function-call key bytes depend on the real
  receiver and method names: give the receiver id's length with `IdBytes`, and placeholder
  method names their real byte count with `WithMethodBytes`.
- Implicit-account creation (`CreatedBytes`: 182, 132 or 100 bytes).
- CreateAccount (100 bytes plus its keys) and DeleteAccount (0), [section 16](#16-creating-and-deleting-accounts).
- Token registrations, when you set `TokRegBytes` (`Nep145`, per token and holder):
  `storage_deposit`,
  `storage_unregister`, `near_deposit`, and `"autoRegister"` transfers, which add bytes with
  no deposit. For near-contract-standards, `StdRegBytes(len)` = 61 + the holder id's length,
  measured in the sim (`StorStd` holds the same line, `storage_deposit/new`).

Give every account its real usage at the start in `StorageInit`: 100 bytes for the account
record, its keys, the contract code (the wasm size) and its data. For a deployed contract,
`view_account` shows `storage_usage`. An entry you leave at 0 makes that account exempt.
`PlatformInit` stops with an `Assert` if an initial balance does not cover its bytes. With a
hand-written `Init` (`PlatformInitStorage`), list `StorageCovered` as an invariant.

```toml
[constants]
StoragePerByte = 'TRUE'
StorageInit = 'Bytes0'          # Bytes0 == [a \in Accts |-> IF a = "v" THEN 120000 ELSE 182]
StorageByteCost = 'Cost'        # Cost == <<1, 100>>: 1 unit = 1 milliNEAR
```

Units: TLC integers are 32-bit, and the check multiplies (`bal * den >= bytes * num`), so keep
balances below 2^31 / `den` and bytes below 2^31 / `num`. At `<<1, 100>>` that is about 21
million units (21,000 NEAR) and 2 GB. A transaction whose deposit would leave its signer
uncovered cannot be submitted. A scripted model that must go on should test `CanSubmit(r, a)`
before `Submit`, since an uncovered `Submit` is a disabled step.

### Bytes from the calibrator

Instead of counting, measure. `calibrate --stor` runs each flow of a flow spec at every point
of its gas grid, reads nearcore's `storage_usage` of every successful call's receiver before and
after it, checks that the bytes do not change with gas, and writes a `StorBytes` table keyed
like `GasBurn` (`"acct.method[/path]"`): bytes = `base + per * size`, the size coming from the
spec's `[[stor_size]]` (for example the key + value length of a write; give a sized key flows
at 3 or more sizes, and a key without one must measure the same everywhere).
Give the table to the library and read it with `OStorKey(O, key, size)`, which adds that key's
bytes to the outcome's:

```tla
Kv == INSTANCE StorKv                        \* generated, beside the spec
VaultStor == Kv!KvStorBytes(V)               \* "v.put/new" :> [base |-> 40, per |-> 1], ...
Rec(O) == OStorKey(O, V \o ".put/new", RecLen)
```

```toml
[constants]
StorBytes = 'VaultStor'
```

A key missing from the table stops TLC with an `Assert`, as `GasBurn` does. Without
`StoragePerByte`, `OStorKey` leaves the outcome as it is and reads no table, so the default,
empty `StorBytes` is fine there. The table counts; you still choose the key and path each
handler reads and state its size, since TLC has no string length. A table holds only what its
flows ran, under their state ([N-storage](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)).
Measure the paths your handlers take, with state like production, as for burns
([Calibrating](#calibrating)). `examples/storage-stake` runs its vault both ways: the
`vault_measured_*` runs read the record's bytes from `StorKv`, measured on the generic probe's
`put`, and an invariant (`BytesBooked`) checks that the library applied the table's line.

## 16. Creating and deleting accounts

The rules are [A6](SEMANTICS.md#a6-createaccount), [A7](SEMANTICS.md#a7-deleteaccount),
[A8](SEMANTICS.md#a8-account-actions-in-a-call-receipt) and
[A9](SEMANTICS.md#a9-deploycontract) and
[A10](SEMANTICS.md#a10-global-contracts-nep-591). Worked examples:
[`account-lifecycle`](../examples/account-lifecycle/) and its `instant/`, `factory/` and
`global-upgrade/`.
Account actions travel in an ACCOUNT receipt (`m = ACCT`), which runs no code:

| constructor | actions |
|---|---|
| `CreateAcctRcpt(id, tx, new, fr, a, dep, cb)` | `[CreateAccount, Transfer(dep)]` from `fr` (no Transfer if `dep = 0`); refunds go to `fr` |
| `DeleteAcctRcpt(id, tx, acct, a, b, cb)` | `[DeleteAccount(b)]` on `acct`, sent by `acct` itself |
| `WithDeleteTo(r, b)` | appends `DeleteAccount(b)` to an ACCOUNT receipt |
| `NearKeys.WithAcctKeys(r, acts)` | adds key actions (`AddKeyAct`, `DelKeyAct`) after the Transfer, e.g. the new account's first key |
| `WithCreate(r)` | puts `[CreateAccount, Transfer(r.dep)]` before the call of a call receipt `r` (the factory batch, A8); the call's own deposit becomes 0 (set `r.dep` afterwards for one) |
| `WithDeleteTo(r, b)` on a call receipt | puts `DeleteAccount(b)` after its call (sent by the account itself, or after a CreateAccount) |
| `WithDeploy(r, t)` | adds `DeployContract(t)` to an ACCOUNT or call receipt, after its CreateAccount and Transfer, before its call and DeleteAccount (A9) |
| `DeployRcpt(id, tx, acct, a, t, cb)` | `[DeployContract(t)]` on `acct`, sent by `acct` itself |
| `WithDeployGlobal(r, t, md)` | adds `DeployGlobalContract(t)` to an ACCOUNT receipt; `md` is `"hash"` or `"acct"` (A10) |
| `DeployGlobalRcpt(id, tx, acct, a, t, md, cb)` | `[DeployGlobalContract(t)]` on `acct`, sent by `acct` itself |
| `WithUseGlobal(r, g)` | adds `UseGlobalContract(g)` to an ACCOUNT or call receipt, where `DeployContract` would go (not both) |
| `UseGlobalRcpt(id, tx, acct, a, g, cb)` | `[UseGlobalContract(g)]` on `acct`, sent by `acct` itself |

In gas mode each constructor sets `gf` to the receipt's whole send + exec fee from the fee
table, the prepaid reservation, whether the receipt succeeds or fails (nearcore refunds a
failed receipt the exec fees of the actions after the failing one as gas, which is not
modelled; SEMANTICS A6). A handler emits these like any child; a script submits them like any transaction
(`Submit(DeleteAcctRcpt(nid, t, "p", args, "b", 0))`: `p` deletes itself, its balance goes to
`b`).

Route them in the dispatcher before your handlers:

```tla
Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE IF IsAcctRcpt(r) THEN ExecAcct(r) /\ UNCHANGED mine
         ELSE RunC(r)
```

With `NearKeys` use `ExecAcctK(r)` (it runs the key actions and clears a deleted account's
keys) and `ExecBuiltinK(r)` (it gives a NEAR-implicit account created by a Transfer its key,
`ImplicitKeyId`); conjoin `UNCHANGED` of your own variables, not of `keyVars`. `Exec` asserts
if it is handed an ACCOUNT receipt.

What the library does:

- **Create.** The checks of A6 in nearcore's order: the account must not exist, its id must
  not be implicit, a top-level id needs `TopCreator` as predecessor, a sub-account its parent
  in `AcctParent`. State them: toy ids have no structure, and by default every account is
  top-level and `TopCreator` is no model account, so every create fails. A failed create
  refunds the deposit to the creator (a factory, not its user) and sends Failed to its
  callback.
- **Delete.** Only the account itself (actor check), nothing staked, and with `StoragePerByte`
  at most 10,000 bytes besides its code (`CodeSize`). The balance goes out as a refund receipt
  to the beneficiary, which runs later and is burnt if the beneficiary does not exist (or is
  the deleted account). The account joins `deleted`: calls, key actions and Stake to it fail,
  it cannot sign (`CanSubmit`), a Transfer to it is refunded unless its id is implicit (then
  the Transfer creates it again).
- **Deploy.** Only the account itself (or after a CreateAccount in the same receipt). A code
  is a tag, `t`, with `CodeLen[t]` bytes (override `CodeLen`, default 0); the account's
  bytes lose the old code's and gain the new code's, its data stays. `CodeOf(a)` is the
  account's code (`InitCode` for the accounts in `Contracts` at the start, else none); a
  deleted account loses its code and an account created again has none. Your handler is the
  same TLA+ either way: branch on `CodeOf(r.to)` if the contract changes at run time.
- **What survives.** Postponed callbacks, data and yields addressed to a deleted account stay
  in flight. They fail while it is deleted and run against the new account once it is
  created again. `NoOrphans` keeps holding: the callbacks still run.

Reset your own state for a deleted account. The library wipes `near`, `stor` and `keys`, not
your variables. Read `DeletesAcct(r)` after `ExecAcct`, like `Ok`:

```tla
RunAcct(r) == /\ ExecAcct(r)
              /\ bal' = IF DeletesAcct(r) THEN [bal EXCEPT ![r.to] = 0] ELSE bal
```

**Account actions in a call receipt** ([A8](SEMANTICS.md#a8-account-actions-in-a-call-receipt)).
A factory sends `WithCreate(Rcpt(nid, r.tx, child, r.to, "init", args, dep, r.to, cb))`: one
receipt that creates the child, funds it with `dep` and calls `init` on it. A contract that
closes itself can end its last call with `WithDeleteTo(Rcpt(nid, r.tx, r.to, r.to, "last",
args, 0, r.to, 0), b)`. `Exec` runs such a receipt (`HasAc(r)`): the account actions' checks
come first, then the call on the account they leave, then the storage check (skipped after a
delete); on commit the account actions' effects join the call's. With key actions in it use
`NearKeys.ExecK(r, O)` and `OkK(r, O)` (they also reset the new or deleted account's keys);
plain `Exec` asserts. Route it to your handler as usual (the handler is the child's code), and
reset your own state with `DeletesAcct(r)`:

```tla
RunBatch(r) == /\ Exec(r, InitOut(r))
               /\ owner' = IF Ok(r, InitOut(r)) THEN [owner EXCEPT ![r.to] = r.a.u] ELSE owner
```

A handler that reads its own balance (`env::account_balance`) should read `BalSeen(r)`, not
`near[r.to]`: it adds the call's attached deposit and, in a factory batch, starts from the new
account's 0 plus the batch's Transfer, as nearcore does.

Three things to know. The new account has no code, so `init` fails unless the batch deploys
first: `WithDeploy(WithCreate(Rcpt(..)), "child")`, the batch `[CreateAccount, Transfer,
DeployContract, FunctionCall(init)]`. With `StoragePerByte` the deposit must cover the code's
`CodeLen` bytes, or the whole batch fails (`factory_underfunds_code`). A failed batch returns
its deposit to the factory, not to the user, and the factory's callback may run before that
refund arrives (S4), so a factory that repays the user from its callback needs a reserve
(`examples/account-lifecycle/factory`, `factory_no_reserve`). After a DeleteAccount the
receipt's result is empty bytes, whatever the call returned.

An account that a model creates must be in `Accounts` (with balance 0 in the initial state)
and outside `Exists`. Without `StoragePerByte` the large-state refusal never happens
(N-delete-large).

**Instant deletes** ([S5](SEMANTICS.md#s5-instant-receipts)). A lone `DeleteAcctRcpt` that a
handler emits in its outcome's ready set (no deposit, no key actions), or a delegate's inner
one, runs right after the receipt that made it: `Commit` tags it (`inst`), and while it is
pending (`InstantPending`) only tagged receipts run and no transaction, block or epoch step is
enabled. The library's own steps are gated; conjoin `~InstantPending` to your own steps that
change state outside receipts (a scripted action, a contract-side clock):

```tla
Tick == ~InstantPending /\ round' = round + 1 /\ UNCHANGED platformVars
```

Forgetting it is sound: your step may then run between a creator and its delete, which only
adds behaviours. The beneficiary's payout is not instant, nor is a delete that is a
transaction's first receipt, nor `[Transfer, DeleteAccount]`. `InstantFirst <- FALSE` turns
the rule off, an over-approximation (N-instant): a self-closing contract then shows a
spurious use-after-close (`examples/account-lifecycle/instant`).

### Global contracts

[A10](SEMANTICS.md#a10-global-contracts-nep-591). An identifier is `GHash(t)` (by hash: users
keep the code they chose) or `GAcct(a)` (by account: the owner `a` redeploys and every user
runs the new code). `IdLen(g)` is its bytes, 32 or the owner id's length. `DeployGlobalRcpt(nid,
t, "o", args, "v2", "acct", 0)` publishes tag `"v2"` under `GAcct("o")`; `UseGlobalRcpt(nid, t,
"u", args, GAcct("o"), 0)` switches `u` to it. In a factory batch,
`WithUseGlobal(WithCreate(Rcpt(..)), GHash("child"))` is `[CreateAccount, Transfer,
UseGlobalContract, FunctionCall(init)]`: the child stores 32 bytes for the identifier, not the
code (`factory_global`).

What the library does:

- **The deploy** burns `GlobalBurn(CodeLen[t])` from the account at commit (it joins `burnt`)
  and emits a `GDIST` receipt, a built-in that `ExecBuiltin` (and `ExecBuiltinK`) runs. Until
  it runs, the identifier is unpublished or still has the old code. Its id is the deploy's
  nonce; it is applied only if that is above the identifier's last applied nonce (`gnonce`),
  so of two deploys in flight the later wins, though the earlier may be published first for a
  while. No account needs to exist for it to run, and it carries no gas or NEAR.
- **The use** fails with `GlobalContractDoesNotExist` unless `gcode` has the identifier when it
  runs, so a use sent right after the deploy can fail (`upgrade_use_races_deploy`).
- **`CodeOf(a)`** of a user is `gcode[guse[a]]` in the current state: a callback that was in
  flight during a by-account redeploy runs the new code. Dispatch on `CodeOf(r.to)` in your
  handler if both versions matter (`upgrade_assumes_old_code`, must fail).
- **Deletion** drops the account's `guse` entry; deleting the owner leaves `gcode`.

`GlobalInstant <- TRUE` skips the `GDIST` receipt and publishes at the deploy's commit. It
saves states but removes the window above, so a verdict that passes with it may not hold
(`upgrade_use_race_instant` passes, `upgrade_use_races_deploy` fails).

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

With `--stor` the same spec gives storage bytes instead: each flow runs over its gas grid, and the tool
writes a `StorBytes` table for `OStorKey` ([section 15](#bytes-from-the-calibrator)). Declare
what the bytes grow with in `[[stor_size]]`, and give each path that writes differently (a new
key, an overwrite) a flow of its own with its `path`.

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
  [Not modelled](SEMANTICS.md#over-approximations)). A sim without fault injection rarely
  shows a same-pair reorder, but nearcore produces one under load
  ([S4](SEMANTICS.md#s4-no-per-pair-order)); reproduce it with `Fault::Hold`, not by waiting
  for it;
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
- `[[witness]]` and `[[mutant]]` tables sit beside the `[[run]]` tables and name the runs
  they apply to ([Witnesses and mutants](#witnesses-and-mutants)).
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

A `pass` run must check at least one invariant: properties alone do not count, since a run
with an empty INVARIANTS section can pass without looking at a single state.
`allow_no_invariants = "why"` is the explicit exception.

## Witnesses and mutants

A pass says that no reachable state breaks an invariant. It does not say the invariant looked
at anything. Two shapes pass vacuously in asynchronous models:

- **The antecedent is never reached.** `Idle => P` holds trivially when the system never
  becomes idle again. A dropped `.then` does exactly that: the call's result is a data receipt
  that nothing consumes, so `Idle` never holds and every `Idle => ...` invariant passes, with
  thousands of states explored.
- **The bug is invisible to the invariants.** A removed precondition whose damage the
  platform repairs (an overdraft that the token refuses, followed by a refund) leaves a
  conservation sum intact.

The runner checks both with two tables in `runs.toml`, run by `--anti-vacuity` after the plain
runs (CI runs it in its own job; without the flag the tables are only validated):

```sh
python3 tools/run.py examples/pay --anti-vacuity
```

**A witness** names a situation that must be reachable. The runner defines
`Wit_<id> == <expr>` in the run's wrapper and checks it alone; TLC must report it violated.
Write the witness as the negation of the situation:

```toml
[[witness]]
id = "on_paid_sees_failed"
expr = '~(\E r \in Runnable : r.m = "on_paid" /\ ~r.res.ok)'
runs = ["pay_unreg"]          # globs; default: every pass run without expect_window
```

A pass is reported as `vacuous: witness <id> never reached` and fails. A situation that is
out of reach by design is documented with `expect = "unreachable"` and a `reason`; then the
runner requires the pass, and fails if the situation is ever reached.

**A mutant** is a deliberate bug that some run must catch. The runner copies the `.tla` files
of the spec's directory (or, with `library = true`, of the library directory holding `file`)
into the job's temporary directory, replaces `find` with `replace` in the copy and runs TLC
with the copy in the original's place. Your files are never touched. The number of
occurrences of `find` must equal `count` (default 1); the runner checks every mutant before
it starts any TLC process. A library module that also sits beside `runs.toml` is refused:
TLC would load that copy, not the patched one.

By default only an invariant violation kills a mutant: an `Assert` (a missing gas key, say)
or a deadlock shows that the mutation broke the model, not that an invariant covers the bug.
`killed_by = ["Books", "assert"]` names the kills that count; list `"assert"` or
`"deadlock"` only when that is the intended detection.

```toml
[[mutant]]
id = "failed_not_credited"
file = "Pay.tla"
find = 'ELSE IF ~r.res.ok THEN 0 ELSE amt'
replace = 'ELSE amt'
count = 1
class = "failure branch skips rollback"
runs = ["pay_unreg"]          # expect = "pass" runs only
# equivalent = "why"          # an accepted survivor must say why
```

Each listed run is checked with its own invariants. The results:

| result | meaning | verdict |
|---|---|---|
| `killed <inv>` | some run violated an invariant (one in `killed_by`, if given) | ok |
| `killed (assert)`, `killed (deadlock)` | a run stopped on an `Assert`, or (with `deadlock = true`) a deadlock, and no invariant caught the mutant | fails, unless `killed_by` lists `"assert"` / `"deadlock"` |
| `survived` | every run passed | fails, unless `equivalent` is given |
| `equivalent` | survived, as `equivalent` says | ok |
| `timeout` | a job ran past its run's `budget_s` | fails; never counted as survived |
| `error` | a parse or evaluation error | fails |

A mutant marked `equivalent` that is killed fails too, so the claim stays true. Each witness
and mutant job has its run's `budget_s` and is stopped there. A check of a run that did not
match its own expectation is skipped and reported.

### Conventions

- **Every `Sane` includes `NoOrphans`.** It is the platform's check that every data receipt
  has a waiting callback and every callback has its data on the way; it turns a dropped or
  mis-wired `.then` into a violation instead of a vacuous pass.
- **For every `P => Q` invariant**, a witness that `P` is reached (`~(P)`; with `Idle`, write
  `~(Idle /\ ntx > 0)`, since the initial state is idle), and a witness that `Q` can be
  false when that is informative.
- **For every callback that reads a promise result**, one witness per arm: the success value,
  `Failed`, and for token answers the unparsable bytes. Forcing a fault on the callee is not the
  same as delivering `Failed` to the callback; forcing a fault on the callback skips its body.
- **For every guard with a numeric threshold**, a boundary witness: the guarded value sits
  exactly at the threshold, and one where the guard refuses.
- **At least one mutant per bug class the example claims to cover**, beside its must-fail
  twins: dropped `.then`, failure branch skips rollback, inverted result check, removed
  precondition, off-by-one guard, wrong refund account. Name the class in `class`.
- **An equivalent mutant carries evidence**: a never-reached witness for the patched branch or
  value, or a stated argument. Equal state counts corroborate; they do not prove.
- **Do not rely on `-coverage` for branch coverage.** TLC 2.19 leaves out untaken `IF`/`CASE`
  arms inside operator bodies instead of reporting them as 0. Use branch witnesses.

### Invariant shapes that turn out weak

- **Conservation sums hide overdrafts and drift.** Pair `a + b + c = total` with `>= 0` per
  term, and, for every internal mirror of another contract's ledger, a "books match" check at
  quiescence.
- **Invariants over a handler-written ghost cannot see a wrong effect.** If the handler records
  "refund = x", a refund of x sent to the wrong account still satisfies the ghost. State money
  properties over what the platform records (balances, ledgers), or over a reference computed
  from the counterparty's recorded answer.
- **"Nothing bad" needs "something good".** Prohibitions alone survive a revoke that does not
  revoke or a delivery that never happens. Add one effect invariant per operation: once settled
  after X, X's effect holds.
- **A mutex checked one way catches half the bugs.** "Idle implies the flag is clear" sees a
  lost unlock, but not a lock taken late or a second operation admitted while one is in
  flight. Add the converse (a pending callback implies the flag is set).
- **Bounds and symmetric data hide bugs.** Equal weights hide a weight swap; one transaction
  per actor hides every mutex bug; a balance that always covers the cap hides the cap. A
  witness per guard shows this in a second; a run with asymmetric constants fixes it.
- **A must-fail run should differ from its passing twin in the contract**, not in the
  environment; a control built by removing the attacker is clean by construction.
- **Keep the full invariant set in every run.** A run that checks one invariant, or only
  library sanity, is weak evidence for the contract. When a known violation forces an
  exception, encode it narrowly rather than dropping the invariant.

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
rounding bound summed over its path, and only on calibrated tables. With the default
`FeeRounding = "up"` the fee table never understates a fee and the unused-gas split never
gives a child more than nearcore does (it hands out no whole-Ggas remainder,
[G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)), so as far as the fee
table and the split go a window's lower edge errs high, never low: by less than 4 Ggas per
action-only receipt, plus less than 1 Ggas per weighted child for each split on the path,
plus what the smaller leftover passes on. Burns are only as good as their calibration
([N-burn](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)). Under `"nearest"` either
edge can err by a few Ggas either way, the split included.

## Worked material

All examples are toy contracts written for this repo.

- **`examples/minimal`**: the complete minimal model above. Copy it to start.
- **`examples/pay`**: a contract that pays out of an internal balance through
  `ft_transfer_call` and reconciles in its callback.
  - fault-mode runs over every receiver behaviour and two token deviations;
  - gas-mode runs: the out-of-gas edge, a print-only window, and the same window on the
    measured `CalibStd` table.
- **`examples/platform-selftest`**: deterministic scenarios with known nearcore outcomes. They
  cover receipts, results, accounts, refunds, staking, storage, keys, gas, tokens, joint
  callbacks and yields. It checks
  the library, and it is a catalogue of how to drive each operator.
- **The semantic examples**, each a must-pass and a must-fail pair for one rule:

  | example | rule |
  |---|---|
  | `callback-after-failure` | callbacks always run and see Failed; a failing callback reverts only itself |
  | `revert-scope` | a failed receipt reverts only itself, not the transaction |
  | `signer-propagation` | the signer is inherited by children and callbacks |
  | `deletekey-atomicity` | `[DeleteKey, FunctionCall]` in one receipt is atomic |
  | `local-priority` | local-receipt priority on versus off |
  | `weight-split` | the split of unused gas by weight; `remainder/`: under `"nearest"` the last child can get more than in nearcore, under `"up"` none does |
  | `eth-implicit-fee` | the Transfer fee to an eth-implicit receiver |
  | `fee-edge` | a gas budget at a fee's edge: `FeeRounding` `"up"` catches a budget 0.37 Ggas short that `"nearest"` passes |
  | `pair-order` | no per-pair FIFO: a receiver that assumes in-order delivery fails, one with sequence numbers passes |
  | `nep141-refund-cap` | the NEP-141 resolver caps the refund at the amount |
  | `nep145-refund-to-predecessor` | `storage_deposit` refunds the excess to the predecessor |
  | `mt-smoke` | NEP-245 transfer and resolve |
  | `mt-batch` | a NEP-245 batch transfer_call to an arbitrary receiver: per id, the resolver refunds min(unused, amount) capped by the receiver's balance; a resolver that ignores the answer, or one that does not cap it at the amount, gives the sender back the wrong amount |
  | `joint-promise` | a joint callback's results: one per input, in order, failing independently |
  | `yield-resume` | resume returns TRUE until the callback runs (the double-resume trap); a timeout is Failed |
  | `yield-clock` | timeouts fire late, never early; the clock bound (with the gap after the last step: `final-observation/`) and `TickAnytime` |
  | `account-lifecycle` | a Transfer to an account deleted meanwhile is refunded to the sender: an escrow without a callback strands it, one with a callback restores the claim; a refund to a deleted account is burnt; `instant/`: a self-closing contract relies on its delete being instant; `factory/`: a factory batch is atomic and its deposit returns to the factory, whose callback must repay the user, from a reserve, and a batch can use a global contract instead of deploying one; `global-upgrade/`: a by-account global contract's redeploy reaches a user's callback already in flight, and a use sent right after the deploy can fail |
  | `storage-stake` | per-byte storage: a record written in a callback after the payout fails for storage, which the fixed floor misses; recording in the paying receipt passes |
  | `session-key` | a function-call key's allowance: sized as plays × cost, forgetting the gas refunds, it lets more plays through; a model that states no refund hides that |
  | `tx-nonce` | transaction nonces: a replay is refused; a wallet that signs payments in parallel loses one when a later one lands first; without nonces a replay pays twice |
  | `limits` | protocol limits at the last value nearcore accepts and the first it refuses: actions per receipt, promises per call, joint inputs, returned bytes, AddKey method names, logs |
