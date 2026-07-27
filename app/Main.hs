{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Catalog
import Agda2Lean.Classify (classifyModule)
import Agda2Lean.Codec (decodeModule, encodeModule)
import Agda2Lean.Hash (hashBytes, renderObjectHash)
import Agda2Lean.IR (CanonicalName (..), CoreDeclaration (..), ModuleIR (..))
import Agda2Lean.Lean.Emit
import Agda2Lean.Platform
import Agda2Lean.Registry.File (loadRegistryLayer)
import Agda2Lean.Render
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as Text
import qualified Data.Vector as Vector
import Options.Applicative
import System.Directory (createDirectoryIfMissing, renameFile)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, openTempFile)

data Command
  = Init GlobalOptions
  | PutModule GlobalOptions FilePath
  | Classify FilePath FilePath
  | GetModule GlobalOptions Text.Text FilePath
  | EmitLean FilePath FilePath FilePath (Maybe FilePath) RegistryOptions Bool
  | BuiltinInventory FilePath
  | Inspect GlobalOptions (Maybe Text.Text)
  | Verify GlobalOptions

newtype GlobalOptions = GlobalOptions
  { databasePath :: FilePath
  }

data RegistryOptions = RegistryOptions
  { libraryRegistryPaths :: [FilePath]
  , projectRegistryPaths :: [FilePath]
  , fixtureRegistryPaths :: [FilePath]
  , registryTestMode :: Bool
  }

main :: IO ()
main = execParser parserInfo >>= runCommand

parserInfo :: ParserInfo Command
parserInfo =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "Store and inspect canonical typed Agda-to-Lean IR"
        <> header "agda2lean"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "init" (info (Init <$> globalOptions) (progDesc "Initialize a catalog"))
        <> command
          "classify"
          (info (Classify <$> inputOption <*> outputOption) (progDesc "Classify features and write canonical CBOR"))
        <> command
          "put-module"
          (info (PutModule <$> globalOptions <*> inputOption) (progDesc "Validate and store a CBOR ModuleIR"))
        <> command
          "get-module"
          (info (GetModule <$> globalOptions <*> moduleOption <*> outputOption) (progDesc "Write a module's canonical CBOR object"))
        <> command
          "emit-lean"
          (info emitLeanParser (progDesc "Emit an Agda-shaped Lean facade and diagnostics"))
        <> command
          "builtin-inventory"
          ( info
              (BuiltinInventory <$> outputOption)
              (progDesc "Write the deterministic builtin coverage inventory")
          )
        <> command
          "inspect"
          (info (Inspect <$> globalOptions <*> optional moduleOption) (progDesc "Render catalog or module summaries"))
        <> command
          "verify"
          (info (Verify <$> globalOptions) (progDesc "Verify hashes, CBOR and canonical encoding"))
    )

globalOptions :: Parser GlobalOptions
globalOptions =
  GlobalOptions
    <$> strOption
      ( long "database"
          <> short 'd'
          <> metavar "PATH"
          <> help "SQLite catalog path"
      )

inputOption :: Parser FilePath
inputOption =
  strOption (long "input" <> short 'i' <> metavar "PATH" <> help "Input CBOR path")

outputOption :: Parser FilePath
outputOption =
  strOption (long "output" <> short 'o' <> metavar "PATH" <> help "Output path")

moduleOption :: Parser Text.Text
moduleOption =
  Text.pack
    <$> strOption
      (long "module" <> short 'm' <> metavar "NAME" <> help "Canonical module name")

registryOptionsParser :: Parser RegistryOptions
registryOptionsParser =
  RegistryOptions
    <$> many
      ( strOption
          ( long "library-registry"
              <> metavar "PATH"
              <> help "LibraryScope registry TSV; may be repeated"
          )
      )
    <*> many
      ( strOption
          ( long "project-registry"
              <> metavar "PATH"
              <> help "ProjectScope registry TSV; may be repeated"
          )
      )
    <*> many
      ( strOption
          ( long "fixture-registry"
              <> metavar "PATH"
              <> help "FixtureOnly registry TSV; requires --registry-test-mode"
          )
      )
    <*> switch
      ( long "registry-test-mode"
          <> help "Permit FixtureOnly registry layers"
      )

emitLeanParser :: Parser Command
emitLeanParser =
  EmitLean
    <$> inputOption
    <*> strOption (long "lean-output" <> metavar "PATH" <> help "Generated Lean file")
    <*> strOption (long "diagnostics" <> metavar "PATH" <> help "Tabular diagnostics file")
    <*> optional
      ( strOption
          ( long "builtin-receipt"
              <> metavar "PATH"
              <> help "Optional provenance-bound builtin semantic receipt file"
          )
      )
    <*> registryOptionsParser
    <*> switch
      ( long "fail-on-reconstruction"
          <> help "Do not emit sorry at reconstruction boundaries"
      )

runCommand :: Command -> IO ()
runCommand (Classify inputPath outputPath) = do
  bytes <- ByteString.readFile inputPath
  moduleIR <- either (ioError . userError . Text.unpack) pure (decodeModule bytes)
  createDirectoryIfMissing True (takeDirectory outputPath)
  ByteString.writeFile outputPath (encodeModule (classifyModule moduleIR))
runCommand (BuiltinInventory outputPath) =
  writeTextAtomic outputPath (inventoryBundle renderBuiltinCoverageInventory)
runCommand (EmitLean inputPath leanPath diagnosticsPath receiptPath registryOptions failOnReconstruction) = do
  ensureCompatible currentVersionContext
  effectiveRegistry <- loadEffectiveRegistry registryOptions
  bytes <- ByteString.readFile inputPath
  moduleIR <- either (ioError . userError . Text.unpack) pure (decodeModule bytes)
  let output =
        emitLeanModule
          defaultEmitOptions
            { emitSorryBodies = not failOnReconstruction
            , emitRegistry = effectiveRegistry
            }
          moduleIR
  ensureReceiptComplete moduleIR output
  writeTextAtomic leanPath (leanSource output)
  writeTextAtomic diagnosticsPath (renderDiagnostics (leanDiagnostics output))
  case receiptPath of
    Nothing -> pure ()
    Just path ->
      writeTextAtomic
        path
        ( receiptBundle
            (effectiveRegistryDigest effectiveRegistry)
            (renderBuiltinReceipts (leanBuiltinReceipts output))
        )
  whenErrors (leanDiagnostics output)
runCommand command' = do
  let options = commandOptions command'
      path = databasePath options
  createDirectoryIfMissing True (takeDirectory path)
  bracket (openCatalog path) closeCatalog $ \catalog ->
    case command' of
      Init _ -> do
        stats <- readCatalogStats catalog
        Text.putStr (renderCatalogStats stats)
      PutModule _ inputPath -> do
        bytes <- ByteString.readFile inputPath
        moduleIR <- either (ioError . userError . Text.unpack) pure (decodeModule bytes)
        objectHash <- storeModule catalog moduleIR
        Text.putStrLn ("stored " <> renderObjectHash objectHash)
      GetModule _ name outputPath -> do
        result <- getModule catalog (CanonicalName name)
        case result of
          Nothing -> do
            Text.putStrLn ("module not found: " <> name)
            exitFailure
          Just moduleIR -> do
            createDirectoryIfMissing True (takeDirectory outputPath)
            ByteString.writeFile outputPath (encodeModule moduleIR)
      Inspect _ Nothing -> do
        summaries <- listModules catalog
        stats <- readCatalogStats catalog
        Text.putStr (renderCatalogStats stats)
        unless (null summaries) $ do
          Text.putStrLn ""
          Text.putStr (renderModuleSummaries summaries)
      Inspect _ (Just name) -> do
        result <- getModule catalog (CanonicalName name)
        case result of
          Nothing -> do
            Text.putStrLn ("module not found: " <> name)
            exitFailure
          Just moduleIR -> Text.putStr (renderModule moduleIR)
      Verify _ -> do
        issues <- verifyCatalog catalog
        Text.putStr (renderCatalogIssues issues)
        unless (null issues) exitFailure
      Classify _ _ -> ioError (userError "internal error: classify opened the catalog")
      EmitLean _ _ _ _ _ _ -> ioError (userError "internal error: emit-lean opened the catalog")
      BuiltinInventory _ -> ioError (userError "internal error: builtin-inventory opened the catalog")

commandOptions :: Command -> GlobalOptions
commandOptions = \case
  Init options -> options
  PutModule options _ -> options
  Classify _ _ -> error "classify does not use a catalog"
  EmitLean _ _ _ _ _ _ -> error "emit-lean does not use a catalog"
  BuiltinInventory _ -> error "builtin-inventory does not use a catalog"
  GetModule options _ _ -> options
  Inspect options _ -> options
  Verify options -> options

loadEffectiveRegistry :: RegistryOptions -> IO (Map.Map BuiltinId PlatformMapping)
loadEffectiveRegistry options = do
  libraryLayers <- traverse (loadRegistryLayer LibraryScope) (libraryRegistryPaths options)
  projectLayers <- traverse (loadRegistryLayer ProjectScope) (projectRegistryPaths options)
  fixtureLayers <- traverse (loadRegistryLayer FixtureOnly) (fixtureRegistryPaths options)
  let mode = if registryTestMode options then TestMode else ProductionMode
      layers = platformRegistryLayer : libraryLayers <> projectLayers <> fixtureLayers
  either
    (ioError . userError . unlines . map show)
    pure
    (composeRegistryLayers mode layers)

ensureReceiptComplete :: ModuleIR -> LeanOutput -> IO ()
ensureReceiptComplete moduleIR output =
  let encountered =
        length
          [ ()
          | declaration <- Vector.toList (moduleDeclarations moduleIR)
          , Just _ <- [declarationBuiltin declaration]
          ]
      recorded = Vector.length (leanBuiltinReceipts output)
   in unless (encountered == recorded) $
        ioError
          ( userError
              ( "builtin receipt completeness failure: encountered "
                  <> show encountered
                  <> ", recorded "
                  <> show recorded
              )
          )

receiptBundle :: Text.Text -> Text.Text -> Text.Text
receiptBundle registryDigest body = provenanceHeader registryDigest <> body

inventoryBundle :: Text.Text -> Text.Text
inventoryBundle body = provenanceHeader platformRegistryDigest <> body

provenanceHeader :: Text.Text -> Text.Text
provenanceHeader registryDigest =
  Text.unlines
    [ "# receipt-schema\t" <> Text.pack (show receiptSchemaVersion)
    , "# codec\t" <> Text.pack (show (versionCodec currentVersionContext))
    , "# registry\t" <> platformRegistryVersion
    , "# registry-digest\t" <> registryDigest
    , "# agda-backend\t" <> versionAgdaBackend currentVersionContext
    , "# lean-target\t" <> versionLeanTarget currentVersionContext
    ]

effectiveRegistryDigest :: Map.Map BuiltinId PlatformMapping -> Text.Text
effectiveRegistryDigest registry =
  renderObjectHash
    ( hashBytes
        ( TextEncoding.encodeUtf8
            ( Text.unlines
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
                | (builtin, mapping) <- Map.toAscList registry
                ]
            )
        )
    )

ensureCompatible :: VersionContext -> IO ()
ensureCompatible context =
  case checkVersionCompatibility context of
    Compatible -> pure ()
    MigrationRequired message -> ioError (userError (Text.unpack message))
    Incompatible message -> ioError (userError (Text.unpack message))

writeTextAtomic :: FilePath -> Text.Text -> IO ()
writeTextAtomic path contents = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  (temporaryPath, handle) <- openTempFile directory (takeFileName path <> ".tmp")
  Text.hPutStr handle contents
  hClose handle
  renameFile temporaryPath path

whenErrors :: Vector.Vector LeanDiagnostic -> IO ()
whenErrors diagnostics =
  if Vector.any ((== Error) . diagnosticSeverity) diagnostics
    then exitFailure
    else pure ()
