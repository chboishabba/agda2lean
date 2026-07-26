{-# OPTIONS --local-rewriting #-}

module LocalRewrite where

open import Agda.Builtin.Equality
open import Agda.Builtin.Equality.Rewrite
open import Agda.Builtin.Nat

module UnderRewrite
  (n m : Nat)
  (@rewrite plus-zero : n + m ≡ m)
  where

  preserved : n + m ≡ m
  preserved = refl
