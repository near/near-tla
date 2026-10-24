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
| Changing a fee value for an already covered version (a correction) | **major** (it can change verdicts); patch only if no shipped example or calibration is affected, and say so |
| A renamed or removed operator, a changed arity, a changed meaning, or a new required constant | major |
| A semantic fix that changes a verdict of an existing model | major |
| Comment, citation or documentation fixes | patch |

Before 1.0.0, a minor release may carry a major change. Every such break goes under "Breaking"
in `CHANGELOG.md` with a one-line migration.

## Each release states its protocol assumptions

Every release section in `CHANGELOG.md` carries these lines:

```
nearcore: 2.14.0-rc.5 (b7b4737)   behaviour: protocol 88   fees: FeeProtocol 88, covered 84-88
near-contract-sim: <rev>          near-contract-standards (token gas defaults): <version>
```

- **nearcore:** the revision every citation in `docs/SEMANTICS.md` and in module comments points
  to.
- **behaviour:** the protocol version whose rules `NearAsync` and `NearKeys` encode.
- **fees:** the `FeeProtocol` default in `modules/NearFees.tla`, plus the versions its
  `...At(pv, ...)` operators cover.
- **near-contract-sim:** the sim revision the conformance suite and the shipped calibrations ran
  on.
- **near-contract-standards:** the version whose `ft_transfer_call` gas behaviour the token
  defaults encode.

## What `FeeProtocol` does and does not change

`FeeProtocol` selects **fees only**. The rules in `NearAsync` and `NearKeys` are protocol 88's,
whatever `FeeProtocol` says. Setting `FeeProtocol == 86` gives 86's fees on top of 88's rules.
These behaviours are gated by version between 83 and 88 (`core/primitives-core/src/version.rs`
`ProtocolFeature::protocol_version` at `:511-655` @ b7b4737, and the parameter yamls):

| version | behaviour | in the model |
|---|---|---|
| 83 | `max_total_prepaid_gas` and `max_gas_burnt` 300 → 1000 Tgas (`83.yaml:6-8`) | gas menus are user-chosen; no cap enforced |
| 85 | create_account repriced (fee table) | `NearFees` per version |
| 85 | `account_creation_charge` 0.007 NEAR taken from the gas refund (`AccountCostIncrease`) | not modelled (gas money) |
| 85 | `one_yocto_on_promise` | not modelled |
| 85 | gas keys, `DelegateV2`, `StrictNonce`, `YieldWithId`, ML-DSA verification cost | not modelled |
| 86 | per-receipt storage-proof limit (`EnforcePerReceiptStorageProofLimit`) | not modelled |
| 87 | gas rewards to contracts 30% → 0 (`RemoveGasRewards`, `87.yaml:1-7`) | the model pays no reward, which is right for 87+ and wrong for 84-86 |
| 87 | promise-input size limit `ReceiptPromiseInputSizeLimit` (4,194,944 bytes) | not modelled |
| 87 | universal (`0u`) accounts, `RejectEmptyMethodName`, `EnforceStorageProofLimitForAllActions`, `FixContractLoadingError` | universal: fee kind only; the rest not modelled |
| 88 | promise-input size limit lifted to `u32::MAX` (`88.yaml`) | n/a |
| 88 | canonical universal state init; universal state-init fees (`88.yaml:14-45`) | not modelled |

So a model of mainnet at 86 differs from the library's rules at least in gas rewards (N-reward
in `docs/SEMANTICS.md`) and in the 87 rules listed above. Check that list against your contract
before trusting a verdict at another version.

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
   `CHANGELOG.md` entry (`CONTRIBUTING.md`).
6. **Edit `NearFees.tla`.** Add the version to `FeeVersions`, add `IF pv >= <v>` branches for
   changed rows, update every citation, and extend the `ASSUME` self-checks with the new totals.
   Change `FeeProtocol` only if the default should move; that is a major change.
7. **Update the behaviour table** above and the "behaviour" line of the release.
8. **Check the sim matches.** The sim builds its runtime config from its own nearcore
   dependency. Confirm that its `Cargo.lock` pins the same nearcore revision, that it runs the
   protocol version you expect, and that the config it applies at that version equals nearcore's
   snapshot for it (fees, limits, flags). If they differ, conformance results do not carry over.
9. **Parse and run.** Run `tools/sany.py modules examples` and every example (`tools/run.py`).
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
only with the protocol version. Their rounding error is bounded in the `NearFees.tla` header and
in N-precision in `docs/SEMANTICS.md`.
