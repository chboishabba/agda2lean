module Boundary.Rewrite where

open import Agda.Builtin.Equality using (_≡_; refl)

postulate
  A : Set
  normalize : A → A
  normalize-idempotent : (value : A) → normalize (normalize value) ≡ normalize value

{-# REWRITE normalize-idempotent #-}
