-- Pinned fixture copied from chboishabba/dashi_agda
-- commit 72ae53834be4cd6df842d80fae97c892990ccef6.

module JFixedPoint where

open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
open import Agda.Builtin.Bool
open import Agda.Builtin.List

record Observation : Set where
  field
    e47 : Nat
    e59 : Nat
    e71 : Nat

contract : Observation → Nat
contract o = Observation.e47 o * 47 * (Observation.e59 o * 59) * (Observation.e71 o * 71) + 1

unit-obs : Observation
unit-obs = record { e47 = 1 ; e59 = 1 ; e71 = 1 }

unit-converges : contract unit-obs ≡ 196884
unit-converges = refl

stack : Nat → Observation
stack zero    = unit-obs
stack (suc n) = unit-obs

fixed-0 : contract (stack 0) ≡ 196884
fixed-0 = refl

fixed-1 : contract (stack 1) ≡ 196884
fixed-1 = refl

fixed-2 : contract (stack 2) ≡ 196884
fixed-2 = refl

fixed-100 : contract (stack 100) ≡ 196884
fixed-100 = refl

Tower : Set
Tower = List Observation

expand : Tower → Tower
expand t = unit-obs ∷ t

contract-all : Tower → List Nat
contract-all []       = []
contract-all (o ∷ os) = contract o ∷ contract-all os

tower-1 : Tower
tower-1 = expand []

tower-3 : Tower
tower-3 = expand (expand (expand []))

all-196884 : contract-all tower-3 ≡ (196884 ∷ 196884 ∷ 196884 ∷ [])
all-196884 = refl
