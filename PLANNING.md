
The primary translator and IR engine should be written in Haskell.

That is the strongest choice because Agda itself is implemented in Haskell, and the critical input is Agda’s elaborated internal syntax, not parsed .agda text. A Haskell backend can access Agda’s checked declarations, inferred implicits, universes, pattern clauses, termination information and dependency graph directly.

The complete system should deliberately use three languages:

Component	Language
Agda extraction, Core IR, mapping engine, Lean source generation, CLI	Haskell
Lean compatibility library, tactics, adapters and generated proofs	Lean 4
Agda-side correspondence and certificate checkers	Agda
Why Haskell for the core
The strongest extraction route is:

Agda.TypeChecking.Monad
Agda.Syntax.Internal
Agda.Syntax.Abstract
Conceptually:

extractDeclaration
  :: AgdaDefinition
  -> TCM CoreDeclaration
This lets us extract the declaration after Agda has resolved:

overloaded names;

implicit and instance arguments;

module parameters;

universe levels;

constructor parameters and indices;

pattern matching;

generated projections;

definitional bodies;

dependencies;

reducibility;

postulates;

termination and coverage information.

Trying to recover those from source text in Rust or Python would mean partially reimplementing the Agda elaborator—which would immediately become the least trustworthy part of the pipeline.

Haskell also naturally represents the IR:

data CoreTerm
  = Var BinderId
  | Sort Universe
  | Pi Binder CoreTerm
  | Sigma Binder CoreTerm
  | Lam Binder CoreTerm
  | App CoreTerm Argument
  | Constructor CanonicalName [Argument]
  | Eliminator EliminatorSpec
  | Equality CoreTerm CoreTerm CoreTerm
  | Axiom CanonicalName
  | Extension ExtensionTerm
and the translation result:

data MappingResult a
  = Exact a
  | Encoded a [Obligation]
  | Reconstruct a [Obligation]
  | Unsupported Diagnostic
That is a much better fit than a loose dictionary-based representation.

Why not write everything in Lean?
Lean 4 would be attractive for implementing the IR and proving things about it, but it has no natural direct access to Agda’s elaborated compiler state.

A Lean-only implementation would need either:

its own Agda parser and elaborator;

Agda to export an intermediate representation first;

a foreign-function bridge into the Haskell Agda compiler.

Once Agda must export its checked representation anyway, Haskell is the natural frontend and coordinator.

Lean should own the parts that genuinely need Lean’s environment:

generated declarations;

macros and elaborators;

Mathlib/PhysLean symbol resolution;

tactics;

native theorem reconstruction;

dependency inspection;

axiom auditing;

final kernel checking.

Why not Rust?
Rust would be a good implementation language for:

a fast external normalizer;

certificate generation;

dependency-graph processing;

incremental build orchestration.

But it is not the best initial core because interfacing with Agda’s Haskell compiler API would dominate the project.

Adding Rust immediately would give us:

Haskell extraction
→ Rust IR
→ Lean generation
without initially providing enough benefit over:

Haskell extraction and IR
→ Lean generation.
A Rust solver can be introduced later behind a language-neutral certificate protocol.

Why not Python?
Python is suitable for prototypes, ledger reporting and repository scripts, but not as the authoritative translator.

The risks would be:

weakly typed transformations;

malformed binder scopes;

accidental universe loss;

nondeterministic serialization details;

harder validation of exhaustive AST handling;

runtime failures where we want compile-time exhaustiveness.

For this project, the translator should refuse to compile when a newly introduced IR constructor is not handled by the Lean emitter. Haskell’s algebraic data types and exhaustive pattern checking give us that property.

Language-neutral interchange
Although the implementation should be Haskell, the persisted IR should not be a Haskell-specific binary dump.

Use a canonical, versioned interchange format such as:

core-ir/
  schema-version
  declarations
  dependency-graph
  source-map
  obligations
  feature-extensions
The authoritative encoding is versioned canonical CBOR. The operational,
queryable store is SQLite in WAL mode. Large typed terms remain a
content-addressed DAG inside immutable module objects, while SQLite indexes
module heads, declarations, direct dependencies, mapping states and receipts.

JSON is not part of the authoritative interchange or inspection path. Human
inspection is provided by stable CLI tables and targeted reports; machine
inspection uses SQL or canonical CBOR.
For reproducibility:

CBOR arrays must have fixed constructor tags and definite lengths;

sets and term tables must be emitted in ascending canonical order;

names must be fully qualified;

binder IDs must be stable;

source formatting must not affect semantic hashes;

declaration and dependency hashes must use canonical encoding.

SQLite database bytes are not semantic identities: page layout, insertion
order and vacuuming are operational details. Semantic hashes are computed over
canonical CBOR before an object is installed in SQLite.

The trusted boundary
The translator itself does not need to be trusted as an oracle.

Its generated results are independently checked:

A
g
d
a
C
h
e
c
k
(
d
A
)
=
s
u
c
c
e
s
s
,
L
e
a
n
C
h
e
c
k
(
d
L
)
=
s
u
c
c
e
s
s
.
AgdaCheck(d 
A
​
 )
LeanCheck(d 
L
​
 )
​
  
=success,
=success.
​
 
The Haskell translator can make mistakes, but those mistakes should produce one of:

rejected Agda;

rejected Lean;

failed statement correspondence;

changed dependency fingerprint;

unresolved translation obligation.

For portable computations, both systems check the same certificate independently.

Recommended repository layout
dashi-port/
  dashi-core-ir/          # Haskell IR types
  agda-extractor/         # Haskell Agda backend
  lean-emitter/           # Haskell Lean facade generator
  dashi-port-cli/         # Haskell orchestration
  schema/                 # Canonical IR specification

DASHILean/
  DASHI/
    Compat/               # Lean compatibility surfaces
    Automation/           # Lean tactics/checkers
    Native/               # Mathlib/PhysLean implementations

DASHI/
  Interop/
    CoreIR/               # Agda-side correspondence
    Certificate/          # Agda certificate checkers
Practical recommendation
Start with:

GHC/Haskell;

Agda pinned to the exact repository version;

one Haskell package containing the IR;

one Agda backend producing canonical CBOR and SQLite catalog entries;

one Haskell Lean emitter;

a small Lean compatibility package.

Do not introduce Rust, Dedukti or Lambdapi into the critical path initially. They can later become:

Rust: fast untrusted certificate producer;

Dedukti: independent semantic audit;

Lambdapi: experimental interoperability backend.

So the direct answer is:

Write the translation engine in Haskell, the Lean realization in Lean 4, and the Agda checker surfaces in Agda.
Write the translation engine in Haskell, the Lean realization in Lean 4, and the Agda checker surfaces in Agda.
​
 
If we must name one principal implementation language, it is Haskell because the hardest and most information-sensitive operation is extracting Agda’s fully elaborated meaning.


Let's consider the architecture in detail, plot in mermaid, then list deliverables

Worked for 1m 2s
The strongest architecture is a proof-producing, typed IR pipeline with native implementations on both sides. The IR coordinates meaning and dependencies; it is not itself trusted. Agda and Lean independently kernel-check the resulting declarations.

Architecture
flowchart TD
    subgraph Source["Source and extraction"]
        AS["Agda source"]
        AE["Agda elaborator"]
        EX["Haskell extractor"]
        AS --> AE --> EX
    end

    subgraph Core["DASHI Core IR"]
        IR["Typed declaration IR"]
        MR["Mapping registry"]
        FP["Feature classifier"]
        EX --> IR
        IR --> FP
        MR --> FP
    end

    subgraph Lowering["Translation planning"]
        EQ["Portable lowering"]
        OB["Lean obligations"]
        QX["Quarantined extensions"]
        FP -->|Exact or encoded| EQ
        FP -->|Reconstruct| OB
        FP -->|Cubical or unsupported| QX
    end

    subgraph LeanSide["Lean realization"]
        LF["Generated Agda-shaped facade"]
        LN["Native Lean implementation"]
        LA["Mathlib and PhysLean adapters"]
        LI["Lean manifest extractor"]
        EQ --> LF
        OB --> LN
        LA --> LN
        LN --> LF
        LF --> LI
    end

    subgraph Certificates["Portable automation"]
        CS["Untrusted solver"]
        CP["Portable certificate"]
        AC["Agda checker"]
        LC["Lean checker"]
        CS --> CP
        CP --> AC
        CP --> LC
    end

    subgraph Verification["Correspondence and promotion"]
        CE["Correspondence engine"]
        DL["Dependency and axiom ledger"]
        RC["Translation receipt"]
        CI["Fail-closed CI gate"]
        IR --> CE
        LI --> CE
        AC --> CE
        LC --> CE
        QX --> DL
        CE --> DL --> RC --> CI
    end
The central invariant is:

same statement
+
same dependency boundary
+
appropriate computational correspondence
same statement+same dependency boundary+appropriate computational correspondence
​
 
The Agda and Lean proof terms may differ completely.

1. Source-of-truth model
Initially:

Agda source
⟶
canonical IR
⟶
Lean facade and obligations
.
Agda source⟶canonical IR⟶Lean facade and obligations.
Agda remains the source of existing declarations. The IR is the canonical translation record, but we do not manually write proofs in it.

Lean consists of two layers:

Agda-shaped public facade

Preserves paths, names, parameter order, record fields and theorem structure.

Native Lean implementation

Uses Mathlib, PhysLean and idiomatic Lean proofs.

For example:

-- Generated/mirrored public surface
theorem boundaryGaugeFixedHodgePoincare
    (index : Index)
    (h : Tangent index)
    (hr : regime index = .boundary)
    (hg : GaugeFixedTangent index h) :
    cBoundary * normSq index h ≤ referenceEnergy index h :=
  Native.Hodge.boundaryCoercivity index h hr hg
The facade resembles Agda; the implementation need not.

2. DASHI Core IR
The IR should represent elaborated declarations rather than source syntax.

Declaration information
CoreDeclaration
  schemaVersion
  canonicalName
  declarationRole
  universeParameters
  moduleParameters
  localBinders
  type
  body or equations
  constructors or fields
  terminationInformation
  reducibility
  directDependencies
  sourceLocation
  featureRequirements
Term language
The portable core needs:

variables and constants;

universes;

dependent functions 
Π
Π;

dependent pairs 
Σ
Σ;

lambdas and applications;

inductive types and constructors;

records and projections;

eliminators;

ordinary equality;

structural and well-founded recursion;

explicit axioms and postulates;

opacity and reducibility.

Declaration roles
Every declaration must be classified as:

computational-data
computational-function
computational-witness
logical-proposition
theorem
axiom
certificate
adapter
This prevents an Agda proof-relevant Set from being incorrectly emitted into Lean’s proof-irrelevant Prop.

3. Mapping registry
Mappings should be data, not scattered emitter special cases.

A mapping entry records:

source construction
target construction
mapping mode
required adapter
semantic correspondence
dependency effect
computational effect
The four principal modes are:

E
x
a
c
t
∣
E
n
c
o
d
e
d
∣
R
e
c
o
n
s
t
r
u
c
t
∣
U
n
s
u
p
p
o
r
t
e
d
.
Exact∣Encoded∣Reconstruct∣Unsupported.
Examples:

Source	Target	Mode
Ordinary Agda record	Lean structure	Exact
Parameterized module	Namespace plus context	Encoded
Proof-relevant Set witness	Lean structure/subtype in Type	Exact
Algebra theorem	Native Mathlib theorem	Reconstruct
Ordinary path fragment	Lean Eq	Encoded
Cubical univalence	Model or explicit axiom	Quarantined
Arbitrary rewrite rule	simp theorem or reconstruction	Reconstruct
Unsupported kernel behaviour	No emission	Unsupported
4. Extension handling
The portable IR should not pretend to contain all Cubical Agda.

Use explicit extension nodes:

Core.Extension.Cubical
Core.Extension.Rewrite
Core.Extension.Coinductive
Core.Extension.UnsafeUniverse
Cubical lowering then returns one of:

ordinary-equality
explicit-quotient
native-reconstruction
semantic-model
axiom-quarantine
unsupported
The authoritative preference order is:

native reconstruction
>
ordinary equality lowering
>
proved semantic model
>
explicit axiom
>
unsupported
.
native reconstruction>ordinary equality lowering>proved semantic model>explicit axiom>unsupported.
Axiom-based Cubical compatibility may assist porting, but its dependencies must remain visibly quarantined from Clay-facing promotion routes.

5. Lean facade generation
The emitter should preserve:

relative module paths;

declaration names;

constructors and fields;

argument order;

declaration order;

documentation;

source locations;

mapping status.

Suggested layout:

DASHI/Algebra/Trit.agda
DASHILean/DASHI/Algebra/Trit.lean

DASHI/Physics/NSPeriodicWallIHarmonicCompletion.agda
DASHILean/DASHI/Physics/NSPeriodicWallIHarmonicCompletion.lean
Generated comments can identify correspondence without making the code unreadable:

/--
Source: DASHI.Physics.NSPeriodicWallIHarmonicCompletion
Statement: exact
Proof: native reconstruction
Dependencies: closed
-/
Generated facades should be deterministic and disposable. Handwritten Lean proofs belong under Native/, where regeneration cannot overwrite them.

6. Native Lean layer
Suggested structure:

DASHILean/
  DASHI/
    Compat/
      Equality.lean
      Dependent.lean
      ModuleContext.lean
      CubicalPathFragment.lean
      CubicalAxioms.lean

    Automation/
      Algebra.lean
      FiniteFold.lean
      Certificate.lean
      DependencyAudit.lean

    Native/
      Foundations/
      Algebra/
      Analysis/
      NavierStokes/
      YangMills/

    Facade/
      Foundations/
      Algebra/
      Analysis/
      NavierStokes/
      YangMills/
Compat/CubicalAxioms.lean should never be imported indirectly. Any import must appear in the dependency ledger.

7. Portable certificate system
Solvers should be untrusted certificate producers.

The first certificate families should cover:

associativity and commutativity;

semiring/ring normalization;

rational arithmetic;

finite sums and products;

literal list folds;

finite enumerator cardinality;

shell-index arithmetic;

scalar inequalities.

For input 
e
e, the solver returns a certificate 
C
C:

s
o
l
v
e
(
e
)
=
C
.
solve(e)=C.
Agda and Lean independently check it:

c
h
e
c
k
A
(
e
,
C
)
=
t
r
u
e
,
c
h
e
c
k
L
(
e
,
C
)
=
t
r
u
e
.
check 
A
​
 (e,C)=true,check 
L
​
 (e,C)=true.
This allows one solver implementation while preserving both kernels as the trust boundary.

8. Lean manifest extraction
After Lean compiles the generated facade and native implementation, a Lean program should inspect the environment and export:

fully elaborated target types;

universe parameters;

implicit and instance binders;

constants actually referenced;

axioms consumed;

reducibility;

declaration kind;

presence of sorryAx.

The correspondence engine compares this output against the source IR. We therefore validate what Lean accepted, not merely what the Haskell emitter intended to generate.

9. Correspondence levels
Every declaration receives:

Status
⁡
(
d
)
=
(
S
,
D
,
C
,
A
)
.
Status(d)=(S,D,C,A).
Where:

S
S: statement correspondence;

D
D: dependency correspondence;

C
C: computation correspondence;

A
A: axiom status.

Possible values include:

exact
bridged
extensionally-proved
certificate-checked
reconstructed
quarantined
unresolved
unsupported
Example theorem:

statement:    exact
dependencies: exact
computation:  not-required
axioms:       none
Example executable enumerator:

statement:    exact
dependencies: exact
computation:  extensionally-proved
certificate: checked-by-both
axioms:       none
Example Cubical staging port:

statement:    bridged
dependencies: cubical-extension
computation:  unavailable
axioms:       univalence
promotion:    prohibited
10. CI promotion gate
A declaration becomes dependency-closed only if:

A
g
d
a
C
h
e
c
k
e
d
(
d
A
)
,
L
e
a
n
C
h
e
c
k
e
d
(
d
L
)
,
S
t
a
t
e
m
e
n
t
A
l
i
g
n
e
d
(
d
A
,
d
L
)
,
D
e
p
e
n
d
e
n
c
i
e
s
R
e
s
o
l
v
e
d
(
d
A
,
d
L
)
,
¬
U
n
e
x
p
e
c
t
e
d
A
x
i
o
m
(
d
L
)
,
¬
S
o
r
r
y
(
d
L
)
,
R
e
q
u
i
r
e
d
C
o
m
p
u
t
a
t
i
o
n
A
l
i
g
n
e
d
(
d
A
,
d
L
)
.
​
  
AgdaChecked(d 
A
​
 ),
LeanChecked(d 
L
​
 ),
StatementAligned(d 
A
​
 ,d 
L
​
 ),
DependenciesResolved(d 
A
​
 ,d 
L
​
 ),
¬UnexpectedAxiom(d 
L
​
 ),
¬Sorry(d 
L
​
 ),
RequiredComputationAligned(d 
A
​
 ,d 
L
​
 ).
​
 
The generated receipt should be machine-readable and human-readable.

Deliverables
Phase 0 — Architecture and specification
Architecture decision record

Haskell as primary translation implementation.

Lean 4 and Agda as native verification layers.

Explicit trust model.

DASHI Core IR specification

Binder and scope model.

Universe representation.

Declaration roles.

Equality and recursion representation.

Dependency semantics.

Extension mechanism.

Canonical serialization specification

Versioned canonical CBOR with a SQLite/WAL operational catalog.

Stable qualified names and binder IDs.

Semantic hashes.

Deterministic key and declaration ordering.

Mapping policy

Exact/encoded/reconstruct/unsupported definitions.

Statement, dependency and computation acceptance rules.

Cubical quarantine policy.

Phase 1 — Minimal working vertical slice
dashi-core-ir Haskell package

Typed AST.

Scope validation.

Dependency graph.

Canonical encoder/decoder.

Semantic hashing.

Pinned Agda extractor

Agda backend using elaborated internal syntax.

Extract declarations by module or qualified name.

Capture module parameters, implicits, definitions and postulates.

Feature classifier

Ordinary portable core.

Cubical use.

rewrite pragmas;

coinduction/copatterns;

unsafe universes;

termination-sensitive definitions.

Initial Lean facade emitter

Data/inductive declarations.

Records/structures.

functions;

theorem signatures;

namespace and module lowering;

source correspondence comments.

Twenty-declaration pilot

finite carrier;

indexed datatype;

record;

proof-relevant witness;

ordinary equality theorem;

structural recursion;

finite fold;

algebraic assembly theorem;

parameterized module;

explicit analytic assumption package.

Phase 2 — Lean native integration
DASHI.Compat Lean library

dependent-pair and transport helpers;

context/module adapters;

record extensionality;

ordinary path compatibility;

explicit Cubical quarantine module.

DASHI.Automation Lean library

Agda-facing wrapper tactics;

algebraic normalization;

finite fold simplification;

dependency audit commands.

Mathlib alignment registry

source DASHI symbol;

target Mathlib symbol;

adapter theorem;

variance and convention notes.

PhysLean alignment registry

Fourier carriers;

norms and inner products;

finite sums/integrals;

PDE and physics structures where available.

Native implementation modules

handwritten Lean proofs;

no generated proof bodies;

facades delegate to native theorems.

Phase 3 — Verification
Lean environment manifest exporter

elaborated declarations;

actual constants consumed;

universes and binders;

axiom usage;

sorryAx detection.

Correspondence engine

source/target statement comparison;

symbol alignment;

dependency-closure comparison;

computation obligation generation.

Translation receipt format

per-declaration status tuple;

source and target hashes;

dependency mapping;

unresolved obligations;

promotion status.

Logical-relation generator

primitive carriers;

products and records;

functions;

propositions;

finite containers;

executable definitions.

Phase 4 — Portable solvers
Certificate schema

expression grammar;

normalization steps;

source expression hash;

result normal form;

checker version.

Initial certificate producer

associativity;

commutativity;

rational arithmetic;

semiring/ring expressions.

Agda certificate checker

Lean certificate checker

Checker correctness theorems

accepted certificate implies represented equality;

malformed certificates fail closed.

DASHI finite-certificate expansion

literal folds;

enumerator lengths;

shell arithmetic;

scalar bounds;

boundary matrices.

Phase 5 — Cubical and exceptional features
Actual Cubical usage audit

declaration-level dependency graph;

distinguish superficial import from consumed primitive;

identify ordinary equality-lowerable cases.

Ordinary path lowering

Path fragment to Lean Eq;

transport/congruence/extensionality adapters;

correspondence proofs.

Cubical semantic decision

select per declaration:

eliminate;

reconstruct;

model;

axiomatize;

reject.

Quarantined Cubical package

explicit imports;

explicit axiom ledger;

hard prohibition from promoted theorem routes.

Optional semantic model prototype

only if genuinely required by important DASHI declarations.

Phase 6 — Production and CI
dashi-port CLI

dashi-port extract
dashi-port classify
dashi-port emit-lean
dashi-port compare
dashi-port certify
dashi-port audit
dashi-port report
Deterministic regeneration check

regenerated IR and facades must match committed output.

Agda validation job

Lean validation job

Cross-language correspondence job

Axiom and sorry audit job

Dependency-drift job

detect newly introduced assumptions or library dependencies.

Certificate replay job

replay every committed certificate in both systems.

Human-readable port dashboard

exact;

reconstructed;

dependency-closed;

computationally aligned;

quarantined;

unresolved.

First release criterion
The first meaningful release should not claim arbitrary Agda→Lean translation. It should demonstrate one closed vertical tranche satisfying:

20
+
 representative declarations
,
matching Agda and Lean public surfaces
,
no Lean sorry
,
no unexpected axioms
,
exact dependency receipts
,
proved or certificate-checked computation where required
,
deterministic regeneration
.
​
  
20+ representative declarations,
matching Agda and Lean public surfaces,
no Lean sorry,
no unexpected axioms,
exact dependency receipts,
proved or certificate-checked computation where required,
deterministic regeneration.
​
 
​
 
That tranche would validate the architecture before expanding into the large NS/YM theorem graphs or committing to a full Cubical model.


Which parts make the most sense to parallelise? Which areas are most likely to see performance degradation especially on larger proofs (dashi is approaching 10k agdas)? Which are likely to cause memory/elaboration/HDD explosion? How will we and in particular haskell address this?

The right parallelisation boundary is the module/declaration dependency DAG, not the internals of Agda elaboration. The biggest risks are repeated transitive-interface loading, uncontrolled normalization, duplicated generated terms, and too many heavyweight Agda/Lean processes competing for memory.

Haskell helps by acting as a strict, streaming scheduler and IR transformer—but it cannot make Agda’s elaborator intrinsically cheap.

Parallelisation model
First construct the import/declaration graph:

G
=
(
V
,
E
)
,
G=(V,E),
where 
u
→
v
u→v means 
v
v depends on 
u
u. At any moment, every node whose predecessors are complete forms the runnable frontier:

F
t
=
{
v
∈
V
∣
pred
⁡
(
v
)
⊆
C
t
}
.
F 
t
​
 ={v∈V∣pred(v)⊆C 
t
​
 }.
Only that frontier should be parallelised.

Stage	Parallelism	Recommended unit
Repository discovery	Low	One graph-building process
Agda typechecking	Bounded	Module or cohesive module shard
Agda extraction	Bounded	Same worker as typechecking
IR validation	High	Module
Feature classification	High	Declaration or module
Mapping lookup	High	Declaration batch
Lean facade emission	High	Module
Native Lean compilation	Bounded	Let Lake schedule modules
Certificate production	High	Goal batch
Agda certificate replay	Bounded	Module
Lean certificate replay	Bounded	Module
Statement comparison	High	Declaration
Dependency comparison	High	Module/declaration
Receipt aggregation	Low	One final reducer
CI reporting	Low	One final reducer
Good candidates for aggressive parallelisation
These are mostly pure transformations:

canonical hashing;

feature classification;

source-map generation;

mapping-registry lookup;

Lean text emission;

certificate generation;

comparison of already-elaborated declarations;

receipt generation;

compression;

formatting;

independent package builds.

Poor candidates for aggressive parallelisation
These processes have large working sets or shared compiler state:

Agda elaboration;

Lean elaboration;

loading Mathlib/PhysLean environments;

whole-program dependency closure;

global name resolution;

global receipt aggregation;

full normalization;

Cubical reduction;

generating logical relations across a large mutually dependent package.

Agda should not be invoked concurrently inside one shared TCM state. Use isolated worker processes or sequential long-lived shard workers.

Recommended scheduling
The scheduler should prioritise large modules early—approximately longest-processing-time-first—so one giant module does not become the final serial tail.

Conceptually:

1. Discover dependency graph
2. Load historical resource estimates
3. Find ready frontier
4. Rank ready modules by expected cost
5. Dispatch through bounded pools
6. Persist results immediately
7. Release worker memory
8. Advance frontier
Use distinct pools:

Agda pool:        memory-heavy, low concurrency
Lean pool:        memory-heavy, low concurrency
Transform pool:   CPU-light, higher concurrency
Certificate pool: CPU-heavy but relatively memory-light
Agda and Lean heavy pools should generally not run at their maximum concurrency simultaneously.

Main degradation risks
1. Repeated transitive interface loading
If 1,000 modules import the same foundational spine and each extractor starts a fresh Agda process, each process may reload much of that spine.

This causes:

repeated disk reads;

duplicate in-memory interface graphs;

repeated decoding;

GC pressure;

large startup costs.

Mitigation:

respect .agdai caches;

assign cohesive module subgraphs to long-lived workers;

process several modules sequentially in each worker;

precompile shared foundation packages;

avoid one process per declaration;

fingerprint dependency interfaces;

skip unchanged modules.

The best unit is normally a module shard, not a declaration.

2. Giant umbrella modules
A module such as DASHI.Everything forces Agda to expose an enormous transitive environment at once.

Umbrella modules are useful for final integration checks, but disastrous as the normal extraction route.

Use them only for:

final regression;

release checks;

whole-repository dependency validation.

Routine extraction should start from the changed modules and their affected reverse dependency closure.

3. Definitional normalization
Normalization can become the largest CPU and memory consumer.

Dangerous cases include:

deeply nested recursive definitions;

large literal lists;

expanded finite sums;

dependent pattern matching;

record projection chains;

Cubical composition;

rewrite rules;

reducible analytic structures;

transparent theorem bodies;

equality checking that repeatedly unfolds the same definitions.

Do not normalize every IR term globally.

Use three normalization levels:

none
weak-head
canonical-for-comparison
Only computational correspondence should request the third level.

For theorem statements, alpha-normalization and stable constant resolution are often sufficient. Full body normalization is usually unnecessary.

4. Parameterized-module expansion
Agda module parameters become parameters of every contained declaration. A large module context can therefore be repeated hundreds or thousands of times in the extracted representation and generated Lean.

Mitigation:

represent module telescopes once in the IR;

let declarations reference a telescope ID;

emit Lean section variables or a context structure;

avoid copying the full binder tree into every serialized declaration;

hash-cons common parameter lists.

5. Dependent pattern matching
Agda elaborates dependent pattern matching into lower-level eliminators and generated auxiliaries. Naively emitting the complete elaborated term can create very large Lean code.

Prefer storing both:

source equation view
elaborated semantic view
Use the source-equation view for recognisable Lean generation. Use the elaborated view for validation and difficult cases.

Do not blindly print Agda’s fully elaborated eliminator term.

6. Logical-relation expansion
A generated relation for every nested type can duplicate large structures.

For example, naively expanding:

R
A
→
B
R 
A→B
​
 
at every use can repeatedly embed the relations for 
A
A and 
B
B.

Mitigation:

generate one named relation per canonical type;

reference relations by name/hash;

memoize relation generation;

share record-field relations;

generate correspondence obligations only for public or computational declarations;

do not generate them for every private helper immediately.

7. Transitive dependency receipts
Materializing the complete transitive dependency list for every declaration can approach quadratic storage:

O
(
∣
V
∣
⋅
∣
E
∣
)
O(∣V∣⋅∣E∣)
in a densely shared graph.

Store only:

direct dependencies;

a Merkle dependency hash;

optional compact closure summaries.

Compute full transitive closures on demand or use compressed bitsets at aggregation time. Do not serialize the same 5,000-declaration closure into thousands of receipts.

8. Lean typeclass and simplifier search
Lean performance may degrade through:

extremely broad imports;

large global simp sets;

overlapping typeclass instances;

recursive instance search;

reducible compatibility wrappers;

generated terms with every implicit made explicit;

giant monolithic facade files;

unrestricted aesop;

global increases to heartbeats or recursion depth.

Mitigation:

narrow imports;

scoped instances;

simp only in generated reconstruction;

explicit high-value arguments where inference is expensive;

one facade per Agda module;

opaque/theorem boundaries around expensive proofs;

local resource-option changes only;

avoid importing all of Mathlib from every generated file.

9. Raw proof-term generation
Term-by-term translation can cause exponential-looking source expansion when shared subterms become copied syntax.

The IR must be a DAG, not a tree:

T
e
r
m
I
d
↦
C
o
r
e
T
e
r
m
.
TermId↦CoreTerm.
Repeated subterms should be named or content-addressed. Lean source should call shared lemmas rather than inline large proof terms.

Memory explosion risks
The most likely memory failures are:

several Agda processes each holding the same transitive environment;

several Lean processes each holding Mathlib/PhysLean;

Haskell retaining Agda TCState through lazy references;

a monolithic in-memory IR;

decoding all declaration bodies into one global graph;

constructing a complete JSON Value before serialization;

unbounded memoization;

excessive parallelism causing GC contention;

keeping source AST, elaborated AST, IR and generated text simultaneously.

How Haskell should control memory
Strict IR
Use strict fields for the compact IR:

{-# LANGUAGE StrictData #-}

data CoreDeclaration = CoreDeclaration
  { declarationName :: !CanonicalName
  , declarationType :: !TermId
  , declarationBody :: !(Maybe TermId)
  , directDeps      :: !(Vector DeclarationId)
  , features        :: !FeatureSet
  }
This avoids large chains of unevaluated thunks.

Extract, force, write, release
Per module:

load Agda interface
extract compact IR
force compact IR
serialize module shard
discard Agda compiler objects
advance to next module
The extractor must not retain pointers into Agda’s full compiler state.

Use deepseq at the boundary before serialization so delayed work cannot retain the original TCState.

Streaming serialization
Avoid building one enormous in-memory serialization value.

Persist:

manifest metadata
module-level declaration index
content-addressed term chunks
direct dependency edges
Use streaming CBOR encoders or builders. Human-facing manifests are rendered
as CLI tables and reports from SQLite queries; large term bodies remain
content-addressed canonical CBOR objects.

Hash-consing
Repeated:

names;

universe expressions;

module telescopes;

types;

subterms;

dependency vectors

should be interned.

Conceptually:

TermHash → TermId
NameHash → NameId
TelescopeHash → TelescopeId
This dramatically reduces repetition in DASHI’s theorem-package architecture.

Bounded caches
Never use an indefinitely growing global memo table.

Caches should have:

explicit size limits;

module/shard lifetime;

LRU eviction where appropriate;

telemetry for hits, misses and retained bytes.

Process isolation
Agda workers should normally be separate OS processes. If one accumulates fragmented memory or compiler caches, it can exit after a bounded amount of work.

For example:

restart worker after:
  100 modules, or
  4 GB peak RSS, or
  30 minutes
The exact thresholds should be derived empirically.

GHC runtime strategy
Do not equate all available cores with useful Haskell parallelism.

If running two Agda worker processes, each should generally begin with one runtime capability:

+RTS -N1
The outer scheduler supplies parallelism. Giving every worker -N8 would oversubscribe the machine and intensify GC contention.

The coordinator can use async with a bounded pool, but it should launch isolated workers rather than execute several Agda TCM computations concurrently inside one process.

Instrumentation should include:

+RTS -s
and periodic heap profiling during development:

-hy
-hc
-hd
Track:

allocated bytes;

maximum residency;

total memory in use;

GC time;

productivity;

module-level peak RSS.

Haskell’s main danger here is not raw speed—it is accidental retention caused by laziness.

Disk and inode explosion
At 10,000 modules, tiny-file proliferation may become as significant as total bytes.

Potential duplicated layers include:

.agda;

.agdai;

IR manifests;

IR body shards;

generated .lean;

.olean;

certificates;

source maps;

per-declaration receipts;

logs;

traces;

CI artifacts;

Nix store copies;

multiple branches/worktrees.

Storage policy
Persist per module, not per declaration:

ir/modules/<module-hash>.cbor.zst
manifests/<module>.json
receipts/<module>.json
Avoid creating separate files for every term, dependency, certificate step and source-map node.

Use:

compressed body blobs;

compact direct-dependency lists;

one module receipt containing declaration entries;

content-addressed deduplication;

bounded build caches;

garbage collection based on reachable manifest roots;

no committed .agdai or .olean;

no permanent verbose compiler traces;

no duplicated pretty-printed IR unless requested.

Source-map policy
A source map for every internal AST node could be enormous.

Default to:

declaration-level source spans;

equation-level spans;

binder spans only when needed for diagnostics.

Generate node-level maps only in debug mode.

Incremental rebuild strategy
Each module receives a build key:

K
(
M
)
=
H
(
source
∥
extractor version
∥
schema version
∥
mapping registry
∥
direct dependency interface hashes
)
.
K(M)=H(source∥extractor version∥schema version∥mapping registry∥direct dependency interface hashes).
If 
K
(
M
)
K(M) is unchanged, reuse:

extracted IR;

classification;

generated facade;

source manifest;

comparison results where the Lean side is also unchanged.

A source change should rebuild:

the changed module;

its reverse dependency closure;

affected Lean facades;

affected correspondence receipts.

It should not regenerate the entire repository.

Suggested concurrency for the current machine
For an i7-7700K with 32 GB RAM, an initial conservative configuration would be:

Pool	Initial concurrency
Agda compilation/extraction	2
Lean compilation	2
Pure IR transforms	4
Certificate production	4
Receipt comparison	4
Final aggregation	1
Do not run two Agda and two Lean heavy workers simultaneously until measurements show sufficient headroom.

A dynamic scheduler should calculate:

J
=
min
⁡
(
J
C
P
U
,
⌊
M
a
v
a
i
l
a
b
l
e
−
M
r
e
s
e
r
v
e
M
p
95
−
w
o
r
k
e
r
⌋
)
.
J=min(J 
CPU
​
 ,⌊ 
M 
p95−worker
​
 
M 
available
​
 −M 
reserve
​
 
​
 ⌋).
Use measured p95 peak RSS by task class, not a fixed global -j.

Performance observability deliverables
The pipeline needs first-class performance receipts from the beginning:

module elaboration time;

interface load time;

extraction time;

peak RSS;

Haskell allocation and residency;

source size;

.agdai size;

IR compressed/uncompressed size;

generated Lean size;

Lean elaboration time;

.olean size;

direct and transitive dependency counts;

normalization requests;

mapping mode counts;

certificate size and replay time;

cache hit/miss status.

Generate ranked reports for:

slowest modules
largest peak RSS
largest interfaces
largest generated expansion
widest dependency fan-out
largest olean files
worst cache invalidators
Specific performance deliverables
Dependency-DAG scheduler with bounded task pools.

Historical cost database for longest-task-first scheduling.

Strict, hash-consed IR representation.

Per-module compressed IR shards.

Incremental Merkle build keys.

Long-lived but recyclable Agda worker processes.

Lean build integration using module-level Lake scheduling.

Resource-aware concurrency controller.

Per-stage RSS/time/disk telemetry.

Expansion-ratio guard for generated Lean.

Dependency-closure compression.

Cache reachability and garbage collector.

Heavy-module regression suite.

Synthetic large-proof benchmark.

Real DASHI pilot benchmark across representative foundational, Cubical, algebraic and analytic modules.

CI performance regression thresholds.

The central performance principle should be:

load once per shard
→
extract compactly
→
persist immediately
→
release memory
load once per shard→extract compactly→persist immediately→release memory
​
 
At DASHI’s scale, the main enemy will not be the semantic mapping table. It will be accidental whole-repository residency and repeated elaboration of shared dependencies.
