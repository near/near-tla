<!--
The title is the squash commit on main, so it must be a Conventional Commit:
`type(scope): summary`, for example `fix(gas): ...` or `docs: ...`. `feat` and `fix` titles
become CHANGELOG entries. See CONTRIBUTING.md, "What every change needs".
-->

What changes and why:

Checked with:

- [ ] `python3 tools/run.py <changed examples>` (and `--anti-vacuity` for a new or changed example)
- [ ] `python3 tools/sany.py modules examples conformance/tla`
- [ ] for a semantic change: nearcore citation, must-fail example and SEMANTICS.md entry
