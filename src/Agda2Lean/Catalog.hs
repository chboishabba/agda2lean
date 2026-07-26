{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

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
import Control.Exception (throwIO)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
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
  , open
  , query
  , query_
  , withTransaction
  )
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

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
  configure connection
  migrate connection
  pure (Catalog connection)

closeCatalog :: Catalog -> IO ()
closeCatalog = close . catalogConnection

configure :: Connection -> IO ()
configure connection = do
  execute_ connection "PRAGMA foreign_keys = ON"
  execute_ connection "PRAGMA journal_mode = WAL"
  execute_ connection "PRAGMA synchronous = NORMAL"
  execute_ connection "PRAGMA temp_store = MEMORY"
  execute_ connection "PRAGMA busy_timeout = 5000"

migrate :: Connection -> IO ()
migrate connection = withTransaction connection $ do
  execute_
    connection
    "CREATE TABLE IF NOT EXISTS catalog_meta \
    \(key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT"
  execute_
    connection
    "CREATE TABLE IF NOT EXISTS ir_objects \
    \(object_hash BLOB PRIMARY KEY, \
    \object_kind TEXT NOT NULL CHECK (object_kind IN ('module')), \
    \codec_version INTEGER NOT NULL CHECK (codec_version > 0), \
    \cbor BLOB NOT NULL, \
    \byte_length INTEGER NOT NULL CHECK (byte_length = length(cbor)), \
    \created_at TEXT NOT NULL) STRICT"
  execute_
    connection
    "CREATE TABLE IF NOT EXISTS module_heads \
    \(module_name TEXT PRIMARY KEY, \
    \object_hash BLOB NOT NULL REFERENCES ir_objects(object_hash), \
    \declaration_count INTEGER NOT NULL CHECK (declaration_count >= 0), \
    \term_count INTEGER NOT NULL CHECK (term_count >= 0), \
    \updated_at TEXT NOT NULL) STRICT"
  execute_
    connection
    "CREATE TABLE IF NOT EXISTS declarations \
    \(declaration_name TEXT PRIMARY KEY, \
    \module_name TEXT NOT NULL REFERENCES module_heads(module_name) ON DELETE CASCADE, \
    \role TEXT NOT NULL, mapping_mode TEXT NOT NULL, \
    \type_term_id INTEGER NOT NULL, body_term_id INTEGER, \
    \source_file TEXT NOT NULL, \
    \source_start_line INTEGER NOT NULL CHECK (source_start_line > 0), \
    \source_end_line INTEGER NOT NULL CHECK (source_end_line >= source_start_line)) STRICT"
  execute_
    connection
    "CREATE INDEX IF NOT EXISTS declarations_by_module \
    \ON declarations(module_name)"
  execute_
    connection
    "CREATE INDEX IF NOT EXISTS declarations_by_status \
    \ON declarations(role, mapping_mode)"
  execute_
    connection
    "CREATE TABLE IF NOT EXISTS direct_dependencies \
    \(declaration_name TEXT NOT NULL REFERENCES declarations(declaration_name) ON DELETE CASCADE, \
    \dependency_name TEXT NOT NULL, \
    \PRIMARY KEY (declaration_name, dependency_name)) WITHOUT ROWID, STRICT"
  execute_
    connection
    "CREATE INDEX IF NOT EXISTS dependencies_by_target \
    \ON direct_dependencies(dependency_name)"
  execute_
    connection
    "CREATE TABLE IF NOT EXISTS module_imports \
    \(module_name TEXT NOT NULL REFERENCES module_heads(module_name) ON DELETE CASCADE, \
    \imported_module_name TEXT NOT NULL, \
    \PRIMARY KEY (module_name, imported_module_name)) WITHOUT ROWID, STRICT"
  execute
    connection
    "INSERT OR IGNORE INTO catalog_meta(key, value) VALUES ('schema_version', ?)"
    (Only ("1" :: Text))
  execute
    connection
    "INSERT OR IGNORE INTO catalog_meta(key, value) VALUES ('codec_version', ?)"
    (Only (Text.pack (show codecVersion)))
  schemaVersions <-
    query
      connection
      "SELECT value FROM catalog_meta WHERE key = 'schema_version'"
      ()
  unless
    (schemaVersions == [Only ("1" :: Text)])
    (throwIO (userError "unsupported SQLite catalog schema"))

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
  objects <-
    query_
      connection
      "SELECT object_hash, cbor FROM ir_objects ORDER BY object_hash"
  fmap concat $ forM objects $ \(storedHashBytes, cborBytes) -> do
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
    pure (hashIssues <> decodingIssues)

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
    traverse
      (checkedWord64 "body term ID" . unTermId)
      (declarationBody declaration)
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
      , indexedRole = constructorName (declarationRole declaration)
      , indexedMapping = constructorName (declarationMapping declaration)
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

constructorName :: Show a => a -> Text
constructorName = Text.pack . show

timestamp :: IO Text
timestamp =
  Text.pack
    . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
    <$> getCurrentTime
