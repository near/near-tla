# AGENTS.md

Instructions for AI agents working in this repo. Humans: see `CONTRIBUTING.md`.

## What this repo is

near-tla is a library of TLA+ modules that model how nearcore executes receipts: callbacks,
promise results, revert scope, refunds, gas as a quantity, accounts, signers and access keys,
and the NEP-141/145/245 and wNEAR token standards. You write a contract model on top of it and
model-check it with TLC. A Rust suite checks the model against nearcore's real runtime through
near-contract-sim.

## Repo map

```
modules/              the library, one flat directory (passed to TLC as -DTLA-Library)
  NearAsync.tla       platform: receipts, callbacks, data, refunds, Transfer/Stake, accounts, storage, gas, local receipts
  NearKeys.tla        access keys, signed submission, AddKey/DeleteKey, multi-action atomicity
  NearFees.tla        action fees in Ggas per protocol version (pure definitions)
  TokenCommon.tla     token argument records, deviations, resolver arithmetic
  Nep145.tla  Nep141.tla  WNear.tla  Tokens.tla   fungible tokens (EXTEND Tokens)
  Nep245.tla          external multi-token contract
  CalibStd.tla        measured gas tables for the standard FT and wNEAR (generated; do not edit)
  CalibStdMt.tla      measured gas tables for a near-sdk-contract-tools NEP-245 token (generated; do not edit)
  StorStd.tla         measured storage bytes for the standard FT and wNEAR (generated; do not edit)
examples/<name>/      toy contracts + runs.toml (must-pass and must-fail runs)
examples/minimal/     the minimal model that docs/TUTORIAL.md builds
examples/platform-selftest/   deterministic scenarios with known nearcore outcomes
tools/run.py          runner: wrappers, TLC, verdict check (see --help)
tools/sany.py         parse check
tools/windows.py      fold print-only window reports into gas intervals
tools/tlctrace.py     print a TLC counterexample as a story (--raw: changed variables only)
tools/audit.py        the runner's audit of what the runs reach
tools/check_links.py  offline Markdown link check (CI runs it)
tools/test_run.py     the runner's self-tests (python3 -m unittest tools/test_run.py)
tools/tlcparse.py     TLC output parsing shared by the tools
conformance/          Rust conformance + calibration crate (standalone; CI does not build it)
Cargo.toml            carries near-tla's version for release-plz (never built; tools/version.rs is
                      its empty target); release-plz.toml configures the releases
conformance/probes/   probe contracts (Rust -> wasm), committed with their hashes
conformance/flows/    flow specs (probes.toml, actions.toml, storage.toml, example.toml)
conformance/tla/      the model side of conformance runs
conformance/scripts/  gen_probes.py, mkconf.py, tlc.sh, conform.py
docs/                 CONCEPTS.md (NEAR and TLA+ basics, vocabulary, what results mean),
                      TUTORIAL.md (first model), USAGE.md (modelling guide), RUNNER.md (runs.toml,
                      traces, witnesses, mutants, sweeps, audit), VALIDATING.md (replaying a
                      counterexample), SEMANTICS.md (rules, citations, trust), CONFORMANCE.md,
                      VERSIONING.md
skills/near-tla/      the agent skill for modelling a user's contract (SKILL.md)
```

## How to run things

```sh
python3 tools/sany.py modules examples       # parse everything
python3 tools/run.py                         # all example runs; nonzero exit on any unexpected verdict
python3 tools/run.py 'pay_*' --print-trace   # some runs, with traces
python3 tools/run.py path/to/model/ my_run   # one run of a model outside examples/
```

`tools/tla2tools.jar` must be tla2tools v1.7.4 (see `CONTRIBUTING.md`). Modelling a contract:
`docs/TUTORIAL.md`, then `docs/USAGE.md`; the runner: `docs/RUNNER.md`. The conformance suite:
`docs/CONFORMANCE.md`.

## Rules

- **Cite nearcore.** Every semantic rule in a module comment or in `docs/SEMANTICS.md` carries
  `path:line @ <rev>` at the reference revision (bc4e9e8, 2.14.0). Read the line before you
  cite it; line numbers in other checkouts differ. If you could not read the source, say
  "recalled".
- **No confidential contract material.** Examples and probes are fresh toy contracts written for
  this repo. Never add models, configs, traces, findings or calibration numbers of real deployed
  contracts, and never name a real contract in connection with a bug.
- **No personal details or home paths** in any file, log, test name or commit message. Write
  `~` for home. Leave HTTP `User-Agent` headers at their defaults.
- **No git identity overrides.** Do not pass `-c user.name`, `-c user.email` or `--author`, and
  do not set `GIT_AUTHOR_*` / `GIT_COMMITTER_*`.
- **No AI attribution:** no `Co-Authored-By` trailers, no "Generated with" footers, in commits,
  PRs or docs.
- **Conventional Commits, through pull requests.** `main` takes changes only by pull request,
  squash-merged, so the PR title becomes the commit. Titles and commit messages are
  `type(scope): summary` (`feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `chore`; scope
  optional, lower case). `!` after the type, or a `BREAKING CHANGE:` footer, marks a breaking
  change as `docs/VERSIONING.md` defines it; put the migration in that footer. release-plz writes
  `CHANGELOG.md` and the next version from the titles. CI's `conventional-commits` check fails
  otherwise.
- **Rust:** build with plain `cargo`, not an absolute toolchain path. Keep any resource limits
  you are given (`-j`).
- **TLC:** at most **2 workers** per run (the runner caps at 4). Use `-metadir /tmp/tlc-<name>`
  for ad-hoc runs and delete those directories afterwards. `-deadlock` is normal: quiescence is
  not an error. Keep each example run under about 60 s.
- Run `python3 tools/sany.py modules examples` before handing work back.

## The method that works

1. **Write the properties first.** State what must hold (books balance, every refund is honoured,
   no double pay) before you write the handlers. Prefer per-user and per-operation obligations to
   one conservation total: a total cannot tell you that one user's money moved to another.
2. **Gas is a quantity, not a boolean.** In gas mode a receipt fails because its calibrated need
   exceeds the gas it holds, and the leftover split decides who gets how much. "This call may fail"
   (fault mode, `MayFail`) is a coarser tool. Use it to explore, not to conclude.
3. **Calibrate before trusting windows.** A gas window is only as good as the burn table. Measure
   burns in the sim for every path that creates a different set of promises, record the table's
   provenance (wasm sha256, crate version, sim rev, nearcore rev, protocol), and check that the
   leftover split reproduces with zero mismatches before believing any gas-mode verdict.
4. **Replay every counterexample on real wasm.** The model over-approximates ordering and
   abstracts the contract. A trace is a hypothesis until the same receipt tree, with the same gas
   and faults, reproduces against the compiled contract: in near-contract-sim, or in a
   near-workspaces sandbox (`docs/VALIDATING.md`).
5. **Show every invariant can fail.** For each invariant, add a deliberately wrong variant (the
   must-fail example) and check that TLC reports a violation of that invariant, for the reason you
   intended. Confirm this from the trace. An invariant that has never failed may be vacuous.
6. **If you conjoin `LocalPriorityOK`, also run without it.** Local priority is opt-in (off
   unless conjoined) and assumes the receiving chunk is not at its compute limit. A violation
   that appears only without it is reachable under congestion; dismiss it only with a concrete
   argument that the receiving chunk cannot be full (`docs/SEMANTICS.md`, S1).
7. **Know what is not modelled.** Read the "Not modelled" section of `docs/SEMANTICS.md` before
   claiming a result. Under-approximations there can hide bugs.
