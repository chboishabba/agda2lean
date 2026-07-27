module Builtins.List where

open import Agda.Builtin.List using (List; []; _∷_)

headOr : {A : Set} → A → List A → A
headOr fallback [] = fallback
headOr fallback (value ∷ values) = value

map : {A B : Set} → (A → B) → List A → List B
map function [] = []
map function (value ∷ values) = function value ∷ map function values
