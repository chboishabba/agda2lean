module Structural.LocalModule where

module IdentityModule (A : Set) where
  identity : A → A
  identity value = value

open IdentityModule public
