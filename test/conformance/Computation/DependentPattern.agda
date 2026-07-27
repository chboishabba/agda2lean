module Computation.DependentPattern where

open import Agda.Builtin.Nat using (Nat; zero; suc)

data Vec (A : Set) : Nat → Set where
  [] : Vec A zero
  _∷_ : {n : Nat} → A → Vec A n → Vec A (suc n)

head : {A : Set} {n : Nat} → Vec A (suc n) → A
head (value ∷ values) = value
