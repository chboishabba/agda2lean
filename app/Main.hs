{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Catalog
import Agda2Lean.Classify (classifyModule)
import Agda2Lean.Codec (decodeModule, encodeModule)
import Agda2Lean.Hash (renderObjectHash)
import Agda2Lean.IR (CanonicalName (..))
import Agda2Lean.Render
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)

data Command
  = Init GlobalOptions
  | PutModule GlobalOptions FilePath
  | Classify FilePath FilePath
  | GetModule GlobalOptions Text.Text FilePath
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

commandOptions :: Command -> GlobalOptions
commandOptions = \case
  Init options -> options
  PutModule options _ -> options
  Classify {} -> error "classify does not use a catalog"
  GetModule options _ _ -> options
  Inspect options _ -> options
  Verify options -> options
