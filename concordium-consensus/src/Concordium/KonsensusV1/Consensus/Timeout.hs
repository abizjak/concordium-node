{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Concordium.KonsensusV1.Consensus.Timeout where

import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State
import Data.Foldable
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Ratio
import qualified Data.Set as Set
import Data.Word
import Lens.Micro.Platform

import Concordium.Genesis.Data.BaseV1
import Concordium.Logger
import Concordium.TimeMonad
import Concordium.Types
import Concordium.Types.BakerIdentity
import Concordium.Types.Parameters hiding (getChainParameters)
import Concordium.Utils

import Concordium.GlobalState.BlockState
import Concordium.GlobalState.Persistent.BlockState
import qualified Concordium.GlobalState.Persistent.BlockState as PBS
import Concordium.GlobalState.Types
import qualified Concordium.GlobalState.Types as GSTypes
import Concordium.KonsensusV1.Consensus
import Concordium.KonsensusV1.Consensus.Finality (checkFinality)
import Concordium.KonsensusV1.Flag
import Concordium.KonsensusV1.TreeState.Implementation
import qualified Concordium.KonsensusV1.TreeState.LowLevel as LowLevel
import Concordium.KonsensusV1.TreeState.Types
import Concordium.KonsensusV1.Types

-- |Reasons that a 'TimeoutMessage' can be rejected.
data ReceiveTimeoutMessageRejectReason
    = -- |The 'Round' presented in the 'TimeoutMessage' is obsolete.
      ObsoleteRound
    | -- | The 'QuorumCertificate' associated with the 'TimeoutMessage' is for
      -- either an obsolete 'Round' or 'Epoch'.
      ObsoleteQC
    | -- |The signer of the 'TimeoutMessage' is not a finalizer for the
      -- current 'Epoch'.
      NotAFinalizer
    | -- |The signature on the 'TimeoutMessage' is invalid.
      InvalidSignature
    | -- |The finalizer already signed a 'TimeoutMessage' for the
      -- current round.
      DoubleSigning
    | -- |The 'QuorumCertificate' is pointing to a block prior
      -- to the last finalized block.
      ObsoleteQCPointer
    | -- |The 'QuorumCertificate' is ponting to a dead block.
      DeadQCPointer
    | -- |The BLS signature was invalid.
      InvalidBLSSignature
    deriving (Eq, Show)

-- |Possibly return codes for when receiving
-- a 'TimeoutMessage'.
data ReceiveTimeoutMessageResult
    = -- |The 'TimeoutMessage' was well received and should
      -- be relayed onto the network.
      Received !PartiallyVerifiedTimeoutMessage
    | -- |The 'TimeoutMessage' could not be verified and should not be
      -- relayed.
      Rejected !ReceiveTimeoutMessageRejectReason
    | -- |The consensus runner needs to catch up before processing the
      -- 'TimeoutMessage'.
      CatchupRequired
    | -- |The 'TimeoutMessage' is a duplicate.
      Duplicate
    deriving (Eq, Show)

-- |A partially verified 'TimeoutMessage' with its associated finalization committees.
-- The timeout message is verified itself but the associated quorum certificate is not.
data PartiallyVerifiedTimeoutMessage = MkPartiallyVerifiedTimeoutMessage
    { -- |The 'TimeoutMessage' that has been partially verified
      pvtm :: !TimeoutMessage,
      -- |The finalization committee with respect to the 'QuorumCertificate' contained
      -- in the 'TimeoutMessage'.
      pvtmQuorumFinalizers :: !FinalizationCommittee
    }
    deriving (Eq, Show)

makeLenses ''PartiallyVerifiedTimeoutMessage

-- |Receive and verify the basics of a 'TimeoutMessage' with respect to
-- the supplied tree state.
-- If this function returns @Received PartiallyVerifiedTimeoutMessage@ then 'executeTimeoutMessage' MUST
-- be invoked immediately after relaying the message. Hence there must be no changes to the tree state in the mean time.
receiveTimeoutMessage ::
    LowLevel.MonadTreeStateStore m =>
    -- |The 'TimeoutMessage' to receive.
    TimeoutMessage ->
    -- |The tree state to verify the 'TimeoutMessage' within.
    SkovData (MPV m) ->
    -- |Result of receiving the 'TimeoutMessage'.
    m ReceiveTimeoutMessageResult
receiveTimeoutMessage tm@TimeoutMessage{tmBody = body@TimeoutMessageBody{..}} skovData = receive
  where
    receive
        --  The round of the 'TimeoutMessage' is obsolete.
        | tmRound < skovData ^. roundStatus . rsCurrentRound =
            return $ Rejected ObsoleteRound
        -- If the round or epoch of the qc associated with the timeout message
        -- is behind the last finalized block then reject the timeout message,
        -- then it means that the sender of the timeout message was lacking behind for some reason.
        -- This can for instance happen if the sender of the timeout message
        -- did not receive the quourum message before sending out the time out message
        -- due to e.g. network issues.
        | qcRound tmQuorumCertificate < skovData ^. lastFinalized . to blockRound
            || qcEpoch tmQuorumCertificate < skovData ^. lastFinalized . to blockEpoch =
            return $ Rejected ObsoleteQC
        -- Before looking up the finalizer we check whether the message is from
        -- a future epoch. If that is the case then we should catch up as
        -- we cannot determine whether the proposed finalizer is actually part of the
        -- finalization committee.
        | tmEpoch > theCurrentEpoch =
            return CatchupRequired
        -- Obtain the finalizer information for the signer of the
        -- timeout message.
        | otherwise = case (getFinalizer, qcEpochFinalizationCommittee) of
            -- Signer is not present in the finalization committee in the
            -- proposed epoch specified by the 'TimeoutMessage', hence
            -- the timeout message is rejected.
            (Nothing, _) -> return $ Rejected NotAFinalizer
            -- Since we can't retrieve the finalization committee with respect
            -- to the qc pointer then we must initiate catch up.
            -- Note that the deserialization checks that the timeout message consists
            -- of coherent rounds i.e. (tm round > qc pointer round)
            (Just _, Nothing) -> return CatchupRequired
            (Just FinalizerInfo{..}, Just qcFinalizationCommittee)
                -- Check whether the signature is ok or not.
                | not (checkTimeoutMessageSignature finalizerSignKey genesisBlockHash tm) ->
                    return $ Rejected InvalidSignature
                -- Consensus runner is not caught up to the round that the timeout message
                -- refers to. So catch up is required.
                | tmRound > currentRound,
                  qcRound tmQuorumCertificate < tmRound - 1 ->
                    return CatchupRequired
                | otherwise -> do
                    getRecentBlockStatus (qcBlock tmQuorumCertificate) skovData >>= \case
                        -- The timeout message does not act according to the longest chain rule
                        -- so it is rejected.
                        OldFinalized -> do
                            return $ Rejected ObsoleteQCPointer
                        -- With respect to the checks carried out above then in case of branching
                        -- in a round it must be checked whether the qc pointer is known or not.
                        -- If the latter then the consensus runner needs to inititate catchup.
                        RecentBlock BlockUnknown -> do
                            return CatchupRequired
                        -- The qc pointer points to a block that has been marked deadp
                        RecentBlock BlockDead -> do
                            return $ Rejected DeadQCPointer
                        -- The qc pointer in the timeout message is pending so catch up
                        -- is required
                        RecentBlock (BlockPending _) ->
                            return CatchupRequired
                        RecentBlock (BlockFinalized _) -> checkWithValidQCPointer finalizerBlsKey qcFinalizationCommittee
                        RecentBlock (BlockAlive _) -> checkWithValidQCPointer finalizerBlsKey qcFinalizationCommittee
    -- Check the quorum message when the qc pointer is alive or finalized.
    checkWithValidQCPointer finalizerBlsKey qcFinalizationCommittee =
        case getExistingMessage of
            Just existingMessage -> do
                -- If timeout message is a duplicate, we report back this fact.
                if existingMessage == tm
                    then return Duplicate
                    else do
                        -- The finalizer has already sent a timeout message for this round, this is not
                        -- allowed so the behavior is flagged and timeout message is rejected.
                        flag $! TimeoutDoubleSigning tm existingMessage
                        return $ Rejected DoubleSigning
            -- Return a 'PartiallyVerifiedTimeoutMessage'
            Nothing ->
                if not (checkTimeoutSignatureSingle (tmSignatureMessage genesisBlockHash body) finalizerBlsKey tmAggregateSignature)
                    then do
                        flag $ InvalidTimeoutSignature tm
                        return $ Rejected InvalidBLSSignature
                    else return $ Received $ MkPartiallyVerifiedTimeoutMessage tm qcFinalizationCommittee
    -- The finalization committee for the proposed qc epoch if present.
    qcEpochFinalizationCommittee = _bfFinalizers <$> getBakersForLiveEpoch (qcEpoch tmQuorumCertificate) skovData
    -- Get an existing message if present otherwise return nothing.
    getExistingMessage = case skovData ^. receivedTimeoutMessages of
        Absent -> Nothing
        Present messages -> messages ^? to tmFirstEpochTimeouts . ix tmFinalizerIndex
    -- The genesis block hash.
    genesisBlockHash = skovData ^. genesisMetadata . to gmFirstGenesisHash
    -- The current round with respect to the tree state supplied.
    currentRound = skovData ^. roundStatus . rsCurrentRound
    -- The current epoch with respect to the tree state supplied.
    theCurrentEpoch = skovData ^. skovEpochBakers . currentEpoch
    -- Try get the 'FinalizerInfo' given the epoch and finalizer index
    -- of the 'TimeoutMessage'.
    getFinalizer = do
        bakers <- getBakersForLiveEpoch tmEpoch skovData
        finalizerByIndex (bakers ^. bfFinalizers) tmFinalizerIndex

-- |The result of executing a 'TimeoutMessage'.
data ExecuteTimeoutMessageResult
    = -- |The 'TimeoutMessage' was succesfully executed.
      ExecutionSuccess
    | -- |The 'QuorumCertificate' for the 'TimeoutMessage'
      -- is invalid.
      InvalidQC !QuorumCertificate
    | -- |The 'QuorumCertificate' for the 'TimeoutMessage'
      -- is for a wrong 'Epoch'.
      InvalidQCEpoch !Epoch !QuorumCertificate
    deriving (Eq, Show)

-- |Execute a 'PartiallyVerifiedTimeoutMessage' that has been _received_ ('receiveTimeoutMessage') prior to
-- this call.
--
-- This function verifies the 'QuorumCertificate' and possibly advances the round.
-- This function also makes sure the check whether a block can be finalized due to the
-- 'QuorumCertificate' of the 'TimeoutMessage'.
executeTimeoutMessage ::
    ( IsConsensusV1 (MPV m),
      MonadThrow m,
      MonadIO m,
      BlockStateStorage m,
      TimeMonad m,
      MonadTimeout m,
      MonadState (SkovData (MPV m)) m,
      MonadLogger m,
      GSTypes.BlockState m ~ PBS.HashedPersistentBlockState (MPV m),
      LowLevel.MonadTreeStateStore m
    ) =>
    -- |The partially verified 'TimeoutMessage' to execute.
    PartiallyVerifiedTimeoutMessage ->
    -- |Returns @Left TimeoutMessage@ if the 'QuorumCertificate' could not be verified,
    -- and otherwise @Right ()@.
    m ExecuteTimeoutMessageResult
executeTimeoutMessage (MkPartiallyVerifiedTimeoutMessage tm@TimeoutMessage{tmBody = TimeoutMessageBody{..}} qcCommittee) = do
    highestQCRound <- use (roundStatus . rsHighestQC . to qcRound)
    -- Check the quorum certificate if it's from a round we have not checked before.
    if qcRound tmQuorumCertificate > highestQCRound
        then do
            checkQC >>= \case
                -- Stop and flag if the quorum certificate is invalid.
                False -> do
                    flag $! TimeoutMessageInvalidQC tm
                    return $ InvalidQC tmQuorumCertificate
                -- The quorum certificate is valid and we check whether we can
                -- advance by it.
                True -> do
                    -- Check if the quorum certificate of the timeout message
                    -- finalizes any blocks.
                    checkFinality tmQuorumCertificate
                    -- Update the highest QC seen.
                    roundStatus . rsHighestQC .= tmQuorumCertificate
                    -- Advance the round if we can advance by the quorum certificate.
                    currentRound <- use $ roundStatus . rsCurrentRound
                    when (currentRound <= qcRound tmQuorumCertificate) $ do
                        advanceRound (currentRound + 1) (Right tmQuorumCertificate)
                    -- Record the witness of the quorum certificate in the existing qcs on the treestate.
                    roundExistingQuorumCertificate (qcRound tmQuorumCertificate) ?= toQuorumCertificateWitness tmQuorumCertificate
                    -- Process the timeout
                    processTimeout tm
                    return ExecutionSuccess
        else do
            -- Check whether we have already checked a qc for the round
            -- As the timeout message has been succesfully received before this we know that the qc
            -- is for a round greater than the last finalized block.
            use (roundExistingQuorumCertificate (qcRound tmQuorumCertificate)) >>= \case
                Just (QuorumCertificateWitness qcEpoch') -> do
                    -- the qc is invalid since it was for another epoch.
                    if qcEpoch' /= qcEpoch tmQuorumCertificate
                        then do
                            flag $ TimeoutMessageInvalidQC tm
                            return $ InvalidQCEpoch qcEpoch' tmQuorumCertificate
                        else do
                            processTimeout tm
                            return ExecutionSuccess
                Nothing ->
                    checkQC >>= \case
                        -- the quorum certificate is not valid so flag and stop.
                        False -> do
                            flag $! TimeoutMessageInvalidQC tm
                            return $ InvalidQC tmQuorumCertificate
                        -- The quorum certificate is valid so check whether it finalises any blocks.
                        True -> do
                            checkFinality tmQuorumCertificate
                            processTimeout tm
                            return ExecutionSuccess
  where
    -- Check the quorum certificate of the timeout message.
    checkQC = do
        genesisBlockHash <- use $ genesisMetadata . to gmFirstGenesisHash
        signatureThreshold <- use $ genesisMetadata . to gmParameters . to genesisSignatureThreshold
        return $! checkQuorumCertificate genesisBlockHash (toRational signatureThreshold) qcCommittee tmQuorumCertificate

-- |Helper function for calcuculating a new @currentTimeout@ given the old @currentTimeout@
-- and the @timeoutIncrease@ chain parameter.
updateCurrentTimeout :: Ratio Word64 -> Duration -> Duration
updateCurrentTimeout timeoutIncrease oldCurrentTimeout =
    let timeoutIncreaseRational = toRational timeoutIncrease :: Rational
        currentTimeOutRational = toRational oldCurrentTimeout :: Rational
        newCurrentTimeoutRational = timeoutIncreaseRational * currentTimeOutRational :: Rational
        newCurrentTimeoutInteger = floor newCurrentTimeoutRational :: Integer
    in  Duration $ fromIntegral newCurrentTimeoutInteger

-- |Grow the current timeout duration in response to an elapsed timeout.
-- This updates the timeout to @timeoutIncrease * oldTimeout@.
growTimeout ::
    ( BlockState m ~ HashedPersistentBlockState (MPV m),
      IsConsensusV1 (MPV m),
      BlockStateQuery m,
      MonadState (SkovData (MPV m)) m
    ) =>
    -- |Block to take the timeout parameters from
    BlockPointer (MPV m) ->
    m ()
growTimeout blockPtr = do
    chainParams <- getChainParameters $ bpState blockPtr
    let timeoutIncrease =
            chainParams
                ^. cpConsensusParameters . cpTimeoutParameters . tpTimeoutIncrease
    currentTimeout %=! \oldCurrentTimeout -> updateCurrentTimeout timeoutIncrease oldCurrentTimeout

-- |This is 'uponTimeoutEvent' from the bluepaper. If a timeout occurs, a finalizers should call this function to
-- generate, send out a timeout message and process it.
-- NB: If the caller is not a finalizer, this function does nothing.
uponTimeoutEvent ::
    ( MonadTimeout m,
      MonadMulticast m,
      MonadReader r m,
      HasBakerContext r,
      BlockStateQuery m,
      BlockState m ~ HashedPersistentBlockState (MPV m),
      IsConsensusV1 (MPV m),
      MonadState (SkovData (MPV m)) m,
      LowLevel.MonadTreeStateStore m
    ) =>
    m ()
uponTimeoutEvent = do
    maybeBakerIdentity <- view bakerIdentity
    forM_ maybeBakerIdentity $ \BakerIdentity{..} -> do
        eBakers <- use skovEpochBakers

        let finComm = eBakers ^. currentEpochBakers . bfFinalizers
        let maybeFinalizer = finalizerByBakerId finComm bakerId

        forM_ maybeFinalizer $ \finInfo -> do
            lastFinBlockPtr <- use lastFinalized
            growTimeout lastFinBlockPtr

            genesisHash <- use currentGenesisHash
            currentRoundStatus <- use roundStatus
            let curRound = _rsCurrentRound currentRoundStatus
            let highestQC = _rsHighestQC currentRoundStatus

            let timeoutSigMessage =
                    TimeoutSignatureMessage
                        { tsmGenesis = genesisHash,
                          tsmRound = curRound,
                          tsmQCRound = qcRound highestQC,
                          tsmQCEpoch = qcEpoch highestQC
                        }
            let timeoutSig = signTimeoutSignatureMessage timeoutSigMessage bakerAggregationKey

            let timeoutMessageBody =
                    TimeoutMessageBody
                        { tmFinalizerIndex = finalizerIndex finInfo,
                          tmRound = curRound,
                          tmEpoch = _currentEpoch eBakers,
                          tmQuorumCertificate = highestQC,
                          tmAggregateSignature = timeoutSig
                        }
            let timeoutMessage = signTimeoutMessage timeoutMessageBody genesisHash bakerSignKey
            setRoundStatus $!
                currentRoundStatus
                    & rsLastSignedTimeoutMessage .~ Present timeoutMessage
            sendTimeoutMessage timeoutMessage
            processTimeout timeoutMessage

-- |Add a 'TimeoutMessage' to an existing set of timeout messages. Returns 'Nothing' if there is
-- no change (i.e. the new message was from an epoch that is too early).
-- The supplied timeout messages can be 'Absent' (i.e. there are no messages), but the return value
-- is only 'Nothing' when there is no change: if the timeout messages are updated, they will
-- always be non-empty (in particular, including the new message).
updateTimeoutMessages ::
    Option TimeoutMessages ->
    TimeoutMessage ->
    Maybe TimeoutMessages
updateTimeoutMessages tms tm =
    case tms of
        Absent ->
            Just $
                TimeoutMessages
                    { tmFirstEpoch = epoch,
                      tmFirstEpochTimeouts = singletonTimeout,
                      tmSecondEpochTimeouts = Map.empty
                    }
        Present TimeoutMessages{..}
            | epoch == tmFirstEpoch ->
                Just $
                    TimeoutMessages
                        { tmFirstEpochTimeouts = insertTimeout tmFirstEpochTimeouts,
                          ..
                        }
            | epoch == tmFirstEpoch + 1 ->
                Just $
                    TimeoutMessages
                        { tmSecondEpochTimeouts = insertTimeout tmSecondEpochTimeouts,
                          ..
                        }
            | epoch + 1 == tmFirstEpoch && null tmSecondEpochTimeouts ->
                Just $
                    TimeoutMessages
                        { tmFirstEpoch = epoch,
                          tmFirstEpochTimeouts = singletonTimeout,
                          tmSecondEpochTimeouts = tmFirstEpochTimeouts
                        }
            | epoch == tmFirstEpoch + 2 && not (null tmSecondEpochTimeouts) ->
                Just $
                    TimeoutMessages
                        { tmFirstEpoch = tmFirstEpoch + 1,
                          tmFirstEpochTimeouts = tmSecondEpochTimeouts,
                          tmSecondEpochTimeouts = singletonTimeout
                        }
            | epoch >= tmFirstEpoch + 2 ->
                Just $
                    TimeoutMessages
                        { tmFirstEpoch = epoch,
                          tmFirstEpochTimeouts = singletonTimeout,
                          tmSecondEpochTimeouts = Map.empty
                        }
            | otherwise -> Nothing
  where
    epoch = tmEpoch $ tmBody tm
    finIndex = tmFinalizerIndex $ tmBody tm
    singletonTimeout = Map.singleton finIndex tm
    insertTimeout = Map.insert finIndex tm

-- |Process a timeout message. This stores the timeout, and makes sure the stored timeout messages
-- do not span more than 2 epochs. If enough timeout messages are stored, we form a timeout certificate and
-- advance round.
--
-- Precondition:
-- * The given 'TimeoutMessage' is valid and has already been checked.
processTimeout ::
    ( MonadTimeout m,
      LowLevel.MonadTreeStateStore m,
      MonadState (SkovData (MPV m)) m
    ) =>
    TimeoutMessage ->
    m ()
processTimeout tm = do
    currentTimeoutMessages <- use receivedTimeoutMessages
    currentRoundStatus <- use roundStatus
    let highestQC = _rsHighestQC currentRoundStatus
    -- Add the new timeout message to the current messages.
    -- If the result is 'Nothing', then there was no change as a result, so nothing left to do.
    let maybeNewTimeoutMessages = updateTimeoutMessages currentTimeoutMessages tm
    forM_ maybeNewTimeoutMessages $ \newTimeoutMessages@TimeoutMessages{..} -> do
        receivedTimeoutMessages .=! Present newTimeoutMessages
        eBakers <- use skovEpochBakers
        let getFinalizersForEpoch epoch = (^. bfFinalizers) <$> getBakersForLiveEpoch epoch eBakers
        -- We should not fail to get the finalizers for the epoch of the highest QC, because it
        -- should either be the current epoch or the previous one.
        let maybeFinComm = getFinalizersForEpoch (qcEpoch highestQC)
        forM_ maybeFinComm $ \finCommQC -> do
            -- The baker IDs of the finalizers who have signed in the first epoch.
            let firstBakerIds
                    | Just firstFinComm <- getFinalizersForEpoch tmFirstEpoch =
                        bakerIdsFor firstFinComm tmFirstEpochTimeouts
                    | otherwise = Set.empty
            -- The baker IDs of the finalizers who have signed in the second epoch.
            let secondBakerIds
                    | not (null tmSecondEpochTimeouts),
                      Just secondFinComm <- getFinalizersForEpoch (tmFirstEpoch + 1) =
                        bakerIdsFor secondFinComm tmSecondEpochTimeouts
                    | otherwise = Set.empty
            -- Compute the voter power in the epoch of the highest QC for a baker by the baker ID.
            let getBakerVoterPower = fmap finalizerWeight . finalizerByBakerId finCommQC
            let voterPowerSum =
                    sum . mapMaybe getBakerVoterPower $
                        Set.toList (firstBakerIds `Set.union` secondBakerIds)
            -- TODO: Factor out finalizer weight check.
            let totalWeightRational = toRational $ committeeTotalWeight finCommQC
            genesisSigThreshold <- toRational . genesisSignatureThreshold . gmParameters <$> use genesisMetadata
            let voterPowerSumRational = toRational voterPowerSum
            when (voterPowerSumRational / totalWeightRational >= genesisSigThreshold) $ do
                let currentRound = _rsCurrentRound currentRoundStatus
                let tc = makeTimeoutCertificate currentRound newTimeoutMessages
                advanceRound (currentRound + 1) (Left (tc, highestQC))
  where
    bakerIdsFor finComm timeouts =
        Set.fromList $
            mapMaybe
                (fmap finalizerBakerId . finalizerByIndex finComm)
                (Map.keys timeouts)

-- |Make a 'TimeoutCertificate' from a 'TimeoutMessages'.
--
-- NB: It is not checked whether enough timeout messages are present.
-- This should be checked before calling 'makeTimeoutCertificate'.
makeTimeoutCertificate :: Round -> TimeoutMessages -> TimeoutCertificate
makeTimeoutCertificate currentRound TimeoutMessages{..} =
    TimeoutCertificate
        { tcRound = currentRound,
          tcMinEpoch = tmFirstEpoch,
          tcFinalizerQCRoundsFirstEpoch = toFinalizerRounds tmFirstEpochTimeouts,
          tcFinalizerQCRoundsSecondEpoch = toFinalizerRounds tmSecondEpochTimeouts,
          tcAggregateSignature =
            fold $ toAggSigs tmFirstEpochTimeouts ++ toAggSigs tmSecondEpochTimeouts
        }
  where
    -- Add an entry to a 'FinalizerRounds' map for a timeout message.
    foldHelper :: Map.Map Round FinalizerSet -> FinalizerIndex -> TimeoutMessage -> Map.Map Round FinalizerSet
    foldHelper finRounds finIndex tm =
        finRounds
            & at' roundOfQC . non emptyFinalizerSet %~ flip addFinalizer finIndex
      where
        roundOfQC = qcRound $ tmQuorumCertificate $ tmBody tm
    -- Convert timeout messages to 'FinalizerRounds'.
    toFinalizerRounds :: Map.Map FinalizerIndex TimeoutMessage -> FinalizerRounds
    toFinalizerRounds = FinalizerRounds . Map.foldlWithKey' foldHelper Map.empty
    -- Convert timeout messages to lists of signatures.
    toAggSigs :: Map.Map FinalizerIndex TimeoutMessage -> [TimeoutSignature]
    toAggSigs = fmap (tmAggregateSignature . tmBody) . Map.elems
