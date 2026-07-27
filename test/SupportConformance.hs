{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.IR
import Agda2Lean.Support
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain
    ( testGroup
        "feature-indexed support conformance"
        [ testCase "registered builtin is reported" $ do
            let report = inspectSupport registeredBuiltinModule
            assertBool
              "BuiltinNat was not reported as supported"
              (hasRow "builtin-term" "BuiltinNat" SupportedCorrespondence report)
        , testCase "reconstruction boundary is explicit" $ do
            let report = inspectSupport reconstructionModule
            supportOverall report @?= ReconstructionBoundary
            assertBool
              "missing-body reconstruction was not reported"
              (any ((== "reconstruction") . supportCategory) (supportRows report))
        , testCase "cubical feature fails closed" $ do
            let report = inspectSupport cubicalModule
            supportOverall report @?= DeliberatelyUnsupported
            assertBool
              "cubical feature was not classified as deliberately unsupported"
              (hasRow "feature" "Cubical" DeliberatelyUnsupported report)
        , testCase "eliminator remains honestly unclassified" $ do
            let report = inspectSupport eliminatorModule
            supportOverall report @?= Unclassified
            assertBool
              "eliminator was not visible in IR coverage"
              (hasRow "ir" "Eliminator" Unclassified report)
        , testCase "report rendering is deterministic and machine-readable" $ do
            let rendered = renderSupportReport (inspectSupport cubicalModule)
            assertBool "TSV header missing" ("category\titem\tcount\tclassification\tdetail" `Text.isInfixOf` rendered)
            assertBool "overall status missing" ("# overall\tdeliberately-unsupported" `Text.isInfixOf` rendered)
        ]
    )

hasRow :: Text.Text -> Text.Text -> SupportClassification -> SupportReport -> Bool
hasRow category item classification =
  any
    (\row ->
      supportCategory row == category
        && supportItem row == item
        && supportClassification row == classification
    )
    . supportRows

registeredBuiltinModule :: ModuleIR
registeredBuiltinModule =
  baseModule
    { moduleTerms = Map.fromList [(TermId 0, Builtin BuiltinNat)]
    , moduleDeclarations = Vector.singleton (baseDeclaration (TermId 0))
    }

reconstructionModule :: ModuleIR
reconstructionModule =
  baseModule
    { moduleTerms = Map.fromList [(TermId 0, Sort UZero)]
    , moduleDeclarations =
        Vector.singleton
          (baseDeclaration (TermId 0))
            { declarationRole = ComputationalFunction
            , declarationMapping = Reconstruct
            }
    }

cubicalModule :: ModuleIR
cubicalModule =
  baseModule
    { moduleTerms = Map.fromList [(TermId 0, Extension (CubicalPrimitive "primComp" Vector.empty))]
    , moduleDeclarations =
        Vector.singleton
          (baseDeclaration (TermId 0))
            { declarationFeatures = Set.singleton Cubical
            , declarationMapping = Unsupported
            }
    }

eliminatorModule :: ModuleIR
eliminatorModule =
  baseModule
    { moduleTerms = Map.fromList [(TermId 0, Eliminator (CanonicalName "Fixture.rec") Vector.empty)]
    , moduleDeclarations = Vector.singleton (baseDeclaration (TermId 0))
    }

baseModule :: ModuleIR
baseModule =
  ModuleIR
    { moduleSchemaVersion = currentSchemaVersion
    , moduleName = CanonicalName "Conformance.Fixture"
    , moduleImports = Set.empty
    , moduleTerms = Map.empty
    , moduleDeclarations = Vector.empty
    }

baseDeclaration :: TermId -> CoreDeclaration
baseDeclaration typeTerm =
  CoreDeclaration
    { declarationName = CanonicalName "Conformance.Fixture.value"
    , declarationBuiltin = Nothing
    , declarationRole = LogicalProposition
    , declarationUniverses = Vector.empty
    , declarationModuleParameters = Vector.empty
    , declarationType = typeTerm
    , declarationBody = Nothing
    , declarationDependencies = Set.empty
    , declarationFeatures = Set.empty
    , declarationSource = SourceSpan "Conformance/Fixture.agda" 1 1
    , declarationMapping = Exact
    }
