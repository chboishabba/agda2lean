{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Agda2Lean.Codec
  ( codecVersion
  , decodeModule
  , encodeModule
  , moduleObjectHash
  ) where

import Agda2Lean.Hash (ObjectHash, hashBytes)
import Agda2Lean.IR
import Codec.CBOR.Decoding
  ( Decoder
  , decodeListLen
  , decodeString
  , decodeWord
  , decodeWord16
  , decodeWord64
  )
import Codec.CBOR.Encoding
  ( Encoding
  , encodeListLen
  , encodeString
  , encodeWord
  , encodeWord16
  , encodeWord64
  )
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Write (toStrictByteString)
import Control.Monad (replicateM, unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (foldMap)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Data.Word (Word16)

codecVersion :: Word16
codecVersion = 3

encodeModule :: ModuleIR -> ByteString
encodeModule = toStrictByteString . encodeModuleIR

moduleObjectHash :: ModuleIR -> ObjectHash
moduleObjectHash = hashBytes . encodeModule

decodeModule :: ByteString -> Either Text.Text ModuleIR
decodeModule bytes = do
  (remaining, result) <-
    first (Text.pack . show)
      (deserialiseFromBytes decodeModuleIR (LazyByteString.fromStrict bytes))
  unless (LazyByteString.null remaining) (Left "trailing bytes after ModuleIR")
  first (Text.intercalate "\n" . Vector.toList) (validateModule result)

encodeModuleIR :: ModuleIR -> Encoding
encodeModuleIR ir =
  encodeListLen 6
    <> encodeWord16 codecVersion
    <> encodeSchemaVersion (moduleSchemaVersion ir)
    <> encodeCanonicalName (moduleName ir)
    <> encodeSet encodeCanonicalName (moduleImports ir)
    <> encodeMap encodeTermId encodeCoreTerm (moduleTerms ir)
    <> encodeVector encodeDeclaration (moduleDeclarations ir)

decodeModuleIR :: Decoder s ModuleIR
decodeModuleIR = do
  expectListLen 6
  version <- decodeWord16
  unless (version == codecVersion) (fail "unsupported CBOR codec version")
  ModuleIR
    <$> decodeSchemaVersion
    <*> decodeCanonicalName
    <*> decodeSet decodeCanonicalName
    <*> decodeMap decodeTermId decodeCoreTerm
    <*> decodeVector decodeDeclaration

encodeSchemaVersion :: SchemaVersion -> Encoding
encodeSchemaVersion = encodeWord16 . unSchemaVersion

decodeSchemaVersion :: Decoder s SchemaVersion
decodeSchemaVersion = SchemaVersion <$> decodeWord16

encodeCanonicalName :: CanonicalName -> Encoding
encodeCanonicalName = encodeString . unCanonicalName

decodeCanonicalName :: Decoder s CanonicalName
decodeCanonicalName = CanonicalName <$> decodeString

encodeBinderId :: BinderId -> Encoding
encodeBinderId = encodeWord64 . unBinderId

decodeBinderId :: Decoder s BinderId
decodeBinderId = BinderId <$> decodeWord64

encodeTermId :: TermId -> Encoding
encodeTermId = encodeWord64 . unTermId

decodeTermId :: Decoder s TermId
decodeTermId = TermId <$> decodeWord64

encodeVisibility :: Visibility -> Encoding
encodeVisibility = encodeWord . fromIntegral . fromEnum

decodeVisibility :: Decoder s Visibility
decodeVisibility = decodeBoundedEnum "visibility"

encodeRelevance :: Relevance -> Encoding
encodeRelevance = encodeWord . fromIntegral . fromEnum

decodeRelevance :: Decoder s Relevance
decodeRelevance = decodeBoundedEnum "relevance"

encodeUniverse :: Universe -> Encoding
encodeUniverse = \case
  UZero -> encodeListLen 1 <> encodeWord 0
  USuc universe ->
    encodeListLen 2 <> encodeWord 1 <> encodeUniverse universe
  UMax universes ->
    encodeListLen 2 <> encodeWord 2 <> encodeVector encodeUniverse universes
  ULevel name ->
    encodeListLen 2 <> encodeWord 3 <> encodeString name
  UProp universe ->
    encodeListLen 2 <> encodeWord 4 <> encodeUniverse universe
  USSet universe ->
    encodeListLen 2 <> encodeWord 5 <> encodeUniverse universe

decodeUniverse :: Decoder s Universe
decodeUniverse = do
  length' <- decodeListLen
  tag <- decodeWord
  case (tag, length') of
    (0, 1) -> pure UZero
    (1, 2) -> USuc <$> decodeUniverse
    (2, 2) -> UMax <$> decodeVector decodeUniverse
    (3, 2) -> ULevel <$> decodeString
    (4, 2) -> UProp <$> decodeUniverse
    (5, 2) -> USSet <$> decodeUniverse
    _ -> fail "invalid Universe encoding"

encodeBinder :: Binder -> Encoding
encodeBinder binder =
  encodeListLen 5
    <> encodeBinderId (binderId binder)
    <> encodeString (binderName binder)
    <> encodeTermId (binderType binder)
    <> encodeVisibility (binderVisibility binder)
    <> encodeRelevance (binderRelevance binder)

decodeBinder :: Decoder s Binder
decodeBinder = do
  expectListLen 5
  Binder
    <$> decodeBinderId
    <*> decodeString
    <*> decodeTermId
    <*> decodeVisibility
    <*> decodeRelevance

encodeArgument :: Argument -> Encoding
encodeArgument argument =
  encodeListLen 3
    <> encodeVisibility (argumentVisibility argument)
    <> encodeRelevance (argumentRelevance argument)
    <> encodeTermId (argumentTerm argument)

decodeArgument :: Decoder s Argument
decodeArgument = do
  expectListLen 3
  Argument <$> decodeVisibility <*> decodeRelevance <*> decodeTermId

encodeExtension :: ExtensionTerm -> Encoding
encodeExtension = \case
  CubicalPrimitive name arguments ->
    encodeListLen 3
      <> encodeWord 0
      <> encodeString name
      <> encodeVector encodeTermId arguments
  RewritePrimitive name arguments ->
    encodeListLen 3
      <> encodeWord 1
      <> encodeCanonicalName name
      <> encodeVector encodeTermId arguments
  CoinductivePrimitive name arguments ->
    encodeListLen 3
      <> encodeWord 2
      <> encodeString name
      <> encodeVector encodeTermId arguments
  UnsafeUniversePrimitive description ->
    encodeListLen 2 <> encodeWord 3 <> encodeString description

decodeExtension :: Decoder s ExtensionTerm
decodeExtension = do
  length' <- decodeListLen
  tag <- decodeWord
  case (tag, length') of
    (0, 3) ->
      CubicalPrimitive <$> decodeString <*> decodeVector decodeTermId
    (1, 3) ->
      RewritePrimitive <$> decodeCanonicalName <*> decodeVector decodeTermId
    (2, 3) ->
      CoinductivePrimitive <$> decodeString <*> decodeVector decodeTermId
    (3, 2) -> UnsafeUniversePrimitive <$> decodeString
    _ -> fail "invalid ExtensionTerm encoding"

encodeCoreTerm :: CoreTerm -> Encoding
encodeCoreTerm = \case
  Var binderId ->
    encodeListLen 2 <> encodeWord 0 <> encodeBinderId binderId
  Sort universe ->
    encodeListLen 2 <> encodeWord 1 <> encodeUniverse universe
  Pi binder body ->
    encodeListLen 3 <> encodeWord 2 <> encodeBinder binder <> encodeTermId body
  Sigma binder body ->
    encodeListLen 3 <> encodeWord 3 <> encodeBinder binder <> encodeTermId body
  Lam binder body ->
    encodeListLen 3 <> encodeWord 4 <> encodeBinder binder <> encodeTermId body
  App function argument ->
    encodeListLen 3
      <> encodeWord 5
      <> encodeTermId function
      <> encodeArgument argument
  Constructor name arguments ->
    encodeListLen 3
      <> encodeWord 6
      <> encodeCanonicalName name
      <> encodeVector encodeArgument arguments
  Eliminator name arguments ->
    encodeListLen 3
      <> encodeWord 7
      <> encodeCanonicalName name
      <> encodeVector encodeArgument arguments
  Equality type' left right ->
    encodeListLen 4
      <> encodeWord 8
      <> encodeTermId type'
      <> encodeTermId left
      <> encodeTermId right
  Axiom name ->
    encodeListLen 2 <> encodeWord 9 <> encodeCanonicalName name
  Builtin builtin ->
    encodeListLen 2 <> encodeWord 11 <> encodeBuiltinId builtin
  Extension extension ->
    encodeListLen 2 <> encodeWord 10 <> encodeExtension extension

decodeCoreTerm :: Decoder s CoreTerm
decodeCoreTerm = do
  length' <- decodeListLen
  tag <- decodeWord
  case (tag, length') of
    (0, 2) -> Var <$> decodeBinderId
    (1, 2) -> Sort <$> decodeUniverse
    (2, 3) -> Pi <$> decodeBinder <*> decodeTermId
    (3, 3) -> Sigma <$> decodeBinder <*> decodeTermId
    (4, 3) -> Lam <$> decodeBinder <*> decodeTermId
    (5, 3) -> App <$> decodeTermId <*> decodeArgument
    (6, 3) ->
      Constructor <$> decodeCanonicalName <*> decodeVector decodeArgument
    (7, 3) ->
      Eliminator <$> decodeCanonicalName <*> decodeVector decodeArgument
    (8, 4) -> Equality <$> decodeTermId <*> decodeTermId <*> decodeTermId
    (9, 2) -> Axiom <$> decodeCanonicalName
    (10, 2) -> Extension <$> decodeExtension
    (11, 2) -> Builtin <$> decodeBuiltinId
    _ -> fail "invalid CoreTerm encoding"

encodeDeclarationRole :: DeclarationRole -> Encoding
encodeDeclarationRole = encodeWord . fromIntegral . fromEnum

decodeDeclarationRole :: Decoder s DeclarationRole
decodeDeclarationRole = decodeBoundedEnum "declaration role"

encodeMappingMode :: MappingMode -> Encoding
encodeMappingMode = encodeWord . fromIntegral . fromEnum

decodeMappingMode :: Decoder s MappingMode
decodeMappingMode = decodeBoundedEnum "mapping mode"

encodeFeature :: Feature -> Encoding
encodeFeature = encodeWord . fromIntegral . fromEnum

decodeFeature :: Decoder s Feature
decodeFeature = decodeBoundedEnum "feature"

encodeSourceSpan :: SourceSpan -> Encoding
encodeSourceSpan source =
  encodeListLen 3
    <> encodeString (sourceFile source)
    <> encodeWord64 (sourceStartLine source)
    <> encodeWord64 (sourceEndLine source)

decodeSourceSpan :: Decoder s SourceSpan
decodeSourceSpan = do
  expectListLen 3
  SourceSpan <$> decodeString <*> decodeWord64 <*> decodeWord64

encodeDeclaration :: CoreDeclaration -> Encoding
encodeDeclaration declaration =
  encodeListLen 11
    <> encodeCanonicalName (declarationName declaration)
    <> encodeMaybe encodeBuiltinId (declarationBuiltin declaration)
    <> encodeDeclarationRole (declarationRole declaration)
    <> encodeVector encodeString (declarationUniverses declaration)
    <> encodeVector encodeBinder (declarationModuleParameters declaration)
    <> encodeTermId (declarationType declaration)
    <> encodeMaybe encodeTermId (declarationBody declaration)
    <> encodeSet encodeCanonicalName (declarationDependencies declaration)
    <> encodeSet encodeFeature (declarationFeatures declaration)
    <> encodeSourceSpan (declarationSource declaration)
    <> encodeMappingMode (declarationMapping declaration)

decodeDeclaration :: Decoder s CoreDeclaration
decodeDeclaration = do
  expectListLen 11
  CoreDeclaration
    <$> decodeCanonicalName
    <*> decodeMaybe decodeBuiltinId
    <*> decodeDeclarationRole
    <*> decodeVector decodeString
    <*> decodeVector decodeBinder
    <*> decodeTermId
    <*> decodeMaybe decodeTermId
    <*> decodeSet decodeCanonicalName
    <*> decodeSet decodeFeature
    <*> decodeSourceSpan
    <*> decodeMappingMode

encodeBuiltinId :: BuiltinId -> Encoding
encodeBuiltinId = encodeWord . fromIntegral . fromEnum

decodeBuiltinId :: Decoder s BuiltinId
decodeBuiltinId = decodeBoundedEnum "builtin id"

encodeMaybe :: (a -> Encoding) -> Maybe a -> Encoding
encodeMaybe _ Nothing = encodeListLen 0
encodeMaybe encoder (Just value) = encodeListLen 1 <> encoder value

decodeMaybe :: Decoder s a -> Decoder s (Maybe a)
decodeMaybe decoder =
  decodeListLen >>= \case
    0 -> pure Nothing
    1 -> Just <$> decoder
    _ -> fail "invalid Maybe encoding"

encodeVector :: (a -> Encoding) -> Vector.Vector a -> Encoding
encodeVector encoder values =
  encodeListLen (fromIntegral (Vector.length values))
    <> foldMap encoder values

decodeVector :: Decoder s a -> Decoder s (Vector.Vector a)
decodeVector decoder = do
  length' <- decodeBoundedListLen "vector"
  Vector.fromList <$> replicateM length' decoder

encodeSet :: (a -> Encoding) -> Set.Set a -> Encoding
encodeSet encoder = encodeVector encoder . Vector.fromList . Set.toAscList

decodeSet :: Ord a => Decoder s a -> Decoder s (Set.Set a)
decodeSet decoder = do
  values <- decodeVector decoder
  let result = Set.fromList (Vector.toList values)
  unless (Set.size result == Vector.length values) (fail "duplicate set entry")
  unless
    (Set.toAscList result == Vector.toList values)
    (fail "set entries are not in canonical order")
  pure result

encodeMap ::
  (key -> Encoding) ->
  (value -> Encoding) ->
  Map.Map key value ->
  Encoding
encodeMap encodeKey encodeValue entries =
  encodeListLen (fromIntegral (Map.size entries))
    <> foldMap
      (\(key, value) ->
         encodeListLen 2 <> encodeKey key <> encodeValue value
      )
      (Map.toAscList entries)

decodeMap ::
  (Eq value, Ord key) =>
  Decoder s key ->
  Decoder s value ->
  Decoder s (Map.Map key value)
decodeMap decodeKey decodeValue = do
  length' <- decodeBoundedListLen "map"
  entries <- replicateM length' $ do
    expectListLen 2
    (,) <$> decodeKey <*> decodeValue
  let result = Map.fromList entries
  unless (Map.size result == length entries) (fail "duplicate map key")
  unless (Map.toAscList result == entries) (fail "map keys not canonical")
  pure result

-- The limit is per module object, not per catalog. It is deliberately high
-- enough for very large proof modules while preventing a corrupt CBOR header
-- from requesting an effectively unbounded allocation.
maxContainerLength :: Int
maxContainerLength = 10_000_000

decodeBoundedListLen :: String -> Decoder s Int
decodeBoundedListLen label = do
  length' <- decodeListLen
  unless
    (length' <= maxContainerLength)
    (fail (label <> " exceeds maximum container length"))
  pure length'

decodeBoundedEnum :: forall a s. (Bounded a, Enum a) => String -> Decoder s a
decodeBoundedEnum label = do
  value <- decodeWord
  let lower = fromEnum (minBound @a)
      upper = fromEnum (maxBound @a)
      value' = fromIntegral value
  if value' >= lower && value' <= upper
    then pure (toEnum value')
    else fail ("invalid " <> label)

expectListLen :: Int -> Decoder s ()
expectListLen expected = do
  actual <- decodeListLen
  unless (actual == expected) (fail "unexpected CBOR array length")
