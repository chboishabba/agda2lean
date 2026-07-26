{-# LANGUAGE OverloadedStrings #-}

module MirrorManifest
  ( mirrorManifestTests
  ) where

import Agda2Lean.Mirror.Manifest
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

mirrorManifestTests :: TestTree
mirrorManifestTests =
  testGroup
    "mirror manifest"
    [ testCase "parses the checked-in DASHI registry" $ do
        input <- Text.readFile "fixtures/dashi-mirrors.toml"
        case parseMirrorManifest input of
          Left issue -> assertFailure (Text.unpack (renderManifestError issue))
          Right manifest -> do
            manifestSchemaVersion manifest @?= 1
            map fixtureId (manifestFixtures manifest)
              @?= map FixtureId ["moonshine", "crtj-fixed-point", "constraint-closure"]
    , testCase "parses a pinned CRTJ fixture" $
        case parseMirrorManifest validManifest of
          Left issue -> assertFailure (Text.unpack (renderManifestError issue))
          Right manifest -> do
            manifestSchemaVersion manifest @?= 1
            length (manifestFixtures manifest) @?= 1
            let fixture = head (manifestFixtures manifest)
            fixtureId fixture @?= FixtureId "crtj-fixed-point"
            agdaRevision (fixtureAgda fixture) @?= agdaSha
            leanRevision (fixtureLean fixture) @?= leanSha
            leanFiles (fixtureLean fixture)
              @?= [ StagedFile
                      "CRTJFixedPointBridge.lean"
                      "AgdaMirror/CRTJFixedPointBridge.lean"
                  ]
            map declarationExpectation (fixtureDeclarations fixture)
              @?= [ExpectPass]
    , testCase "parses an expected structural block" $
        case
            parseMirrorManifest
              ( fixtureManifest
                  "constraint-closure-structure"
                  "DASHI/Algebra/Quantum/ConstraintClosure.agda"
                  "ConstraintClosure.lean"
                  "DASHI.Algebra.Quantum.ConstraintClosure.ConstraintClosureAxioms"
                  "AgdaMirror.ConstraintClosure.ConstraintClosureAxioms"
                  "structure"
                  "blocked"
                  (Just "A2L-E-STRUCTURE-SHAPE")
              )
          of
            Left issue -> assertFailure (Text.unpack (renderManifestError issue))
            Right manifest ->
              map declarationExpectation
                (fixtureDeclarations (head (manifestFixtures manifest)))
                @?= [ExpectBlocked "A2L-E-STRUCTURE-SHAPE"]
    , testCase "rejects unsupported schema versions" $
        assertErrorCode
          "A2L-MANIFEST-SCHEMA"
          (Text.replace "schema-version = 1" "schema-version = 2" validManifest)
    , testCase "rejects a short or symbolic Git ref" $
        assertErrorCode
          "A2L-MANIFEST-REVISION"
          (Text.replace agdaSha "main" validManifest)
    , testCase "rejects uppercase Git object IDs" $
        assertErrorCode
          "A2L-MANIFEST-REVISION"
          (Text.replace agdaSha (Text.toUpper agdaSha) validManifest)
    , testCase "rejects source path traversal" $
        assertErrorCode
          "A2L-MANIFEST-PATH"
          ( Text.replace
              "CRTJFixedPointBridge.agda"
              "../CRTJFixedPointBridge.agda"
              validManifest
          )
    , testCase "rejects staged path traversal" $
        assertErrorCode
          "A2L-MANIFEST-PATH"
          ( Text.replace
              "AgdaMirror/CRTJFixedPointBridge.lean"
              "../AgdaMirror/CRTJFixedPointBridge.lean"
              validManifest
          )
    , testCase "rejects duplicate fixture IDs" $
        let first =
              fixtureBlock
                "crtj-fixed-point"
                "CRTJFixedPointBridge.agda"
                "CRTJFixedPointBridge.lean"
                "CRTJFixedPointBridge.period-plus-one"
                "AgdaMirror.CRTJFixedPointBridge.period_plus_one"
                "theorem"
                "pass"
                Nothing
            second =
              fixtureBlock
                "crtj-fixed-point"
                "Other.agda"
                "Other.lean"
                "Other.source"
                "Other.target"
                "theorem"
                "pass"
                Nothing
         in assertErrorCode
              "A2L-MANIFEST-DUPLICATE-FIXTURE"
              ("schema-version = 1\n" <> first <> second)
    , testCase "rejects duplicate Agda declaration symbols" $
        assertErrorCode
          "A2L-MANIFEST-DUPLICATE-AGDA-SYMBOL"
          ( validManifest
              <> declarationBlock
                "CRTJFixedPointBridge.period-plus-one"
                "AgdaMirror.CRTJFixedPointBridge.another"
                "theorem"
                "pass"
                Nothing
          )
    , testCase "rejects duplicate Lean declaration symbols" $
        assertErrorCode
          "A2L-MANIFEST-DUPLICATE-LEAN-SYMBOL"
          ( validManifest
              <> declarationBlock
                "CRTJFixedPointBridge.another"
                "AgdaMirror.CRTJFixedPointBridge.period_plus_one"
                "theorem"
                "pass"
                Nothing
          )
    , testCase "rejects duplicate mapping sources" $
        assertErrorCode
          "A2L-MANIFEST-DUPLICATE-MAPPING-SOURCE"
          ( validManifest
              <> mappingBlock "Agda.Builtin.Nat.Nat" "Nat" "semantic"
              <> mappingBlock "Agda.Builtin.Nat.Nat" "NatAlias" "semantic"
          )
    , testCase "rejects duplicate scalar fields" $
        assertErrorCode
          "A2L-MANIFEST-DUPLICATE-FIELD"
          (Text.replace "tier = \"smoke\"" "tier = \"smoke\"\ntier = \"pilot\"" validManifest)
    ]

assertErrorCode :: Text.Text -> Text.Text -> Assertion
assertErrorCode expected input =
  case parseMirrorManifest input of
    Left issue -> manifestErrorCode issue @?= expected
    Right _ -> assertFailure ("expected manifest error " <> Text.unpack expected)

validManifest :: Text.Text
validManifest =
  fixtureManifest
    "crtj-fixed-point"
    "CRTJFixedPointBridge.agda"
    "CRTJFixedPointBridge.lean"
    "CRTJFixedPointBridge.period-plus-one"
    "AgdaMirror.CRTJFixedPointBridge.period_plus_one"
    "theorem"
    "pass"
    Nothing

fixtureManifest ::
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Maybe Text.Text ->
  Text.Text
fixtureManifest identifier agdaPath leanPath source target kind expected expectedCode =
  "schema-version = 1\n"
    <> fixtureBlock
      identifier
      agdaPath
      leanPath
      source
      target
      kind
      expected
      expectedCode

fixtureBlock ::
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Maybe Text.Text ->
  Text.Text
fixtureBlock identifier agdaPath leanPath source target kind expected expectedCode =
  Text.unlines
    [ "[[fixture]]"
    , "id = " <> quoted identifier
    , "tier = \"smoke\""
    , ""
    , "[fixture.agda]"
    , "repo = \"../dashi_agda\""
    , "ref = " <> quoted agdaSha
    , "module = \"CRTJFixedPointBridge\""
    , "path = " <> quoted agdaPath
    , "include-dirs = [\".\"]"
    , ""
    , "[fixture.lean]"
    , "repo = \"../dashi_lean4\""
    , "ref = " <> quoted leanSha
    , "module = \"AgdaMirror.CRTJFixedPointBridge\""
    , "toolchain = \"leanprover/lean4:v4.28.0\""
    , "files = ["
        <> quoted (leanPath <> " => AgdaMirror/" <> leanPath)
        <> "]"
    , ""
    , "[fixture.policy]"
    , "statement = \"lean-defeq\""
    , "axioms = \"target-subset\""
    , "allowed-lean-axioms = []"
    ]
    <> declarationBlock source target kind expected expectedCode

declarationBlock ::
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Text.Text ->
  Maybe Text.Text ->
  Text.Text
declarationBlock source target kind expected expectedCode =
  Text.unlines
    ( [ ""
      , "[[fixture.declaration]]"
      , "agda = " <> quoted source
      , "lean = " <> quoted target
      , "kind = " <> quoted kind
      , "expected = " <> quoted expected
      ]
        <> maybe [] (\code -> ["expected-code = " <> quoted code]) expectedCode
    )

mappingBlock :: Text.Text -> Text.Text -> Text.Text -> Text.Text
mappingBlock source target kind =
  Text.unlines
    [ ""
    , "[[fixture.mapping]]"
    , "from = " <> quoted source
    , "to = " <> quoted target
    , "kind = " <> quoted kind
    ]

quoted :: Text.Text -> Text.Text
quoted value = "\"" <> value <> "\""

agdaSha :: Text.Text
agdaSha = "72ae53834be4cd6df842d80fae97c892990ccef6"

leanSha :: Text.Text
leanSha = "55132524c2e132c0b86c17eeb60d7e39c3af08b6"
