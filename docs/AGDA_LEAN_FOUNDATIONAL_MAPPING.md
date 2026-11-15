# Agda ↔ Lean: foundational constructs and function-level quality map

> **Status (15 November 2026):** curated, machine-readable **candidate
> taxonomy**, NOT proof of translation equivalence. The registry has 51
> entries and covers the 13 lean2agda foundational gaps. No row is
> independently certified. This file adds a foundational map; it does
> **not** replace the older feature interaction crosswalk.

## Where the maps live

| Source | Scope | What it does *not* establish |
|---|---|---|
| [agda_lean_foundational_mapping.tsv](agda_lean_foundational_mapping.tsv) | Universe, binder, function, data, equality, arithmetic, logic, axiom, Cubical, and trust counterpart candidates | Kernel-checked semantic equivalence of a real translated term |
| [roundtrip_feature_crosswalk.tsv](roundtrip_feature_crosswalk.tsv) | Eight reviewed correlations between the *translators' feature taxonomies* | Same-object source/target correspondence |
| [lean/Agda2Lean/TranslationQuality.lean](../lean/Agda2Lean/TranslationQuality.lean) | Proof-relevant logical relation over functions, products, options, lists and observers | A real compiler implementing the relation |
| [test/agda/TranslationQuality.agda](../test/agda/TranslationQuality.agda) | Independently written Agda reference with `Set`-valued relation | Automatic equivalence with the Lean reference |
| [BIDIRECTIONAL_ROUNDTRIP_MAX_CUT.md](BIDIRECTIONAL_ROUNDTRIP_MAX_CUT.md) | Gates M01–M10, real cycle, receipt security, kernel and source authority | Closure of any unpaid gate |

## The central warning: `Set`, `Type`, and `Prop`

```text
Agda              Lean 4                       Requirement

Set ℓ             Type u / Sort (u+1)          preserve a proof-relevant carrier;
                                              solve predicative level constraints
Prop ℓ            Prop / Sort 0                NOT a global equality:
                                              Agda Prop is predicative,
                                              Lean Prop is impredicative
Setω              no uniform Type u            specialisation or quarantine
Σ A (λ a → P a)   Subtype P when P : A → Prop   NOT direct if P has
                                              proof-relevant Agda witnesses
Path / PathP      Eq / HEq                     no general equivalence; Cubical
                                              composition is not Lean Eq.rec
```

Agda's `Set ℓ` is computational/proof-relevant. Lean's `Type u` is
also proof-relevant; Lean's `Prop` is proof-irrelevant *definitionally*
and, unlike Agda's `Prop ℓ`, impredicative. Collapsing an Agda
`Set`-valued witness into Lean `Prop` can lose data even if both kernels
accept their own terms. Agda `Prop` cannot be interpreted as all of Lean
`Prop` without handling level constraints and elimination restrictions.

This is **not** a claim of an unconditional equivalence between
`Set ℓ` and `Type u`: context, universe equations, impredicative
occurrences, conversion/reduction rules, erasure, axioms and dependencies
still require checked translation. The mapping's "fragment" classification
means only "sensible candidate in a *restricted*, proof-relevant fragment."

The direct conflict control is `subtype.proof`: the expression
`Σ a : A, P a` with a `Set`-valued proof need not be equivalent to Lean
`Subtype P` with `P : A → Prop`. Fixing that requires an explicit
h-proposition/proof-irrelevance argument or another proof-preserving
encoding. It must **never** be silently promoted just because it looks
like a dependent pair.

## Main constructor and function dictionary

| Agda | Lean | Priority / quality obligation |
|---|---|---|
| `(x : A) → B x` | `(x : A) → B x` | Dependent Pi: logical relation of arguments and results |
| `λ x → t` | `fun x => t` | Beta/eta and elaborated implicit arguments |
| `{x : A}` / `{{x : C}}` | `{x : A}` / `[x : C]` | Explicitly account for elaborator/typeclass search |
| `record`, projection | `structure`, projection | Eta, projection reduction, recursive records |
| `data`, pattern match | `inductive`, recursor | Constructors, positivity, iota reduction, termination |
| `Maybe`, `nothing`, `just` | `Option`, `none`, `some` | Constructor shape, payload relation |
| `List`, `[]`, `_∷_` | `List`, `nil`, `cons` | Induction, `map`, length, per-element relation |
| `Nat`, `zero`, `suc` | `Nat`, `zero`, `succ` | Numerals, recursion and builtin arithmetic |
| `_+_`, `_*_` | `Nat.add`, `Nat.mul` | Closed and symbolic arithmetic checks |
| `_≡_`, `refl` | `Eq`, `rfl` | Introduction; do not infer equal elimination rules |
| `J`, `subst` | `Eq.rec`, `Eq.ndrec` | K/UIP, dependent elimination and reduction |
| `Dec P` | `Decidable P` | Prop/Set boundary, instance provenance and branching |
| `Set`-valued proof | `Subtype` proof in `Prop` | **Conflict:** must preserve or justify erasure |
| Agda rewrite pragma | Lean `simp` theorem | **Conflict:** tactic rewrites are not kernel conversion |
| Cubical `Path` | Lean `Eq` | **No direct match** without restricted interpretation |
| `--type-in-type` | predicative `Type` hierarchy | **Not a certification mode** |

This table is illustrative. The machine registry includes 51 separately
addressable IDs with domain, counterpart, restricted target profiles,
semantic risk, required M03/M04/M05/M06/M10 gates and the upstream
foundation-gap slug.

## Four distinct kinds of evidence

1. **Taxonomy / candidate**: a human-reviewed *potential* counterpart
   (this registry). No translator ran, no proof.
2. **Operational translation**: Agda2Lean and/or Lean2Agda actually
   emitted and checked source-bound target declarations, pinned to
   original source SHA and exact toolchain revisions.
3. **Checked preservation**: each generated declaration has
   statement, dependency closure, computation observer and axiom
   witnesses with both independent kernel checks (S/D/C/A).
4. **Certified round trip**: both directions and their interpretation
   maps satisfy inverse/fixed-point laws for the *same selected object*.

The labels `fragment`, `bridge`, `conflict`, `no-direct` in
the registry refer exclusively to **kind of semantic mapping**;
`certification` remains `candidate-only` for *every* row. A
`fragment` is **not** a pass. Nor is a matching name in both source
files a kernel witness.

## What should be automatic?

The long-term registry should join per-declaration **elaborated** source
and target signatures to this mapping:

```text
Agda checked declaration / Lean checked constant
   ↓  source digest, original name, full dependency closure
typed Core IR / native Lean environment
   ↓  construct-level registry lookup + source-bound elaboration
supported fragment | bridge obligation | foundational conflict
   ↓  compiler output + Agda/Lean independent kernel receipts
M03 statement | M04 axioms | M05 dependencies | M06 computation
   ↓
verified quality vector (S,D,C,A), or candidate/quarantine
```

Automatic lexical or AST mappings can *suggest* candidate pairs, but
cannot make proof certification decisions. There should be a
machine-generated **used-features table** for each actual translation
containing the dictionary IDs encountered; a failed feature should
name the exact first mismatch. The 51 curated rows are seed rules,
not a claim that all 51 compiler passes are implemented.

## Reproducible taxonomy gate

```bash
python3 scripts/check_foundational_mapping.py
python3 -m unittest discover -s scripts \
  -p 'test_check_foundational_mapping.py' -v
```

The validator requires unique stable IDs, reviewed mapping kinds,
accepted target-profile strings, explicit semantic cautions and proof
obligations, the full 13-category lean2agda gap coverage, exact
proof-relevant type and erasure boundary anchors, and
`certification=candidate-only`. It outputs a deterministic report with
`certified=0` and all proof promotion flags false. This is a
**metadata integrity gate only**, not an Agda or Lean theorem checker.

## Independent source evidence

* Agda 2.9 universe hierarchy and `Setω`:
  https://agda.readthedocs.io/en/latest/language/universe-levels.html
* Agda predicative `Prop` hierarchy:
  https://agda.readthedocs.io/en/latest/language/prop.html
* Lean 4 universes, `Sort 0`, `Type u` and impredicative `Prop`:
  https://lean-lang.org/doc/reference/latest/The-Type-System/Universes/
* Lean quotients and primitive computation:
  https://lean-lang.org/doc/reference/latest/The-Type-System/Quotients/
* `formalverification/lean2agda` foundation-gap catalog
  (13 source-authored entries, pinned Agda/Lean probes):
  https://github.com/formalverification/lean2agda/blob/main/docs/foundations/gap-catalog.md

## Next direct mathematical cut

Close **one** small, actual-source counterpart *first*:
`test/agda/Identity.agda` should be source-elaborated,
transmitted to Lean, checked, returned by Lean2Agda, checked again
and equipped with a proof-relevant statement/observer relation.
Its metadata must cite the exact **registry IDs** and original
source digest, not just similar spelling. Then move to
`test/agda/JFixedPoint.agda` for dependencies, arithmetic and
numeric computation.

The registry and the paired handwritten reference theories are now
available to structure that experiment. The actual source-bound
cross-compiler `M01–M07` evidence remains **OPEN** until real
translator and kernel checks exist.

---

## 16 November 2026 — declaration-level trace and original-source pilot

The constructive dictionary now connects to actual **emitter metadata** through
`scripts/declaration_quality_trace.py`. This is a deliberately narrow,
read-only observer built on already-existing Agda2Lean artifacts, not a new
source parser or translation engine. It consumes:

1. An exact original Agda source file and a reviewed SHA256-bound case file.
2. The emitted Lean file with existing `-- Agda:`,
   `-- Mapping:`, and `-- Direct dependencies:` comments.
3. The reviewed 51-rule machine registry (validated under the existing
   anti-promotion contract).
4. Optionally, the binary elaborated Agda CBOR, emitter diagnostics, and
   the Lean 4 `Manifest.lean` type/value/axiom TSV to attach additional
   artifact digests and checker-output observations.

The output schema is `a2l-declaration-quality-trace-v1`, with source,
case, registry and Lean output SHA256 digests; exact original and expected
Lean names; **reviewed** construct IDs; observed emitter mapping mode;
observed direct dependencies; optional Lean type/value/axiom manifest
data; foundational conflicts and the union of required M03–M06/M10
obligations. Statuses distinguish `candidate-observation-only`,
`reconstruction-observation-only`,
`incomplete-emitter-annotation`, and
`quarantined-foundational-conflict`.

The binding of a reviewed construct ID to an Agda source declaration is
still a **human-reviewed expectation**. The emitter supplies original
declaration names and direct dependencies from its existing typed Core
pipeline, but the report has not independently reconstructed the
elaborated Agda term or proved that the generated Lean type has the same
meaning. Even a complete Lean manifest remains observation until the
actual native kernel checks and independently verified logical-relation
witnesses are tied to these bytes.

### Source-pinned cases

| Case | Source policy | Declarations | Checked against |
|---|---|---:|---|
| Identity | [identity_mapping_case.json](../fixtures/bidirectional/identity_mapping_case.json) | 2 | `Identity.identity`; `Identity.identity-law` with its essential direct dependency on `identity` |
| JFixedPoint | [jfixedpoint_mapping_case.json](../fixtures/bidirectional/jfixedpoint_mapping_case.json) | 6 | `unit-converges`, `fixed-0/1/2/100`, `all-196884` and the **original** direct dependency pairs in `comparison/receipts/jfixedpoint.project-dependencies.tsv` |

The Identity source is pinned to
`8dba25148b761f439749275fa06d381864ae9945030d0fbc2e0a3ca0d81bcd1c`;
JFixedPoint is pinned to
`f3ee60483de5a2086a75b74f1c9c2636cdee1542a79092d1477b92362c022436`.
These are **file-content** hashes, not Git commit IDs.

For the Identity case, the existing `agda-backend` CI job now runs the
real Agda 2.9 extraction and Lean emitter, then produces:

```sh
python3 scripts/declaration_quality_trace.py \
  --case fixtures/bidirectional/identity_mapping_case.json \
  --source test/agda/Identity.agda \
  --source-ir build/agda-ir/Identity/module.a2l.cbor \
  --emitted build/agda-ir/Identity.generated.lean \
  --diagnostics build/agda-ir/Identity.diagnostics.tsv \
  --out build/agda-ir/Identity.foundation-observation.json
```

The existing `scripts/check-jfixedpoint.sh` already typechecks its Agda
source, regenerates Lean twice, builds under Lean 4.28, checks actual
`contract-all` reduction, audits Lean axiom closure, and compares
source dependencies. The new trace is called **after** those original
checks, using their generated Lean file and manifest; it cannot replace
or dilute them. The JFixedPoint report remains explicitly
`semantic_correspondence_proved=false`: an original-direction
successful check is not yet an Agda → Lean → Agda fixed point.

### Testing and next proof cut

```sh
python3 -m unittest discover -s scripts \
  -p test_declaration_quality_trace.py -v
```

The 14 new local tests passed on synthetic emitted fixtures with
a synthetic 51-row registry stand-in. They check both source
hashes, the reviewed dependency boundary, Unicode Lean quoted names,
conflicts, reconstruction, absent metadata, duplicate declarations,
source mutation, malformed manifest, and fake proof flags. They are
**not** compiler-quality benchmarks. The GitHub Actions gate is
configured against the repository's real reviewed registry and
compiler artifacts but has not yet produced an accepted receipt at this
branch head.

**Next maximum cut:** ingest genuine Agda/Lean checked *types* and
independent kernel/proof objects into this same per-declaration trace.
Build an independently audited `M03` witness for one original theorem
that preserves `Set`-valued evidence, then `M04/M05/M06`, and only
then instantiate the inverse/fixed-point obligations `M01/M02/M07`.
No mapping-table count, source hash or command exit code may pay
those mathematical gates.
