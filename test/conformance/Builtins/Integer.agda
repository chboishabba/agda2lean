module Builtins.Integer where

open import Agda.Builtin.Int using (Int; pos; negsuc)
open import Agda.Builtin.Nat using (Nat; zero; suc)

zeroInt : Int
zeroInt = pos zero

minusOne : Int
minusOne = negsuc zero
