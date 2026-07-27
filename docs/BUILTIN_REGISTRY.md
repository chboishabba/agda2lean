# Builtin registry hardening contract

The builtin subsystem treats Agda builtin bindings as semantic identities, not source-name coincidences.

## Decision pipeline

```text
Agda elaborated binding
  -> BuiltinId
  -> canonical CBOR
  -> validated registry composition
  -> Lean lowering
  -> semantic receipt
```

The public registry label remains `lean4-platform-v1` for compatibility with codec-v3 receipts. The actual reviewed rule set is additionally bound by the canonical SHA-256 `platformRegistryDigest`; changing rule content changes the digest.

## Agda extraction and target-policy boundary

The Agda 2.9 backend is deliberately target-neutral. It queries Agda's active elaborated builtin environment, records canonical `BuiltinId` values in the IR, and writes codec-v3 CBOR. It does **not** load Lean registry files: doing so would couple source-language extraction to one target platform and would make the same CBOR non-portable.

Registry files are therefore loaded and validated at the production `emit-lean` boundary, where Lean policy is actually selected. Before any Lean or receipt output is written, the CLI:

1. checks the codec/registry/receipt/Agda/Lean compatibility tuple;
2. loads all requested layers;
3. validates deterministic composition;
4. verifies that the effective registry covers every builtin encountered in the module;
5. emits with that effective registry;
6. verifies one semantic receipt per encountered builtin decision.

This is the completed backend integration contract: the Agda backend supplies semantic identities, while the Lean backend consumes an explicitly composed target registry. There is no hidden platform lookup between those boundaries.

## Complete current inventory

The lowering surface is exactly the `BuiltinId` enumeration. `builtinCoverageInventory` classifies every constructor with:

- Agda audit key;
- expected entity kind;
- support status;
- Lean strategy;
- computation treatment;
- axiom delta;
- override policy.

`renderBuiltinCoverageInventory` provides deterministic TSV output. A future Agda builtin is not inferred from its printed name: it must first receive an explicit `BuiltinId`, inventory classification, and registry rule or an explicit blocked status.

The broader Agda 2.9 declaration universe is audited by `scripts/check-agda-builtin-inventory.sh`. It reads `Agda.Syntax.Builtin` from the pinned Cabal source cache (or `AGDA_SOURCE_DIR`) and reports all 313 upstream `BuiltinId` and `PrimitiveId` entries.

The coverage decision is explicit:

- 18 currently recognised semantic identities are represented by the language-neutral IR and platform registry;
- the remaining 295 upstream names are `unsupported-or-unmapped` and are outside the current translation contract;
- they are not silently accepted, name-matched, or assigned placeholder `BuiltinId` values;
- promotion requires a reviewed semantic identity, entity kind, computation treatment, axiom effect, extraction binding, lowering rule, and tests.

An explicitly unsupported entry is safer than a nominal mapping with no established cross-language semantics.

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

Composition is deterministic with respect to map and rule insertion order. The Lean emitter receives the resulting effective `Map BuiltinId PlatformMapping` through `EmitOptions`; the production CLI additionally checks complete coverage before invoking it.

### Registry file format

Registry files use deterministic UTF-8 TSV:

```text
# registry-name\tmy-library
# registry-version\t1
# registry-scope\tLibraryScope
builtin-id\tagda-binding\tlean-target\trule\tcomputation\taxiom-effect\taxiom-delta\tentity-kind
```

Rows use the exact constructor spellings exported by the compiler. `axiom-delta` is `-` or a comma-separated list. Files round-trip through `parseRegistryLayer` and `renderRegistryLayer`.

Production CLI options are repeatable:

```sh
agda2lean emit-lean \
  --input module.a2l.cbor \
  --lean-output Module.lean \
  --diagnostics diagnostics.tsv \
  --builtin-receipt builtins.tsv \
  --library-registry library.tsv \
  --project-registry project.tsv
```

Fixture layers additionally require both `--fixture-registry PATH` and `--registry-test-mode`; otherwise composition fails closed.

Because every current `BuiltinId` is platform-protected, current library and project files are normally empty extension declarations. They cannot redefine `Nat`, `Bool`, equality, or universes. New extension identities must be introduced deliberately before such layers can supply mappings.

## Compatibility tuple

`VersionContext` binds:

- CBOR codec version;
- builtin registry version;
- receipt schema version;
- Agda backend version;
- Lean target platform.

`checkVersionCompatibility` returns `Compatible`, `MigrationRequired`, or `Incompatible`. Semantic version skew is checked before translation and is fail-closed rather than warning-only.

## Receipt completeness and provenance

For every module:

```text
encountered builtin declarations == emitted builtin receipt rows
```

The production CLI verifies this equality before writing output. It also refuses to emit if any encountered `BuiltinId` is absent from the effective registry.

Receipt headers bind:

- receipt schema;
- codec version;
- nominal registry version;
- SHA-256 digest of the complete effective registry;
- Agda backend version;
- Lean target.

Mapped, blocked, and unsupported lowering outcomes remain explicit in receipt status and diagnostics. Receipt, diagnostics, Lean, and inventory files are written atomically.

Builtin receipts should be required in correspondence gates, release verification, and audit workflows. Ordinary local compilation may keep receipt output optional, but the internal completeness check is always applied.

## Receipt and release policy

Generated Lean, CBOR, temporary comparison workspaces, and ad-hoc receipt files are reproducible build products and should remain ignored. Only reviewed golden fixtures and selected durable audit examples belong in version control.

The hardening tests exercise complete inventory coverage, protected mappings, duplicate/conflict rejection, production fixture rejection, version skew, registry digest shape, insertion-order determinism, registry-file round-tripping, and invalid identifier rejection.

## Agda 2.9 validation entrypoint

The Agda backend has a separate Cabal project because Agda 2.9 is pinned from the audited source revision. Do not invoke the backend with plain `cabal` from the default project. Use:

```sh
nix develop -c scripts/cabal-agda-2.9.sh build --flag agda-backend exe:agda2lean-agda
nix develop -c scripts/check-agda-backend.sh
```

The wrapper selects `cabal.project.agda-2.9`; the check script builds the backend, resolves the resulting executable, and processes `Identity.agda`.
