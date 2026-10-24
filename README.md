# near-tla

TLA+ models of NEAR's runtime execution semantics, for model-checking smart
contracts against the way nearcore actually executes receipts.

> Status: under construction (pre-0.1.0). Module APIs may still change.

## What's here

| path | contents |
|---|---|
| `modules/` | the reusable TLA+ library: receipts, callbacks and promise results; revert scope and refunds; gas as a quantity; accounts; signers and access keys; NEP-141, NEP-145, NEP-245 and wNEAR |
| `examples/` | toy contracts with must-pass and must-fail TLC runs |
| `tools/` | the runner (generates per-run wrappers, runs TLC, checks expected verdicts) |
| `conformance/` | a Rust suite that checks the model's per-receipt predictions against nearcore's runtime (via near-contract-sim). Runs locally only |
| `docs/` | semantics and trust, usage, conformance, versioning |

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.
