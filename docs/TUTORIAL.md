# Tutorial: your first model

This tutorial builds a complete model of a small contract, runs it, reads a counterexample,
and then checks that the passing runs mean something. It takes about an hour. At the end you
will have written every part a real model has.

The finished model is [`examples/minimal/`](../examples/minimal/) ([`Tally.tla`](../examples/minimal/Tally.tla)
and its [`runs.toml`](../examples/minimal/runs.toml)). CI runs it, so it keeps working. You can
read along in those files, or type the model yourself in a new directory.

If NEAR's receipts or TLA+ are new to you, read [CONCEPTS.md](CONCEPTS.md) first: it explains
both in a page each, and has a [vocabulary table](CONCEPTS.md#vocabulary) that maps NEAR terms
to the names used here.

## Contents

- [Before you start](#before-you-start)
- [The contract](#the-contract)
- [Step 1: write the property first](#step-1-write-the-property-first)
- [Step 2: state and the initial state](#step-2-state-and-the-initial-state)
- [Step 3: the handlers](#step-3-the-handlers)
- [Step 4: run a handler](#step-4-run-a-handler)
- [Step 5: the dispatcher and the steps](#step-5-the-dispatcher-and-the-steps)
- [Step 6: the runs](#step-6-the-runs)
- [Step 7: run it and read the counterexample](#step-7-run-it-and-read-the-counterexample)
- [Step 8: make sure a pass means something](#step-8-make-sure-a-pass-means-something)
- [Step 9: gas mode](#step-9-gas-mode)
- [Step 10: the audit](#step-10-the-audit)
- [Where to go next](#where-to-go-next)

## Before you start

You need Java 21, Python 3.11 or later, and the TLC jar the README's
[Quickstart](../README.md#quickstart) fetches. Check that the examples run:

```sh
python3 tools/run.py examples/minimal
```

Your own model can live anywhere. The runner finds the library by itself when you run the
runner from your near-tla checkout:

```sh
mkdir -p ~/models/tally
python3 ~/src/near-tla/tools/run.py ~/models/tally      # wherever your checkout is
```

## The contract

Two contracts and one user:

- **C**, the tally contract. A user calls `C.ping()` with a deposit of 1. `ping` asks D to do
  some work, and schedules its own callback `done` to run afterwards. `done` counts the work.
- **D**, the worker. `work()` counts how many times it ran.

The property we want: once nothing is in flight, C's count equals D's count. C should count
only the works that happened.

Here is C in near-sdk Rust. The correct `done` reads its promise result:

```rust
#[near(contract_state)]
pub struct Tally {
    worker: AccountId,
    n: u64,
}

#[ext_contract(ext_worker)]
trait Worker {
    fn work(&mut self);
}

#[near]
impl Tally {
    #[payable]
    pub fn ping(&mut self) -> Promise {
        ext_worker::ext(self.worker.clone())
            .with_static_gas(Gas::from_tgas(5))
            .work()
            .then(
                Self::ext(env::current_account_id())
                    .with_static_gas(Gas::from_tgas(2))
                    .with_unused_gas_weight(0)
                    .done(),
            )
    }

    #[private]
    pub fn done(&mut self, #[callback_result] result: Result<(), PromiseError>) {
        if result.is_ok() {
            self.n += 1;
        }
    }
}
```

D is one line:

```rust
#[near]
impl Worker {
    pub fn work(&mut self) {
        self.works += 1;
    }
}
```

The buggy version of C's `done` trusts the call:

```rust
    #[private]
    pub fn done(&mut self) {
        self.n += 1; // counts even when work failed
    }
```

On NEAR, `work` can fail (it can panic, or run out of gas) after `ping` has already committed.
`done` runs anyway and sees a Failed result. The buggy `done` counts a work that never
happened. The model will find this, and then show that the correct `done` has no such bug
within the bounds we choose.

## Step 1: write the property first

Before writing any handler, write down what must hold. Here it is one line:

```tla
Counted == Idle => n = works
```

`Idle` is the library's "nothing in flight": no receipt waiting to run, no callback waiting,
no result in transit. `n` will be C's count and `works` D's.

Writing the property first keeps the model honest: you decide what "correct" means before you
see what the model can do. Prefer properties about each user or each operation over one grand
total; a total can balance while one user's money moves to another.

The model also checks three library sanity properties, which every model should list:

```tla
Sane == NearConserved(InitU) /\ GasBounded(LAMBDA t : gas[t]) /\ NoOrphans
```

- `NearConserved(InitU)`: NEAR is neither created nor lost (only U starts with NEAR, `InitU` of it).
- `GasBounded(..)`: no receipt holds more gas than its transaction prepaid.
- `NoOrphans`: every waiting callback has its input on the way. A dropped `.then` breaks it.

## Step 2: state and the initial state

The model `EXTENDS NearAsync`, the platform module. It declares its own constants and
variables:

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
```

- `n` and `works` are the two contracts' counts.
- `ntx` counts the transactions sent so far, and `gas` records the prepaid gas of each one.
- `platformVars` are the library's variables (the receipts in flight, balances, and so on).
  `vars` must contain both.

The initial state gives U its balance and everyone else nothing:

```tla
Accts   == {U, C, D}
TxIds   == 1..MaxTx
Near0   == [a \in Accts |-> IF a = U THEN InitU ELSE 0]

Init == /\ PlatformInit(Near0, TxIds)
        /\ n = 0 /\ works = 0 /\ ntx = 0
        /\ gas = [t \in TxIds |-> 0]
```

`PlatformInit(balances, txIds)` sets every platform variable: the balances, an empty receipt
pool, and room for the transaction ids.

## Step 3: the handlers

A handler is the model of one method. It does not change any variable itself. It returns an
**outcome**: what the method wants to happen.

```tla
Outcome(ready, post, ret, out, ids)
```

| field | meaning |
|---|---|
| `ready` | new receipts that can run now: calls, Transfers |
| `post` | new callbacks that wait for a result (the `.then` part) |
| `ret` | what the method returns: `RVal(v)` for a value, `RProm` for a promise |
| `out` | the NEAR attached to the new receipts, taken from the contract's balance |
| `ids` | how many fresh receipt ids the handler used |

Here is `ping` next to its Rust:

```rust
ext_worker::ext(worker).work()         // a call to D
    .then(Self::ext(me).done())         // C's own callback, waiting for work's result
```

```tla
\* ping(): D.work().then(C.done()); returns done's result.
H_ping(r) ==
    LET w  == Rcpt(nid, r.tx, D, C, "work", r.a, 0, C, nid + 1)
        cb == Rcpt(nid + 1, r.tx, C, C, "done", r.a, 0, C, r.cb)
    IN Outcome({w}, {cb}, RProm, 0, 2)
```

`Rcpt(id, tx, to, fr, m, a, dep, rto, cb)` builds a receipt. Reading the arguments of `w`:

- `id = nid`: a fresh id. `nid` is the next free receipt id; the handler uses `nid` and
  `nid + 1`, so it reports `ids = 2`.
- `tx = r.tx`: the same transaction as the receipt running now.
- `to = D`, `fr = C`: from C to D.
- `m = "work"`, `a = r.a`: the method and its arguments.
- `dep = 0`: no deposit attached. `rto = C`: refunds would go to C.
- `cb = nid + 1`: **work's result goes to the receipt with id `nid + 1`**, which is `done`.
  This is how `.then` is wired.

The callback `cb` goes in the `post` set, because it waits. Its own `cb` is `r.cb`: `ping`
returns the promise, so whoever waits on `ping` gets `done`'s result. `RProm` says `ping`
returns a promise.

`done` creates nothing and returns nothing (`EMPTY` is "empty bytes"). The decision is in the
state change, which comes next:

```tla
\* done(): count the work only if it succeeded (Trusting: count it anyway).
H_done(r) == Outcome({}, {}, RVal(EMPTY), 0, 0)
NewN(r) == IF Trusting \/ ~IsFailed(r.res) THEN n + 1 ELSE n
```

`r.res` is the promise result the callback sees. `IsFailed(r.res)` is the Rust
`result.is_err()`. The constant `Trusting` switches between the correct contract and the
buggy one, so one model can check both.

Get `ids` right. It must equal the number of fresh ids the handler used. If it is too small,
two receipts end up with the same id, and the model reports violations that are not in the
contract.

## Step 4: run a handler

A handler only describes an outcome. `Exec(r, O)` runs it: the library decides whether the
receipt commits, fails or runs out of gas, and makes the platform changes (creates the
children, moves the deposit, sends the result to a waiting callback, or on failure refunds
and sends Failed). You add the contract's own state change, guarded by `Ok(r, O)`, which is
true when the receipt committed:

```tla
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
```

Two rules:

- Write `Ok(r, O)` in the same step as `Exec(r, O)`, after it. `Ok` reads the step's result.
- On failure, leave your state unchanged. That is NEAR's revert: a failed receipt keeps none
  of its changes.

## Step 5: the dispatcher and the steps

The dispatcher sends each receipt to the code that runs it. Built-in receipts (Transfers,
refunds) go to the library's `ExecBuiltin`; everything else to a contract:

```tla
Step(r) ==
    CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine     \* Transfer, refund, Stake
      [] r.to = D     -> RunD(r)
      [] OTHER        -> RunC(r)
```

A user's transaction is a step too. `Submit` sends U's call to `ping`, with a deposit of 1, as
transaction number `ntx + 1`. `WithGas` attaches prepaid gas from the menu (in fault mode the
menu is just `{0}`):

```tla
Ping ==
    /\ ntx < MaxTx
    /\ \E g \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
         /\ Submit(WithGas(Rcpt(nid, ntx + 1, C, U, "ping", [x |-> 0], 1, U, 0), g))
         /\ gas' = [gas EXCEPT ![ntx + 1] = g]
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<n, works>>
```

`Next` lists everything that can happen: a user pings, some receipt runs, or TLC fails a
receipt on purpose. `Runnable` is the set of receipts that can run now. `ForcedFail(r)` fails
a receipt whose method is in `MayFail`, at most `MaxFails` times; this is how fault mode asks
"what if this call fails?":

```tla
\* Named steps, so a trace says which kind of step each state took.
RunReceipt == \E r \in Runnable : Step(r)
Fault      == \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine

Next == Ping \/ RunReceipt \/ Fault
Spec == Init /\ [][Next]_vars
```

Giving each kind of step a name is optional, but the counterexample then says
`RunReceipt` or `Fault` for each step instead of `Next`.

## Step 6: the runs

`runs.toml`, beside the `.tla` file, says which TLC runs to do. Each run sets constants and
says whether it must pass or must fail:

```toml
spec = "Tally"
workers = 2
budget_s = 60
invariants = ["Counted", "Sane"]
platform_defaults = true        # fill the platform constants this model does not use

[constants]
Accounts = 'Accts'
MayFail = '{}'                  # no forced faults unless a run allows them
MaxFails = '0'
TrackSigner = 'FALSE'           # the model never reads the signer
U = '"u"'
C = '"c"'
D = '"d"'
MaxTx = '2'
InitU = '2'
GasMenu = '{0}'
Trusting = 'FALSE'

# work may fail once; done checks the result, so the counts agree.
[[run]]
name = "tally_ok"
expect = "pass"
[run.constants]
MayFail = '{"work"}'
MaxFails = '1'

# Must fail: done counts without checking, and a failed work is counted.
[[run]]
name = "tally_trusting"
expect = "violation"
invariant = "Counted"
[run.constants]
MayFail = '{"work"}'
MaxFails = '1'
Trusting = 'TRUE'
```

- Constant values are TLA+ expressions in single quotes: `'"u"'` is the string `"u"`.
- `platform_defaults = true` fills the platform constants this model does not use (staking,
  storage, the gas tables, the outcome log) with neutral values. You still set `Accounts`,
  `MayFail` and `MaxFails`, because they define the world and its faults.
- `tally_ok` lets `work` fail once and expects every invariant to hold.
- `tally_trusting` is the buggy contract, and **must** fail `Counted`. A must-fail run shows
  that the invariant can catch the bug it is there for.

[RUNNER.md](RUNNER.md#runstoml) lists every key.

## Step 7: run it and read the counterexample

```sh
python3 tools/run.py examples/minimal tally_ok tally_trusting --print-trace
```

```
run            | expect            | actual            | generated | distinct | depth | secs | result
---------------+-------------------+-------------------+-----------+----------+-------+------+-------
tally_ok       | pass              | pass              | 151       | 86       | 9     | 0.9  | ok
tally_trusting | violation Counted | violation Counted | 22        | 21       | 5     | 0.8  | ok
```

Both runs did what they were expected to do: `tally_ok` passed after exploring 86 distinct
states, and `tally_trusting` violated `Counted`. `ok` in the last column means "as expected".

`--print-trace` prints the counterexample for the failing run as a story, one block per
state:

```
State 1: Initial predicate
    n = 0
    near = [d |-> 0, c |-> 0, u |-> 2]
    ntx = 0
    works = 0
    gas = <<0, 0>>
    (18 platform variables never change here; --raw shows them)
State 2: Ping (Tally:70)
    submitted #1 ping u->c (tx 1, deposit 1, args [x |-> 0])
    near.u: 2 -> 1
    ntx: 0 -> 1
State 3: RunReceipt (Tally:82)
    ran #1 ping u->c: committed
        (tx 1, deposit 1, args [x |-> 0])
    created #2 work c->d (tx 1, result to #3, args [x |-> 0])
    created #3 done c->c (tx 1, args [x |-> 0]) (postponed)
    near.c: 0 -> 1
State 4: Fault (Tally:83)
    ran #2 work c->d: failed (forced fault)
        (tx 1, result to #3, args [x |-> 0])
    data -> #3: Failed
State 5: RunReceipt (Tally:82)
    ran #3 done c->c, seeing Failed: committed
        (tx 1, args [x |-> 0])
    n: 0 -> 1
The model's variables at the last state:
    n = 1
    ntx = 1
    works = 0
    gas = <<0, 0>>
```

Read it as the life of one transaction:

1. U submits `ping` with a deposit of 1. U's balance drops from 2 to 1.
2. `ping` runs and commits: C keeps the deposit, and two receipts appear: `work` for D, whose
   result goes to receipt #3, and `done` (#3), postponed until that result arrives.
3. TLC fails `work` (a forced fault: `work` is in `MayFail`). D's count stays 0. The
   library sends Failed to #3.
4. `done` runs, sees Failed, and commits anyway: the trusting version counts it. `n` becomes 1.

Nothing is in flight now, and `n = 1` while `works = 0`, so `Counted` is false.

That is the bug from [The contract](#the-contract), found by the model. On a real network the
failure would come from `work` panicking or running out of gas. Before you report a
counterexample like this about a real contract, replay it on the compiled code:
[VALIDATING.md](VALIDATING.md) shows how.

## Step 8: make sure a pass means something

`tally_ok` passed. That is only worth something if the run actually reached the situations
the property is about, and if the property would catch a broken contract. A pass can be
**vacuous**: for example, if `work` could never fail in that run, `done` would never see
Failed and `Counted` would pass trivially.

Two checks guard against that. They live in `runs.toml` and run with `--anti-vacuity`.

A **witness** is a situation that must be reachable. The runner asks TLC to find a state where
the expression is false, and fails if none exists:

```toml
# done's failure arm is reached: done runs with a Failed result.
[[witness]]
id = "done_sees_failed"
expr = '~(\E r \in Runnable : r.m = "done" /\ IsFailed(r.res))'
runs = ["tally_ok", "tally_gas_ok"]
```

A **mutant** is a small deliberate bug. The runner patches a copy of the model and runs the
listed passing runs on it; some invariant must fail. If every run still passes, the mutant
"survived", and your properties miss that kind of bug:

```toml
# A dropped .then must be caught (here by NoOrphans, in Sane).
[[mutant]]
id = "dropped_then"
file = "Tally.tla"
find = 'IN Outcome({w}, {cb}, RProm, 0, 2)'
replace = 'IN Outcome({w}, {}, RProm, 0, 2)'
class = "dropped .then"
runs = ["tally_ok"]
```

```sh
python3 tools/run.py examples/minimal --anti-vacuity
```

The example has four witnesses (the system settles, it settles at the maximum gas, `done`
sees success, `done` sees Failed) and four mutants (a dropped `.then`, a failure that is
counted anyway, an inverted result check, swapped gas weights). All are reached or killed.
[RUNNER.md](RUNNER.md#witnesses-and-mutants) explains the conventions.

## Step 9: gas mode

So far TLC failed `work` by fiat. Gas mode asks a sharper question: with how much prepaid gas
does `work` run out?

Gas mode needs two tables. `GasCall` gives each method's static gas and weight, from the
Rust (`with_static_gas`, `with_unused_gas_weight`) and a fee. `GasBurn` gives the gas each
method burns. The numbers below are **illustrative**, not measured; a real model measures
them ([Calibrating](USAGE.md#calibrating)) or uses the host-cost floor
([USAGE section 12](USAGE.md#gas-without-a-calibration-the-host-cost-floor)):

```tla
\* Gas tables (Ggas).  ILLUSTRATIVE numbers, not measured (docs/USAGE.md, Calibrating).
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
TGasCall == ("work" :> GC(<<5000>>, <<1>>, 300))     \* 5 Tgas static + all the leftover
         @@ ("done" :> GC(<<2000>>, <<0>>, 300))     \* 2 Tgas static, no share
TGasBurn == ("ping" :> [base |-> 1000, per |-> 0])
         @@ ("work" :> [base |-> 5500, per |-> 0])
         @@ ("done" :> [base |-> 600,  per |-> 0])
Menu    == {t * 100 : t \in 80..95} \cup {1000000}   \* 8.0-9.5 Tgas by 0.1, and the 1000 Tgas maximum
```

The arithmetic: `ping` needs its own burn (1 Tgas) plus, for each child, the child's fee and
static gas: 0.3 + 5 for `work` and 0.3 + 2 for `done`, 8.6 Tgas in all. Whatever U prepaid
above 8.6 Tgas is the leftover, and all of it goes to `work` (weight 1; `done` has weight 0).
`work` burns 5.5 Tgas but holds 5 Tgas plus the leftover, so it runs out whenever the
leftover is under 0.5 Tgas: for prepaid gas from 8.6 to 9.0 Tgas. Below 8.6 Tgas, `ping`
itself runs out and creates nothing, which is harmless.

The gas runs switch `GasMode` to `"gas"` and give the tables and the menu:

```toml
[[run]]
name = "tally_gas_trusting"
expect = "violation"
invariant = "Counted"
[run.constants]
GasMode = '"gas"'
GasCall = 'TGasCall'
GasBurn = 'TGasBurn'
GasMenu = 'Menu'
MaxTx = '1'
Trusting = 'TRUE'
```

Its trace now says `ran #2 work c->d: out of gas` instead of a forced fault. A third run,
`tally_gas_win`, prints the whole range of prepaid amounts at which `Counted` breaks and checks
it is exactly 8.6-9.0 Tgas ([print-only windows](RUNNER.md#print-only-window-invariants)).

## Step 10: the audit

After the runs, the runner prints an audit: for each method you list, which kinds of failure
the runs actually reached, and which they did not. A callback that completes earlier work
deserves gas-mode runs, a least-gas sweep and its worst-case storage cost; the audit lists
what is missing until each gap is closed by a run or accepted with a reason.

```toml
# C's methods, from the source: the call users make and the callback it schedules.
[audit]
methods = ["ping", "done"]

[audit.accept]
"done trie" = "done writes no storage in this toy (H_done declares no write)"
"done least-gas" = "done's budget is a fixed 2 Tgas against a 0.6 Tgas burn; tally_gas_win maps the prepaid edge"
```

[RUNNER.md](RUNNER.md#auditing-what-the-runs-reach) explains each kind of gap.

## Where to go next

You have written every part of a model: properties, state, handlers, the run step, the
dispatcher, transactions, runs, witnesses, mutants, gas tables and the audit. For your own
contract:

- [USAGE.md](USAGE.md) is the modelling guide: tokens (NEP-141, NEP-245, wNEAR), receiving
  tokens, signers and access keys, local receipts, joint callbacks (`promise_and`), yield and
  resume, storage staking, creating and deleting accounts, and calibrating gas.
- [RUNNER.md](RUNNER.md) is the runner's reference.
- [VALIDATING.md](VALIDATING.md) shows how to replay a counterexample on the compiled contract.
- [SEMANTICS.md](SEMANTICS.md) lists every rule the library encodes and what it leaves out.
- The [`examples/`](../examples/) directory has a model for each feature. Copy the closest one.
- If you use an AI coding agent, the [near-tla skill](../skills/near-tla/SKILL.md) walks it
  through the same method on your contract.
