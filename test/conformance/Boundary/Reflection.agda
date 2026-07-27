module Boundary.Reflection where

open import Agda.Builtin.Reflection using (Term; TC)

postulate
  reflectedTerm : Term
  reflectedComputation : TC Term
