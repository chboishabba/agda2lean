{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Codec (decodeModule)
import Agda2Lean.Support (inspectSupport, renderSupportReport)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Options.Applicative
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, openTempFile)

data Options = Options
  { inputPath :: FilePath
  , outputPath :: FilePath
  }

main :: IO ()
main = do
  options <- execParser parserInfo
  bytes <- ByteString.readFile (inputPath options)
  moduleIR <- either (ioError . userError . Text.unpack) pure (decodeModule bytes)
  writeTextAtomic (outputPath options) (renderSupportReport (inspectSupport moduleIR))

parserInfo :: ParserInfo Options
parserInfo =
  info
    ( optionsParser <**> helper )
    ( fullDesc
        <> progDesc "Inspect builtin, IR, declaration, computation and semantic-boundary support"
        <> header "agda2lean-support"
    )

optionsParser :: Parser Options
optionsParser =
  Options
    <$> strOption
      ( long "input"
          <> short 'i'
          <> metavar "MODULE.a2l.cbor"
          <> help "Canonical ModuleIR CBOR produced by the Agda backend"
      )
    <*> strOption
      ( long "output"
          <> short 'o'
          <> metavar "support.tsv"
          <> help "Deterministic support survey report"
      )

writeTextAtomic :: FilePath -> Text.Text -> IO ()
writeTextAtomic path contents = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  (temporaryPath, handle) <- openTempFile directory (takeFileName path <> ".tmp")
  Text.hPutStr handle contents
  hClose handle
  renameFile temporaryPath path
