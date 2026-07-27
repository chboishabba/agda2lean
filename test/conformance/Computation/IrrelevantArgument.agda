module Computation.IrrelevantArgument where

ignore : {A : Set} → .A → Set → Set
ignore .value result = result
