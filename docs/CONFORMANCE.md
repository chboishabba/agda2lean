# Feature-indexed conformance programme

The conformance programme is the executable support contract for `agda2lean`. It distinguishes successful translation, explicit reconstruction, deliberate rejection, and genuinely unclassified behaviour.

## Stable classifications

Every case and every observed support row uses one of:

- `supported-correspondence`
- `reconstruction-boundary`
- `deliberately-unsupported`
- `unclassified`

An unexpected acceptance is a failure just as an unexpected rejection is. Unsupported semantics must not become plausible Lean by accident.

## Five questions per case

Each case records:

1. whether the pinned Agda revision elaborates the source;
2. which semantic builtins, declaration roles, features and IR terms appear;
3. whether checked emission accepts, reconstructs or blocks it;
4. whether diagnostics and receipts explain the decision;
5. whether an accepted result has a Lean correspondence oracle.

The unit of evidence is therefore:

```text
Agda source
  + expected extraction
  + expected lowering
  + expected receipt
  + optional Lean oracle
```

## Survey command

After running the Agda backend, inspect a canonical module with:

```sh
cabal run agda2lean-support -- \
  --input path/to/module.a2l.cbor \
  --output path/to/support.tsv
```

The report includes:

- declaration-level and term-level builtin identities;
- all IR constructor families encountered;
- declaration roles;
- feature flags;
- mapping modes;
- missing portable bodies and reconstruction points;
- cubical, rewrite, coinductive and unsafe-universe extension terms;
- an overall fail-closed classification.

The report is deterministic UTF-8 TSV and can be diffed or retained as a golden.

## Corpus manifest

`test/conformance/manifest.tsv` is the declared scope. Its columns are:

```text
id source expected phase features oracle rationale
```

`expected` uses the stable classifications above. `oracle` is `-` until a Lean correspondence file exists.

`unclassified` means not yet investigated. It must not be used as a synonym for unsupported.

## Coverage axes

Support is tracked independently across:

1. semantic builtin coverage;
2. IR term coverage;
3. declaration and module-shape coverage;
4. body/computation preservation;
5. semantic-extension boundaries.

A source file is not marked supported merely because Lean accepts generated syntax.

## Capability promotion

A builtin or language feature may move to `supported-correspondence` only when all applicable gates pass:

- pinned Agda elaboration;
- explicit semantic identity or feature detection;
- lossless IR and codec representation;
- reviewed target lowering;
- checked emission;
- Lean compilation;
- computation or theorem correspondence;
- receipt completeness and provenance;
- adversarial negative variants;
- generated support documentation.

For a new builtin family the required vertical slice is:

```text
Agda binding
  -> BuiltinId
  -> codec
  -> protected registry rule
  -> declaration and term lowering
  -> receipt
  -> computation correspondence
```

A family is not promoted by adding only a registry row.

## Semantic extension policy

The following boundaries require their own design before positive lowering:

- rewrite rules: oriented theorem-backed computation and explicit `[simp]` policy;
- sized types: proved erasure or an explicit size encoding;
- coinduction: productivity and observation/bisimulation correspondence;
- IO: effectful platform correspondence and foreign-call trust policy;
- reflection: elaborated-result preservation or a reviewed metaprogram bridge;
- cubical features: interval, path, transport and composition semantics.

Until such a design exists, reliable detection plus fail-closed rejection is the correct conformance result.

## Body translation policy

The principal positive capability gap is clause/body translation. Promotion requires a typed clause and pattern representation covering, as needed:

- variables, constructors, literals, wildcards and absurd patterns;
- projections and inaccessible patterns;
- dependent motives;
- clause ordering and coverage;
- generated with-functions;
- structural, mutual, nested and well-founded recursion;
- termination evidence;
- relevance and erasure.

Statement preservation alone is classified separately from computation preservation.

## Quantitative confidence

Release reports should publish three values rather than one misleading percentage:

```text
behavioural coverage
  = classified cases / declared cases

positive semantic coverage
  = supported cases with correspondence oracles / supported cases

fail-closed coverage
  = known unsupported cases that reliably block / known unsupported cases
```

## Commands

```sh
# Unit-level classification and report regressions
cabal test support-conformance-test

# Elaborate every non-boundary corpus case and survey generated CBOR
nix develop -c scripts/check-conformance-corpus.sh

# Render the declared support matrix without executing Agda
scripts/render-support-matrix.sh
```

Boundary fixtures may require feature-specific Agda flags or libraries. The corpus checker treats them as declared negative/survey cases rather than silently skipping their status.
