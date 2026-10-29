# near-tla

Model-check the cross-contract logic of NEAR smart contracts with TLA+.

New to NEAR's receipts or to TLA+? [CONCEPTS.md](docs/CONCEPTS.md) explains both in a page each
and defines the terms used below (receipt, callback, invariant, behavior, counterexample).

On NEAR, a call to another contract is not part of one atomic transaction. It runs later, as
a separate receipt. It can fail after the caller has already committed. The caller's callback
runs either way, and has to cope with the failure. Deposits come back as separate refund
receipts, and gas is split between calls by fixed rules. Most cross-contract bugs live in these
rules, and tests rarely reach them, because a test runs the one order and the one outcome the
sandbox happens to produce.

near-tla encodes NEAR's runtime rules as reusable TLA+ modules. You write a small model of
your contract's methods on top of them and state what must always hold, for example "a user's
deposit is either credited or refunded". The TLC model checker then tries every order of
receipts and every failure you enable (the calls you let fail, out of gas at the prepaid amounts
you list), within bounds you choose, and shows you a step by step counterexample when the
property breaks.

It catches bugs such as:

- a callback that acts as if its call succeeded when it failed;
- state committed before a call that later fails, and never rolled back;
- a refund or a callback that arrives after another transaction has used the money;
- a callback that runs out of gas at some prepaid amounts, so its cleanup never happens;
- two receipts between the same pair of accounts that run in the opposite order to the one
  the contract assumed.

## Quickstart

You need git, curl, Java 17 or later (CI uses 21) and Python 3.11 or later (standard library
only).

```sh
git clone https://github.com/near/near-tla.git
cd near-tla

# Fetch the pinned TLC jar (tla2tools v1.7.4) and check its hash, as CI does.
curl -sSfL -o tools/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
# Check the hash with whichever tool your system has (macOS: shasum; Linux: sha256sum).
echo "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  tools/tla2tools.jar" \
  | shasum -a 256 -c -
echo "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  tools/tla2tools.jar" \
  | sha256sum -c -
```

Run the minimal example. It models a contract whose callback must check its promise result,
in a correct version and a buggy one:

```sh
python3 tools/run.py examples/minimal
```

Every run prints `ok`: each did what its entry in `runs.toml` expects, and the buggy version
fails on purpose. To see the bug the buggy version has, print its counterexample:

```sh
python3 tools/run.py examples/minimal tally_trusting --print-trace
```

The trace reads like a story: the user's `ping`, the call to `work` failing, the callback
`done` seeing Failed and counting anyway. The [tutorial](docs/TUTORIAL.md) builds this model
from scratch and explains every line.

After the table, the runner prints an audit. It lists the receipts the runs model but never push
to their gas, storage or log edges, and says which gaps are open and which you accepted with a
reason. The first command above ended with `0 open gap(s), 3 accepted`: the shipped model
accepts its three gaps. The second command ran one run of five, so the audit judged only that
run and reported `1 open gap(s)`: the gas-mode run that would close it was not selected. That is
expected here. The audit is informational unless you pass `--anti-vacuity`
([RUNNER.md](docs/RUNNER.md#the-audit-lines)).

To run every example in the repo: `python3 tools/run.py examples/`. That is about 250 runs and
takes about 5 minutes on 4 cores (the run count and the time vary), and it prints several
hundred lines, including `note:` lines from the audits of the shipped examples. Whether it
passed is the `N/N runs as expected` line, which comes before the audit reports, and the exit
code (0 when every run came out as expected).

## What a result means

**A pass** means every invariant held in every behavior (every possible run) TLC explored.
It holds:

- within the run's bounds: the number of transactions, forced failures and prepaid gas amounts
  you chose;
- for your model of the contract, which is a hand-written abstraction of the code;
- under the runtime rules of protocol version 88 (nearcore 2.14.0); which protocol version
  mainnet runs, as of what date, and what differs from 88 are in
  [SEMANTICS.md](docs/SEMANTICS.md#reference-revision);
- for the properties you wrote, and no others.

**A failure** is a counterexample: a hypothesis about your contract. Confirm it on the compiled
contract before you report it. [VALIDATING.md](docs/VALIDATING.md) shows how to replay it in
[near-contract-sim](https://github.com/near/near-contract-sim), which runs your wasm on
nearcore's runtime and can force the trace's failures and receipt order, or in a local sandbox.

[CONCEPTS.md](docs/CONCEPTS.md#what-a-pass-means) explains both in more detail.

## Why you can trust it, and where you can't

[SEMANTICS.md](docs/SEMANTICS.md) is the trust document.

- **Every rule cites nearcore** at a pinned revision (2.14.0, commit `bc4e9e8`): the
  `path:line` it comes from, the operator that encodes it, and how far it has been checked.
- **Gas and fees are checked against nearcore.** A simulator, near-contract-sim, runs
  nearcore's own `Runtime::apply` on small test contracts written to exercise the rules, across
  a grid of prepaid gas. Every receipt's status matched the model, every attached gas was
  within 5 Ggas, and every one of 210,283 gas splits between child calls matched exactly (across
  the three flow sets)
  ([CONFORMANCE.md](docs/CONFORMANCE.md) has the counts). Users replay their own
  counterexamples in the same sim (or in the near-workspaces sandbox)
  ([VALIDATING.md](docs/VALIDATING.md)).
- **Receipt order is not part of that comparison.** The ordering rules rest on targeted
  simulator tests (local receipts first, no order between a pair of accounts) and on reading
  nearcore (the rest), as each rule's entry in SEMANTICS says.
- **What is not modeled is listed**, entry by entry, with what each omission could hide
  ([Not modeled](docs/SEMANTICS.md#not-modeled)). Of its 50 entries, 15 are
  over-approximations (the model allows more than a network does, so it can report a
  counterexample no network reaches), 24 are under-approximations (they can hide bugs; several
  apply at the default settings) and 11 are outside the library's scope.
- **The library is checked like a model.** The examples carry their own checks that a pass
  means something: must-fail runs, mutants their properties must catch, and witnesses that
  their situations are reached. CI runs them all.

## Documentation

| read | when |
|---|---|
| [CONCEPTS.md](docs/CONCEPTS.md) | first: NEAR's execution model and TLA+ in a page each, the vocabulary, what a result means |
| [TUTORIAL.md](docs/TUTORIAL.md) | to write your first model, step by step |
| [USAGE.md](docs/USAGE.md) | while modeling your contract: tokens, keys, gas, storage, accounts, calibration |
| [RUNNER.md](docs/RUNNER.md) | to run checks, read traces, and make sure a pass means something |
| [VALIDATING.md](docs/VALIDATING.md) | when TLC finds a counterexample: replay it, write it up |
| [SEMANTICS.md](docs/SEMANTICS.md) | to know exactly which runtime rule each operator encodes, and what is left out |
| [CONFORMANCE.md](docs/CONFORMANCE.md) | maintainers: how the model is checked against nearcore (to calibrate your own contract, see USAGE.md) |
| [VERSIONING.md](docs/VERSIONING.md) | what a release promises, how releases are made, and how protocol upgrades are handled |

## Using it with an AI coding agent

[`skills/near-tla/SKILL.md`](skills/near-tla/SKILL.md) is an agent skill that walks a coding
agent through the whole method on your contract: inventory the methods and callbacks, write
the properties, model the handlers, write must-pass and must-fail runs, run TLC, close the
audit gaps, triage counterexamples, replay them in near-contract-sim and write up the findings.

For Claude Code, copy or link the directory into your skills:

```sh
mkdir -p ~/.claude/skills
ln -s "$PWD/skills/near-tla" ~/.claude/skills/near-tla              # for every project

mkdir -p path/to/your-project/.claude/skills
ln -s "$PWD/skills/near-tla" path/to/your-project/.claude/skills/   # for one project
```

Other agents can be pointed at the `SKILL.md` file directly.

## Repo map

| path | contents |
|---|---|
| [`modules/`](modules/) | the library: one flat directory, passed to TLC as `-DTLA-Library` |
| [`examples/`](examples/) | small contracts, each with a `runs.toml` of must-pass and must-fail runs; `minimal` is the starting point, `platform-selftest` checks the library itself against known nearcore outcomes |
| [`tools/`](tools/) | `run.py` (the runner), `tlctrace.py` (counterexample stories), `sany.py` (parse check), `windows.py` (print-only gas windows), `tlcparse.py` (TLC output parsing), `audit.py` (what the runs reach), `check_links.py` (offline link check), `test_run.py` (the tools' tests) |
| [`skills/`](skills/) | the agent skill |
| [`conformance/`](conformance/) | a Rust crate that checks the model against nearcore through near-contract-sim, and produces calibrated gas tables. Maintainers run the suite; you can use its `calibrate` tool on your own contract ([USAGE.md](docs/USAGE.md#calibrating)) |
| [`docs/`](docs/) | the documentation above |

### Modules

| module | what it provides |
|---|---|
| `NearAsync` | the platform: receipts, callbacks and promise results, joint callbacks (`promise_and`), yield/resume with its timeout, a block clock, revert scope, deposit refunds, Transfer and Stake, account kinds and implicit creation, calls to code-less accounts, signer propagation, local receipts, storage staking (a fixed floor, or per byte), and gas as a bounded quantity (fault mode or gas mode) |
| `NearKeys` | access keys: full-access and function-call permissions, signed submission, AddKey/DeleteKey receipts and their storage bytes, key actions bundled atomically with a call, delegate actions |
| `NearFees` | NEAR's action and receipt fees in Ggas, per protocol version 84-88 (pure definitions) |
| `TokenCommon` | the shared token argument record, selectable non-standard behaviors, resolver arithmetic, an arbitrary receiver |
| `Nep145` | NEP-145 storage management and the token ledger |
| `Nep141` | NEP-141 fungible-token core, including `ft_transfer_call` and its resolver and gas shape |
| `WNear` | wNEAR's `near_deposit` / `near_withdraw` |
| `Tokens` | the top of the FT stack: dispatch, atomic batches, supply checks. Extend this one |
| `Nep245` | an external NEP-245 multi-token contract |
| `CalibStd` | measured gas tables for a standard FT and a wNEAR-like token (generated by `conformance/`) |
| `CalibStdMt` | measured gas tables for a near-sdk-contract-tools 4.0.0 NEP-245 token, for `MtGasShape = "tools"` (generated by `conformance/`) |
| `StorStd` | measured storage bytes for the same tokens' calls, for `OStorKey` (generated by `conformance/`) |

Dependencies (`A → B`: A extends B):

```
Tokens → WNear → Nep141 → Nep145 → TokenCommon → NearAsync
                           Nep245 → TokenCommon
                         NearKeys → NearAsync
NearAsync uses NearFees as a named instance (NearFeeTable)
CalibStd, CalibStdMt and StorStd stand alone; instantiate them (Std == INSTANCE CalibStd)
```

A model that needs both tokens and keys writes `EXTENDS Tokens, NearKeys`. TLA+ merges the
shared `NearAsync` base.

## Requirements and limits

- **TLC only.** The library uses TLC's `Assert`, `PrintT`, `TLCGet` and `TLCSet`, and the runner
  overrides definitions through the TLC config; Apalache and TLAPS will not check it as is.
- **Safety properties.** Models check invariants; there is no liveness or fairness. "Callbacks
  always run" is checked as the invariant `NoOrphans`
  ([CONCEPTS.md](docs/CONCEPTS.md#design-choices)).
- **Bounded.** TLC explores every behavior within the constants you set, and nothing beyond
  them ([choosing bounds](docs/CONCEPTS.md#bounds-and-the-size-of-the-state-space)).

## Status and versioning

Each release is a `vX.Y.Z` tag with its section in [`CHANGELOG.md`](CHANGELOG.md); release-plz
writes the sections from the commit titles, and its open release pull request shows what the
next release holds. The behavior encoded is protocol version **88** at nearcore
2.14.0. `NearFees` also carries the fee tables of 84-87, selected by `FeeProtocol`; the
other rules are 88's. [VERSIONING.md](docs/VERSIONING.md) says what counts as a breaking
change, what each release states about its protocol assumptions, and how the library moves to a
new protocol version.

Planned next:

- Check more of the runtime rules against the simulator, including the order of receipts
  across shards, which needs a multi-shard simulator.
- Model more of what is [not modeled](docs/SEMANTICS.md#not-modeled) today: the rest of
  transaction validity, the protocol limits, state init for deterministic accounts, gas keys.
- Measured gas tables for more token implementations and versions, and more event logs.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.
