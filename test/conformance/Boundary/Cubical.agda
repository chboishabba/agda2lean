{-# OPTIONS --cubical #-}
module Boundary.Cubical where

open import Agda.Builtin.Cubical.Path using (PathP; _≡_; refl)

pathIdentity : {A : Set} {x : A} → x ≡ x
pathIdentity = refl
