{-# LANGUAGE DeriveGeneric #-}
module Data.Store.Rev.Change (Key, Value, Change(..))
where

import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.UUID.Types (UUID)
import GHC.Generics (Generic)

type Key = UUID
type Value = ByteString

-- TODO: Store the smaller of (Maybe Value) and (IRef Value)
data Change = Change
    { objectKey :: Key
    , oldValue :: Maybe Value
    , newValue :: Maybe Value
    } deriving (Eq, Ord, Show, Read, Generic)
instance Binary Change
