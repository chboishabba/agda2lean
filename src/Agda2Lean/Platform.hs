{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Platform
  ( ArgumentPolicy (..)
  , AxiomEffect (..)
  , BuiltinCoverage (..)
  , BuiltinEntityKind (..)
  , Compatibility (..)
  , ComputationTreatment (..)
  , PlatformMapping (..)
  , RegistryIssue (..)
  , RegistryLayer (..)
  , RegistryMode (..)
  , RegistryScope (..)
  , VersionContext (..)
  , builtinAuditName
  , builtinCoverageInventory
  , checkVersionCompatibility
  , composeRegistryLayers
  , currentVersionContext
  , leanTargetVersion
  , lookupPlatformMapping
  , platformMappings
  , platformRegistryDigest
  , platformRegistryLayer
  , platformRegistryVersion
  , receiptSchemaVersion
  , renderBuiltinCoverageInventory
  ) where

import Agda2Lean.Codec (codecVersion)
import Agda2Lean.Hash (hashBytes, renderObjectHash)
import Agda2Lean.IR
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word16)
import qualified Data.Vector as Vector

-- | How an elaborated Agda application spine is projected into a Lean
-- application spine.  Indices are zero-based and may reorder as well as erase
-- source arguments.  The source arity makes partial applications fail closed
-- instead of accidentally changing their meaning.
data ArgumentPolicy
  = PreserveArguments
  | ProjectArguments Word16 (Vector.Vector Word16)
  deriving stock (Eq, Ord, Show)

data AxiomEffect = NoAxioms | MayIntroduceAxioms
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data ComputationTreatment
  = NativeDefinitional
  | TranslatedRecursive
  | TheoremBacked
  | OpaqueConstant
  | AxiomaticCompatibility
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data BuiltinEntityKind
  = BuiltinDatatype
  | BuiltinConstructor
  | BuiltinFunction
  | BuiltinPrimitive
  | BuiltinSort
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data RegistryScope
  = PlatformProtected
  | LibraryScope
  | ProjectScope
  | FixtureOnly
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data RegistryMode = ProductionMode | TestMode
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- Registry v2 adds argument-spine policies and the List semantic family.
-- Semantic identity is additionally bound to 'platformRegistryDigest'.
platformRegistryVersion :: Text
platformRegistryVersion = "lean4-platform-v2"

receiptSchemaVersion :: Word16
receiptSchemaVersion = 3

leanTargetVersion :: Text
leanTargetVersion = "lean4"

data VersionContext = VersionContext
  { versionCodec :: Word16
  , versionRegistry :: Text
  , versionReceiptSchema :: Word16
  , versionAgdaBackend :: Text
  , versionLeanTarget :: Text
  }
  deriving stock (Eq, Ord, Show)

data Compatibility
  = Compatible
  | MigrationRequired Text
  | Incompatible Text
  deriving stock (Eq, Ord, Show)

currentVersionContext :: VersionContext
currentVersionContext =
  VersionContext codecVersion platformRegistryVersion receiptSchemaVersion "2.9.0" leanTargetVersion

checkVersionCompatibility :: VersionContext -> Compatibility
checkVersionCompatibility context
  | versionCodec context /= codecVersion = Incompatible "unsupported IR codec version"
  | versionReceiptSchema context > receiptSchemaVersion = Incompatible "receipt schema is newer than this compiler"
  | versionReceiptSchema context < receiptSchemaVersion = MigrationRequired "receipt schema migration required"
  | versionRegistry context /= platformRegistryVersion = Incompatible "builtin registry version mismatch"
  | versionAgdaBackend context /= "2.9.0" = Incompatible "unsupported Agda backend version"
  | versionLeanTarget context /= leanTargetVersion = Incompatible "unsupported Lean target platform"
  | otherwise = Compatible

data PlatformMapping = PlatformMapping
  { platformBuiltin :: BuiltinId
  , platformAuditName :: Text
  , platformTarget :: Text
  , platformMode :: Text
  , platformComputation :: ComputationTreatment
  , platformAxiomEffect :: AxiomEffect
  , platformAxiomDelta :: [Text]
  , platformEntityKind :: BuiltinEntityKind
  , platformArgumentPolicy :: ArgumentPolicy
  , platformScope :: RegistryScope
  }
  deriving stock (Eq, Ord, Show)

data RegistryLayer = RegistryLayer
  { registryLayerName :: Text
  , registryLayerVersion :: Text
  , registryLayerScope :: RegistryScope
  , registryLayerMappings :: [PlatformMapping]
  }
  deriving stock (Eq, Show)

data RegistryIssue
  = DuplicateRule Text BuiltinId
  | ConflictingRule Text Text BuiltinId
  | ProtectedOverride Text BuiltinId
  | FixtureRuleOutsideTestMode BuiltinId
  | ScopeMismatch Text BuiltinId RegistryScope RegistryScope
  | KindMismatch BuiltinId BuiltinEntityKind BuiltinEntityKind
  | InvalidArgumentPolicy Text BuiltinId ArgumentPolicy
  deriving stock (Eq, Ord, Show)

composeRegistryLayers :: RegistryMode -> [RegistryLayer] -> Either [RegistryIssue] (Map BuiltinId PlatformMapping)
composeRegistryLayers mode layers =
  case concatMap validateLayer layers <> compositionIssues of
    [] -> Right composed
    issues -> Left (sortOn show issues)
  where
    composed = foldl' insertLayer Map.empty layers
    insertLayer table layer = foldl' (insertRule layer) table (registryLayerMappings layer)
    insertRule layer table mapping =
      case Map.lookup (platformBuiltin mapping) table of
        Nothing -> Map.insert (platformBuiltin mapping) mapping table
        Just previous
          | registryLayerScope layer == FixtureOnly
              && mode == TestMode
              && platformScope previous /= PlatformProtected ->
                  Map.insert (platformBuiltin mapping) mapping table
          | otherwise -> table

    compositionIssues = snd (foldl' inspectLayer (Map.empty, []) layers)
    inspectLayer state layer = foldl' (inspectRule layer) state (registryLayerMappings layer)
    inspectRule layer (seen, issues) mapping =
      case Map.lookup builtin seen of
        Nothing -> (Map.insert builtin (registryLayerName layer, mapping) seen, issues)
        Just (owner, previous)
          | platformEntityKind previous /= platformEntityKind mapping ->
              (seen, KindMismatch builtin (platformEntityKind previous) (platformEntityKind mapping) : issues)
          | platformScope previous == PlatformProtected ->
              (seen, ProtectedOverride (registryLayerName layer) builtin : issues)
          | registryLayerScope layer == FixtureOnly && mode /= TestMode ->
              (seen, FixtureRuleOutsideTestMode builtin : issues)
          | registryLayerScope layer == FixtureOnly ->
              (Map.insert builtin (registryLayerName layer, mapping) seen, issues)
          | previous == mapping -> (seen, issues)
          | otherwise ->
              (seen, ConflictingRule owner (registryLayerName layer) builtin : issues)
      where
        builtin = platformBuiltin mapping

    validateLayer layer = duplicateIssues <> scopeIssues <> fixtureIssues <> argumentPolicyIssues
      where
        counts = Map.fromListWith (+) [(platformBuiltin mapping, 1 :: Int) | mapping <- registryLayerMappings layer]
        duplicateIssues =
          [ DuplicateRule (registryLayerName layer) builtin
          | (builtin, count) <- Map.toAscList counts
          , count > 1
          ]
        scopeIssues =
          [ ScopeMismatch (registryLayerName layer) (platformBuiltin mapping)
              (registryLayerScope layer) (platformScope mapping)
          | mapping <- registryLayerMappings layer
          , platformScope mapping /= registryLayerScope layer
          ]
        fixtureIssues =
          [ FixtureRuleOutsideTestMode (platformBuiltin mapping)
          | registryLayerScope layer == FixtureOnly
          , mode /= TestMode
          , mapping <- registryLayerMappings layer
          ]
        argumentPolicyIssues =
          [ InvalidArgumentPolicy (registryLayerName layer) (platformBuiltin mapping) policy
          | mapping <- registryLayerMappings layer
          , let policy = platformArgumentPolicy mapping
          , not (validArgumentPolicy policy)
          ]

    validArgumentPolicy PreserveArguments = True
    validArgumentPolicy (ProjectArguments arity order) =
      all (< arity) (Vector.toList order)

platformMappings :: Map BuiltinId PlatformMapping
platformMappings = Map.fromList [(platformBuiltin mapping, mapping) | mapping <- mappings]
  where
    mappings =
      [ entry BuiltinNat "Agda.Builtin.Nat.Nat" "Nat" "exact-inductive" BuiltinDatatype
      , entry BuiltinNatZero "Agda.Builtin.Nat.Nat.zero" "Nat.zero" "constructor" BuiltinConstructor
      , entry BuiltinNatSuc "Agda.Builtin.Nat.Nat.suc" "Nat.succ" "constructor" BuiltinConstructor
      , entry BuiltinNatAdd "Agda.Builtin.Nat._+_" "Nat.add" "reduction" BuiltinFunction
      , entry BuiltinNatSub "Agda.Builtin.Nat._-_" "Nat.sub" "reduction" BuiltinFunction
      , entry BuiltinNatMul "Agda.Builtin.Nat._*_" "Nat.mul" "reduction" BuiltinFunction
      , entry BuiltinNatEq "Agda.Builtin.Nat._==_" "Nat.decEq" "reduction" BuiltinFunction
      , entry BuiltinNatLt "Agda.Builtin.Nat._<_" "Nat.lt" "reduction" BuiltinFunction
      , entry BuiltinBool "Agda.Builtin.Bool.Bool" "Bool" "exact-inductive" BuiltinDatatype
      , entry BuiltinBoolTrue "Agda.Builtin.Bool.Bool.true" "true" "constructor" BuiltinConstructor
      , entry BuiltinBoolFalse "Agda.Builtin.Bool.Bool.false" "false" "constructor" BuiltinConstructor
      , entryWithPolicy BuiltinList "Agda.Builtin.List.List" "List" "exact-inductive" BuiltinDatatype 2 [1]
      , entryWithPolicy BuiltinListNil "Agda.Builtin.List.List.[]" "List.nil" "constructor" BuiltinConstructor 2 [1]
      , entryWithPolicy BuiltinListCons "Agda.Builtin.List.List._∷_" "List.cons" "constructor" BuiltinConstructor 4 [1, 2, 3]
      , entry BuiltinEquality "Agda.Builtin.Equality._≡_" "Eq" "ordinary-equality" BuiltinDatatype
      , entryWithPolicy BuiltinRefl "Agda.Builtin.Equality._≡_.refl" "Eq.refl" "constructor" BuiltinConstructor 3 [1, 2]
      , entry BuiltinLevel "Agda.Primitive.Level" "Type" "universe" BuiltinSort
      , entry BuiltinLevelZero "Agda.Primitive.lzero" "0" "universe" BuiltinPrimitive
      , entry BuiltinLevelSuc "Agda.Primitive.lsuc" "+ 1" "universe" BuiltinPrimitive
      , entry BuiltinLevelMax "Agda.Primitive._⊔_" "max" "universe" BuiltinPrimitive
      , entry BuiltinProp "Agda.Primitive.Prop" "Prop" "universe" BuiltinSort
      , entry BuiltinSet "Agda.Primitive.Set" "Type" "universe" BuiltinSort
      ]

    entry builtin audit target mode kind =
      entryWithArgumentPolicy builtin audit target mode kind PreserveArguments

    entryWithPolicy builtin audit target mode kind arity order =
      entryWithArgumentPolicy
        builtin audit target mode kind
        (ProjectArguments arity (Vector.fromList order))

    entryWithArgumentPolicy builtin audit target mode kind argumentPolicy =
      PlatformMapping builtin audit target mode (computationFor builtin) NoAxioms [] kind argumentPolicy PlatformProtected

    computationFor BuiltinEquality = TheoremBacked
    computationFor BuiltinRefl = TheoremBacked
    computationFor BuiltinNatEq = TranslatedRecursive
    computationFor BuiltinNatLt = TranslatedRecursive
    computationFor _ = NativeDefinitional

platformRegistryLayer :: RegistryLayer
platformRegistryLayer =
  RegistryLayer "lean4-platform" platformRegistryVersion PlatformProtected (Map.elems platformMappings)

platformRegistryDigest :: Text
platformRegistryDigest = renderObjectHash (hashBytes (TextEncoding.encodeUtf8 canonicalRegistryText))
  where
    canonicalRegistryText =
      Text.unlines
        [ Text.intercalate "\t"
            [ Text.pack (show builtin)
            , platformAuditName mapping
            , platformTarget mapping
            , platformMode mapping
            , Text.pack (show (platformComputation mapping))
            , Text.pack (show (platformAxiomEffect mapping))
            , Text.intercalate "," (platformAxiomDelta mapping)
            , Text.pack (show (platformEntityKind mapping))
            , Text.pack (show (platformArgumentPolicy mapping))
            , Text.pack (show (platformScope mapping))
            ]
        | (builtin, mapping) <- Map.toAscList platformMappings
        ]

data BuiltinCoverage = BuiltinCoverage
  { coverageBuiltin :: BuiltinId
  , coverageAgdaKey :: Text
  , coverageEntityKind :: BuiltinEntityKind
  , coverageStatus :: Text
  , coverageLeanStrategy :: Text
  , coverageComputation :: ComputationTreatment
  , coverageAxiomDelta :: [Text]
  , coverageArgumentPolicy :: ArgumentPolicy
  , coverageOverrideAllowed :: Bool
  }
  deriving stock (Eq, Ord, Show)

builtinCoverageInventory :: [BuiltinCoverage]
builtinCoverageInventory =
  [ BuiltinCoverage builtin (platformAuditName mapping) (platformEntityKind mapping)
      "native" (platformMode mapping) (platformComputation mapping)
      (platformAxiomDelta mapping) (platformArgumentPolicy mapping)
      (platformScope mapping /= PlatformProtected)
  | builtin <- [minBound .. maxBound]
  , let mapping = platformMappings Map.! builtin
  ]

renderBuiltinCoverageInventory :: Text
renderBuiltinCoverageInventory =
  Text.unlines
    ( "builtin-id\tagda-key\tentity-kind\tstatus\tlean-strategy\tcomputation\taxiom-delta\targument-policy\toverride-allowed"
        : [ Text.intercalate "\t"
              [ Text.pack (show (coverageBuiltin coverage))
              , coverageAgdaKey coverage
              , Text.pack (show (coverageEntityKind coverage))
              , coverageStatus coverage
              , coverageLeanStrategy coverage
              , Text.pack (show (coverageComputation coverage))
              , if null (coverageAxiomDelta coverage) then "-" else Text.intercalate "," (coverageAxiomDelta coverage)
              , Text.pack (show (coverageArgumentPolicy coverage))
              , if coverageOverrideAllowed coverage then "yes" else "no"
              ]
          | coverage <- sortOn coverageBuiltin builtinCoverageInventory
          ]
    )

lookupPlatformMapping :: BuiltinId -> Maybe PlatformMapping
lookupPlatformMapping = (`Map.lookup` platformMappings)

builtinAuditName :: BuiltinId -> Text
builtinAuditName builtin =
  maybe ("<unregistered:" <> Text.pack (show builtin) <> ">") platformAuditName
    (lookupPlatformMapping builtin)
