# Concepts

This page explains the ideas behind near-tla before you write a model. It is for two kinds of
reader: NEAR developers who have not used TLA+, and TLA+ users who have not used NEAR. Read the
half you need, then the vocabulary table, then the sections on what a result means.

- [NEAR's execution model, in one page](#nears-execution-model-in-one-page)
- [TLA+ and TLC, in one page](#tla-and-tlc-in-one-page)
- [How near-tla fits together](#how-near-tla-fits-together)
- [Vocabulary](#vocabulary)
- [Fault mode and gas mode](#fault-mode-and-gas-mode)
- [What a pass means](#what-a-pass-means)
- [What a failure means](#what-a-failure-means)
- [Bounds and the size of the state space](#bounds-and-the-size-of-the-state-space)
- [Design choices](#design-choices)

## NEAR's execution model, in one page

A NEAR transaction does not run as one atomic unit. It turns into a tree of **receipts**, and
each receipt runs on its own, later, on the account that receives it.

- **A transaction becomes one receipt.** When a user signs a transaction to call
  `vault.deposit()`, the network turns it into a receipt addressed to `vault`. The account that
  sent a receipt is its **predecessor**; the account that signed the original transaction is
  its **signer**. Every receipt in the tree has the same signer.
- **A receipt runs atomically, and only on its receiver.** Running `deposit` may change
  `vault`'s state and create new receipts (calls to other contracts), but it cannot touch
  another contract's state directly.
- **A failure reverts only its own receipt.** If a receipt panics or runs out of gas, its
  state changes and the receipts it would have created are thrown away. Receipts that already
  ran, earlier in the same transaction, stay committed. There is no transaction-wide rollback.
- **Cross-contract calls are promises.** `token.ft_transfer(..).then(self.on_done())` creates
  two receipts: the call to `token`, and a **callback** to the contract itself that waits.
  The callback is **postponed** until the call's result arrives, carried by a separate
  **data receipt**.
- **Callbacks always run.** The callback runs whether the call succeeded or failed. It sees
  the outcome as a **promise result**: Successful with the returned bytes, or Failed. A
  callback that does not check its result will act on work that never happened.
- **Deposits come back as receipts too.** When a receipt that carried attached NEAR fails, the
  NEAR goes back to the sender in a separate **refund receipt**, which runs later.
- **Gas is prepaid and split.** The signer attaches gas to the transaction (up to 1000 Tgas
  since protocol 83). Each call a receipt creates gets a fixed **static** amount plus a share
  of the gas left over, by **weight**. A receipt that needs more gas than it holds runs out,
  with the same revert scope as any failure.
- **Order is loose.** Receipts of different transactions interleave freely. Even two receipts
  from one account to another can run in the opposite order to the one they were created in
  ([S4](SEMANTICS.md#s4-no-per-pair-order)). A transaction whose signer is also its receiver
  starts with a local receipt, which runs earlier ([S1](SEMANTICS.md#s1-local-receipts-first-the-exact-rule)).

Most cross-contract bugs come from these rules: a callback that trusts a failed call, state
committed before a call that later fails, a refund that arrives after something else has used
the money, a callback starved of gas.

## TLA+ and TLC, in one page

TLA+ describes a system as **states** and **steps**. A state is a value for each variable.
A step is a relation between one state and the next, written with primed variables:
`n' = n + 1` means "in the next state, `n` is one more than now".

- **A spec** gives the initial states (`Init`) and the steps allowed from any state (`Next`).
  `Next` is usually a disjunction (`\/`) of actions: "a user submits a transaction, or some
  pending receipt runs, or a receipt fails".
- **An invariant** is a formula that must be true in every reachable state, for example
  "once nothing is in flight, the contract's count equals the number of works done".
- **TLC**, the model checker, starts from every initial state and tries every step from every
  state it reaches, until there are no new states. If an invariant is false in some state, it
  stops and prints a **counterexample**: the sequence of states from the start to the bad one.
- **Constants** fix the size of what TLC explores: how many users, how many transactions, how
  many faults. TLC checks every behaviour within those bounds, exhaustively. It does not prove
  anything about larger bounds.

You need very little TLA+ syntax to read a near-tla model: records `[a |-> 1, b |-> 2]`, sets
`{1, 2}`, sequences `<<1, 2>>`, functions `[a \in S |-> 0]`, `LET .. IN`, `IF .. THEN .. ELSE`,
`CASE`, `\E x \in S : P` (some x) and `\A x \in S : P` (every x). The video course and
the reference on the TLA+ website explain each in a few minutes.

## How near-tla fits together

near-tla is a library of TLA+ modules that encode NEAR's runtime rules. You write a model of
your contract on top of it.

```
your model (MyContract.tla)            the library (modules/)
--------------------------            -----------------------
your state variables                   the receipt pool, data receipts
one handler per method:                the verdict of each receipt:
  what it changes, which receipts        commit, fail, out of gas
  it creates, what it returns          refunds, the gas split, fees
a dispatcher (which handler runs)      built-in receipts: Transfer, refunds,
users' transactions                      Stake, keys, account actions
the properties that must hold          sanity checks: NEAR conserved,
                                         no orphaned callbacks
```

A model is a directory with your `.tla` file and a `runs.toml`. The `runs.toml` lists the
TLC runs you want: the constants for each, and whether each must pass or must fail. The
runner (`tools/run.py`) runs them all and checks each result against its expectation
([RUNNER.md](RUNNER.md)).

The [tutorial](TUTORIAL.md) builds a complete small model step by step.

## Vocabulary

Each NEAR term, the name the model uses for it, and where it lives. `r` is the receipt being
run; most names are defined in `modules/NearAsync.tla`.

| NEAR | in the model | notes |
|---|---|---|
| account | a string in `Accounts` | toy names such as `"u"`, `"c"`; `Exists` says which exist at the start |
| transaction | `Submit(WithGas(Rcpt(...), g))` | a step of your `Next`; `r.tx` is its transaction id |
| receipt | a record built by `Rcpt(id, tx, to, fr, m, a, dep, rto, cb)` | every receipt has the same fields |
| receiver, predecessor | `r.to`, `r.fr` | `env::current_account_id()`, `env::predecessor_account_id()` |
| signer | `Signer(r)` | read from `txsig`; switch it off with `TrackSigner <- FALSE` if the model never reads it |
| method and arguments | `r.m`, `r.a` | `r.a` is a record you define |
| attached deposit | `r.dep` | in toy units of NEAR |
| refund account | `r.rto` | the predecessor, unless the contract set `refund_to` |
| receipts waiting to run | `rq` (ready), `post` (postponed callbacks) | `Runnable` is the set that can run now |
| data receipt | an element of `data` | carries a result to the callback whose id is `d.to` |
| `.then(callback)` | a child in the handler's `post` set, and `cb` on the call | the call's `cb` is the callback's id |
| promise result | `r.res`, a record `[ok, v, sz, len]` | `IsFailed(r.res)`; `v` may be a number or `EMPTY`, `MAL`, `NONEMPTY`, `NOPR` ([section 7](USAGE.md#7-reading-promise-results)) |
| return a value / a promise | `RVal(v)` / `RProm` | the `ret` of an outcome |
| what a method does | a handler returning `Outcome(ready, post, ret, out, ids)` | children that run now, children that wait, the return, NEAR sent out, fresh ids used |
| a receipt runs | `Exec(r, O)` | the library decides commit, failure or out of gas |
| did it commit? | `Ok(r, O)` | guard your state change with it, in the same step as `Exec` |
| panic (`require!`, `env::panic_str`) | `OErr(O, msg)` | the receipt fails |
| liquid balance | `near[a]` | |
| prepaid gas | `WithGas(r, g)` | in Ggas: 1 Tgas = 1000 Ggas |
| static gas, weight | `GasCall` table, or `WithStatic`, `WithWeight` | per method |
| gas burnt | `GasBurn` table | per method or per code path (`OKey`) |
| ran out of gas | recorded in `oog` | |
| a failure TLC may inject | `ForcedFail(r)`, for methods in `MayFail`, at most `MaxFails` times | counted in `fails` |
| nothing in flight | `Idle` | no ready receipts, no postponed callbacks, no data |
| Transfer, refund | receipts with `m = "XFER"`, `m = "REFUND"` | run by `ExecBuiltin` |

The full list of what each operator encodes, with nearcore citations, is in
[SEMANTICS.md](SEMANTICS.md).

## Fault mode and gas mode

The constant `GasMode` picks how a receipt can fail for lack of gas.

- **Fault mode** (`"fault"`) treats gas as abstract. A receipt fails for gas only when TLC
  chooses to fail it: every method listed in `MayFail` may fail, up to `MaxFails` times in a
  behaviour. This is the quick way to ask "what if this call fails?". It needs no numbers.
- **Gas mode** (`"gas"`) treats gas as a quantity. A transaction carries prepaid gas, each
  child gets its static gas and a weighted share of the leftover, and a receipt whose need
  exceeds what it holds runs out. This answers "at which prepaid amounts does this fail?". It
  needs gas numbers for your methods: measured burns (see [Calibrating](USAGE.md#calibrating)),
  or the host-cost floor, a lower bound that needs no measurement
  ([USAGE section 12](USAGE.md#gas-without-a-calibration-the-host-cost-floor)).

The forced-fault switch works in both modes. Start in fault mode; move to gas mode for the
callbacks whose failure matters.

## What a pass means

A run that passes means: **in every behaviour TLC explored, every invariant held.** That is a
strong statement, with four limits.

1. **Within the bounds.** TLC explored the runs' constants: so many users, so many
   transactions (`MaxTx`), so many forced faults (`MaxFails`), the prepaid gas amounts in the
   menu. A bug that needs three transactions is invisible to a run with two.
2. **For your abstraction of the contract.** The handlers are hand-written. If a handler
   skips a branch the real code has, the model cannot find bugs in that branch
   ([N-wasm](SEMANTICS.md#scope-limits)).
3. **Under the rules the library encodes.** Those are nearcore's at protocol version 88
   (nearcore 2.14.0-rc.5). Some runtime behaviour is left out. Most omissions are
   over-approximations, which can only add behaviours. But 25 of the 51 entries in
   [Not modelled](SEMANTICS.md#not-modelled) are under-approximations, which can hide bugs,
   and several apply at the default settings (for example per-byte storage staking, off by
   default, and the rounding of fees and burns). Read that list for the features your
   contract uses.
4. **For the properties you wrote.** TLC checks the invariants you list and nothing else.
   A property that is too weak (a total that balances while one user's money moves to
   another) passes on a broken contract.

Every model should therefore also have must-fail runs, witnesses and mutants: evidence that
each invariant can fail, that the interesting situations are reached, and that small bugs
are caught ([RUNNER.md](RUNNER.md#every-invariant-must-be-able-to-fail)).

## What a failure means

A run that fails prints a counterexample: a sequence of transactions, receipts and failures
that ends in a state where an invariant is false. Treat it as a **hypothesis about your
contract**, not yet a finding.

- It may be real: replay it on the compiled contract and it breaks there too.
- The handler may not match the contract: the model did something the code does not.
- The order may not be reachable: the model allows some orders a network does not produce
  ([Over-approximations](SEMANTICS.md#over-approximations)). A reorder of two receipts between
  the same pair of accounts **is** reachable ([S4](SEMANTICS.md#s4-no-per-pair-order)), so
  that alone is never a reason to dismiss a trace.
- The gas numbers may be wrong for that path, if it is a gas-mode run.

[VALIDATING.md](VALIDATING.md) shows how to replay a counterexample in a local sandbox and how
to write it up.

## Bounds and the size of the state space

TLC enumerates states, so the bounds decide how long a run takes. Each extra transaction,
fault or gas amount multiplies the number of interleavings.

- **Start small.** Two or three accounts, one or two transactions, one forced fault. Most
  async bugs need only one transaction and one failure, or two transactions that interleave.
- **Grow one bound at a time**, and watch the `distinct` column the runner prints. A run of
  thousands of states takes a second; millions take minutes.
- **Keep the gas menu short.** In gas mode, each prepaid amount is a separate branch. A menu
  around the edge you care about (and the maximum) is enough; a least-gas sweep finds the
  edge for you ([RUNNER.md](RUNNER.md#least-gas-and-size-sweeps)).
- **Bound your own data.** Amounts, ids and lists in your state should range over small sets.
- **Set `budget_s`** in `runs.toml` so a run that grows past its budget is reported instead
  of running for hours.

Accounts are strings, so TLC's symmetry reduction does not apply.

## Design choices

- **Safety only.** near-tla checks invariants, not liveness. "Callbacks always run" is checked
  as the invariant `NoOrphans` (every postponed callback has its input on the way) together
  with witnesses showing the callbacks are reached. The runner turns deadlock checking off by
  default, because a finished system has nothing left to do.
- **TLC only.** The library uses TLC's `Assert`, `PrintT`, `TLCGet` and `TLCSet`, and the
  runner overrides definitions through the TLC config. Apalache and TLAPS will not check it as
  it is.
- **One flat namespace.** Models `EXTENDS` the modules, so library operator names are visible
  in your model. If TLC reports a name clash, rename your operator.
- **Toy units.** Balances and deposits are small integers; gas is in Ggas. The fee operators
  take bytes, and some sizes are in KB ([Units](SEMANTICS.md#units)).
