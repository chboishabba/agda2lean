module Identity where

open import Agda.Builtin.Equality using (_≡_; refl)

variable
  A : Set

identity : A → A
identity x = x

identity-law : (x : A) → identity x ≡ x
identity-law x = refl
