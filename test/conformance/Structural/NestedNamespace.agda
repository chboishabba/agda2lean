module Structural.NestedNamespace where

module Outer where
  module Inner where
    identity : {A : Set} → A → A
    identity value = value

open Outer.Inner public
