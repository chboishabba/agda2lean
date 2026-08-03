{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Agda2Lean.Catalog
  ( Catalog
  , CatalogIssue (..)
  , CatalogStats (..)
  , ModuleSummary (..)
  , closeCatalog
  , getModule
  , listModules
  , openCatalog
  , readCatalogStats
  , storeModule
  , verifyCatalog
  ) where

import Agda2Lean.Codec
  ( codecVersion
  , decodeModule
  , encodeModule
  )
import Agda2Lean.Hash
  ( ObjectHash (..)
  , hashBytes
  , renderObjectHash
  )
import Agda2Lean.IR
import Control.Exception (onException, throwIO)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.FileEmbed (embedFile, makeRelativeToProject)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as Vector
import Data.Word (Word64)
import Database.SQLite.Simple
  ( Connection
  , FromRow (fromRow)
  , Only (..)
  , close
  , execute
  , execute_
  , field
  , fold_
  , open
  , Query (..)
  , query
  , query_
  , withTransaction
  )
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Text.Read (readMaybe)

newtype Catalog = Catalog {catalogConnection :: Connection}

data ModuleSummary = ModuleSummary
  { summaryModuleName :: Text
  , summaryObjectHash :: ObjectHash
  , summaryDeclarationCount :: Int64
  , summaryTermCount :: Int64
  , summaryObjectBytes :: Int64
  , summaryUpdatedAt :: Text
  }
  deriving stock (Eq, Show)

instance FromRow ModuleSummary where
  fromRow =
    ModuleSummary
      <$> field
      <*> (ObjectHash <$> field)
      <*> field
      <*> field
      <*> field
      <*> field

data CatalogStats = CatalogStats
  { statsModules :: Int64
  , statsDeclarations :: Int64
  , statsObjects :: Int64
  , statsObjectBytes :: Int64
  , statsDirectDependencies :: Int64
  }
  deriving stock (Eq, Show)

data CatalogIssue = CatalogIssue
  { issueObjectHash :: ObjectHash
  , issueDescription :: Text
  }
  deriving stock (Eq, Show)

openCatalog :: FilePath -> IO Catalog
openCatalog path = do
  connection <- open path
  (do
      configure connection
      migrate connection
      pure (Catalog connection)
    )
    `onException` close connection

closeCatalog :: Catalog -> IO ()
closeCatalog = close . catalogConnection

configure :: Connection -> IO ()
configure connection = do
  ensureSQLiteVersion connection
  execute_ connection "PRAGMA foreign_keys = ON"
  journalModes <-
    query_ connection "PRAGMA journal_mode = WAL" :: IO [Only Text]
  unless
    (journalModes == [Only "wal"])
    (throwIO (userError "SQLite refused WAL journal mode"))
  execute_ connection "PRAGMA synchronous = NORMAL"
  execute_ connection "PRAGMA temp_store = MEMORY"
  execute_ connection "PRAGMA busy_timeout = 5000"

migrate :: Connection -> IO ()
migrate connection = withTransaction connection $ do
  forM_ catalogSchemaStatements (execute_ connection)
  execute
    connection
    "INSERT OR IGNORE INTO catalog_meta(key, value) VALUES ('schema_version', ?)"
    (Only catalogSchemaVersion)
  execute
    connection
    "INSERT OR IGNORE INTO catalog_meta(key, value) VALUES ('codec_version', ?)"
    (Only (Text.pack (show codecVersion)))
  schemaVersions <-
    query_
      connection
      "SELECT value FROM catalog_meta WHERE key = 'schema_version'"
  unless
    (schemaVersions == [Only catalogSchemaVersion])
    (throwIO (userError "unsupported SQLite catalog schema"))
  codecVersions <-
    query_
      connection
      "SELECT value FROM catalog_meta WHERE key = 'codec_version'"
  unless
    (codecVersions == [Only (Text.pack (show codecVersion))])
    (throwIO (userError "catalog was written with a different CBOR codec version"))

storeModule :: Catalog -> ModuleIR -> IO ObjectHash
storeModule (Catalog connection) moduleIR = do
  validated <-
    either
      (throwIO . userError . Text.unpack . Text.intercalate "\n" . Vector.toList)
      pure
      (validateModule moduleIR)
  indexedDeclarations <-
    traverse toIndexedDeclaration (Vector.toList (moduleDeclarations validated))
  now <- timestamp
  let canonicalBytes = encodeModule validated
      objectHash@(ObjectHash hashBytes') = hashBytes canonicalBytes
      moduleName' = unCanonicalName (moduleName validated)
  withTransaction connection $ do
    execute
      connection
      "INSERT OR IGNORE INTO ir_objects \
      \(object_hash, object_kind, codec_version, cbor, byte_length, created_at) \
      \VALUES (?, 'module', ?, ?, ?, ?)"
      ( hashBytes'
      , fromIntegral codecVersion :: Int64
      , canonicalBytes
      , ByteString.length canonicalBytes
      , now
      )
    execute
      connection
      "INSERT INTO module_heads \
      \(module_name, object_hash, declaration_count, term_count, updated_at) \
      \VALUES (?, ?, ?, ?, ?) \
      \ON CONFLICT(module_name) DO UPDATE SET \
      \object_hash = excluded.object_hash, \
      \declaration_count = excluded.declaration_count, \
      \term_count = excluded.term_count, \
      \updated_at = excluded.updated_at"
      ( moduleName'
      , hashBytes'
      , Vector.length (moduleDeclarations validated)
      , Map.size (moduleTerms validated)
      , now
      )
    execute
      connection
      "DELETE FROM declarations WHERE module_name = ?"
      (Only moduleName')
    execute
      connection
      "DELETE FROM module_imports WHERE module_name = ?"
      (Only moduleName')
    forM_ indexedDeclarations $ \indexed -> do
      execute
        connection
        "INSERT INTO declarations \
        \(declaration_name, module_name, role, mapping_mode, \
        \type_term_id, body_term_id, source_file, \
        \source_start_line, source_end_line) \
        \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        ( indexedName indexed
        , moduleName'
        , indexedRole indexed
        , indexedMapping indexed
        , indexedTypeTerm indexed
        , indexedBodyTerm indexed
        , indexedSourceFile indexed
        , indexedStartLine indexed
        , indexedEndLine indexed
        )
      forM_ (indexedDependencies indexed) $ \dependency ->
        execute
          connection
          "INSERT INTO direct_dependencies \
          \(declaration_name, dependency_name) VALUES (?, ?)"
          (indexedName indexed, dependency)
    forM_ (Set.toAscList (moduleImports validated)) $ \imported ->
      execute
        connection
        "INSERT INTO module_imports \
        \(module_name, imported_module_name) VALUES (?, ?)"
        (moduleName', unCanonicalName imported)
  pure objectHash

getModule :: Catalog -> CanonicalName -> IO (Maybe ModuleIR)
getModule (Catalog connection) name = do
  rows <-
    query
      connection
      "SELECT objects.cbor \
      \FROM module_heads AS heads \
      \JOIN ir_objects AS objects ON objects.object_hash = heads.object_hash \
      \WHERE heads.module_name = ?"
      (Only (unCanonicalName name))
  case rows of
    [] -> pure Nothing
    [Only bytes] ->
      either
        (throwIO . userError . Text.unpack)
        (pure . Just)
        (decodeModule bytes)
    _ -> throwIO (userError "catalog invariant violated: duplicate module head")

listModules :: Catalog -> IO [ModuleSummary]
listModules (Catalog connection) =
  query_
    connection
    "SELECT heads.module_name, heads.object_hash, \
    \heads.declaration_count, heads.term_count, objects.byte_length, \
    \heads.updated_at \
    \FROM module_heads AS heads \
    \JOIN ir_objects AS objects ON objects.object_hash = heads.object_hash \
    \ORDER BY heads.module_name"

readCatalogStats :: Catalog -> IO CatalogStats
readCatalogStats (Catalog connection) = do
  [Only moduleCount] <- query_ connection "SELECT count(*) FROM module_heads"
  [Only declarationCount] <- query_ connection "SELECT count(*) FROM declarations"
  [(objectCount, objectBytes)] <-
    query_
      connection
      "SELECT count(*), coalesce(sum(byte_length), 0) FROM ir_objects"
  [Only dependencyCount] <-
    query_ connection "SELECT count(*) FROM direct_dependencies"
  pure
    CatalogStats
      { statsModules = moduleCount
      , statsDeclarations = declarationCount
      , statsObjects = objectCount
      , statsObjectBytes = objectBytes
      , statsDirectDependencies = dependencyCount
      }

verifyCatalog :: Catalog -> IO [CatalogIssue]
verifyCatalog (Catalog connection) = do
  reversedIssues <-
    fold_
      connection
      "SELECT object_hash, cbor FROM ir_objects ORDER BY object_hash"
      []
      (\issues row -> pure (reverse (verifyObject row) <> issues))
  pure (reverse reversedIssues)

verifyObject :: (ByteString, ByteString) -> [CatalogIssue]
verifyObject (storedHashBytes, cborBytes) =
    let storedHash = ObjectHash storedHashBytes
        actualHash = hashBytes cborBytes
        hashIssues =
          [ CatalogIssue
              storedHash
              ( "content hash mismatch; computed "
                  <> renderObjectHash actualHash
              )
          | storedHash /= actualHash
          ]
        decodingIssues =
          case decodeModule cborBytes of
            Left message -> [CatalogIssue storedHash ("invalid CBOR: " <> message)]
            Right decoded ->
              [ CatalogIssue storedHash "stored object is not canonically encoded"
              | encodeModule decoded /= cborBytes
              ]
     in hashIssues <> decodingIssues

data IndexedDeclaration = IndexedDeclaration
  { indexedName :: Text
  , indexedRole :: Text
  , indexedMapping :: Text
  , indexedTypeTerm :: Int64
  , indexedBodyTerm :: Maybe Int64
  , indexedSourceFile :: Text
  , indexedStartLine :: Int64
  , indexedEndLine :: Int64
  , indexedDependencies :: [Text]
  }

toIndexedDeclaration :: CoreDeclaration -> IO IndexedDeclaration
toIndexedDeclaration declaration = do
  typeTerm <- checkedWord64 "type term ID" (unTermId (declarationType declaration))
  bodyTerm <-
    case declarationDefinition declaration of
      TermDefinition body ->
        Just <$> checkedWord64 "body term ID" (unTermId body)
      _ -> pure Nothing
  startLine <-
    checkedWord64
      "source start line"
      (sourceStartLine (declarationSource declaration))
  endLine <-
    checkedWord64
      "source end line"
      (sourceEndLine (declarationSource declaration))
  pure
    IndexedDeclaration
      { indexedName = unCanonicalName (declarationName declaration)
      , indexedRole = roleStorageText (declarationRole declaration)
      , indexedMapping = mappingStorageText (declarationMapping declaration)
      , indexedTypeTerm = typeTerm
      , indexedBodyTerm = bodyTerm
      , indexedSourceFile = sourceFile (declarationSource declaration)
      , indexedStartLine = startLine
      , indexedEndLine = endLine
      , indexedDependencies =
          map unCanonicalName
            (Set.toAscList (declarationDependencies declaration))
      }

checkedWord64 :: String -> Word64 -> IO Int64
checkedWord64 label value
  | value <= fromIntegral (maxBound :: Int64) = pure (fromIntegral value)
  | otherwise =
      throwIO
        (userError (label <> " exceeds SQLite's signed 64-bit integer range"))

roleStorageText :: DeclarationRole -> Text
roleStorageText = \case
  ComputationalData -> "computational-data"
  ComputationalFunction -> "computational-function"
  ComputationalWitness -> "computational-witness"
  LogicalProposition -> "logical-proposition"
  Theorem -> "theorem"
  AxiomDeclaration -> "axiom"
  Certificate -> "certificate"
  Adapter -> "adapter"

mappingStorageText :: MappingMode -> Text
mappingStorageText = \case
  Exact -> "exact"
  Encoded -> "encoded"
  Reconstruct -> "reconstruct"
  Quarantined -> "quarantined"
  Unsupported -> "unsupported"

catalogSchemaVersion :: Text
catalogSchemaVersion = "2"

catalogSchemaBytes :: ByteString
catalogSchemaBytes =
  $(makeRelativeToProject "schema/catalog.sql" >>= embedFile)

catalogSchemaStatements :: [Query]
catalogSchemaStatements =
  [ Query statement
  | statement <-
      map Text.strip
        (Text.splitOn ";" (Text.decodeUtf8 catalogSchemaBytes))
  , not (Text.null statement)
  ]

ensureSQLiteVersion :: Connection -> IO ()
ensureSQLiteVersion connection = do
  versions <- query_ connection "SELECT sqlite_version()" :: IO [Only Text]
  case versions of
    [Only version]
      | sqliteVersionAtLeast (3, 37, 0) version -> pure ()
      | otherwise ->
          throwIO
            ( userError
                ( "SQLite 3.37.0 or newer is required for STRICT tables; found "
                    <> Text.unpack version
                )
            )
    _ -> throwIO (userError "could not determine SQLite version")

sqliteVersionAtLeast :: (Int, Int, Int) -> Text -> Bool
sqliteVersionAtLeast required version =
  case
      traverse
        (readMaybe . Text.unpack)
        (take 3 (Text.splitOn "." version))
    of
      Just [major, minor, patch] -> (major, minor, patch) >= required
      _ -> False

timestamp :: IO Text
timestamp =
  Text.pack
    . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
    <$> getCurrentTime
