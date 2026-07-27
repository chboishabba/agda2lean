{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.IR (BuiltinId (..))
import Agda2Lean.Platform
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain
    ( testGroup
        "builtin registry hardening"
        [ inventoryTests
        , compatibilityTests
        , compositionTests
        , determinismTests
        ]
    )

inventoryTests :: TestTree
inventoryTests =
  testGroup
    "coverage inventory"
    [ testCase "classifies every BuiltinId exactly once" $ do
        let expected = [minBound .. maxBound] :: [BuiltinId]
            actual = map coverageBuiltin builtinCoverageInventory
        actual @?= expected
        mapM_ (assertBool "inventory entry is not registered" . (`Map.member` platformMappings)) expected
    , testCase "marks platform semantics as protected" $
        mapM_
          (assertBool "platform builtin unexpectedly allows override" . not . coverageOverrideAllowed)
          builtinCoverageInventory
    , testCase "renders a stable machine-readable inventory" $ do
        assertBool "inventory header missing" ("builtin-id\tagda-key" `Text.isPrefixOf` renderBuiltinCoverageInventory)
        assertBool "equality entry missing" ("BuiltinEquality" `Text.isInfixOf` renderBuiltinCoverageInventory)
    ]

compatibilityTests :: TestTree
compatibilityTests =
  testGroup
    "version compatibility"
    [ testCase "accepts the current compatibility tuple" $
        checkVersionCompatibility currentVersionContext @?= Compatible
    , testCase "rejects codec skew" $
        case checkVersionCompatibility currentVersionContext {versionCodec = 999} of
          Incompatible _ -> pure ()
          result -> assertFailure ("unexpected compatibility result: " <> show result)
    , testCase "requires migration for an older receipt schema" $
        case checkVersionCompatibility currentVersionContext {versionReceiptSchema = 1} of
          MigrationRequired _ -> pure ()
          result -> assertFailure ("unexpected compatibility result: " <> show result)
    , testCase "rejects nominal registry-version skew" $
        case checkVersionCompatibility currentVersionContext {versionRegistry = "lean4-platform-forged"} of
          Incompatible _ -> pure ()
          result -> assertFailure ("unexpected compatibility result: " <> show result)
    ]

compositionTests :: TestTree
compositionTests =
  testGroup
    "validated registry composition"
    [ testCase "accepts the platform layer" $
        composeRegistryLayers ProductionMode [platformRegistryLayer]
          @?= Right platformMappings
    , testCase "rejects duplicate rules within one layer" $ do
        let mapping = platformMappings Map.! BuiltinNat
            duplicateLayer =
              RegistryLayer
                { registryLayerName = "duplicate"
                , registryLayerVersion = "1"
                , registryLayerScope = PlatformProtected
                , registryLayerMappings = [mapping, mapping]
                }
        case composeRegistryLayers ProductionMode [duplicateLayer] of
          Left issues -> assertBool "duplicate was not reported" (any isDuplicate issues)
          Right _ -> assertFailure "duplicate rule was accepted"
    , testCase "rejects project shadowing of a protected builtin" $ do
        let mapping = (platformMappings Map.! BuiltinNat) {platformScope = ProjectScope, platformTarget = "FakeNat"}
            projectLayer =
              RegistryLayer
                { registryLayerName = "project"
                , registryLayerVersion = "1"
                , registryLayerScope = ProjectScope
                , registryLayerMappings = [mapping]
                }
        case composeRegistryLayers ProductionMode [platformRegistryLayer, projectLayer] of
          Left issues -> assertBool "protected override was not reported" (any isProtected issues)
          Right _ -> assertFailure "protected platform mapping was shadowed"
    , testCase "rejects fixture rules outside explicit test mode" $ do
        let mapping = (platformMappings Map.! BuiltinBool) {platformScope = FixtureOnly}
            fixtureLayer =
              RegistryLayer
                { registryLayerName = "fixture"
                , registryLayerVersion = "1"
                , registryLayerScope = FixtureOnly
                , registryLayerMappings = [mapping]
                }
        case composeRegistryLayers ProductionMode [fixtureLayer] of
          Left issues -> assertBool "fixture-mode violation was not reported" (any isFixture issues)
          Right _ -> assertFailure "fixture rule was accepted in production"
    ]
  where
    isDuplicate (DuplicateRule _ _) = True
    isDuplicate _ = False
    isProtected (ProtectedOverride _ _) = True
    isProtected _ = False
    isFixture (FixtureRuleOutsideTestMode _) = True
    isFixture _ = False

determinismTests :: TestTree
determinismTests =
  testGroup
    "determinism"
    [ testCase "registry digest is present and SHA-256 shaped" $
        Text.length platformRegistryDigest @?= 64
    , testCase "mapping insertion order cannot change canonical composition" $ do
        let reversedLayer = platformRegistryLayer {registryLayerMappings = reverse (registryLayerMappings platformRegistryLayer)}
        composeRegistryLayers ProductionMode [reversedLayer]
          @?= composeRegistryLayers ProductionMode [platformRegistryLayer]
    ]
