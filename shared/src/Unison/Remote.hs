{-# Language DeriveGeneric #-}
{-# Language DeriveFoldable #-}
{-# Language DeriveFunctor #-}
{-# Language DeriveTraversable #-}

module Unison.Remote where

import qualified Unison.Hashable as Hashable
import Unison.Hashable (Hashable, Hashable1)
import GHC.Generics
import Data.Text (Text)
import Data.Aeson (ToJSON,FromJSON)
import qualified Data.Text as Text

-- `t` will be a Unison term, generally
data Remote t = Step (Step t) | Bind (Step t) t deriving (Generic,Show,Eq,Foldable,Functor,Traversable)
instance ToJSON t => ToJSON (Remote t)
instance FromJSON t => FromJSON (Remote t)

data Step t = Local (Local t) | At Node t deriving (Generic,Show,Eq,Foldable,Functor,Traversable)
instance ToJSON t => ToJSON (Step t)
instance FromJSON t => FromJSON (Step t)

data Local t
  -- fork : Remote a -> Local ()
  = Fork (Remote t)
  -- channel : Local (Channel a)
  | CreateChannel
  -- here : Local Node
  | Here
  -- receiveAsync : Channel a -> Local (Local a)
  | ReceiveAsync Channel Timeout
  -- receive : Channel a -> Local a
  | Receive Channel
  -- send : a -> Channel a -> Local ()
  | Send t Channel
  | Pure t deriving (Generic,Show,Eq,Foldable,Functor,Traversable)
instance ToJSON t => ToJSON (Local t)
instance FromJSON t => FromJSON (Local t)
instance Hashable1 Remote where
  hash1 hashCycle hash r = error "todo"

newtype Timeout = Seconds { seconds :: Double } deriving (Eq,Ord,Show,Generic)
instance ToJSON Timeout
instance FromJSON Timeout
instance Hashable Timeout where
  tokens (Seconds seconds) = [Hashable.Double seconds]


{-
When sending a `Remote` value to a `Node` for evaluation,
the implementation syncs any needed hashes for just the
outermost `Local`, then begins evaluation of the `Local`.
Concurrent with evaluation it syncs any needed hashes for
the continuation of the `Bind` (ignoring this step for a
purely `Local` computation).

When both the `Local` portion of the computation has completed
and any hashes needed by the continuation have also been
synced, the continuation is invoked and evaluated and the
computation is sent to the specified `Node` for its next step.
Note that the computation never 'returns', and it may run forever,
hopping between different nodes. To return a result to some node,
we use some of the effects in `Local` to write the final step to
a channel from which we `receive`.
-}

newtype Base64 = Base64 Text deriving (Eq,Ord,Generic,Show)
instance ToJSON Base64
instance FromJSON Base64
instance Hashable Base64 where
  tokens (Base64 txt) = [Hashable.Text txt]


-- | A node is a host and a public key. For instance: `Node "unisonweb.org" key`
data Node = Node { host :: Text, publicKey :: Base64 } deriving (Eq,Ord,Generic)
instance ToJSON Node
instance FromJSON Node
instance Hashable Node where
  tokens (Node host (Base64 key)) = [Hashable.Text host, Hashable.Text key]

instance Show Node where
  show (Node host (Base64 key)) = "http://" ++ Text.unpack host ++ "/" ++ Text.unpack key

newtype Channel = Channel Base64 deriving (Eq,Ord,Generic,Show)
instance ToJSON Channel
instance FromJSON Channel
instance Hashable Channel where tokens (Channel c) = Hashable.tokens c
