module Structural.MutualDefinitions where

open import Agda.Builtin.Nat using (Nat; zero; suc)
open import Agda.Builtin.Bool using (Bool; true; false)

mutual
  even : Nat → Bool
  even zero = true
  even (suc n) = odd n

  odd : Nat → Bool
  odd zero = false
  odd (suc n) = even n
