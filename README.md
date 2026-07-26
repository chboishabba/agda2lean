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

The first vertical tranche provides:

- a strict typed Core IR;
- a deterministic canonical CBOR codec;
- SHA-256 content addressing;
- a transactional SQLite/WAL catalog;
- normalized declaration and direct-dependency indexes;
- CLI initialization, ingestion, extraction, inspection and verification;
- round-trip, determinism, deduplication and corruption tests.

JSON is deliberately absent from the authoritative path. SQLite is the
queryable operational store, CBOR is the semantic encoding, and CLI reports are
the human inspection surface.

## Commands

```bash
cabal build all
cabal test all

cabal run agda2lean -- init --database build/catalog.sqlite
cabal run agda2lean -- put-module \
  --database build/catalog.sqlite \
  --input module.cbor
cabal run agda2lean -- inspect --database build/catalog.sqlite
cabal run agda2lean -- verify --database build/catalog.sqlite
```

`put-module` validates and re-encodes the supplied object before storing it, so
non-canonical or trailing input cannot acquire an authoritative object hash.

See [PLANNING.md](PLANNING.md), [ROADMAP.md](ROADMAP.md), and
[ADR 0001](docs/adr/0001-storage-and-canonical-encoding.md).
