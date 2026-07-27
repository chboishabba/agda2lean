module Structural.ImplicitArguments where

identity : {A : Set} → A → A
identity value = value

apply : {A B : Set} → (A → B) → A → B
apply function value = function value
