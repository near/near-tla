# Versioning

## Library versions

near-tla follows [Semantic Versioning](https://semver.org/). The public API is:

- the module names in `modules/`;
- the names, arities and meanings of the operators and constants they export;
- the record fields that contract models read or build (for example `r.res`, `r.res.sz`, the
  `Rcpt` fields and the outcome record);
- the `runs.toml` format and the `tools/run.py` command line.

| change | bump |
|---|---|
| A new operator, module, constant with a default, account kind or fee row | minor |
| A fee-table update for a new protocol version, with the default `FeeProtocol` unchanged | minor |
| Changing the default `FeeProtocol` | minor, listed under "Changed" in `CHANGELOG.md` |
| A renamed or removed operator, a changed arity, a changed meaning, or a new required constant | major |
| A semantic fix that changes a verdict of an existing model | major if the old behaviour was documented, else minor; always under "Changed" |
| Comment, citation or documentation fixes | patch |

Before 1.0.0, minor releases may break the API. Every break goes under "Breaking" in
`CHANGELOG.md` with a one-line migration.

## Each release states its protocol assumptions

Every release section in `CHANGELOG.md` carries these lines:

```
nearcore: 2.14.0-rc.5 (b7b4737)   protocol (default FeeProtocol): 88   covered: 84-88
near-contract-sim: <rev>          near-contract-standards (token gas defaults): <version>
```

- **nearcore:** the revision every citation in `docs/SEMANTICS.md` and in module comments points
  to.
- **protocol:** the `FeeProtocol` default in `modules/NearFees.tla`, plus the versions its
  `...At(pv, ...)` operators cover.
- **near-contract-sim:** the sim revision the conformance suite and the shipped calibrations ran
  on.
- **near-contract-standards:** the version whose `ft_transfer_call` gas behaviour the token
  defaults encode.

## Updating `NearFees.tla` on a protocol bump

Do this when the sim moves to a new nearcore, or when mainnet or stable moves to a version not
yet covered.

1. **Find the versions.** In the new nearcore, read `STABLE_PROTOCOL_VERSION`,
   `PROTOCOL_VERSION` and `MIN_SUPPORTED_PROTOCOL_VERSION` in
   `core/primitives-core/src/version.rs`. Also read the `ProtocolFeature` → version table in the
   same file, for features that change semantics without changing a parameter.
2. **Diff the parameters.** Between the old and the new revision, diff:
   - `core/parameters/res/runtime_configs/parameters.yaml` (base values; old versions are
     sometimes folded into it);
   - every new `core/parameters/res/runtime_configs/<v>.yaml` (per-version diffs);
   - `core/parameters/src/snapshots/near_parameters__config_store__tests__<v>.json.snap` (the
     resolved config per version: read the values from here);
   - `core/parameters/src/config_store.rs` (which yamls exist; a version with no yaml inherits
     the previous one).

   Look at `action_receipt_creation_config`, `data_receipt_creation_config`,
   `action_creation_config`, `storage_usage_config`, `eth_implicit_accounts`,
   `universal_accounts` and the limit config.
3. **Diff the fee logic.** Diff these:
   - `core/parameters/src/cost.rs` (`transfer_exec_fee`, `transfer_send_fee`, refund penalty);
   - `runtime/runtime/src/config.rs` (`total_send_fees`, `exec_fee`, `permission_*_fees`,
     `total_prepaid_exec_fees`);
   - `runtime/near-vm-runner/src/logic/host.rs` (`pay_gas_for_new_receipt`,
     `promise_batch_action_*`, `value_return`, `pay_action_base`, `pay_action_per_byte`);
   - `runtime/runtime/src/actions.rs` (`check_account_existence`, `implicit_creation_allowed`,
     `get_account_type`);
   - the `near-account-id` version in `Cargo.lock`, and its `validation.rs`, for new account
     patterns.
4. **Edit `NearFees.tla`.** Add the version to `FeeVersions`, add the `IF pv >= <v>` branches
   for changed rows, update every citation, and extend the `ASSUME` self-checks with the new
   totals. Change `FeeProtocol` only if the default should move, and say so in `CHANGELOG.md`.
5. **Re-cite.** Line numbers move between revisions. Re-check every `path:line` in
   `docs/SEMANTICS.md` and in module comments against the new revision, then update the
   reference revision at the top of `SEMANTICS.md`.
6. **Parse and run.** Run SANY on `modules/` and every example (`tools/run.py`).
7. **Repeat conformance** (see `docs/CONFORMANCE.md`):
   - the fee probes: Transfer to named, NEAR-implicit and eth-implicit receivers, existing and
     absent; AddKey/DeleteKey; Stake;
   - the gas-split and out-of-gas probes;
   - the local-receipt priority probe, if `runtime/runtime/src/lib.rs` `process_transactions` or
     `process_receipts` changed;
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
only with the protocol version.
