{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agda2Lean.Capability
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Options.Applicative
import System.Exit (exitFailure)

data Options = Options
  { databasePath :: FilePath
  , declarationName :: Text.Text
  }

main :: IO ()
main = do
  options <- execParser parserInfo
  result <- readDeclarationCapability (databasePath options) (declarationName options)
  case result of
    Nothing -> do
      Text.putStrLn ("missing\t" <> declarationName options)
      exitFailure
    Just capability -> Text.putStr (renderDeclarationCapability capability)

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper)
    ( fullDesc
        <> progDesc "Read one declaration's proof-aware agda2lean translation capability"
        <> header "agda2lean-capability"
    )

optionsParser :: Parser Options
optionsParser =
  Options
    <$> strOption
      ( long "database"
          <> short 'd'
          <> metavar "PATH"
          <> help "agda2lean SQLite catalog"
      )
    <*> ( Text.pack
            <$> strOption
              ( long "declaration"
                  <> metavar "NAME"
                  <> help "Canonical elaborated Agda declaration name"
              )
        )
