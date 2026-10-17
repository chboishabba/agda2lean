# DASHI proof-router capability contract

`agda2lean` participates in the DASHI proof/formalisation router as a **translation-capability authority for its own elaborated catalog**, not as theorem authority.

The authoritative translation path remains:

```text
Agda elaboration
  -> typed Core IR
  -> canonical CBOR
  -> content-addressed SQLite catalog
  -> Lean facade / reconstruction obligations
  -> independent Lean validation
```

## Stable declaration query

`Agda2Lean.Capability.readDeclarationCapability` and the `agda2lean-capability` executable expose one declaration's catalog-backed routing surface:

```sh
cabal run agda2lean-capability -- \
  --database build/catalog.sqlite \
  --declaration DASHI.Example.sourceTheorem
```

The TSV result includes:

- canonical declaration and module names;
- declaration role;
- `mapping_mode`;
- content-addressed module object hash;
- exact checked Agda source SHA-256 when available;
- source file and line range;
- direct elaborated dependencies;
- explicit `authority = translation-capability-only`;
- explicit `establishes_proof = false`.

## Routing interpretation

The mapping modes keep their existing IR meaning and are consumed conservatively by `dashi-repo`:

| mapping mode | router interpretation |
|---|---|
| `exact` | agda2lean may perform the translation lane; Lean validation still required |
| `encoded` | translation lane is supported through the registered encoding; Lean validation still required |
| `reconstruct` | emit/plan the Lean obligation and route the reconstruction to Aristotle/Lean |
| `quarantined` | do not translate as proof; route to an independent formalisation path |
| `unsupported` | do not translate as proof; route to an independent formalisation path |

No mapping mode, object hash, source hash, or successful extraction can establish a Lean theorem by itself.

## SLR external formal-proof demands

SLR may export a persisted proof obligation to `dashi-repo` as an authority-neutral formal demand carrying at least:

```text
demand_ref
external_obligation_ref
statement_digest
query / statement owner
requested target prover
optional DA51 address
optional Agda source declaration
```

`agda2lean` consumes only the source-declaration / translation-capability part of that route. It does **not** consume or mutate SLR PNF, residual, proposition, Matter, review, or payment state.

The statement digest is part of the payment boundary:

```text
SLR statement_digest A
  -> dashi-repo route for A
  -> agda2lean capability/translation work for A
  -> Lean artifact
  -> independent Lean checker receipt for A
```

If translation/reconstruction changes the formal statement from digest `A` to digest `B`, the resulting certificate cannot pay the original SLR obligation merely because the symbol name, DA51 address, or source declaration stayed the same. The backend must provide an explicit equivalence/transport receipt, or the changed statement must be routed as a new demand.

### Mapping-mode handoff

```text
Exact / Encoded
  -> translation lane
  -> independent Lean check

Reconstruct
  -> reconstruction obligation
  -> agda2lean + Aristotle/Lean
  -> independent Lean check

Quarantined / Unsupported
  -> independent formalisation
  -> independent checker
```

Every mode retains `establishes_proof = false` until the independent checker boundary has been crossed.

## Max-cut with repository intelligence

The intended orchestration is:

```text
SLR proof obligation / formal demand
  -> optional DA51 identity join
  -> dashi-repo exact/equivalent/similar/history discovery
  -> fail-closed absence receipt
  -> proof-debt classification
  -> agda2lean declaration capability (when an Agda source owner exists)
  -> Aristotle / Agda / agda2lean / Lean-kernel route
  -> independent checker receipt bound to the same statement digest
  -> authority-neutral provenance/evidence edge
  -> exact SLR obligation reopen
```

`dashi-repo` owns scheduling. `agda2lean` owns the translation capability it can substantiate from elaborated Agda IR. Aristotle owns reasoning/reconstruction work assigned to it. Agda and Lean kernels own their respective certification receipts. SLR remains the owner of PNF/proof-obligation/payment state.

The following implications are forbidden:

```text
source aligned != theorem certified
agda2lean exact != Lean theorem certified
agda2lean object hash != proof authority
similar symbol != equivalent theorem
DA51 status nibble != proof term
routing receipt != theorem proof
changed statement != original obligation without transport/equivalence receipt
```
