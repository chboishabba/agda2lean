# agda2lean

`agda2lean` is a proof-aware translation pipeline for producing recognisable,
native Lean counterparts of elaborated Agda declarations while preserving
their statements, dependency boundaries and required computational behaviour.

The implementation is intentionally not a text-to-text converter:

```text
Agda elaboration
    -> strict typed Core IR
    -> canonical CBOR
    -> SQLite catalog
    -> Lean facade and reconstruction obligations
    -> independent Lean validation
```

## Current implementation

The first two vertical tranches provide:

- a strict typed Core IR;
- a deterministic canonical CBOR codec;
- SHA-256 content addressing;
- a transactional SQLite/WAL catalog;
- normalized declaration and direct-dependency indexes;
- CLI initialization, ingestion, extraction, inspection and verification;
- an Agda 2.8 compiler backend that consumes typechecked internal syntax;
- a version-independent elaboration snapshot and de Bruijn-safe DAG extractor;
- direct-dependency and feature discovery from elaborated terms;
- an Agda-shaped Lean facade emitter with escaped original names;
- explicit reconstruction diagnostics and a fail-closed emission mode;
- round-trip, determinism, deduplication and corruption tests.

JSON is deliberately absent from the authoritative path. SQLite is the
queryable operational store, CBOR is the semantic encoding, and CLI reports are
the human inspection surface.

## Commands

```bash
cabal build all
cabal test all

# Build the version-pinned Agda backend when Agda 2.8 is installed.
cabal build -fagda-backend agda2lean-agda

# Typecheck a real Agda module and emit canonical IR under build/ir/.
cabal run -fagda-backend agda2lean-agda -- \
  --lean-ir --compile-dir build/ir path/to/Module.agda

cabal run agda2lean -- init --database build/catalog.sqlite
cabal run agda2lean -- put-module \
  --database build/catalog.sqlite \
  --input module.cbor
cabal run agda2lean -- inspect --database build/catalog.sqlite
cabal run agda2lean -- verify --database build/catalog.sqlite

cabal run agda2lean -- emit-lean \
  --input build/ir/Module/module.a2l.cbor \
  --lean-output build/lean/Module.lean \
  --diagnostics build/lean/Module.diagnostics.tsv

# CI/promotion mode: do not permit reconstruction sorries.
cabal run agda2lean -- emit-lean \
  --input build/ir/Module/module.a2l.cbor \
  --lean-output build/lean/Module.lean \
  --diagnostics build/lean/Module.diagnostics.tsv \
  --fail-on-reconstruction
```

`put-module` validates and re-encodes the supplied object before storing it, so
non-canonical or trailing input cannot acquire an authoritative object hash.

See [PLANNING.md](PLANNING.md), [ROADMAP.md](ROADMAP.md),
[ADR 0001](docs/adr/0001-storage-and-canonical-encoding.md), and
[ADR 0002](docs/adr/0002-elaborated-extraction-and-lean-facades.md).

Related implementations:

- [lean2agda](https://github.com/lyphyser/lean2agda)
- [Agda](https://github.com/agda/agda)
- [Lean 4](https://github.com/leanprover/lean4)
