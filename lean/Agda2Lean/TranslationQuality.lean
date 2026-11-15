import Lean

/-!
# Semantic quality relations for the explicitly supported translation fragment

This is a *logical relation* over source and target representations; a name
match, a digest match, or successful parsing does not construct a witness.
The structural lemmas explain how the same correspondence obligation scales
from atoms to products, options and lists. They do not assume either compiler
produces the required relation, and do not discharge any real-source M01–M07
gate until the generated declarations instantiate these witnesses.

The inverse-law/fixed-point owner is
\`dashi_lean4/Integration/JMD/RoundTripFixedPoint.lean\`.
-/

namespace Agda2Lean.TranslationQuality

universe u v w x

/-- A semantic relation and a proof that a particular forward map respects it.
    This is weaker than isomorphism: proof-irrelevant or quotient encodings
    may admit only a logical relation, not literal inverse functions. -/
structure ForwardWitness (A : Type u) (B : Type v) where
  relation : A → B → Prop
  translate : A → B
  preserved : ∀ a : A, relation a (translate a)

/-- A concrete witness, not declaration-name equality, supplies the
    proposition needed by a semantic correspondence check. -/
theorem translation_related (r : ForwardWitness A B) (a : A) :
    r.relation a (r.translate a) :=
  r.preserved a

/-- Pointwise relational interpretation of dependent-free functions. -/
def ArrowRel {A : Type u} {B : Type v} {C : Type w} {D : Type x}
    (RA : A → B → Prop) (RB : C → D → Prop)
    (f : A → C) (g : B → D) : Prop :=
  ∀ a b, RA a b → RB (f a) (g b)

/-- An observer-equivalence obligation is explicit and cannot be inferred
    from the existence of a translator or from typechecking alone. -/
structure ObserverWitness {A : Type u} {B : Type v} {C : Type w}
    (r : ForwardWitness A B) (sourceObserve : A → C)
    (targetObserve : B → C) : Prop where
  preserves : ∀ a, sourceObserve a = targetObserve (r.translate a)

theorem observer_preservation {A : Type u} {B : Type v} {C : Type w}
    (r : ForwardWitness A B) (sourceObserve : A → C)
    (targetObserve : B → C)
    (h : ObserverWitness r sourceObserve targetObserve) (a : A) :
    sourceObserve a = targetObserve (r.translate a) :=
  h.preserves a

/-- The logical relation for a pair is the conjunction of field relations. -/
def ProdRel {A : Type u} {B : Type v} {C : Type w} {D : Type x}
    (RA : A → B → Prop) (RB : C → D → Prop)
    (p : A × C) (q : B × D) : Prop :=
  RA p.1 q.1 ∧ RB p.2 q.2

def product {A : Type u} {B : Type v} {C : Type w} {D : Type x}
    (r : ForwardWitness A B) (s : ForwardWitness C D) :
    ForwardWitness (A × C) (B × D) where
  relation := ProdRel r.relation s.relation
  translate := fun p => (r.translate p.1, s.translate p.2)
  preserved := by
    intro p
    exact ⟨r.preserved p.1, s.preserved p.2⟩

/-- The option relation preserves constructor choice and relates payloads. -/
inductive OptionRel {A : Type u} {B : Type v}
    (R : A → B → Prop) : Option A → Option B → Prop where
  | none : OptionRel R none none
  | some {a : A} {b : B} : R a b →
      OptionRel R (some a) (some b)

def option {A : Type u} {B : Type v}
    (r : ForwardWitness A B) : ForwardWitness (Option A) (Option B) where
  relation := OptionRel r.relation
  translate := Option.map r.translate
  preserved := by
    intro value
    cases value with
    | none => exact .none
    | some a => exact .some (r.preserved a)

/-- The list relation preserves length, constructor shape and every element. -/
inductive ListRel {A : Type u} {B : Type v}
    (R : A → B → Prop) : List A → List B → Prop where
  | nil : ListRel R [] []
  | cons {a : A} {b : B} {xs : List A} {ys : List B} :
      R a b → ListRel R xs ys → ListRel R (a :: xs) (b :: ys)

theorem list_map_related {A : Type u} {B : Type v}
    (r : ForwardWitness A B) : ∀ xs : List A,
      ListRel r.relation xs (xs.map r.translate)
  | [] => .nil
  | a :: xs => .cons (r.preserved a) (list_map_related r xs)

def list {A : Type u} {B : Type v}
    (r : ForwardWitness A B) : ForwardWitness (List A) (List B) where
  relation := ListRel r.relation
  translate := List.map r.translate
  preserved := list_map_related r

/-- A finite observer check is only a *necessary example* of computation
    preservation; it is not a universal computation proof. -/
theorem list_length_observer {A : Type u} {B : Type v}
    (r : ForwardWitness A B) (xs : List A) :
    xs.length = (xs.map r.translate).length := by
  simp

/-- Sanity control: an explicitly supplied equality interpretation really
    yields a witness on the finite Bool carrier. This is hand-written and is
    NOT an assertion about generated code. -/
def boolIdentity : ForwardWitness Bool Bool where
  relation := Eq
  translate := id
  preserved := by intro b; rfl

example : ListRel Eq [true, false] [true, false] :=
  list_map_related boolIdentity [true, false]

end Agda2Lean.TranslationQuality
