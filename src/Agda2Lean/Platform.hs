{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Platform
  ( AxiomEffect (..)
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
import qualified Data.Text.Encoding as Text
import Data.Word (Word16)

-- | Whether a lowering is known to extend the target axiom surface.
data AxiomEffect = NoAxioms | MayIntroduceAxioms
  deriving stock (Eq, Ord, Show)

data ComputationTreatment
  = NativeDefinitional
  | TranslatedRecursive
  | TheoremBacked
  | OpaqueConstant
  | AxiomaticCompatibility
  deriving stock (Eq, Ord, Show)

-- | The semantic kind expected for a registered Agda entity.
data BuiltinEntityKind
  = BuiltinDatatype
  | BuiltinConstructor
  | BuiltinFunction
  | BuiltinPrimitive
  | BuiltinSort
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Registry scopes are semantic authority levels, not ordinary shadowing
-- precedence. Platform entries are protected; fixture replacement is only
-- available in explicit test mode.
data RegistryScope
  = PlatformProtected
  | LibraryScope
  | ProjectScope
  | FixtureOnly
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data RegistryMode = ProductionMode | TestMode
  deriving stock (Eq, Ord, Show)

platformRegistryVersion :: Text
platformRegistryVersion = "lean4-platform-v2"

receiptSchemaVersion :: Word16
receiptSchemaVersion = 2

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
  VersionContext
    { versionCodec = codecVersion
    , versionRegistry = platformRegistryVersion
    , versionReceiptSchema = receiptSchemaVersion
    , versionAgdaBackend = "2.9.0"
    , versionLeanTarget = leanTargetVersion
    }

checkVersionCompatibility :: VersionContext -> Compatibility
checkVersionCompatibility context
  | versionCodec context /= codecVersion =
      Incompatible "unsupported IR codec version"
  | versionReceiptSchema context > receiptSchemaVersion =
      Incompatible "receipt schema is newer than this compiler"
  | versionReceiptSchema context < receiptSchemaVersion =
      MigrationRequired "receipt schema migration required"
  | versionRegistry context /= platformRegistryVersion =
      Incompatible "builtin registry version mismatch"
  | versionAgdaBackend context /= "2.9.0" =
      Incompatible "unsupported Agda backend version"
  | versionLeanTarget context /= leanTargetVersion =
      Incompatible "unsupported Lean target platform"
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
  deriving stock (Eq, Ord, Show)

-- | Compose layers from lowest to highest authority. Ordinary library and
-- project layers may fill extension points but may not silently override an
-- existing mapping. Fixture replacement is test-only and can never replace a
-- platform-protected identity.
composeRegistryLayers :: RegistryMode -> [RegistryLayer] -> Either [RegistryIssue] (Map BuiltinId PlatformMapping)
composeRegistryLayers mode layers =
  case concatMap validateLayer layers <> compositionIssues of
    [] -> Right composed
    issues -> Left (sortOn show issues)
  where
    composed = foldl' insertLayer Map.empty layers
    insertLayer table layer =
      foldl' (insertRule layer) table (registryLayerMappings layer)
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
    inspectLayer (seen, issues) layer =
      foldl' (inspectRule layer) (seen, issues) (registryLayerMappings layer)
    inspectRule layer (seen, issues) mapping =
      case Map.lookup builtin seen of
        Nothing -> (Map.insert builtin (registryLayerName layer, mapping) seen, issues)
        Just (owner, previous)
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

    validateLayer layer = duplicateIssues <> scopeIssues <> fixtureIssues
      where
        counts = Map.fromListWith (+) [(platformBuiltin mapping, 1 :: Int) | mapping <- registryLayerMappings layer]
        duplicateIssues =
          [ DuplicateRule (registryLayerName layer) builtin
          | (builtin, count) <- Map.toAscList counts
          , count > 1
          ]
        scopeIssues =
          [ ScopeMismatch
              (registryLayerName layer)
              (platformBuiltin mapping)
              (registryLayerScope layer)
              (platformScope mapping)
          | mapping <- registryLayerMappings layer
          , platformScope mapping /= registryLayerScope layer
          ]
        fixtureIssues =
          [ FixtureRuleOutsideTestMode (platformBuiltin mapping)
          | registryLayerScope layer == FixtureOnly
          , mode /= TestMode
          , mapping <- registryLayerMappings layer
          ]

-- This is the reviewed semantic dictionary. Names are diagnostics only;
-- extraction selects entries by BuiltinId.
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
      , entry BuiltinEquality "Agda.Builtin.Equality._≡_" "Eq" "ordinary-equality" BuiltinDatatype
      , entry BuiltinRefl "Agda.Builtin.Equality._≡_.refl" "Eq.refl" "constructor" BuiltinConstructor
      , entry BuiltinLevel "Agda.Primitive.Level" "Type" "universe" BuiltinSort
      , entry BuiltinLevelZero "Agda.Primitive.lzero" "0" "universe" BuiltinPrimitive
      , entry BuiltinLevelSuc "Agda.Primitive.lsuc" "+ 1" "universe" BuiltinPrimitive
      , entry BuiltinLevelMax "Agda.Primitive._⊔_" "max" "universe" BuiltinPrimitive
      , entry BuiltinProp "Agda.Primitive.Prop" "Prop" "universe" BuiltinSort
      , entry BuiltinSet "Agda.Primitive.Set" "Type" "universe" BuiltinSort
      ]

    entry builtin audit target mode kind =
      PlatformMapping
        { platformBuiltin = builtin
        , platformAuditName = audit
        , platformTarget = target
        , platformMode = mode
        , platformComputation = computationFor builtin
        , platformAxiomEffect = NoAxioms
        , platformAxiomDelta = []
        , platformEntityKind = kind
        , platformScope = PlatformProtected
        }

    computationFor builtin =
      case builtin of
        BuiltinEquality -> TheoremBacked
        BuiltinRefl -> TheoremBacked
        BuiltinNatEq -> TranslatedRecursive
        BuiltinNatLt -> TranslatedRecursive
        _ -> NativeDefinitional

platformRegistryLayer :: RegistryLayer
platformRegistryLayer =
  RegistryLayer
    { registryLayerName = "lean4-platform"
    , registryLayerVersion = platformRegistryVersion
    , registryLayerScope = PlatformProtected
    , registryLayerMappings = Map.elems platformMappings
    }

-- | A content digest binds the semantic version to the actual canonical rule
-- set. Map ordering cannot affect this digest.
platformRegistryDigest :: Text
platformRegistryDigest =
  renderObjectHash
    (hashBytes (Text.encodeUtf8 canonicalRegistryText))
  where
    canonicalRegistryText =
      Text.unlines
        [ Text.intercalate
            "\t"
            [ Text.pack (show builtin)
            , platformAuditName mapping
            , platformTarget mapping
            , platformMode mapping
            , Text.pack (show (platformComputation mapping))
            , Text.pack (show (platformAxiomEffect mapping))
            , Text.intercalate "," (platformAxiomDelta mapping)
            , Text.pack (show (platformEntityKind mapping))
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
  , coverageOverrideAllowed :: Bool
  }
  deriving stock (Eq, Ord, Show)

-- | Complete inventory for the BuiltinId surface supported by this compiler.
-- Unsupported future Agda builtins must first receive an explicit BuiltinId and
-- inventory entry; absence is not treated as a fallback mapping.
builtinCoverageInventory :: [BuiltinCoverage]
builtinCoverageInventory =
  [ BuiltinCoverage
      { coverageBuiltin = builtin
      , coverageAgdaKey = platformAuditName mapping
      , coverageEntityKind = platformEntityKind mapping
      , coverageStatus = "native"
      , coverageLeanStrategy = platformMode mapping
      , coverageComputation = platformComputation mapping
      , coverageAxiomDelta = platformAxiomDelta mapping
      , coverageOverrideAllowed = platformScope mapping /= PlatformProtected
      }
  | builtin <- [minBound .. maxBound]
  , let mapping = platformMappings Map.! builtin
  ]

renderBuiltinCoverageInventory :: Text
renderBuiltinCoverageInventory =
  Text.unlines
    ( "builtin-id\tagda-key\tentity-kind\tstatus\tlean-strategy\tcomputation\taxiom-delta\toverride-allowed"
        : [ Text.intercalate
              "\t"
              [ Text.pack (show (coverageBuiltin coverage))
              , coverageAgdaKey coverage
              , Text.pack (show (coverageEntityKind coverage))
              , coverageStatus coverage
              , coverageLeanStrategy coverage
              , Text.pack (show (coverageComputation coverage))
              , if null (coverageAxiomDelta coverage)
                  then "-"
                  else Text.intercalate "," (coverageAxiomDelta coverage)
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
