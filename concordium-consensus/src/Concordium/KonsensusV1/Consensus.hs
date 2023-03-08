{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Concordium.KonsensusV1.Consensus where

import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Maybe (isJust)
import qualified Data.Vector as Vector

import Lens.Micro.Platform

import qualified Concordium.KonsensusV1.TreeState.LowLevel as LowLevel
import Concordium.KonsensusV1.TreeState.Implementation
import Concordium.KonsensusV1.TreeState.LowLevel (MonadTreeStateStore (writeCurrentRoundStatus))
import qualified Concordium.KonsensusV1.TreeState.LowLevel as LowLevel
import Concordium.KonsensusV1.TreeState.Types
import Concordium.KonsensusV1.Types
import Concordium.Types
import Concordium.Types.BakerIdentity
import Concordium.Utils

-- |A Monad for multicasting timeout messages.
class MonadMulticast m where
    -- |Multicast a timeout message over the network
    sendTimeoutMessage :: TimeoutMessage -> m ()

-- |A baker context containing the baker identity. Used for accessing relevant baker keys and the baker id.
newtype BakerContext = BakerContext
    { _bakerIdentity :: BakerIdentity
    }

makeClassy ''BakerContext

-- |A Monad for timer related actions.
class MonadTimeout m where
    -- |Reset the timeout from the supplied 'Duration'.
    resetTimer :: Duration -> m ()

-- |Return 'Just FinalizerInfo' if the consensus running
-- is part of the of the provided 'BakersAndFinalizers'.
-- Otherwise return 'Nothing'.
isBakerFinalizer ::
    BakerId ->
    -- |A collection of bakers and finalizers.
    BakersAndFinalizers ->
    -- |'True' if the consensus is part of the finalization committee.
    -- Otherwise 'False'
    Maybe FinalizerInfo
isBakerFinalizer bakerId bakersAndFinalizers = do
    -- This is O(n) but in principle we could do binary search here as the 'committeeFinalizers' are
    -- sorted by ascending baker id.
    Vector.find (\finalizerInfo -> finalizerBakerId finalizerInfo == bakerId) finalizers
  where
    finalizers = committeeFinalizers $ bakersAndFinalizers ^. bfFinalizers

-- |Produce a block and multicast it onto the network.
makeBlock :: MonadState (SkovData (MPV m)) m => m ()
makeBlock = return ()

-- |Make a block if the consensus runner is leader for the
-- current round.
-- TODO: call 'makeBlock' if we're leader for the current round.
makeBlockIfLeader :: MonadState (SkovData (MPV m)) m => m ()
makeBlockIfLeader = return ()

-- |Advance to the provided 'Round'.
--
-- This function does the following:
-- * Update the current 'RoundStatus'.
-- * Persist the new 'RoundStatus'.
-- * If the consensus runner is leader in the new
--   round then make the new block.
advanceRound ::
    ( MonadReader r m,
      HasBakerContext r,
      MonadTimeout m,
      LowLevel.MonadTreeStateStore m,
      MonadState (SkovData (MPV m)) m
    ) =>
    -- |The 'Round' to progress to.
    Round ->
    -- |If we are advancing from a round that timed out
    -- then this will be @Just 'TimeoutCertificate, 'QuorumCertificate')@ otherwise
    -- 'Nothing'.
    --
    -- In case of the former then the 'TimeoutCertificate' is from the round we're
    -- advancing from and the associated 'QuorumCertificate' verifies it.
    Maybe (TimeoutCertificate, QuorumCertificate) ->
    m ()
advanceRound newRound timedOut = do
    myBakerId <- bakerId <$> view bakerIdentity
    currentRoundStatus <- use roundStatus
    -- Reset the timeout timer if the consensus runner is part of the
    -- finalization committee.
    resetTimerIfFinalizer myBakerId (rsCurrentTimeout currentRoundStatus)
    -- Advance the round.
    roundStatus .=! advanceRoundStatus newRound timedOut currentRoundStatus
    -- Write the new round status to disk.
    writeCurrentRoundStatus =<< use roundStatus
    -- Make a new block if the consensus runner is leader of
    -- the 'Round' progressed to.
    makeBlockIfLeader
  where
    -- Reset the timer if this consensus instance is member of the
    -- finalization committee for the current 'Epoch'.
    resetTimerIfFinalizer bakerId currentTimeout = do
        currentEpoch <- rsCurrentEpoch <$> use roundStatus
        gets (getBakersForLiveEpoch currentEpoch) >>= \case
            Nothing -> return () -- No bakers or finalizers could be looked up for the current 'Epoch' so we do nothing.
            Just bakersAndFinalizers -> do
                if isJust $! isBakerFinalizer bakerId bakersAndFinalizers
                    then -- The consensus runer is a finalizer for the current epoch then we reset the timer
                        resetTimer currentTimeout
                    else return () -- The consensus runner is not part of the finalization committee, so we don't have to do anything.

-- |Advance the 'Epoch' of the current 'RoundStatus'.
--
-- Advancing epochs in particular carries out the following:
-- * Updates the 'rsCurrentEpoch' to the provided 'Epoch' for the current 'RoundStatus'.
-- * Computes the new 'LeadershipElectionNonce' and updates the current 'RoundStatus'.
-- * Updates the 'rsLatestEpochFinEntry' of the current 'RoundStatus' to @Present finalizationEntry@.
advanceEpoch :: (MonadState (SkovData (MPV m)) m,
               LowLevel.MonadTreeStateStore m) => Epoch -> FinalizationEntry ->  m ()
advanceEpoch newEpoch finalizationEntry = do
    currentRoundStatus <- use roundStatus
    
    return ()



