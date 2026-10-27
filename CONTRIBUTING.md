# Contributing

## Setup

- Java 21 (what CI uses).
- `tools/tla2tools.jar`: tla2tools **v1.7.4** (TLC 2.19). The file is gitignored. Fetch it the
  way CI does:

  ```sh
  curl -sSfL -o tools/tla2tools.jar \
    https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
  echo "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  tools/tla2tools.jar" \
    | shasum -a 256 -c -
  ```

  Or point `TLA2TOOLS_JAR` (or `--jar`) at an existing copy.
- Python 3.11 or later, standard library only, for `tools/`.
- Rust, only for the conformance suite (see below).

## Running the examples

Every example directory `examples/<name>/` has one or more specs and a `runs.toml` that lists
its TLC runs and the verdict each must give.

```sh
python3 tools/run.py                    # every run under examples/
python3 tools/run.py --list             # list runs
python3 tools/run.py examples/pay       # one directory
python3 tools/run.py examples/pay pay_std   # one run within a directory
python3 tools/run.py 'pay_*'            # runs by name under examples/ (globs work)
python3 tools/run.py --print-trace pay_ignore   # show the counterexample of a violating run
python3 tools/run.py --keep pay_std     # keep the generated wrapper, cfg and log in build/
python3 tools/run.py examples/pay --anti-vacuity   # also its witnesses and mutants
python3 tools/run.py examples/owed-effect --sweep  # also its least-gas and size sweeps
python3 tools/run.py examples/owed-effect vault_gas_short --least-gas 'GasMenu={%d}' --gas-range 0:300000
```

A `[[sweep]]` bisects a gas knob for the boundary at which a run's success invariants start
to hold and reports need − 1, need and need + 1 (`exact = true` or `--exact` scans every
value instead, for the least one when success is not monotone), or runs a size knob at 1, at the contract's cap and
at the protocol limit, ±1 each ([Least gas and size
sweeps](docs/RUNNER.md#least-gas-and-size-sweeps)). A change that moves a gas or size edge
keeps an example's sweeps as expected.

For each run the runner generates a wrapper `MC_<run>.tla` and a config `MC_<run>.cfg` in a
fresh temporary directory, runs TLC there with `-DTLA-Library` pointing at `modules/`, and
exits nonzero if a verdict differs from its `expect`. It keeps the wrapper, config and log in
`examples/<name>/build/` (gitignored) only for runs whose verdict did not match, or for every
run with `--keep`. See `python3 tools/run.py --help` for the `runs.toml` format, and
[`docs/USAGE.md`](docs/USAGE.md) for writing a model of your own.

**Thread stack.** TLC evaluates nested and recursive operators on the JVM thread stack, and
the default (512 KB to 1 MB) overflows on large sets (`StackOverflowError`; CI hit it on the
Linux runner in `limit_join_128` and `limit_log_101`). Every TLC process the repo starts gets
`-Xss16m`: `tools/run.py` (and so both CI workflows), `tools/sany.py` and
`conformance/scripts/tlc.sh`. `TLC_JAVA_OPTS` comes after it, so an `-Xss` there wins, and a
run's own `stack = "512k"` in `runs.toml` after that. Library sums split their sets
(`KeySum`, `RcptSum`, `SeqSum`, `FunSum` in `NearAsync`) instead of recursing once per element;
write new ones that way. `examples/limits`' `limit_fan_gas_1000` checks it: a gas-mode split
over 1000 children on a 512 KB stack, which a per-element sum overflows.

## Parsing

Run SANY on everything you touched before pushing. CI parses every module and fails on any error:

```sh
python3 tools/sany.py modules examples conformance/tla
# or, for one module:
cd modules && java -cp ../tools/tla2tools.jar tla2sany.SANY NearFees.tla
```

SANY in v1.7.4 exits 0 even on semantic errors; `tools/sany.py` checks the output too.

## The conformance suite

The Rust crate in `conformance/` checks the model's per-receipt predictions against nearcore's
runtime through near-contract-sim. It also produces the calibrated gas tables. CI on push does not
build Rust; the suite runs nightly and on demand (`.github/workflows/conformance.yml`) and
locally. See [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) for how to run
it and how to read a mismatch, and [`conformance/README.md`](conformance/README.md) for the
flow-spec format used to add a probe flow.

## What every change needs

**A semantic change** is any change to what a module allows, forbids or computes. It needs all
of these:

1. **A nearcore citation:** `path:line @ <rev>` at the reference revision (currently b7b4737,
   2.14.0-rc.5), in the module comment and in `docs/SEMANTICS.md`. If the behaviour depends on
   the protocol version, say which. Do not cite a newer nearcore's line numbers without checking
   them at the reference revision.
2. **A must-fail example:** in `examples/<name>/`, a correct toy contract with
   `expect = "pass"` and a deliberately wrong one with `expect = "violation"` naming the
   invariant. Check the trace: the wrong one must fail for the reason its comment gives, not
   for an unrelated one.
3. **A conformance probe**, where feasible, that exercises the rule in the sim and compares
   per-receipt outcomes with the model. If it is not feasible, say why in `SEMANTICS.md` and mark
   the rule "nearcore reading" or "recalled", not "sim".
4. **`docs/SEMANTICS.md` updated:** the rule, the citation, the operator, and the validation
   level. If the change adds or removes an approximation, update "Not modelled" as well.
5. **`CHANGELOG.md` updated.** A break of an operator name, arity or meaning goes under
   "Breaking" with a one-line migration.

**A new example** ships witnesses and mutants in its `runs.toml`, beside its must-pass and
must-fail runs (see [Witnesses and mutants](docs/RUNNER.md#witnesses-and-mutants)):

- `NoOrphans` in its `Sane`;
- a `[[witness]]` for the antecedent of every `P => Q` invariant, for each arm of every
  callback that reads a promise result, and at each numeric guard's threshold;
- a `[[mutant]]` for each bug class the example claims to cover (dropped `.then`, failure
  branch skips rollback, inverted result check, removed precondition, off-by-one guard, wrong
  refund account), each killed, or marked `equivalent` with the reason;
- `python3 tools/run.py examples/<name> --anti-vacuity` all as expected. CI runs it in its own
  job.

A change to an existing example keeps its witnesses reached and its mutants killed.

**A fee-table change** follows `docs/VERSIONING.md`.

**A calibrated table** records the wasm sha256, the source crate and version, the sim revision,
the nearcore revision and the protocol version.

## Keeping runs fast

- Keep each example run under about **60 s on 2 workers**, and set `budget_s` in `runs.toml`.
  CI fails a run that exceeds its budget.
- Use at most 2 TLC workers locally (`workers = 2`; the runner caps at 4).
- Shrink scope before adding symmetry tricks: fewer accounts, smaller amounts, shorter gas
  menus. A run that needs minutes belongs in a local-only config, not in `runs.toml`.

## Content rules

- Examples are fresh toy contracts written for this repo. Do not add models, configs, traces,
  findings or calibration numbers of real deployed contracts.
- No personal details in files, logs or commit messages: no names, emails, machine names or
  home-directory paths (write `~`). The runner rewrites `$HOME` to `~` in logs.
- Commit with your normal git identity. Do not add AI-attribution trailers or footers.
