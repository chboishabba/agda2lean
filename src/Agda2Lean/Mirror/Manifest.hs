{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.Mirror.Manifest
  ( AgdaFixtureSource (..)
  , DeclarationExpectation (..)
  , FixtureDeclaration (..)
  , FixtureId (..)
  , FixturePolicy (..)
  , FixtureTier (..)
  , LeanFixtureSource (..)
  , ManifestError (..)
  , MirrorFixture (..)
  , MirrorManifest (..)
  , NameMapping (..)
  , StagedFile (..)
  , parseMirrorManifest
  , renderManifestError
  ) where

import Control.Monad (foldM, unless, when)
import Data.Char (isAsciiLower, isDigit, isHexDigit, isSpace)
import Data.List (group, sort)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Text.Read (readMaybe)

newtype FixtureId = FixtureId {unFixtureId :: Text}
  deriving stock (Eq, Ord, Show)

data FixtureTier
  = Smoke
  | Pilot
  | Corpus
  deriving stock (Eq, Ord, Show)

data StagedFile = StagedFile
  { stagedFileSource :: FilePath
  , stagedFileDestination :: FilePath
  }
  deriving stock (Eq, Ord, Show)

data AgdaFixtureSource = AgdaFixtureSource
  { agdaRepository :: FilePath
  , agdaRevision :: Text
  , agdaModule :: Text
  , agdaSourcePath :: FilePath
  , agdaIncludeDirectories :: [FilePath]
  }
  deriving stock (Eq, Show)

data LeanFixtureSource = LeanFixtureSource
  { leanRepository :: FilePath
  , leanRevision :: Text
  , leanModule :: Text
  , leanToolchain :: Text
  , leanFiles :: [StagedFile]
  }
  deriving stock (Eq, Show)

data FixturePolicy = FixturePolicy
  { statementPolicy :: Text
  , axiomPolicy :: Text
  , allowedLeanAxioms :: Set Text
  }
  deriving stock (Eq, Show)

data DeclarationExpectation
  = ExpectPass
  | ExpectBlocked Text
  deriving stock (Eq, Ord, Show)

data FixtureDeclaration = FixtureDeclaration
  { agdaDeclaration :: Text
  , leanDeclaration :: Text
  , declarationKind :: Text
  , declarationExpectation :: DeclarationExpectation
  }
  deriving stock (Eq, Ord, Show)

data NameMapping = NameMapping
  { mappingSource :: Text
  , mappingTarget :: Text
  , mappingKind :: Text
  }
  deriving stock (Eq, Ord, Show)

data MirrorFixture = MirrorFixture
  { fixtureId :: FixtureId
  , fixtureTier :: FixtureTier
  , fixtureAgda :: AgdaFixtureSource
  , fixtureLean :: LeanFixtureSource
  , fixturePolicy :: FixturePolicy
  , fixtureDeclarations :: [FixtureDeclaration]
  , fixtureMappings :: [NameMapping]
  }
  deriving stock (Eq, Show)

data MirrorManifest = MirrorManifest
  { manifestSchemaVersion :: Int
  , manifestFixtures :: [MirrorFixture]
  }
  deriving stock (Eq, Show)

data ManifestError = ManifestError
  { manifestErrorLine :: Maybe Int
  , manifestErrorCode :: Text
  , manifestErrorMessage :: Text
  }
  deriving stock (Eq, Ord, Show)

renderManifestError :: ManifestError -> Text
renderManifestError issue =
  location
    <> manifestErrorCode issue
    <> ": "
    <> manifestErrorMessage issue
  where
    location =
      maybe
        ""
        (\lineNumber -> "line " <> Text.pack (show lineNumber) <> ": ")
        (manifestErrorLine issue)

data Section
  = TopLevel
  | FixtureSection
  | AgdaSection
  | LeanSection
  | PolicySection
  | DeclarationSection
  | MappingSection
  deriving stock (Eq, Show)

data AgdaBuilder = AgdaBuilder
  { agdaRepositoryField :: Maybe Text
  , agdaRevisionField :: Maybe Text
  , agdaModuleField :: Maybe Text
  , agdaPathField :: Maybe Text
  , agdaIncludesField :: Maybe [Text]
  }

emptyAgdaBuilder :: AgdaBuilder
emptyAgdaBuilder = AgdaBuilder Nothing Nothing Nothing Nothing Nothing

data LeanBuilder = LeanBuilder
  { leanRepositoryField :: Maybe Text
  , leanRevisionField :: Maybe Text
  , leanModuleField :: Maybe Text
  , leanToolchainField :: Maybe Text
  , leanFilesField :: Maybe [Text]
  }

emptyLeanBuilder :: LeanBuilder
emptyLeanBuilder = LeanBuilder Nothing Nothing Nothing Nothing Nothing

data PolicyBuilder = PolicyBuilder
  { statementPolicyField :: Maybe Text
  , axiomPolicyField :: Maybe Text
  , allowedAxiomsField :: Maybe [Text]
  }

emptyPolicyBuilder :: PolicyBuilder
emptyPolicyBuilder = PolicyBuilder Nothing Nothing Nothing

data DeclarationBuilder = DeclarationBuilder
  { declarationAgdaField :: Maybe Text
  , declarationLeanField :: Maybe Text
  , declarationKindField :: Maybe Text
  , declarationExpectedField :: Maybe Text
  , declarationExpectedCodeField :: Maybe Text
  }

emptyDeclarationBuilder :: DeclarationBuilder
emptyDeclarationBuilder =
  DeclarationBuilder Nothing Nothing Nothing Nothing Nothing

data MappingBuilder = MappingBuilder
  { mappingFromField :: Maybe Text
  , mappingToField :: Maybe Text
  , mappingKindField :: Maybe Text
  }

emptyMappingBuilder :: MappingBuilder
emptyMappingBuilder = MappingBuilder Nothing Nothing Nothing

data FixtureBuilder = FixtureBuilder
  { fixtureStartLine :: Int
  , fixtureIdField :: Maybe Text
  , fixtureTierField :: Maybe Text
  , agdaBuilder :: AgdaBuilder
  , leanBuilder :: LeanBuilder
  , policyBuilder :: PolicyBuilder
  , declarationBuilders :: [DeclarationBuilder]
  , currentDeclaration :: Maybe DeclarationBuilder
  , mappingBuilders :: [MappingBuilder]
  , currentMapping :: Maybe MappingBuilder
  }

emptyFixtureBuilder :: Int -> FixtureBuilder
emptyFixtureBuilder lineNumber =
  FixtureBuilder
    { fixtureStartLine = lineNumber
    , fixtureIdField = Nothing
    , fixtureTierField = Nothing
    , agdaBuilder = emptyAgdaBuilder
    , leanBuilder = emptyLeanBuilder
    , policyBuilder = emptyPolicyBuilder
    , declarationBuilders = []
    , currentDeclaration = Nothing
    , mappingBuilders = []
    , currentMapping = Nothing
    }

data ParserState = ParserState
  { parserSection :: Section
  , parserSchema :: Maybe Int
  , completedFixtures :: [FixtureBuilder]
  , currentFixture :: Maybe FixtureBuilder
  }

initialParserState :: ParserState
initialParserState = ParserState TopLevel Nothing [] Nothing

parseMirrorManifest :: Text -> Either ManifestError MirrorManifest
parseMirrorManifest input = do
  parsed <-
    foldM
      parseLine
      initialParserState
      (zip [1 ..] (Text.lines input))
  finalState <- finishCurrentFixture parsed
  schema <-
    maybe
      (Left (globalError "A2L-MANIFEST-SCHEMA" "missing schema-version"))
      Right
      (parserSchema finalState)
  unless (schema == 1) $
    Left
      ( globalError
          "A2L-MANIFEST-SCHEMA"
          ("unsupported schema-version " <> Text.pack (show schema))
      )
  fixtures <- traverse finishFixture (reverse (completedFixtures finalState))
  when (null fixtures) $
    Left (globalError "A2L-MANIFEST-EMPTY" "manifest contains no fixtures")
  rejectDuplicates
    "A2L-MANIFEST-DUPLICATE-FIXTURE"
    "fixture id"
    (map (unFixtureId . fixtureId) fixtures)
  pure
    MirrorManifest
      { manifestSchemaVersion = schema
      , manifestFixtures = fixtures
      }

parseLine :: ParserState -> (Int, Text) -> Either ManifestError ParserState
parseLine state (lineNumber, originalLine)
  | Text.null line = Right state
  | "[[" `Text.isPrefixOf` line = parseArrayHeader lineNumber line state
  | "[" `Text.isPrefixOf` line = parseTableHeader lineNumber line state
  | otherwise = parseAssignment lineNumber line state
  where
    line = Text.strip (stripComment originalLine)

parseArrayHeader ::
  Int ->
  Text ->
  ParserState ->
  Either ManifestError ParserState
parseArrayHeader lineNumber header state =
  case header of
    "[[fixture]]" -> do
      finished <- finishCurrentFixture state
      pure
        finished
          { parserSection = FixtureSection
          , currentFixture = Just (emptyFixtureBuilder lineNumber)
          }
    "[[fixture.declaration]]" -> do
      fixture <- requireCurrentFixture lineNumber state
      fixture' <- finishCurrentNested fixture
      pure
        state
          { parserSection = DeclarationSection
          , currentFixture =
              Just fixture' {currentDeclaration = Just emptyDeclarationBuilder}
          }
    "[[fixture.mapping]]" -> do
      fixture <- requireCurrentFixture lineNumber state
      fixture' <- finishCurrentNested fixture
      pure
        state
          { parserSection = MappingSection
          , currentFixture = Just fixture' {currentMapping = Just emptyMappingBuilder}
          }
    _ ->
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-SECTION"
            ("unknown array table " <> header)
        )

parseTableHeader ::
  Int ->
  Text ->
  ParserState ->
  Either ManifestError ParserState
parseTableHeader lineNumber header state = do
  fixture <- requireCurrentFixture lineNumber state
  fixture' <- finishCurrentNested fixture
  section <-
    case header of
      "[fixture.agda]" -> Right AgdaSection
      "[fixture.lean]" -> Right LeanSection
      "[fixture.policy]" -> Right PolicySection
      _ ->
        Left
          ( lineError
              lineNumber
              "A2L-MANIFEST-SECTION"
              ("unknown table " <> header)
          )
  pure state {parserSection = section, currentFixture = Just fixture'}

parseAssignment ::
  Int ->
  Text ->
  ParserState ->
  Either ManifestError ParserState
parseAssignment lineNumber line state = do
  let (rawKey, rawValueWithEquals) = Text.breakOn "=" line
  when (Text.null rawValueWithEquals) $
    Left
      (lineError lineNumber "A2L-MANIFEST-SYNTAX" "expected key = value")
  let key = Text.strip rawKey
      rawValue = Text.strip (Text.drop 1 rawValueWithEquals)
  when (Text.null key || Text.any isSpace key) $
    Left (lineError lineNumber "A2L-MANIFEST-KEY" "invalid key")
  case parserSection state of
    TopLevel ->
      case key of
        "schema-version" -> do
          value <- parseInteger lineNumber rawValue
          schema <-
            setOnce
              lineNumber
              "schema-version"
              (parserSchema state)
              value
          pure state {parserSchema = schema}
        _ -> unknownKey lineNumber key
    section -> do
      fixture <- requireCurrentFixture lineNumber state
      fixture' <- parseFixtureField lineNumber section key rawValue fixture
      pure state {currentFixture = Just fixture'}

parseFixtureField ::
  Int ->
  Section ->
  Text ->
  Text ->
  FixtureBuilder ->
  Either ManifestError FixtureBuilder
parseFixtureField lineNumber section key rawValue fixture =
  case section of
    FixtureSection ->
      case key of
        "id" -> do
          value <- parseString lineNumber rawValue
          field <- setOnce lineNumber key (fixtureIdField fixture) value
          pure fixture {fixtureIdField = field}
        "tier" -> do
          value <- parseString lineNumber rawValue
          field <- setOnce lineNumber key (fixtureTierField fixture) value
          pure fixture {fixtureTierField = field}
        _ -> unknownKey lineNumber key
    AgdaSection -> do
      builder <- parseAgdaField lineNumber key rawValue (agdaBuilder fixture)
      pure fixture {agdaBuilder = builder}
    LeanSection -> do
      builder <- parseLeanField lineNumber key rawValue (leanBuilder fixture)
      pure fixture {leanBuilder = builder}
    PolicySection -> do
      builder <- parsePolicyField lineNumber key rawValue (policyBuilder fixture)
      pure fixture {policyBuilder = builder}
    DeclarationSection -> do
      builder <-
        maybe
          (Left (lineError lineNumber "A2L-MANIFEST-SECTION" "missing declaration table"))
          Right
          (currentDeclaration fixture)
      builder' <- parseDeclarationField lineNumber key rawValue builder
      pure fixture {currentDeclaration = Just builder'}
    MappingSection -> do
      builder <-
        maybe
          (Left (lineError lineNumber "A2L-MANIFEST-SECTION" "missing mapping table"))
          Right
          (currentMapping fixture)
      builder' <- parseMappingField lineNumber key rawValue builder
      pure fixture {currentMapping = Just builder'}
    TopLevel -> unknownKey lineNumber key

parseAgdaField ::
  Int ->
  Text ->
  Text ->
  AgdaBuilder ->
  Either ManifestError AgdaBuilder
parseAgdaField lineNumber key rawValue builder =
  case key of
    "repo" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (agdaRepositoryField builder) value
      pure builder {agdaRepositoryField = field}
    "ref" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (agdaRevisionField builder) value
      pure builder {agdaRevisionField = field}
    "module" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (agdaModuleField builder) value
      pure builder {agdaModuleField = field}
    "path" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (agdaPathField builder) value
      pure builder {agdaPathField = field}
    "include-dirs" -> do
      value <- parseStringArray lineNumber rawValue
      field <- setOnce lineNumber key (agdaIncludesField builder) value
      pure builder {agdaIncludesField = field}
    _ -> unknownKey lineNumber key

parseLeanField ::
  Int ->
  Text ->
  Text ->
  LeanBuilder ->
  Either ManifestError LeanBuilder
parseLeanField lineNumber key rawValue builder =
  case key of
    "repo" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (leanRepositoryField builder) value
      pure builder {leanRepositoryField = field}
    "ref" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (leanRevisionField builder) value
      pure builder {leanRevisionField = field}
    "module" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (leanModuleField builder) value
      pure builder {leanModuleField = field}
    "toolchain" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (leanToolchainField builder) value
      pure builder {leanToolchainField = field}
    "files" -> do
      value <- parseStringArray lineNumber rawValue
      field <- setOnce lineNumber key (leanFilesField builder) value
      pure builder {leanFilesField = field}
    _ -> unknownKey lineNumber key

parsePolicyField ::
  Int ->
  Text ->
  Text ->
  PolicyBuilder ->
  Either ManifestError PolicyBuilder
parsePolicyField lineNumber key rawValue builder =
  case key of
    "statement" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (statementPolicyField builder) value
      pure builder {statementPolicyField = field}
    "axioms" -> do
      value <- parseString lineNumber rawValue
      field <- setOnce lineNumber key (axiomPolicyField builder) value
      pure builder {axiomPolicyField = field}
    "allowed-lean-axioms" -> do
      value <- parseStringArray lineNumber rawValue
      field <- setOnce lineNumber key (allowedAxiomsField builder) value
      pure builder {allowedAxiomsField = field}
    _ -> unknownKey lineNumber key

parseDeclarationField ::
  Int ->
  Text ->
  Text ->
  DeclarationBuilder ->
  Either ManifestError DeclarationBuilder
parseDeclarationField lineNumber key rawValue builder = do
  value <- parseString lineNumber rawValue
  case key of
    "agda" -> do
      field <- setOnce lineNumber key (declarationAgdaField builder) value
      pure builder {declarationAgdaField = field}
    "lean" -> do
      field <- setOnce lineNumber key (declarationLeanField builder) value
      pure builder {declarationLeanField = field}
    "kind" -> do
      field <- setOnce lineNumber key (declarationKindField builder) value
      pure builder {declarationKindField = field}
    "expected" -> do
      field <- setOnce lineNumber key (declarationExpectedField builder) value
      pure builder {declarationExpectedField = field}
    "expected-code" -> do
      field <- setOnce lineNumber key (declarationExpectedCodeField builder) value
      pure builder {declarationExpectedCodeField = field}
    _ -> unknownKey lineNumber key

parseMappingField ::
  Int ->
  Text ->
  Text ->
  MappingBuilder ->
  Either ManifestError MappingBuilder
parseMappingField lineNumber key rawValue builder = do
  value <- parseString lineNumber rawValue
  case key of
    "from" -> do
      field <- setOnce lineNumber key (mappingFromField builder) value
      pure builder {mappingFromField = field}
    "to" -> do
      field <- setOnce lineNumber key (mappingToField builder) value
      pure builder {mappingToField = field}
    "kind" -> do
      field <- setOnce lineNumber key (mappingKindField builder) value
      pure builder {mappingKindField = field}
    _ -> unknownKey lineNumber key

finishCurrentFixture :: ParserState -> Either ManifestError ParserState
finishCurrentFixture state =
  case currentFixture state of
    Nothing -> Right state
    Just fixture -> do
      fixture' <- finishCurrentNested fixture
      pure
        state
          { completedFixtures = fixture' : completedFixtures state
          , currentFixture = Nothing
          }

finishCurrentNested :: FixtureBuilder -> Either ManifestError FixtureBuilder
finishCurrentNested fixture =
  Right
    fixture
      { declarationBuilders =
          maybe
            (declarationBuilders fixture)
            (: declarationBuilders fixture)
            (currentDeclaration fixture)
      , currentDeclaration = Nothing
      , mappingBuilders =
          maybe
            (mappingBuilders fixture)
            (: mappingBuilders fixture)
            (currentMapping fixture)
      , currentMapping = Nothing
      }

finishFixture :: FixtureBuilder -> Either ManifestError MirrorFixture
finishFixture builder = do
  identifierText <- required "id" (fixtureIdField builder)
  validateFixtureId lineNumber identifierText
  tierText <- required "tier" (fixtureTierField builder)
  tier <- parseTier lineNumber tierText
  agda <- finishAgda lineNumber (agdaBuilder builder)
  lean <- finishLean lineNumber (leanBuilder builder)
  policy <- finishPolicy lineNumber (policyBuilder builder)
  declarations <-
    traverse
      (finishDeclaration lineNumber)
      (reverse (declarationBuilders builder))
  mappings <-
    traverse
      (finishMapping lineNumber)
      (reverse (mappingBuilders builder))
  when (null declarations) $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-DECLARATIONS"
          "fixture contains no declarations"
      )
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-AGDA-SYMBOL"
    "Agda declaration"
    (map agdaDeclaration declarations)
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-LEAN-SYMBOL"
    "Lean declaration"
    (map leanDeclaration declarations)
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-MAPPING-SOURCE"
    "mapping source"
    (map mappingSource mappings)
  pure
    MirrorFixture
      { fixtureId = FixtureId identifierText
      , fixtureTier = tier
      , fixtureAgda = agda
      , fixtureLean = lean
      , fixturePolicy = policy
      , fixtureDeclarations = declarations
      , fixtureMappings = mappings
      }
  where
    lineNumber = fixtureStartLine builder
    required field =
      maybe
        ( Left
            ( lineError
                lineNumber
                "A2L-MANIFEST-MISSING"
                ("missing fixture field " <> field)
            )
        )
        Right

finishAgda :: Int -> AgdaBuilder -> Either ManifestError AgdaFixtureSource
finishAgda lineNumber builder = do
  repository <- requireField "fixture.agda.repo" (agdaRepositoryField builder)
  validateRepository lineNumber repository
  revision <- requireField "fixture.agda.ref" (agdaRevisionField builder)
  validateRevision lineNumber revision
  moduleName <- requireField "fixture.agda.module" (agdaModuleField builder)
  validateSymbol lineNumber "Agda module" moduleName
  path <- requireField "fixture.agda.path" (agdaPathField builder)
  validateMaterializedPath lineNumber False "Agda source path" path
  includes <-
    requireField "fixture.agda.include-dirs" (agdaIncludesField builder)
  traverse_ (validateMaterializedPath lineNumber True "Agda include directory") includes
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-PATH"
    "Agda include directory"
    includes
  pure
    AgdaFixtureSource
      { agdaRepository = Text.unpack repository
      , agdaRevision = revision
      , agdaModule = moduleName
      , agdaSourcePath = Text.unpack path
      , agdaIncludeDirectories = map Text.unpack includes
      }
  where
    requireField = requiredAt lineNumber

finishLean :: Int -> LeanBuilder -> Either ManifestError LeanFixtureSource
finishLean lineNumber builder = do
  repository <- requireField "fixture.lean.repo" (leanRepositoryField builder)
  validateRepository lineNumber repository
  revision <- requireField "fixture.lean.ref" (leanRevisionField builder)
  validateRevision lineNumber revision
  moduleName <- requireField "fixture.lean.module" (leanModuleField builder)
  validateSymbol lineNumber "Lean module" moduleName
  toolchain <- requireField "fixture.lean.toolchain" (leanToolchainField builder)
  when (Text.null toolchain || Text.any isSpace toolchain) $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-TOOLCHAIN"
          "Lean toolchain must be a non-empty token"
      )
  fileSpecs <- requireField "fixture.lean.files" (leanFilesField builder)
  when (null fileSpecs) $
    Left
      (lineError lineNumber "A2L-MANIFEST-FILES" "Lean file list is empty")
  files <- traverse (parseStagedFile lineNumber) fileSpecs
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-PATH"
    "Lean source file"
    (map (Text.pack . stagedFileSource) files)
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-PATH"
    "Lean staged file"
    (map (Text.pack . stagedFileDestination) files)
  pure
    LeanFixtureSource
      { leanRepository = Text.unpack repository
      , leanRevision = revision
      , leanModule = moduleName
      , leanToolchain = toolchain
      , leanFiles = files
      }
  where
    requireField = requiredAt lineNumber

finishPolicy :: Int -> PolicyBuilder -> Either ManifestError FixturePolicy
finishPolicy lineNumber builder = do
  statement <- requiredAt lineNumber "fixture.policy.statement" (statementPolicyField builder)
  unless (statement == "lean-defeq") $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-POLICY"
          ("unsupported statement policy " <> statement)
      )
  axioms <- requiredAt lineNumber "fixture.policy.axioms" (axiomPolicyField builder)
  unless (axioms == "target-subset") $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-POLICY"
          ("unsupported axiom policy " <> axioms)
      )
  allowed <-
    requiredAt
      lineNumber
      "fixture.policy.allowed-lean-axioms"
      (allowedAxiomsField builder)
  traverse_ (validateSymbol lineNumber "allowed Lean axiom") allowed
  rejectDuplicatesAt
    lineNumber
    "A2L-MANIFEST-DUPLICATE-AXIOM"
    "allowed Lean axiom"
    allowed
  pure
    FixturePolicy
      { statementPolicy = statement
      , axiomPolicy = axioms
      , allowedLeanAxioms = Set.fromList allowed
      }

finishDeclaration ::
  Int ->
  DeclarationBuilder ->
  Either ManifestError FixtureDeclaration
finishDeclaration lineNumber builder = do
  source <- required "agda" (declarationAgdaField builder)
  validateSymbol lineNumber "Agda declaration" source
  target <- required "lean" (declarationLeanField builder)
  validateSymbol lineNumber "Lean declaration" target
  kind <- required "kind" (declarationKindField builder)
  unless (kind `Set.member` allowedKinds) $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-KIND"
          ("unsupported declaration kind " <> kind)
      )
  expected <- required "expected" (declarationExpectedField builder)
  expectation <-
    case expected of
      "pass" ->
        case declarationExpectedCodeField builder of
          Nothing -> Right ExpectPass
          Just _ ->
            Left
              ( lineError
                  lineNumber
                  "A2L-MANIFEST-EXPECTATION"
                  "passing declaration must not specify expected-code"
              )
      "blocked" -> do
        code <- required "expected-code" (declarationExpectedCodeField builder)
        when (Text.null code || Text.any isSpace code) $
          Left
            ( lineError
                lineNumber
                "A2L-MANIFEST-EXPECTATION"
                "expected-code must be a non-empty token"
            )
        Right (ExpectBlocked code)
      _ ->
        Left
          ( lineError
              lineNumber
              "A2L-MANIFEST-EXPECTATION"
              ("unsupported expected value " <> expected)
          )
  pure
    FixtureDeclaration
      { agdaDeclaration = source
      , leanDeclaration = target
      , declarationKind = kind
      , declarationExpectation = expectation
      }
  where
    required = requiredAt lineNumber
    allowedKinds =
      Set.fromList ["theorem", "function", "data", "structure", "certificate"]

finishMapping :: Int -> MappingBuilder -> Either ManifestError NameMapping
finishMapping lineNumber builder = do
  source <- required "from" (mappingFromField builder)
  validateSymbol lineNumber "mapping source" source
  target <- required "to" (mappingToField builder)
  validateSymbol lineNumber "mapping target" target
  kind <- required "kind" (mappingKindField builder)
  unless (kind `Set.member` allowedKinds) $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-MAPPING-KIND"
          ("unsupported mapping kind " <> kind)
      )
  pure
    NameMapping
      { mappingSource = source
      , mappingTarget = target
      , mappingKind = kind
      }
  where
    required = requiredAt lineNumber
    allowedKinds = Set.fromList ["semantic", "encoding", "platform"]

parseStagedFile :: Int -> Text -> Either ManifestError StagedFile
parseStagedFile lineNumber value =
  case Text.splitOn "=>" value of
    [rawSource, rawDestination] -> do
      let source = Text.strip rawSource
          destination = Text.strip rawDestination
      validateMaterializedPath lineNumber False "Lean source file" source
      validateMaterializedPath lineNumber False "Lean staged file" destination
      pure
        StagedFile
          { stagedFileSource = Text.unpack source
          , stagedFileDestination = Text.unpack destination
          }
    _ ->
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-FILE-SPEC"
            "Lean file must have the form source => staged"
        )

parseTier :: Int -> Text -> Either ManifestError FixtureTier
parseTier lineNumber = \case
  "smoke" -> Right Smoke
  "pilot" -> Right Pilot
  "corpus" -> Right Corpus
  value ->
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-TIER"
          ("unsupported fixture tier " <> value)
      )

parseInteger :: Int -> Text -> Either ManifestError Int
parseInteger lineNumber value =
  maybe
    (Left (lineError lineNumber "A2L-MANIFEST-INTEGER" "invalid integer"))
    Right
    (readMaybe (Text.unpack value))

parseString :: Int -> Text -> Either ManifestError Text
parseString lineNumber value =
  case Text.uncons value of
    Just ('"', rest) ->
      case unsnoc rest of
        Just (body, '"') -> decodeString lineNumber body
        _ -> unterminated
    _ ->
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-STRING"
            "expected a double-quoted string"
        )
  where
    unterminated =
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-STRING"
            "unterminated double-quoted string"
        )

parseStringArray :: Int -> Text -> Either ManifestError [Text]
parseStringArray lineNumber value =
  case (Text.uncons value, unsnoc value) of
    (Just ('[', _), Just (_, ']')) ->
      let body = Text.strip (Text.dropEnd 1 (Text.drop 1 value))
       in if Text.null body
            then Right []
            else splitArray body >>= traverse (parseString lineNumber)
    _ ->
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-ARRAY"
            "expected a single-line array of strings"
        )
  where
    splitArray = go False False "" []

    go _ _ current values remaining
      | Text.null remaining =
          if Text.null (Text.strip current)
            then
              Left
                ( lineError
                    lineNumber
                    "A2L-MANIFEST-ARRAY"
                    "empty array element"
                )
            else Right (reverse (Text.strip current : values))
    go quoted escaped current values remaining =
      case Text.uncons remaining of
        Nothing -> Right (reverse (Text.strip current : values))
        Just (character, tail')
          | escaped -> go quoted False (Text.snoc current character) values tail'
          | quoted && character == '\\' ->
              go quoted True (Text.snoc current character) values tail'
          | character == '"' ->
              go (not quoted) False (Text.snoc current character) values tail'
          | character == ',' && not quoted ->
              if Text.null (Text.strip current)
                then
                  Left
                    ( lineError
                        lineNumber
                        "A2L-MANIFEST-ARRAY"
                        "empty array element"
                    )
                else go False False "" (Text.strip current : values) tail'
          | otherwise ->
              go quoted False (Text.snoc current character) values tail'

decodeString :: Int -> Text -> Either ManifestError Text
decodeString lineNumber = fmap Text.pack . go . Text.unpack
  where
    go [] = Right []
    go ('\\' : []) =
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-ESCAPE"
            "trailing string escape"
        )
    go ('\\' : character : rest) = do
      decoded <-
        case character of
          '"' -> Right '"'
          '\\' -> Right '\\'
          'n' -> Right '\n'
          't' -> Right '\t'
          _ ->
            Left
              ( lineError
                  lineNumber
                  "A2L-MANIFEST-ESCAPE"
                  ("unsupported string escape \\" <> Text.singleton character)
              )
      (decoded :) <$> go rest
    go (character : rest)
      | character == '"' =
          Left
            ( lineError
                lineNumber
                "A2L-MANIFEST-STRING"
                "unescaped quote in string"
            )
      | character < ' ' =
          Left
            ( lineError
                lineNumber
                "A2L-MANIFEST-STRING"
                "control character in string"
            )
      | otherwise = (character :) <$> go rest

stripComment :: Text -> Text
stripComment = go False False ""
  where
    go _ _ result remaining
      | Text.null remaining = result
    go quoted escaped result remaining =
      case Text.uncons remaining of
        Nothing -> result
        Just (character, tail')
          | escaped -> go quoted False (Text.snoc result character) tail'
          | quoted && character == '\\' ->
              go quoted True (Text.snoc result character) tail'
          | character == '"' ->
              go (not quoted) False (Text.snoc result character) tail'
          | character == '#' && not quoted -> result
          | otherwise -> go quoted False (Text.snoc result character) tail'

setOnce ::
  Int ->
  Text ->
  Maybe value ->
  value ->
  Either ManifestError (Maybe value)
setOnce lineNumber field current value =
  case current of
    Nothing -> Right (Just value)
    Just _ ->
      Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-DUPLICATE-FIELD"
            ("duplicate field " <> field)
        )

requiredAt :: Int -> Text -> Maybe value -> Either ManifestError value
requiredAt lineNumber field =
  maybe
    ( Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-MISSING"
            ("missing field " <> field)
        )
    )
    Right

requireCurrentFixture ::
  Int ->
  ParserState ->
  Either ManifestError FixtureBuilder
requireCurrentFixture lineNumber state =
  maybe
    ( Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-SECTION"
            "fixture subsection appears before [[fixture]]"
        )
    )
    Right
    (currentFixture state)

validateFixtureId :: Int -> Text -> Either ManifestError ()
validateFixtureId lineNumber value =
  unless valid $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-ID"
          ("invalid fixture id " <> value)
      )
  where
    valid =
      not (Text.null value)
        && isAsciiLower (Text.head value)
        && Text.all
          (\character -> isAsciiLower character || isDigit character || character == '-')
          value
        && Text.last value /= '-'
        && not ("--" `Text.isInfixOf` value)

validateRevision :: Int -> Text -> Either ManifestError ()
validateRevision lineNumber revision =
  unless
    ( Text.length revision == 40
        && Text.all (\character -> isHexDigit character && not (character >= 'A' && character <= 'F')) revision
    )
    ( Left
        ( lineError
            lineNumber
            "A2L-MANIFEST-REVISION"
            "revision must be a full 40-character lowercase Git object id"
        )
    )

validateRepository :: Int -> Text -> Either ManifestError ()
validateRepository lineNumber repository =
  when (Text.null repository || Text.any (== '\NUL') repository) $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-REPOSITORY"
          "repository must be non-empty and contain no NUL"
      )

validateMaterializedPath ::
  Int ->
  Bool ->
  Text ->
  Text ->
  Either ManifestError ()
validateMaterializedPath lineNumber allowDot label path =
  unless valid $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-PATH"
          (label <> " is unsafe: " <> path)
      )
  where
    normalized = Text.replace "\\" "/" path
    segments = Text.splitOn "/" normalized
    driveQualified =
      Text.length normalized >= 2 && Text.index normalized 1 == ':'
    valid =
      not (Text.null normalized)
        && not ("/" `Text.isPrefixOf` normalized)
        && not driveQualified
        && not (Text.any (== '\NUL') normalized)
        && all
          (\segment ->
             not (Text.null segment)
               && segment /= ".."
               && (allowDot || segment /= ".")
          )
          segments

validateSymbol :: Int -> Text -> Text -> Either ManifestError ()
validateSymbol lineNumber label symbol =
  unless valid $
    Left
      ( lineError
          lineNumber
          "A2L-MANIFEST-SYMBOL"
          (label <> " is invalid: " <> symbol)
      )
  where
    valid =
      not (Text.null symbol)
        && not ("." `Text.isPrefixOf` symbol)
        && not ("." `Text.isSuffixOf` symbol)
        && not (".." `Text.isInfixOf` symbol)
        && not (Text.any (\character -> isSpace character || character == '\NUL') symbol)

rejectDuplicates ::
  Text ->
  Text ->
  [Text] ->
  Either ManifestError ()
rejectDuplicates code label values =
  case duplicates values of
    [] -> Right ()
    duplicate : _ ->
      Left
        ( globalError
            code
            ("duplicate " <> label <> ": " <> duplicate)
        )

rejectDuplicatesAt ::
  Int ->
  Text ->
  Text ->
  [Text] ->
  Either ManifestError ()
rejectDuplicatesAt lineNumber code label values =
  case duplicates values of
    [] -> Right ()
    duplicate : _ ->
      Left
        ( lineError
            lineNumber
            code
            ("duplicate " <> label <> ": " <> duplicate)
        )

duplicates :: Ord value => [value] -> [value]
duplicates = map head . filter ((> 1) . length) . group . sort

unknownKey :: Int -> Text -> Either ManifestError value
unknownKey lineNumber key =
  Left
    ( lineError
        lineNumber
        "A2L-MANIFEST-KEY"
        ("unknown key " <> key)
    )

lineError :: Int -> Text -> Text -> ManifestError
lineError lineNumber code message =
  ManifestError
    { manifestErrorLine = Just lineNumber
    , manifestErrorCode = code
    , manifestErrorMessage = message
    }

globalError :: Text -> Text -> ManifestError
globalError code message =
  ManifestError
    { manifestErrorLine = Nothing
    , manifestErrorCode = code
    , manifestErrorMessage = message
    }

unsnoc :: Text -> Maybe (Text, Char)
unsnoc value
  | Text.null value = Nothing
  | otherwise = Just (Text.init value, Text.last value)

traverse_ :: Applicative f => (a -> f b) -> [a] -> f ()
traverse_ action = foldr ((*>) . action) (pure ())
