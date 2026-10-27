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
  - [In a local sandbox with near-workspaces](#in-a-local-sandbox-with-near-workspaces)
  - [In near-contract-sim](#in-near-contract-sim)
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
against the compiled contract, and check the same property. There are three ways to do it:

| | who can use it | failures | orders |
|---|---|---|---|
| [near-workspaces sandbox](#in-a-local-sandbox-with-near-workspaces) | anyone (public) | by cause: a stub receiver, the prepaid gas, the state | no switch: argued, or provoked by load |
| [near-contract-sim](#in-near-contract-sim) | maintainers and anyone with access (private) | injected directly | forced by holding receipts |
| [code reading](#without-either-by-reading-the-code) | anyone | argued | argued |

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

A **stub**, a small contract you deploy in place of another, may stand in only for a
*receiver* that can really fail, or answer that way, on the network: an untrusted token, a
callee that panics on some input or state. Never stub the contract under test: its own code
must run as compiled. With no real-network cause, the trace does not reproduce, and a stub
would only make it look as if it did.

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
  order where you can (the sim), and otherwise argue it from nearcore's rules
  ([below](#what-the-sandbox-cannot-do-force-an-order)).

The trace's last line, `Label: ...`, gives the library's label for the whole trace: `forced`
if any forced fault fired, else `caller-gas` if a receipt ran out of gas, else `no-fault`
([section 13 of USAGE](USAGE.md#13-the-forced-fault-switch-and-labels)). A trace can hold
failures of several kinds, so go through each failure line, not only the label.

If the failed receipt is marked owed or detached, the library records the failure in its
variable `ofail`, with the cause (`why`) and, for out of gas, the gas the receipt had (`g`) and
needed (`need`) ([Owed callbacks and detached work](USAGE.md#owed-callbacks-and-detached-work)).

## Step 3: replay it

With public tools, a counterexample that depends on receipt order is confirmed in its failures
only; its order is argued from SEMANTICS S1-S5 and the code, and the write-up says so. The
sandbox cannot force an order
([What the sandbox cannot do](#what-the-sandbox-cannot-do-force-an-order)); only the private
sim can.

### In a local sandbox with near-workspaces

[near-workspaces](https://github.com/near/near-workspaces-rs) (Rust) starts a local nearcore
node, the sandbox, deploys your compiled wasm to it, and sends real transactions. It is public,
and the sandbox runs on macOS (Intel and Apple silicon) and on x86-64 Linux.

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

#### The replay of `tally_trusting`

The test below replays the trace from [Step 1](#step-1-read-the-trace). It assumes C has an
init method `new(worker)` and a view method `count` that returns `n`; use your contract's
own names. `res/tally.wasm` is C compiled, `res/stub.wasm` the stub from
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

- `is_success()` is the transaction's status. It follows the value the transaction returns,
  not every receipt: `ping` returns the promise that ends in `done`, so the transaction
  succeeds although `work` failed. Check each receipt.
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

The model's `p` Ggas is `p × 10^9` gas. near-workspaces' `Gas` is near-gas's `NearGas`
(`near_workspaces::types::Gas`), not the sim's type, so its constructors are `from_gas`,
`from_ggas` and `from_tgas`:

```rust
let p: u64 = 8_600; // Ggas, from the trace
let outcome = u
    .call(c.id(), "ping")
    .deposit(NearToken::from_yoctonear(1))
    .gas(Gas::from_gas(p * 1_000_000_000)) // or Gas::from_ggas(p)
    .transact()
    .await?;
```

You set only the transaction's prepaid gas. A child's attached gas (the `gas 5000` on `work`)
follows from it: the static gas the code attaches plus a weighted share of what the creator
leaves ([G3](SEMANTICS.md#g3-weight-and-the-leftover-split-distribute_gas)), and the creator's
real burn decides that share. `worker.receipt(..)` shows what the child got.

A gas-mode trace is only as good as its burn table. The tally example's burns are
illustrative, so on real wasm the edge sits somewhere else, or nowhere. If the receipt does not
run out at the trace's amount, look for the real edge: lower the prepaid gas step by step (or
bisect) and watch that receipt's outcome.

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

A patched state must be one users can reach through the contract's methods. Otherwise the
replay shows a state no one can arrange, and proves nothing.

#### Advance blocks for yield timeouts

A yield times out from 200 blocks after the block that created it
([C7](SEMANTICS.md#c7-yield-and-resume-nep-519)). `worker.fast_forward(n)` moves the sandbox's
block height, timestamp and epoch forward by `n` blocks, in a fraction of the time producing
them would take.

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
order from nearcore's rules and the contract's code, and write the argument down:

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

#### Measure your own burns

The sandbox burns real gas, so it is also how you measure your contract's burns for gas mode
without the sim. Each receipt outcome's `gas_burnt` is a measurement, on the state the
sandbox holds; give it realistic state first, because burns grow with storage reads and
writes, and measure at a prepaid gas where the receipt succeeds.

`gas_burnt` is not the model's burn. A `GasBurn` entry is `gas_burnt` minus the receipt's own
exec fees (which its creator prepaid) minus the send fees of the action-only children it
created ([Calibrating your own contract](../conformance/README.md#calibrating-your-own-contract),
step 2; the fees are in `modules/NearFees.tla`). Convert to Ggas and round up. None of the
calibrator's checks (the leftover split, a declared static for every child) run on a hand
measurement; [Calibrating](USAGE.md#calibrating) says how to treat such tables.

### In near-contract-sim

near-contract-sim is a private repository
([Access to the sim](CONFORMANCE.md#access-to-the-sim)). It runs your compiled wasm on
nearcore's runtime at the pinned revision, and adds what the sandbox lacks: fault injection,
and holding receipts, so orderings can be forced. The sim's own docs describe its API; the
steps below use its names. Start from the list you made in [Step 1](#step-1-read-the-trace).

1. **List the transactions.** Every `Submit` / `SubmitAs` / `SubmitSigned` step is one sim
   transaction: `sim.call(signer, receiver, method)` with the same arguments and deposit. If the
   model pinned prepaid gas (`WithGas(r, p)`, `p` in Ggas), pin the same amount with `.gas(..)`:
   `p` Ggas is `p × 10^9` gas, `Gas::from_gigagas(p)`, or `Gas::from_teragas(p / 1000)` when
   `p` is whole Tgas.
2. **Map receipts to sim receipts.** Each model receipt is a sim receipt with the same
   receiver and method. Callbacks are the receipts that wait on a result
   (`Receipts::callback(m)`). Repeated calls are told apart with
   `Receipts::occurrence(receiver, m, k)` or `.nth(k)`.
3. **Reproduce the failures.**
   - A `"forced"` failure of method `m` on `receiver` (`failed (forced fault)` in the story):
     `tx.inject(Receipts::call(receiver, m), Fault::OutOfGas)`. If the model failed the call a
     callback waits on, `Fault::PromiseFailed` on the callback (`Receipts::callback(cb)`) gives
     the callback a Failed result.
   - A `"caller-gas"` failure (`out of gas` in the story): reproduce it with the transaction's
     gas (`Tx::gas`), not with a fault. To pin one child's gas, use `Fault::Gas(g)`.
     `Tx::least_gas` finds the least gas at which the transaction still succeeds, a quick
     check of a predicted edge.
   - A receiver's answer the model chose (`MAL`, `NONEMPTY`, a number): deploy a stub
     receiver (`sim.deploy_stub`), or put `Fault::ReturnValue(bytes)` on the callback.
4. **Reproduce the order.** The model interleaves receipts freely. Where the trace runs one
   transaction's receipt before another's, delay the other with `Fault::Hold(n)` (a receipt
   leaves `n` blocks late) or `Fault::HoldResult(n)` (its result reaches the callback late).
   `submit()` the first transaction, `run_until` the hold is in place, then submit the second.
5. **Check the same property.** Assert on the outcome (statuses, `value()`, balances and token
   moves via `effects()`), and read `sim.findings()`. If the model's invariant breaks in the
   sim too, it is real.

The sim also calibrates: the `calibrate` tool measures your contract's burns and checks the
leftover split ([Calibrating](USAGE.md#calibrating)).

### Without either: by reading the code

When you cannot run the wasm (no build of the deployed code, no machine the sandbox runs on),
walk the trace against the contract's source by hand, receipt by receipt, and say in your
write-up that it was not replayed. For each receipt in your list from Step 1:

- find the method in the source, and check that the code takes the handler's branch for those
  arguments and that state;
- check each receipt it creates against the code's promises: receiver, method, arguments,
  deposit, static gas and weight;
- for each callback, check how the code reads the result the trace gave it;
- for each failure, name the cause on a real network ([Step 2](#step-2-decide-what-each-failure-needs));
- for each order the model chose, give the argument from S1-S5
  ([above](#what-the-sandbox-cannot-do-force-an-order)).

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
  [Not modelled](SEMANTICS.md#over-approximations)). A sim without fault injection rarely
  shows a same-pair reorder, but nearcore produces one under load
  ([S4](SEMANTICS.md#s4-no-per-pair-order)); reproduce it with `Fault::Hold`, not by waiting
  for it. The sandbox has no hold: build the load S4 describes (large receipts that do not
  fit the link's limits), or argue the reorder from S4;
- the gas tables are wrong for this path ([Calibrating](USAGE.md#calibrating));
- your handler does not match the contract (re-read the source);
- or the library is wrong: open an issue with the trace and the replay (the sandbox or sim
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
- sandbox: the test file, the wasm's sha256, and what it showed;
- sim: the test file, the sim's revision, and what it showed;
- by code reading: not replayed, and the walk-through.
Whether the trace's order was reproduced or argued. For any order the replay could not force,
the argument from SEMANTICS S1-S5.

**Run.** The model directory and run name, the command, and the bounds and switches of the
run: MaxTx, MayFail, MaxFails, GasMode (and GasMenu, the gas tables and where their numbers
come from), whether the model conjoins LocalPriorityOK, MaxBlk, InstantFirst, FeeRounding,
TrieGasWorst, HostFloorGas.

**Versions.** The near-tla commit (`git rev-parse HEAD` in your checkout) and release; the
nearcore rules it encodes (protocol 88, nearcore 2.14.0, from SEMANTICS); for a sandbox
replay, the near-workspaces version and the sandbox's nearcore and protocol versions
(`worker.status()`); the contract's commit and the wasm's sha256.

**Fix.** The change, the model run that passes with it, and the must-fail run that still
fails on the old code.
````

The [VERSIONING](VERSIONING.md) page says what each release assumes about protocol versions.

**Report security bugs privately.** If the finding lets someone take funds, lock them, or
break the contract's guarantees, send it to the contract's maintainers through their
disclosure channel (a security policy, a bug bounty programme, a security contact), not in a
public issue, pull request or chat. The model and the trace are a recipe for the exploit: keep
them private too until the maintainers have fixed it.
