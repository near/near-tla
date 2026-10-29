# Versioning

## Library versions

near-tla follows [Semantic Versioning](https://semver.org/). The public API is:

- the module names in `modules/`;
- the names, arities and meanings of the operators and constants they export;
- the record fields that contract models read or build (for example `r.res`, `r.res.sz`, the
  `Rcpt` fields and the outcome record);
- the `runs.toml` format and the `tools/run.py` command line.

The rule of thumb: **anything that can change the verdict of an existing model is major.**

| change | bump |
|---|---|
| A new operator, module, constant with a default, account kind, or fee row for a new protocol version, with every default unchanged | minor |
| Changing the default `FeeProtocol` (fees move, so gas-mode verdicts and windows can change) | **major** |
| Changing the default `FeeRounding` (every fee moves by up to 1 Ggas per entry, and the unused-gas split's remainder rule with it) | **major** |
| Changing a fee value for an already covered version (a correction) | **major** (it can change verdicts); patch only if no shipped example or calibration is affected, and say so |
| A renamed or removed operator, a changed arity, a changed meaning, or a new required constant | major |
| A semantic fix that changes a verdict of an existing model | major |
| Comment, citation or documentation fixes | patch |

Before 1.0.0, a minor release may carry a major change.

The version is the one in the root `Cargo.toml`, and release `X.Y.Z` is the git tag `vX.Y.Z`.
The library is TLA+, not Rust: that manifest only carries the version for release-plz, and
the conformance crate (`conformance/`) is a separate workspace with a version of its own.

## Commits pick the bump

release-plz reads the Conventional Commit titles merged since the last tag, picks the bump
from them, and writes the release's section of `CHANGELOG.md` from them. So a commit's type
has to match the table above:

| commit | listed in `CHANGELOG.md` under | bump while 0.x | bump from 1.0 |
|---|---|---|---|
| a `!` title (`feat!:`, `fix!:`, ...) or a `BREAKING CHANGE:` footer | Breaking | minor | major |
| `feat` | Added | minor | minor |
| `fix` | Fixed | patch | patch |
| any other type (`docs`, `test`, `ci`, `chore`, `refactor`, ...) | not listed | none on its own | none on its own |

A breaking change says how to migrate in its `BREAKING CHANGE:` footer, and its entry ends
with that text. A commit of another type is released with the next listed change; a
documentation or citation fix that users should see is a `fix`. A squash merge's commit
takes the pull request's title, so the title carries the type and the `!`.

## Making a release

`.github/workflows/release-plz.yml` runs release-plz on every push to `main` (configuration:
`release-plz.toml`).

1. Once a listed change is on `main`, release-plz opens a release pull request, titled
   `chore: release vX.Y.Z`, and updates it as more changes land. It bumps the version in
   `Cargo.toml` and `Cargo.lock` and adds the release's section to `CHANGELOG.md`. The workflow
   then starts `ci.yml` on the release branch, since a branch that GITHUB_TOKEN pushed starts no
   workflow by itself.
2. Before merging it, check the bump against the table above and fix it if needed (the version
   in `Cargo.toml` and `Cargo.lock` and the section's heading, or `release-plz set-version`), add
   the protocol assumptions below under the section's heading, and edit the entries if they
   need it. Do this last: when `main` moves on, release-plz replaces an edited release pull
   request with a new one, without the edits.
3. Merging it makes release-plz tag `vX.Y.Z` and publish a GitHub release whose notes are the
   section. Nothing goes to crates.io.

release-plz takes the last release from the newest `vX.Y.Z` tag and needs the root `Cargo.toml`
in that tag's tree. `v0.1.0` predates that manifest, so 0.1.1 was prepared by hand: the change
that added release-plz set the version to 0.1.1 and wrote its section, and the workflow tagged
`v0.1.1` when that change was merged.

## Each release states its protocol assumptions

Every release section in `CHANGELOG.md` carries these lines, which release-plz does not
write (step 2 above):

```
nearcore: 2.14.0 (bc4e9e8)   behaviour: protocol 88   fees: FeeProtocol 88, rounded up, covered 84-88
near-contract-sim: <rev>          near-contract-standards (token gas defaults): <version>
```

- **nearcore:** the revision every citation in `docs/SEMANTICS.md` and in module comments points
  to.
- **behaviour:** the protocol version whose rules `NearAsync` and `NearKeys` encode.
- **fees:** the `FeeProtocol` default in `modules/NearFees.tla`, plus the versions its
  `...At(pv, ...)` operators cover, and the `FeeRounding` default ("rounded up" or "rounded to
  nearest").
- **near-contract-sim:** the sim revision the conformance suite and the shipped calibrations ran
  on.
- **near-contract-standards:** the version whose `ft_transfer_call` gas behaviour the token
  defaults encode. The other version-dependent token default, the resolver's 42-byte read
  bound (`TokResolveMaxLen`), holds from 5.24.0 (SEMANTICS T2).

## What `FeeProtocol` does and does not change

`FeeProtocol` selects **fees only**. The rules in `NearAsync` and `NearKeys` are protocol 88's,
whatever `FeeProtocol` says. Setting `FeeProtocol == 86` gives 86's fees on top of 88's rules.
The one rule of 84-88 the model can switch is universal accounts, through its own overridable
definition `UniversalOn` (default TRUE, 88), not through `FeeProtocol`. So with
`FeeProtocol == 86` and the default `UniversalOn`, a Transfer to an absent universal (`0u`)
account still creates it (88's rule), and its creator pays 86's fee for that receiver, which is
the named-account Transfer fee (`NearFees.tla` `TransferSendAt` / `TransferExecAt`: the
create_account part is charged for universal ids from 88 only). To model the rule before 88 as
well, add `UniversalOn <- FALSE`: the Transfer then fails and refunds, as to a missing named
account.
These behaviours are gated by version between 83 and 88 (`core/primitives-core/src/version.rs`
`ProtocolFeature::protocol_version` at `:514-659` @ bc4e9e8, and the parameter yamls):

| version | behaviour | in the model |
|---|---|---|
| 83 | `max_total_prepaid_gas` and `max_gas_burnt` 300 → 1000 Tgas (`83.yaml:6-8`) | gas menus are user-chosen; no cap enforced |
| 85 | create_account repriced (fee table) | `NearFees` per version |
| 85 | `account_creation_charge` 0.007 NEAR taken from the gas refund (`AccountCostIncrease`) | not modelled (gas money) |
| 85 | `one_yocto_on_promise` | not modelled |
| 85 | gas keys, `DelegateV2`, `StrictNonce`, `YieldWithId`, ML-DSA verification cost | not modelled |
| 86 | per-receipt storage-proof limit (`EnforcePerReceiptStorageProofLimit`) | not modelled |
| 87 | gas rewards to contracts 30% → 0 (`RemoveGasRewards`, `87.yaml:1-7`) | the model pays no reward, which is right for 87+ and wrong for 84-86 |
| 87 | `RejectEmptyMethodName`, `EnforceStorageProofLimitForAllActions`, `FixContractLoadingError`, `RejectUniversalAccountTransfers` | not modelled |
| 88 | universal (`0u`) accounts (`UniversalAccounts`, `88.yaml:1-3`) | fee kind by `FeeProtocol`; creation by Transfer by `UniversalOn` (default on, independent of `FeeProtocol`) |
| 88 | canonical universal state init; universal state-init fees (`88.yaml:18-49`) | not modelled |

So a model of mainnet at 86 differs from the library's rules at least in gas rewards (N-reward
in `docs/SEMANTICS.md`), in universal-account creation unless it sets `UniversalOn <- FALSE`,
and in the other 87 and 88 rules listed above. Check that list against your contract before trusting a
verdict at another version.

## Procedure for a protocol bump

Do this when the sim moves to a new nearcore, or when mainnet or stable moves to a version not
yet covered. Track it as one change; every step below either changes a file or records "no
change" in the PR description.

1. **Find the versions.** In the new nearcore, read `STABLE_PROTOCOL_VERSION`,
   `PROTOCOL_VERSION` and `MIN_SUPPORTED_PROTOCOL_VERSION` in
   `core/primitives-core/src/version.rs`. Diff the `ProtocolFeature` → version table in the same
   file: every newly enabled feature is a candidate behaviour change, even with no parameter
   change.
2. **Diff the parameters.**
   - `core/parameters/src/snapshots/near_parameters__config_store__tests__<v>.json.snap`: the
     resolved config per version. Read fee and limit values from here.
   - `core/parameters/res/runtime_configs/parameters.yaml`: base values. Some parameters are
     **not in the snapshots** and must be read here and in the version yamls, for example
     `gas_refund_penalty`, `min_gas_refund_penalty`, `min_gas_purchase_price`,
     `account_creation_charge`, `burnt_gas_reward` and the account-creation config. Old versions
     are sometimes folded into this file.
   - every new `core/parameters/res/runtime_configs/<v>.yaml` (per-version diffs).
   - `core/parameters/src/config_store.rs`: which yamls exist. A version with no yaml inherits
     the previous one.

   Look at `action_receipt_creation_config`, `data_receipt_creation_config`,
   `action_creation_config`, `storage_usage_config`, `eth_implicit_accounts`,
   `universal_accounts`, the limit config and the gas economics config.
3. **Diff the fee logic.**
   - `core/parameters/src/cost.rs` (`transfer_exec_fee`, `transfer_send_fee`, refund penalty);
   - `runtime/runtime/src/config.rs` (`calculate_tx_cost`, `total_send_fees`, `exec_fee`,
     `permission_*_fees`, `total_prepaid_exec_fees`);
   - `runtime/near-vm-runner/src/logic/host.rs` (`pay_gas_for_new_receipt`,
     `promise_batch_action_*`, `value_return`, `pay_action_base`, `pay_action_per_byte`);
   - the `near-account-id` version in `Cargo.lock`, and its `validation.rs` and
     `account_id_ref.rs`, for new account patterns.
4. **Diff the runtime behind the non-fee rules.** Every rule in `docs/SEMANTICS.md` cites one of
   these files. Diff all of them between the old and the new revision:
   - `runtime/runtime/src/lib.rs` (receipt processing, revert scope, refunds, local receipts,
     ordering, storage check);
   - `runtime/runtime/src/receipt_manager.rs` (`distribute_gas`, gas weights);
   - `runtime/runtime/src/function_call.rs` (signer propagation, VM outcome, no-code failure);
   - `runtime/near-vm-runner/src/logic/gas_counter.rs` (prepaid and static gas checks);
   - `runtime/runtime/src/verifier.rs` (access keys, allowance, nonce, storage stake);
   - `core/primitives/src/receipt.rs` (receipt shapes, refund receipts, instant receipts);
   - `runtime/runtime/src/access_keys.rs` (AddKey, DeleteKey);
   - `runtime/runtime/src/action_validation.rs` (action and receipt limits);
   - `runtime/runtime/src/actions.rs` (existence, permissions, implicit creation, Stake,
     DeleteAccount);
   - `runtime/runtime/src/congestion_control.rs` (delayed queue, outgoing buffers).
5. **Re-check behaviour, not only line numbers.** For each rule in `docs/SEMANTICS.md`, read the
   cited code at the new revision and confirm it still does what the rule says. Then update the
   line numbers and the reference revision at the top of `SEMANTICS.md`. A moved line with
   changed logic is a semantic change: it needs a module change, a must-fail example and a
   commit title that release-plz lists in `CHANGELOG.md` ([Commits pick the
   bump](#commits-pick-the-bump), `CONTRIBUTING.md`).
6. **Edit `NearFees.tla`.** Add the version to `FeeVersions`, add `IF pv >= <v>` branches for
   changed rows, update every citation, and extend the `ASSUME` self-checks with the new totals.
   Change `FeeProtocol` only if the default should move; that is a major change.
7. **Update the behaviour table** above and the "behaviour" line of the release.
8. **Check the sim matches.** The sim builds its runtime config from its own nearcore
   dependency. Confirm that its `Cargo.lock` pins the same nearcore revision, that it runs the
   protocol version you expect, and that the config it applies at that version equals nearcore's
   snapshot for it (fees, limits, flags). If they differ, conformance results do not carry over.
9. **Parse and run.** Run `python3 tools/sany.py modules examples conformance/tla` and every
   example (`python3 tools/run.py`).
10. **Repeat conformance** (see `docs/CONFORMANCE.md`):
    - the fee probes: Transfer to named, NEAR-implicit and eth-implicit receivers, existing and
      absent; AddKey/DeleteKey; Stake;
    - the gas-split and out-of-gas probes;
    - the local-receipt priority probe, if `process_transactions`, `process_local_receipts` or
      `process_receipts` in `runtime/runtime/src/lib.rs` changed;
    - recalibrating every shipped table (below), because the protocol version is part of its
      key.

## Calibrated burn tables are tied to their provenance

A calibrated gas table (`GasCall`, `GasBurn`) is valid only for the combination it was measured
on. Each shipped table records:

- the **sha256 of the wasm** it was measured on;
- the **source crate and version** (for example near-contract-standards x.y.z);
- the **near-contract-sim revision**;
- the **nearcore revision**;
- the **protocol version**.

If any of these change, the table is stale. Burns move with the compiler, the SDK, the
contract source, trie layout and gas pricing, so a window computed from a stale table may be in
the wrong place. Recalibrate before trusting a gas-mode verdict. The shipped tables come from
the repo's probe contracts. A model of a real deployment must be recalibrated against that
deployment's wasm.

`NearFees.tla` values come from nearcore's parameter files and are not calibrated. They change
only with the protocol version. They are rounded up to whole Ggas by default (`FeeRounding`);
the rounding error is bounded in the `NearFees.tla` header and in N-precision in
`docs/SEMANTICS.md`.
