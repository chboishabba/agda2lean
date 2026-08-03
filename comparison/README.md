# Comparison workspace

This directory is the hermetic Lean comparison workspace for emitted `agda2lean`
output.

The intended flow is:

1. run the Agda backend to populate `build/moonshine-lean/`;
2. stage those generated files into `comparison/generated/`;
3. stage the handwritten mirror files into `comparison/fixtures/handwritten/`;
4. create the root Lean source links in this directory;
5. build the workspace under the pinned `lean-toolchain`.

The workspace is intentionally split into data and build surfaces:

- `generated/` stores emitted Lean files copied from `build/`;
- `fixtures/handwritten/` stores the authoritative handwritten Lean mirrors;
- `Agda2Lean/Compat/` is reserved for future compatibility facades;
- the root Lean modules in this directory are symlinks into those staging areas.

The first acceptance gate is Moonshine:

- every generated file elaborates under Lean 4.28;
- the handwritten Moonshine mirror elaborates under the same toolchain;
- the generated Moonshine receipt is normalized and compared against
  `receipts/moonshine.receipt.tsv` for statement/dependency and axiom-closure
  regression coverage.

The next semantic gate is handled by `scripts/check-moonshine-correspondence.sh`:

- generated and handwritten Moonshine manifests are extracted in the same
  workspace;
- statement shape and direct type dependencies are compared after name
  normalization;
- `value-direct` rows are recorded as informational proof-machinery context;
- `Lean.sorryAx` in either axiom closure is a hard failure;
- the script emits phase heartbeats while Lake or Lean work is still running.

The proof-producing `JFixedPoint` tranche is intentionally stricter than the
historical mirror checks. `scripts/check-jfixedpoint.sh` uses the pinned fixture
in `test/agda/`, generates a standalone Lake workspace through the transitive
project driver, validates the original Agda public surface (including all four
`fixed-*` theorems), audits Lean axiom closures, and kernel-checks the expected
`contract-all tower-3` reduction. The handwritten mirror's stronger
`stack_converges` theorem remains a target-only strengthening rather than a
substitute for those facade declarations. The checked-in
`receipts/jfixedpoint.project-dependencies.tsv` is the reviewed project-local
boundary policy; the gate combines it with Agda dependency comments and Lean's
elaborated manifest to produce `build/jfixedpoint-gate/jfixedpoint.correspondence.tsv`.
