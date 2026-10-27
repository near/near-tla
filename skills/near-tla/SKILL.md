---
name: near-tla
description: Model-check a NEAR smart contract's cross-contract logic with near-tla (TLA+/TLC) to find async bugs in callbacks, promises, refunds and gas. Use when asked to model a NEAR contract in TLA+, to hunt for cross-contract or callback bugs in a NEAR contract, to extend an existing near-tla model, or to triage and replay a near-tla counterexample.
---

# Model-check a NEAR contract with near-tla

You will model the contract's methods on the near-tla library, state what must hold, let TLC
explore every receipt order and failure within small bounds, and turn each counterexample into
a confirmed finding or a documented non-issue. Work through the steps in order; each ends on a
check you can run.

Two words carry the method:

- **vacuous**: a pass that proves nothing, because the run never reached the situation the
  property is about, or the property could not fail. Every pass you report is shown
  non-vacuous by a must-fail run, witnesses and mutants.
- **hypothesis**: what a counterexample is until it is replayed on the compiled contract or
  traced through the source.

## Step 0: find near-tla and check it runs

`NT` is the near-tla checkout: the directory holding `tools/run.py`, `modules/` and `docs/`.
If this skill sits at `NT/skills/near-tla/`, NT is two levels up. Otherwise use the parent of
`$NEAR_TLA_LIBRARY`, or ask the user where their checkout is. TLC needs Java 21 and
`NT/tools/tla2tools.jar` (the README's Quickstart fetches it).

Read `NT/docs/CONCEPTS.md` once: the vocabulary table maps NEAR terms to model names, and
"What a pass means" sets the claims you may make.

**Done when** `python3 NT/tools/run.py NT/examples/minimal` ends with `5/5 runs as expected`.

## Step 1: inventory the contract

Read the contract source. In a scratch file `model/INVENTORY.md` beside where the model will
live (inside the user's project), list:

- every public method a user or another contract can call, with its deposit and who may call it;
- every cross-contract call it makes (`ext_*::ext(..)`, `Promise::new(..)`), with its static gas
  and weight, and the callback chained with `.then`;
- every callback (`#[private]` methods reached by `.then`), what it reads from its promise result,
  and what it completes or undoes;
- the state each method writes before the call goes out, and the assets that move (NEAR,
  fungible or multi tokens, storage deposits);
- the token standards involved (NEP-141, NEP-145, NEP-245, wNEAR), and whether keys, signers,
  `promise_and`, yield/resume, account creation or deletion appear.

**Done when** every `Promise`, `.then` and `ext(` in the source maps to a row, and every
callback has a line saying what goes wrong for a user if it fails or sees Failed.

## Step 2: write the properties first

Write each property in words, then in TLA+, before any handler. For each fund-moving method,
ask: after everything settles (`Idle`), is every user whole? Prefer per-user and per-operation
obligations ("each deposit is credited or refunded once") over one conservation total, which
balances while one user's money moves to another. Add the library sanity checks
(`NearConserved`, `GasBounded`, `NoOrphans`) and, for each callback that completes or undoes
an earlier commit, mark it owed (`OwedMethods`) and check `OwedOK`.

**Done when** every callback row of the inventory is covered by a property that a mishandled
failure would break.

## Step 3: write the model

Copy the closest example from `NT/examples/` (start from `minimal` if unsure) and follow
`NT/docs/TUTORIAL.md` for the shape: variables and `Init` with `PlatformInit`, one handler per
method returning an `Outcome`, a run step with `Exec(r, O)` and the state change guarded by
`Ok(r, O)`, a dispatcher, one `Submit` step per user action, and `ForcedFail` in `Next`. Name
the steps of `Next` so traces label them. Look up each feature where `NT/docs/USAGE.md` covers
it:

| the contract uses | USAGE section |
|---|---|
| fungible tokens, `ft_transfer_call` | 8. Calling tokens, 9. Receiving tokens |
| signer, access keys, nonces, meta transactions | 10. Signer and keys |
| self-signed transactions | 11. Local-receipt priority |
| gas budgets, prepaid gas | 12. Fault mode and gas mode |
| callbacks that must not fail | 13, "Owed callbacks and detached work" |
| `promise_and`, yield/resume, block height | 14. Joint callbacks, yield/resume and the block clock |
| storage deposits | 15. Storage staking per byte |
| account creation, deletion, deploys | 16. Creating and deleting accounts |

Keep each handler faithful to the code path by path: every `require!` becomes an `OErr`, every
branch that creates receipts creates the same ones, and `ids` counts exactly the fresh ids
used (a wrong count gives two receipts one id and fake violations). Note in a comment the
source lines each handler models.

**Done when** `python3 NT/tools/sany.py <model-dir>` parses, and every inventory method has a
handler or a comment saying why it is out of scope.

## Step 4: write the runs

In `runs.toml` (reference: `NT/docs/RUNNER.md`), set `platform_defaults = true`, the accounts,
and small bounds: two or three accounts, `MaxTx` of 1 or 2, one forced fault. Then, for each
property:

- a **must-pass** run of the contract as written, in fault mode with the calls that can fail in
  `MayFail`;
- a **must-fail** run that breaks it on purpose (a switch constant that reproduces the bug
  class the property guards: a callback that ignores its result, a missing rollback), with
  `expect = "violation"` and the property named;
- **witnesses** that each callback's success arm and failure arm are reached;
- **mutants** for the bug classes: a dropped `.then`, a failure branch that skips its rollback,
  an inverted result check.

List the contract's methods in `[audit] methods`.

**Done when** `python3 NT/tools/run.py <model-dir> --anti-vacuity` reports every run as
expected, every witness reached and every mutant killed. A surviving mutant means a property
is too weak: strengthen the property, not the mutant.

## Step 5: go to gas mode where it matters

For each owed callback and each call with a fixed gas budget, add a gas-mode run. Without
measured burns, use the host-cost floor (`HostFloorGas`, USAGE section 12): a callback that
runs out on the floor runs out on real wasm too. Declare storage writes (`OWriteKey`) and run
with `TrieGasWorst`; find the least gas with a sweep. Then read the audit the runner prints
after the table and close each gap with a run, or accept it in `[audit.accept]` with a reason
that cites the source line or a run.

**Done when** the audit reports 0 open gaps and every accept names its evidence.

## Step 6: triage every counterexample

For each run that fails unexpectedly, print the trace:

```sh
python3 NT/tools/run.py <model-dir> <run> --print-trace
```

Walk it step by step against the source and classify it:

- **contract bug**: the code does what the trace does. Keep it as a hypothesis for step 7.
- **model error**: a handler does something the code does not. Fix the handler, rerun, and
  note the fix.
- **unreachable**: the schedule needs an order a network does not produce. Name the
  over-approximation in `NT/docs/SEMANTICS.md` ("Not modelled") that allows it. A reorder of
  two receipts between the same pair of accounts is reachable (SEMANTICS S4), so it stays a
  hypothesis until the schedule is shown unreachable.

**Done when** every failing run has a classification with the evidence (source lines, the
SEMANTICS entry) written down.

## Step 7: validate on the compiled contract

Follow `NT/docs/VALIDATING.md`. Build the contract's wasm and write a near-workspaces sandbox
test that replays each contract-bug hypothesis: the same transactions, the prepaid gas from a
gas-mode trace, a stub receiver that fails where the trace has a forced fault, and an
assertion of the broken property. Use near-contract-sim if the user has access. When an
ordering cannot be forced in the sandbox, replay the failure parts and argue the order from
the SEMANTICS ordering rules (S1-S5) and the code.

**Done when** each finding has a passing replay test that shows the bug, or is marked "not
replayed" with the reason and the code-reading argument.

## Step 8: report

Write `model/FINDINGS.md` with the template in `NT/docs/VALIDATING.md`: for each finding, the
impact, the property, the trace, the replay, the run's bounds and switches, the near-tla commit
and protocol version, and a suggested fix. Then state what the passing runs cover, in the terms
of CONCEPTS "What a pass means": the bounds, the modelled methods, the under-approximations in
SEMANTICS "Not modelled" that apply to this contract, and the gaps accepted in the audit.

Findings in a contract the user does not own are confidential: give them to the user, who
reports them privately to the maintainers' security contact.

**Done when** every finding and every accepted gap appears in `FINDINGS.md`, and the summary
states the bounds under which the passes hold.
