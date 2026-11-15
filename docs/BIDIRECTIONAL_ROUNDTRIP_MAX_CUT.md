# JMD bidirectional proof-world programme — phases, deliverables, exact max-cut

Last audited: **2026-11-09**. Formal source declarations are authoritative.
This is the single round-trip-specific roadmap; retain the prior per-project
owner roadmaps instead of replacing their historical checkpoints.

## Scope and boundaries

Goal: mechanically join Lean/Agda proof worlds, discover gaps without an LLM,
and support **source-faithful, checker-validated** repeated translation on an
explicitly supported fragment. `itir.formal.inspect` and
`itir.formal.route` in ITIR-suite provide candidate-only gap lookup. AO's
agent/fleet/prompt orchestration is **out of scope**. OEIS/Wikidata QIDs are
optional mathematical-discovery hints, never type or proof authority.

**Do not submit unpublished DASHI proof code to third parties.** In particular,
`formalverification/lean2agda` is an inspect-only upstream reference. Its
issue [#61](https://github.com/formalverification/lean2agda/issues/61)
concerns outreach, not completed translation. A generic upstream contribution
requires distinct explicit authorisation.

## Audited existing owners (do not duplicate)

| Owner | Existing capability | Evidence / source |
|---|---|---|
| `chboishabba/agda2lean` | Agda 2.9 elaboration → typed Core IR → canonical CBOR → SQLite → Lean emission, with fail-closed reconstruction | `README.md`, `ROADMAP.md`, `scripts/a2l_project.py`, `lean/Agda2Lean/Manifest.lean` |
| `agda2lean` PR #7 | Feature-indexed conformance, 19 declared test cases, no positively promoted correspondences | `test/conformance/manifest.tsv`, `docs/CONFORMANCE.md`, `docs/SUPPORT_MATRIX.md` |
| `agda2lean` PR #9 | Source SHA, mapping mode and dependencies of each elaborated Agda declaration | `Agda2Lean.Capability`; *capability-only*, no proof implied |
| `formalverification/lean2agda` | Elaborated Lean extraction, axiom/feature atlas and Lean → Agda constructive/classical target profiles | `README.md`, `docs/foundations/gap-catalog.md`, `corpus/SCHEMA.md` |
| `dashi_lean4` PR #105 | 21,481 global Lean repository identities; Lean-local proof-world owner and manifest extraction | `Integration/JMD/CertifiedWorld.lean`, `Integration/JMD/RoundTripFixedPoint.lean`, `scripts/jmd_lean_dependency_receipts.py` |
| `dashi_agda` PR #1477 | Native Agda proof-world transport owner, reverse dependency reopening | `DASHI/Interop/JMDFormalWorldReconciliationExact.agda`, `JMDRoundTripFixedPointExact.agda` |
| `ITIR-suite` | Candidate-only gap discovery/routing, independent referee and governed receipts | `itir-mcp/src/itir_mcp/formal_tools.py`, `scripts/formal_gap_join.py` |

**Version-sensitive:** upstream `lean2agda` foundational probes are
documented at Lean 4.33.1/Agda 2.8.0; our `agda2lean` extractor targets
Agda 2.9; the pinned DASHI Lean toolchain differs. A cross-version syntax
pass is NOT a semantic equivalence receipt.

## Definition of a valid round trip

For an explicitly supported pair of representations `A` and `B`, source
and translated carrier maps must have *actual checked inverse laws*:

```text
a2l : A → B
l2a : B → A
l2a (a2l a) = a
a2l (l2a b) = b
```

For general logic these may be logical relations or certified equivalences
instead of literal inverse functions. Both checkers must independently accept
the required translated declarations. No unexpected axioms/postulates, sorry,
new trust assumptions, dependency drift or computational mismatch may silently
appear.

The inverse-law composition/idempotence theorems are source-written in
`Integration/JMD/RoundTripFixedPoint.lean` and
`DASHI/Interop/JMDRoundTripFixedPointExact.agda`.
They are **conditional algebraic theorems**; they are not evidence that either
compiler satisfies the hypotheses.

## Exact phase and deliverable ledger

| Phase/gate | Decisive deliverable | Existing implementation | Outstanding acceptance |
|---|---|---|---|
| **R0** — capability intersection | Read both original feature corpora without inventing translations or correspondence | `scripts/bidirectional_conformance.py` on this repository's main; PR #7 support matrix | Run against real `lean2agda/corpus/manifest.json`; version/pin alignment |
| **R1** — fail-closed reporter | Literal feature-tag candidates and explicit untrusted round-trip observations | `scripts/bidirectional_conformance.py`; `scripts/test_bidirectional_conformance.py` | Execute complete unit tests; preserve full source identities |
| **R2** — fixed-point mathematics | Conditional inverse laws, idempotence, composition, predicate/observer transport | Lean and Agda modules above | **Both kernel checks**; consumer theorem instantiation |
| **R3** — translator execution | Native A→L→A and L→A→L over an agreed small corpus, with pins | `agda2lean/scripts/a2l_project.py`; lean2agda corpus and translator | Build a sandboxed, bounded executable driver that calls the *real* existing translators; no fabricated outputs |
| **R4** — correspondence | Agda and Lean independently validate semantic type/proof/behaviour, axiom/dependency preservation | `Agda2Lean.Manifest`, source-native conformance/axiom tools | First real paired checker receipts; agreed bridge/translation relation |
| **R5** — generalise | Expand to dependent patterns, recursion, records and data; negative classical/cubical cases | PR #7 features; lean2agda 13-rule gap catalogue | Individual positive reconstruction + negative controls, no blanket support |
| **R6** — automatic reconciliation | ITIR standalone gap finder selects owner/obligation, then checked reuse updates world | `scripts/formal_gap_join.py`, DASHI proof-debt owners | Real end-to-end source update → proof match → target checker → selective reopening |

## Exact remaining mathematical lemmas (the names below are acceptance targets)

| ID | Precise mathematical statement / obligation | Standing |
|---|---|---|
| **M01** | `leanRoundTripInverseOnSelectedCarrier`: for one named pinned Lean declaration and generated Agda carrier, independently checked source and target maps satisfy inverse laws | OPEN: generic conditional theorem exists, real compiler maps not proved |
| **M02** | `agdaRoundTripInverseOnSelectedCarrier`: source Agda carrier and generated Lean counterpart satisfy inverse laws with exact source SHA | OPEN, as M01 |
| **M03** | `selectedStatementCorrespondence`: elaborated source/target propositions are linked by a *checked* interpretation/equivalence, not string hashes | OPEN |
| **M04** | `selectedAxiomClosurePreserved`: accepted target proof depends on no additional unaccounted axiom (respecting classical-profile boundaries) | OPEN |
| **M05** | `selectedDependencyClosureTransport`: every essential original dependency is mapped/paid in the target checked environment | OPEN |
| **M06** | `selectedComputationPreservation`: original and regenerated finite observer/evaluator agree; non-computational theorem cases explicitly N/A | OPEN |
| **M07** | `roundTripCanonicalFixedPoint`: for a selected class of supported declarations, further translation rounds preserve the certified semantic world representation | OPEN: generic inverse/idempotence law source-written |
| **M08** | `candidateCannotPayUnmatchedGoal`: numerical/QID/lexical match is not a proof and cannot discharge a changed statement | Existing formal firewalls; runtime test pending |
| **M09** | `selectiveReopeningPreservesUnaffectedProofs`: actual world changes reopen only dependents while preserving source-bound valid proofs | Existing dependency theorems; end-to-end instantiation OPEN |
| **M10** | `classicalOrCubicalIncompatibilityNotPromoted`: cases requiring incompatible choice/K/cubical principles remain blocked or conditional, never falsely marked translated | Existing source classifiers; automatic paired negative control OPEN |

No claim is made that M01–M10 are the names of existing Agda/Lean source declarations:
they are **target proof debts**. Search the current native owner indices before
introducing any new module or second implementation.

## Focused proof cut / order

1. **Kernel preflight:** compile the two new conditional fixed-point modules.
2. **One real ordinary-core cycle:** a minimal record/function/equality example
   known to both tools, with actual pinned source files. Prefer an *existing*
   corpus case and repair its existing Lean oracle rather than fabricate a case.
3. **Axiom negative control:** `Classical.choice`, quotients or K/UIP must
   remain conditional/rejected under an incompatible Agda profile.
4. **Proof-bearing equality/transport:** obtain M01–M06 for that one cycle;
   use them to discharge M07, not the other way round.
5. **Automated discovery:** make the ITIR gap join identify the case and attach
   the actual checker receipts to the existing world.
6. **Then** scale to Hecke/Monster/VOA/Karp, respecting source equivalence
   and independent author attribution.

## Reproducible current commands

```sh
# From agda2lean with PR #7 conformance manifest present:
python scripts/bidirectional_conformance.py \
  --agda2lean-manifest test/conformance/manifest.tsv \
  --lean2agda-manifest /path/to/lean2agda/corpus/manifest.json \
  --out build/bidirectional-conformance.json

python -m unittest discover -s scripts \
  -p 'test_bidirectional_conformance.py' -v

# From dashi_lean4, pinned environment:
lake env lean Integration/JMD/RoundTripFixedPoint.lean

# From dashi_agda, pinned Agda stdlib / project imports:
agda -i . DASHI/Interop/JMDRoundTripFixedPointExact.agda
```

The scripts/lemmas are source-written and committed. **No live whole-cycle
compiler run, Lean/Agda kernel run or upstream transfer has been performed
from this environment.** The benchmark does not assert any verified cycle
from a JSON or a matching name. This limitation is an exact unpaid gate, not
an architectural obstacle to future automation.


## Cross-project corpus reconciliation and reviewed candidate taxonomy

Independent source audit found the current upstream `lean2agda/corpus/manifest.json`
contains **12 records, all marked `translated`**: **T0=1, T1=7, T2=4**.
These are source-manifest statuses, not evidence that our current Agda 2.9
environment reproduced their original Agda 2.8 checker results or that a
round trip to Lean was completed.

The `agda2lean` PR #7 manifest has **19 classified cases** and
**zero `supported-correspondence`** (11 reconstruction boundaries and
8 deliberately unsupported). This does not mean `lean2agda` is superior:
their 12 entries and our 19 feature fixtures test different directions,
versions and semantic acceptance criteria.

`docs/roundtrip_feature_crosswalk.tsv` therefore records a minimal,
source-reviewed, **candidate-only** taxonomy crosswalk for record/structure
eta, projections, mutual definitions, integers/literals, irrelevance and
Cubical/K-UIP. These coordinates are not equivalence relations.

```sh
python scripts/bidirectional_conformance.py \
  --agda2lean-manifest test/conformance/manifest.tsv \
  --lean2agda-manifest /path/to/lean2agda/corpus/manifest.json \
  --feature-crosswalk docs/roundtrip_feature_crosswalk.tsv \
  --out build/roundtrip-capability-intersection.json
```

The benchmark currently emits **discovery candidates** and
**untrusted-observation-only** round-trip records. A separate local,
authenticated proof referee must inspect live kernel artefacts; arbitrary
JSON receipts are explicitly incapable of setting `stable_verified=true`.

### Highest-alpha remaining exact work after the crosswalk

- **M00a — runtime:** execute `scripts/test_bidirectional_conformance.py`
  and the actual two source manifests; repair any schema/pin regressions.
- **M00b — normalization:** define the first *checked* paired semantic
  expression normal form, preserving universe profiles, binders, proof
  irrelevance and classical axioms; do not hash dissimilar IRs together.
- **M01/M02 — real witnesses:** construct and kernel-check actual inverse
  representation maps over a selected shared base fragment; source-written
  generic inverse laws remain conditional.
- **M03–M06 — correspondence:** both checkers accept a real selected proof
  and its dependencies/axioms/finite observable correspondence.
- **M07 — certified fixed point:** instantiate the generic round-trip
  idempotence theorem with those *actual* witness maps.
- **M08–M10 — gap safety:** integrate ITIR's candidate-only gap output
  without promoting external ontology or incompatible foundational cases.

No mathematical source from DASHI has been contributed upstream.

## Executable local cycle runner — implemented after the initial roadmap

`scripts/run_bidirectional_cycle.py` now executes an explicit ordered plan of
pinned source checkout commands for either direction, with maximum per-step
timeouts, expected-artifact hashing, source revision validation and immediate
failure stops. It never uses a shell, fetches sources, publishes code, promotes
metadata to theoremhood or calls an LLM. `scripts/test_run_bidirectional_cycle.py`
contains local Git fixture controls for correct pinning, dirty inputs,
missing artifacts, bad plan roles and the distinction between successful
commands and certified semantics.

Example format (replace the commands with the **actual** pinned translator,
source-export and checker commands from their respective existing READMEs):

```json
{
  "schema": "jmd-roundtrip-exec-v1",
  "steps": [
    {
      "role": "lean-extract",
      "cwd": "lean-source-checkout",
      "git_sha": "PUT_EXACT_40_HEX_COMMIT_HERE",
      "argv": ["lake", "env", "lean", "--run", "Export.lean"],
      "timeout_seconds": 300,
      "expected_artifacts": ["build/lean-export.ndjson"]
    },
    {
      "role": "lean2agda",
      "cwd": "lean2agda-checkout",
      "git_sha": "PUT_EXACT_40_HEX_COMMIT_HERE",
      "argv": ["make", "corpus-check"],
      "timeout_seconds": 900,
      "expected_artifacts": []
    }
  ]
}
```

This two-step sample is a **format demonstration**, not a round trip; a real
plan must include the *actual* translation and independent checker steps in
both directions, with their output artifacts. The runner is not a semantic
comparator: it records `semantic_fixed_point_proved=false` even if all
commands return success and output hashes repeat. The M01–M07 selected
correspondence proofs and verified normal forms are still unpaid.

```sh
python -m unittest discover -s scripts -p 'test_run_bidirectional_cycle.py' -v
python scripts/run_bidirectional_cycle.py \
  --plan /path/to/locally-reviewed-plan.json \
  --base /path/to/parent-of-pinned-checkouts \
  --out build/local-roundtrip-observation.json
```

**Safety:** executing untrusted translator repositories may execute their
build scripts. Use a locally controlled Nix development sandbox and review the
explicit argv plan. Do not run third-party build code with unpublished DASHI
secrets or credentials.

### Updated tranche result

The machine-executable harness, checked generic inverse-law theorem sources,
corpus metadata audit and candidate feature crosswalk are **implemented in
source**. The uncompleted decisive result remains *one actual selected
translation cycle with both kernel checks, source-faithful type/dependency
correspondence and witness inverse laws*. Until it exists, do not mark a
round trip semantically stable.

---

## 15 November 2026 — strict cycle and logical-relation quality tranche

**Authority:** this is a source-implemented tranche on branch
\`feat/bidi-quality-semantic-maxcut-20261115\`; kernel and pinned CI checks
remain unpaid until executed. Do **not** call a candidate pair, source digest,
successful subprocess, JSON boolean, or finite test a proof of equivalence.

### Quality formalism (the actual acceptance criterion)

We distinguish an explicitly **provided** logical relation
\(\mathcal R_{A,B} : A \to B \to \mathrm{Prop}\) from a translator whose
correctness must be **proved**. A forward witness is

\[
(\mathcal R,F,h_F),\qquad
F:A\to B,\qquad h_F:\forall a,\mathcal R(a,F(a)).
\]

The new \`lean/Agda2Lean/TranslationQuality.lean\` represents this as
\`ForwardWitness\`. It defines and gives constructor-level soundness witnesses
for products (\`ProdRel\`), options (\`OptionRel\`) and lists (\`ListRel\`).
It also defines the function-space relation \`ArrowRel\` and makes observable
computation preservation an explicit \`ObserverWitness\` obligation.
A hand-written Boolean identity witness is a **sanity control only**.

This is deliberately weaker than a global isomorphism: a quotient,
proof-irrelevant encoding or Cubical construction may have a logical
correspondence without literal inverse maps. For the *chosen strict
isomorphism fragment*, the separate native
\`dashi_lean4/Integration/JMD/RoundTripFixedPoint.lean\` owns the
conditional inverse/idempotence mathematics. Neither module asserts that
the actual compilers inhabit its hypotheses.

The public quality outcome remains the independent vector
\((S,D,C,A)\) — statement, dependency closure, computation, and
axiom/trust — plus a provenance/checker status and a directional cycle
status. \`S\` requires interpretation of the *elaborated* propositions.
\`D\` must account for transitive essential dependencies.
\`C\` requires an observer relation or computation proof, not one value.
\`A\` compares the full assumption profiles, including \`sorryAx\`,
choice, quotient, postulates, rewriting and univalence policy.
Averaging these gates into one confidence score is forbidden: failing one
required gate prohibits certification.

### Runner contract — additional strict mode

\`scripts/run_bidirectional_cycle.py\` retains the old two-command mode
as **observation only**, for backward compatibility. A new strict
\`cycle_origin\` selects exactly one of:

\`\`\`text
agda-first:
  agda-check → agda-extract → agda2lean → lean-check →
  lean2agda → agda-check → correspondence

lean-first:
  lean-check → lean-extract → lean2agda → agda-check →
  agda2lean → lean-check → correspondence
\`\`\`

The strict plan must contain \`case_id\`, a \`source\` object with
\`cwd\`, tracked \`path\` and 64-digit byte \`sha256\`; each stage must
name an expected output artifact; every subsequent stage declares
\`consumes: [{"from_step": N, "artifact": "relative/path"}]\` for a
previously produced output. Every command still pins its local checkout
by exact 40-digit Git SHA and explicit argv. The runner now checks:

* each checkout and artifact path stays within its declared root;
* the selected original source file is tracked and matches its SHA256;
* the checkout still matches its Git pin *after* every command;
* earlier artifact bytes remain unchanged at later stages;
* inputs actually refer to a prior stage's declared, hashed output;
* missing outputs, mutable tracked source, non-zero exit and timeout fail.

These are **necessary reproducibility conditions**, not proof that a
command actually used its declared input, or that its output is a
correct Lean/Agda translation. Both \`semantic_fixed_point_proved\` and
\`independent_correspondence_verified\` remain **false** in every runner
result. \`ordered_cycle_complete\` means only that the ordered subprocess
and artifact checks passed.

A single plan executes one direction; **both** source directions and
both native kernel audits are needed for full bidirectional acceptance.

### Anti-forgery and test gates

\`scripts/bidirectional_conformance.py\` now checks that each claimed
receipt uses the expected checker channel (Agda, Lean, or correspondence)
and actual lowercase hexadecimal digests. Importantly, the JSON key
\`authenticated_referee\` is **not an authentication channel**: user
JSON can never set \`externally_authenticated=true\` or
\`stable_verified=true\`. A complete collection of self-reported flags
is only \`reported_all_gates\`, **not** a theorem.

Source-written regression suites:

\`\`\`sh
python -m unittest discover -s scripts \
  -p 'test_run_bidirectional_cycle.py' -v
python -m unittest discover -s scripts \
  -p 'test_bidirectional_conformance.py' -v

# Requires pinned Lean 4.28.0; cannot run without the compiler:
bash scripts/check-translation-quality.sh
\`\`\`

Coverage includes valid seven-stage fixture execution, missing return,
missing artifact, invalid lineage, wrong SHA, untracked source, checkout
escape, after-the-fact artifact rewrite, tracked-source mutation,
wrong checker, forged authentication, malformed digests and no-promotion
negative controls. The fixture uses **fake Python subprocess commands on
purpose** to prove the receipt still refuses semantic certification.

### Exact remaining maximum cut — no premature promotions

| Gate | Tranche result | Still required for authoritative closure |
|---|---|---|
| **R0** | 19 Agda feature cases / 12 Lean corpus examples yield 42 reviewed taxonomy candidate pairs, with 0 literal-feature matches and 0 certified pairs | Align source, translator, Lean and Agda version pins for one identical object |
| **R1** | Strict source-bound observer, anti-forgery checks and regression source written | Execute exact-head Python tests; attach output and mutation receipts |
| **R2/M00b** | Typed \`ForwardWitness\`, \`ArrowRel\`, \`ProdRel\`, \`OptionRel\`, \`ListRel\`, \`ObserverWitness\` source written | Lean 4.28 kernel check; instantiate the relation on actual emitted representations |
| **R3** | Real-command full-cycle plan shape and artifact lineage now available | Execute native A→L→A and L→A→L on pinned same-source examples, not fake fixtures |
| **R4/M01–M06** | Exact admission obligations identified; no real-cycle theorem evidence | Both kernels check; statement equivalence; direct/transitive dependencies; assumptions; computational observers |
| **R5/M07–M10** | Positive structural relation template and fail-closed negative controls | Derive fixed point from real maps; add dependent/recursive cases; enforce classical/Cubical incompatibility |
| **R6** | ITIR candidate-only interface unchanged | Source update → independently checked theorem matching → dependency-scoped reopening |

Suggested **first actual source**: use the already pinned
\`test/agda/Identity.agda\` (identity and \`identity-law\`) for the
minimal core, and separately the existing stronger
\`test/agda/JFixedPoint.agda\` for computation/proof and dependency
stress. They must not be replaced by hand-written lookalikes when
claiming a translator quality result. Lean2Agda's profile-U scaffolds
(\`--type-in-type\`, postulates, rewrite rules) are **discovery evidence
only**, never an accepted safe target.

**Max-cut remains:** execute a real same-object cycle under the pinned
toolchains; then construct source-bound proof relation and independent
axiom/dependency/observer receipts to instantiate M01–M07. Current
source changes **do not close M01–M07 or R3/R4**.
