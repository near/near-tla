# Validating a counterexample

When a run fails, TLC prints a counterexample: a sequence of transactions, receipts and
failures that ends in a state where an invariant is false. This page shows how to confirm or
refute it on the real compiled contract, and how to write it up.

It assumes you can run a model and print its trace; the
[tutorial](TUTORIAL.md#step-7-run-it-and-read-the-counterexample) walks through one. The
running example here is the tutorial's tally contract, modelled in
[`examples/minimal`](../examples/minimal/): a user calls `C.ping()`, `ping` asks D to `work`,
and C's callback `done` counts the work. The buggy `done` counts even when `work` failed.

## Contents

- [Why validate](#why-validate)
- [Step 1: read the trace](#step-1-read-the-trace)
- [Step 2: decide what each failure needs](#step-2-decide-what-each-failure-needs)
- [Step 3: replay it](#step-3-replay-it)
  - [In near-contract-sim](#in-near-contract-sim)
  - [In a local sandbox with near-workspaces](#in-a-local-sandbox-with-near-workspaces)
  - [Without either: by reading the code](#without-either-by-reading-the-code)
- [When it does not reproduce](#when-it-does-not-reproduce)
- [Writing up a finding](#writing-up-a-finding)

## Why validate

A counterexample is a hypothesis about your contract, not yet a finding. The model can be
wrong about it in three ways:

- **The handlers.** They are hand-written abstractions of the contract
  ([N-wasm](SEMANTICS.md#scope-limits)). A handler can take a path the code does not, or miss
  a panic the code has (an overflow, a failed deserialization).
- **The order.** The model has no chunks or shards, so it allows some schedules that no
  network produces ([Over-approximations](SEMANTICS.md#over-approximations)).
- **The gas numbers**, in gas mode. Burn tables are estimates unless they were measured on
  your wasm, and even then they hold only for the paths and sizes measured
  ([Calibrating](USAGE.md#calibrating)).

One thing is **not** a reason to dismiss a trace: two receipts between the same pair of
accounts running in the opposite order to their creation. nearcore does that
([S4](SEMANTICS.md#s4-no-per-pair-order)). The question is whether the trace's particular
schedule is reachable.

To validate a trace, run the same receipt tree, with the same gas and the same failures,
against the compiled contract, and check the same property. There are three ways to do it,
and the first is the default:

| | what runs your wasm | failures | orders |
|---|---|---|---|
| [near-contract-sim](#in-near-contract-sim) | nearcore's runtime, inside a Rust test | injected directly, or by cause | forced by holding receipts |
| [near-workspaces sandbox](#in-a-local-sandbox-with-near-workspaces) | a local nearcore node | by cause: a stub receiver, the prepaid gas, the state | no switch: argued, or provoked by load |
| [code reading](#without-either-by-reading-the-code) | nothing: you walk the source | argued | argued |

## Step 1: read the trace

Print the counterexample with the run:

```sh
python3 tools/run.py <path> <run> --print-trace
```

For a log kept with `--keep` (in `build/` beside the `runs.toml`),
`python3 tools/tlctrace.py <log>` prints the same. [RUNNER.md](RUNNER.md#reading-a-counterexample)
explains every kind of line. Here is `tally_trusting`, from State 2 on (the runner prints it
indented under the run's row in the table, after a `trace:` line):

```
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
Label: forced (the forced-fault switch fired; ask whether the network can cause that failure)
```

The words that matter for a replay:

- `submitted #1 ping u->c` is a new transaction: signer `u` calls `ping` on `c`. `#1` is the
  model's receipt id; on the network a receipt id is a hash.
- `created #2 work c->d` is a receipt that `#1` created. `result to #3` means its result goes
  to receipt `#3`. `(postponed)` marks a callback waiting for its results; a joint callback
  (`promise_and`) or a yield says what it waits for. A joint callback waits for data ids, so
  `result to #5` on a call that feeds one names data id 5, not a receipt.
- `ran #k ...: <outcome>` is a receipt running. The outcome is `committed`,
  `committed (deleted a)` or `committed (created a)`, `failed`, `failed (forced fault)`,
  `failed (deposit refunded)`, `out of gas`, or `burnt (a does not exist; 2 burnt)` for a
  refund to an account that no longer exists
  ([The kinds of line](RUNNER.md#the-kinds-of-line) explains each).
- `seeing X` is the promise result a callback read: for a joint callback, one per input in
  order (`seeing Failed, 1`), and for a yield whose deadline passed, `seeing Failed (timed out)`.
  `data -> #3: X` is a result on its way to receipt `#3`. `X` is `Failed`, a number, or one of
  `EMPTY`, `MAL`, `NONEMPTY`, `NOPR` ([section 7 of USAGE](USAGE.md#7-reading-promise-results)).
- `gas g` on a receipt is its attached gas in Ggas (1 Tgas = 1000 Ggas); on a submitted
  receipt it is the transaction's prepaid gas. Fault-mode traces show none.
- Deposits and balances are in the model's toy units, not yoctoNEAR
  ([Vocabulary](CONCEPTS.md#vocabulary)).
- `Label:` on the last line says what kind of failure the trace needs: `forced` (a forced
  fault fired), `caller-gas` (a receipt ran out of gas at the prepaid amount chosen) or
  `no-fault` (neither). [Step 2](#step-2-decide-what-each-failure-needs) says what each needs.

Now turn the story into a list. Write down every transaction, every receipt, every failure,
and every place where the order was a choice:

```
Transactions:  1. u calls c.ping, deposit 1 (any deposit ping accepts), prepaid gas not modelled (fault mode)
Receipts:      #1 ping on c; #2 work on d, result to #3; #3 done on c, the callback
Failures:      #2 work fails (forced fault)
Order:         none chosen: #1 creates #2 and #3, and #3 waits for #2's result
Property:      Counted (n = works once nothing is in flight): n = 1, works = 0
```

The order line is the one people skip. The trace itself fixes the order of two receipts when:

- one created the other, directly or through other receipts;
- one waits for the other's result;
- one belongs to a transaction sent after the other ran (its user can wait for that).

The model chose every other order, such as two children of one receipt, or the receipts of two
transactions in flight together. The replay must reach that order, or you must argue that it
is reachable.

## Step 2: decide what each failure needs

On a real network nothing fails "because the model said so". Each failure in the trace needs
a cause the replay can produce, and you name that cause before you build the replay.

The sim can force a failure directly, with an injected fault, and both the sim and the sandbox
can deploy a **stub**, a small contract, in place of another. Use either only where you have
named a cause. A stub may stand in only for a *receiver* that can really fail, or answer that
way, on the network: an untrusted token, a callee that panics on some input or state. Never
stub the contract under test: its own code must run as compiled. With no real-network cause,
the trace does not reproduce, and a fault or a stub would only make it look as if it did.

- **`failed (forced fault)`.** The forced-fault switch fired: the method is in `MayFail`, and
  TLC failed it without a reason ([F1](SEMANTICS.md#f1-forced-fault-switch-versus-gas-mode)).
  Find a cause on real wasm:
  - a receiver that can panic on the network: put the real receiver in a state where it
    panics (an unregistered account, a balance too low), or, if it is a contract you do not
    control, deploy a stub in its place that panics, and say why the real one can;
  - a prepaid gas at which it runs out: possible only if the receipt's gas depends on the
    prepaid amount (it gets a weighted share of its creator's leftover,
    [G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)) or its burn grows with
    an input a user picks;
  - a state that fails an action: a missing receiver account
    ([A4](SEMANTICS.md#a4-transfer-to-a-missing-named-account-fails-and-refunds),
    [A5](SEMANTICS.md#a5-function-call-to-an-account-without-code-fails)), a balance that no
    longer covers storage ([B2](SEMANTICS.md#b2-balance-must-cover-storage-lackbalanceforstate)).

  If no cause exists, the trace does not reproduce as it stands
  ([When it does not reproduce](#when-it-does-not-reproduce)).
- **`out of gas`.** A gas-mode failure: the receipt's need exceeded its attached gas.
  Reproduce it with the transaction's prepaid gas, the `gas` on the `submitted` line, not with
  a fault. The story cannot always tell a second out-of-gas of the same method in the same
  transaction from a plain failure, and then says `(or out of gas again: ...)`.
- **`failed` or `failed (deposit refunded)`.** The handler panicked (`OErr`), an action failed,
  or a host limit was hit. Reproduce it with the same arguments and state.
- **`committed (deleted a)`, `committed (created a)` and `burnt (...)`.** Not failures, so they
  need no cause: an account action committed, or a refund reached an account that no longer
  exists (usually one a `DeleteAccount` earlier in the trace removed) and was burnt. Replay
  those steps as they are.
- **A receiver's answer the model chose.** A callback `seeing` a number, `EMPTY`, `MAL` or
  `NONEMPTY` from a receiver the model lets answer anything (for example through
  `RecvOutcome`). If the real receiver can answer with those bytes, reproduce it with a stub
  receiver that returns them.
- **An order the model chose.** A trace with no failure at all needs only an order. Force the
  order in the sim, and argue from nearcore's rules that a network can produce it
  ([Force an order](#force-an-order)).

The trace's last line, `Label: ...`, gives the library's label for the whole trace: `forced`
if any forced fault fired, else `caller-gas` if a receipt ran out of gas, else `no-fault`
([section 13 of USAGE](USAGE.md#13-the-forced-fault-switch-and-labels)). A trace can hold
failures of several kinds, so go through each failure line, not only the label.

If the failed receipt is marked owed or detached, the library records the failure in its
variable `ofail`, with the cause (`why`) and, for out of gas, the gas the receipt had (`g`) and
needed (`need`) ([Owed callbacks and detached work](USAGE.md#owed-callbacks-and-detached-work)).

## Step 3: replay it

Replay in near-contract-sim when you can. It runs your compiled wasm on nearcore's own
runtime, injects the trace's failures directly, and forces its orders by holding receipts
back. The near-workspaces sandbox is the alternative: a real local node, with no fault
injection and no way to force an order. Without either, walk the trace through the source.

Whatever forces a failure or an order in a replay, the cause is still yours to name. An
injected fault needs the real-network cause from
[Step 2](#step-2-decide-what-each-failure-needs). A forced order needs the argument from
SEMANTICS S1-S5 that a network can produce it ([Force an order](#force-an-order)). A replay
that cannot force the trace's order, as in the sandbox, confirms its failures only, and the
write-up says so.

### In near-contract-sim

[near-contract-sim](https://github.com/near/near-contract-sim) runs a contract's wasm inside
`cargo test`, on nearcore's `Runtime::apply` over an in-memory chain. Every receipt, callback
and refund runs, with a node's gas. Its release v0.1.0 pins nearcore 2.14.0 (protocol 88), the
revision this library encodes ([Reference revision](SEMANTICS.md#reference-revision)). On top
of that it can fail any receipt a transaction spawns, make a callee answer as the test says,
and hold a receipt back so that others overtake it.

Its guides are an agent skill in its repository,
[skills/near-contract-sim](https://github.com/near/near-contract-sim/tree/v0.1.0/skills/near-contract-sim),
and its API is in rustdoc. This section shows what a replay needs, and links the guide page
for each part.

#### Set up the test crate

Put the replay in a crate of its own beside the contract's, since the contract's crate builds
for wasm32. The sim is not on crates.io. It is a git dependency, pinned by tag:

```toml
[dev-dependencies]
near-contract-sim = { git = "https://github.com/near/near-contract-sim", tag = "v0.1.0" }
serde_json = "1"
borsh = { version = "1", features = ["derive"] }   # only for typed contract state

[profile.dev.package."*"]
opt-level = 2   # nearcore is slow unoptimized
debug = false
```

The crate's `rust-toolchain.toml` pins `channel = "1.95.0"`, the Rust version nearcore 2.14
requires. Its `.cargo/config.toml` caps the test threads with `RUST_TEST_THREADS = "4"` under
`[env]`, since nearcore's VM allows 1000 wasm instances per process. Commit the crate's
`Cargo.lock`, so that a rerun builds the same nearcore. The first build compiles nearcore: 10
to 30 minutes and several GB, with a C/C++ compiler, libclang, perl and make installed. Build
the contract's wasm as you deploy it and copy it to the test crate's `tests/res/`, or build it
in the test. The sim's
[quickstart](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/quickstart.md)
has the layout, the system packages and both ways to build the wasm.

#### The sim replay of `tally_trusting`

The test below replays the trace from [Step 1](#step-1-read-the-trace). `tests/res/tally.wasm`
is C compiled, with an init method `new(worker)` and a view method `count` that returns `n`.
`tests/res/worker.wasm` is D, the tutorial's worker, with a view method `works` that returns
its count. Use your contracts' own names. Any account id works in the sim, so the model's `c`,
`d` and `u` become made-up ids.

```rust
use near_contract_sim::prelude::*;
use serde_json::json;

const C: &str = "c.test.near"; // the tally contract
const D: &str = "d.test.near"; // the worker it calls
const U: &str = "u.test.near"; // a user

fn wasm(name: &str) -> Vec<u8> {
    let path = format!("{}/tests/res/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// The model's Init: u, d running the worker, and c initialised on d.
fn world() -> Sim {
    Fixture::new()
        .account(U, Balance::from_near(10))
        .contract(D, wasm("worker.wasm"))
        .contract(C, wasm("tally.wasm"))
        .init("new")
        .args_json(json!({ "worker": D }))
        .build()
}

/// A `u64` view.
fn view(sim: &Sim, id: &str, method: &str) -> u64 {
    sim.view(id, method, ()).json()
}

/// u's call to `ping`, as the trace's `submitted` line has it.
fn ping(sim: &mut Sim) -> Tx<'_> {
    sim.call(U, C, "ping").deposit(Balance::from_yoctonear(1))
}

#[test]
fn replay_tally_trusting() {
    let mut sim = world();

    // State 2: u submits ping with a deposit. State 4: d's work fails (forced fault).
    let out = ping(&mut sim).inject(Receipts::call(D, "work"), Fault::OutOfGas).transact();

    // The fault landed on work, and done ran after it (State 5).
    assert_eq!(out.expect_receipt("work").fault, Some(Fault::OutOfGas), "{out}");
    assert!(out.expect_receipt("done").is_success(), "{out}");

    // The property: Counted, n = works once nothing is in flight.
    let (n, works) = (view(&sim, C, "count"), view(&sim, D, "works"));
    assert_eq!(n, works, "Counted is false: n = {n}, works = {works}\n{out}");
    sim.findings().assert_none();
}
```

The test asserts the model's property, so it fails while the bug is there. On the buggy
`done` it fails at the last assertion, with the state the trace ends in (the gas table that
follows the tree is cut here):

```
assertion `left == right` failed: Counted is false: n = 1, works = 0
tx 2gEtkq… signed by u.test.near at #7 (conversion 0.31 Tgas) -> SUCCESS
└─ #8 c.test.near::ping  attached 300.00 Tgas, burnt 1.91 Tgas (1.03 + 0.89 exec fees), headroom 295.20 Tgas  ok (returns a promise)
   ├─ #9 d.test.near::work [fault: OutOfGas]  attached 0.00 Tgas, burnt 0.89 Tgas (0.00 + 0.89 exec fees)  FAILED: out of gas (Exceeded the prepaid gas)
   └─ #10 c.test.near::done [callback of d.test.near::work]  attached 2.00 Tgas, burnt 1.19 Tgas (0.31 + 0.89 exec fees), headroom 1.69 Tgas  ok
(3 refund receipt(s) not shown)
```

With the correct `done` the same test passes. Keep it: it is the finding's regression test.
The snippets in the rest of this section go in tests like this one, after
`let mut sim = world();`, unless they set up their own `Sim`.

Notes on each part:

- **The fault.** [Step 2](#step-2-decide-what-each-failure-needs) names the cause first:
  `work` can panic, and its gas is 5 Tgas plus a share of what `ping` leaves. Then
  `tx.inject(Receipts::call(D, "work"), Fault::OutOfGas)` fails that call. It runs with 1 gas
  and fails at load, before its code changes anything, as the model's forced fault does. A
  selector that matches no receipt changes nothing, so assert that the fault landed: `fault`
  on the receipt (`held` for a hold).
- **Other forced faults.** `Fault::PromiseFailed` on a callback (`Receipts::callback("done")`)
  fails every call the callback waits on, and the callback reads `Failed`. Repeated calls of
  one method are told apart with `Receipts::occurrence(receiver, m, k)` or `.nth(k)`. The
  sim's
  [faults page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/faults.md)
  lists every fault and selector, and which faults a network can cause.
- **The property is yours to assert.** `sim.findings()` runs the sim's built-in checks: a
  failure nobody learned of, a failed callback, NEAR created or destroyed. They all pass on
  the buggy `done`, because `work`'s failure reaches `done` and `done` commits. Write each
  property of the model as an assertion.
- **Accounts.** `Fixture` writes the setup as data and builds it once per test binary; each
  test gets its own copy. Its `init` is signed by the contract itself. Any id works without a
  parent account. If your contract checks account ids (an owner, an allowed token), use the
  ids it expects.
- **Transactions.** Each `submitted` line (a `Submit`, `SubmitAs` or `SubmitSigned` step) is
  one `sim.call(signer, receiver, method)` with `.args_json(..)` and `.deposit(..)`. Use the
  deposit your contract expects, not the model's toy number. If the model pinned the prepaid
  gas (`WithGas(r, p)`), pin it with `.gas(..)`
  ([below](#pin-the-prepaid-gas-and-find-the-edge)). Without `.gas(..)` a call attaches 300
  Tgas, as wallets do, which suits a fault-mode trace.
- **Receipts.** Each model receipt is a sim receipt with the same receiver and method, and its
  outcome names that method.

#### Read the sim's outcome

`transact()` produces blocks until every receipt of the transaction has run, refunds
included, and returns a `TxOutcome`. Printing it (`{out}`) draws the receipt tree above: each
receipt's gas, status and logs, and any fault forced on it, then a gas table. To check it in
code:

- `out.is_success()` is the transaction's status. It follows the value the transaction
  returns, not every receipt: `ping` returns the promise that ends in `done`, so the
  transaction succeeds although `work` failed. Check each receipt.
- `out.receipts` has every receipt in the order they ran, refunds included. Each
  `ReceiptOutcome` has `receiver_id`, `method_names`, `block_height`, `attached_gas`,
  `gas_burnt`, `logs`, `is_success()` and `failure()`, and what the test forced on it: `fault`
  and `held`. `out.receipt(m)` is the first receipt that ran method `m`, and
  `out.expect_receipt(m)` panics with the tree if none did.
- `out.value()` is the transaction's return value, `out.failure()` why it failed
  (`Failure::OutOfGas`, `Failure::Panic(msg)`, ...), and `out.effects()` who paid whom, in
  NEAR and in the tokens you watch.
- Views read state afterwards: `sim.view(id, method, args).json()`.

A yield's callback is the exception to "every receipt": [Time out a yield](#time-out-a-yield).
The sim's
[outcomes page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/outcomes-and-effects.md)
has the rest.

#### Fail a receiver, or make it answer

An injected fault fails a call whatever its code does. A stub replaces the receiver's code, so
the failure or the answer comes from the receiver itself. Use a stub for a receiver that
really answers that way on the network, never for the contract under test
([Step 2](#step-2-decide-what-each-failure-needs)). `sim.deploy_stub(id, stub)` deploys it in
the receiver's place. In the replay above, instead of the fault:

```rust
sim.deploy_stub(D, Stub::new().on("work", Reply::panic("stub: work fails on purpose")));
let out = ping(&mut sim).transact();

// The stub keeps no count: d's works are the calls it received that succeeded.
let calls = sim.calls_to(D);
assert!(calls.len() == 1 && !calls[0].succeeded, "{out}");
let works = calls.iter().filter(|c| c.succeeded).count() as u64;
assert_eq!(view(&sim, C, "count"), works, "Counted is false\n{out}");
```

This fails on the buggy `done` too. `sim.calls_to(id)` lists every function call an account
received, failed ones included, with its method, arguments, deposit and gas. Choose the stub's
`Reply` from the result the trace's callback saw
([section 7 of USAGE](USAGE.md#7-reading-promise-results)):

| the callback sees | the stub's reply | `work` returns |
|---|---|---|
| `Failed` | `Reply::panic(msg)` | nothing: it panics |
| a number, say 7, read as a `U128` | `Reply::json("7")` | `"7"` (near-sdk's `U128` is a JSON string) |
| `EMPTY` | `Reply::json(())` | empty bytes |
| `MAL`, bytes the reader cannot parse | `Reply::bytes("oops")` where a number is expected | `oops` |
| `NONEMPTY`, other bytes | `Reply::json(None::<u8>)` | `null` |

A stub answers only the methods it declares. A call to any other fails, as on chain. To change
only the result a callback reads, and leave the callee's effects standing, put
`Fault::ReturnValue(bytes)` on the callback instead: a forced answer, for a callee that is
untrusted or can be upgraded. The sim's
[stubs page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/stubs.md)
has the rest: logs, gas burns, and a stub that calls back into the contract.

#### Pin the prepaid gas, and find the edge

Gas-mode traces carry the prepaid gas. `tally_gas_trusting` submits with 8600 Ggas, and
`work` runs out:

```
State 2: Ping (Tally:70)
    submitted #1 ping u->c (tx 1, deposit 1, gas 8600, args [x |-> 0])
...
State 4: RunReceipt (Tally:82)
    ran #2 work c->d: out of gas
        (tx 1, gas 5000, result to #3, args [x |-> 0])
```

The model's `p` Ggas is `Gas::from_gigagas(p)`, or `Gas::from_teragas(p / 1000)` when `p` is
whole Tgas:

```rust
let p: u64 = 8_600; // Ggas, from the trace's `submitted` line
let out = ping(&mut sim).gas(Gas::from_gigagas(p)).transact();
```

You set only the transaction's prepaid gas. A child's attached gas (the `gas 5000` on `work`)
follows from it: the static gas the code attaches plus a weighted share of what the creator
leaves ([G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)), and the
creator's real burn decides that share. The receipt tree shows what each child got.

A gas-mode trace is only as good as its burn table, and the tally example's burns are
illustrative. On a build of the tutorial's contracts (near-sdk 5.29.1, Rust 1.95.0, release
profile), `ping` itself runs out at 8600 Ggas:
its own burn, the 7 Tgas of static gas it attaches and the exec fees it prepays for its two
calls come to about 9.8 Tgas. Two tools find the real edges:

- `least_gas` bisects, on copies of the sim, for the least prepaid gas at which the
  transaction succeeds:

  ```rust
  let least = ping(&mut sim).least_gas().expect("it succeeds at the most");
  ```

  The transaction's result is `done`'s, which succeeds whether `work` committed or failed. So
  this is the least gas at which `ping` makes its calls, not the gas at which `work` runs out.
- `gas_edges` splits a range of prepaid gas into regions where a key of the outcome is the
  same, and bisects each edge to 1 gas. Key it on the receipt that fails in the trace:

  ```rust
  let regions = ping(&mut sim).gas_edges(
      Gas::from_teragas(1)..=Gas::from_teragas(300),
      Gas::from_teragas(1),
      |out| out.receipt("work").map(|w| w.is_success()), // None: work never ran
  );
  for r in &regions {
      println!("{:?} gas: {:?}", r.range, r.key);
  }
  ```

On that build `gas_edges` finds two regions: `None` below about 9.8 Tgas, where `ping` runs
out, and `Some(true)` above it. `work` always gets at least its 5 Tgas of static gas, and burns
about 0.2 Tgas of it. So `work` never runs out, and the gas-mode trace does not reproduce: the
burn table was wrong for this path ([When it does not reproduce](#when-it-does-not-reproduce)).
`Fault::Gas(g)` runs one call with `g` gas instead. That is a forced fault: use it only where a
caller can attach that little, or the contract forwards a share that small. The sim's
[transactions page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/transactions.md)
covers gas.

#### Arrange state

The trace starts from the model's `Init` and builds the rest with transactions. Prefer the
same: make the calls a user would make (register, deposit) before the trace's transactions, in
the `Fixture` or in the test. When that is slow or impossible, write state directly:

- `sim.update_contract_state::<T>(id, |s| ..)` edits a near-sdk contract's root struct, read
  as a type of the test's own with the contract's fields in order, and
  `sim.contract_state::<T>(id)` reads it. For C, with this mirror of its struct:

  ```rust
  use borsh::{BorshDeserialize, BorshSerialize};

  /// C's root struct, its fields in order.
  #[derive(BorshSerialize, BorshDeserialize)]
  struct TallyState {
      worker: String,
      n: u64,
  }
  ```

  a test writes `n` and reads it back through the contract:

  ```rust
  sim.update_contract_state::<TallyState>(C, |s| s.n = 41);
  assert_eq!(view(&sim, C, "count"), 41);
  ```
- `sim.set_state(id, key, value)` writes one storage key and keeps the account's
  `storage_usage` right. A collection keeps each entry under its prefix and the entry's
  borsh-encoded key, which `key::borsh(prefix, &k)` builds. `sim.apply_state_records(records)`
  writes nearcore `StateRecord`s, as a state dump holds them.
- To replay against the deployed build, deploy its bytes with `sim.deploy(id, wasm)` (the RPC
  query `view_code` returns them), and assert their hash.

The sim's
[sim page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/sim.md)
shows how to mirror each near-sdk collection. A patched state must be one users can reach
through the contract's methods. Otherwise the replay shows a state no one can arrange, and
proves nothing.

#### Time out a yield

A yield times out from 200 blocks after the block that created it
([C7](SEMANTICS.md#c7-yield-and-resume-nep-519)). In the sim, blocks happen only when the test
asks, so a test reaches any height at once. `transact()` returns with the yield's callback
parked. `sim.yields()` lists each parked yield with `expires_at`, the height at which its
timeout fires, and `sim.expire(&y)` advances there, settles and returns the transaction's
outcome. With a contract at C whose `request` yields to a callback that returns `"timeout"`
when it reads `Failed`:

```rust
let mut sim = Sim::new();
sim.create_account(U, Balance::from_near(10));
sim.deploy(C, wasm("yielder.wasm")); // request yields; its callback returns "timeout" on Failed
let out = sim.call(U, C, "request").transact(); // returns with the yield parked
assert!(!out.is_complete(), "{out}");
let [y] = <[_; 1]>::try_from(sim.yields()).expect("one parked yield");
let out = sim.expire(&y); // advances to y.expires_at, settles, returns the outcome
assert_eq!(out.json::<String>(), "timeout", "{out}");
```

In that run the yield was created in block 4, `expires_at` was 204, and the callback ran in
block 205. `sim.advance_to(h)` moves to any later height. To race a resume against the
timeout, play each side from a clone of the `Sim`; the sim's
[blocks and clock page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/blocks-and-clock.md)
shows how, and which side wins at the edge.

#### Force an order

Where the trace chose an order (the order line of your list from Step 1), hold receipts back
so that the others overtake them:

- `Fault::Hold(n)`: the receipt leaves `n` blocks late;
- `Fault::HoldResult(n)`: its result reaches the callback `n` blocks late;
- `Fault::HoldUntil(receipts)`: it leaves after the receipt that `receipts` names has run.

`transact()` runs until everything settles, held receipts included. To put a second
transaction in the gap, `submit()` the first, `run_until` the hold is in place, then send the
second. The tally trace chose no order. With two pings (`MaxTx = 2`), a trace that runs
transaction 2's `work` before transaction 1's replays as:

```rust
// tx 1's work leaves 5 blocks late; tx 2 runs meanwhile.
let first = ping(&mut sim).inject(Receipts::call(D, "work"), Fault::Hold(5)).submit();
sim.run_until(10, |s| s.outcome(first).receipt("ping").is_some()).unwrap();
let second = ping(&mut sim).transact(); // settles the held one too
let first = sim.outcome(first);
let (w1, w2) = (first.expect_receipt("work"), second.expect_receipt("work"));
assert_eq!(w1.held, Some(5), "{first}");
assert!(w2.block_height < w1.block_height, "tx 2's work ran first\n{first}\n{second}");
```

A hold shows that the order happens on nearcore's runtime. It does not show that a network
delays the receipt that long: a hold has no cause of its own. The sim also has one shard, and
a hold cannot reach a transaction's first receipt, a gas refund, a yield's callback or the
resume that wakes it (the sim's
[fidelity page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/fidelity.md)).
So for every order the trace chose, forced or not, argue from nearcore's rules and the
contract's code that a network can produce it, and write the argument down:

- [S1](SEMANTICS.md#s1-local-receipts-first-the-exact-rule): a transaction's first receipt is
  local when its receiver is its signer, and runs in the same chunk before delayed and incoming
  receipts, unless the chunk is full. Receipts created by a receipt (self-calls, callbacks,
  refunds) are never local.
- [S2](SEMANTICS.md#s2-ordering-otherwise): a chunk runs local receipts, then the delayed
  queue, then incoming receipts, then yield timeouts. Receipts in one receipt proof (one
  source chunk to one destination shard) keep their order.
- [S3](SEMANTICS.md#s3-block-clock): a receipt created by a receipt runs in a later block,
  except instant receipts.
- [S4](SEMANTICS.md#s4-no-per-pair-order): there is no per-pair order. A later, smaller
  receipt can overtake an earlier one waiting in the outgoing buffer (the earlier one must not
  fit the link's remaining gas or size limits), and after missed chunks receipts from a newer
  block run first.
- [S5](SEMANTICS.md#s5-instant-receipts): a lone `DeleteAccount` created by a receipt runs
  right after it, with nothing in between.

If the trace runs a non-local receipt to an account while a local receipt to that account is
pending, it uses an order `LocalPriorityOK` forbids. nearcore produces that order when the
receiving chunk is full (S1), so the violation is real unless you can show the receiving shard
is never at its limit ([section 11 of USAGE](USAGE.md#11-local-receipt-priority)).

#### Measure burns in the sim

The sim's gas is nearcore's, receipt by receipt, so a sim run measures your contract's burns
for gas mode. For a table you rely on, use the `calibrate` tool. It runs your wasm in the sim
over a grid of prepaid gas, checks that nearcore's leftover split reproduces from the static
gas and weights you declare, and writes the TLA+ table with its provenance
([Calibrating](USAGE.md#calibrating)). For a first look, read the receipts of one run:

```rust
let out = ping(&mut sim).transact();
for r in out.receipts.iter().filter(|r| !r.is_refund()) {
    let burn = r.gas_burnt.as_gas() - r.prepaid_exec_fees.as_gas();
    println!("{} {:?}: burnt {burn} gas besides its exec fees", r.receiver_id, r.method_names);
}
```

`gas_burnt` is everything a receipt burnt, and `prepaid_exec_fees` is the part its creator
prepaid: the receipt's own exec fees. A `GasBurn` entry is `gas_burnt` minus those fees minus
the send fees of the action-only children the receipt created, in Ggas, rounded up
([Calibrating your own contract](../conformance/README.md#calibrating-your-own-contract),
step 2; the fees are in `modules/NearFees.tla`). On the build above `work` burns about 174
Ggas besides its fees, against the example table's 5500. Burns grow with storage reads and
writes, so give the contract realistic state first, and measure at a prepaid gas where the
receipt succeeds. `r.headroom()` is the attached gas a successful receipt left unused, and
`out.assert_headroom(method, min)` asserts a fixed-budget callback's margin. None of the
calibrator's checks run on a hand measurement; [Calibrating](USAGE.md#calibrating) says how to
treat such tables.

### In a local sandbox with near-workspaces

[near-workspaces](https://github.com/near/near-workspaces-rs) (Rust) starts a local nearcore
node, the sandbox, deploys your compiled wasm to it, and sends real transactions. It has no
fault injection and no way to hold a receipt. Each failure needs a cause you build (a stub
receiver, the prepaid gas, the state), and every order the trace chose is argued
([What the sandbox cannot do](#what-the-sandbox-cannot-do-force-an-order)). Prefer it to the
sim when:

- the project already tests with near-workspaces, and the replay belongs beside those tests;
- you want the check on a real node. The sim matches a nearcore 2.14.0 sandbox receipt by
  receipt (its
  [fidelity page](https://github.com/near/near-contract-sim/blob/v0.1.0/skills/near-contract-sim/references/fidelity.md)),
  but runs one shard, in process;
- you want the deployed contract with its state: `import_contract` copies both from testnet
  or mainnet ([Set up state](#set-up-state)).

The sandbox runs on macOS (Intel and Apple silicon) and on x86-64 Linux.

The model encodes nearcore 2.14 (protocol 88, nearcore 2.14.0;
[Reference revision](SEMANTICS.md#reference-revision)). near-workspaces 0.24 runs a
nearcore 2.14 sandbox; 0.23 has the same API but runs nearcore 2.13. Record what the sandbox
ran: `worker.status().await?` returns the node's version and protocol version.

Put the replay in an integration test of your contract's crate:

```toml
[dev-dependencies]
near-workspaces = "0.24"          # runs a nearcore 2.14 sandbox
tokio = { version = "1", features = ["full"] }
serde_json = "1"
anyhow = "1"
```

#### The sandbox replay of `tally_trusting`

The test below replays the trace from [Step 1](#step-1-read-the-trace) with a stub in D's
place, since the sandbox cannot inject the fault. `res/tally.wasm` is C compiled, as in the
sim replay, and `res/stub.wasm` the stub from
[Make a receiver fail or answer](#make-a-receiver-fail-or-answer).

```rust
use near_workspaces::types::{Gas, NearToken};
use serde_json::json;

#[tokio::test]
async fn replay_tally_trusting() -> anyhow::Result<()> {
    let worker = near_workspaces::sandbox().await?;

    // The model's accounts: c (the contract), d (the worker it calls), u (a user).
    let c = worker.dev_deploy(&std::fs::read("res/tally.wasm")?).await?;
    let d = worker.dev_deploy(&std::fs::read("res/stub.wasm")?).await?; // work() panics
    let u = worker.dev_create_account().await?;

    c.call("new")
        .args_json(json!({ "worker": d.id() }))
        .transact()
        .await?
        .into_result()?;

    // State 2: u submits ping with a deposit. A fault-mode trace has no prepaid gas,
    // so give enough that nothing runs out by accident.
    let outcome = u
        .call(c.id(), "ping")
        .deposit(NearToken::from_yoctonear(1))
        .gas(Gas::from_tgas(300))
        .transact()
        .await?;

    // Every receipt of the transaction: where it ran, how it ended, what it burnt.
    for o in outcome.receipt_outcomes() {
        println!(
            "{}: success {}, burnt {} gas, logs {:?}",
            o.executor_id, o.is_success(), o.gas_burnt.as_gas(), o.logs
        );
    }

    // State 4: d's work failed.
    assert!(outcome.receipt_failures().iter().any(|o| &o.executor_id == d.id()));

    // State 5: done ran and counted it. n = 1 while d did no work: Counted is false.
    let n: u64 = c.view("count").await?.json()?;
    assert_eq!(n, 1, "done counted a work that failed");
    Ok(())
}
```

This test asserts the bug itself (`n = 1`), so it passes while the bug is there. To keep it as
a regression test, assert the property instead, as the sim replay does: here, `n = 0`, since
the stub's `work` never succeeds.

Notes on each part:

- **Accounts.** `dev_deploy` and `dev_create_account` make accounts with random names under
  the sandbox's root account. If your contract checks account ids (an owner, an allowed
  token), create named ones: `worker.root_account()?.create_subaccount("alice")` with
  `.initial_balance(..)` and `.transact().await?.into_result()?` gives `alice.<root>`;
  `.deploy(&wasm)` on an account deploys code to it. `worker.create_tla(id, key)` creates a
  top-level account.
- **Transactions.** Each `submitted` line is one call:
  `user.call(contract.id(), "method").args_json(json!({..})).deposit(..).gas(..).transact()`.
  Use the deposit your contract expects, not the model's toy number.
- **Prepaid gas.** Without `.gas(..)` a call gets 10 Tgas, a different transaction from the
  trace's. `.max_gas()` attaches 1000 Tgas.
- **Balances.** A balance read straight after `transact()` with `.max_gas()` has been seen to
  disagree with the transfers the call made, by far more than the gas cost; the cause was not
  isolated. Compare the contract's own state (its ledger, its counts) where you can. To compare
  NEAR balances, attach only the gas the trace needs, `worker.fast_forward(5)` before reading,
  and allow for the gas the signer paid.

#### Read the outcome

`transact()` waits until every receipt of the transaction has run, and returns an
`ExecutionFinalResult`:

- `is_success()` is the transaction's status, which follows the value the transaction returns,
  as in the sim. Check each receipt.
- `receipt_outcomes()` has one `ExecutionOutcome` per receipt: `executor_id` (the account it
  ran on), `gas_burnt`, `logs`, `receipt_ids` (the receipts it created), `block_hash`, and its
  own `is_success()` / `is_failure()`. `o.clone().into_result()` gives its error; for out of
  gas the cause is nearcore's `GasExceeded` ([G1](SEMANTICS.md#g1-prepaid-gas)). The list can
  include refund receipts, which the model shows only for deposits (`REFUND`).
- `receipt_failures()` lists only the failed receipts, and `logs()` every log line.
- Views read state afterwards: `contract.view("m").args_json(json!({..})).await?.json()?`.

An outcome does not name its method. Match outcomes to the model's receipts by `executor_id`,
by the logs each method writes, and by the tree: `receipt_ids` names an outcome's children,
and for a receipt outcome the field `transaction_hash` holds the receipt's own id
(near-workspaces fills it from the outcome's id). `worker.receipt(..)` fetches a receipt by
that id (its argument is near-jsonrpc-primitives' `ReceiptReference`) with its actions: method
name, arguments, attached gas and deposit.

Do not read the list's order as the order the receipts ran in. To compare, look up each
outcome's block: `worker.view_block().block_hash(o.block_hash).await?.height()`.

#### Make a receiver fail or answer

near-workspaces has no fault injection. To make a receiver fail, or return a chosen value,
deploy a small stub contract in its place, but only for a receiver that can really fail or
answer that way on the network, never for the contract under test
([Step 2](#step-2-decide-what-each-failure-needs)).

This stub, in near-sdk 5, panics in `work` by default, and returns bytes you choose once
`set_answer` is called:

```rust
use near_sdk::{env, near};

#[near(contract_state)]
#[derive(Default)]
pub struct Stub {
    answer: Option<String>, // None: work panics
}

#[near]
impl Stub {
    pub fn set_answer(&mut self, answer: Option<String>) {
        self.answer = answer;
    }

    pub fn work(&mut self) {
        match &self.answer {
            Some(answer) => env::value_return(answer.as_bytes()),
            None => env::panic_str("stub: work fails on purpose"),
        }
    }
}
```

Build it like any contract and `dev_deploy` it where the trace's receiver was. Then choose
what `work` does from the result the trace's callback saw
([section 7 of USAGE](USAGE.md#7-reading-promise-results)), for example
`d.call("set_answer").args_json(json!({ "answer": "\"7\"" })).transact().await?`:

| the callback sees | `work` returns | `"answer"` in `set_answer`'s JSON |
|---|---|---|
| `Failed` | nothing: it panics | `null` (the default) |
| a number, say 7, read as a `U128` | `"7"` (near-sdk's `U128` is a JSON string) | `"\"7\""` |
| `EMPTY` | empty bytes | `""` |
| `MAL`, bytes the reader cannot parse | `"oops"` where a number is expected | `"\"oops\""` |
| `NONEMPTY`, other bytes | the bytes `null`, `true` or an object | `"null"` |

Two details make a stub fail for the wrong reason. A method with parameters must accept the
arguments the contract sends; one without parameters ignores them. And a method that receives
a deposit must be `#[payable]`, or near-sdk rejects the deposit.

#### Pin the prepaid gas from a gas-mode trace

Take the prepaid gas from the trace's `submitted` line, as in the sim
([Pin the prepaid gas, and find the edge](#pin-the-prepaid-gas-and-find-the-edge) shows
`tally_gas_trusting`'s). The model's `p` Ggas is `p × 10^9` gas. near-workspaces' `Gas` is
near-gas's `NearGas` (`near_workspaces::types::Gas`), not the sim's type, so its constructors
are `from_gas`, `from_ggas` and `from_tgas`:

```rust
let p: u64 = 8_600; // Ggas, from the trace
let outcome = u
    .call(c.id(), "ping")
    .deposit(NearToken::from_yoctonear(1))
    .gas(Gas::from_gas(p * 1_000_000_000)) // or Gas::from_ggas(p)
    .transact()
    .await?;
```

A child's attached gas follows from the prepaid gas, as in the sim; `worker.receipt(..)` shows
what the child got. If the receipt does not run out at the trace's amount, the sandbox has no
`gas_edges`: lower the prepaid gas step by step (or bisect) and watch that receipt's outcome.

#### Set up state

The trace starts from the model's `Init` and builds the rest with transactions. Prefer the
same: make the calls a user would make (register, deposit) before the trace's transactions.
When that is slow or impossible, write state directly:

- `worker.patch_state(contract.id(), key, value)` writes one storage key. near-sdk keeps a
  contract's top-level struct borsh-encoded under the key `STATE`, so
  `patch_state(c.id(), b"STATE", &borsh::to_vec(&state)?)` replaces it. Collections keep their
  entries under their own prefixes.
- `worker.patch(contract.id())` patches several things in one go: `.account(..)` (balance,
  storage), `.code(..)`, `.access_key(..)`, `.state(key, value)`, then `.transact().await?`.
- `worker.import_contract(&id, &other_worker)` copies a deployed contract's code from another
  network (a testnet or mainnet worker) into the sandbox, so you replay against the exact
  deployed wasm; `.with_data()` copies its state too (up to 50 kB through a public RPC node),
  `.block_height(h)` takes both as of block `h`, and `.transact().await?` runs the import.

As in the sim, a patched state must be one users can reach through the contract's methods.

#### Advance blocks for yield timeouts

A yield times out from 200 blocks after the block that created it
([Time out a yield](#time-out-a-yield)). `worker.fast_forward(n)` moves the sandbox's block
height, timestamp and epoch forward by `n` blocks, in a fraction of the time producing them
would take.

The yield's callback belongs to the transaction that yielded, so `transact()` returns no result
until the callback has run (or its RPC request times out first). Send the transaction with
`transact_async()`, which returns once it is sent, then fast-forward past the deadline, then
wait for the result:

```rust
let status = u.call(c.id(), "request").gas(Gas::from_tgas(100)).transact_async().await?;
// ... wait until the yielding receipt has run (a view that shows the pending request) ...
worker.fast_forward(250).await?;
let outcome = status.await?; // returns once the callback has run
```

The deadline counts from the yielding receipt's own block, so fast-forward only after that
receipt has run. Then confirm from the callback's outcome (a log it writes, the state it
leaves) that it ran with the timeout's `Failed`.

#### What the sandbox cannot do: force an order

The sandbox is one local node. It runs receipts in its own order and offers no way to hold a
receipt or to reorder two receipts. (A block has one chunk per shard, so
`worker.view_block().await?.chunks().len()` shows how many shards it runs.) You control only
when transactions are sent: await one before sending the next, or send several with
`transact_async()` so that they are in flight together. Which receipt then runs first is the
node's choice. Repeating a test shows which orders the node happens to produce, not whether an
order is reachable on a network.

Load can reorder receipts without any switch. S4's buffer bypass was shown in the sim with no
fault injected: large calls (about 1.2 MB each) filled the link's grant, and a later small call
between the same two accounts ran a block before the ones still buffered. You can try to build
that load in the sandbox. Short of that, a counterexample whose bug needs a specific
interleaving cannot be forced there. Replay the failure parts in the sandbox, then argue the
order from nearcore's rules (S1-S5, listed under [Force an order](#force-an-order)) and the
contract's code, and write the argument down.

#### Measure your own burns

The sandbox burns real gas too, so it also measures your contract's burns for gas mode. Each
receipt outcome's `gas_burnt` is a measurement, on the state the sandbox holds. Convert it to
a `GasBurn` entry as in the sim ([Measure burns in the sim](#measure-burns-in-the-sim)):
subtract the receipt's own exec fees, which its creator prepaid, and the send fees of the
action-only children it created (the fees are in `modules/NearFees.tla`), and round up to
Ggas. The same caveats hold: realistic state, a prepaid gas where the receipt succeeds, and
none of the calibrator's checks.

### Without either: by reading the code

When you cannot run the wasm (no build of the deployed code, no machine that builds the sim
or runs the sandbox), walk the trace against the contract's source by hand, receipt by
receipt, and say in your write-up that it was not replayed. For each receipt in your list from
Step 1:

- find the method in the source, and check that the code takes the handler's branch for those
  arguments and that state;
- check each receipt it creates against the code's promises: receiver, method, arguments,
  deposit, static gas and weight;
- for each callback, check how the code reads the result the trace gave it;
- for each failure, name the cause on a real network ([Step 2](#step-2-decide-what-each-failure-needs));
- for each order the model chose, give the argument from S1-S5
  ([Force an order](#force-an-order)).

Gas verdicts need the same care without measured burns
([The method](USAGE.md#the-method)):

- keep to fault mode for conclusions that depend on a burn you estimated;
- use gas mode with the host-cost floor (`HostFloorGas <- TRUE`, an empty `GasBurn`, and the
  static gas and weights your contract declares) for each callback with a fixed budget
  ([Gas without a calibration](USAGE.md#gas-without-a-calibration-the-host-cost-floor)). The
  floor is sound only for a callback with weight 0 whose declared writes and logs happen on
  that path, whose static gas is the code's, and whose trie charge, if the trace uses one, is
  reachable. Its rule, [G7](SEMANTICS.md#g7-a-floor-from-host-costs), was checked by reading
  nearcore only. So replay at the trace's gas before you report a callback that runs out on
  the floor;
- treat every other gas window, and every pass on the floor, as illustrative.

## When it does not reproduce

If it does not reproduce, find out why before discarding it:

- the order needs timing a network does not produce (see the over-approximations in
  [Not modelled](SEMANTICS.md#over-approximations)). Without a hold the sim runs receipts in
  the order they were sent, so it rarely shows a same-pair reorder, but nearcore produces one
  under load ([S4](SEMANTICS.md#s4-no-per-pair-order)); reproduce it with `Fault::Hold`, not
  by waiting for it. The sandbox has no hold: build the load S4 describes (large receipts that
  do not fit the link's limits), or argue the reorder from S4;
- the gas tables are wrong for this path ([Calibrating](USAGE.md#calibrating)), as for
  `tally_gas_trusting` on real wasm
  ([Pin the prepaid gas, and find the edge](#pin-the-prepaid-gas-and-find-the-edge));
- your handler does not match the contract (re-read the source);
- or the library is wrong: open an issue with the trace and the replay (the sim or sandbox
  test).

A forced fault for which you find no cause ([Step 2](#step-2-decide-what-each-failure-needs))
does not reproduce as it stands. Before you drop it, check the causes against every input and
state a user can arrange, not only the trace's.

## Writing up a finding

A finding is a counterexample that reproduced, or one you argued receipt by receipt. Write it
up so that someone who has never seen the model can check it. Copy this template:

````markdown
## <one line: what goes wrong, in which method>

**Impact.** Who loses what, and who can trigger it (any user, a receiver, the owner only).

**Property violated.** The invariant, in words and as written in the model
(for example `Counted`: once nothing is in flight, C's count equals D's).

**Trace.** The `--print-trace` output, trimmed to the states that matter, and the list made
from it: transactions, receipts, failures, orders.

**Causes.** For each failure in the trace, what makes it happen on a network (a receiver that
panics, prepaid gas p, a state).

**Replay.** One of:
- sim: the test file, the wasm's sha256, what it showed, and each fault and hold it injected;
- sandbox: the test file, the wasm's sha256, and what it showed;
- by code reading: not replayed, and the walk-through.
Whether the trace's order was forced or argued, and for each order, the argument from
SEMANTICS S1-S5 that a network can produce it (for a hold, what would delay that receipt).

**Run.** The model directory and run name, the command, and the bounds and switches of the
run: MaxTx, MayFail, MaxFails, GasMode (and GasMenu, the gas tables and where their numbers
come from), whether the model conjoins LocalPriorityOK, MaxBlk, InstantFirst, FeeRounding,
TrieGasWorst, HostFloorGas.

**Versions.** The near-tla commit (`git rev-parse HEAD` in your checkout) and release; the
nearcore rules it encodes (protocol 88, nearcore 2.14.0, from SEMANTICS); for a sim replay,
the near-contract-sim tag and rev (from the test crate's `Cargo.lock`) and the nearcore it
pins; for a sandbox replay, the near-workspaces version and the sandbox's nearcore and
protocol versions (`worker.status()`); the contract's commit and the wasm's sha256.

**Fix.** The change, the model run that passes with it, and the must-fail run that still
fails on the old code.
````

The [VERSIONING](VERSIONING.md) page says what each release assumes about protocol versions.

**Report security bugs privately.** If the finding lets someone take funds, lock them, or
break the contract's guarantees, send it to the contract's maintainers through their
disclosure channel (a security policy, a bug bounty programme, a security contact), not in a
public issue, pull request or chat. The model and the trace are a recipe for the exploit: keep
them private too until the maintainers have fixed it.
