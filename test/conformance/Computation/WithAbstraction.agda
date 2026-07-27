module Computation.WithAbstraction where

open import Agda.Builtin.Nat using (Nat; zero; suc)
open import Agda.Builtin.Bool using (Bool; true; false)

isZero : Nat → Bool
isZero zero = true
isZero (suc n) = false

choose : Nat → Nat → Nat
choose left right with isZero left
... | true = right
... | false = left
