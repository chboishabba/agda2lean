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

universe u v w x y z

/-- A *proof-relevant* relation and a witness that a forward map respects it.
    Lean Type is used deliberately: an arbitrary Agda Set witness must not be
    silently erased into Lean Prop. Propositional/quotient encodings require
    a separate reviewed adapter, not a weaker relation chosen post hoc. -/
structure ForwardWitness (A : Type u) (B : Type v) where
  relation : A → B → Type y
  translate : A → B
  preserved : ∀ a : A, relation a (translate a)

/-- A concrete witness, not declaration-name equality, supplies the
    relation witness needed by a semantic correspondence check. -/
def translation_related {A : Type u} {B : Type v}
    (r : ForwardWitness A B) (a : A) :
    r.relation a (r.translate a) :=
  r.preserved a

/-- Pointwise relational interpretation of dependent-free functions. -/
def ArrowRel {A : Type u} {B : Type v} {C : Type w} {D : Type x}
    (RA : A → B → Type y) (RB : C → D → Type z)
    (f : A → C) (g : B → D) :=
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
    (RA : A → B → Type y) (RB : C → D → Type z)
    (p : A × C) (q : B × D) : Type (max y z) :=
  RA p.1 q.1 × RB p.2 q.2

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
    (R : A → B → Type y) : Option A → Option B → Type y where
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
    (R : A → B → Type y) : List A → List B → Type y where
  | nil : ListRel R [] []
  | cons {a : A} {b : B} {xs : List A} {ys : List B} :
      R a b → ListRel R xs ys → ListRel R (a :: xs) (b :: ys)

def list_map_related {A : Type u} {B : Type v}
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

/-- A proof-relevant, constructor-faithful relation for the finite Boolean
    carrier. Unlike an always-True relation it rejects false ↔ true. -/
inductive BoolMatch : Bool → Bool → Type where
  | true : BoolMatch true true
  | false : BoolMatch false false

/-- Hand-written reference control, NOT the output of either translator. -/
def boolIdentity : ForwardWitness Bool Bool where
  relation := BoolMatch
  translate := id
  preserved := by
    intro b
    cases b with
    | false => exact .false
    | true => exact .true

example : ListRel BoolMatch [true, false] [true, false] :=
  list_map_related boolIdentity [true, false]

end Agda2Lean.TranslationQuality
