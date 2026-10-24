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
tools/run.py                    # every run under examples/
tools/run.py --list             # list runs
tools/run.py examples/pay       # one directory
tools/run.py 'pay_*'            # runs by name (globs work)
tools/run.py --print-trace pay_ignore   # show the counterexample of a violating run
tools/run.py --keep pay_std     # keep the generated wrapper, cfg and log in build/
```

The runner writes `MC_<run>.tla`, `MC_<run>.cfg` and `<run>.log` into `examples/<name>/build/`
(gitignored), runs TLC with `-DTLA-Library` pointing at `modules/`, and exits nonzero if a
verdict differs from its `expect`. See `tools/run.py --help` for the `runs.toml` format.

## Parsing

Run SANY on everything you touched before pushing. CI parses every module and fails on any error:

```sh
tools/sany.py modules examples
# or, for one module:
cd modules && java -cp ../tools/tla2tools.jar tla2sany.SANY NearFees.tla
```

SANY in v1.7.4 exits 0 even on semantic errors; `tools/sany.py` checks the output too.

## The conformance suite

The Rust crate in `conformance/` checks the model's per-receipt predictions against nearcore's
runtime through near-contract-sim. It also produces the calibrated gas tables. It runs locally
only; CI does not build Rust. See [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) for how to run
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
