{-# LANGUAGE FlexibleContexts, NumericUnderscores, ScopedTypeVariables, TypeFamilies, FlexibleInstances, GeneralizedNewtypeDeriving, TemplateHaskell, UndecidableInstances, StandaloneDeriving, DerivingVia, RecordWildCards, LambdaCase #-}
-- |This module provides an abstraction over the operations done in the LMDB database that serves as a backend for storing blocks and finalization records.

module Concordium.GlobalState.Persistent.LMDB (
  DatabaseHandlers (..)
  , storeEnv
  , blockStore
  , finalizationRecordStore
  , initialDatabaseHandlers
  , LMDBStoreType (..)
  , LMDBStoreMonad (..)
  , putOrResize
  ) where

import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Block
import Concordium.GlobalState.Classes
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Persistent.BlockPointer
import Concordium.Types
import Concordium.Crypto.SHA256
import Concordium.Types.HashableTo
import Control.Exception
import Control.Monad.IO.Class
import Data.ByteString
import Data.Serialize as S (put, runPut, Put)
import Database.LMDB.Raw
import Database.LMDB.Simple as L
import Lens.Micro.Platform
import System.Directory

-- |Values used by the LMDBStoreMonad to manage the database
data DatabaseHandlers bs = DatabaseHandlers {
    _limits :: Limits,
    _storeEnv :: Environment ReadWrite,
    _blockStore :: Database BlockHash ByteString,
    _finalizationRecordStore :: Database FinalizationIndex FinalizationRecord
}
makeLenses ''DatabaseHandlers

blockStoreName :: String
blockStoreName = "blocks"
finalizationRecordStoreName :: String
finalizationRecordStoreName = "finalization"

-- |Initialize the database handlers creating the databases if needed and writing the genesis block and its finalization record into the disk
initialDatabaseHandlers :: PersistentBlockPointer bs -> S.Put -> RuntimeParameters -> IO (DatabaseHandlers bs)
initialDatabaseHandlers gb serState RuntimeParameters{..} = liftIO $ do
  -- The initial mapsize needs to be high enough to allocate the genesis block and its finalization record or
  -- initialization would fail. It also needs to be a multiple of the OS page size. We considered keeping 4096 as a typical
  -- OS page size and setting the initial mapsize to 64MB which is very unlikely to be reached just by the genesis block.
  let _limits = defaultLimits { mapSize = 2^(26 :: Int), maxDatabases = 2 } -- 64MB
  createDirectoryIfMissing False rpTreeStateDir
  _storeEnv <- openEnvironment rpTreeStateDir _limits
  _blockStore <- transaction _storeEnv
    (getDatabase (Just "blocks") :: L.Transaction ReadWrite (Database BlockHash ByteString))
  _finalizationRecordStore <- transaction _storeEnv
    (getDatabase (Just "finalization") :: L.Transaction ReadWrite (Database FinalizationIndex FinalizationRecord))
  let gbh = getHash gb
      gbfin = FinalizationRecord 0 gbh emptyFinalizationProof 0
  transaction _storeEnv (L.put _blockStore (getHash gb) (Just $ runPut (putBlock gb <> serState <> S.put (BlockHeight 0))))
  transaction _storeEnv (L.put _finalizationRecordStore 0 (Just gbfin))
  return $ DatabaseHandlers {..}

resizeDatabaseHandlers :: DatabaseHandlers bs -> Int -> IO (DatabaseHandlers bs)
resizeDatabaseHandlers dbh size = do
  let step = 2^(26 :: Int)
      delta = size + (step - size `mod` step)
      lim = (dbh ^. limits)
      newSize = mapSize lim + delta
      _limits = lim { mapSize = newSize }
      _storeEnv = dbh ^. storeEnv
  resizeEnvironment _storeEnv newSize
  _blockStore <- transaction _storeEnv (getDatabase (Just blockStoreName) :: Transaction ReadWrite (Database BlockHash ByteString))
  _finalizationRecordStore <- transaction _storeEnv (getDatabase (Just finalizationRecordStoreName) :: Transaction ReadWrite (Database FinalizationIndex FinalizationRecord))
  return DatabaseHandlers {..}

-- |For now the database only supports two stores: blocks and finalization records.
-- In order to abstract the database access, this datatype was created.
-- When implementing `putOrResize` a tuple will need to be created and `putInProperDB` will choose the correct database.
data LMDBStoreType = Block (BlockHash, ByteString) -- ^The Blockhash and the serialized form of the block
               | Finalization (FinalizationIndex, FinalizationRecord) -- ^The finalization index and the associated finalization record
               deriving (Show)

lmdbStoreTypeSize :: LMDBStoreType -> Int
lmdbStoreTypeSize (Block (_, v)) = digestSize + Data.ByteString.length v
lmdbStoreTypeSize (Finalization (_, v)) = let FinalizationProof (vs, _)  = finalizationProof v in
  -- key + finIndex + finBlockPointer + finProof (list of Word32s + BlsSignature.signatureSize) + finDelay
  64 + 64 + digestSize + (32 * Prelude.length vs) + 48 + 64

-- | Depending on the variant of the provided tuple, this function will perform a `put` transaction in the
-- correct database.
putInProperDB :: LMDBStoreType -> DatabaseHandlers bs -> IO ()
putInProperDB (Block (key, value)) dbh = do
  let env = dbh ^. storeEnv
  transaction env $ L.put (dbh ^. blockStore) key (Just value)
putInProperDB (Finalization (key, value)) dbh =  do
  let env = dbh ^. storeEnv
  transaction env $ L.put (dbh ^. finalizationRecordStore) key (Just value)

-- |Provided default function that tries to perform an insertion in a given database of a given value,
-- altering the environment if needed when the database grows.
putOrResize :: MonadIO m => DatabaseHandlers bs -> LMDBStoreType -> m (DatabaseHandlers bs)
putOrResize dbh tup = liftIO $ handleJust selectDBFullError handleResize tryResizeDB
    where tryResizeDB = dbh <$ putInProperDB tup dbh
          -- only handle the db full error and propagate other exceptions.
          selectDBFullError = \case (LMDB_Error _ _ (Right MDB_MAP_FULL)) -> Just ()
                                    _ -> Nothing
          -- Resize the database handlers, and try to add again in case the size estimate
          -- given by lmdbStoreTypeSize is off.
          handleResize () = do
            dbh' <- resizeDatabaseHandlers dbh (lmdbStoreTypeSize tup)
            putOrResize dbh' tup

-- |Monad to abstract over the operations for reading and writing from a LMDB database. It provides functions for reading and writing Blocks and FinalizationRecords.
-- The databases should be indexed by the @BlockHash@ and the @FinalizationIndex@ in each case.
class (MonadIO m) => LMDBStoreMonad m where
   writeBlock :: BlockPointer m -> m ()

   readBlock :: BlockHash -> m (Maybe (BlockPointer m))

   writeFinalizationRecord :: FinalizationRecord -> m ()

   readFinalizationRecord :: FinalizationIndex -> m (Maybe FinalizationRecord)
