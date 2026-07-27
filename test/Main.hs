{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Catalog
import Agda2Lean.Agda.Extract
import Agda2Lean.Agda.Snapshot
import Agda2Lean.Classify
import Agda2Lean.Codec
import Agda2Lean.Hash
import Agda2Lean.IR
import Agda2Lean.Lean.Emit
import Agda2Lean.Platform (ComputationTreatment (..))
import AgdaFixture
import Control.Exception (SomeException, try)
import Data.Bits (xor)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Data.Word (Word8)
import Database.SQLite.Simple (Only (..), close, execute, open, query_)
import Fixture
import MirrorManifest (mirrorManifestTests)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain
    ( testGroup
        "agda2lean"
        [ codecTests
        , extractionTests
        , leanEmitterTests
        , mirrorManifestTests
        , validationTests
        , classificationTests
        , catalogTests
        ]
    )

codecTests :: TestTree
codecTests =
  testGroup
    "canonical CBOR"
    [ testCase "round trips a module" $
        decodeModule (encodeModule exampleModule)
          @?= Right exampleModule
    , testCase "Map insertion order does not affect bytes" $
        encodeModule exampleModuleReordered
          @?= encodeModule exampleModule
    , testCase "semantic hash follows canonical bytes" $
        moduleObjectHash exampleModuleReordered
          @?= moduleObjectHash exampleModule
    , testCase "semantic hash matches the codec-v3 golden object" $
        renderObjectHash (moduleObjectHash exampleModule)
          @?= "7eeb8aba83ae0e642977926cd6c38ad9ffd9820ed01bdf72bb88a0314f375fd3"
    , testCase "rejects trailing bytes" $
        case decodeModule (encodeModule exampleModule <> "\NUL") of
          Left _ -> pure ()
          Right _ -> assertFailure "trailing data was accepted"
    , testCase "rejects oversized container headers before allocation" $ do
        let encoded = encodeModule exampleModule
            oversizedLength = ByteString.pack [0x9a, 0x00, 0x98, 0x96, 0x81]
            hostile = oversizedLength <> ByteString.drop 1 encoded
        case decodeModule hostile of
          Left _ -> pure ()
          Right _ -> assertFailure "oversized container was accepted"
    ]

extractionTests :: TestTree
extractionTests =
  testGroup
    "Agda elaborated extraction"
    [ testCase "normalizes binders and discovers direct dependencies" $
        case extractModule identitySnapshot of
          Left issue -> assertFailure (show issue)
          Right moduleIR -> do
            let declaration = Vector.head (moduleDeclarations moduleIR)
            declarationDependencies declaration
              @?= Set.singleton (CanonicalName "DASHI.Example.Carrier")
            declarationMapping declaration @?= Exact
            validateModule moduleIR @?= Right moduleIR
    , testCase "preserves dependencies discovered in omitted clause bodies" $
        let declaration =
              Vector.head (agdaModuleDeclarations identitySnapshot)
            helper = CanonicalName "DASHI.Proof.Helper"
            bodyless =
              identitySnapshot
                { agdaModuleDeclarations =
                    Vector.singleton
                      declaration
                        { agdaDeclarationBody = Nothing
                        , agdaDeclarationAdditionalDependencies =
                            Set.singleton helper
                        }
                }
         in case extractModule bodyless of
              Left issue -> assertFailure (show issue)
              Right moduleIR ->
                declarationDependencies
                  (Vector.head (moduleDeclarations moduleIR))
                  @?= Set.fromList
                    [ CanonicalName "DASHI.Example.Carrier"
                    , helper
                    ]
    , testCase "rejects an out-of-scope de Bruijn variable" $
        let declaration =
              Vector.head (agdaModuleDeclarations identitySnapshot)
            invalid =
              identitySnapshot
                { agdaModuleDeclarations =
                    Vector.singleton
                      declaration
                        { agdaDeclarationBody = Just (AgdaVar 3 Vector.empty)
                        }
                }
         in case extractModule invalid of
              Left UnboundDeBruijnIndex {} -> pure ()
              Left issue -> assertFailure ("unexpected error: " <> show issue)
              Right _ -> assertFailure "unbound de Bruijn variable was accepted"
    ]

leanEmitterTests :: TestTree
leanEmitterTests =
  testGroup
    "Lean facade emitter"
    [ testCase "emits an exact Agda-shaped facade without sorry" $
        case extractModule identitySnapshot of
          Left issue -> assertFailure (show issue)
          Right moduleIR -> do
            let output = emitLeanModule defaultEmitOptions moduleIR
            assertBool
              "original declaration name is not traceable"
              ("-- Agda: DASHI.Example.Identity.identity" `Text.isInfixOf` leanSource output)
            assertBool
              "exact identity was not emitted"
              ("def identity" `Text.isInfixOf` leanSource output)
            assertBool
              "exact output contains sorry"
              (not ("sorry" `Text.isInfixOf` leanSource output))
    , testCase "pins the Agda.Builtin.Equality shim shape" $ do
        let output = emitLeanModule defaultEmitOptions builtinEqualityModule
        assertBool
          "equality definition missing"
          ("def «_≡_» {α : Type} (x y : α) : Prop := Eq x y"
            `Text.isInfixOf` leanSource output)
        assertBool
          "refl theorem missing"
          ("theorem «_≡_».refl {α : Type} {x : α} : «_≡_» x x := rfl"
            `Text.isInfixOf` leanSource output)
        assertBool
          "equality shim emitted diagnostics unexpectedly"
          (Vector.null (leanDiagnostics output))
    , testCase "records deterministic builtin semantic receipts" $ do
        let output = emitLeanModule defaultEmitOptions builtinEqualityModule
            receipts = leanBuiltinReceipts output
            equalityReceipt = Vector.head receipts
        Vector.length receipts @?= 2
        builtinReceiptAgdaBinding equalityReceipt
          @?= "Agda.Builtin.Equality._≡_"
        builtinReceiptRegistryVersion equalityReceipt @?= "lean4-platform-v1"
        builtinReceiptRule equalityReceipt @?= Just "ordinary-equality"
        builtinReceiptLeanTarget equalityReceipt @?= Just "Eq"
        builtinReceiptComputation equalityReceipt @?= Just TheoremBacked
        builtinReceiptStatus equalityReceipt @?= "mapped"
        assertBool
          "receipt rendering omitted its semantic fields"
          ( and
              [ "builtin-id" `Text.isInfixOf` renderBuiltinReceipts receipts
              , "Agda.Builtin.Equality._≡_" `Text.isInfixOf` renderBuiltinReceipts receipts
              , "TheoremBacked" `Text.isInfixOf` renderBuiltinReceipts receipts
              ]
          )
    , testCase "records a blocked lowering instead of hiding it" $ do
        let declaration = Vector.head (moduleDeclarations builtinEqualityModule)
            blockedModule =
              builtinEqualityModule
                { moduleDeclarations =
                    Vector.singleton
                      declaration {declarationBuiltin = Just BuiltinLevelZero}
                }
            output = emitLeanModule defaultEmitOptions blockedModule
            receipt = Vector.head (leanBuiltinReceipts output)
        builtinReceiptStatus receipt @?= "blocked"
        builtinReceiptRule receipt @?= Just "universe"
        assertBool
          "blocked builtin did not produce an error"
          ( Vector.any
              ((== "A2L-E-BUILTIN") . diagnosticCode)
              (leanDiagnostics output)
          )
    , testCase "pins the Agda.Builtin.Nat OfNat shim" $ do
        let output = emitLeanModule defaultEmitOptions builtinNatModule
        assertBool
          "Nat OfNat instance missing"
          ("noncomputable instance (n : _root_.Nat) : OfNat Nat n := ⟨Nat.zero⟩"
            `Text.isInfixOf` leanSource output)
        assertBool
          "Nat shim emitted diagnostics unexpectedly"
          (Vector.null (leanDiagnostics output))
    , testCase "makes reconstruction boundaries explicit and machine visible" $
        case extractModule reconstructSnapshot of
          Left issue -> assertFailure (show issue)
          Right moduleIR -> do
            let output = emitLeanModule defaultEmitOptions moduleIR
            assertBool "reconstruction body lacks sorry" ("sorry" `Text.isInfixOf` leanSource output)
            assertBool
              "reconstruction diagnostic missing"
              ( Vector.any
                  ((== "A2L-W-RECONSTRUCT") . diagnosticCode)
                  (leanDiagnostics output)
              )
    , testCase "can fail closed instead of emitting reconstruction sorries" $
        case extractModule reconstructSnapshot of
          Left issue -> assertFailure (show issue)
          Right moduleIR -> do
            let output =
                  emitLeanModule
                    defaultEmitOptions {emitSorryBodies = False}
                    moduleIR
            assertBool
              "fail-closed diagnostic missing"
              ( Vector.any
                  ((== Error) . diagnosticSeverity)
                  (leanDiagnostics output)
              )
    ]

builtinNatModule :: ModuleIR
builtinNatModule =
  exampleModule
    { moduleName = CanonicalName "Agda.Builtin.Nat"
    , moduleImports =
        Set.fromList
          [ CanonicalName "Agda.Builtin.Bool"
          , CanonicalName "Agda.Primitive"
          ]
    , moduleDeclarations = Vector.empty
    , moduleTerms = Map.empty
    }

builtinEqualityModule :: ModuleIR
builtinEqualityModule =
  ModuleIR
    { moduleSchemaVersion = currentSchemaVersion
    , moduleName = CanonicalName "Agda.Builtin.Equality"
    , moduleImports = Set.singleton (CanonicalName "Agda.Primitive")
    , moduleTerms = Map.empty
    , moduleDeclarations =
        Vector.fromList
          [ CoreDeclaration
              { declarationName = CanonicalName "Agda.Builtin.Equality._≡_"
              , declarationBuiltin = Just BuiltinEquality
              , declarationRole = AxiomDeclaration
              , declarationUniverses = Vector.empty
              , declarationModuleParameters = Vector.empty
              , declarationType = TermId 0
              , declarationBody = Nothing
              , declarationDependencies = Set.empty
              , declarationFeatures = Set.empty
              , declarationSource = SourceSpan "Agda/Builtin/Equality.agda" 1 1
              , declarationMapping = Exact
              }
          , CoreDeclaration
              { declarationName = CanonicalName "Agda.Builtin.Equality._≡_.refl"
              , declarationBuiltin = Just BuiltinRefl
              , declarationRole = Theorem
              , declarationUniverses = Vector.empty
              , declarationModuleParameters = Vector.empty
              , declarationType = TermId 0
              , declarationBody = Nothing
              , declarationDependencies = Set.empty
              , declarationFeatures = Set.empty
              , declarationSource = SourceSpan "Agda/Builtin/Equality.agda" 2 2
              , declarationMapping = Exact
              }
          ]
    }

validationTests :: TestTree
validationTests =
  testGroup
    "validation"
    [ testCase "rejects a missing declaration type" $
        case
            validateModule
              exampleModule
                { moduleTerms =
                    Map.delete (TermId 2) (moduleTerms exampleModule)
                }
          of
            Left _ -> pure ()
            Right _ -> assertFailure "missing declaration type was accepted"
    , testCase "unsupported declarations cannot carry bodies" $
        let declarations = moduleDeclarations exampleModule
            declaration = Vector.head declarations
            invalid =
              exampleModule
                { moduleDeclarations =
                    Vector.singleton
                      declaration {declarationMapping = Unsupported}
                }
         in case validateModule invalid of
              Left _ -> pure ()
              Right _ -> assertFailure "unsupported proof body was accepted"
    , testCase "declarations must belong to their module namespace" $
        let declaration = Vector.head (moduleDeclarations exampleModule)
            invalid =
              exampleModule
                { moduleDeclarations =
                    Vector.singleton
                      declaration
                        { declarationName = CanonicalName "Other.identity"
                        }
                }
         in case validateModule invalid of
              Left _ -> pure ()
              Right _ -> assertFailure "cross-module declaration name was accepted"
    ]

classificationTests :: TestTree
classificationTests =
  testGroup
    "feature classification"
    [ testCase "ordinary definitions remain exact" $
        classificationMode
          ( classifyDeclaration
              exampleModule
              (Vector.head (moduleDeclarations exampleModule))
          )
          @?= Exact
    , testCase "Cubical terms are quarantined" $
        let cubicalTermId = TermId 5
            terms =
              Map.insert
                cubicalTermId
                (Extension (CubicalPrimitive "comp" Vector.empty))
                (moduleTerms exampleModule)
            declaration =
              (Vector.head (moduleDeclarations exampleModule))
                { declarationType = cubicalTermId
                , declarationBody = Nothing
                }
            cubicalModule =
              exampleModule
                { moduleTerms = terms
                , moduleDeclarations = Vector.singleton declaration
                }
         in classificationMode
              (classifyDeclaration cubicalModule declaration)
              @?= Quarantined
    , testCase "module parameter features cannot bypass classification" $
        let cubicalTermId = TermId 5
            terms =
              Map.insert
                cubicalTermId
                (Extension (CubicalPrimitive "interval" Vector.empty))
                (moduleTerms exampleModule)
            declaration =
              (Vector.head (moduleDeclarations exampleModule))
                { declarationModuleParameters =
                    Vector.singleton
                      Binder
                        { binderId = BinderId 99
                        , binderName = "I"
                        , binderType = cubicalTermId
                        , binderVisibility = Implicit
                        , binderRelevance = Relevant
                        }
                }
            parameterModule =
              exampleModule
                { moduleTerms = terms
                , moduleDeclarations = Vector.singleton declaration
                }
         in classificationMode
              (classifyDeclaration parameterModule declaration)
              @?= Quarantined
    ]

catalogTests :: TestTree
catalogTests =
  testGroup
    "SQLite catalog"
    [ testCase "deduplicates immutable module objects" $
        withSystemTempDirectory "agda2lean-test" $ \directory -> do
          let path = directory </> "catalog.sqlite"
          catalog <- openCatalog path
          firstHash <- storeModule catalog exampleModule
          secondHash <- storeModule catalog exampleModule
          stats <- readCatalogStats catalog
          fetched <-
            getModule catalog (CanonicalName "DASHI.Example.Identity")
          closeCatalog catalog
          firstHash @?= secondHash
          statsModules stats @?= 1
          statsObjects stats @?= 1
          statsDeclarations stats @?= 1
          fetched @?= Just exampleModule
    , testCase "atomically replaces a module head and its indexes" $
        withSystemTempDirectory "agda2lean-test" $ \directory -> do
          let path = directory </> "catalog.sqlite"
              declaration =
                (Vector.head (moduleDeclarations exampleModule))
                  { declarationDependencies =
                      Set.singleton (CanonicalName "DASHI.New.Helper")
                  }
              updated =
                exampleModule
                  { moduleImports =
                      Set.singleton (CanonicalName "DASHI.New.Import")
                  , moduleDeclarations = Vector.singleton declaration
                  }
          catalog <- openCatalog path
          originalHash <- storeModule catalog exampleModule
          updatedHash <- storeModule catalog updated
          fetched <-
            getModule catalog (CanonicalName "DASHI.Example.Identity")
          closeCatalog catalog
          assertBool "module head did not advance" (originalHash /= updatedHash)
          fetched @?= Just updated

          raw <- open path
          [Only importCount] <-
            query_ raw "SELECT COUNT(*) FROM module_imports" :: IO [Only Int]
          [Only dependencyCount] <-
            query_ raw "SELECT COUNT(*) FROM direct_dependencies" :: IO [Only Int]
          [Only oldImportCount] <-
            query_
              raw
              "SELECT COUNT(*) FROM module_imports WHERE imported_module_name = 'Agda.Primitive'" ::
              IO [Only Int]
          [Only oldDependencyCount] <-
            query_
              raw
              "SELECT COUNT(*) FROM direct_dependencies WHERE dependency_name = 'DASHI.Example.Carrier'" ::
              IO [Only Int]
          close raw
          importCount @?= 1
          dependencyCount @?= 1
          oldImportCount @?= 0
          oldDependencyCount @?= 0
    , testCase "detects corrupted stored objects" $
        withSystemTempDirectory "agda2lean-test" $ \directory -> do
          let path = directory </> "catalog.sqlite"
          catalog <- openCatalog path
          ObjectHash objectHash <- storeModule catalog exampleModule
          closeCatalog catalog

          raw <- open path
          let original = encodeModule exampleModule
              corrupted =
                ByteString.cons
                  (ByteString.head original `xorByte` 1)
                  (ByteString.tail original)
          execute
            raw
            "UPDATE ir_objects SET cbor = ?, byte_length = ? WHERE object_hash = ?"
            (corrupted, ByteString.length corrupted, objectHash)
          close raw

          reopened <- openCatalog path
          issues <- verifyCatalog reopened
          closeCatalog reopened
          assertBool "corruption was not detected" (not (null issues))
    , testCase "rejects catalogs from a different codec version" $
        withSystemTempDirectory "agda2lean-test" $ \directory -> do
          let path = directory </> "catalog.sqlite"
          catalog <- openCatalog path
          closeCatalog catalog
          raw <- open path
          execute
            raw
            "UPDATE catalog_meta SET value = '999' WHERE key = 'codec_version'"
            ()
          close raw
          opened <- try (openCatalog path) :: IO (Either SomeException Catalog)
          case opened of
            Left _ -> pure ()
            Right unexpected -> do
              closeCatalog unexpected
              assertFailure "catalog codec mismatch was accepted"
    ]

xorByte :: Word8 -> Word8 -> Word8
xorByte = xor
