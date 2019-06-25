{-# LANGUAGE RecordWildCards, DeriveGeneric #-}
module Concordium.Birk.Bake where

import GHC.Generics
import Control.Monad.Trans.Maybe
import Control.Monad
import Control.Monad.IO.Class

import Data.Serialize

import Concordium.Types

import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Block
import Concordium.GlobalState.BlockState
import Concordium.GlobalState.TreeState
import Concordium.GlobalState.Transactions

import Concordium.Skov.Monad
import Concordium.Birk.LeaderElection
import Concordium.Kontrol.BestBlock

import Concordium.Skov.Update (updateFocusBlockTo)

import Concordium.Scheduler.TreeStateEnvironment(constructBlock)

import Concordium.Logger
import Concordium.TimeMonad


data BakerIdentity = BakerIdentity {
    bakerId :: BakerId,
    bakerSignKey :: BakerSignPrivateKey,
    bakerSignPublicKey :: BakerSignVerifyKey,
    bakerElectionKey :: BakerElectionPrivateKey,
    bakerElectionPublicKey :: BakerElectionVerifyKey
} deriving (Eq, Generic)

instance Serialize BakerIdentity where

processTransactions :: TreeStateMonad m => Slot -> BlockPointer m -> BlockPointer m -> BakerId -> m ([Transaction], BlockState m)
processTransactions slot bh finalizedP bid = do
  -- update the focus block to the parent block (establish invariant needed by constructBlock)
  updateFocusBlockTo bh
  -- at this point we can contruct the block. The function 'constructBlock' also
  -- updates the pending table and purges any transactions deemed invalid
  constructBlock slot bh finalizedP bid
  -- NB: what remains is to update the focus block to the newly constructed one.
  -- This is done in the method below once a block pointer is constructed.


bakeForSlot :: (SkovMonad m, TreeStateMonad m, MonadIO m) => BakerIdentity -> Slot -> m (Maybe BakedBlock)
bakeForSlot BakerIdentity{..} slot = runMaybeT $ do
    bb <- bestBlockBefore slot
    guard (blockSlot (bpBlock bb) < slot)
    birkParams@BirkParameters{..} <- getBirkParameters (bpState bb)
    (_, lotteryPower) <- MaybeT . pure $ birkBaker bakerId birkParams
    electionProof <- MaybeT . liftIO $
        leaderElection _birkLeadershipElectionNonce _birkElectionDifficulty slot bakerElectionKey lotteryPower
    logEvent Baker LLInfo $ "Won lottery in " ++ show slot
    nonce <- liftIO $ computeBlockNonce _birkLeadershipElectionNonce slot bakerElectionKey
    lastFinal <- lastFinalizedBlock
    (transactions, newState) <- processTransactions slot bb lastFinal bakerId
    let block = signBlock bakerSignKey slot (bpHash bb) bakerId electionProof nonce (bpHash lastFinal) transactions
    logEvent Baker LLInfo $ "Baked block"
    receiveTime <- currentTime
    newbp <- storeBakedBlock (makePendingBlock block receiveTime)
                         bb
                         lastFinal
                         newState
    -- update the current focus block to the newly created block to maintain invariants.
    putFocusBlock newbp
    logEvent Baker LLInfo $ "Finished bake block " ++ show newbp
    return block
