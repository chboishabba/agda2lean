# ADR 0003: Project closure, interface caches, and generated Lake workspaces

## Status

Accepted.

## Decision

Project-scale translation is orchestrated by `scripts/a2l_project.py`. The
driver discovers only module names and import edges from concrete Agda files;
Agda 2.9 remains the sole parser, elaborator, and semantic authority.

For one or more entry modules, the driver:

1. resolves the transitive project import closure;
2. classifies reviewed platform imports separately from project imports;
3. rejects unresolved imports and cycles before invoking a compiler;
4. schedules modules in dependency-first frontiers;
5. extracts independent modules in a frontier concurrently;
6. emits independent Lean modules in the same deterministic frontier order;
7. replaces native platform imports with explicit prelude decisions; and
8. writes an isolated, self-contained Lean 4.28 Lake workspace.

The emitted `plan.tsv`, platform-import receipts, diagnostics, builtin
receipts, and `files.sha256` make these orchestration decisions auditable.
Machine-local cache roots are removed from generated human artifacts before
hashing.

## Cache identity

Agda interfaces are never written into the user's source checkout. The closure
is materialized as a writable shadow project under:

```text
build/cache/agda/<toolchain-sha256>/<source-closure-sha256>/
```

The toolchain key includes the backend executable (or a deliberate pinned
toolchain identifier). The source key includes the deterministic closure plan,
module names, relative source paths, and all source bytes. Agda's own interface
cache therefore lives beneath a key that changes whenever the relevant
toolchain or source closure changes.

Source bytes are stored once in a cross-closure content-addressed pool at
`build/cache/agda/sources/sha256/`. Shadows hardlink immutable blobs when the
filesystem permits and fall back to copies otherwise. A one-file edit in a
10,000-module project therefore adds one new blob instead of copying the other
9,999 files into another cache generation. `sources.tsv` records every blob
identity and materialization decision.

`-j1` is used inside each Agda process. Parallelism is supplied across
independent modules at a DAG frontier, preventing accidental nested
parallelism and making the `--jobs` memory bound meaningful.

## Platform imports

`Agda.Builtin.*` and `Agda.Primitive` imports are platform decisions rather
than project modules. Once their uses have been lowered through the semantic
builtin registry, the project driver replaces those imports with an explicit
comment recording that Lean's native prelude supplies the entity. Any
remaining qualified Agda reference then fails the Lean build instead of being
silently supplied by an ad hoc shim.

Unreviewed external modules are not guessed. They require either another
Agda source root or an explicit external policy, and the resulting Lean import
must be supplied by the generated workspace's dependency policy.

## Promotion gate

`scripts/check-jfixedpoint.sh` is the first strict proof-producing project
gate. It requires:

- all original `JFixedPoint.agda` public declarations, including
  `fixed-0`, `fixed-1`, `fixed-2`, and `fixed-100`;
- `--fail-on-reconstruction` emission;
- a Lean 4.28 build of the complete generated project closure;
- kernel reduction of `contract-all tower-3` to the expected list;
- empty axiom closures for every required declaration;
- no `sorry`, `Lean.sorryAx`, or generated `axiom`; and
- byte-identical deterministic workspace receipts across two regenerations.

The fixture is pinned under `test/agda/`; shared compiler and orchestration
logic contains no `JFixedPoint` name checks.
