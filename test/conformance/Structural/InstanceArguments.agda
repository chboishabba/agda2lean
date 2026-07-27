module Structural.InstanceArguments where

record HasDefault (A : Set) : Set where
  field
    default : A

open HasDefault {{...}} public

useDefault : {A : Set} → {{instance : HasDefault A}} → A
useDefault {{instance}} = HasDefault.default instance
