module Computation.StructuralRecursion where

open import Agda.Builtin.Nat using (Nat; zero; suc)
open import Agda.Builtin.List using (List; []; _∷_)

length : {A : Set} → List A → Nat
length [] = zero
length (_ ∷ values) = suc (length values)
