# ADR 0001: SQLite catalog with canonical CBOR objects

Status: accepted

## Decision

The operational store is SQLite in WAL mode. Semantic identity is computed
from a versioned canonical CBOR encoding. JSON is not part of the authoritative
storage or interchange path.

The catalog stores:

- the current object hash for each module;
- immutable CBOR objects keyed by their SHA-256 digest;
- declaration summaries and direct dependencies;
- schema and codec versions;
- resumable build state.

Human inspection is provided by stable CLI reports and SQL queries. It is not
provided by dumping the entire IR into a nominally textual serialization.

## Why SQLite is not itself the canonical encoding

SQLite provides transactions, indexes, bounded write amplification and useful
queries. Its page layout, row placement and database file bytes are not stable
semantic representations. Hashing a database file would make object identity
depend on insertion order, vacuuming, SQLite version and page-size choices.

Canonical CBOR therefore supplies the deterministic byte representation:

```text
typed ModuleIR
    -> versioned canonical CBOR
    -> SHA-256 object identifier
    -> SQLite object/catalog rows
```

The encoder uses fixed numeric constructor tags, definite-length arrays and
ascending numeric order for term tables. Map ordering is never delegated to a
runtime hash map.

## Performance properties

- One transaction installs an object, its module head and its indexes.
- `INSERT OR IGNORE` deduplicates identical immutable objects.
- WAL permits concurrent readers while one bounded writer commits.
- Large declaration bodies are stored once in the module CBOR object rather
  than repeated across dependency and receipt rows.
- Direct dependencies are indexed; transitive closures are computed rather
  than copied into every receipt.
- The CLI reads module bodies only for commands that need them.

If profiling later shows that large blobs should live outside SQLite, the
content-addressed object interface permits moving CBOR bytes to a packed object
store without changing hashes or catalog semantics.

## Human-facing output

The supported inspection surface is:

```text
agda2lean inspect --database build/catalog.sqlite
agda2lean inspect --database build/catalog.sqlite --module DASHI.Algebra.Trit
agda2lean verify --database build/catalog.sqlite
```

These commands render concise tables and diagnostics. Machine consumers use
SQLite queries or canonical CBOR, not JSON.
