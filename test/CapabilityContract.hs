{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Catalog
import Fixture (exampleModule)
import qualified Data.Text as Text
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "agda2lean declaration capability"
      [ testCase "catalog exposes mapping/source/dependencies without proof promotion" testCapability
      , testCase "unknown declaration returns Nothing" testMissing
      ]

testCapability :: Assertion
testCapability =
  withSystemTempDirectory "a2l-capability" $ \directory -> do
    let database = directory </> "catalog.sqlite3"
        checked = Text.replicate 64 "a"
    catalog <- openCatalog database
    _ <- storeModuleWithSourceHash catalog (Just checked) exampleModule
    capability <- getDeclarationCapability catalog "DASHI.Example.Identity.identity"
    closeCatalog catalog
    case capability of
      Nothing -> assertFailure "expected declaration capability"
      Just item -> do
        capabilityDeclarationName item @?= "DASHI.Example.Identity.identity"
        capabilityModuleName item @?= "DASHI.Example.Identity"
        capabilityRole item @?= "computational-function"
        capabilityMappingMode item @?= "exact"
        capabilityCheckedSourceSha256 item @?= Just checked
        capabilitySourceFile item @?= "DASHI/Example/Identity.agda"
        capabilitySourceStartLine item @?= 5
        capabilitySourceEndLine item @?= 6
        capabilityDirectDependencies item @?= ["DASHI.Example.Carrier"]
        capabilityEstablishesProof item @?= False

testMissing :: Assertion
testMissing =
  withSystemTempDirectory "a2l-capability-missing" $ \directory -> do
    catalog <- openCatalog (directory </> "catalog.sqlite3")
    capability <- getDeclarationCapability catalog "DASHI.Missing.nope"
    closeCatalog catalog
    capability @?= Nothing
