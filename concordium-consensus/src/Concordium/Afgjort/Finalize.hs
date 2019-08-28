{-# LANGUAGE RecordWildCards, ScopedTypeVariables, TemplateHaskell, LambdaCase, FlexibleContexts, MultiParamTypeClasses, RankNTypes, DerivingStrategies, DerivingVia, StandaloneDeriving #-}
module Concordium.Afgjort.Finalize (
    FinalizationMonad(..),
    FinalizationStateLenses(..),
    FinalizationInstance(..),
    FinalizationOutputEvent(..),
    FinalizationState(..),
    FinalizationSessionId(..),
    FinalizationPoint,
    FinalizationMessage(..),
    FinalizationMessageHeader,
    FinalizationQuery(..),
    FinalizationStateQuery(..),
    initialFinalizationState,
    verifyFinalProof,
    makeFinalizationCommittee,
    notifyBlockArrival,
    notifyBlockFinalized,
    receiveFinalizationMessage,
    nextFinalizationJustifierHeight,
    -- * Passive mode
    PassiveFinalizationState(..),
    PassiveFinalizationStateLenses(..),
    initialPassiveFinalizationState,
    passiveNotifyBlockFinalized,
    passiveReceiveFinalizationMessage,
    -- * For testing
    FinalizationRound(..)
) where

import qualified Data.Vector as Vec
import qualified Data.Map.Strict as Map
import Data.Map.Strict(Map)
import qualified Data.Set as Set
import Data.Set(Set)
import qualified Data.Serialize as S
import Data.Serialize.Put
import Data.Maybe
import Lens.Micro.Platform
import Control.Monad.State.Class
import Control.Monad.IO.Class
import Control.Monad

import qualified Concordium.Crypto.BlockSignature as Sig
import qualified Concordium.Crypto.VRF as VRF
import Concordium.Types
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.BlockState(BlockPointerData(..))
import Concordium.Kontrol
import Concordium.Afgjort.Types
import Concordium.Afgjort.WMVBA
import Concordium.Afgjort.Freeze (FreezeMessage(..))
import Concordium.Kontrol.BestBlock
import Concordium.Logger
import Concordium.Afgjort.Finalize.Types

atStrict :: (Ord k) => k -> Lens' (Map k v) (Maybe v)
atStrict k f m = f mv <&> \r -> case r of
        Nothing -> maybe m (const (Map.delete k m)) mv
        Just v' -> Map.insert k v' m
    where mv = Map.lookup k m
{-# INLINE atStrict #-}

members :: (Ord a) => a -> Lens' (Set a) Bool
members e = lens (Set.member e) upd
    where
        upd s True = Set.insert e s
        upd s False = Set.delete e s


data FinalizationRound = FinalizationRound {
    roundInput :: !(Maybe BlockHash),
    roundDelta :: !BlockHeight,
    roundMe :: !Party,
    roundWMVBA :: !(WMVBAState Sig.Signature)
}

instance Show FinalizationRound where
    show FinalizationRound{..} = "roundInput: " ++ take 11 (show roundInput) ++ " roundDelta: " ++ show roundDelta



ancestorAtHeight :: BlockPointerData bp => BlockHeight -> bp -> bp
ancestorAtHeight h bp
    | h == bpHeight bp = bp
    | h < bpHeight bp = ancestorAtHeight h (bpParent bp)
    | otherwise = error $ "ancestorAtHeight: block is below required height"

data PendingMessage = PendingMessage !Party !WMVBAMessage !Sig.Signature
    deriving (Eq, Ord, Show)

type PendingMessageMap = Map FinalizationIndex (Map BlockHeight (Set PendingMessage))

data FinalizationState = FinalizationState {
    _finsSessionId :: !FinalizationSessionId,
    _finsIndex :: !FinalizationIndex,
    _finsHeight :: !BlockHeight,
    _finsCommittee :: !FinalizationCommittee,
    _finsMinSkip :: !BlockHeight,
    _finsPendingMessages :: !PendingMessageMap,
    _finsCurrentRound :: !(Maybe FinalizationRound),
    _finsFailedRounds :: [Map Party Sig.Signature]
}
makeLenses ''FinalizationState

instance Show FinalizationState where
    show FinalizationState{..} = "finIndex: " ++ show (theFinalizationIndex _finsIndex) ++ " finHeight: " ++ show (theBlockHeight _finsHeight) ++ " currentRound:" ++ show _finsCurrentRound
        ++ "\n pendingMessages:" ++ show (Map.toList $ fmap (Map.toList . fmap Set.size)  _finsPendingMessages)

class FinalizationStateLenses s where
    finState :: Lens' s FinalizationState
    finSessionId :: Lens' s FinalizationSessionId
    finSessionId = finState . finsSessionId
    finIndex :: Lens' s FinalizationIndex
    finIndex = finState . finsIndex
    finHeight :: Lens' s BlockHeight
    finHeight = finState . finsHeight
    finCommittee :: Lens' s FinalizationCommittee
    finCommittee = finState . finsCommittee
    -- |The minimum distance between finalized blocks will be @1 + finMinSkip@.
    finMinSkip :: Lens' s BlockHeight
    finMinSkip = finState . finsMinSkip
    -- |All received finalization messages for the current and future finalization indexes.
    -- (Previously, this was just future messages, but now we store all of them for catch-up purposes.)
    finPendingMessages :: Lens' s PendingMessageMap
    finPendingMessages = finState . finsPendingMessages
    finCurrentRound :: Lens' s (Maybe FinalizationRound)
    finCurrentRound = finState . finsCurrentRound
    -- |For each failed round (from most recent to oldest), signatures
    -- on @WeAreDone False@ proving failure.
    finFailedRounds :: Lens' s [Map Party Sig.Signature]
    finFailedRounds = finState . finsFailedRounds

instance FinalizationStateLenses FinalizationState where
    finState = id

initialFinalizationState :: FinalizationInstance -> BlockHash -> FinalizationParameters -> FinalizationState
initialFinalizationState FinalizationInstance{..} genHash finParams = FinalizationState {
    _finsSessionId = FinalizationSessionId genHash 0,
    _finsIndex = 1,
    _finsHeight = 1 + finalizationMinimumSkip finParams,
    _finsCommittee = com,
    _finsMinSkip = finalizationMinimumSkip finParams,
    _finsPendingMessages = Map.empty,
    _finsCurrentRound = case filter (\p -> partySignKey p == Sig.verifyKey finMySignKey && partyVRFKey p == VRF.publicKey finMyVRFKey) (Vec.toList (parties com)) of
        [] -> Nothing
        (p:_) -> Just FinalizationRound {
            roundInput = Nothing,
            roundDelta = 1,
            roundMe = partyIndex p,
            roundWMVBA = initialWMVBAState
        },
    _finsFailedRounds = []
    }
    where
        com = makeFinalizationCommittee finParams

data FinalizationOutputEvent
    = BroadcastFinalizationMessage !FinalizationMessage
    | BroadcastFinalizationRecord !FinalizationRecord

class (SkovMonad m, MonadState s m, FinalizationStateLenses s, MonadIO m) => FinalizationMonad s m where
    broadcastFinalizationMessage :: FinalizationMessage -> m ()
    broadcastFinalizationRecord :: FinalizationRecord -> m ()
    requestMissingFinalization :: FinalizationIndex -> m ()
    requestMissingBlock :: BlockHash -> m ()
    -- |Request a block that is descended from the given block by the given height difference
    requestMissingBlockDescendant :: BlockHash -> BlockHeight -> m ()
    getFinalizationInstance :: m FinalizationInstance

tryNominateBlock :: (FinalizationMonad s m) => m ()
tryNominateBlock = do
    currRound <- use finCurrentRound
    forM_ currRound $ \r@FinalizationRound{..} ->
        when (isNothing roundInput) $ do
            h <- use finHeight
            bBlock <- bestBlock
            when (bpHeight bBlock >= h + roundDelta) $ do
                let nomBlock = bpHash $ ancestorAtHeight h bBlock
                finCurrentRound ?= r {roundInput = Just nomBlock}
                liftWMVBA $ startWMVBA nomBlock

nextRound :: (FinalizationMonad s m) => FinalizationIndex -> BlockHeight -> m ()
nextRound oldFinIndex oldDelta = do
    curFinIndex <- use finIndex
    when (curFinIndex == oldFinIndex) $ do
        oldRound <- use finCurrentRound
        forM_ oldRound $ \r ->
            when (roundDelta r == oldDelta) $ do
                newRound (2 * oldDelta) (roundMe r)


newRound :: (FinalizationMonad s m) => BlockHeight -> Party -> m ()
newRound newDelta me = do
        finCurrentRound ?= FinalizationRound {
            roundInput = Nothing,
            roundDelta = newDelta,
            roundMe = me,
            roundWMVBA = initialWMVBAState
        }
        h <- use finHeight
        logEvent Afgjort LLDebug $ "Starting finalization round: height=" ++ show (theBlockHeight h) ++ " delta=" ++ show (theBlockHeight newDelta)
        justifiedInputs <- fmap (ancestorAtHeight h) <$> getBlocksAtHeight (h + newDelta)
        finIx <- use finIndex
        committee <- use finCommittee
        sessId <- use finSessionId
        let
            msgHdr src = FinalizationMessageHeader {
                msgSessionId = sessId,
                msgFinalizationIndex = finIx,
                msgDelta = newDelta,
                msgSenderIndex = src
            }
            toFinMsg (PendingMessage src msg sig) = FinalizationMessage (msgHdr src) msg sig
        -- Filter the messages that have valid signatures and reference legitimate parties
        pmsgs <- finPendingMessages . atStrict finIx . non Map.empty . atStrict newDelta . non Set.empty <%= Set.filter (checkMessage committee . toFinMsg)
        -- Justify the blocks
        forM_ justifiedInputs $ \i -> do
            logEvent Afgjort LLTrace $ "Justified input at " ++ show finIx ++ ": " ++ show i
            liftWMVBA $ justifyWMVBAInput $ bpHash i
        -- Receive the pending messages
        forM_ pmsgs $ \smsg@(PendingMessage src msg sig) -> do
            logEvent Afgjort LLDebug $ "Handling message: " ++ show (toFinMsg smsg)
            liftWMVBA $ receiveWMVBAMessage src sig msg
        tryNominateBlock


handleWMVBAOutputEvents :: (FinalizationMonad s m) => [WMVBAOutputEvent Sig.Signature] -> m ()
handleWMVBAOutputEvents evs = do
        FinalizationState{..} <- use finState
        FinalizationInstance{..} <- getFinalizationInstance
        forM_ _finsCurrentRound $ \FinalizationRound{..} -> do
            let msgHdr = FinalizationMessageHeader{
                msgSessionId = _finsSessionId,
                msgFinalizationIndex = _finsIndex,
                msgDelta = roundDelta,
                msgSenderIndex = roundMe
            }
            let
                handleEvs _ [] = return ()
                handleEvs b (SendWMVBAMessage msg0 : evs') = do
                    case msg0 of
                        WMVBAFreezeMessage (Proposal v) -> logEvent Afgjort LLDebug $ "Nominating block " ++ show v
                        _ -> return ()
                    let msg = signFinalizationMessage finMySignKey msgHdr msg0
                    broadcastFinalizationMessage msg
                    -- We manually loop back messages here
                    _ <- receiveFinalizationMessage msg
                    handleEvs b evs'
                handleEvs False (WMVBAComplete Nothing : evs') = do
                    -- Round failed, so start a new one
                    nextRound _finsIndex roundDelta
                    handleEvs True evs'
                handleEvs False (WMVBAComplete (Just (finBlock, sigs)) : evs') = do
                    let finRec = FinalizationRecord {
                        finalizationIndex = _finsIndex,
                        finalizationBlockPointer = finBlock,
                        finalizationProof = FinalizationProof sigs,
                        finalizationDelay = roundDelta
                    }
                    _ <- finalizeBlock finRec
                    broadcastFinalizationRecord finRec
                    handleEvs True evs'
                handleEvs True (WMVBAComplete _ : evs') = handleEvs True evs'
            handleEvs False evs

liftWMVBA :: (FinalizationMonad s m) => WMVBA Sig.Signature a -> m a
liftWMVBA a = do
    FinalizationState{..} <- use finState
    FinalizationInstance{..} <- getFinalizationInstance
    case _finsCurrentRound of
        Nothing -> error "No current finalization round"
        Just (fr@FinalizationRound{..}) -> do
            let
                baid = runPut $ S.put _finsSessionId >> S.put _finsIndex >> S.put roundDelta
                pWeight party = partyWeight (parties _finsCommittee Vec.! fromIntegral party)
                pVRFKey party = partyVRFKey (parties _finsCommittee Vec.! fromIntegral party)
                maxParty = fromIntegral $ Vec.length (parties _finsCommittee) - 1
                inst = WMVBAInstance baid (totalWeight _finsCommittee) (corruptWeight _finsCommittee) pWeight maxParty pVRFKey roundMe finMyVRFKey
            (r, newState, evs) <- liftIO $ runWMVBA a inst roundWMVBA
            finCurrentRound ?= fr {roundWMVBA = newState}
            -- logEvent Afgjort LLTrace $ "New WMVBA state: " ++ show newState
            handleWMVBAOutputEvents evs
            return r

-- |Request any blocks that are referenced by a message, but have not arrived.
requestAbsentBlocks :: (FinalizationMonad s m) => WMVBAMessage -> m ()
requestAbsentBlocks msg = forM_ (messageValues msg) $ \block -> do
        bs <- resolveBlock block
        when (isNothing bs) $ do
            logEvent Afgjort LLDebug $ "Requesting missing block " ++ show block ++ " referenced by finalization message"
            requestMissingBlock block
        FinalizationState{..} <- use finState
        forM_ _finsCurrentRound $ \FinalizationRound{..} -> do
            justified <- liftWMVBA $ isJustifiedWMVBAInput block
            unless justified $ do
                logEvent Afgjort LLDebug $ "Requesting missing descendant of " ++ show block ++ " at height delta " ++ show (theBlockHeight roundDelta)
                requestMissingBlockDescendant block roundDelta

savePendingMessage :: (FinalizationMonad s m) => FinalizationIndex -> BlockHeight -> PendingMessage -> m Bool
savePendingMessage finIx finDelta pmsg = do
    pmsgs <- use finPendingMessages
    case Map.lookup finIx pmsgs of
        Nothing -> do
            finPendingMessages .= Map.insert finIx (Map.singleton finDelta $ Set.singleton pmsg) pmsgs
            return False
        Just ipmsgs -> case Map.lookup finDelta ipmsgs of
            Nothing -> do
                finPendingMessages .= Map.insert finIx (Map.insert finDelta (Set.singleton pmsg) ipmsgs) pmsgs
                return False
            Just s -> if pmsg `Set.member` s then
                    return True
                else do
                    finPendingMessages .= Map.insert finIx (Map.insert finDelta (Set.insert pmsg s) ipmsgs) pmsgs
                    return False
{-
    msgs <- use $ finPendingMessages . at finIx . non Map.empty . at finDelta . non Set.empty
    if pmsg `Set.member` msgs then
        return True
    else do
        finPendingMessages . atStrict finIx . non Map.empty . atStrict finDelta ?= Set.insert pmsg msgs
        return False
-}

-- |Called when a finalization message is received.
receiveFinalizationMessage :: (FinalizationMonad s m) => FinalizationMessage -> m UpdateResult
receiveFinalizationMessage msg@FinalizationMessage{msgHeader=FinalizationMessageHeader{..},..} = do
        FinalizationState{..} <- use finState
        -- Check this is the right session
        if (_finsSessionId == msgSessionId) then
            -- Check the finalization index is not out of date
            case compare msgFinalizationIndex _finsIndex of
                LT -> return ResultStale -- message is out of date
                GT -> do
                    -- Save the message for a later finalization index
                    -- isDuplicate <- finPendingMessages . atStrict msgFinalizationIndex . non Map.empty . atStrict msgDelta . non Set.empty . members (PendingMessage msgSenderIndex msgBody msgSignature) <<.= True
                    isDuplicate <- savePendingMessage msgFinalizationIndex msgDelta (PendingMessage msgSenderIndex msgBody msgSignature)
                    if isDuplicate then
                        return ResultDuplicate
                    else do
                        -- Since we're behind, request the finalization record we're apparently missing
                        logEvent Afgjort LLDebug $ "Requesting missing finalization at index " ++ (show $ msgFinalizationIndex - 1)
                        requestMissingFinalization (msgFinalizationIndex - 1)
                        -- Request any missing blocks that this message refers to
                        requestAbsentBlocks msgBody
                        return ResultPendingFinalization
                EQ -> -- handle the message now, since it's the current round
                    if checkMessage _finsCommittee msg then do
                        -- Save the message
                        -- isDuplicate <- finPendingMessages . atStrict msgFinalizationIndex . non Map.empty . atStrict msgDelta . non Set.empty . members (PendingMessage msgSenderIndex msgBody msgSignature) <<.= True
                        isDuplicate <- savePendingMessage msgFinalizationIndex msgDelta (PendingMessage msgSenderIndex msgBody msgSignature)
                        if isDuplicate then
                            return ResultDuplicate
                        else do
                            -- Request any missing blocks that this message refers to
                            requestAbsentBlocks msgBody
                            -- Check if we're participating in finalization for this index
                            forM_ _finsCurrentRound $ \FinalizationRound{..} ->
                                -- And it's the current round
                                when (msgDelta == roundDelta) $ do
                                    logEvent Afgjort LLDebug $ "Handling message: " ++ show msg
                                    liftWMVBA (receiveWMVBAMessage msgSenderIndex msgSignature msgBody)
                            return ResultSuccess
                    else do
                        logEvent Afgjort LLWarning $ "Received bad finalization message"
                        return ResultInvalid
            else
                return ResultIncorrectFinalizationSession

-- |Called to notify the finalization routine when a new block arrives.
notifyBlockArrival :: (FinalizationMonad s m, BlockPointerData bp) => bp -> m ()
notifyBlockArrival b = do
    FinalizationState{..} <- use finState
    forM_ _finsCurrentRound $ \FinalizationRound{..} -> do
        when (bpHeight b == _finsHeight + roundDelta) $ do
            logEvent Afgjort LLTrace $ "Justified input at " ++ show _finsIndex ++ ": " ++ show (bpHash (ancestorAtHeight _finsHeight b))
            liftWMVBA $ justifyWMVBAInput (bpHash (ancestorAtHeight _finsHeight b))
        tryNominateBlock


getMyParty :: (FinalizationMonad s m) => m (Maybe Party)
getMyParty = do
        finInst <- getFinalizationInstance
        let
            myVerifyKey = (Sig.verifyKey . finMySignKey) finInst
            myPublicVRFKey = (VRF.publicKey . finMyVRFKey) finInst
        ps <- parties <$> use finCommittee
        case filter (\p -> partySignKey p == myVerifyKey && partyVRFKey p == myPublicVRFKey) (Vec.toList ps) of
            (p:_) -> return $ Just (partyIndex p)
            [] -> return Nothing


-- |Called to notify the finalization routine when a new block is finalized.
-- (NB: this should never be called with the genesis block.)
notifyBlockFinalized :: (FinalizationMonad s m, BlockPointerData bp) => FinalizationRecord -> bp -> m ()
notifyBlockFinalized fr@FinalizationRecord{..} bp = do
        finIndex .= finalizationIndex + 1
        -- Discard finalization messages from old round
        finPendingMessages . atStrict finalizationIndex .= Nothing
        pms <- use finPendingMessages
        logEvent Afgjort LLTrace $ "Finalization complete. Pending messages: " ++ show pms
        let newFinDelay = nextFinalizationDelay fr
        fs <- use finMinSkip
        finHeight .= nextFinalizationHeight fs bp
        -- Determine if we're in the committee
        mMyParty <- getMyParty
        forM_ mMyParty $ \myParty -> do
            newRound newFinDelay myParty

nextFinalizationDelay :: FinalizationRecord -> BlockHeight
nextFinalizationDelay FinalizationRecord{..} = if finalizationDelay > 2 then finalizationDelay `div` 2 else 1

-- |Given the finalization minimum skip and an explicitly finalized block, compute
-- the height of the next finalized block.
nextFinalizationHeight :: (BlockPointerData bp)
    => BlockHeight -- ^Finalization minimum skip
    -> bp -- ^Last finalized block
    -> BlockHeight
nextFinalizationHeight fs bp = bpHeight bp + max (1 + fs) ((bpHeight bp - bpHeight (bpLastFinalized bp)) `div` 2)

-- |The height that a chain must be for a block to be eligible for finalization.
-- This is the next finalization height + the next finalization delay.
nextFinalizationJustifierHeight :: (BlockPointerData bp)
    => FinalizationParameters
    -> FinalizationRecord -- ^Last finalization record
    -> bp -- ^Last finalized block
    -> BlockHeight
nextFinalizationJustifierHeight fp fr bp = nextFinalizationHeight (finalizationMinimumSkip fp) bp + nextFinalizationDelay fr

getPartyWeight :: FinalizationCommittee -> Party -> VoterPower
getPartyWeight com pid = case parties com ^? ix (fromIntegral pid) of
        Nothing -> 0
        Just p -> partyWeight p

-- |Check that a finalization record has a valid proof
verifyFinalProof :: FinalizationSessionId -> FinalizationCommittee -> FinalizationRecord -> Bool
verifyFinalProof sid com@FinalizationCommittee{..} FinalizationRecord{..} = sum (sigWeight <$> sigs) > corruptWeight
    where
        FinalizationProof sigs = finalizationProof
        hdr si = FinalizationMessageHeader {
            msgSessionId = sid,
            msgFinalizationIndex = finalizationIndex,
            msgDelta = finalizationDelay,
            msgSenderIndex = si
        }
        sigWeight (pid, sig) = if checkMessageSignature com (FinalizationMessage (hdr pid) (WMVBAWitnessCreatorMessage finalizationBlockPointer) sig)
            then getPartyWeight com pid
            else 0

data FinalizationPoint = FinalizationPoint !FinalizationSessionId !FinalizationIndex !BlockHeight
  deriving(Show)

instance S.Serialize FinalizationPoint where
    put (FinalizationPoint session index delta) = do
        S.put session
        S.put index
        S.put delta
    get = FinalizationPoint <$> S.get <*> S.get <*> S.get

class FinalizationQuery s where
    -- |Get all of the finalization messages received for indexes beyond the last finalized index
    -- and no sooner than the given finalization point.
    getPendingFinalizationMessages :: s -> FinalizationPoint -> [FinalizationMessage]
    -- |Get the current point in the finalization protocol.
    getCurrentFinalizationPoint :: s -> FinalizationPoint

newtype FinalizationStateQuery s = FinalizationStateQuery s

doGetPendingFinalizationMessages :: FinalizationSessionId -> PendingMessageMap -> FinalizationPoint -> [FinalizationMessage]
doGetPendingFinalizationMessages mySessionId myPendingMessages (FinalizationPoint sess lowIndex lowIndexDelta)
        | sess == mySessionId = Map.foldrWithKey eachIndex [] (at lowIndex . non Map.empty %~ Map.dropWhileAntitone (<lowIndexDelta) $ Map.dropWhileAntitone (< lowIndex) myPendingMessages)
        | otherwise = []
    where
        eachIndex ind m l = Map.foldrWithKey (eachDelta ind) l m
        eachDelta ind delta msgs l = map (eachMsg ind delta) (Set.toList msgs) ++ l
        eachMsg ind delta (PendingMessage senderIndex msgBody msgSignature) = FinalizationMessage{..}
            where
                msgHeader = FinalizationMessageHeader {
                    msgSessionId = mySessionId,
                    msgFinalizationIndex = ind,
                    msgDelta = delta,
                    msgSenderIndex = senderIndex
                }

instance (FinalizationStateLenses s) => FinalizationQuery (FinalizationStateQuery s) where
    getPendingFinalizationMessages (FinalizationStateQuery fs) fp = doGetPendingFinalizationMessages (fs ^. finSessionId) (fs ^. finPendingMessages) fp
    getCurrentFinalizationPoint (FinalizationStateQuery fs) = FinalizationPoint (fs ^. finSessionId) (fs ^. finIndex) delta
        where
            delta = case fs ^. finCurrentRound of
                        Nothing -> 0
                        Just r -> roundDelta r

deriving via (FinalizationStateQuery FinalizationState) instance FinalizationQuery FinalizationState

data FinalizationSummary = FinalizationSummary {
    -- |For each failed round (in order of increasing delta),
    -- a collection of signatures on 'WeAreDone False'.
    summaryFailedRounds :: [Map Party Sig.Signature],
    -- |Summary for the current round.
    summaryCurrentRound :: WMVBASummary Sig.Signature
}

-- * Passive finalization [deprecated]

data PassiveFinalizationState = PassiveFinalizationState {
    _pfinsSessionId :: !FinalizationSessionId,
    _pfinsIndex :: !FinalizationIndex,
    _pfinsPendingMessages :: !PendingMessageMap
}
makeLenses ''PassiveFinalizationState

class PassiveFinalizationStateLenses s where
    pfinState :: Lens' s PassiveFinalizationState
    pfinSessionId :: Lens' s FinalizationSessionId
    pfinSessionId = pfinState . pfinsSessionId
    pfinIndex :: Lens' s FinalizationIndex
    pfinIndex = pfinState . pfinsIndex
    -- |All received finalization messages for the current and future finalization indexes, for catch-up.
    pfinPendingMessages :: Lens' s PendingMessageMap
    pfinPendingMessages = pfinState . pfinsPendingMessages

instance PassiveFinalizationStateLenses PassiveFinalizationState where
    pfinState = id

-- |Generate an initial 'PassiveFinalizationState' from the genesis 'BlockHash'.
initialPassiveFinalizationState :: BlockHash -> PassiveFinalizationState
initialPassiveFinalizationState genHash = PassiveFinalizationState {
    _pfinsSessionId = FinalizationSessionId genHash 0,
    _pfinsIndex = 1,
    _pfinsPendingMessages = Map.empty
    }

instance FinalizationQuery PassiveFinalizationState where
    getPendingFinalizationMessages pfs fp = doGetPendingFinalizationMessages (pfs ^. pfinsSessionId) (pfs ^. pfinsPendingMessages) fp
    getCurrentFinalizationPoint pfs = FinalizationPoint (pfs ^. pfinsSessionId) (pfs ^. pfinsIndex) 0

-- |Called when a finalization message is received.
passiveReceiveFinalizationMessage :: (MonadState s m, PassiveFinalizationStateLenses s) => FinalizationMessage -> m UpdateResult
passiveReceiveFinalizationMessage FinalizationMessage{msgHeader=FinalizationMessageHeader{..},..} = do
        PassiveFinalizationState{..} <- use pfinState
        -- Check this is the right session
        if (_pfinsSessionId == msgSessionId) then
            -- Check the finalization index is not out of date
            if msgFinalizationIndex < _pfinsIndex then
                return ResultStale
            else do
                -- Save the message
                isDuplicate <- pfinPendingMessages . atStrict msgFinalizationIndex . non Map.empty . atStrict msgDelta . non Set.empty . members (PendingMessage msgSenderIndex msgBody msgSignature) <<.= True
                if isDuplicate then
                    return ResultDuplicate
                else
                    return ResultSuccess
            else
                return ResultIncorrectFinalizationSession

-- |Called when a new block is finalized.
-- (NB: this should never be called with the genesis block.)
passiveNotifyBlockFinalized :: (MonadState s m, PassiveFinalizationStateLenses s) => FinalizationRecord -> m ()
passiveNotifyBlockFinalized FinalizationRecord{..} = do
        pfinIndex .= finalizationIndex + 1
        -- Discard finalization messages from old round
        pfinPendingMessages . atStrict finalizationIndex .= Nothing
