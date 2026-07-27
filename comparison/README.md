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
