{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Platform
  ( AxiomEffect (..)
  , ComputationTreatment (..)
  , PlatformMapping (..)
  , platformRegistryVersion
  , platformMappings
  , lookupPlatformMapping
  , builtinAuditName
  ) where

import Agda2Lean.IR
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

data AxiomEffect = NoAxioms | MayIntroduceAxioms
  deriving stock (Eq, Show)

data ComputationTreatment
  = NativeDefinitional
  | TranslatedRecursive
  | TheoremBacked
  | OpaqueConstant
  | AxiomaticCompatibility
  deriving stock (Eq, Ord, Show)

platformRegistryVersion :: Text
platformRegistryVersion = "lean4-platform-v1"

data PlatformMapping = PlatformMapping
  { platformBuiltin :: BuiltinId
  , platformAuditName :: Text
  , platformTarget :: Text
  , platformMode :: Text
  , platformComputation :: ComputationTreatment
  , platformAxiomEffect :: AxiomEffect
  , platformAxiomDelta :: [Text]
  }
  deriving stock (Eq, Show)

-- This is the reviewed semantic dictionary. Names are diagnostics only;
-- extraction selects entries by BuiltinId.
platformMappings :: Map BuiltinId PlatformMapping
platformMappings = Map.fromList (map entry [
    (BuiltinNat, "Agda.Builtin.Nat.Nat", "Nat", "exact-inductive")
  , (BuiltinNatZero, "Agda.Builtin.Nat.Nat.zero", "Nat.zero", "constructor")
  , (BuiltinNatSuc, "Agda.Builtin.Nat.Nat.suc", "Nat.succ", "constructor")
  , (BuiltinNatAdd, "Agda.Builtin.Nat._+_", "Nat.add", "reduction")
  , (BuiltinNatSub, "Agda.Builtin.Nat._-_", "Nat.sub", "reduction")
  , (BuiltinNatMul, "Agda.Builtin.Nat._*_", "Nat.mul", "reduction")
  , (BuiltinNatEq, "Agda.Builtin.Nat._==_", "Nat.decEq", "reduction")
  , (BuiltinNatLt, "Agda.Builtin.Nat._<_", "Nat.lt", "reduction")
  , (BuiltinBool, "Agda.Builtin.Bool.Bool", "Bool", "exact-inductive")
  , (BuiltinBoolTrue, "Agda.Builtin.Bool.Bool.true", "true", "constructor")
  , (BuiltinBoolFalse, "Agda.Builtin.Bool.Bool.false", "false", "constructor")
  , (BuiltinEquality, "Agda.Builtin.Equality._≡_", "Eq", "ordinary-equality")
  , (BuiltinRefl, "Agda.Builtin.Equality._≡_.refl", "Eq.refl", "constructor")
  , (BuiltinLevel, "Agda.Primitive.Level", "Type", "universe")
  , (BuiltinLevelZero, "Agda.Primitive.lzero", "0", "universe")
  , (BuiltinLevelSuc, "Agda.Primitive.lsuc", "+ 1", "universe")
  , (BuiltinLevelMax, "Agda.Primitive._⊔_", "max", "universe")
  , (BuiltinProp, "Agda.Primitive.Prop", "Prop", "universe")
  , (BuiltinSet, "Agda.Primitive.Set", "Type", "universe")
  ])
  where
    entry (builtin, audit, target, mode) =
      ( builtin
      , PlatformMapping
          builtin
          audit
          target
          mode
          (computationFor builtin)
          NoAxioms
          []
      )

    computationFor builtin =
      case builtin of
        BuiltinEquality -> TheoremBacked
        BuiltinRefl -> TheoremBacked
        BuiltinNatEq -> TranslatedRecursive
        BuiltinNatLt -> TranslatedRecursive
        _ -> NativeDefinitional

lookupPlatformMapping :: BuiltinId -> Maybe PlatformMapping
lookupPlatformMapping = (`Map.lookup` platformMappings)

builtinAuditName :: BuiltinId -> Text
builtinAuditName builtin =
  maybe ("<unregistered:" <> Text.pack (show builtin) <> ">") platformAuditName
    (lookupPlatformMapping builtin)
