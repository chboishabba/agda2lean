module Structural.Record where

record Pair (A B : Set) : Set where
  constructor _,_
  field
    first : A
    second : B

open Pair public

swap : {A B : Set} → Pair A B → Pair B A
swap (a , b) = b , a
