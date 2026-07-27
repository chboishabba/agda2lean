# Builtin registry hardening contract

The builtin subsystem treats Agda builtin bindings as semantic identities, not source-name coincidences.

## Decision pipeline

```text
Agda elaborated binding
  -> BuiltinId
  -> validated registry composition
  -> Lean lowering
  -> semantic receipt
```

The public registry label remains `lean4-platform-v1` for compatibility with codec-v3 receipts. The actual reviewed rule set is additionally bound by the canonical SHA-256 `platformRegistryDigest`; changing rule content without changing the digest is impossible.

## Complete current inventory

The supported compiler surface is exactly the `BuiltinId` enumeration. `builtinCoverageInventory` classifies every constructor with:

- Agda audit key;
- expected entity kind;
- support status;
- Lean strategy;
- computation treatment;
- axiom delta;
- override policy.

`renderBuiltinCoverageInventory` provides deterministic TSV output. A future Agda builtin is not silently inferred from its printed name: it must first receive an explicit `BuiltinId`, inventory classification, and registry rule or an explicit blocked status.

The broader Agda 2.9 declaration universe is audited by
`scripts/check-agda-builtin-inventory.sh`. It reads `Agda.Syntax.Builtin` from
the pinned Cabal source cache (or `AGDA_SOURCE_DIR`) and reports every Agda
`BuiltinId` and `PrimitiveId`, marking entries that are not registered by the
backend as `unsupported-or-unmapped`. This keeps the upstream inventory
derived and reproducible rather than hand-maintained.

## Registry layers

Layers are validated semantic scopes:

1. `PlatformProtected` — language/platform correspondences; never replaceable.
2. `LibraryScope` — dependency-specific extension points.
3. `ProjectScope` — project-local extension points.
4. `FixtureOnly` — test substitutions, accepted only in `TestMode`.

`composeRegistryLayers` rejects:

- duplicate rules within a layer;
- conflicting mappings across ordinary layers;
- kind mismatches;
- attempts to override platform-protected semantics;
- fixture mappings in production mode;
- mapping/layer scope inconsistencies.

Composition is deterministic with respect to map and rule insertion order.
The Lean emitter receives the resulting effective `Map BuiltinId PlatformMapping`
through `EmitOptions`; it does not perform an implicit platform-only lookup.

## Compatibility tuple

`VersionContext` binds:

- CBOR codec version;
- builtin registry version;
- receipt schema version;
- Agda backend version;
- Lean target platform.

`checkVersionCompatibility` returns `Compatible`, `MigrationRequired`, or `Incompatible`. Semantic version skew is fail-closed rather than warning-only.

## Receipt and release policy

Builtin receipts should be required in correspondence gates, release verification, and audit workflows. Ordinary local compilation may keep receipt output optional.

Generated Lean, CBOR, temporary comparison workspaces, and ad-hoc receipt files are reproducible build products and should remain ignored. Only reviewed golden fixtures and selected durable audit examples belong in version control.

The hardening tests exercise complete inventory coverage, protected mappings, duplicate/conflict rejection, production fixture rejection, version skew, registry digest shape, and insertion-order determinism.

## Agda 2.9 validation entrypoint

The Agda backend has a separate Cabal project because Agda 2.9 is pinned from
the audited source revision. Do not invoke the backend with plain `cabal` from
the default project. Use:

```sh
nix develop -c scripts/cabal-agda-2.9.sh build --flag agda-backend exe:agda2lean-agda
nix develop -c scripts/check-agda-backend.sh
```

The wrapper selects `cabal.project.agda-2.9`; the check script builds the
backend, resolves the resulting executable, and processes `Identity.agda`.
