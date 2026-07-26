{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Catalog
import Agda2Lean.Classify
import Agda2Lean.Codec
import Agda2Lean.Hash
import Agda2Lean.IR
import Data.Bits (xor)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Vector as Vector
import Data.Word (Word8)
import Database.SQLite.Simple (close, execute, open)
import Fixture
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
    , testCase "rejects trailing bytes" $
        case decodeModule (encodeModule exampleModule <> "\NUL") of
          Left _ -> pure ()
          Right _ -> assertFailure "trailing data was accepted"
    ]

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
    ]

xorByte :: Word8 -> Word8 -> Word8
xorByte = xor
