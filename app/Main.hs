{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Catalog
import Agda2Lean.Classify (classifyModule)
import Agda2Lean.Codec (decodeModule, encodeModule)
import Agda2Lean.Hash (renderObjectHash)
import Agda2Lean.IR (CanonicalName (..))
import Agda2Lean.Lean.Emit
import Agda2Lean.Render
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Vector as Vector
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)

data Command
  = Init GlobalOptions
  | PutModule GlobalOptions FilePath
  | Classify FilePath FilePath
  | GetModule GlobalOptions Text.Text FilePath
  | EmitLean FilePath FilePath FilePath (Maybe FilePath) Bool
  | Inspect GlobalOptions (Maybe Text.Text)
  | Verify GlobalOptions

newtype GlobalOptions = GlobalOptions
  { databasePath :: FilePath
  }

main :: IO ()
main = execParser parserInfo >>= runCommand

parserInfo :: ParserInfo Command
parserInfo =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc
          "Store and inspect canonical typed Agda-to-Lean IR"
        <> header "agda2lean"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "init"
        (info (Init <$> globalOptions) (progDesc "Initialize a catalog"))
        <> command
          "classify"
          ( info
              (Classify <$> inputOption <*> outputOption)
              (progDesc "Classify features and write canonical CBOR")
          )
        <> command
          "put-module"
          ( info
              (PutModule <$> globalOptions <*> inputOption)
              (progDesc "Validate and store a CBOR ModuleIR")
          )
        <> command
          "get-module"
          ( info
              (GetModule <$> globalOptions <*> moduleOption <*> outputOption)
              (progDesc "Write a module's canonical CBOR object")
          )
        <> command
          "emit-lean"
          ( info
              emitLeanParser
              (progDesc "Emit an Agda-shaped Lean facade and diagnostics")
          )
        <> command
          "inspect"
          ( info
              (Inspect <$> globalOptions <*> optional moduleOption)
              (progDesc "Render catalog or module summaries")
          )
        <> command
          "verify"
          ( info
              (Verify <$> globalOptions)
              (progDesc "Verify hashes, CBOR and canonical encoding")
          )
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
  strOption
    (long "input" <> short 'i' <> metavar "PATH" <> help "Input CBOR path")

outputOption :: Parser FilePath
outputOption =
  strOption
    (long "output" <> short 'o' <> metavar "PATH" <> help "Output CBOR path")

moduleOption :: Parser Text.Text
moduleOption =
  Text.pack
    <$> strOption
      (long "module" <> short 'm' <> metavar "NAME" <> help "Canonical module name")

emitLeanParser :: Parser Command
emitLeanParser =
  EmitLean
    <$> inputOption
    <*> strOption
      (long "lean-output" <> metavar "PATH" <> help "Generated Lean file")
    <*> strOption
      (long "diagnostics" <> metavar "PATH" <> help "Tabular diagnostics file")
    <*> optional
      (strOption
        ( long "builtin-receipt"
            <> metavar "PATH"
            <> help "Optional tabular builtin semantic receipt file"
        ))
    <*> switch
      ( long "fail-on-reconstruction"
          <> help "Do not emit sorry at reconstruction boundaries"
      )

runCommand :: Command -> IO ()
runCommand (Classify inputPath outputPath) = do
  bytes <- ByteString.readFile inputPath
  moduleIR <-
    either
      (ioError . userError . Text.unpack)
      pure
      (decodeModule bytes)
  createDirectoryIfMissing True (takeDirectory outputPath)
  ByteString.writeFile outputPath (encodeModule (classifyModule moduleIR))
runCommand (EmitLean inputPath leanPath diagnosticsPath receiptPath failOnReconstruction) = do
  bytes <- ByteString.readFile inputPath
  moduleIR <-
    either
      (ioError . userError . Text.unpack)
      pure
      (decodeModule bytes)
  let output =
        emitLeanModule
          defaultEmitOptions
            { emitSorryBodies = not failOnReconstruction
            }
          moduleIR
  createDirectoryIfMissing True (takeDirectory leanPath)
  createDirectoryIfMissing True (takeDirectory diagnosticsPath)
  Text.writeFile leanPath (leanSource output)
  Text.writeFile diagnosticsPath (renderDiagnostics (leanDiagnostics output))
  case receiptPath of
    Nothing -> pure ()
    Just path -> do
      createDirectoryIfMissing True (takeDirectory path)
      Text.writeFile path (renderBuiltinReceipts (leanBuiltinReceipts output))
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
        moduleIR <-
          either
            (ioError . userError . Text.unpack)
            pure
            (decodeModule bytes)
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
      Classify _ _ ->
        ioError (userError "internal error: classify opened the catalog")
      EmitLean _ _ _ _ _ ->
        ioError (userError "internal error: emit-lean opened the catalog")

commandOptions :: Command -> GlobalOptions
commandOptions = \case
  Init options -> options
  PutModule options _ -> options
  Classify _ _ -> error "classify does not use a catalog"
  EmitLean _ _ _ _ _ -> error "emit-lean does not use a catalog"
  GetModule options _ _ -> options
  Inspect options _ -> options
  Verify options -> options

whenErrors :: Vector.Vector LeanDiagnostic -> IO ()
whenErrors diagnostics =
  if Vector.any ((== Error) . diagnosticSeverity) diagnostics
    then exitFailure
    else pure ()
