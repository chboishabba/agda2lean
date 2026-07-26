module Agda2Lean.Hash
  ( ObjectHash (..)
  , hashBytes
  , objectHashBytes
  , renderObjectHash
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text

newtype ObjectHash = ObjectHash {objectHashBytes :: ByteString}
  deriving stock (Eq, Ord, Show)

hashBytes :: ByteString -> ObjectHash
hashBytes bytes =
  ObjectHash (ByteArray.convert (hash bytes :: Digest SHA256))

renderObjectHash :: ObjectHash -> Text
renderObjectHash (ObjectHash bytes) =
  Text.concat (map renderByte (ByteString.unpack bytes))
  where
    digits = "0123456789abcdef"
    renderByte byte =
      Text.pack
        [ digits !! fromIntegral (byte `div` 16)
        , digits !! fromIntegral (byte `mod` 16)
        ]
