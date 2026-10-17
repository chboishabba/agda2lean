{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.Capability
  ( DeclarationCapability (..)
  , readDeclarationCapability
  , renderDeclarationCapability
  ) where

import Agda2Lean.Hash (ObjectHash (..), renderObjectHash)
import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import Database.SQLite.Simple
  ( Only (..)
  , close
  , open
  , query
  )

-- | Read-only translation capability for one declaration in an agda2lean
-- catalog.  Mapping mode describes the translator's lowering boundary only;
-- it does not establish that any emitted Lean declaration has been validated.
data DeclarationCapability = DeclarationCapability
  { capabilityDeclarationName :: Text
  , capabilityModuleName :: Text
  , capabilityRole :: Text
  , capabilityMappingMode :: Text
  , capabilityObjectHash :: Text
  , capabilityCheckedSourceSha256 :: Maybe Text
  , capabilitySourceFile :: Text
  , capabilitySourceStartLine :: Int64
  , capabilitySourceEndLine :: Int64
  , capabilityDirectDependencies :: [Text]
  , capabilityEstablishesProof :: Bool
  }
  deriving stock (Eq, Show)

readDeclarationCapability :: FilePath -> Text -> IO (Maybe DeclarationCapability)
readDeclarationCapability database declarationName = do
  connection <- open database
  rows <-
    query
      connection
      "SELECT d.declaration_name, d.module_name, d.role, d.mapping_mode, \
      \h.object_hash, h.checked_source_sha256, d.source_file, \
      \d.source_start_line, d.source_end_line \
      \FROM declarations AS d \
      \JOIN module_heads AS h ON h.module_name = d.module_name \
      \WHERE d.declaration_name = ?"
      (Only declarationName) ::
      IO [(Text, Text, Text, Text, ByteString.ByteString, Maybe Text, Text, Int64, Int64)]
  result <-
    case rows of
      [] -> pure Nothing
      [(name, moduleName, role, mappingMode, objectHashBytes, checkedSource, sourceFile, startLine, endLine)] -> do
        dependencies <-
          query
            connection
            "SELECT dependency_name FROM direct_dependencies \
            \WHERE declaration_name = ? ORDER BY dependency_name"
            (Only declarationName) :: IO [Only Text]
        pure $
          Just
            DeclarationCapability
              { capabilityDeclarationName = name
              , capabilityModuleName = moduleName
              , capabilityRole = role
              , capabilityMappingMode = mappingMode
              , capabilityObjectHash = renderObjectHash (ObjectHash objectHashBytes)
              , capabilityCheckedSourceSha256 = checkedSource
              , capabilitySourceFile = sourceFile
              , capabilitySourceStartLine = startLine
              , capabilitySourceEndLine = endLine
              , capabilityDirectDependencies = [dependency | Only dependency <- dependencies]
              , capabilityEstablishesProof = False
              }
      _ -> ioError (userError "catalog invariant violated: duplicate declaration capability")
  close connection
  pure result

renderDeclarationCapability :: DeclarationCapability -> Text
renderDeclarationCapability item =
  Text.unlines $
    [ "declaration\t" <> capabilityDeclarationName item
    , "module\t" <> capabilityModuleName item
    , "role\t" <> capabilityRole item
    , "mapping_mode\t" <> capabilityMappingMode item
    , "object_hash\t" <> capabilityObjectHash item
    , "checked_source_sha256\t" <> maybe "" id (capabilityCheckedSourceSha256 item)
    , "source_file\t" <> capabilitySourceFile item
    , "source_start_line\t" <> Text.pack (show (capabilitySourceStartLine item))
    , "source_end_line\t" <> Text.pack (show (capabilitySourceEndLine item))
    , "authority\ttranslation-capability-only"
    , "establishes_proof\tfalse"
    ]
      <> ["dependency\t" <> dependency | dependency <- capabilityDirectDependencies item]
