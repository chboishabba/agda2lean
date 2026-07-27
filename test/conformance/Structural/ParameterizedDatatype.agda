module Structural.ParameterizedDatatype where

data Box (A : Set) : Set where
  box : A → Box A

unbox : {A : Set} → Box A → A
unbox (box value) = value
