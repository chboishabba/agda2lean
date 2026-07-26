# ADR 0002: Elaborated extraction and Lean facades

## Status

Accepted.

## Decision

`agda2lean` extracts Agda's typechecked internal syntax through a custom Agda
2.9 compiler backend pinned to an audited source revision. It does not parse
concrete `.agda` text.

The backend uses Agda 2.9 language metadata for Cubical classification and
preserves dependencies/features from local `@rewrite` domains. Agda import
elaboration may run with a bounded `-j` value, while snapshot emission remains
deterministic and sequential per module.

The boundary is split into two layers:

1. `agda2lean-agda` is a thin, version-pinned adapter over
   `Agda.Compiler.Backend`.
2. `Agda2Lean.Agda.Extract` converts a stable elaboration snapshot into the
   versioned typed IR, interns repeated terms into a DAG, discovers direct
   dependencies, and classifies non-portable features.

This keeps Agda API churn out of the persistent representation and out of the
Lean emitter.

The Lean facade emitter preserves:

- the top-level module and direct imports;
- fully qualified Agda names, including escaped Lean identifiers for mixfix
  and Unicode names;
- binder order, visibility, relevance metadata, and dependent types;
- source locations and direct dependency boundaries;
- the distinction between exact bodies and reconstruction obligations.

It does not promise to preserve Agda's proof strategy. Exact portable bodies
are emitted directly. A renderable statement with a non-portable or absent body
is emitted as an explicit axiom or `sorry`-backed theorem according to its
declaration role, and a diagnostic is always recorded. With
`--fail-on-reconstruction`, theorem obligations are emitted as blocked comments
and the command exits unsuccessfully.

Cubical interval application, rewrite primitives, coinduction, unresolved
metavariables, internal dummy terms, and unannotated internal lambdas cross the
boundary as explicit extension or unsupported nodes. They are never silently
translated to Lean equality.

Adding explicit `Prop` and `SSet` universe forms advances both the IR schema and
canonical CBOR codec to version 2. Prototype version-1 objects must be
re-extracted; they are rejected rather than ambiguously upgraded.

## Dependency-boundary invariant

For every emitted declaration, the IR stores the exact set of global names
reached from its elaborated type and all elaborated source clauses. This remains
true when the clauses themselves are not copied as a Lean proof strategy:

```text
dependencies(declaration)
  = globals(type) union globals(elaborated clauses) minus self
```

The generated Lean source repeats this set in a stable declaration comment.
A later Lean manifest pass will compare the constants used by the elaborated
Lean declaration against this expected boundary.

## Scale consequences

- Agda is loaded once per project/module graph by its normal compiler driver.
- Each module is written independently as canonical CBOR.
- Term interning prevents repeated telescopes and shared subterms from becoming
  serialized trees.
- Lean files are emitted module-by-module and can be elaborated independently
  in dependency order.
- Human-readable diagnostics are tab-separated text; SQLite and CBOR remain the
  machine interfaces.
