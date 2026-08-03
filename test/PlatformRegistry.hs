{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.IR
import Agda2Lean.Lean.Checked (emitLeanModuleChecked)
import Agda2Lean.Lean.Emit
import Agda2Lean.Platform
import Agda2Lean.Registry.File (parseRegistryLayer, renderRegistryLayer)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Vector as Vector
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
        , registryFileTests
        , checkedEmissionTests
        , semanticLoweringTests
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
    , testCase "rejects a wrong entity kind before lowering" $ do
        let mapping =
              (platformMappings Map.! BuiltinNat)
                { platformScope = ProjectScope
                , platformEntityKind = BuiltinFunction
                }
            projectLayer =
              RegistryLayer
                { registryLayerName = "wrong-kind"
                , registryLayerVersion = "1"
                , registryLayerScope = ProjectScope
                , registryLayerMappings = [mapping]
                }
        case composeRegistryLayers ProductionMode [platformRegistryLayer, projectLayer] of
          Left issues -> assertBool "kind mismatch was not reported" (any isKindMismatch issues)
          Right _ -> assertFailure "wrong-kind mapping was accepted"
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
    isKindMismatch (KindMismatch _ _ _) = True
    isKindMismatch _ = False
    isFixture (FixtureRuleOutsideTestMode _) = True
    isFixture _ = False

registryFileTests :: TestTree
registryFileTests =
  testGroup
    "registry files"
    [ testCase "round-trips a deterministic registry layer" $
        parseRegistryLayer (renderRegistryLayer libraryLayer) @?= Right libraryLayer
    , testCase "rejects unknown builtin identifiers" $
        case parseRegistryLayer invalidLayerText of
          Left message -> assertBool "missing parse context" ("unknown BuiltinId" `Text.isInfixOf` message)
          Right _ -> assertFailure "unknown BuiltinId was accepted"
    ]
  where
    libraryLayer =
      RegistryLayer
        { registryLayerName = "empty-library"
        , registryLayerVersion = "1"
        , registryLayerScope = LibraryScope
        , registryLayerMappings = []
        }
    invalidLayerText =
      Text.unlines
        [ "# registry-name\tinvalid"
        , "# registry-version\t1"
        , "# registry-scope\tLibraryScope"
        , "builtin-id\tagda-binding\tlean-target\trule\tcomputation\taxiom-effect\taxiom-delta\tentity-kind\targument-policy"
        , "BuiltinDoesNotExist\tX\tX\texact\tNativeDefinitional\tNoAxioms\t-\tBuiltinFunction\tpreserve"
        ]

checkedEmissionTests :: TestTree
checkedEmissionTests =
  testGroup
    "checked emission"
    [ testCase "missing declaration mapping blocks an otherwise native builtin" $
        case
            emitLeanModuleChecked
              currentVersionContext
              defaultEmitOptions {emitRegistry = Map.empty}
              builtinNatDeclarationModule
          of
            Left message ->
              assertBool
                "missing declaration registry coverage was not explained"
                ("BuiltinNat" `Text.isInfixOf` message)
            Right _ -> assertFailure "BuiltinNat declaration emitted without an effective mapping"
    , testCase "missing term mapping blocks the low-level renderer" $
        case
            emitLeanModuleChecked
              currentVersionContext
              defaultEmitOptions {emitRegistry = Map.empty}
              builtinNatTermModule
          of
            Left message ->
              assertBool
                "missing term registry coverage was not explained"
                ("BuiltinNat" `Text.isInfixOf` message)
            Right _ -> assertFailure "BuiltinNat term rendered without an effective mapping"
    , testCase "divergent term target is rejected before rendering" $
        let divergentRegistry =
              Map.adjust
                (\mapping -> mapping {platformTarget = "FakeNat"})
                BuiltinNat
                platformMappings
         in case
              emitLeanModuleChecked
                currentVersionContext
                defaultEmitOptions {emitRegistry = divergentRegistry}
                builtinNatTermModule
              of
                Left message ->
                  assertBool
                    "renderer divergence was not explained"
                    ("term renderer" `Text.isInfixOf` message)
                Right _ -> assertFailure "divergent effective target bypassed checked emission"
    ]

semanticLoweringTests :: TestTree
semanticLoweringTests =
  testGroup
    "semantic lowering"
    [ testCase "List family has complete native mappings" $ do
        platformTarget (platformMappings Map.! BuiltinList) @?= "List"
        platformTarget (platformMappings Map.! BuiltinListNil) @?= "List.nil"
        platformTarget (platformMappings Map.! BuiltinListCons) @?= "List.cons"
        platformArgumentPolicy (platformMappings Map.! BuiltinList)
          @?= ProjectArguments 2 (Vector.singleton 1)
        platformArgumentPolicy (platformMappings Map.! BuiltinListCons)
          @?= ProjectArguments 4 (Vector.fromList [1, 2, 3])
    , testCase "erases Agda's hidden List level and retains its element type" $ do
        let output = emitLeanModule defaultEmitOptions listApplicationModule
        assertBool
          "List application did not project the hidden source spine"
          ("(@List Nat)" `Text.isInfixOf` leanSource output)
        assertBool
          "erased level leaked into the Lean application"
          (not ("@List 0 Nat" `Text.isInfixOf` leanSource output))
    , testCase "renders structured first-class level expressions" $ do
        let output = emitLeanModule defaultEmitOptions levelExpressionModule
        assertBool
          "level maximum/successor was not rendered as universe syntax"
          ("(max 0 (0 + 1))" `Text.isInfixOf` leanSource output)
    , testCase "projects Eq.refl's level argument and preserves hidden arguments" $ do
        let output = emitLeanModule defaultEmitOptions reflApplicationModule
        assertBool
          "Eq.refl source spine was not projected"
          ("(@Eq.refl Nat x)" `Text.isInfixOf` leanSource output)
        assertBool
          "proposition-shaped function was not emitted as a theorem"
          ("theorem proof" `Text.isInfixOf` leanSource output)
    , testCase "under-applied argument policies fail closed" $ do
        let output = emitLeanModule defaultEmitOptions underAppliedListModule
        assertBool
          "under-application diagnostic missing"
          (any ((== Error) . diagnosticSeverity) (Vector.toList (leanDiagnostics output)))
        assertBool "under-applied builtin was not blocked" ("-- BLOCKED" `Text.isInfixOf` leanSource output)
        assertBool "default emission introduced sorry" (not ("sorry" `Text.isInfixOf` leanSource output))
    ]

listApplicationModule :: ModuleIR
listApplicationModule =
  simpleTermModule
    "Example.ListApplication"
    (Map.fromList
      [ (TermId 0, Builtin BuiltinList)
      , (TermId 1, Level LevelZero)
      , (TermId 2, Builtin BuiltinNat)
      , (TermId 3, App (TermId 0) (Argument Implicit Relevant (TermId 1)))
      , (TermId 4, App (TermId 3) (Argument Implicit Relevant (TermId 2)))
      ])
    (TermId 4)
    AxiomDefinition

underAppliedListModule :: ModuleIR
underAppliedListModule =
  simpleTermModule
    "Example.UnderAppliedList"
    (Map.fromList
      [ (TermId 0, Builtin BuiltinList)
      , (TermId 1, Level LevelZero)
      , (TermId 2, App (TermId 0) (Argument Implicit Relevant (TermId 1)))
      ])
    (TermId 2)
    AxiomDefinition

levelExpressionModule :: ModuleIR
levelExpressionModule =
  simpleTermModule
    "Example.LevelExpression"
    (Map.singleton
      (TermId 0)
      (Level (LevelMaximum (Vector.fromList [LevelZero, LevelSuccessor LevelZero]))))
    (TermId 0)
    AxiomDefinition

reflApplicationModule :: ModuleIR
reflApplicationModule =
  simpleTermModule
    "Example.ReflApplication"
    terms
    (TermId 4)
    (TermDefinition (TermId 10))
  where
    binder = Binder (BinderId 0) "x" (TermId 0) Explicit Relevant
    terms =
      Map.fromList
        [ (TermId 0, Builtin BuiltinNat)
        , (TermId 1, Var (BinderId 0))
        , (TermId 2, Equality (TermId 0) (TermId 1) (TermId 1))
        , (TermId 3, Pi binder (TermId 2))
        , (TermId 4, Pi binder (TermId 2))
        , (TermId 5, Builtin BuiltinRefl)
        , (TermId 6, Level LevelZero)
        , (TermId 7, App (TermId 5) (Argument Implicit Relevant (TermId 6)))
        , (TermId 8, App (TermId 7) (Argument Implicit Relevant (TermId 0)))
        , (TermId 9, App (TermId 8) (Argument Implicit Relevant (TermId 1)))
        , (TermId 10, Lam binder (TermId 9))
        ]

simpleTermModule :: Text.Text -> Map.Map TermId CoreTerm -> TermId -> DeclarationDefinition -> ModuleIR
simpleTermModule moduleText terms typeId definition =
  ModuleIR
    { moduleSchemaVersion = currentSchemaVersion
    , moduleName = CanonicalName moduleText
    , moduleImports = Set.empty
    , moduleTerms = terms
    , moduleDeclarations =
        Vector.singleton
          CoreDeclaration
            { declarationName = CanonicalName (moduleText <> ".proof")
            , declarationBuiltin = Nothing
            , declarationRole =
                case definition of
                  AxiomDefinition -> AxiomDeclaration
                  _ -> ComputationalFunction
            , declarationUniverses = Vector.empty
            , declarationModuleParameters = Vector.empty
            , declarationType = typeId
            , declarationDefinition = definition
            , declarationDependencies = Set.empty
            , declarationFeatures = Set.empty
            , declarationSource = SourceSpan "fixture.agda" 1 1
            , declarationMapping = Exact
            }
    }

builtinNatDeclarationModule :: ModuleIR
builtinNatDeclarationModule =
  ModuleIR
    { moduleSchemaVersion = currentSchemaVersion
    , moduleName = CanonicalName "Agda.Builtin.Nat"
    , moduleImports = Set.empty
    , moduleTerms = Map.empty
    , moduleDeclarations =
        Vector.singleton
          CoreDeclaration
            { declarationName = CanonicalName "Agda.Builtin.Nat.Nat"
            , declarationBuiltin = Just BuiltinNat
            , declarationRole = ComputationalData
            , declarationUniverses = Vector.empty
            , declarationModuleParameters = Vector.empty
            , declarationType = TermId 0
            , declarationDefinition = AxiomDefinition
            , declarationDependencies = Set.empty
            , declarationFeatures = Set.empty
            , declarationSource = SourceSpan "Agda/Builtin/Nat.agda" 1 1
            , declarationMapping = Exact
            }
    }

builtinNatTermModule :: ModuleIR
builtinNatTermModule =
  ModuleIR
    { moduleSchemaVersion = currentSchemaVersion
    , moduleName = CanonicalName "Example.BuiltinTerm"
    , moduleImports = Set.empty
    , moduleTerms = Map.singleton (TermId 0) (Builtin BuiltinNat)
    , moduleDeclarations =
        Vector.singleton
          CoreDeclaration
            { declarationName = CanonicalName "Example.BuiltinTerm.value"
            , declarationBuiltin = Nothing
            , declarationRole = ComputationalFunction
            , declarationUniverses = Vector.empty
            , declarationModuleParameters = Vector.empty
            , declarationType = TermId 0
            , declarationDefinition = AxiomDefinition
            , declarationDependencies = Set.empty
            , declarationFeatures = Set.empty
            , declarationSource = SourceSpan "Example/BuiltinTerm.agda" 1 1
            , declarationMapping = Exact
            }
    }

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
