# near-tla

TLA+ models of NEAR's runtime execution semantics, for model-checking smart contracts.

NEAR contracts talk to each other through asynchronous receipts. A cross-contract call can fail
after the caller has already committed, a callback runs whether or not its call succeeded, a
failed receipt reverts only itself, refunds travel as separate receipts, and gas is split
between children by static amounts and weights. Most cross-contract bugs live in these rules.
near-tla encodes them as reusable TLA+ modules. You write a model of your contract's handlers
on top of them, state the properties it must keep, and let TLC explore every order and failure
the runtime allows.

## Why you can trust it (and where you can't)

[`docs/SEMANTICS.md`](docs/SEMANTICS.md) is the trust document. In short:

- **Every rule cites nearcore at a pinned revision:** 2.14.0-rc.5, commit `b7b4737`, protocol
  version 88. Each entry gives the `path:line` the rule comes from, the operator that encodes
  it, and how far it has been checked.
- **Gas semantics and fees are checked per receipt against nearcore**, through
  near-contract-sim, which runs nearcore's own `Runtime::apply`. Probe contracts are swept over
  a grid of prepaid gas, and every receipt's status, attached gas and failure edge is compared
  with the model: **74 flows × 1313 prepaid points, all matching; 108,986 child gas splits, 0
  mismatches**. See [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md).
- **What is not modelled** is listed, item by item, with what each omission could hide:
  [Not modelled](docs/SEMANTICS.md#not-modelled).
- **Over- versus under-approximations.** Most omissions are over-approximations: the model
  allows more orders than a network produces, so it misses no bug but can report
  counterexamples no network reaches. Replay every counterexample in the sim. (Receipts from
  one account to another overtaking each other does happen in nearcore,
  [S4](docs/SEMANTICS.md#s4-no-per-pair-order), so such a reorder alone does not make a
  counterexample spurious; its schedule still has to be reachable.) A few are
  under-approximations, which can hide bugs (for example, local-receipt priority under a full
  chunk); they are listed separately in
  [Under-approximations](docs/SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs).
  Fees are rounded up by default and the unused-gas split then hands out no rounding
  remainder, so a gas budget the model finds enough is enough as far as the fee table and the
  split go.

## Quickstart

You need git, Java 21 and Python 3.11 or later (standard library only).

Clone the repo and work from its root:

```sh
git clone https://github.com/near/near-tla.git
cd near-tla
```

Fetch the pinned TLC jar (tla2tools v1.7.4) and check its hash, as CI does:

```sh
curl -sSfL -o tools/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
echo "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  tools/tla2tools.jar" \
  | shasum -a 256 -c -        # Linux: sha256sum -c -
```

Run every example and check its expected verdicts:

```sh
python3 tools/run.py examples/
```

Each example has must-pass runs and must-fail runs. The runner exits nonzero if any verdict
differs from its expectation. `python3 tools/run.py --help` documents the `runs.toml` format.
With `--anti-vacuity` it also checks that each example's witnesses are reached and its mutants
are caught, so a pass cannot be vacuous ([Witnesses and mutants](docs/USAGE.md#witnesses-and-mutants)).

To model your first contract, follow [`docs/USAGE.md`](docs/USAGE.md). It starts from
[`examples/minimal`](examples/minimal/), a complete model you can copy; your model can live
outside this repo, and the runner still finds the library.

## Repo map

| path | contents |
|---|---|
| [`modules/`](modules/) | the library: one flat directory, passed to TLC as `-DTLA-Library` |
| [`examples/`](examples/) | toy contracts, each with a `runs.toml` of must-pass and must-fail runs; `minimal` is the starting point, `platform-selftest` checks the library itself against known nearcore outcomes |
| [`tools/`](tools/) | `run.py` (the runner), `sany.py` (parse check), `windows.py` (print-only gas windows), `tlctrace.py` (counterexample summaries), `tlcparse.py` (TLC output parsing), `check_links.py` (offline link check), `test_run.py` (the runner's self-tests) |
| [`conformance/`](conformance/) | a Rust crate that checks the model against nearcore through near-contract-sim and produces calibrated gas tables. Runs locally only |
| [`docs/`](docs/) | [`SEMANTICS.md`](docs/SEMANTICS.md) (rules, citations, trust), [`USAGE.md`](docs/USAGE.md) (modelling a contract), [`CONFORMANCE.md`](docs/CONFORMANCE.md), [`VERSIONING.md`](docs/VERSIONING.md) |

### Modules

| module | what it provides |
|---|---|
| `NearAsync` | the platform: receipts, callbacks and promise results, joint callbacks (`promise_and`), yield/resume with its timeout, a block clock, revert scope, deposit refunds, Transfer and Stake, account kinds and implicit creation, calls to code-less accounts, signer propagation, local receipts, storage staking (a fixed floor, or per byte), and gas as a bounded quantity (fault mode or gas mode) |
| `NearKeys` | access keys: full-access and function-call permissions, signed submission, AddKey/DeleteKey receipts and their storage bytes, key actions bundled atomically with a call, delegate actions |
| `NearFees` | NEAR's action and receipt fees in Ggas, per protocol version 84-88 (pure definitions) |
| `TokenCommon` | the shared token argument record, selectable non-standard behaviours, resolver arithmetic, an arbitrary receiver |
| `Nep145` | NEP-145 storage management and the token ledger |
| `Nep141` | NEP-141 fungible-token core, including `ft_transfer_call` and its resolver and gas shape |
| `WNear` | wNEAR's `near_deposit` / `near_withdraw` |
| `Tokens` | the top of the FT stack: dispatch, atomic batches, supply checks. Extend this one |
| `Nep245` | an external NEP-245 multi-token contract |
| `CalibStd` | measured gas tables for a standard FT and a wNEAR-like token (generated by `conformance/`) |

Dependencies (`A → B`: A extends B):

```
Tokens → WNear → Nep141 → Nep145 → TokenCommon → NearAsync
                           Nep245 → TokenCommon
                         NearKeys → NearAsync
NearAsync uses NearFees as a named instance (NearFeeTable)
CalibStd stands alone; instantiate it (Std == INSTANCE CalibStd)
```

A model that needs both tokens and keys writes `EXTENDS Tokens, NearKeys`. TLA+ merges the
shared `NearAsync` base.

## Status and versioning

No release has been tagged yet; changes accumulate under `[Unreleased]` in
[`CHANGELOG.md`](CHANGELOG.md). The behaviour encoded is protocol version
**88** at nearcore 2.14.0-rc.5. `NearFees` also carries the fee tables of 84-87, selected by
`FeeProtocol`; the other rules are 88's. [`docs/VERSIONING.md`](docs/VERSIONING.md) says what
counts as a breaking change, what each release states about its protocol assumptions, and how
to move to a new protocol version.

## Roadmap

### Done (unreleased)

Everything planned for v0.2 is in; it is waiting for a release tag.

- `promise_and`: callbacks that join several promise results (SEMANTICS C6).
- Yield/resume (NEP-519), with an abstract block clock for the timeout (C7, S3).
- Fees rounded up instead of to the nearest Ggas, and the unused-gas split without a
  whole-Ggas remainder, so gas edges err on the safe side
  (`FeeRounding`, N-precision); calibrated burns fitted as an upper envelope.
- Per-sender-receiver ordering: dropped. nearcore keeps no per-pair order at protocol 88
  (SEMANTICS S4), so a pair-order switch would hide real bugs. Not every order the model
  allows is reachable, though: a counterexample's schedule still needs replaying.
- Delegate actions (NEP-366 meta transactions), where the signer is the relayer and the
  predecessor the user (SEMANTICS K4, `examples/meta-tx`).
- Per-byte storage staking, opt-in next to the fixed floor (`StoragePerByte`, SEMANTICS B2,
  `examples/storage-stake`): the bytes of writes, keys, created accounts and token
  registrations, checked after every receipt with the 770-byte zero-balance exemption.
- CreateAccount and DeleteAccount (SEMANTICS A6, A7, `examples/account-lifecycle`): the
  creation rules, deletion with its payout, receipts to a deleted account, and an account
  created again; a lone DeleteAccount created by a receipt runs right after it (instant
  receipts, S5). DeployContract is still open.

### Later

- **An optional conformance CI job.** The suite runs locally only today, because
  near-contract-sim is a private git dependency. A job that runs it needs sim access through a
  deploy key or an app token.
- **Promote rules to "sim" validation** as the conformance probes cover them (the rules marked
  in `docs/SEMANTICS.md`). Per-byte storage is checked by sim tests only; a probe flow for it
  needs a re-sweep of every flow.
- **Storage bytes from the calibrator:** a per-(method, path) table of the bytes each call
  writes, measured in the sim beside the gas burns, so that models need not count `OStor`
  bytes by hand.
- **Other gaps from the [Not modelled](docs/SEMANTICS.md#not-modelled) list:** the
  function-call AddKey per-byte fee; access-key allowances and transaction validity (nonces);
  DeployContract, deterministic-account state init, global contracts and
  gas keys.
- **More calibrated standard tables:** further near-contract-standards versions, and NEP-245.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.
