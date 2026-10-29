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

**Done when** `python3 NT/tools/run.py NT/examples/minimal` reports `5/5 runs as expected`.

## Step 1: inventory the contract

Read the contract source. In a scratch file `model/INVENTORY.md` beside where the model will
live (inside the user's project), list:

- every public method a user or another contract can call, with its deposit and who may call it;
- every cross-contract call and Transfer it makes (`ext_*::ext(..)`, `Self::ext(..)`,
  `Promise::new(..)`), with its static gas and weight, and the callback chained with `.then`.
  A call that sets neither gets near-sdk's defaults, static gas 0 and weight 1: write those
  down, because a callback that only shares the leftover can be starved by the caller's
  choice of prepaid gas;
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
an earlier commit, mark it owed (`OwedMethods`) and check `OwedOK`. The audit in step 5 sees
only the callbacks you mark, so mark every one that restores state, refunds or credits back.
The platform variable `paid` records the NEAR each account received from Transfers and
refunds, per transaction, which is what a per-payee property needs.

**Done when** every callback row of the inventory is covered by a property that a mishandled
failure would break.

## Step 3: write the model

Copy the closest example from `NT/examples/` (start from `minimal` if unsure) and follow
`NT/docs/TUTORIAL.md` for the shape: variables and `Init` with `PlatformInit`, one handler per
method returning an `Outcome`, a run step with `Exec(r, O)` and the state change guarded by
`Ok(r, O)`, a dispatcher whose first arm is `PlatformStep` (`PlatformStepK` with keys), one
`Submit` step per user action, and `ForcedFail` in `Next`. Name
the steps of `Next` so traces label them. Look up each feature where `NT/docs/USAGE.md` covers
it:

| the contract uses | USAGE section |
|---|---|
| NEAR Transfers, refunds | 4. Receipts (`XFER`; `MayFail = {"XFER"}` lets a Transfer fail, and its amount comes back to `rto`) |
| fungible tokens, `ft_transfer_call` | 8. Calling tokens, 9. Receiving tokens |
| signer, access keys, nonces, meta transactions | 10. Signer and keys |
| self-signed transactions | 11. Local-receipt priority |
| gas budgets, prepaid gas, a child's `fee` | 12. Fault mode and gas mode |
| callbacks that must not fail | 13, "Owed callbacks and detached work" |
| `promise_and`, yield/resume, block height | 14. Joint callbacks, yield/resume and the block clock |
| storage deposits | 15. Storage staking per byte |
| account creation, deletion, deploys | 16. Creating and deleting accounts |

Keep each handler faithful to the code path by path: every `require!` becomes an `OErr`, every
branch that creates receipts creates the same ones, and `ids` counts exactly the fresh ids
used (too small a count stops TLC with an `Assert` naming the method; too large a count
passes unflagged, so count carefully). Note in a comment the
source lines each handler models.

**Done when** `python3 NT/tools/sany.py <model-dir>` parses, and every inventory method has a
handler or a comment saying why it is out of scope.

## Step 4: write the runs

In `runs.toml` (reference: `NT/docs/RUNNER.md`), set `platform_defaults = true`, the accounts,
and small bounds: two or three accounts, `MaxTx` of 1 or 2, one forced fault. Then, for each
property:

- a run of the contract as written, in fault mode with the calls that can fail in `MayFail`,
  expected to pass;
- a **must-fail** run that breaks it on purpose (a switch constant that reproduces the bug
  class the property guards: a callback that ignores its result, a missing rollback), with
  `expect = "violation"` and the property named;
- **witnesses** that each callback's success arm and failure arm are reached, each written
  as `expr = '~(S)'` for the situation `S`;
- **mutants** for the bug classes: a missing `Ok(r, O)` guard, a dropped `.then`, a failure
  branch that does the success work, an inverted result check.

TLC names the first invariant in a run's list that a state violates, so put the one a
must-fail run targets first in that run's `invariants`. List the contract's methods in
`[audit] methods`.

When a run of the contract as written fails, triage it (step 6) before going on. If it is a
contract bug, set that run to `expect = "violation"` with the invariant TLC named, and add a
fix switch: a constant that applies the fix you will suggest, with its own runs expected to
pass. Witnesses and mutants run only on passing runs, so point them at the fixed variant's
runs.

**Done when** `python3 NT/tools/run.py <model-dir> --anti-vacuity --no-audit` reports every
run as expected, every witness reached and every mutant killed (the audit's gaps are step
5's). A surviving mutant means a property
is too weak: strengthen the property, not the mutant.

## Step 5: go to gas mode where it matters

For each owed callback, each callback that shares the leftover gas (a weight above 0, the
near-sdk default) and each call with a fixed gas budget, add a gas-mode run. Without measured
burns, use the host-cost floor (`HostFloorGas`, USAGE section 12). Its verdicts differ:

- a callback with a fixed budget (weight 0) that runs out on the floor runs out on real wasm
  too: a finding;
- a window for a weighted callback is illustrative: the floor under-counts the creator's burn,
  which leaves the callback more gas than nearcore would. It says where to look; step 7 finds
  the real edges on the wasm.

Declare storage writes (`OWriteKey`) and run with `TrieGasWorst`; find the least gas with a
sweep. Then read the audit the runner prints after the table and close each gap with a run,
or accept it in `[audit.accept]` with a reason that cites the source line or a run. The audit
keys on method names, not on switches, so a fixed variant's runs also close the as-written
method's gaps: to see the gaps of the contract as written, name only its runs
(`run.py <model-dir> <run> ...`), and the audit judges those alone.

**Done when** the audit reports 0 open gaps and every accept names its evidence.

## Step 6: triage every counterexample

For each run that fails unexpectedly, print the trace:

```sh
python3 NT/tools/run.py <model-dir> <run> --print-trace
```

The story's last line is the label. `forced`: the trace needs a forced fault, so ask whether
the network can make that call fail. `caller-gas`: a receipt ran out of gas at a prepaid
amount the caller chose, which any user can do. `no-fault`: the bug needs only the order of
receipts shown.

Walk the trace step by step against the source and classify it:

- **contract bug**: the code does what the trace does. Keep it as a hypothesis for step 7.
- **model error**: a handler does something the code does not. Fix the handler, rerun, and
  note the fix.
- **gas tables wrong**: a gas-mode trace turns on a static gas, weight, fee or burn that does
  not match the source or a measurement. Fix the table and rerun.
- **library wrong**: the platform step itself disagrees with the nearcore source that its
  SEMANTICS entry cites. That is a near-tla bug, not a contract finding: give the user the
  trace and the entry so they can report it to near-tla.
- **unreachable**: the schedule needs an order a network does not produce. Name the
  over-approximation in `NT/docs/SEMANTICS.md` ("Not modelled") that allows it. A reorder of
  two receipts between the same pair of accounts is reachable (SEMANTICS S4), so it stays a
  hypothesis until the schedule is shown unreachable.

**Done when** every failing run has a classification with the evidence (source lines, the
SEMANTICS entry) written down.

## Step 7: validate on the compiled contract

Replay each contract-bug hypothesis in near-contract-sim. `NT/docs/VALIDATING.md`, Step 3,
"In near-contract-sim", has the API and a worked replay of the tutorial's trace. For each
hypothesis:

1. **Name the causes.** For each forced fault in the trace, name what makes that call fail on
   a real network: the callee panics on these arguments, the receiver account does not exist,
   an untrusted contract chooses to fail, the call's share of gas runs out. A forced fault
   with no such cause makes the finding "not reproduced": record the reason and go to the next
   hypothesis.
2. **Build the replay.** Build the contract's wasm and a sim test crate; start the crate's
   first build in the background, since it compiles nearcore. Send the trace's transactions
   with their arguments and deposits. Reproduce each failure from its named cause: inject a
   fault on that receipt (`tx.inject`), or deploy a stub for a receiver that really answers
   that way. Where the trace chose an order, hold receipts back (`Fault::Hold`, `HoldResult`,
   `HoldUntil`) to force it. Assert that each fault and hold landed on its receipt.
3. **Assert the property.** Assert the broken property itself, as the model states it, so the
   test goes red on the contract as written. The sim's built-in `findings()` check only
   generic failures; your property is the assertion.
4. **Find the gas edges on the wasm.** For a `caller-gas` trace, pin its prepaid gas with
   `.gas(..)`, then run `gas_edges` keyed on the receipt that runs out in the trace. The
   model's window says where to look; the wasm decides where the edge is. With no edge on the
   wasm, the finding is "not reproduced", and the reason is the gas table.
5. **Argue the orders.** For each order the trace chose, forced or not, write down the
   argument from SEMANTICS S1-S5 that a network produces it. A hold shows that the order
   happens on nearcore's runtime; the argument shows that a network delays that receipt.

Use the near-workspaces sandbox instead when the project already tests with it or the user
asks for a real node. It has no fault injection and no holds, so a sandbox replay builds every
failure from its cause and argues every order.

**Done when** each hypothesis has one of: a replay test that goes red on the contract as
written by failing the property's assertion, with its causes and order arguments written
down; "not reproduced" with the reason; or, when the wasm cannot be built, "not replayed" with
the code-reading argument (VALIDATING.md, "Without either: by reading the code").

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
