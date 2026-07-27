module Computation.IrrelevantArgument where

ignore : {A : Set} → .A → A → A
ignore _ value = value
