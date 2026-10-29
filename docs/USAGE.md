# Modelling guide

This guide covers everything a model of a real contract needs beyond the
[tutorial](TUTORIAL.md): the modules to choose, the constants, receipts and handlers in full,
promise results, tokens, keys, ordering, gas, joint callbacks and yields, storage staking,
accounts, and calibrating gas. Read the tutorial first; this guide assumes you have written
its model.

- New to NEAR's receipts or to TLA+? Start with [CONCEPTS.md](CONCEPTS.md).
- Running checks, reading traces, witnesses, mutants, sweeps and the audit:
  [RUNNER.md](RUNNER.md).
- Replaying a counterexample on the compiled contract: [VALIDATING.md](VALIDATING.md).
- Which runtime rule each operator encodes, and what is not modelled:
  [SEMANTICS.md](SEMANTICS.md).

The sections build on each other. 1-7 are the basics every model uses. 8-11 and 14-16 are
features: read the ones your contract uses. 12 and 13 and [Calibrating](#calibrating) are about
gas.

## Contents

- [The method](#the-method)
- [1. Choose the modules](#1-choose-the-modules)
- [2. Constants and overridable definitions](#2-constants-and-overridable-definitions)
- [3. Variables and Init](#3-variables-and-init)
- [4. Receipts](#4-receipts)
- [5. Writing handlers](#5-writing-handlers)
- [6. The dispatcher and Next](#6-the-dispatcher-and-next)
- [7. Reading promise results](#7-reading-promise-results)
  - [Reading a large result costs gas](#reading-a-large-result-costs-gas)
- [8. Calling tokens](#8-calling-tokens)
  - [Event logs](#event-logs)
  - [Batches of hundreds of ids: id classes](#batches-of-hundreds-of-ids-id-classes)
- [9. Receiving tokens](#9-receiving-tokens)
- [10. Signer and keys](#10-signer-and-keys)
- [11. Local-receipt priority](#11-local-receipt-priority)
- [12. Fault mode and gas mode](#12-fault-mode-and-gas-mode)
  - [Worst-case storage gas (trie depth)](#worst-case-storage-gas-trie-depth)
  - [Gas without a calibration: the host-cost floor](#gas-without-a-calibration-the-host-cost-floor)
- [13. The forced-fault switch and labels](#13-the-forced-fault-switch-and-labels)
  - [Owed callbacks and detached work](#owed-callbacks-and-detached-work)
- [14. Joint callbacks, yield/resume and the block clock](#14-joint-callbacks-yieldresume-and-the-block-clock)
- [15. Storage staking per byte](#15-storage-staking-per-byte)
- [16. Creating and deleting accounts](#16-creating-and-deleting-accounts)
- [Calibrating](#calibrating)
- [Worked material](#worked-material)

## The method

These seven habits separate a model that finds real bugs from one that produces confident
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
   measured burns (from the sandbox's `gas_burnt`, or the calibrator if you have the sim), record
   their provenance, and check that the leftover split reproduces before believing any
   gas-mode verdict ([Calibrating](#calibrating)).
4. **Replay every counterexample on real wasm.** The model over-approximates some ordering
   (it has no chunks or shards) and abstracts your contract. Do not dismiss a counterexample
   only because two receipts from one account to another run in the opposite order to their
   creation: nearcore can do that ([S4](SEMANTICS.md#s4-no-per-pair-order)). A trace is a
   hypothesis until the same receipt tree, with the same gas and faults, reproduces against
   the compiled contract, in a near-workspaces sandbox or in near-contract-sim
   ([VALIDATING.md](VALIDATING.md)).
5. **Make every invariant able to fail.** For each invariant, add a deliberately wrong
   variant that TLC must report, and confirm from the trace that it fails for the reason you
   intended. An invariant that has never failed may be vacuous. Then show that each
   invariant's situation is reached and that small bugs are caught
   ([Witnesses and mutants](RUNNER.md#witnesses-and-mutants)).
6. **If you conjoin `LocalPriorityOK`, also run without it.** Local-receipt priority is
   opt-in, and off unless your model conjoins it ([section 11](#11-local-receipt-priority)).
   It holds only while the receiving chunk has room. A violation that appears only without it
   is real whenever the chunk is full, unless you can show the receiving shard is never at its
   limit.
7. **Push every owed callback to its edges, and audit what the runs reach.** A callback that
   completes or undoes an earlier commit must survive every input and every state a user can
   arrange, not only the ones your runs happen to use. For each one:
   - run it in gas mode;
   - declare its storage writes (`OWriteKey`) and run with `TrieGasWorst`;
   - find its least gas with a sweep;
   - declare its logs with lengths computed from its input, and sweep that input (the number
     of ids, the amounts, a memo) up to the per-call limits.

   List the source's callbacks and the methods other contracts call in `[audit] methods`.
   Then work through the runner's audit report until each gap is closed or accepted with a
   reason ([Auditing what the runs reach](RUNNER.md#auditing-what-the-runs-reach)). `--anti-vacuity`
   fails on every open gap. None of this needs the sim
   ([Gas without a calibration](#gas-without-a-calibration-the-host-cost-floor)).

**Without measured burns**, keep to fault mode for conclusions that depend on a burn you
estimated, and use gas mode with the host-cost floor for each callback with a fixed budget: a
callback that runs out on the floor runs out on real wasm too
([Gas without a calibration](#gas-without-a-calibration-the-host-cost-floor)). Treat other gas
windows, and every pass on the floor, as illustrative.

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
text (see [The runner](RUNNER.md#runstoml)). With `platform_defaults = true` in `runs.toml` you
set only `Accounts`, `MayFail` and `MaxFails`: the runner fills the others you leave unset with
neutral values (every account exists, no staking, no storage floor, fault mode with empty gas
tables, no outcome log; [Platform defaults](RUNNER.md#platform-defaults)).

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

**Accounts and code**

| definition | default | override when |
|---|---|---|
| `Contracts` | `Accounts` | some accounts have no code: a function call to an account outside `Contracts` fails |
| `AcctKind` | every account `"named"` | an account is NEAR-implicit, eth-implicit, deterministic or universal; toy ids cannot match the real patterns, so you state the kind. `AcctKinds(eth, nearImp)` builds the common case |
| `UniversalOn` | `TRUE` (protocol 88) | you model the rules before protocol 88, where a universal id is named and a Transfer to an absent one fails: `FALSE`. It is independent of `NearFees.FeeProtocol`, which selects fees only ([VERSIONING](VERSIONING.md#what-feeprotocol-does-and-does-not-change)) |
| `AcctParent` | every account top-level | the model creates sub-accounts: each account's direct parent, `Parents({<<"s.c", "c">>})` ([section 16](#16-creating-and-deleting-accounts)) |
| `TopCreator` | `"top-creator"` (no model account) | the model creates top-level accounts: the account standing for the protocol's `registrar_account_id` |
| `InitCode` | `"code"` for every account | a model reads `CodeOf` and its contracts start with different code: each account's tag at the start (only the accounts in `Contracts` have code) |
| `EthWalletCode` | `"eth_wallet"` | a model reads `CodeOf`: the tag of the eth wallet contract an eth-implicit account gets when a Transfer creates it (again) |
| `InitGCode` | nothing published | global contracts published at the start: a function from identifiers (`GHash(t)`, `GAcct(a)`) to code tags, `(GHash("child") :> "child")` ([section 16](#global-contracts)) |
| `InitUses` | no account uses one | accounts that run a global contract at the start: account to identifier; it wins over `InitCode`. With `StoragePerByte`, count the identifier's bytes (`IdLen`) in `StorageInit` |

**Signer and keys**

| definition | default | override when |
|---|---|---|
| `TrackSigner` | `TRUE` | the model never reads the signer: `FALSE` saves states. Do not read the signer with `FALSE`: with `PlatformInit` (`txsig` starts empty) that is a TLC error, but with an `Init` that pre-sizes `txsig` it silently returns the initial value |
| `DefaultKey` | `"default"` | your key ids differ and you use `Submit` |
| `IdBytes(s)`, `KeyBytes(p)` | 10; the borsh formula | `NearKeys`, with `StoragePerByte`: the real length of the receiver id a model id stands for (method names count as written, or as `WithMethodBytes` states); another key type (a key with an allowance, `WithAllowance`, already counts its 16 bytes) |

**The block clock**

| definition | default | override when |
|---|---|---|
| `MaxBlk` | `0` (no clock) | the model uses the block clock: the bound on `blk` ([section 14](#14-joint-callbacks-yieldresume-and-the-block-clock)) |
| `YieldTicks` | `0` | the model uses the clock: a yield's timeout in ticks (nearcore: 200 blocks) |
| `TickAnytime` | `TRUE` | no handler reads `blk` or `BlockTs`: `FALSE` lets blocks pass only while a yield's deadline is ahead, which saves states |

**Storage**

| definition | default | override when |
|---|---|---|
| `StoragePerByte` | `FALSE` | the model tracks storage in bytes: `TRUE` replaces the fixed `StorageFloor` with `stor` priced per byte ([section 15](#15-storage-staking-per-byte)) |
| `StorageInit` | 0 bytes for every account | with `StoragePerByte`: each account's storage usage at the start (record, keys, code, data). An entry of at most 770 bytes is exempt |
| `StorBytes` | empty | handlers read measured bytes with `OStorKey(O, key, size)`: the calibrator's table, `[key -> [base, per]]` keyed like `GasBurn` (a missing key is an `Assert`; unread without `StoragePerByte`) ([section 15](#bytes-from-the-calibrator)) |
| `CodeSize` | 0 bytes for every account | with `StoragePerByte` and DeleteAccount: the code bytes in each contract's `StorageInit`, which the 10,000-byte delete limit leaves out |
| `CodeLen` | 0 bytes for every code tag | with `StoragePerByte` and DeployContract: the bytes of each code tag a model deploys, `("child" :> 300000)` ([section 16](#16-creating-and-deleting-accounts)) |
| `StorageByteCost` | `<<1, 100000>>` (1 unit = 1 NEAR) | your NEAR unit is not 1 NEAR: one byte costs `num/den` units, `<<1, 100>>` for 1 unit = 1 milliNEAR |
| `GlobalByteCost` | `<<1, 10000>>` (0.0001 NEAR per byte) | your NEAR unit is not 1 NEAR, as for `StorageByteCost`: the burn of a DeployGlobalContract per code byte, `num/den` units; the burn of a deploy must be a whole number of units (an `Assert`) |
| `TokRegBytes` | 0 per token and holder | with `StoragePerByte`: `TokRegBytes[t][h]`, the bytes holder `h`'s registration adds to token `t`, for every `h` in `TokHolders[t]` (near-contract-standards: `StdRegBytes(len(id))` = 61 + the real id's length, measured; `TokStorageMin` stays the price of the longest id, `StdRegBytes(64)` = 125 bytes) |

**Gas**

| definition | default | override when |
|---|---|---|
| `PooledGasOK` | `FALSE` | a receipt with several function calls and no `pa` should pool their gas: `TRUE` (otherwise an `Assert`) |
| `HostFloorGas` | `FALSE` | gas mode without a calibrated table: `TRUE` adds the host-cost floor of each outcome's declared writes and logs to its burn, and a missing `GasBurn` key counts as 0 ([section 12](#gas-without-a-calibration-the-host-cost-floor)) |
| `TrieGasWorst` | `FALSE` | gas mode, and the model declares storage writes with `OWriteKey`: `TRUE` also runs each such receipt at every extra trie-node count up to its worst case ([section 12](#worst-case-storage-gas-trie-depth)) |
| `TrieAcctLen` | 64 | with `TrieGasWorst`: the real length of the receiver's account id in bytes (one value for all accounts) |
| `TokBatchPerAction` | `TRUE` | token batches should be one gas pool with the whole-batch key: `FALSE` (also set `PooledGasOK <- TRUE` if the batch has several gas entries) ([section 12](#per-action-gas-pa)) |
| `NearFees!FeeRounding` | `"up"` | you want the fee table's earlier rounding to the nearest Ggas, closer to nearcore's figures but able to understate a fee by a few Ggas: `"nearest"`. A definition inside the `NearFeeTable` instance, so the key is module-qualified: `"NearFees!FeeRounding" = '"nearest"'`, which the runner turns into a generated definition and TLC's `FeeRounding <- [NearFees] <that definition>`. In a hand-written cfg, define the value in your spec (`FeeNearest == "nearest"`) and write `FeeRounding <- [NearFees] FeeNearest`: TLC rejects a string literal on the right of `<-` as an undefined identifier. `"up"` also keeps the unused-gas split from handing out its whole-Ggas remainder ([N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs), [G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)). A module-qualified key overrides definitions only; the runner rejects one that names a `CONSTANT` |
| `MtGasIds` | 3 | gas mode, with a burn table of your own measured on larger NEP-245 batches: the most ids a batch may carry before it is an `Assert` (`CalibStdMt` is measured at 1-3; the resolver's burn grows faster than linearly) ([section 8](#batches-of-hundreds-of-ids-id-classes)) |
| `MtGasIdLen` | 2 | gas mode, with a burn table of your own measured on longer NEP-245 token ids: the most bytes an id (`MtIdLen`, else the model id's length) may have before a call carrying it is an `Assert` (`CalibStdMt` is measured on 2-byte ids; the burn grows with the length) ([section 8](#batches-of-hundreds-of-ids-id-classes)) |

**Tokens**

| definition | default | override when |
|---|---|---|
| `TokFtGasShape` | `"standard"` per token | the token is near-contract-standards 3.x/4.x style: `"reserve"`. This can change verdicts, not only gas windows; tokens built on 3.x/4.x (many older deployments) use the reserve shape, so check your token's version |
| `TokOnTransferStatic`, `TokOnTransferWeight` | -1 per token (the shape's default) | the token gives `ft_on_transfer` a different static or weight |
| `TokResolveStatic` | 5000 Ggas per token | the token's resolver has a different static gas |
| `TokResolveMaxLen` | 42 bytes per token (`FtMaxResultLen`) | the token is near-contract-standards 5.23.0 or older (3.x/4.x) and reads the receiver's result unbounded: -1. With 42, a longer result counts as all unused ([T2](SEMANTICS.md#t2-ft_resolve_transfer)) |
| `EvAcctLen`, `EvAmtExp`, `MtIdLen` | each model value's own length | the events' byte lengths matter: the real length of account ids and token ids, a token's decimal exponent ([section 8](#event-logs)) |
| `MtIdCount` | 1 for every id | a NEP-245 batch of many ids: the number of ids each model id stands for ([section 8](#batches-of-hundreds-of-ids-id-classes)) (at least 1) |

**Leave at the default.** These keep an older model's behaviour, or save states at the cost of hiding behaviours. A new model sets none of them.

| definition | default | override when |
|---|---|---|
| `CallsNeedCode` | `TRUE` | **deprecated** (to be removed in a later release); never, unless you are keeping an older model's behaviour (calls run whatever code the receiver has; a missing receiver still fails them) |
| `BurnLostRefunds` | `TRUE` | **deprecated** (to be removed in a later release); never, unless keeping older behaviour (a refund to a missing account stays in flight) |
| `InstantFirst` | `TRUE` | never, unless you want the over-approximation without instant receipts ([S5](SEMANTICS.md#s5-instant-receipts)): `FALSE` lets other receipts, transactions and blocks run between a receipt and the lone DeleteAccount it creates |
| `ResultReadGas` | `TRUE` | **deprecated** (to be removed in a later release); never, unless keeping older behaviour: `FALSE` stops charging the reads outcomes declare with `OReadRes` ([section 7](#reading-a-large-result-costs-gas)) |
| `TokEvents` | `TRUE` | the model declares the token's events itself (setting it to keep older behaviour is **deprecated**, to be removed in a later release): `FALSE` stops the token handlers from declaring their NEP-297 events and plain logs ([section 8](#event-logs)) |
| `GlobalInstant` | `FALSE` | state counts only: `TRUE` publishes a global deploy at its commit, without the distribution receipt. Unsound: it hides the window in which a use fails or users still run the old code ([N-global-instant](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)) |
| `TrieGasEnds` | `FALSE` | with `TrieGasWorst`: `TRUE` takes only no extra nodes and the worst case; fewer states, **unsound** |

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
| `PlatformInitExtra` | for a model that initialises the older platform variables itself: only `txsig`, `created`, `burnt`, `deleted`, `code`, `gcode`, `guse`, `gnonce`, `blk`, `stor`, `ofail` (= `PlatformInitSigner /\ PlatformInitAccounts /\ PlatformInitClock /\ PlatformInitStorage /\ PlatformInitOwed`) |
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
platform variable (`blk` and `stor` in 0.2, `deleted`, `code`, `gcode`, `guse`, `gnonce` and
`ofail` later), a hand-written list goes stale silently.

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
        dn == Rcpt(nid + 1, r.tx, C, C, "done", r.a, 0, C, r.cb)
    IN Outcome({w}, {dn}, RProm, 0, 2)
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
| `ids` | how many fresh ids the handler used. `Commit` asserts that the children's receipt ids and the joint callbacks' data ids are distinct and lie in `nid .. nid + ids - 1` |

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
that declares none never hits the limit. The library's token handlers declare their own
events ([section 8](#event-logs)).

## 6. The dispatcher and Next

Pick a runnable receipt and route it:

```tla
Step(r) ==
    CASE IsPlatformRcpt(r)              -> PlatformStep(r) /\ UNCHANGED mine  \* no contract code
      [] ~IsPlatformRcpt(r) /\ r.to = D -> RunD(r)
      [] OTHER                          -> RunC(r)

Next == \/ Ping                                                  \* submit transactions
        \/ \E r \in Runnable : Step(r)
        \/ \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine
```

- `PlatformStep(r)` runs the receipts that run no contract code: built-ins (Transfer, refund,
  Stake, global distribution) with `ExecBuiltin`, and account actions with `ExecAcct`.
  `IsPlatformRcpt(r)` says which receipts those are. With `NearKeys` use `IsPlatformRcptK` and
  `PlatformStepK`, which also run delegate receipts and an account receipt's key actions.
  `Exec` asserts if it is handed one of these receipts, or a key receipt.
- Keep the arms from overlapping: a `CASE` whose guards overlap may take either arm.
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

A callback sees `r.res = [ok, v, sz, len]`: whether the call succeeded, the value it returned,
and the value's size in KB and in bytes (0 when the model does not state it):

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

### Reading a large result costs gas

Copying a result into the contract's memory costs about 2.8 Mgas per byte: 11.8 Tgas for a
4 MiB result, which the receiver chooses. A bounded read (near-sdk's
`promise_result_checked(idx, max_len)`) of a longer result copies nothing. Declare the read in
the callback's outcome, with its bound (`-1` for unbounded), and gas mode charges it:

```tla
O == OReadRes(OKey(Out0, "on_done"), r.res, 64)    \* read with a 64-byte bound
```

Only results that state their size (`RValLen`, `RValSz`) cost anything. The NEP-141 resolver
declares its read (`TokResolveMaxLen`). `ResultReadGas <- FALSE` turns the charge off
([C4](SEMANTICS.md#c4-result-size)); `examples/result-read-gas` shows an unbounded resolver
running out of gas on a padded result.

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
`sdRefundToAccount` and `autoRegister`. `MtDev` does the same for a NEP-245 token, and also
takes `zeroAmountSkipped` and `selfTransferCredits`: near-sdk-contract-tools 4.0.0 skips a
zero amount and lets a transfer to oneself raise one's balance, where the model panics on
both by default ([N-mt](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)).

### Event logs

The token handlers log what the standard implementations log: an `ft_transfer`,
`ft_burn` or `mt_transfer` event (`EVENT_JSON:` + NEP-297 JSON) for each transfer and each
resolver refund, and near-contract-standards' few plain logs
([T8](SEMANTICS.md#t8-event-logs-nep-297)). Each one's byte length is computed from its
content and declared on the outcome, as `OLog` would, so the per-call limits (100 logs,
16384 bytes; R6) apply with nothing to declare: a batch whose event is too long fails with
`TotalLogLengthExceeded` and moves nothing, and an owed resolver that does shows that cause in
`OwedOK`'s `ofail`. The lengths use the model's values, so make them the real ones where it
matters:

- `EvAcctLen`: the real byte length of account ids (a partial function; an account outside
  its domain counts its model string, `Len(a)`), e.g.
  `EvAcctLen = '[a \in {"d", "r"} |-> IF a = "d" THEN 16 ELSE 14]'`;
- `EvAmtExp`: per token, the decimal exponent of a model amount: with `e`, the amount `x`
  prints with `Digits(x) + e` digits (`x` stands for `x × 10^e`), e.g. 18 or 24 for a token
  of that many decimals and amounts in whole tokens;
- `MtIdLen`: the byte length of NEP-245 token ids, else `Len(id)`;
- a memo: `WithMemo(FtArgs(rc, amt, msg), m)` gives the call a memo of `m` bytes (JSON-escaped:
  a `"` or `\` counts two); without it the memo is `None`.

A handler of your own that mints or burns with the standard events adds them the same way:
`OLog(O, FtMintLog(t, owner, amt, -1))`, `MtMintLog(t, owner, ids, amts, -1)`,
`MtBurnLog(...)` (the last argument is the memo's bytes, -1 for none); `EvLen` and the item
operators take raw byte lengths. Do not also `OLog` a token's own events: they would count
twice. `TokEvents <- FALSE` (`TokEvents = "FALSE"` in `runs.toml`) turns the token logs off.
`examples/event-logs` checks the lengths against the sim and shows both failures.

### Batches of hundreds of ids: id classes

`MtBatchArgs` vectors stay short in the model (a receiver's answer travels as one integer,
fewer than 16 entries), but a real batch can carry hundreds of ids, and its event and gas
grow with every one. An id class gives that size without the vectors: with
`MtIdCount = '[i \in {"ca", "cb"} |-> 200]'`, the model ids `"ca"` and `"cb"` each stand for
200 distinct ids, and `MtBatchArgs(R, <<"ca", "cb">>, <<1, 25>>, "")` is a batch of 400 ids,
1 of each of the first 200 and 25 of each of the others. `mtk`'s balance of a class is each
of its ids' balance, a receiver answers one value per class (`MtRet(<<u1, u2>>)`), and the
resolver caps and refunds per id as before; the event and the burn size count 400. Set
`MtIdLen` for the ids' byte length. This covers only behaviours in which the ids of a class
stay alike: a transfer of part of a class, or a receiver answering differently for ids of
one class, cannot be written (T5 has the exact boundary; N-mtclass). `mt_transfer` on a class
of more than one id is an `Assert`. So is, in gas mode, any NEP-245 call outside the ids
the burn table was measured on: a batch of 0 or of more than `MtGasIds` (3) ids, or an id
longer than `MtGasIdLen` (2) bytes. Past 3 ids the resolver's burn grows faster than
linearly, and every method's burn grows with the ids' length, which the keys do not see
(T5), so a line would understate them. Check large batches in fault mode, or measure your
contract's burns on such batches and ids, give them as your own `GasBurn` and raise
`MtGasIds` / `MtGasIdLen`. In gas mode, give a model id that stands for a 2-byte id but is
spelled longer its length with `MtIdLen`.
`examples/event-logs/batch-payout` pays two classes in fault mode and sweeps their size for
the edge at 16384 bytes.

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
as one integer (`["v"]` is the number `v`). The code fits TLC's integers when the vector
has fewer than 16 entries and the length times the bits of the largest entry is at most 21:
two entries up to 1023, three up to 127; beyond that `MtVecCode` stops TLC with an Assert. The arbitrary receiver is
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
`CalibStdMt` has the measured burns and the resolver's split for that implementation
([The standard tokens](#the-standard-tokens-calibstd)); `mt_batch_gas_std` in
`examples/mt-batch` uses it.

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
  come from `GasCall[key] = [st, wt, fee]`, looked up as `"acct.method"`, then `"method"`.
  For a function-call child, `fee` is the exec fee its creator prepays,
  `NearFeeTable!OneCallReceiptExecFee(n)` with `n` the method name's length plus the argument
  bytes; its send fees are part of the creator's burn;
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

### Worst-case storage gas (trie depth)

A calibrated burn holds the trie-node gas of the sim world it was measured in. At 88 a
`storage_write` or `storage_remove` pays 2.28 Ggas per trie node on its key's path, and the
path gets longer when other keys share a prefix with the key, which users of the contract
can often arrange. Reads and `has_key` pay no per-node gas
([G6](SEMANTICS.md#g6-storage-gas-and-trie-depth)). To check that a fixed gas budget survives
a deep trie, declare each write or remove of an `n`-byte key in the outcome, and turn the mode
on:

```tla
O == OWriteKey(OWriteKey(OKey(Out0, "on_take/refund"), 40), 40)   \* two writes of 40-byte keys
```

```toml
[run.constants]
TrieGasWorst = "TRUE"
TrieAcctLen = "20"        # the receiver's real account id length; default 64
```

With the mode on, in gas mode, `Exec` runs every receipt with a declaration once per extra
node count n, from 0 up to the writes' bound, `2 (2 + TrieAcctLen + n) + 2` nodes per write:
at its calibrated burn plus n × 2.28 Ggas (`TrieGasAt(n)`, rounded up). A failure that the
calibrated burn alone would not have reads `"out of gas (worst-case trie depth)"` in `ofail`.
With the mode off, `OWriteKey` changes nothing, so a model can declare its writes and run
both ways.

- Guard on `Ok(r, O)` after `Exec(r, O)` as usual. With the mode on, `Ok` reads `ofail`, where
  every failure of a receipt with declared writes is recorded (with `k = {}` when unmarked).
- Every count, not just 0 and the bound: less trie gas leaves the children more, and what a
  child does with more gas need not be safer. `examples/trie-gas/leftover`: at 0 extra the
  child's owed callback has enough, at the bound the child runs out before creating it, and
  at 190 extra nodes the child commits and the callback runs out.
- `TrieGasEnds <- TRUE` explores only 0 and the bound. It is **unsound** (it misses the
  failure above; `leftover_ends_only` passes) and only for a first, cheaper look at a model
  with many declared nodes.
- The bound is an upper bound: it also counts the nodes the calibrated burn already paid for.
  A second write of a key the same receipt already wrote pays no more in a deep trie than in
  a shallow one (the deeper path is charged once per receipt); declare it once.
- Not on a panic path (`OPanicKey`), and an `Assert` with `pa`.
- A receipt with declared writes has up to bound + 1 successors (215 for one 40-byte key with
  a 64-byte account id), and its children's shares differ between them, so expect more
  states.

`examples/trie-gas` has an owed callback whose 4.5 Tgas budget fits its calibrated refund path
(4 Tgas) but not the worst case of its two writes (+976 Ggas); its `cb_need` sweep finds the
least budget, 4976 Ggas.

### Gas without a calibration: the host-cost floor

Some host calls pay fixed fees whatever the wasm does. A storage write or remove pays at least
53.47 Ggas plus 38.22 Mgas per key byte. A log pays at least 6.66 Ggas plus 122.25 Mgas per
byte, decoding included ([G7](SEMANTICS.md#g7-a-floor-from-host-costs)). With
`HostFloorGas <- TRUE`, `Burn` adds that floor for the writes and logs an outcome declares
(`OWriteKey`, `OWriteKeys`, `OLog`, `OLogs`), and a missing `GasBurn` key counts as 0. So
without the sim you can run gas mode on the source's numbers alone:

```toml
[constants]
GasMode = '"gas"'
GasCall = "MyGasCall"     # static gas and weight of every call, from the source
GasBurn = "NoTable"       # [x \in {} |-> 0]: no burns measured
HostFloorGas = "TRUE"
```

```tla
\* the resolver removes n entries of 100-byte keys and logs a refund event
O == OLog(OWriteKeys(OKey(Out0, "on_take/refund"), 100, n), EvBytes(n))
```

Need is then a lower bound of nearcore's, and the verdicts split:

- **a finding:** a callback with a fixed budget (static gas, weight 0) gets exactly its static
  gas. If it runs out on the floor, it runs out on real wasm too, whatever the wasm burns on
  top.
- **a finding if the depth is real:** with `TrieGasWorst` on as well, a failure labelled
  `"out of gas (worst-case trie depth)"` also needs the trie charge the trace chose. That
  charge is an upper bound ([G6](SEMANTICS.md#g6-storage-gas-and-trie-depth)). It holds for
  distinct keys, each declared once, at a depth other users can build by storing keys that
  share a prefix with yours. Check the trace's charge against that before you call it real.
- **illustrative:** a pass, and any window of a weighted child. The wasm's own burn comes on
  top of the floor, and an under-counted burn in the creator leaves a weighted child more gas
  than nearcore would.

The floor counts what you declare, so declare every write and log the path makes, with
lengths from its input: the number of entries, the ids' lengths, the amounts. A larger
`GasBurn` entry is fine only if it bounds from below the work the floor does not count:
wasm execution, reads, value bytes. A measured burn already includes the host fees, so
adding the floor to it counts them twice. Never combine the switch with a calibrated table. Nothing is added on a panic path or per action (`pa`).

`examples/host-floor` has an owed callback with a fixed 5 Tgas budget that removes a batch
of distinct 100-byte keys and logs a refund event. On the floor alone, 80 entries fit and 81
run out (`floor_over`); with `TrieGasWorst`, 7 run out at the deepest trie
(`floor_trie_over`). Its `cb_need` sweep finds
the least budget for 81, 5049 Ggas.

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
- `"no-fault"`: neither. Any failure in the trace follows from the code and the accounts (a
  `require!`, a missing account), so the bug needs only the order of receipts shown.

The counterexample story prints the label on its last line. `LogOn = TRUE` keeps a per-receipt log
in `rlog` (`[tx, id, m, to, st, g]`), which is what conformance runs compare.

### Owed callbacks and detached work

Some receipts must not fail at all, whatever the cause
([F2](SEMANTICS.md#f2-owed-callbacks-and-detached-work)). Mark them and list the library's
check; you do not write an invariant about the callback yourself.

- **Owed**: a callback that completes or undoes what an earlier receipt committed: a resolver
  that refunds, a callback that credits back on `Failed`. Mark the child where you create it,
  `WithOwed(Rcpt(..., "on_deliver", ...))`, or name its method once,
  `OwedMethods <- {"on_deliver"}` (or `"v.on_deliver"`; this form counts only a postponed
  callback on its own account, so a user calling the method directly is not reported). List
  `OwedOK` as an invariant.
- **Detached**: work handed to a call that may fail with nothing to fix it: a payout Transfer,
  a job sent to another contract. Mark the receipt with `WithDetached(...)` (any kind, a
  Transfer too) or `DetachedMethods`, say what "voided" means for that work, and list
  `DetachedVoided`:

  ```tla
  Undone(x)  == <<x.a.k, x.a.t>> \notin done      \* x: the failed receipt's ofail record
  PayVoided  == DetachedVoided(Undone)            \* checked once x's transaction has settled
  ```

  Name the work instance (a ticket in the args), not just the item: after a void, a second
  legitimate attempt may mark the item done again.

The library records every failure of a marked receipt in the ghost `ofail`, with its cause:

```
ofail = { [ m |-> "on_deliver", to |-> "v", tx |-> 1, id |-> 3, k |-> {"owed"},
            why |-> "out of gas", g |-> 3000, need |-> 4000, a |-> [n |-> 1, memo |-> 1] ] }
```

`k` is the receipt's set of marks. A receipt marked both owed and detached is recorded once
with `k |-> {"owed", "detached"}` and counts for both checks (`OwedFailed` and
`DetachedFailed` filter by membership).

`why` is a panic with the handler's message, `"out of gas"` (with the attached gas `g` and
what it needed, `need`), a host limit (`TotalLogLengthExceeded`, `NumberOfLogsExceeded`,
`ReturnedValueLengthExceeded`, `NumberPromisesExceeded`), `FunctionCallZeroAttachedGas`,
`LackBalanceForState`, a missing account or code, or `"forced fault (MayFail)"`. A must-fail
run can pin the cause with `expect_output = 'why \|-> "out of gas"'`. `OwedFailed` is the set
of owed failures, for a print-only window:

```tla
WinOwed == OwedFailed # {} => PrintT(<<"WIN", "OwedOK", gas[1], OwedFailed>>)
```

The token modules mark the NEP-141 resolver (`ft_resolve_transfer`) and the NEP-245 one
(`mt_resolve_transfer`) owed by default (`TokOwedResolve`, `MtOwedResolve`; `<- FALSE` leaves
them unmarked), so a token model that lists
`OwedOK` checks that no resolver fails. Unmarked receipts record nothing, so marking costs
states only where a marked receipt fails. `examples/owed-effect` has a vault with one wrong
variant per cause and a payout without a callback.

`ofail` keeps every record for the rest of the run; nothing clears it at settlement, because
`DetachedVoided` reads a record after its transaction settles. Each record names its receipt
(`tx`, `id`), so `ofail` is as finite as the receipts the model can create: with bounded
transactions (`MaxTx`, `TxIds`), as in every example, it is. A model made finite some other
way, say a hand-written cfg whose `VIEW` or `CONSTRAINT` merges states that differ only in
history, has to account for `ofail` too, or two states the model considers equal stay apart
by their failure history and the state space need not close. In such a `VIEW`, replace `ofail`
by its (marks, cause) pairs, `{<<x.k, x.why>> : x \in ofail}`: `OwedOK` depends only on
whether an owed record exists, so its verdict is kept; `DetachedVoided` reads `x.tx` and
`x.a` and is not covered by that projection. Under `TrieGasWorst`, `Ok` reads `x.id` in
the step's own successor, which a `VIEW` does not affect.

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

Route them in the dispatcher before your handlers (`PlatformStep` does both arms, section 6):

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

There are two ways to measure:

- **In a local sandbox (public).** Run each path of your contract with near-workspaces and
  read each receipt's `gas_burnt`; [Measure your own burns](VALIDATING.md#measure-your-own-burns)
  shows how. You fit the `GasBurn` entries by hand, and should measure with realistic state,
  since burns grow with storage reads and writes.
- **With the `calibrate` tool (needs the sim).** It runs your wasm in near-contract-sim
  ([Fetching the sim](CONFORMANCE.md#fetching-the-sim)), over a grid of
  prepaid gas, checks the leftover split, and writes the TLA+ table with its provenance. The
  rest of this section describes it.

Without either, keep gas windows illustrative and base conclusions on fault mode and the
host-cost floor ([The method](#the-method)).

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

`CalibStdMt` does the same for a plain near-sdk-contract-tools 4.0.0 NEP-245 token
(`StdMtGasBurn(mt)`, `StdMtGasCall(mt)`), measured by the conformance flow set `mt`. Use it
with `MtGasShape[mt] = "tools"`. `mt_batch_transfer`, `mt_batch_transfer_call` and
`mt_resolve_transfer` burn base + per id. The resolver has no path keys: its key holds the
largest burn seen, so it overstates a resolve that refunds little (by up to 1.4 Tgas; it
creates no receipts, so no attached gas depends on it). `mt_on_transfer`'s burn and exec fee
are the receiver's entries, as for `ft_on_transfer`.

### Recalibrating for a real deployment

Burns depend on the contract's code, its state and the protocol. Before you rely on a window
for a deployed contract, recalibrate against **the exact wasm that is deployed**, with state
shaped like production (registered accounts, map sizes), and check its hash against the
table's header. Recalibrate again after any contract upgrade, any change of
near-contract-standards version, and any protocol bump ([`VERSIONING.md`](VERSIONING.md)).
Even then, treat edges as accurate only to the rounding bound in
[N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs).

## Running and checking a model

The runner, its `runs.toml` format, counterexample traces, must-fail runs, witnesses and
mutants, print-only windows, least-gas and size sweeps, and the audit are documented in
[RUNNER.md](RUNNER.md).

## Worked material

All examples are toy contracts written for this repo.

- **`examples/minimal`**: the model the [tutorial](TUTORIAL.md) builds. Copy it to start.
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
  | `owed-effect` | an owed callback must not fail: the library's `OwedOK` names each cause (panic, log and return limits, out of gas, a forced fault); `detached/`: a payout handed to a Transfer that fails must be voided (`DetachedVoided`) |
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
  | `mt-batch` | a NEP-245 batch transfer_call to an arbitrary receiver: per id, the resolver refunds min(unused, amount) capped by the receiver's balance; a resolver that ignores the answer, or one that does not cap it at the amount, gives the sender back the wrong amount; a gas-mode run on `CalibStdMt` with the 30 Tgas floor; amounts above 63; near-sdk-contract-tools' zero amounts and transfers to oneself (`MtDev`); fixed resolver cases with unequal `token_ids` and `amounts` |
  | `joint-promise` | a joint callback's results: one per input, in order, failing independently |
  | `yield-resume` | resume returns TRUE until the callback runs (the double-resume trap); a timeout is Failed |
  | `yield-clock` | timeouts fire late, never early; the clock bound (with the gap after the last step: `final-observation/`) and `TickAnytime` |
  | `account-lifecycle` | a Transfer to an account deleted meanwhile is refunded to the sender: an escrow without a callback strands it, one with a callback restores the claim; a refund to a deleted account is burnt; `instant/`: a self-closing contract relies on its delete being instant; `factory/`: a factory batch is atomic and its deposit returns to the factory, whose callback must repay the user, from a reserve, and a batch can use a global contract instead of deploying one; `global-upgrade/`: a by-account global contract's redeploy reaches a user's callback already in flight, and a use sent right after the deploy can fail |
  | `storage-stake` | per-byte storage: a record written in a callback after the payout fails for storage, which the fixed floor misses; recording in the paying receipt passes |
  | `session-key` | a function-call key's allowance: sized as plays × cost, forgetting the gas refunds, it lets more plays through; a model that states no refund hides that |
  | `tx-nonce` | transaction nonces: a replay is refused; a wallet that signs payments in parallel loses one when a later one lands first; without nonces a replay pays twice |
  | `result-read-gas` | an owed token resolver that reads its receiver's result unbounded runs out of gas on a 4 MiB answer; the 42-byte bound does not |
  | `host-floor` | gas mode without a calibration: an owed callback's fixed budget against the floor of its declared writes and event (`HostFloorGas`), which runs out on any wasm once the batch is large enough; with `TrieGasWorst`, sooner |
  | `trie-gas` | worst-case storage gas: an owed callback whose fixed budget fits its calibrated burn but not the trie-node gas of its writes in a deep trie (`TrieGasWorst`); `leftover/`: a child's owed callback that fails only at an intermediate trie charge |
  | `limits` | protocol limits at the last value nearcore accepts and the first it refuses: actions per receipt, promises per call, joint inputs, returned bytes, AddKey method names, logs |
  | `event-logs` | the token handlers' NEP-297 event lengths against the sim's, and an id class at the 16384-byte edge; `batch-payout/`: a batch payout whose event grows with the batch (sweep `payout_edge` finds the first size over the limit), an owed callback that marks it paid regardless; `resolver-log/`: an owed token resolver over a lowered log limit, reported by `OwedOK` |
