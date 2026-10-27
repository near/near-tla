# Conformance

> **For maintainers.** This page is about how the library itself is checked against nearcore.
> You do not need it to model a contract. The suite needs near-contract-sim, which is a private
> repository today ([Access to the sim](#access-to-the-sim)); its results are committed here
> and CI reruns them nightly. To check your own counterexamples on real wasm, see
> [VALIDATING.md](VALIDATING.md).

The conformance suite checks the model against nearcore. It runs generic probe contracts in
near-contract-sim, which executes receipts with nearcore's own `Runtime::apply`, sweeps each
transaction over a grid of prepaid gas, and compares every receipt with what the model predicts
at the same point. The same crate measures the calibrated gas tables the library ships
(`modules/CalibStd.tla`, `modules/CalibStdMt.tla`) and the tables you build for your own contract, and, with `--stor`,
the storage bytes each call adds (`modules/StorStd.tla`; [Storage
bytes](../conformance/README.md#storage-bytes)).

This page explains how to run the suite, what it compares, and how to read a mismatch. The
crate's own [README](../conformance/README.md) is the reference for its pins, layout, commands,
flow-spec format and JSONL schema; this page links there instead of repeating it.

## Running it locally

### Access to the sim

near-contract-sim is a private repository. Cargo fetches it over git, so it needs credentials
once, for the first fetch. Pass them through a git credential helper for that one command, as
[Fetching the sim](../conformance/README.md#fetching-the-sim) shows: the helper reads the token
from the GitHub CLI (`gh auth token`) at fetch time.

- Never write a token into a file, a remote URL, `Cargo.toml`, `.cargo/config.toml` or an
  environment file in the repo.
- After the first fetch, cargo builds offline from its git cache.
- With a local checkout of the sim instead, use the uncommitted `[patch]` described in
  [Using a local sim checkout instead](../conformance/README.md#using-a-local-sim-checkout-instead),
  and check that the checkout is at the pinned rev.

### Build, test, sweep

All commands run from `conformance/`, with `CARGO_TARGET_DIR` set to a directory outside the
repo. Use plain `cargo`.

1. **Probes.** The probe `.wasm` files are committed with their hashes in
   `probes/res/SHA256SUMS`, so you only rebuild them when you change a probe:
   `cd probes && ./build.sh` (or `./build.sh --check` to verify). See
   [The probe contracts](../conformance/README.md#the-probe-contracts).
2. **Tests.** The smoke grid and the receipt-semantics tests, one test at a time:
   `cargo test --release --test smoke` and `cargo test --release --test semantics`.
3. **The full grid.** `cargo run --release --bin calibrate -- --flows flows/probes.toml` sweeps
   every probe flow over the standard grid, writes the sweeps to `data/` with their provenance
   (`.meta.json`, bound to the sweep by its sha256), and prints the calibration report. The
   second flow set, `probes2` (`probe2`'s rule parts), is swept the same way from
   `flows/probes2.toml`, and the third, `mt` (NEP-245 on near-sdk-contract-tools), from
   `flows/mt.toml`.
4. **The model side.**
   - `python3 scripts/mkconf.py` writes one TLC wrapper per flow (`tla/build/MC_<flow>.tla` and
     `.cfg`), on the library in `../modules/`;
   - `scripts/tlc.sh` runs TLC on them (2 workers);
   - `python3 scripts/conform.py` compares model and sim per receipt and per edge, prints a
     summary table, and exits nonzero if any flow fails.

   Each takes `--set probes2` or `--set mt` for the other sets (`scripts/flowsets.py`; default
   `probes`). Each set has its own sweeps, table (`tla/CalibProbes2.tla`, `tla/CalibMt.tla`),
   driver (`tla/Probe2Conf.tla`, `tla/MtConf.tla`) and build directory, so the sets never read
   each other's data. In `probes2` the comparison
   also covers deposit refunds, by receiver, and each receipt's deposit amount, the sim's
   yoctoNEAR converted to the model's unit, 1 mNEAR (`mkconf.dep`).

   The exact invocations are in [Running](../conformance/README.md#running).
5. **Calibration.** `calibrate` with `--tla` writes a TLA+ table; see
   [Regenerating the tables](../conformance/README.md#regenerating-the-tables) for the library's
   own tables and [Calibrating your own contract](../conformance/README.md#calibrating-your-own-contract)
   for yours. [`docs/USAGE.md`](USAGE.md#calibrating) explains how to use the result in a model.

`mkconf.py --grid smoke` and `conform.py --subset` give a quick partial look. Only a full
standard-grid run counts as a result.

## What is compared

For each flow (one transaction shape on the probe world, swept over prepaid gas, and
optionally further steps after it: a transaction at fixed gas, or a yield's timeout) and each
prepaid-gas point:

- **Statuses.** Every receipt's outcome: ok, failed, out of gas, or not created. The model's
  outcome is its per-receipt log (`rlog`, with `LogOn = TRUE`), printed by TLC; the sim's is
  the JSONL sweep. A receipt is identified by its transaction (1 for the swept one, then the
  later ones in order), receiver and method, so outcomes swapped between two transactions
  fail. A yield callback belongs to the transaction that yielded, in both.
- **Parked yields.** The number of yields still waiting once the point's last step has run
  (the sweep's `yields`, from `Sim::yields()`; the model's `Parked`), part of the status
  vector, so a stale yield left behind does not pass as clean-up.
- **Attached gas.** The gas each function-call child was given, which is where the static and
  weighted split shows. It must agree within the tolerance `conform.py --tol` (5 Ggas by
  default), which covers the rounding of fees and burns to whole Ggas. Gas is compared together
  with status: at each point, the receipts must pair up one to one by label (transaction
  included) and status with their gas within tolerance, so a gas value cannot match a receipt
  of another status or another transaction.
- **Edges.** The prepaid values at which the vector of statuses changes. These are the window
  boundaries a gas-mode model predicts, so they must be identical, not just close.

The model side runs with the fee table's `FeeRounding` pinned to `"nearest"` (by
`conformance/scripts/mkconf.py`), because the comparison measures accuracy; the library's
default `"up"` overstates fees on purpose ([N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)
gives what changes under `"up"`: two flows' edges, one grid point up, on the safe side).

Not compared: the order in which receipts run. Each point is compared as a multiset of
receipts per transaction plus the final parked-yield count, so two executions that differ only
in order (a callback before or after one of its inputs) look the same. The order of a joint
callback's results is visible only where a probe turns it into a status (`on_order`).

Separately, `calibrate`'s **split check** checks nearcore's leftover split against the
declared statics and weights for every function-call child at every grid point, to the gas
unit, per action for multi-call receipts. A table is written only if it finds no mismatch.

A flow passes only if TLC finished cleanly, the sweep's provenance names the current flows
file and the flow's grid and matches the sweep's sha256 and point count, the sweep holds every
grid point exactly once, the model has every grid point and none outside it, every status
vector is equal, the edges are identical and every attached gas is within tolerance. An empty,
truncated or duplicated sweep fails.

## Results

Results at the pins in [conformance/README.md](../conformance/README.md#pins), recorded on
2026-10-27 on the library at commit `b3caa4d`. The model side of all three sets was run on that
library. The sweeps were taken through near-contract-sim at its pinned rev on nearcore
2.14.0-rc.5: `probes` and `probes2` on 2026-10-24, `mt` on 2026-10-27; `tla/CalibMt.tla` and
`modules/CalibStdMt.tla` regenerate from them unchanged. The same sim rev built against
nearcore 2.14.0 (`bc4e9e8`), the revision the library cites, gives byte-identical sweeps for
all 121 flows. Every sweep's flows file and probe wasm hashes match the committed ones.

The flow set `probes`:

| | |
|---|---|
| flows | 74, all match (58, plus 8 joint-promise, 7 yield/resume flows and 1 relayed (delegate) flow) |
| prepaid points per flow | 1313 (97,162 points in all) |
| receipts compared | 227,922 sim receipts |
| status mismatches | 0 (receipts matched by transaction; parked yields at the end: 0 at every point, on both sides) |
| edge mismatches | 0 |
| attached-gas differences above tolerance | 0 (tolerance 5 Ggas; largest 5 Ggas, from rounding up at two creation levels) |
| split-check mismatches | 0 of 108,986 children (largest difference 0 gas) |

The flow set `probes2`, `probe2`'s rule parts (R5 `refund_to`, C6 one result by index, C7
`promise_yield_create_with_id`, a yield's deposit and a returned yield, B1 a callback after a
Stake), on the same pins:

| | |
|---|---|
| flows | 28, all match |
| prepaid points per flow | 1313 (36,764 points in all) |
| receipts compared | 122,825 sim receipts (deposit refunds included, by receiver; deposit amounts compared, in mNEAR) |
| status mismatches | 0 |
| edge mismatches | 0 |
| attached-gas differences above tolerance | 0 (largest 5 Ggas) |
| split-check mismatches | 0 of 70,757 children (largest difference 0 gas) |

The flow set `mt`, NEP-245 on the `mt` probe (near-sdk-contract-tools 4.0.0) and the `mtrecv`
receiver: `mt_transfer` and `mt_batch_transfer` with 1 to 3 ids, `mt_transfer_call` and
`mt_batch_transfer_call` with 1 to 3 ids and every receiver answer (keep, return, over-amount,
short, long, malformed, empty, a panic, a 20 Tgas burn), each through `mt_resolve_transfer`.
The model side is `Nep245` with `MtGasShape = "tools"` and the burns of `tla/CalibMt.tla`:

| | |
|---|---|
| flows | 19, all match |
| prepaid points per flow | 1313 (24,947 points in all) |
| receipts compared | 55,487 sim receipts |
| status mismatches | 0 |
| edge mismatches | 0 (the calls' edges at 0.5 and 30.0 Tgas, the 30 Tgas floor, and 31.0 for the 20 Tgas burn; the transfers' at 0.9 to 1.8 Tgas, rising with the number of ids) |
| attached-gas differences above tolerance | 0 (largest 4 Ggas) |
| split-check mismatches | 0 of 30,540 children (largest difference 0 gas) |

With the default `MtGasShape = "reserve"` instead, `mt_bcall2_keep` fails at every point
(no 30 Tgas edge, out of gas instead of the floor's failure), so the comparison sees the
shape.

The calibration figures for the shipped tables (split check, action-only fees, multi-call
burns, `ft_transfer_call`'s gas behaviour) are in
[Results at the pins](../conformance/README.md#results-at-the-pins). What the joint-promise and
yield/resume flows check, the sim's yield API they use, and what they leave out are in
[Async patterns](../conformance/README.md#async-patterns-joint-promises-and-yieldresume). The differences found so
far and how each was resolved are in its [Mismatch log](../conformance/README.md#mismatch-log).

With these results, the rules marked `<!-- conformance -->` in [`SEMANTICS.md`](SEMANTICS.md)
have moved to "sim" where a flow exercises them and the comparison can see a difference. Where
a flow covers a rule only in part, its **Validated:** line says which part the sim checked;
the rest keeps its earlier level.

## Triage: what a mismatch means

When the model and the sim disagree, decide which of these it is before changing anything.

1. **Model bug.** The library encodes a rule differently from nearcore. Typical signs: the
   status differs at every gas point, or the edge sits in the wrong place by more than a
   rounding error, or a receipt exists on one side only. Find the nearcore code path, fix the
   module, cite the line, add a must-fail example and update `SEMANTICS.md` (see
   [`CONTRIBUTING.md`](../CONTRIBUTING.md)). Past examples are in the mismatch log: a
   zero-gas child that nearcore rejects at validation, a panic that runs out of gas first, a
   batch whose gas nearcore splits per action.
2. **Calibration gap.** The rule is right but the burn table is not: a path the flows never
   reached, a burn that grows with something not declared as a size (an argument's length, a
   receiver id), a merged key that holds a different path's burn, or a missing static or
   weight. Signs: edges off by a roughly constant amount on one path, statuses right
   elsewhere. Fix the flow spec (a new flow, a `[[size]]`, a `path`) and recalibrate. Do not
   edit a generated table by hand.
3. **Scale artifact.** The model's units cannot express the difference: whole Ggas, sizes in
   KB rounded up, NEAR scaled to small integers, a grid step coarser than a window. Signs:
   disagreements of a few Ggas, only next to an edge, or a window narrower than the grid step.
   Check the bounds in [N-precision](SEMANTICS.md#under-approximations-unsound-they-can-hide-bugs)
   and [Units](SEMANTICS.md#units); either refine the grid or record the bound. Do not widen
   `--tol` to hide a real difference.
4. **Sim versus nearcore divergence.** The sim gives nearcore's runtime inputs nearcore would
   not (an epoch simplification, a missing protocol feature at the sim's rev) or reports a
   result differently. Confirm by reading the nearcore path at the pinned rev, then report it
   to the sim's maintainers and record it in the mismatch log with the sim rev. Until it is
   fixed, exclude the flow and say why. So far there has been none: the sim runs nearcore's
   runtime unpatched.

Write every mismatch, its class and its resolution into the mismatch log in
`conformance/README.md`.

## Provenance rules

A measured number is only meaningful with what it was measured on.

- **Every calibrated table records** the wasm sha256 of each measured contract, the source
  crate and its version, the sim rev, the nearcore version and rev, the protocol version, the
  flows file and its sha256, the grid, and the exact `calibrate` command line (home directory
  written as `~`). `calibrate` writes this header itself; `modules/CalibStd.tla` shows it.
- **Every sweep records** the same facts in `data/<spec>/<flow>.meta.json`, with the sweep's
  point count and sha256. `calibrate` publishes the pair under a per-flow lock: it removes the
  old `.meta.json`, writes the JSONL whole, then the new `.meta.json` with the sha256 of the
  bytes it wrote. An interrupted sweep has no provenance, and concurrent sweeps of a flow leave
  one sweep's pair. `--from-data` and `conform.py` refuse a sweep whose provenance is missing
  (any field), differs from the current setup or does not match the data; `--force-data` uses it
  anyway and writes the difference into the table's header. Prefer a fresh sweep.
- **A table describes one wasm build.** Burns depend on the contract's code and state, so a
  table measured on a probe or a test build does not describe a deployed contract. Recalibrate
  for the build you deploy, and pin its hash.
- **Tables are regenerated, never hand-edited.** A change to a probe, a flow, the sim rev or
  the nearcore pin means a new sweep and a new table.
- **A protocol bump** follows [`docs/VERSIONING.md`](VERSIONING.md), which includes
  recalibrating and re-running conformance.

## CI

CI on every push checks the TLA+ side only. It SANY-parses every module, every example spec and the
conformance specs in `conformance/tla/` (`ProbeConf.tla`, `Probe2Conf.tla`, `MtConf.tla` and their tables), and it runs every
example's expectations. It also runs `conform.py`'s self-tests
(`conformance/scripts/test_conform.py`), which use toy data. It neither runs TLC on the conformance flows nor builds the
conformance crate, because near-contract-sim is a private git dependency that pulls in
nearcore, so a cold build is slow. The calibrated tables are committed, so models and
examples that use them run in CI without the sim.

The whole suite runs nightly and on demand (`workflow_dispatch`) in
`.github/workflows/conformance.yml`. It fetches near-contract-sim at the rev pinned in
`Cargo.lock` with a read-only deploy key (the `NEAR_CONTRACT_SIM_DEPLOY_KEY` secret), which
exists only for the fetch step; every later cargo step runs offline. It then:

1. runs every sim test;
2. sweeps every flow of the three flow sets on the standard grid;
3. regenerates `CalibProbes`, `CalibProbes2`, `CalibMt`, `CalibStd`, `CalibStdMt`, `StorStd` and `StorKv` and fails if
   any differs from the committed file;
4. runs TLC on every flow and `conform.py`, for each set.

Nothing gates on it, so a failure does not block `main`. The nightly run comes after the
merge, so still re-run the suite locally before merging any change to the gas rules, the fee
table, the token modules or a calibrated table, and paste `conform.py`'s summary into the
pull request.
