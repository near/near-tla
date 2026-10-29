# The runner

`tools/run.py` runs your model's checks in TLC and tells you whether each one gave the result
you expected. This page covers how to run checks, how to read what comes back, and how to make
sure that a pass means something.

You describe the checks in a `runs.toml` file beside your spec. Each check is a **run**: a set
of constants for TLC, the invariants to check, and the verdict TLC must give. For every run,
the runner:

1. generates a small wrapper module and a TLC config that set the run's constants;
2. runs TLC on them;
3. reads TLC's verdict (no error, an invariant violated, an `Assert`, a deadlock) and compares
   it with the run's `expect`;
4. prints a table, and exits with a nonzero code if any run did not give its expected verdict.

Some runs are expected to fail, on purpose. A run that must break an invariant is the evidence
that the invariant can fail at all: an invariant that has never failed may be vacuous, true
only because it never looks at anything. Beyond the runs, the runner can show that the
situations you care about are reached and that small bugs are caught (witnesses and mutants),
find exact gas and size boundaries (sweeps), and report what your runs never pushed to its
edges (the audit).

`python3 tools/run.py --help` is the full reference for every key and option; this page
explains them with examples. If you are new to near-tla, read [CONCEPTS.md](CONCEPTS.md)
first: it explains receipts, callbacks and the other terms used here
([Vocabulary](CONCEPTS.md#vocabulary)).

- [Running checks](#running-checks)
- [Reading the output](#reading-the-output)
- [Reading a counterexample](#reading-a-counterexample)
- [`runs.toml`](#runstoml)
- [Every invariant must be able to fail](#every-invariant-must-be-able-to-fail)
- [Witnesses and mutants](#witnesses-and-mutants)
- [Print-only window invariants](#print-only-window-invariants)
- [Least gas and size sweeps](#least-gas-and-size-sweeps)
- [Auditing what the runs reach](#auditing-what-the-runs-reach)
- [Advanced](#advanced): peel mode, definitions inside other modules, stack size

## Running checks

From the root of the repo:

```sh
python3 tools/run.py examples/minimal                                  # every run of one model
python3 tools/run.py examples/minimal tally_gas_trusting --print-trace # one run, with its counterexample
python3 tools/run.py examples/minimal --anti-vacuity                   # and its witnesses and mutants
python3 tools/run.py path/to/model/ my_run --print-trace               # one run of your own model
python3 tools/run.py 'pay_*'                                           # runs by name, under examples/
python3 tools/run.py --list path/to/model/                             # list the runs, run nothing
```

You need Python 3.11 or later, Java 21, and the pinned TLC jar at `tools/tla2tools.jar`
([Quickstart](../README.md#quickstart)). `--jar JAR` points at another jar; the environment
variable `TLA2TOOLS_JAR` is used when `tools/tla2tools.jar` is missing.

### Choosing runs

The arguments can mix three kinds of thing:

- a `runs.toml` file;
- a directory, searched recursively for `runs.toml` files (`build/` directories are skipped);
- a run name. Shell-style globs such as `'pay_*'` work; quote them so the shell leaves them
  alone.

Names filter the runs of the given paths. With names only, they are looked up under this
repo's `examples/`. With no arguments at all, every run under `examples/` is checked. A run
name must be unique across all the files loaded in one invocation.

Selecting some of a file's runs also selects the witnesses and mutants that apply to them
(narrowed to the selected runs), and, with `--sweep`, the sweeps whose base run is selected.

`--list` prints the selected runs (name, directory, expectation, tags) and exits without
starting TLC. With `--anti-vacuity` it lists the witnesses and mutants too, and with `--sweep`
the sweeps.

### Options

| option | what it does |
|---|---|
| `--print-trace` | When a run ends in a violation, an `Assert` or a deadlock, print a readable summary of TLC's counterexample under its row, whether or not that was the expected verdict ([Reading a counterexample](#reading-a-counterexample)). |
| `--keep` | Keep the generated wrapper, config and TLC log of every run in `build/`. Without it they are kept only for runs that did not match their expectation. |
| `--workers N` | Lower every run's TLC worker count to at most N. A run's own `workers` (default 2, at most 4) is an upper bound: `--workers` can lower it, never raise it. |
| `--json PATH` | Also write the results to PATH as JSON: every run, then every witness and mutant check, then every sweep row, with the table's fields, the notes, the kept log and the audit's facts. |
| `--library DIR` | Use DIR as the library for every run, whatever `runs.toml` says. The environment variable `NEAR_TLA_LIBRARY` does the same. Several directories can be joined with the path separator (`:` on Linux and macOS). |
| `--peel` | On a violation, drop the violated invariant and run again, to see every invariant a change breaks ([Peel mode](#peel-mode)). |
| `--anti-vacuity` | After the runs, check every witness and mutant of the selected runs, and fail on open audit gaps ([Witnesses and mutants](#witnesses-and-mutants)). |
| `--sweep` | After the runs, run every sweep whose base run is selected ([Least gas and size sweeps](#least-gas-and-size-sweeps)). |
| `--least-gas`, `--gas-range`, `--success`, `--exact`, `--gas-step` | An ad hoc least-gas search on each selected run ([Least gas and size sweeps](#least-gas-and-size-sweeps)). |
| `--no-audit` | Do not collect the audit's facts or print its report ([Auditing what the runs reach](#auditing-what-the-runs-reach)). |
| `--list` | List the selected runs and exit. |
| `--jar JAR` | The TLC jar (default `tools/tla2tools.jar`, else `$TLA2TOOLS_JAR`). |

`TLC_JAVA_OPTS` adds JVM options to every TLC process, for example `-Xmx4g` for a larger heap
([Stack size and JVM options](#stack-size-and-jvm-options)).

### Where your model lives

A model is a directory with your spec (`MyContract.tla`) and a `runs.toml` that lists its
runs. It does not have to be inside this repo.

- **Inside `examples/<name>/`** of this repo, the runner finds the library at
  `../../modules`, the default.
- **Anywhere else** (your own repo, a scratch directory), the runner falls back to the
  `modules/` directory of the near-tla checkout it lives in. So you can call your checkout's
  `run.py` from any directory, for example `python3 ~/src/near-tla/tools/run.py ~/models/tally`.
  The model directory needs its `runs.toml`: on a directory without one, the runner prints
  `no runs selected` and exits with code 2.
- **To point at a specific library**, set `library = "path/to/modules"` in `runs.toml`
  (relative to the `runs.toml`). `--library DIR` and the environment variable
  `NEAR_TLA_LIBRARY` override it for every run.

The runner passes the library to TLC as `-DTLA-Library=<spec dir>:<library>`, so modules
beside your spec (a calibrated table, say) are found first.

## Reading the output

This is `python3 tools/run.py examples/minimal --workers 1`:

```
run                | expect            | actual            | generated | distinct | depth | secs | result
-------------------+-------------------+-------------------+-----------+----------+-------+------+-------
tally_ok           | pass              | pass              | 151       | 86       | 9     | 0.8  | ok
tally_trusting     | violation Counted | violation Counted | 22        | 21       | 5     | 0.8  | ok
tally_gas_ok       | pass              | pass              | 63        | 63       | 5     | 0.8  | ok
tally_gas_trusting | violation Counted | violation Counted | 53        | 53       | 5     | 0.8  | ok
tally_gas_win      | pass              | pass              | 63        | 63       | 5     | 0.9  | ok
    window Counted 8600-9000

5/5 runs as expected

audit examples/minimal/runs.toml: 1 owed or fixed-budget receipt(s), 0 open gap(s), 3 accepted
  c.done    trie       accepted: done writes no storage in this toy (H_done declares no write)
  c.done    least-gas  accepted: done's budget is a fixed 2 Tgas against a 0.6 Tgas burn; tally_gas_win maps the prepaid edge
  c.done    logs       accepted: done logs nothing (H_done declares no log)
```

Progress lines (`running tally_ok (examples/minimal) ...`) go to standard error; the table
goes to standard output.

### The table

| column | meaning |
|---|---|
| `run` | the run's name |
| `expect` | the verdict `runs.toml` asks for: `pass`, `violation <invariant>`, `assert` or `deadlock` |
| `actual` | the verdict TLC gave: one of the above, or `timeout` (stopped, see below), `error` (a parse or evaluation error, or TLC stopped for another reason), `assumption` (an `ASSUME` in the spec is false); in peel mode, `peeled {...}` |
| `generated` | states TLC generated, repeats included |
| `distinct` | distinct states TLC found: the best measure of how big a run is |
| `depth` | how deep TLC's breadth-first search went, counting the initial state as 1 |
| `secs` | wall-clock seconds, JVM start-up included |
| `result` | `ok` if the run met every expectation, `FAIL` if not |

Indented lines under a row are notes: an `Assert`'s message, `over budget`, `vacuous`, an
`expect_output` that did not match, the windows a window run printed, or the trace with
`--print-trace`. A row that fails ends with `log: <path>`, the TLC log kept for it.

The line after the table counts the runs that matched (`5/5 runs as expected`) and names any
that did not (`FAILED: ...`). With `--anti-vacuity`, a second table lists the witness and
mutant checks ([Witnesses and mutants](#witnesses-and-mutants)); with `--sweep`, another lists
the sweep rows ([Least gas and size sweeps](#least-gas-and-size-sweeps)).

### When a row is ok

A row is `ok` when all of these hold:

- **The verdict matches `expect`.** A violation must name the run's `invariant`.
- **A pass is a real pass.** TLC exited with code 0, printed "No error has been found", and
  explored at least one distinct state. A pass over zero states fails, with the note
  `vacuous: TLC explored no distinct states`.
- **The run kept to its budget.** A run that takes longer than its `budget_s` (default 60
  seconds) fails, but is still reported. A run still going after 3 × `budget_s`, or after
  `budget_s` + 30 seconds if that is later, is stopped and reported as `timeout`.
- **`expect_output` and `expect_window` match**, if the run has them.

**What a pass means.** A pass holds only within limits, such as the run's bounds and the
model's abstraction of the contract; [What a pass means](CONCEPTS.md#what-a-pass-means) lists
them.

**Must-fail runs are part of the method.** `ok` on a `violation` run says that the invariant
can fail, for the reason the run sets up. An invariant that has never failed may be vacuous, so
each one needs a must-fail run ([Every invariant must be able to fail](#every-invariant-must-be-able-to-fail)).

**Counts and workers.** The `generated` and `distinct` counts of a passing run are exact: TLC
explores the whole state space, whatever the number of workers. A must-fail run stops at the
first violation a worker finds, so with more than one worker its counts, and its
counterexample, can change from one invocation to the next. With one worker they repeat. The
examples on this page use `--workers 1` for that reason.

### Exit code

- `0`: every run, witness, mutant, sweep row and (with `--anti-vacuity`) audit check came out
  as expected.
- `1`: at least one did not.
- `2`: the runner could not start: a `runs.toml` error, an unknown constant, no run selected,
  no TLC jar or no Java.

### Logs and generated files

The runner generates each run's wrapper (`MC_<run>.tla`) and config (`MC_<run>.cfg`) in a fresh
temporary directory, so that nothing stale can shadow a module, and runs TLC there. TLC's
output goes to `build/<run>.log` beside the `runs.toml`, with your home directory written as
`~` and temporary directories as `<tmp>`. Each log starts with the Java command line and ends
with a `# runner:` line giving the wall time, TLC's exit code and the verdict.

The wrapper, config and log stay in `build/` only for runs that did not match their
expectation, or for every run with `--keep`. Otherwise the runner deletes them. `build/` is
gitignored. Witness, mutant and sweep jobs write their logs to the same place, named after
the run and the check (`<run>__w_<id>.log`, `<run>__m_<id>.log`, `<run>__s_<id>_<value>.log`),
and keep them when the job fails or with `--keep`.

### The audit lines

After the tables, the runner prints one audit report per `runs.toml`. It counts the owed
receipts (receipts that must not fail, such as a callback that refunds) and the callbacks with
a fixed gas budget that the runs executed, then lists each gap: something the runs modeled
but never pushed to its edge. A receipt counts as owed only if you mark it, so a refunding
callback you left unmarked can leave the report at `0 open gap(s)`
([What the audit judges](#what-the-audit-judges)).
Accepted gaps are listed with their reason. When only some of a file's runs were selected, the
header says so, and the gaps are judged on those runs only:

```
audit examples/minimal/runs.toml (1 of 5 runs; sweeps and gaps judged on those): 1 owed or fixed-budget receipt(s), 0 open gap(s), 3 accepted
```

In a plain invocation the report is for information. With `--anti-vacuity`, each open gap
of a file whose runs all ran fails the invocation.
[Auditing what the runs reach](#auditing-what-the-runs-reach) explains each rule and how to
close it.

## Reading a counterexample

When a run ends in a violation, an `Assert` or a deadlock, `--print-trace` prints TLC's
counterexample as a story: which receipt ran in each step, how it ended, and what changed.
This is the minimal model's trusting callback in gas mode, which must fail `Counted`:

```sh
python3 tools/run.py examples/minimal tally_gas_trusting --print-trace --workers 1
```

The trace is printed under the run's row in the table, after a `trace:` line. The summary line
and the audit report follow it; they are left out here.

```
run                | expect            | actual            | generated | distinct | depth | secs | result
-------------------+-------------------+-------------------+-----------+----------+-------+------+-------
tally_gas_trusting | violation Counted | violation Counted | 53        | 53       | 5     | 1.1  | ok
    trace:
    State 1: Initial predicate
        n = 0
        near = [d |-> 0, c |-> 0, u |-> 2]
        ntx = 0
        works = 0
        gas = <<0>>
        (18 platform variables never change here; to see them, rerun with --keep, then tools/tlctrace.py --raw <log>)
    State 2: Ping (Tally:70)
        submitted #1 ping u->c (tx 1, deposit 1, gas 8600, args [x |-> 0])
        near.u: 2 -> 1
        ntx: 0 -> 1
        gas[1]: 0 -> 8600
    State 3: RunReceipt (Tally:82)
        ran #1 ping u->c: committed
            (tx 1, deposit 1, gas 8600, args [x |-> 0])
        created #2 work c->d (tx 1, gas 5000, result to #3, args [x |-> 0])
        created #3 done c->c (tx 1, gas 2000, args [x |-> 0]) (postponed)
        near.c: 0 -> 1
    State 4: RunReceipt (Tally:82)
        ran #2 work c->d: out of gas
            (tx 1, gas 5000, result to #3, args [x |-> 0])
        data -> #3: Failed
    State 5: RunReceipt (Tally:82)
        ran #3 done c->c, seeing Failed: committed
            (tx 1, gas 2000, args [x |-> 0])
        n: 0 -> 1
    The model's variables at the last state:
        n = 1
        ntx = 1
        works = 0
        gas = <<8600>>
    Label: caller-gas (a receipt ran out of gas at a prepaid amount the caller chose)
```

Read it step by step:

1. **State 1** is the initial state. `u`'s balance is 2; nothing has happened yet.
2. **State 2**: user `u` submits transaction 1, a call to `c.ping()` with a deposit of 1 and
   8600 Ggas (8.6 Tgas) of prepaid gas. The deposit leaves `u`'s balance.
3. **State 3**: `ping` runs and commits. It creates receipt #2, the call to `d.work()`, whose
   result goes to #3; and #3, the callback `c.done()`, which is postponed until that result
   arrives. The deposit reaches `c`.
4. **State 4**: `work` runs out of gas. At 8.6 Tgas, `ping` passes on no leftover gas, so
   `work` holds only its 5 Tgas of static gas, and it needs 5.5. A data receipt carries the
   result `Failed` to #3.
5. **State 5**: `done` runs, sees `Failed`, and commits. The trusting `done` counts the work
   anyway: `n` goes from 0 to 1.
6. **At the last state** nothing is in flight, `n = 1` and `works = 0`, so
   `Counted == Idle => n = works` is false.
7. **The label**, `caller-gas`, says what kind of failure the trace needs: here, an out-of-gas
   at the prepaid amount the user chose, not a forced fault.

The same model's fault-mode twin, `tally_trusting`, tells the same story with a forced fault
instead: its state 4 reads `Fault (Tally:83)` and `ran #2 work c->d: failed (forced fault)`,
and its label is `forced`.

### The kinds of line

**The step header**, `State 3: RunReceipt (Tally:82)`, names the action TLC took and the module
and line of its definition. The action is the disjunct of your `Next` that made the step. Name
your disjuncts, as [`examples/minimal/Tally.tla`](../examples/minimal/Tally.tla) does, so that
each step says what kind of step it was:

```tla
RunReceipt == \E r \in Runnable : Step(r)
Fault      == \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine
Next       == Ping \/ RunReceipt \/ Fault
```

With the disjuncts written inline in `Next`, every step is labeled `Next` and only the line
number tells them apart. A stuttering step prints its header and nothing else.

**Receipts** are written `#id method predecessor->receiver`: `#2 work c->d` is receipt 2, a
call of `work` from `c` to `d`. The details in parentheses are, where they apply:

- the transaction (`tx 1`);
- the attached deposit (`deposit 1`);
- the attached gas in Ggas, one number per function call (`gas 5000`);
- for an `ACCOUNT` receipt, its account actions: `CreateAccount`, `DeleteAccount, beneficiary b`,
  or both, joined with `+`;
- the promise result a callback has been given (`sees ...`);
- where the receipt's result goes (`result to #3`);
- the marks `owed` and `detached`;
- the arguments, with empty fields left out (`args [x |-> 0]`).

A joint callback (one that waits on several promises, `promise_and`) waits for **data ids**,
not receipt ids. So on a call whose result feeds a joint callback, `result to #5` names data
id 5, which is not a receipt: the joint callback's `(postponed: ...)` line lists the data ids
it waits for.

| line | meaning |
|---|---|
| `submitted #1 ping u->c (...)` | the first receipt of a new transaction |
| `ran #2 work c->d: out of gas` | receipt #2 ran in this step; after the colon, how it ended. The next line gives its details |
| `ran #3 done c->c, seeing Failed: committed` | a callback ran; `seeing` gives the promise result it consumed |
| `ran #4 on_both s->s, seeing Failed, 1: committed` | a joint callback ran; `seeing` gives the result of each of its inputs, in order |
| `ran #2 on_answer q->q, seeing Failed (timed out): committed` | a yield callback ran because its deadline passed, and sees `Failed` |
| `created #2 work c->d (...)` | a receipt this step created |
| `created #3 done c->c (...) (postponed)` | a callback that waits for its input before it can run |
| `... (postponed: a joint callback, waits for the results sent to #5, #6)` | a joint callback; it runs once a result has reached each of these data ids |
| `... (postponed: a yield, until resumed or block 12)` | a yield callback; it runs when resumed, or with `Failed` once the block clock reaches 12 (or `MaxBlk`, the clock's bound) |
| `updated #4 ...` | a receipt still waiting whose record changed in this step |
| `data -> #3: Failed` | a new data receipt, carrying a promise result to callback #3 (or to data id 3 of a joint callback) |
| `near.c: 0 -> 1` | a variable that changed, field by field |
| `warning: receipts share an id (#7): check the ids the model gave them` | two receipts in flight have the same id (below) |
| `(no change)` | nothing the printer shows changed in this step |

**Receipts that share an id** are a modeling error, not a contract bug. An `Outcome` whose
`ids` count is too small no longer gets this far: `Commit` asserts the ids of its children.
A shared id can still come from a receipt the model builds outside an outcome, such as a
`Submit` with a fixed id. The library removes a receipt by its id, so running one of the pair
removes the other too, and the story shows only one of them. Fix the id and run again.

**How a receipt ended**, after the colon of a `ran` line, is one of:

- `committed`: it ran to the end and its changes stand;
- `committed (deleted p)`, `committed (created q)`: it committed, and an account was deleted
  or created (by a `DeleteAccount` or `CreateAccount`, or a Transfer that creates an implicit
  account). When both happen, both are named, separated by `;`;
- `failed`: it failed (a panic, say), and its changes were reverted;
- `failed (forced fault)`: TLC chose to fail it, through the forced-fault switch (`MayFail`,
  `MaxFails`);
- `failed (deposit refunded)`: it failed, and a system refund receipt returns its deposit;
- `out of gas`: it needed more gas than it held;
- `burnt (a does not exist; 2 burnt)`: a refund reached an account that no longer exists, so
  its amount (2 here) was burnt instead of credited.

**Promise results** are decoded wherever they appear (`data ->`, `seeing`, `sees`):

- `Failed`;
- a number: Successful, a well-formed JSON number;
- `EMPTY`: Successful, empty bytes (a Transfer, or a method that returns `()`);
- `MAL`: Successful, malformed bytes the callback cannot parse;
- `NONEMPTY`: Successful, other bytes (a JSON object, `null`, ...);
- `NOPR (no promise result)`: the receipt has no promise results at all.

A result whose size is stated ends with it, in bytes and KB: `7 (42 B, 1 KB)`.

**Changes to variables** are printed field by field, up to three levels deep:

- a record or function whose fields stay the same prints each changed field:
  `near.c: 0 -> 1`;
- a sequence whose length stays the same prints each changed position: `gas[1]: 0 -> 8600`;
- a set prints each element added (`name + element`) and removed (`name - element`);
- anything else prints whole: `name: old -> new`.

The platform's receipt bookkeeping (`rq`, `post`, `data`, `nid`, `oog`, `fails`) is told as
`ran`, `created` and `data` lines instead. The other platform variables, such as `near` (each
account's liquid balance), print as changes like your own.

**The first state** lists your model's variables, and the platform variables (those
`NearAsync` and `NearKeys` declare) that change somewhere in the trace; the receipt
bookkeeping is left out while it is empty. Platform variables that never change in the trace
are left out, and a line says how many and how to see them: keep the log with
`run.py --keep`, then run `tlctrace.py --raw` on it ([Raw values and logs](#raw-values-and-logs)).

**The model's variables at the last state** follows the last step. It lists every variable that is
not a platform variable (a token module's `tk` and `mtk` count as yours) at the last state TLC
printed. For an invariant violation, that is the state that breaks the invariant: check the
invariant against these values.

**The label** is the last line, `Label: <kind> (<what it means>)`. It is the library's `Label`
of the last state ([section 13 of USAGE](USAGE.md#13-the-forced-fault-switch-and-labels)):

- `forced`: the forced-fault switch fired somewhere in the trace;
- `caller-gas`: no forced fault, but a receipt ran out of gas at a prepaid amount the caller
  chose;
- `no-fault`: neither; any failure in the trace follows from the code and the accounts.

It tells you what a replay must reproduce
([Step 2 of VALIDATING](VALIDATING.md#step-2-decide-what-each-failure-needs)). It is printed
only for a spec with the platform variables `fails` and `oog`.

### How outcomes are inferred

TLC records states, not events. The printer infers how each receipt ended from what the step
left in the platform variables, testing in this order:

1. `out of gas` if the step added an entry to `oog`;
2. `failed (forced fault)` if the forced-fault counter `fails` grew;
3. `burnt (...)` if the receipt is a refund and `burnt` grew: its receiver no longer exists;
4. `committed (deleted ...)` or `committed (created ...)` if `deleted` or `created` gained an
   account;
5. `failed` if the receipt's callback was sent a `Failed` result;
6. `failed (deposit refunded)` if the step created a system refund receipt with the next free
   id, and no balance in `near` changed;
7. `failed` if the step used up exactly one receipt id, created nothing with it (no receipt,
   no data receipt), and no balance in `near` changed. This is what a failure without a
   callback or a deposit leaves;
8. `committed` otherwise.

Rules 6 and 7 test `near` because a failed receipt moves no balance: its changes are reverted.
Rule 5 comes before rule 6, so a failed receipt that has a callback reads plain `failed`, even
when its deposit is refunded too. Look for a `created #k REFUND system->...` line in the same
step.

**Which results a callback saw** is inferred the same way. `seeing` lists the data receipts the
step consumed that were addressed to the receipt: to its own id, or, for a joint callback, to
each data id it waits for, in that order. A yield callback that consumed none ran because its
deadline passed, and reads `seeing Failed (timed out)`.

One case is ambiguous. `oog` is a set of `<<transaction, method>>` pairs, so a second
out-of-gas of the same method in the same transaction does not change it. When `oog` already
holds the receipt's pair, any of the `failed` outcomes of rules 5 to 7 gets a warning appended,
for example `failed (or out of gas again: oog already holds this tx and method)`.

### Raw values and logs

The story is a reading aid. When something in it looks wrong, or you need a value it leaves out,
look at TLC's own values:

```sh
python3 tools/run.py examples/minimal tally_gas_trusting --keep --workers 1
python3 tools/tlctrace.py examples/minimal/build/tally_gas_trusting.log        # the same story
python3 tools/tlctrace.py --raw examples/minimal/build/tally_gas_trusting.log  # TLC's raw values
```

`tools/tlctrace.py <log>` prints the story for any kept TLC log. The runner deletes the log of
every run that met its expectation, including a must-fail run that failed. Add `--keep` to keep
it.

`--raw` prints the full initial state, then for each step the action and every variable that
changed, as TLC printed it and in full. The story cuts values longer than 160 characters with
`...`. `--width N` sets the limit for either form (0: no limit). For a spec without the
platform variables, or a value the printer cannot parse, the story falls back to the raw form.

### A trace is a hypothesis

A counterexample shows that the model can break the invariant. It does not yet show that the
contract can. The handler may not match the contract, the order may be one a network does not
produce, or the gas numbers may be wrong for that path. Before you report a trace, replay it
against the compiled contract, as [VALIDATING.md](VALIDATING.md) describes.

## `runs.toml`

A `runs.toml` lists the runs of one model. Start from the minimal model's file,
[`examples/minimal/runs.toml`](../examples/minimal/runs.toml). This is its first half,
annotated:

```toml
# File-level keys: defaults for every run in this file.
spec = "Tally"                    # the module to check: Tally.tla, beside this file
workers = 2                       # TLC workers per run (1 to 4; default 2)
library = "../../modules"         # the near-tla modules, relative to this file
budget_s = 60                     # seconds a run may take
invariants = ["Counted", "Sane"]  # checked by every run that does not list its own
platform_defaults = true          # fill the platform constants this model does not use

# Constants shared by every run. Each value is TLA+ expression text.
[constants]
Accounts = 'Accts'                # the set Tally.tla defines as Accts
MayFail = '{}'                    # no forced faults unless a run allows them
MaxFails = '0'
TrackSigner = 'FALSE'             # an overridable definition: the model never reads the signer
U = '"u"'                         # a TLA+ string: double quotes inside TOML single quotes
C = '"c"'
D = '"d"'
MaxTx = '2'
InitU = '2'
GasMenu = '{0}'
Trusting = 'FALSE'

# Must pass: work may fail once; done checks the result, so the counts agree.
[[run]]
name = "tally_ok"
expect = "pass"
tags = ["semantics:callback-result"]
[run.constants]                   # merged over [constants]
MayFail = '{"work"}'
MaxFails = '1'

# Must fail: done counts without checking, and a failed work is counted.
[[run]]
name = "tally_trusting"
expect = "violation"
invariant = "Counted"             # the invariant that must break
tags = ["semantics:callback-failure"]
[run.constants]
MayFail = '{"work"}'
MaxFails = '1'
Trusting = 'TRUE'

# Must fail in gas mode: work runs out of gas below 9.1 Tgas. These constants
# replace the fault-mode values platform_defaults would fill.
[[run]]
name = "tally_gas_trusting"
expect = "violation"
invariant = "Counted"
tags = ["gas:out-of-gas"]
[run.constants]
GasMode = '"gas"'
GasCall = 'TGasCall'
GasBurn = 'TGasBurn'
GasMenu = 'Menu'
MaxTx = '1'
Trusting = 'TRUE'
```

The rest of the file adds two passing gas-mode runs and a print-only window run, then the
witnesses, mutants and `[audit]` table that the later sections of this page describe.

### Values

Each entry under `[constants]` or `[run.constants]` is TLA+ expression text: `'2'`,
`'{"work"}'`, `'[a \in Accts |-> 0]'`, `'"c"'`. Write it in TOML single quotes. Single-quoted
TOML strings are literal, so backslashes and double quotes need no escaping. In double quotes,
every `\` must be written `\\`. A multi-line value can use TOML's `'''...'''`.

TOML integers and booleans are accepted too (`MaxTx = 2`, `Trusting = false`, which becomes
`FALSE`). An empty value is an error.

Constants and overridable definitions are set the same way: the runner turns each entry into
TLC's `Name <- ...`, which assigns a `CONSTANT` and overrides a definition alike.
[Constants and overridable definitions](USAGE.md#2-constants-and-overridable-definitions) lists
both for the library. A definition inside another module takes a module-qualified key,
`Mod!Name` ([A definition inside another module](#a-definition-inside-another-module)).

### Keys

Most keys can be given at the top level of the file, as a default for every run, or in a
`[[run]]`, where they win. `[constants]` and `[run.constants]` are merged, the run's entries
over the file's.

| key | default | meaning |
|---|---|---|
| `spec` | required | the module to check: a `.tla` file beside `runs.toml` |
| `workers` | 2 | TLC workers, 1 to 4; `--workers` can only lower it |
| `library` | `"../../modules"` | the library directory, relative to `runs.toml`, or a list of directories. If the default does not exist, the `modules/` of the runner's own checkout ([Where your model lives](#where-your-model-lives)) |
| `budget_s` | 60 | wall-clock seconds; a slower run fails, but is still reported |
| `init`, `next` | `"Init"`, `"Next"` | the initial predicate and the next-state action |
| `specification` | none | a temporal formula, such as `"Spec"`, instead of `init` and `next` (not both). Not to be confused with `spec`, which names the module |
| `invariants` | `[]` | the invariants TLC checks |
| `properties` | `[]` | the temporal properties TLC checks |
| `deadlock` | `false` | `true` makes a stuck state an error (below) |
| `stack` | `"16m"` | the JVM thread stack (`-Xss`) of each TLC run ([Stack size and JVM options](#stack-size-and-jvm-options)) |
| `tags` | `[]` | free-form labels, such as `"gas:out-of-gas"`; `--list` shows them |
| `platform_defaults` | `false` | for a spec that extends `NearAsync`: fill the platform constants the model does not set (below) |
| `[constants]` | none | constants for every run of the file |

These keys belong to one run and cannot be given at the top level:

| key | meaning |
|---|---|
| `name` | required: unique across all loaded files; letters, digits and `_`, starting with a letter |
| `expect` | required: `"pass"`, `"violation"`, `"assert"` or `"deadlock"` |
| `invariant` | with `expect = "violation"`, and only then: the invariant or property that must break |
| `expect_output` | a regular expression that must match TLC's output, with whitespace collapsed. It pins a detail, such as the gas value in the violating state |
| `expect_window`, `window_step` | the expected windows of a print-only run ([Print-only window invariants](#print-only-window-invariants)) |
| `allow_no_invariants` | lets a `pass` run check no invariant; the value must say why |

`[[witness]]`, `[[mutant]]` and `[[sweep]]` tables sit beside the `[[run]]` tables and name the
runs they apply to ([Witnesses and mutants](#witnesses-and-mutants),
[Least gas and size sweeps](#least-gas-and-size-sweeps)). One `[audit]` table lists the
source's methods and the accepted gaps ([Auditing what the runs reach](#auditing-what-the-runs-reach)).

### Expectations

- **`expect = "pass"`** needs TLC to finish with no error, having explored at least one state.
  The run must check at least one invariant: properties alone do not count, since a run with an
  empty INVARIANTS section can pass without looking at a single state.
  `allow_no_invariants = "why"` is the explicit exception.
- **`expect = "violation"`** needs `invariant`, naming one of the run's `invariants` or
  `properties`; TLC must report that one. When a state breaks several invariants, TLC
  reports the first in the run's list, so put the one the run targets first. TLC does not name a violated temporal property, so
  when `invariant` names a property, that property must be the only entry of `properties`;
  TLC's "Temporal properties were violated" then matches it.
- **`expect = "assert"`** needs TLC to stop on a failed `Assert`, such as a missing gas key.
- **`expect = "deadlock"`** needs `deadlock = true` and a state with no next step.

**Deadlock.** By default the runner passes TLC `-deadlock`, which turns deadlock checking off:
a system that has finished, with nothing left to run, is fine. `deadlock = true` makes a state
with no next step an error, so a stuck receipt is reported. Then also add a do-nothing step for
when the model is idle, such as `Idle /\ UNCHANGED vars` as a disjunct of `Next`, or every
finished state is reported as a deadlock.

### Platform defaults

`NearAsync` declares constants for features many models do not use: staking, a storage floor,
gas mode, an outcome log. A model that does not use them still has to give each a value.
`platform_defaults = true` fills the ones your file leaves unset:

| constant | value | effect |
|---|---|---|
| `Exists` | `Accounts` | every account exists at the start |
| `StakingAcct` | `CHOOSE a \in Accounts : TRUE` | unused while `MaxEpoch = 0` |
| `MinStake` | `1` | |
| `MaxEpoch` | `0` | no epoch ticks, so no staking rewards |
| `MaxReward` | `0` | |
| `StorageFloor` | `[a \in Accounts \|-> 0]` | no storage floor |
| `GasMode` | `"fault"` | fault mode |
| `GasCall`, `GasBurn` | `[k \in {} \|-> 0]` | empty gas tables |
| `LogOn` | `FALSE` | no per-receipt outcome log |

Only constants that neither `[constants]` nor the run's `[run.constants]` sets are filled, so
your own value always wins: the minimal model's gas runs set `GasMode`, `GasCall` and
`GasBurn`. `Accounts`, `MayFail` and `MaxFails` are never filled. They are the model's world
and its fault assumption, so you always set them. The key can be set at the top level or in a
single run. It is for specs that extend `NearAsync`, directly or through another module; for
any other spec the filled names are not constants it declares, and the runner stops with an
error.

### Checks before TLC starts

The runner validates every loaded `runs.toml` before it starts any TLC process, and stops with
exit code 2 on an error:

- unknown keys, wrong types and malformed names are errors;
- every constant name must be a `CONSTANT` declared by the spec or a module it EXTENDS, or a
  zero-arity definition there (TLC's `<-` overrides a definition too; the library uses that
  for overridable defaults). A `Mod!Name` key must name a zero-arity definition of a module
  reachable from the spec through EXTENDS and INSTANCE. The runner finds them with a simple
  parse of the spec's directory and the library; when it cannot find a module, it prints a
  warning and skips the check;
- a constant may not reuse the name of `init`, `next`, `specification` or of an invariant or
  property the run checks;
- the witness, mutant, sweep and audit tables are validated on every load, even when their
  flag is off (the count of each mutant's `find` text is checked only with `--anti-vacuity`).

### What the runner generates

For each run, the runner writes:

- `MC_<run>.tla`, a wrapper that EXTENDS the spec and defines `const_<C> == <expr>` for each
  constant;
- `MC_<run>.cfg`, a TLC config that substitutes `C <- const_<C>` (a cfg file cannot hold
  tuples, so the values live in the wrapper), or `C <- [Mod] const_Mod_C` for a key `Mod!C`.
  It also names the `INIT` and `NEXT` (or the `SPECIFICATION`), the `INVARIANTS` and the
  `PROPERTIES`. With the audit on, it sets the library's `AuditOn` too.

Keep them with `--keep` to see exactly what TLC checked.

## Every invariant must be able to fail

Must-fail runs are part of the method, not an extra. An invariant that holds in every run
might be true, or it might be vacuous: guarded by a condition that is never reached, or
checking a ghost that never changes. A run that must break it shows that it can fail.

The minimal model pairs a passing run with a must-fail twin that differs in one constant,
`Trusting`, which switches on a wrong `done` that counts without checking its result:

```toml
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

For every invariant:

1. Add a must-fail run that breaks it on purpose, for a reason you can state. Options: a
   constant that switches on a wrong variant of the handler (`Trusting = 'TRUE'` in the
   minimal model), a token deviation (`TokDev`), a forced fault, or a gas menu that reaches
   the edge.
2. Check that the verdict names that invariant (`expect = "violation"`, `invariant = "..."`).
3. Read the trace (`--print-trace`) and confirm that it fails **for the reason in the run's
   comment**, not for an unrelated one.
4. Keep the pair in `runs.toml`, with a comment on the must-fail run saying why it fails.
   Then a later change that makes the invariant vacuous turns the must-fail run into a pass,
   and the runner reports it.

## Witnesses and mutants

A pass says that no reachable state breaks an invariant. It does not say that the invariant
looked at anything. Two shapes pass vacuously in asynchronous models:

- **The antecedent is never reached.** `Idle => P` holds trivially when the system never
  becomes idle again. A dropped `.then` does exactly that: the call's result is a data receipt
  that nothing consumes, so `Idle` never holds and every `Idle => ...` invariant passes, with
  thousands of states explored.
- **The bug is invisible to the invariants.** A removed precondition whose damage the
  platform repairs (an overdraft that the token refuses, followed by a refund) leaves a
  conservation sum intact.

Two kinds of table in `runs.toml` check for both. A **witness** shows that a situation is
reached; a **mutant** shows that a deliberate bug is caught. `--anti-vacuity` runs them after
the plain runs. CI runs it in its own job; without the flag, the tables are only validated.

```sh
python3 tools/run.py examples/pay --anti-vacuity
```

### Witnesses

A witness names a situation `S` that must be reachable. Write `S` inside `~( )`: the runner
defines `Wit_<id> == ~(S)` in the run's wrapper and has TLC check it alone, as an invariant. A
violation means TLC found a state where `S` holds, so the situation was reached.

```toml
[[witness]]
id = "on_paid_sees_failed"
expr = '~(\E r \in Runnable : r.m = "on_paid" /\ ~r.res.ok)'
about = "on_paid sees Failed"   # optional
runs = ["pay_unreg"]            # globs over this file's runs
```

`id` is letters, digits and `_`, starting with a letter, and unique in the file. `runs`
defaults to every `expect = "pass"` run without `expect_window`; the witness is checked once
per listed run.

No violation means `S` never happens: the row reads `never reached`, with the note
`vacuous: witness <id> never reached`, and fails. A situation that is out of reach by design is
documented with `expect = "unreachable"` and a `reason`; then the runner requires the pass, and
fails if the situation is ever reached.

A violation by the initial state shows nothing was reached: the row reads `reached at Init`
and fails, with a note. It almost always means `S` was written without its `~( )`. The
summary line counts it under `other`.

### Mutants

A mutant is a deliberate bug that some run must catch. The runner copies the `.tla` files of
the spec's directory (or, with `library = true`, of the library directory holding `file`) into
the job's temporary directory, replaces `find` with `replace` in the copy, and runs TLC with
the copy in the original's place. Your files are never touched.

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

- `file` is a bare module file name, beside `runs.toml`, or with `library = true` a module of
  the run's library (the first library directory that has it). A library module that also
  sits beside `runs.toml` is refused: TLC would load that copy, not the patched one.
- `find` is exact text. The number of its occurrences must equal `count` (default 1). With
  `--anti-vacuity`, the runner checks every mutant before it starts any TLC process.
- `replace` is required, and may be empty.
- `class` is required: the bug class the mutant stands for.
- `runs` has the same default as for witnesses. Every listed run must be an `expect = "pass"`
  run that checks an invariant or property.

By default, only an invariant violation kills a mutant. An `Assert` (a missing gas key, say)
or a deadlock shows that the mutation broke the model, not that an invariant covers the bug.
`killed_by = ["Books", "assert"]` names the kills that count; list `"assert"` or `"deadlock"`
only when that is the intended detection.

Each listed run is checked with its own invariants and properties. The results:

| result | meaning | verdict |
|---|---|---|
| `killed <inv>` | some run violated an invariant (one in `killed_by`, if given) | ok |
| `killed (assert)`, `killed (deadlock)` | a run stopped on an `Assert`, or (with `deadlock = true`) a deadlock, and no invariant caught the mutant | fails, unless `killed_by` lists `"assert"` / `"deadlock"` |
| `survived` | every run passed | fails, unless `equivalent` is given |
| `equivalent` | survived, as `equivalent` says | ok |
| `timeout` | a job ran past its run's `budget_s` | fails; never counted as survived |
| `error` | a parse or evaluation error | fails |

When `killed_by` is given and only other invariants caught the mutant, it fails with the note
`caught only by ...`. A mutant marked `equivalent` that is killed fails too, so the claim stays
true. A job that timed out or errored fails the mutant even when another run killed it.

Each witness and mutant job has its run's `budget_s`, and is stopped there. A check of a run
that did not match its own expectation is skipped, and reported as a failure.

### The check table

This is the check table of `python3 tools/run.py examples/minimal --anti-vacuity --workers 1`,
shortened:

```
check                        | run                   | expect  | actual          | secs | result
-----------------------------+-----------------------+---------+-----------------+------+-------
witness ping_settles         | tally_ok              | reached | reached         | 0.9  | ok
witness done_sees_failed     | tally_gas_ok          | reached | reached         | 0.9  | ok
mutant ok_guard_dropped      | tally_gas_ok          | killed  | killed Counted  | 0.9  | ok
    tally_gas_ok: violation Counted (53 distinct, 0.9s)
mutant dropped_then          | tally_ok              | killed  | killed Sane     | 0.9  | ok
    tally_ok: violation Sane (8 distinct, 0.9s)
mutant weights_swapped       | tally_gas_ok          | killed  | killed WorkFits | 1.0  | ok
    tally_gas_ok: violation WorkFits (63 distinct, 1.0s)

examples/minimal: mutants 5: killed 5, equivalent 0, survived 0, timeout 0, other 0; witnesses 4 (7 jobs): reached 7, unreachable as documented 0, never reached 0, other 0

12/12 checks as expected
```

Each witness gets one row per run. Each mutant gets one row, with a note per run saying what
that run gave. The summary line per directory counts the results.

### Conventions

- **Every `Sane` includes `NoOrphans`.** It is the platform's check that every data receipt
  has a waiting callback and every callback has its data on the way. It turns a dropped or
  mis-wired `.then` into a violation instead of a vacuous pass.
- **For every `P => Q` invariant**, a witness that `P` is reached (`~(P)`; with `Idle`, write
  `~(Idle /\ ntx > 0)`, since the initial state is idle), and a witness that `Q` can be
  false when that is informative.
- **For every callback that reads a promise result**, one witness per arm: the success value,
  `Failed`, and for token answers the unparsable bytes. Forcing a fault on the callee is not the
  same as delivering `Failed` to the callback; forcing a fault on the callback skips its body.
- **For every guard with a numeric threshold**, a boundary witness: one where the guarded value
  sits exactly at the threshold, and one where the guard refuses.
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
  revoke, or a delivery that never happens. Add one effect invariant per operation: once
  settled after X, X's effect holds.
- **A mutex checked one way catches half the bugs.** "Idle implies the flag is clear" sees a
  lost unlock, but not a lock taken late or a second operation admitted while one is in
  flight. Add the converse (a pending callback implies the flag is set).
- **Bounds and symmetric data hide bugs.** Equal weights hide a weight swap; one transaction
  per actor hides every mutex bug; a balance that always covers the cap hides the cap. A
  witness per guard shows this in a second; a run with asymmetric constants fixes it.
- **A must-fail run should differ from its passing twin in the contract**, not in the
  environment. A control built by removing the attacker is clean by construction.
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

Run it as a `pass` run with `expect_window`, the expected intervals in Ggas:

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

The runner folds the printed values into intervals and checks them; the table shows what it
found under the row (`window Counted 8600-9000`). Values at most `window_step` apart (an integer in Ggas, written
without quotes; 100 by default) join one interval, so the step must be at least the menu's step.
`python3 tools/windows.py --step 100 <log>` does the same for any TLC log, and prints the
intervals in Tgas.

`expect_window` takes ascending intervals, `"lo-hi, lo-hi"`, in two forms:

- **A string** checks the union of all labels.
- **A table** (`expect_window = { Counted = "8600-9000" }`) checks each label separately, and
  fails if a label it does not list prints anything.

Windows inherit the precision of the tables. Trust a window only on calibrated tables
([Calibrating](USAGE.md#calibrating)), and only when it is wider than the rounding on its path.
With the default rounding (`FeeRounding = "up"`), fees and the leftover split can put a
window's lower edge a few Ggas high per receipt on its path, never low; under `"nearest"`,
either edge can be a few Ggas off either way
([N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)). Burns are only
as good as their calibration.

## Least gas and size sweeps

A window maps where something breaks on a menu of values. Two questions need exact edges:

- the least prepaid gas at which a run's operation is safe;
- how a contract behaves at its own size cap and at the protocol limit.

`[[sweep]]` tables in `runs.toml` answer both. Run them with `--sweep`; they are validated on
every load, and skipped otherwise. Each sweep value is one TLC run of a base run of the same
file, with a knob constant set to the value. The sweep table lists one row per reported value
(`sweep`, `run`, `expect`, `actual`, `distinct`, `secs`, `result`), then a summary.

### Least gas

```toml
[[sweep]]
id = "vault_need"
kind = "least_gas"
run = "vault_gas_short"       # base run: its constants, budget and workers
knob = "GasMenu"              # the constant set to each value (or a list of constants)
form = '{%d}'                 # its TLA+ text; %d is the value (default '%d')
lo = 0                        # a value where success fails (default 0)
hi = 300000                   # a value where it holds (required)
success = ["OwedOK"]          # what "safe" means (default: the run's invariants)
window_run = "vault_gas_win"  # optional: bracket from a window run's top bad value
expect_need = 8600            # optional
# exact = true                # optional: scan the bracket instead of bisecting
# step = 100                  # optional, with exact: scan in steps of 100 (default 1: every value)
covers = ["on_deliver"]       # optional, for the audit: the receipts whose edge the knob moves
```

The runner checks that `success` holds at `hi` and fails at `lo`. It bisects in between (about
20 TLC runs over 0..1,000,000 Ggas), and reports `need − 1`, `need` and `need + 1` with their
verdicts. With `window_run`, the window's top bad value and the next menu step bracket the
search, so it takes a few runs; `window_label` picks one label's window, and the window run
must be selected too. The sweep fails unless `need − 1` fails and both `need` and `need + 1`
hold; a failure at `need + 1` is reported as non-monotone. `expect_need`, if given, must equal
the result.

**Bisection finds *a* boundary**: a value where success fails one below and holds at it. That
is the least gas only if success is monotone in the knob, and bisection does not check it:
with success at 20 and again from 50 up, it can report 50. So the result reads `boundary N`.
Gas is not always monotone: more gas for a parent can let a child commit that would otherwise
have failed cleanly, and then run its owed callback short (`examples/trie-gas/leftover` has
the same shape for trie gas).

**A scan checks.** `exact = true` (or `--exact` on the command line, for every least-gas sweep
it runs) scans `lo..hi` in steps of `step` (or `--gas-step N`), `hi` always included, one TLC
run per value. At step 1, the default, it tries every value; at a larger step it tries only a
sample, which can miss a flip between two scanned values. It reports `need N`, the least
scanned value at which `success` holds, with the values where the verdict flips. It fails if
success fails at a scanned value above `N`, and says where
(`non-monotone: ... fails at 21..49 above it; ... holds at every scanned value from 50`). A
scan costs one TLC run per value: narrow the bracket first (a bisection or a window run) and
scan around it.

**Choose `success` with care.** Give it explicitly when the run's invariants also hold at low
gas for the wrong reason: below the gas the first receipt needs, nothing happens and every
invariant holds, so `lo` must sit in the failing region (the window's top value does). A value
whose verdict is neither a pass nor a violation of a `success` invariant (an `Assert`, a
deadlock, a timeout) stops the sweep with an error. The base run's own `expect` does not
matter: a must-fail run is the natural base.

**Ad hoc.** `--least-gas 'GasMenu={%d}' --gas-range 0:300000 [--success OwedOK]` runs the same
search on each selected run, without a `[[sweep]]` table; add `--exact [--gas-step N]` to scan
instead.

### Sizes

```toml
[[sweep]]
id = "memo_cap"
kind = "size"
run = "vault_log_capped"
knob = "Memos"
form = '{%d}'
cap = 16377                   # the contract's own cap (optional)
limit = "MaxLogBytes"         # the protocol limit: a number or a NearAsync limit name
floor = 1                     # optional: drop values below it (default 0)
expect = { "16378" = "pass" } # optional, per value: "pass", "violation <Inv>", "assert", "deadlock"
[sweep.constants]             # optional overrides of the base run's constants
MemoCap = "16377"
```

The values are 1, `cap` and `limit`, each with −1 and +1, at or above `floor`; give `cap`,
`limit` or both. Each value runs with the base run's invariants, and its verdict is reported. A
value listed in `expect` must match; the sweep also fails on a timeout or an error. The limit
names are `NearAsync`'s (`MaxActionsPerReceipt`, `MaxPromisesPerCall`, `MaxJointInputs`,
`MaxReturnedData`, `MaxLogs`, `MaxLogBytes`), read from the run's library.
`examples/owed-effect` has both kinds; `examples/limits` sweeps joint inputs around 128.

### Searching a size with `least_gas`

`least_gas` bisects any knob, not only gas, wherever success is monotone in it. To find the
size at which something stops fitting, make success the failure you are looking for.
`examples/event-logs/batch-payout`'s `payout_edge` sweeps a batch's size with
`success = ["NeverPaid"]` (the recipient never receives the batch). That fails while the
batch's event fits, and holds from the first size whose event is over 16384 bytes, so the
reported `boundary` is that size (217 ids per class there; add `exact = true` to check it by
scanning).

## Auditing what the runs reach

The runs check what you modeled. The audit reports what you modeled but never pushed to its
edges and, from an inventory you give it, what you never modeled at all. It is on for every
plain run; `--no-audit` turns it off.

This is the minimal model's report. Its one owed receipt, `c.done`, has three gaps, all
accepted with a reason:

```
audit examples/minimal/runs.toml: 1 owed or fixed-budget receipt(s), 0 open gap(s), 3 accepted
  c.done    trie       accepted: done writes no storage in this toy (H_done declares no write)
  c.done    least-gas  accepted: done's budget is a fixed 2 Tgas against a 0.6 Tgas burn; tally_gas_win maps the prepaid edge
  c.done    logs       accepted: done logs nothing (H_done declares no log)
```

The runner sets the library's `AuditOn`, so `Exec` prints one fact for each distinct receipt
it runs. The fact records:

- the receipt's marks (owed, detached), and whether it is a callback;
- the gas mode and `TrieGasWorst`;
- whether its budget is fixed (static gas, weight 0);
- the logs and writes its outcome declares.

An **owed** receipt is one that must not fail: a callback that completes or undoes what an
earlier receipt committed
([Owed callbacks and detached work](USAGE.md#owed-callbacks-and-detached-work)).

### What the audit judges

The audit cannot tell which of your callbacks matter. It judges:

- **receipts you mark owed**: with `WithOwed(...)` where you create the receipt, or by naming
  its method in `OwedMethods` (that form counts only a postponed callback on its own account).
  List `OwedOK` among the run's invariants too: it is the check that an owed receipt never
  fails. Every rule below except `inventory` applies to owed receipts;
- **callbacks with a fixed budget** (static gas, weight 0), in gas-mode runs: the `trie`,
  `writes` and `least-gas` rules;
- **callbacks that declare logs**: the `log-size` rule.

Every other receipt gets no gaps. So a callback that completes or undoes earlier work (a
refund, a credit back on `Failed`), left unmarked, with no logs, and run only in fault mode,
leaves the report at `0 open gap(s)`. Mark every such callback owed.

### The gaps

After the runs, the runner prints the gaps for each `runs.toml`:

| rule | reported for | closed by |
|---|---|---|
| `gas` | an owed receipt that no gas-mode run executes | a gas-mode run that reaches it |
| `trie` | an owed receipt, or a callback with a fixed budget, that runs in gas mode but never with `TrieGasWorst` | a run with `TrieGasWorst = "TRUE"` |
| `writes` | the same, which declares no writes in its `TrieGasWorst` runs | `OWriteKey` for each storage write and remove it makes |
| `least-gas` | the same, with no `least_gas` sweep that covers it | a sweep of its budget or of the prepaid gas, listing it in `covers` |
| `logs` | an owed receipt that declares no logs in any run | its logs and events, declared with lengths from its input (`OLog`, `EvLen`) |
| `log-size` | an owed receipt or a callback that logs, with no sweep that covers its log size | a sweep of the input its log grows with, toward `MaxLogBytes` and `MaxLogs`, listing it in `covers` |
| `inventory` | a method in `[audit] methods` that your contract's code runs in no run (the library's token implementations do not count) | a run that reaches it |

A gap closes when a run or sweep reaches what it names, or when you accept it with a reason.

### Sweeps that close a gap

A sweep counts for a receipt only if two things hold:

- Its `covers` lists the receipt, method or `acct.method`. `"on_refund"` closes the rule of the
  sweep's kind: `least-gas` for a `least_gas` sweep, `log-size` for a `size` sweep.
  `"on_refund log-size"` names the rule, for a `least_gas` search over a size (as
  `payout_edge` does); `least-gas` can only come from a `least_gas` sweep.
- Its base run actually runs the receipt. A `window_run` that does is not enough: the sweep
  varies the base run.

The credit comes from `runs.toml`: the sweep need not have run in this invocation, so run
`--sweep` to check that it holds.

### Methods with two roles

Some methods run in two roles: as an owed callback in one place and as a plain callback in
another. The audit judges each role on its own runs and reports its gaps per role, labeled
`(owed)` or `(callback)`. A direct call of the method, not as a callback, closes neither.

A `covers` entry for such a method must name the role, as in `"on_refund least-gas owed"`, or
it credits nothing. An entry that names only the method, with no account, needs the role as
soon as the method runs in both roles on any account. An entry that names a role credits that
role even when the selected runs show only one role.

Where the library's token code and your contract both run a method, a `covers` entry credits
only your contract's runs.

### The inventory: `[audit] methods`

The audit cannot see a handler you left out: it leaves no facts. The inventory closes that gap.
Fill `methods` from the source, not from the model:

- every callback the contract schedules (`.then(...)`, `#[private]` methods);
- every method other contracts call on it: token receivers (`*_on_transfer`), and resolvers
  of its own transfers.

A method no run executes is then reported. Without a `methods` list, the report's header says
that a method no run executes goes unreported.

```toml
[audit]
methods = ["ft_on_transfer", "on_resolve", "v.on_refund"]   # method, or acct.method

[audit.accept]
"on_refund trie" = "writes no storage: it only sends a Transfer"
"v.on_legacy" = "out of scope: disabled by the owner since the last upgrade"
```

### Accepting a gap

`accept` silences a gap and prints its reason instead:

- `"<key> <rule>"` accepts one rule;
- `"<key> <rule> owed"` (or `callback`) accepts one role's gap, for a method with both;
- `"<key>"` accepts every rule for that key;
- the key is `acct.method` or `method`.

The reason must be a non-empty string. Gaps of the library's own token methods
(`ft_resolve_transfer`, `mt_resolve_transfer`) are listed apart: they are standard
implementations, worth checking only where your contract depends on them.

### Failing on open gaps

A plain run only prints the report. With `--anti-vacuity`, each open gap fails like a vacuous
witness, and so does a `runs.toml` with no `[audit] methods`:

```
audit: 3 runs.toml file(s) checked, 2 open; FAILED: audit:v.on_res gas@my/runs.toml audit:methods@my/runs.toml
```

Gaps of the library's token methods never fail. Neither does a `runs.toml` of which only some
runs were selected: a run left out may close its gaps. Its header says so.

### Limits of the audit

- Facts come only from the runs that ran in this invocation. With some runs selected, the
  header says how many, and gaps are judged on those.
- A run whose library predates the hook runs as before and contributes nothing.
- With the audit off, `Exec` is unchanged. With it on, TLC checks one set membership per
  receipt run (a few percent of the time). Each worker prints a fact once; the runner merges
  them.
- A fact is printed when TLC evaluates `Exec`. A conjunct after `Exec` that rules the step
  out still leaves the fact, so put a handler's guards before `Exec`.
- Witness, mutant and sweep jobs are never audited.
- Outside the runner, `AuditOn <- TRUE` in a cfg prints the same tuples. A run that sets
  `AuditOn` itself keeps its value, and its facts are still read.
- Account ids in keys may hold dots (`vault.near.on_refund`); the method is the part after
  the last dot.
- Facts are keyed by account and method, not by the constants a run sets. A fix switch's
  runs therefore close the gaps of the same method as written. To see the gaps of the contract
  as written, name only its runs on the command line.

## Advanced

### Peel mode

A violating run stops at the first invariant that breaks. To see every invariant a change
breaks, run with `--peel`. On a violation, the runner drops the violated invariant or property
and runs TLC again, until the run is clean, stops for another reason, or nothing is left to
check. The `actual` column then shows the set of names that broke, such as
`peeled {Books, Sane}`.

In peel mode, `expect = "violation"` means that the run's `invariant` is in that set and the
last rerun ended clean (or with every name peeled). Any other expectation requires that nothing
was peeled. Peel mode checks verdicts, budgets and vacuity only, not `expect_output` or
`expect_window`.

### A definition inside another module

A constant key can override a definition of another module, with a module-qualified key,
`Mod!Name`:

```toml
"NearFees!FeeRounding" = '"nearest"'
```

It overrides a definition of a module the spec EXTENDS or INSTANCEs, directly or through its
modules: TLC's `Name <- [Mod] expr`, which also reaches a named instance such as `NearAsync`'s
`NearFeeTable`. It works for definitions only. A `CONSTANT` of `Mod` given this way is an
error: assign it unqualified, or bind it with `INSTANCE Mod WITH`.

### Stack size and JVM options

TLC evaluates recursive operators on the JVM thread stack. Every run gets `"16m"`, enough for
the library's sums over a thousand receipts and more; the key `stack` sets another size, such
as `"512k"`. A recursive operator of your own that takes one element per level can still
overflow on a large set: split the set instead, as `NearAsync.KeySum` does.

`TLC_JAVA_OPTS` adds JVM options to every TLC process, for example `-Xmx4g` for a larger heap.
They come after the runner's default thread stack, `-Xss16m`, so an `-Xss` there wins. A run's
own `stack` comes after them and wins over both.
