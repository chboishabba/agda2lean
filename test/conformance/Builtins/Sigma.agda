module Builtins.Sigma where

open import Agda.Builtin.Sigma using (Σ; _,_; fst; snd)

pair : {A : Set} {B : A → Set} → (value : A) → B value → Σ A B
pair value witness = value , witness
