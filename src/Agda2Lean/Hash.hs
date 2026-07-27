{-# LANGUAGE DerivingStrategies #-}
module Agda2Lean.Hash
  ( ObjectHash (..)
  , hashBytes
  , objectHashBytes
  , renderObjectHash
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric (readHex)

newtype ObjectHash = ObjectHash {objectHashBytes :: ByteString}
  deriving stock (Eq, Ord, Show)

hashBytes :: ByteString -> ObjectHash
hashBytes bytes =
  ObjectHash (decodeHexBytes (show (hash bytes :: Digest SHA256)))

renderObjectHash :: ObjectHash -> Text
renderObjectHash (ObjectHash bytes) =
  Text.pack (ByteStringChar8.unpack (hexEncode bytes))

decodeHexBytes :: String -> ByteString
decodeHexBytes = ByteString.pack . go
  where
    go [] = []
    go (hi : lo : rest) =
      case readHex [hi, lo] of
        [(value, "")] -> fromIntegral value : go rest
        _ -> error "invalid SHA256 digest"
    go _ = error "invalid SHA256 digest length"

hexEncode :: ByteString -> ByteString
hexEncode = ByteString.concatMap encodeByte
  where
    digits = "0123456789abcdef" :: String
    encodeByte byte =
      ByteStringChar8.pack
        [ digits !! fromIntegral (byte `div` 16)
        , digits !! fromIntegral (byte `mod` 16)
        ]
