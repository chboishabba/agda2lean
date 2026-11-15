module TranslationQuality where

-- Constructive, proof-relevant reference for the ordinary Agda fragment.
-- This is a hand-written semantic *specification*, not translated output.
-- Keeping Rel in Set explicitly prevents an accidental assumption that
-- arbitrary Agda proof witnesses may be erased into Lean Prop.

open import Agda.Builtin.Bool using (Bool; true; false)
open import Agda.Builtin.Equality using (_≡_; refl)
open import Agda.Builtin.List using (List; []; _∷_)
open import Agda.Builtin.Maybe using (Maybe; nothing; just)

record ForwardWitness (A B : Set) : Set₁ where
  field
    Rel        : A → B → Set
    translate  : A → B
    preserved  : (a : A) → Rel a (translate a)

open ForwardWitness

translation-related :
  {A B : Set} (r : ForwardWitness A B) (a : A) →
  Rel r a (translate r a)
translation-related r a = preserved r a

ArrowRel : {A B C D : Set} →
  (A → B → Set) → (C → D → Set) →
  (A → C) → (B → D) → Set
ArrowRel {A} {B} RA RB f g =
  (a : A) → (b : B) → RA a b → RB (f a) (g b)

record ObserverWitness {A B C : Set}
  (r : ForwardWitness A B)
  (sourceObserve : A → C)
  (targetObserve : B → C) : Set where
  field
    agrees : (a : A) →
      sourceObserve a ≡ targetObserve (translate r a)

observer-preservation :
  {A B C : Set} (r : ForwardWitness A B)
  (sourceObserve : A → C) (targetObserve : B → C) →
  ObserverWitness r sourceObserve targetObserve →
  (a : A) → sourceObserve a ≡ targetObserve (translate r a)
observer-preservation r sourceObserve targetObserve witness a =
  ObserverWitness.agrees witness a

record Pair (A B : Set) : Set where
  constructor _,_
  field
    first  : A
    second : B

data ProdRel {A B C D : Set}
  (RA : A → B → Set) (RB : C → D → Set) :
  Pair A C → Pair B D → Set where
  rel-pair : {a : A} {b : B} {c : C} {d : D} →
    RA a b → RB c d → ProdRel RA RB (a , c) (b , d)

productTranslate : {A B C D : Set} →
  (r : ForwardWitness A B) (s : ForwardWitness C D) →
  Pair A C → Pair B D
productTranslate r s (a , c) = translate r a , translate s c

productRelated : {A B C D : Set} →
  (r : ForwardWitness A B) (s : ForwardWitness C D) →
  (p : Pair A C) →
  ProdRel (Rel r) (Rel s) p (productTranslate r s p)
productRelated r s (a , c) = rel-pair (preserved r a) (preserved s c)

productWitness : {A B C D : Set} →
  ForwardWitness A B → ForwardWitness C D →
  ForwardWitness (Pair A C) (Pair B D)
productWitness r s = record
  { Rel = ProdRel (Rel r) (Rel s)
  ; translate = productTranslate r s
  ; preserved = productRelated r s
  }

data MaybeRel {A B : Set} (R : A → B → Set) :
  Maybe A → Maybe B → Set where
  rel-nothing : MaybeRel R nothing nothing
  rel-just : {a : A} {b : B} →
    R a b → MaybeRel R (just a) (just b)

mapMaybe : {A B : Set} → (A → B) → Maybe A → Maybe B
mapMaybe f nothing = nothing
mapMaybe f (just a) = just (f a)

maybeRelated : {A B : Set} →
  (r : ForwardWitness A B) (x : Maybe A) →
  MaybeRel (Rel r) x (mapMaybe (translate r) x)
maybeRelated r nothing = rel-nothing
maybeRelated r (just a) = rel-just (preserved r a)

maybeWitness : {A B : Set} →
  ForwardWitness A B → ForwardWitness (Maybe A) (Maybe B)
maybeWitness r = record
  { Rel = MaybeRel (Rel r)
  ; translate = mapMaybe (translate r)
  ; preserved = maybeRelated r
  }

data ListRel {A B : Set} (R : A → B → Set) :
  List A → List B → Set where
  rel-nil : ListRel R [] []
  rel-cons : {a : A} {b : B} {xs : List A} {ys : List B} →
    R a b → ListRel R xs ys → ListRel R (a ∷ xs) (b ∷ ys)

mapList : {A B : Set} → (A → B) → List A → List B
mapList f [] = []
mapList f (a ∷ xs) = f a ∷ mapList f xs

listRelated : {A B : Set} →
  (r : ForwardWitness A B) (xs : List A) →
  ListRel (Rel r) xs (mapList (translate r) xs)
listRelated r [] = rel-nil
listRelated r (a ∷ xs) = rel-cons (preserved r a) (listRelated r xs)

listWitness : {A B : Set} →
  ForwardWitness A B → ForwardWitness (List A) (List B)
listWitness r = record
  { Rel = ListRel (Rel r)
  ; translate = mapList (translate r)
  ; preserved = listRelated r
  }

-- Sanity control only: equality on Bool is explicit and computational.
boolIdentity : ForwardWitness Bool Bool
boolIdentity = record
  { Rel = _≡_
  ; translate = λ b → b
  ; preserved = λ b → refl
  }

boolListControl :
  ListRel _≡_ (true ∷ false ∷ []) (true ∷ false ∷ [])
boolListControl = listRelated boolIdentity (true ∷ false ∷ [])
