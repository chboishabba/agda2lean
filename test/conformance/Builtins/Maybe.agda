module Builtins.Maybe where

open import Agda.Builtin.Maybe using (Maybe; nothing; just)

fromMaybe : {A : Set} → A → Maybe A → A
fromMaybe fallback nothing = fallback
fromMaybe fallback (just value) = value
