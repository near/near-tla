# near-tla conformance

This crate checks the model in `../modules/` against nearcore. It runs generic probe contracts in
[near-contract-sim](https://github.com/near/near-contract-sim), which executes receipts with
nearcore's own `Runtime::apply`. Each transaction runs at every point of a prepaid-gas grid, and
every receipt is compared with what the model predicts at the same point:

- the receipt status: ok, failed, out of gas, or not created;
- the gas attached to each function call;
- the window edges, i.e. the prepaid values at which the outcome changes.

The crate also has a calibration tool. It measures a contract's burn per method and path, and
writes them as a TLA+ `GasBurn` / `GasCall` table with a provenance header.
`../modules/CalibStd.tla` (standard FT and wNEAR) is generated this way.

This is a standalone crate. It is outside any workspace and CI does not build it, because the sim
is a git dependency.

## Pins

| | |
|---|---|
| near-contract-sim | `29e909033bb59eab792dee136e9d02870488bc3e` (git dependency, `Cargo.toml`) |
| nearcore | `2.14.0-rc.5`, rev `b7b4737cab46f17a6daa2ed694d7aebbd204363a` (from the sim's lock file, copied to `Cargo.lock`) |
| protocol version | 88 (read from the sim at run time; matches `NearFees.tla`'s `FeeProtocol`) |
| Rust | 1.95.0 (`rust-toolchain.toml`) |
| near-sdk / near-contract-standards | 5.29.1 (probe contracts) |

`calibrate` prints all of these and writes them into every table it emits. It reads the nearcore
pin from `Cargo.lock` and the protocol version from the running sim.

These features are not available at this sim rev: `Config::minimum_stake`, `Tx::gas_windows` and
`Fault::HoldUntil`. Instead of `gas_windows`, the crate sweeps the grid itself, cloning the sim
once per point.

## Layout

| path | contents |
|---|---|
| `probes/` | the probe contracts (own workspace): `probe` (generic, on `p.near` and `q.near`), `ft` (plain near-contract-standards FT), `wrap` (wNEAR-like). `build.sh` builds them |
| `probes/res/` | the built `.wasm` files and `SHA256SUMS` (committed) |
| `flows/probes.toml` | the probe world and its 36 flows (conformance and standard-token calibration) |
| `flows/example.toml` | a template for calibrating your own contract |
| `src/lib.rs` | sweeps, the JSONL dump, fee lookups, provenance |
| `src/spec.rs` | the flow-spec format |
| `src/calib.rs` | the split check, burn collection and fit, and the TLA+ emitter |
| `src/bin/calibrate.rs` | the calibration / sweep tool |
| `tests/semantics.rs` | receipt semantics: local-receipt priority (D2), signer propagation (D1), DeleteKey batch atomicity |
| `tests/smoke.rs` | the smoke grid: split check, standard burns, two window edges |
| `tla/ProbeConf.tla` | the model side: the probe contract on the library, one flow per run, `PrintT` per receipt |
| `tla/CalibProbes.tla` | the probe world's burn and exec-fee table (generated) |
| `scripts/mkconf.py` | writes `tla/build/MC_<flow>.tla/.cfg` for each flow |
| `scripts/tlc.sh` | runs TLC on them (2 workers) |
| `scripts/conform.py` | compares model and sim per receipt and per edge |
| `data/`, `tla/build/` | sweep output and TLC logs (not committed) |

## Setup

### Fetching the sim

near-contract-sim is a private repository, so cargo has to fetch it over git with credentials.
The following works with the GitHub CLI signed in. It passes the token through a credential
helper for one command only, and never writes it to a file or remote URL:

```sh
export CARGO_TARGET_DIR=~/.targets/near-tla   # any directory; one per checkout is fine
CARGO_NET_GIT_FETCH_WITH_CLI=true \
GIT_CONFIG_COUNT=2 \
GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
GIT_CONFIG_KEY_1=credential.helper \
GIT_CONFIG_VALUE_1='!f() { echo username=x-access-token; echo "password=$(gh auth token)"; }; f' \
cargo fetch
```

After the first fetch, cargo builds offline from its git cache.

### Using a local sim checkout instead

Add this to `Cargo.toml` (do not commit it):

```toml
[patch."https://github.com/near/near-contract-sim"]
near-contract-sim = { path = "../../near-contract-sim" }   # your checkout, at the pinned rev
```

Check that the checkout is at the rev in the table above. The provenance check reads the rev
from `Cargo.lock`, so a patched build at a different rev reports the wrong rev.

### The probe contracts

The `.wasm` files in `probes/res/` are committed with their hashes, so the suite runs without a
wasm toolchain. `probe_wasm` refuses a file whose hash is not in `SHA256SUMS`. To rebuild them:

```sh
cd probes && ./build.sh          # builds, copies to res/, rewrites res/SHA256SUMS
cd probes && ./build.sh --check  # rebuilds and verifies against SHA256SUMS
```

`build.sh` uses plain `cargo build --target wasm32-unknown-unknown --release` with the 1.95.0
default features (bulk memory and sign extension are fine at protocol 88). It remaps every
local path prefix (`--remap-path-prefix`) and strips the output (`-C link-arg=-s`). As a result
the build is reproducible and the wasm carries no local paths.

Stripping removes the panic strings. A panic in a probe (such as the FT receiver's `panic`
message) therefore shows up as a wasm trap (`unreachable`) instead of a panic message. The
status (`failed`) is the same.

## Running

All commands run from `conformance/`, with `CARGO_TARGET_DIR` set as above. Tests run one at a
time (`.cargo/config.toml` sets `RUST_TEST_THREADS=1`; `--test-threads 1` says the same).

```sh
# smoke: 10 flows on the smoke grid, split check, standard burns, two edges
cargo test --release --test smoke -- --test-threads 1
# receipt semantics (prints what it observed with --nocapture)
cargo test --release --test semantics -- --test-threads 1

# full sweep of every probe flow on the standard grid (5-130 Tgas by 0.1, 140-300 by 10;
# 1268 points per flow), JSONL to data/probes/, then the calibration report
cargo run --release --bin calibrate -- --flows flows/probes.toml

# the model side, on ../modules/ (TLC: TLA2TOOLS_JAR or ../tools/tla2tools.jar)
python3 scripts/mkconf.py                 # all flows; or name some
scripts/tlc.sh chain1 ft_call_return ...  # one TLC run per flow, 2 workers
python3 scripts/conform.py                # per-flow comparison and a summary table
```

`mkconf.py --grid smoke` (or `lo:hi:step` in Tgas) runs the model on a coarser grid. Use
`calibrate --grid` to run the sim on the same grid.

### Regenerating the tables

`--from-data` reuses the JSONL of the last sweep in `data/` (not committed). Drop it to sweep
afresh.

```sh
cargo run --release --bin calibrate -- --flows flows/probes.toml --from-data \
  --merge-accts ft,wrap --tla tla/CalibProbes.tla --prefix Probe

cargo run --release --bin calibrate -- --flows flows/probes.toml --from-data \
  --merge-accts ft,wrap --group ft:StdFt --group wrap:StdWNear \
  --tla ../modules/CalibStd.tla --module CalibStd --note "..."
```

`--note` lines go into the header. The committed header shows the notes used.

## Calibrating your own contract

1. Copy `flows/example.toml`. Set `wasm = "${WASM}"` on your contract.
2. Describe the world: accounts, other contracts, `[[setup]]` calls.
3. Declare the static gas and weight of every call the contract makes (`[[static]]`), and what
   each burn grows with (`[[size]]`).
4. Write one `[[flow]]` per path you want a burn key for.
5. Run it:

```sh
cargo run --release --bin calibrate -- --flows my.toml --wasm path/to/contract.wasm \
  --tla MyCalib.tla --prefix My --params app
```

The template runs as written with `--wasm probes/res/probe.wasm`.

The tool works in three steps:

1. **Split check.** It first checks that nearcore's leftover split reproduces from your
   declared statics and weights. The check runs over every child of a single-call receipt, at
   every grid point. If any child differs, the tool refuses to write a table. In that case the
   declarations are wrong, or the contract computes its gas some other way.
2. **Burns.** It takes each receipt's burn at the top of the grid:
   `gas_burnt − prepaid_exec_fees − send fees of action-only children` (D6). The send fee
   depends on the receiver's account kind: named, NEAR-implicit or eth-implicit.
3. **Fit.** For each key it fits `base + per · size` (Ggas, size in the unit of `[[size]]`). It
   prints the residuals and the spread over all successful receipts.

`--params app` turns that account's keys into `app \o ".method"`. The emitted operator,
`MyGasBurn(app)`, can then be instantiated for any model account name. `--merge-accts a,b`
gives those accounts one key per method, holding the largest burn of any path. This is the
token modules' key scheme. `--accts a,b` restricts the table to those accounts. `--group
acct:Prefix` emits one parameterized pair of operators per account.

Burns depend on the contract's code and state. A table describes the wasm whose hash is in its
header. Recalibrate for the deployed build.

## Flow specs (TOML)

| section | fields |
|---|---|
| `[world]` | `protocol_version` (the sim's; default the pinned nearcore's), `names` (sim id → model name), `keys` (method list of a batch → burn key, e.g. `"near_deposit+ft_transfer" = "batch/DT"`) |
| `[[account]]` | `id`, `near` (whole NEAR) |
| `[[contract]]` | `id`, `wasm` (path relative to the spec, or `${WASM}`), `near`, `init = { method, args }`, `source` (free text for the provenance header) |
| `[[setup]]` | a call run once before every flow: `signer`, `receiver`, `method`, `args` (JSON text or a TOML table), `deposit` (yocto, string), `tgas` (default 300) |
| `[[static]]` | `child = "<receiver>.<method>[+method2...]"`, optional `parent`, `actions = [[static_ggas, weight], ...]` (one per function-call action), or `prepaid_minus_ggas` for a child given the creator's prepaid minus a constant |
| `[[size]]` | `key = "<receiver>.<method>"`, `from = "arg:<field>" \| "result" \| "result_size"`, `div` |
| `[[flow]]` | `name`, `about`, `tx` (a call as in `[[setup]]`), `grid` (`standard`, `smoke`, `lo:hi:step` in Tgas), `setup` (extra calls), `size`, `static` (per-flow `[[flow.static]]`), `path` / `path_for` (split one method's burns by an argument, e.g. the FT receiver's `msg`) |

Gas is in Ggas unless a field is named `tgas`. Deposits are yocto strings.

## JSONL schema

`data/<spec stem>/<flow>.jsonl` holds one line per grid point:

```
{ "flow": str, "gas": prepaid (gas units), "tx_ok": bool, "receipts": [receipt, ...] }
```

Each receipt is listed in execution order, with the transaction's conversion first and refunds
included:

| field | |
|---|---|
| `id`, `parent` | receipt id, and the id of the receipt or conversion that created it |
| `conversion` | true for the transaction's conversion to its first receipt |
| `receiver`, `predecessor` | account ids |
| `methods`, `actions` | method names of its function calls; every action's kind |
| `args` | the first function call's arguments, if at most 512 bytes |
| `refund` | the refund kind (Debug text) for a refund receipt, else null |
| `callback` | whether it waited on a promise result |
| `attached`, `burnt`, `exec_fees` | attached gas (sum over calls), gas burnt, prepaid exec fees of its children (gas units) |
| `deposit` | yocto, as a string |
| `status`, `fail` | `ok` / `oog` / `failed`, and the failure (Debug text) |
| `result_size`, `result` | return value length, and the value if at most 64 bytes |
| `logs`, `block` | logs, block height |

An "edge" is a grid point where the status vector changes. The status vector is the sorted
`receiver::methods=status` of every non-refund receipt.

## Units in the model

- Gas is in Ggas (1 Tgas = 1000).
- Result sizes (`r.res.sz`) and `GasBurn.per` are per KB (1000 bytes). The measured slopes are
  3.14 Ggas/KB for a callback reading its results and 69.6 Ggas/KB for returning a value. At
  this unit, rounding costs at most a few Ggas over a 100 KB range.
- In `ProbeConf`, 1 NEAR is 1000 model units, and the storage minimum and 1 yocto are both 1.

## Results at the pins

All 36 probe flows were run on the standard grid (1268 points each), on `../modules/` as of
commit `d8cea1f` with the `NearFees.tla` revision that followed it (fee protocol 88).

**Split check.** 46 726 children of single-call receipts were checked, with 0 mismatches
(worst difference 0 gas). Children of multi-call (batch) receipts are reported apart, because
nearcore splits per action; see below.

**Action-only children.** Their exec fees equal the fee table: named 223.18, eth-implicit
7423.18 and NEAR-implicit 7524.95 Ggas.

**near-contract-standards 5.29.1, `ft_transfer_call`.**

- `ft_on_transfer` gets static 0 and the leftover by weight 1.
- `ft_resolve_transfer` gets static 5 Tgas and weight 0.
- There is no reserve and no prepaid check. The call fails for lack of gas only when
  burn + 2 child exec fees + 5 Tgas exceeds prepaid: about 8.4 Tgas for the FT. Between 8.4 and
  8.8 Tgas the receiver runs out of gas.

The table below is the output of `scripts/conform.py`. Gas is in Ggas and edges are in Tgas.

| flow | statuses equal | attached gas worst | model edges | sim edges |
|---|---:|---:|---|---|
| chain1 | 1268 | 1 | 5.0, 12.9 | 5.0, 12.9 |
| chain3w | 1268 | 1 | 5.0, 13.1 | 5.0, 13.1 |
| chain_w0 | 1268 | 0 | 5.0, 9.9 | 5.0, 9.9 |
| chain_s0 | **9** | 0 | 5.0, 5.9 | 5.0, 5.9 |
| ret0 / ret1000 / ret10000 / ret100000 | 1268 each | 0 | 5.0, 10.9 | 5.0, 10.9 |
| retc0 / retc10000 | 1268 each | 0 | 5.0, 10.9 | 5.0, 10.9 |
| send_named / send_named_missing | 1268 each | 0 | 5.0 | 5.0 |
| send_nimp / send_nimp_new | 1268 each | 0 | 5.0, 8.7 | 5.0, 8.7 |
| send_eth / send_eth_new | 1268 each | 0 | 5.0, 8.5 | 5.0, 8.5 |
| send_eth_new_cb | 1268 | 0 | 5.0, 14.8 | 5.0, 14.8 |
| send_named_missing_cb | 1268 | 11 | 5.0, 7.1 | 5.0, 7.1 |
| ft_call_keep / return / over | 1268 each | 0 | 5.0, 8.4, 8.8 | 5.0, 8.4, 8.8 |
| ft_call_panic | **1265** | 0 | 5.0, 8.4 | 5.0, 8.4, 8.7 |
| ft_call_burn20000 | 1268 | 1 | 5.0, 8.4, 28.5 | 5.0, 8.4, 28.5 |
| ft_call_big2000 | 1268 | 0 | 5.0, 8.4, 8.9 | 5.0, 8.4, 8.9 |
| ft_transfer, ft_storage_new, ft_storage_again | 1268 each | 0 | 5.0 | 5.0 |
| wrap_deposit, wrap_deposit_new, wrap_withdraw, wrap_transfer | 1268 each | 0 | 5.0 | 5.0 |
| wrap_call | 1268 | 0 | 5.0, 8.4, 8.8 | 5.0, 8.4, 8.8 |
| wrap_batch_DT | 1268 | 0 | 5.0, 12.6 | 5.0, 12.6 |
| wrap_batch_DC | 1268 | **135 635** | 5.0, 37.6 | 5.0, 37.6 |
| wrap_batch_DST | 1268 | 0 | 5.0, 18.6 | 5.0, 18.6 |
| wrap_batch_DSC | 1268 | **179 800** | 5.0, 43.6 | 5.0, 43.6 |

## Mismatch log

Every difference below is between the model and nearcore. The sim was not patched. None of them
is a sim-vs-nearcore divergence: the sim runs nearcore's runtime.

1. **chain_s0: a function call with 0 attached gas.** The parent creates a call with static 0
   and weight 0.
   - **nearcore:** rejects the parent's promise with
     `ActionsValidation(FunctionCallZeroAttachedGas)`. The parent fails and no child exists.
   - **Model:** creates the child, which then runs out of gas, and the parent succeeds.
   - **Status:** library gap, reported for `modules/`. Edges agree, since the parent's own
     out-of-gas edge is the same.
2. **ft_call_panic, 8.4-8.6 Tgas.**
   - **nearcore:** the receiver runs out of gas before it reaches its panic (`oog`).
   - **Model:** reports `failed`, because the verdict checks the error before gas.
   - **Status:** label only; the revert and the refund are the same. Suggested fix: a call that
     errors with less gas than its burn reports out of gas.
3. **wrap_batch_DC / DSC: attached gas of `ft_on_transfer` in a multi-call receipt.**
   - **nearcore:** splits the leftover per function-call action. The child created by the last
     action gets that action's gas minus its own burn and its children's costs. Every earlier
     action's leftover is refunded.
   - **Model:** splits the receipt's whole leftover.
   - **Status:** library gap. Statuses and edges agree because the receiver has plenty of gas
     either way. Per-action gas matches exactly. Measured burns: last action 1549 Ggas in both
     flows; earlier actions 612 Ggas (DC) and 1190 Ggas (DSC). Suggested fix: for a multi-call
     receipt, compute the split from the last call's gas and burn.
4. **send_named_missing_cb: up to 11 Ggas on the callback's attached gas.** `p.send`'s burn
   varies with the receiver id's length (280-300 Ggas). The single key holds the largest burn.
   **Status:** calibration granularity; edges agree.
5. **Merged token keys.** The token modules have one burn key per method, so a key whose burn
   depends on the path holds the largest burn seen:

   | key | path burns (Ggas) |
   |---|---|
   | `wrap.near_deposit` | 608 registered / 678 registering |
   | `ft.ft_resolve_transfer` | 418 / 858 with a refund |
   | `wrap.ft_resolve_transfer` | 420 / 848 |
   | `ft.storage_deposit` | 556 / 595 |

   **Status:** conservative by construction; edges agree.

The split check excludes the children of multi-call receipts (3648 seen) for the reason in
item 3.
