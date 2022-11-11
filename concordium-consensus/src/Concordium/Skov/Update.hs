{-# LANGUAGE
    ScopedTypeVariables,
    ViewPatterns,
    UndecidableInstances#-}
module Concordium.Skov.Update where

import Control.Monad
import qualified Data.Sequence as Seq
import qualified Data.Vector as Vec
import Lens.Micro.Platform
import Data.Foldable
import Data.List (intercalate)
import GHC.Stack
import Data.Maybe (fromMaybe)
import Data.Time (diffUTCTime)
import Control.Monad.IO.Class
import Control.Monad.Reader.Class

import Concordium.Types
import Concordium.Types.Accounts
import Concordium.Types.HashableTo
import Concordium.GlobalState.TreeState
import Concordium.GlobalState.BlockPointer hiding (BlockPointer)
import Concordium.GlobalState.BlockMonads
import Concordium.GlobalState.BlockState
import qualified Concordium.GlobalState.Block as GB (PendingBlock(..))
import Concordium.GlobalState.Block hiding (PendingBlock)
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Parameters
import Concordium.Types.Transactions
import Concordium.GlobalState.BakerInfo

import Concordium.Scheduler.TreeStateEnvironment

import Concordium.Kontrol hiding (getRuntimeParameters, getGenesisData)
import Concordium.Kontrol.Bakers
import Concordium.Birk.LeaderElection
import Concordium.Kontrol.UpdateLeaderElectionParameters
import Concordium.Afgjort.Finalize
import Concordium.Afgjort.Finalize.Types
import Concordium.Logger
import Concordium.TimeMonad
import Concordium.Skov.Statistics
import qualified Concordium.TransactionVerification as TV
import Concordium.Types.Updates (uiHeader, updateType, uiPayload)
import Concordium.Scheduler.Types (updateSeqNumber)
import Concordium.GlobalState.TransactionTable

-- |Determine if one block is an ancestor of another.
-- A block is considered to be an ancestor of itself.
isAncestorOf :: BlockPointerMonad m => BlockPointerType m -> BlockPointerType m -> m Bool
isAncestorOf b1 b2 = case compare (bpHeight b1) (bpHeight b2) of
        GT -> return False
        EQ -> return (b1 == b2)
        LT -> do
          parent <- bpParent b2
          isAncestorOf b1 parent

-- |Update the focus block, together with the pending transaction table.
updateFocusBlockTo :: (TreeStateMonad m) => BlockPointerType m -> m ()
updateFocusBlockTo newBB = do
        oldBB <- getFocusBlock
        pts <- getPendingTransactions
        upts <- updatePTs oldBB newBB [] pts
        putPendingTransactions upts
        putFocusBlock newBB
    where
        updatePTs :: (BlockPointerMonad m) => BlockPointerType m -> BlockPointerType m -> [BlockPointerType m] -> PendingTransactionTable -> m PendingTransactionTable
        updatePTs oBB nBB forw pts = case compare (bpHeight oBB) (bpHeight nBB) of
                LT -> do
                  parent <- bpParent nBB
                  updatePTs oBB parent (nBB : forw) pts
                EQ -> if oBB == nBB then
                            return $ foldl (\p f-> forwardPTT (blockTransactions f) p) pts forw
                        else do
                            parent1 <- bpParent oBB
                            parent2 <- bpParent nBB
                            updatePTs parent1 parent2 (nBB : forw) (reversePTT (blockTransactions oBB) pts)
                GT -> do
                  parent <- bpParent oBB
                  updatePTs parent nBB forw (reversePTT (blockTransactions oBB) pts)

-- |Make a 'FinalizerInfo' from a 'FinalizationCommittee' and 'FinalizationProof'. It is assumed
-- that the 'FinalizationProof' is valid with respect to the 'FinalizationCommittee'.
makeFinalizerInfo :: FinalizationCommittee -> FinalizationProof -> FinalizerInfo
makeFinalizerInfo committee finProof =
    FinalizerInfo {
        committeeVoterPower = finPower <$> parties committee,
        committeeSigners = finSigner <$> finalizationProofParties finProof
    }
    where
        finPower p = (partyBakerId p, partyWeight p)
        finSigner i = partyBakerId $ parties committee Vec.! fromIntegral i

-- |A monad implementing 'OnSkov' provides functions for responding to
-- a block being added to the tree, and a finalization record being verified.
-- It also provides a function for logging transfers at finalization time.
class OnSkov m where
    -- |Called when a block arrives.
    onBlock :: BlockPointerType m -> m ()
    -- |Called when a finalization record is validated.  This is
    -- only called for the block that is explicitly finalized (i.e.
    -- once per finalization record).
    onFinalize :: FinalizationRecord -> BlockPointerType m -> [BlockPointerType m] -> m ()
    -- |Called when a block or finalization record that was previously
    -- pending becomes live.
    onPendingLive :: m ()

-- |Handle a block arriving that is dead.  That is, the block has never
-- been in the tree before, and now it never can be.  Any descendants of
-- this block that have previously arrived cannot have been added to the
-- tree, and we purge them recursively from '_skovPossiblyPendingTable'.
blockArriveDead :: (HasCallStack, BlockPointerMonad m, MonadLogger m, TreeStateMonad m) => BlockHash -> m ()
blockArriveDead cbp = do
        markDead cbp
        logEvent Skov LLDebug $ "Block " ++ show cbp ++ " arrived dead"
        children <- map getHash <$> takePendingChildren cbp
        forM_ children blockArriveDead

-- |Purge pending blocks with slot numbers predating the last finalized slot.
purgePending :: (HasCallStack, TreeStateMonad m, MonadLogger m) => m ()
purgePending = do
        lfSlot <- getLastFinalizedSlot
        let purgeLoop = takeNextPendingUntil lfSlot >>= \case
                            Nothing -> return ()
                            Just (getHash -> pb) -> do
                                pbStatus <- getBlockStatus pb
                                let
                                    isPending Nothing = True
                                    isPending (Just BlockPending{}) = True
                                    isPending _ = False
                                when (isPending pbStatus) $ blockArriveDead pb
                                purgeLoop
        purgeLoop

doTrustedFinalize :: (TreeStateMonad m, SkovMonad m, OnSkov m) => FinalizationRecord -> m (Either UpdateResult (BlockPointerType m))
doTrustedFinalize finRec =
    getBlockStatus (finalizationBlockPointer finRec) >>= \case
        Just (BlockAlive bp) -> Right bp <$ processFinalization bp finRec
        Just BlockDead -> return $ Left ResultInvalid
        Just BlockFinalized{} -> return $ Left ResultInvalid
        Just BlockPending{} -> return $ Left ResultUnverifiable
        Nothing -> return $ Left ResultUnverifiable

-- |Process the finalization of a block.  The following are assumed:
--
-- * The block is either alive or finalized.
-- * The finalization record is valid and finalizes the given block.
processFinalization :: forall m. (TreeStateMonad m, SkovMonad m, OnSkov m) => BlockPointerType m -> FinalizationRecord -> m ()
processFinalization newFinBlock finRec@FinalizationRecord{..} = do
    nextFinIx <- getNextFinalizationIndex
    when (nextFinIx == finalizationIndex) $ do
        startTime <- currentTime
        -- We actually have a new block to finalize.
        logEvent Skov LLInfo $ "Block " ++ show (bpHash newFinBlock) ++ " is finalized at height " ++ show (theBlockHeight $ bpHeight newFinBlock) ++ " with finalization delta=" ++ show finalizationDelay
        updateFinalizationStatistics
        -- Check if the focus block is a descendent of the block we are finalizing
        focusBlockSurvives <- isAncestorOf newFinBlock =<< getFocusBlock
        -- If not, update the focus to the new finalized block.
        -- This is to ensure that the focus block is always a live (or finalized) block.
        unless focusBlockSurvives $ updateFocusBlockTo newFinBlock
        lastFinHeight <- getLastFinalizedHeight
        -- Prune the branches, which consist of all the non-finalized blocks
        -- grouped by block height.
        oldBranches <- getBranches
        -- 'pruneHeight' is the number of blocks that are being finalized
        -- as a result of the finalization record.
        let pruneHeight = fromIntegral (bpHeight newFinBlock - lastFinHeight)
        -- First, prune the trunk: the section of the branches beyond the
        -- last finalized block up to and including the new finalized block.
        -- We proceed backwards from the new finalized block, collecting blocks
        -- to mark as dead. When we exhaust the branches we then mark blocks as finalized
        -- by increasing height.
        -- 
        -- Instead of marking blocks dead immediately, we accumulate them in a list by decreasing
        -- height. The reason for doing this is that we never have to look up a parent block that is
        -- already marked dead.
        let pruneTrunk :: [BlockPointerType m] -- ^List of blocks to remove.
                       -> [BlockPointerType m] -- ^List of finalized blocks.
                       -> BlockPointerType m -- ^Finalized block to consider now.
                                            -- At the same height as the latest branch in the next argument
                       -> Branches m
                       -> m ([BlockPointerType m], [BlockPointerType m])
                       -- ^ The return value is a list of blocks to mark dead (ordered by decreasing
                       -- height) and a list of blocks to mark finalized (ordered by increasing
                       -- height).
            pruneTrunk toRemove toFinalize _ Seq.Empty = return (toRemove, toFinalize)
            pruneTrunk toRemove toFinalize keeper (brs Seq.:|> l) = do
              let toRemove1 = toRemove ++ filter (/= keeper) l
              parent <- bpParent keeper
              pruneTrunk toRemove1 (keeper : toFinalize) parent brs
        (toRemoveFromTrunk, toFinalize) <- pruneTrunk [] [] newFinBlock (Seq.take pruneHeight oldBranches)
        -- Add the finalization to the finalization list
        addFinalization newFinBlock finRec
        mffts <- forM toFinalize $ \block -> do
          -- mark blocks as finalized in the order returned by `pruneTrunk`, so that blocks are marked
          -- finalized by increasing height          
          mf <- markFinalized (getHash block) finRec
          -- Finalize the transactions of surviving blocks in the order of their finalization.
          ft <- finalizeTransactions (getHash block) (blockSlot block) (blockTransactions block)
          return (mf, ft)
        -- block states and transaction statuses need to be added into the same LMDB transaction
        -- with the finalization record, if persistent tree state is used
        wrapupFinalization finRec mffts
        logEvent Skov LLDebug $ "Blocks " ++ intercalate ", " (map show toFinalize) ++ " marked finalized"
        -- Archive the states of blocks up to but not including the new finalized block
        let doArchive b = case compare (bpHeight b) lastFinHeight of
                LT -> return []
                EQ -> do
                  archiveBlockState =<< blockState b
                  return []
                GT -> do
                        blocks <- doArchive =<< bpParent b
                        archiveBlockState =<< blockState b
                        return (b:blocks)
        finalizedBlocks <- doArchive =<< bpParent newFinBlock
        -- Prune the branches: mark dead any block that doesn't descend from
        -- the newly-finalized block.
        -- Instead of marking blocks dead immediately we accumulate them
        -- and a return a list. The reason for doing this is that we never
        -- have to look up a parent block that is already marked dead.
        let
            pruneBranches :: [BlockPointerType m] -- ^Accumulator of blocks to mark dead.
                          -> [BlockPointerType m] -- ^Parents that remain alive.
                          -> Branches m -- ^Branches to prune
                          -> m (Branches m, [BlockPointerType m])
                          -- ^The return value is a pair of new branches and the
                          -- list of blocks to mark dead. The blocks are ordered
                          -- by decreasing height.
            pruneBranches toRemove _ Seq.Empty = return (Seq.empty, toRemove)
            pruneBranches toRemove parents (brs Seq.:<| rest) = do
                (survivors, removals) <- foldrM (\bp ~(keep, remove) -> do
                    parent <- bpParent bp
                    if parent `elem` parents then
                        return (bp:keep, remove)
                    else
                        return (keep, bp:remove))
                    ([], toRemove) brs
                (rest', toRemove') <- pruneBranches removals survivors rest
                return (survivors Seq.<| rest', toRemove')
        (unTrimmedBranches, toRemoveFromBranches) <- pruneBranches [] [newFinBlock] (Seq.drop pruneHeight oldBranches)
        -- This removes empty lists at the end of branches which can result in finalizing on a
        -- block not in the current best local branch
        let
            trimBranches Seq.Empty = return Seq.Empty
            trimBranches prunedbrs@(xs Seq.:|> x) =
                case x of
                    [] -> trimBranches xs
                    _ -> return prunedbrs
        newBranches <- trimBranches unTrimmedBranches
        putBranches newBranches
        -- mark dead blocks by decreasing height
        forM_ (toRemoveFromBranches ++ toRemoveFromTrunk) $ \bp -> do
          markLiveBlockDead bp
          logEvent Skov LLDebug $ "Block " ++ show (bpHash bp) ++ " marked dead"
        -- purge pending blocks with slot numbers predating the last finalized slot
        purgePending
        onFinalize finRec newFinBlock finalizedBlocks
        endTime <- currentTime
        logEvent Skov LLDebug $ "Processed finalization in " ++ show (diffUTCTime endTime startTime)

-- |Try to add a block to the tree.  
-- Besides taking the `PendingBlock` this function takes a list
-- of verification results which ensures sharing of computed verification results.
-- 
-- Important! The verification results must be the result of verifying transactions in the block.
--  
-- There are three possible outcomes:
-- 1. The block is determined to be invalid in the current tree.
--    In this case, the block is marked dead.
-- 2. The block is pending the arrival of its parent block, or
--    the finalization of its last finalized block.  In this case
--    it is added to the appropriate pending queue.  'addBlock'
--    should be called again when the pending criterion is fulfilled.
-- 3. The block is determined to be valid and added to the tree.
-- todo doc
addBlock :: forall m. (HasCallStack, TreeStateMonad m, SkovMonad m, FinalizationMonad m, OnSkov m) => PendingBlock -> [Maybe TV.VerificationResult] -> BlockPointerType m -> Maybe FinalizerInfo -> m UpdateResult
addBlock block txvers parentP mFinInfo = do
        lfs <- getLastFinalizedSlot
        -- The block must be later than the last finalized block
        if lfs >= blockSlot block then deadBlock else do
            -- Look up the block parent, if any.
            -- This is performance sensitive since it is before we managed to validate the block,
            -- so we make sure to look up as little data as possible to determine block validity.
            -- In particular we do not use getBlockStatus since that loads the entire block
            -- from the database if the block is finalized.
            addBlockWithLiveParent block txvers parentP mFinInfo
    where
        deadBlock :: m UpdateResult
        deadBlock = do
            blockArriveDead $! getHash block
            return ResultStale

-- |Add a block to the pending blocks table, returning 'ResultPendingBlock'.
-- It is assumed that the parent of the block is unknown or also a pending block, and that its
-- slot time is after the slot time of the last finalized block.
addBlockAsPending :: (TreeStateMonad m, MonadLogger m) => PendingBlock -> m UpdateResult
addBlockAsPending block = do
        addPendingBlock block
        markPending block
        let parent = blockPointer block
        logEvent Skov LLDebug $ "Block " ++ show block ++ " is pending its parent (" ++ show parent ++ ")"
        return ResultPendingBlock

-- |Add a block where the parent block is known to be live, and the transactions have been verified.
-- If the block proves to be valid, it is added to the tree and this returns 'ResultSuccess'.
-- Otherwise, the block is marked dead and 'ResultInvalid' is returned.
--
-- PRECONDITION: The parent of the block provided must be either alive or finalized.
-- It is assumed that the slot time of the block is after the last finalized block.
-- todo doc.
addBlockWithLiveParent ::
    forall m.
    (HasCallStack, TreeStateMonad m, SkovMonad m, FinalizationMonad m, OnSkov m) =>
    -- |A pending block with a live or finalized parent.
    PendingBlock ->
    -- |Verification results of transactions, corresponding to those in the block
    [Maybe TV.VerificationResult] ->
    -- |Parent block pointer
    BlockPointerType m ->
    -- |Finalizer info if available.
    Maybe FinalizerInfo ->
    m UpdateResult
addBlockWithLiveParent block txvers parentP finInfo = do
    (lfbp, _) <- getLastFinalized
    parentState <- blockState parentP
    parentSeedState <- getSeedState parentState
    slotTime <- getSlotTimestamp (blockSlot block)
    -- Update the seed state with the block nonce
    let newSeedState = updateSeedState blkSlot (blockNonce block) parentSeedState
        ts = zip (blockTransactions block) txvers
    executeFrom blkHash blkSlot slotTime parentP (blockBaker block) finInfo newSeedState ts >>= \case
        Left err -> do
            logEvent Skov LLWarning ("Block execution failure: " ++ show err)
            invalidBlock "execution failure"
        Right result -> do
            -- Check that the StateHash is correct
            stateHash <- getStateHash (_finalState result)
            check "Claimed stateHash did not match calculated stateHash"(stateHash == blockStateHash block) $ do
                -- Check that the TransactionOutcomeHash is correct
                tohash <- getTransactionOutcomesHash (_finalState result)
                check "Claimed transactionOutcomesHash did not match actual transactionOutcomesHash"(tohash ==  blockTransactionOutcomesHash block) $ do
                    -- Add the block to the tree
                    blockP <- blockArrive block parentP lfbp result
                    -- Notify of the block arrival (for finalization)
                    finalizationBlockArrival blockP
                    onBlock blockP
                    -- Process finalization records
                    -- Handle any blocks that are waiting for this one
                    children <- takePendingChildren blkHash
                    forM_ children $ \childpb -> do
                        childStatus <- getBlockStatus (getHash childpb)
                        verress <- mapM getNonFinalizedTransactionVerificationResult (blockTransactions childpb)
                        let isPending Nothing = True
                            isPending (Just (BlockPending _)) = True
                            isPending _ = False
                        let parentHash = blockPointer childpb
                        mParentP <- resolveBlock parentHash
                        case mParentP of
                            Nothing -> return ()
                            Just childPP -> do
                                when (isPending childStatus) $ addBlock childpb verress childPP Nothing >>= \case
                                    ResultSuccess -> onPendingLive
                                    _ -> return ()
                    return ResultSuccess
    where
        invalidBlock :: String -> m UpdateResult
        invalidBlock reason = do
            logEvent Skov LLWarning $ "Block is not valid (" ++ reason ++ "): " ++ show block
            blockArriveDead $ getHash block
            return ResultInvalid
        check reason q a = if q then a else invalidBlock reason
        blkSlot = blockSlot block
        blkHash = getHash block

-- |Add a valid, live block to the tree.
-- This is used by 'addBlock' and 'doBakeForSlot', and should not
-- be called directly otherwise.
blockArrive :: (HasCallStack, TreeStateMonad m, SkovMonad m)
        => PendingBlock           -- ^Block to add
        -> BlockPointerType m     -- ^Parent pointer
        -> BlockPointerType m    -- ^Last finalized pointer
        -> ExecutionResult m -- ^Result of block execution (state, energy used, ...)
        -> m (BlockPointerType m)
blockArrive block parentP lfBlockP ExecutionResult{..} = do
        let height = bpHeight parentP + 1
        curTime <- currentTime
        blockP <- makeLiveBlock block parentP lfBlockP _finalState curTime _energyUsed
        logEvent Skov LLInfo $ "Block " ++ show block ++ " arrived"
        -- Update the statistics
        updateArriveStatistics blockP
        -- Add to the branches
        finHght <- getLastFinalizedHeight
        brs <- getBranches
        let branchLen = fromIntegral $ Seq.length brs
        let insertIndex = height - finHght - 1
        if insertIndex < branchLen then
            putBranches $ brs & ix (fromIntegral insertIndex) %~ (blockP:)
        else
            if insertIndex == branchLen then
                putBranches $ brs Seq.|> [blockP]
            else do
                -- This should not be possible, since the parent block should either be
                -- the last finalized block (in which case insertIndex == 0)
                -- or the child of a live block (in which case insertIndex <= branchLen)
                let errMsg = "Attempted to add block at invalid height (" ++ show (theBlockHeight height) ++ ") while last finalized height is " ++ show (theBlockHeight finHght)
                logEvent Skov LLError errMsg
                error errMsg
        return blockP

-- |Receive a block (as received from the network) in the tree.
-- This checks for validity of the block, and may add the block
-- to a pending queue if its prerequisites are not met.
-- If the block is too early, it is rejected with 'ResultEarlyBlock'.
-- todo doc
doReceiveBlock :: (TreeStateMonad m, FinalizationMonad m, SkovMonad m) => PendingBlock -> m (UpdateResult, Maybe VerifiedPendingBlock)
{- - INLINE doReceiveBlock - -}
doReceiveBlock pb@GB.PendingBlock{pbBlock = BakedBlock{..}, ..} = isShutDown >>= \case
    True -> return (ResultConsensusShutDown, Nothing)
    False -> do
        threshold <- rpEarlyBlockThreshold <$> getRuntimeParameters
        slotTime <- getSlotTimestamp (blockSlot pb)
        -- Check if the block is too early. We check that the threshold is not maxBound also, so that
        -- by setting the threshold to maxBound we can ensure blocks will never be considered early.
        -- This can be useful for testing.
        -- A more general approach might be to check for overflow generally, but this is simple and
        -- workable.
        if slotTime > addDuration (utcTimeToTimestamp pbReceiveTime) threshold && threshold /= maxBound then
            return (ResultEarlyBlock, Nothing)
        else
            -- Check if the block is already known.
            getRecentBlockStatus blockHash >>= \case
                Unknown -> do
                    lfs <- getLastFinalizedSlot
                    -- The block must be later than the last finalized block, otherwise it is already
                    -- dead.
                    if lfs >= blockSlot pb then rejectStaleBlock else do
                        -- Get the parent if available
                        let parent = blockPointer bbFields
                        parentStatus <- getRecentBlockStatus parent
                        -- If the parent is unknown, try to check the signing key and block proof based on the last finalized block
                        case parentStatus of
                            Unknown -> processPending slotTime Nothing
                            RecentBlock (BlockPending ppb) -> processPending slotTime $ Just $ blockSlot ppb
                            RecentBlock (BlockAlive parentB) -> verifyPendingBlock pb slotTime parentB
                            RecentBlock (BlockFinalized parentB _) -> verifyPendingBlock pb slotTime parentB
                            RecentBlock BlockDead -> rejectStaleBlock
                            OldFinalized -> rejectStaleBlock
                _ -> return (ResultDuplicate, Nothing)
    where
        checkClaimedSignature a = if verifyBlockSignature pb then a else do
            logEvent Skov LLWarning "Dropping block where signature did not match claimed key or blockhash."
            return (ResultInvalid, Nothing)
        blockHash = getHash pb
        rejectStaleBlock = do
            blockArriveDead blockHash
            return (ResultStale, Nothing)
        verifyBlockTransactions slotTime contextState = do
            txListWithVerRes <- sequence <$> forM (blockTransactions pb)
                (\tr -> fst <$> doReceiveTransactionInternal (TV.Block contextState) tr slotTime (blockSlot pb))           
            purgeTransactionTable False =<< currentTime
            updateReceiveStatistics pb
            return txListWithVerRes
        -- Processes a pending block that cannot be immediately be executed.
        processPending slotTime maybeParentBlockSlot = do
            -- Check:
            -- - Claimed baker key is valid in committee
            -- - Proof is valid
            -- - Signature is correct with the claimed key.
            -- - Assert that transactions can be verified wtr. the last finalized block.
            lastFin <- fst <$> getLastFinalized
            lastFinBS <- blockState lastFin
            gd <- getGenesisData
            let continuePending = checkClaimedSignature $ do
                    verifyBlockTransactions slotTime lastFinBS >>= \case
                        Nothing -> rejectStaleBlock
                        Just _ -> addBlockAsPending pb >>= (\updateResult -> return (updateResult, Nothing))
            getDefiniteSlotBakers gd lastFinBS (blockSlot pb) >>= \case
               Just bakers -> case lotteryBaker bakers (blockBaker pb) of
                   Just (bkrInfo, bkrPower)
                       | bkrInfo ^. bakerSignatureVerifyKey /= blockBakerKey pb -> do
                           logEvent Skov LLWarning $ "Pending block is not signed by a valid baker: " ++ show pb
                           rejectStaleBlock
                       | otherwise -> do
                           lastFinSS <- getSeedState lastFinBS
                           case predictLeadershipElectionNonce lastFinSS (blockSlot lastFin) maybeParentBlockSlot (blockSlot pb) of
                               Nothing -> continuePending -- Cannot check the proof (yet)
                               Just nonceList -> do
                                   -- We get the election difficulty based on the last finalized block.
                                   -- In principle, this could change before the block.
                                   elDiff <- getElectionDifficulty lastFinBS slotTime
                                   let verifyProofWithNonce nonce = verifyProof
                                           nonce
                                           elDiff
                                           (blockSlot pb)
                                           (bkrInfo ^. bakerElectionVerifyKey)
                                            bkrPower
                                           (blockProof pb)
                                   if any verifyProofWithNonce nonceList
                                   then do
                                       continuePending
                                   else do
                                       logEvent Skov LLWarning $ "Block proof of pending block was not verifiable: " ++ show pb
                                       rejectStaleBlock
                   Nothing -> rejectStaleBlock
               Nothing -> continuePending


-- |Check validity of a block (whose parent is either alive or finalized) and if present then also the finalization record.
-- Returns a `VerifiedPendingBlock` the `PendingBlock` could be verified.
-- This should be called if the parent is known to be alive or finalized.
-- Hence the function is used when receiving a block from the network and the parent is either alive or finalized,
-- or when processing pending children blocks of a block that was priorly also pending but where the parent has become
-- alive or finalized.
verifyPendingBlock :: (MonadLogger m, TreeStateMonad m, SkovQueryMonad m, FinalizationMonad m)
    => PendingBlock
    -> Timestamp
    -> BlockPointerType m
    -> m (UpdateResult, Maybe VerifiedPendingBlock)
verifyPendingBlock block slotTime parentP =
    -- Check that the claimed key matches the signature/blockhash
    checkClaimedSignature $ do
    -- Check that the blockSlot is beyond the parent slot
    check ("block slot (" ++ show (blockSlot block) ++ ") not later than parent block slot (" ++ show (blockSlot parentP) ++ ")") (blockSlot parentP < blockSlot block) $ do
        -- get Birk parameters from the __parent__ block. The baker must have existed in that
        -- block's state in order that the current block is valid
        parentState <- blockState parentP
        -- Determine the baker and its lottery power
        gd <- getGenesisData
        bakers <- getSlotBakers gd parentState (blockSlot block)
        let baker = lotteryBaker bakers (blockBaker block)
        -- Determine the leadership election nonce
        parentSeedState <- getSeedState parentState
        let nonce = computeLeadershipElectionNonce parentSeedState (blockSlot block)
        -- Determine the election difficulty
        elDiff <- getElectionDifficulty parentState slotTime
        logEvent Skov LLTrace $ "Verifying block with election difficulty " ++ show elDiff
        case baker of
            Nothing -> rejectInvalidBlock $ "unknown baker " ++ show (blockBaker block)
            Just (BakerInfo{..}, lotteryPower) ->
                -- Check the block proof
                check "invalid block proof" (verifyProof
                            nonce
                            elDiff
                            (blockSlot block)
                            _bakerElectionVerifyKey
                            lotteryPower
                            (blockProof block)) $
                -- The block nonce
                check "invalid block nonce" (verifyBlockNonce
                            nonce
                            (blockSlot block)
                            _bakerElectionVerifyKey
                            (blockNonce block)) $
                -- And check baker key matches claimed key.
                -- The signature is checked using the claimed key already in doStoreBlock for blocks which were received from the network.
                check "Baker key claimed in block did not match actual baker key" (_bakerSignatureVerifyKey == blockBakerKey block) $ do
                    let
                        ebpPb = block                        
                        ebpSlotTime = slotTime
                        ebpTxVerCtx = parentState
                        ebpParentPointer = parentP
                    case blockFinalizationData block of
                        -- If the block contains no finalization data, it is trivially valid and
                        -- inherits the last finalized pointer from the parent.
                        NoFinalizationData -> do
                            logEvent Skov LLInfo $ "Received block " ++ show block
                            return (ResultSuccess, Just $! VerifiedPendingBlock $! doExecuteBlock ExecuteBlockParams'{ebpFinInfo = Nothing,..})
                        -- If the block contains a finalization record...
                        BlockFinalizationData finRec@FinalizationRecord{finalizationBlockPointer=finBP,..} -> do
                            -- Get whichever block was finalized at the previous index.
                            -- We do this before calling finalization because there is a (slightly) greater
                            -- chance that this is the last finalized block, which saves a DB lookup.
                            previousFinalized <- fmap finalizationBlockPointer <$> recordAtFinIndex (finalizationIndex - 1)
                            -- send it for finalization processing
                            finOK <- finalizationReceiveRecord True finRec >>= \case
                                ResultSuccess ->
                                    -- In this event, we can be sure that the finalization record
                                    -- was used to finalize a block; so in particular, the block it
                                    -- finalizes is the named one.
                                    -- Check that the parent block is still live: potentially, the
                                    -- block might not be descended from the one it has a finalization
                                    -- record for.  Furthermore, if the parent block is finalized now,
                                    -- it has to be the last finalized block.
                                    getBlockStatus (bpHash parentP) >>= \case
                                        Just BlockAlive{} -> return True
                                        Just BlockFinalized{} -> do
                                            -- The last finalized block may have changed as a result
                                            -- of the call to finalizationReceiveRecord.
                                            (lf, _) <- getLastFinalized
                                            return (parentP == lf)
                                        _ -> return False
                                ResultDuplicate -> return True
                                _ -> return False
                            -- check that the finalized block at the previous index
                            -- is the last finalized block of the parent
                            check "invalid finalization" (finOK && previousFinalized == Just (bpLastFinalizedHash  parentP)) $
                                finalizationUnsettledRecordAt finalizationIndex >>= \case
                                     Nothing -> rejectInvalidBlock $ "no unsettled finalization at index " ++ show finalizationIndex
                                     Just (_,committee,_) ->
                                         -- Check that the finalized block at the given index
                                         -- is actually the one named in the finalization record.
                                         blockAtFinIndex finalizationIndex >>= \case
                                             Just fbp -> do 
                                                 check "finalization inconsistency" (bpHash fbp == finBP) $ do
                                                     logEvent Skov LLInfo $ "Received block " ++ show block
                                                     return (ResultSuccess,
                                                             Just (VerifiedPendingBlock (
                                                                      doExecuteBlock ExecuteBlockParams'{ebpFinInfo = Just (makeFinalizerInfo committee finalizationProof),..})))
                                             Nothing -> rejectInvalidBlock $ "no finalized block at index " ++ show finalizationIndex
    where
        checkClaimedSignature a = if verifyBlockSignature block then a else do
            logEvent Skov LLWarning "Dropping block where signature did not match claimed key or blockhash."
            return (ResultInvalid, Nothing)
        blockHash = getHash block
        rejectInvalidBlock reason = do
            logEvent Skov LLWarning $ "Block is not valid (" ++ reason ++ "): " ++ show block
            blockArriveDead blockHash
            return (ResultInvalid, Nothing)
        check reason q a = if q then a else rejectInvalidBlock reason


-- todo doc
type ExecuteBlockParams m = ExecuteBlockParams' (BlockState m) (BlockPointerType m)
-- todo doc
data ExecuteBlockParams' bst bpt = ExecuteBlockParams' {
    ebpSlotTime :: !Timestamp,
    ebpPb :: !PendingBlock,
    ebpTxVerCtx :: !bst,
    ebpParentPointer :: !bpt,
    ebpFinInfo :: !(Maybe FinalizerInfo)
}

class BlockExecutionMonad m where
    executeBlockM :: m UpdateResult

instance (TreeStateMonad m, FinalizationMonad m, SkovMonad m, OnSkov m, MonadIO m, MonadReader (ExecuteBlockParams m) m) => BlockExecutionMonad m where
    executeBlockM = do
        params <- ask
        res <- doExecuteBlock params
        return res

-- |Execute a 'VerifiedPendingBlock'.
-- Before adding the block to the tree we verify the transactions.
-- If the 'VerifiedPendingBlock' is awaiting its parent then it is added to the pending blocks table.
-- If the parent of @block@ is alive or finalized then we add it to the tree.
doExecuteBlock :: (TreeStateMonad m, FinalizationMonad m, SkovMonad m, OnSkov m) => ExecuteBlockParams m -> m UpdateResult
{- - INLINE doExecuteBlock - -}
doExecuteBlock ExecuteBlockParams'{..} = do
    verifyBlockTransactions ebpPb ebpTxVerCtx >>= \case
        Nothing -> deadBlock $! pbHash ebpPb
        Just (newBlock, verificationResults) -> addBlockWithLiveParent newBlock verificationResults ebpParentPointer ebpFinInfo
    where
        -- |Verify the transactions of the block within the provided block state context.
        -- If transactions could successfully be verified then this function
        -- outputs a 'Just (PendingBlock, [VerificationResult])' which should either be immediatly executed if the parent is
        -- alive or finalized.
        -- If the parent is pending as well or 'Unknown' then the block must be added as pending.
        -- If the transactions could not be verified we return 'Nothing' 
        verifyBlockTransactions pb@GB.PendingBlock{pbBlock = BakedBlock{..}, ..} contextState = do
            txListWithVerRes <- sequence <$> forM (blockTransactions pb)
                (\tr -> fst <$> doReceiveTransactionInternal (TV.Block contextState) tr ebpSlotTime (blockSlot pb))
            forM (unzip <$> txListWithVerRes) $ \(newTransactions, verificationResults) -> do
                purgeTransactionTable False =<< currentTime
                -- We wrap the processed transactions within the pending block as processing
                -- transactions ensures sharing of transactions in case of duplication.
                -- I.e. if a transaction has been received individually but also as part of the block
                -- we're about to execute.
                let block1 = GB.PendingBlock{pbBlock = BakedBlock{bbTransactions = newTransactions, ..}, ..}
                updateReceiveStatistics block1
                return (block1, verificationResults)
        -- |Mark the block as dead.
        deadBlock blockHash = do
            blockArriveDead blockHash
            return ResultStale


-- |Add a transaction to the transaction table.
-- This returns
--   * 'ResultSuccess' if the transaction is freshly added.
--     The transaction is added to the transaction table.
--   * 'ResultDuplicate', which indicates that either the transaction is a duplicate
--     The transaction is not added to the transaction table.
--   * 'ResultStale' which indicates that a transaction with the same sender
--     and nonce has already been finalized, or the transaction has already expired. In this case the transaction is not added to the table.
--   * 'ResultInvalid' which indicates that the transaction signature was invalid.
--     The transaction is not added to the transaction table.
--   * 'ResultShutDown' which indicates that consensus was shut down, and so the transaction was not added.
--   * 'ResultTooLowEnergy' which indicates that the transactions stated energy was below the minimum amount needed for the
--     transaction to be included in a block. The transaction is not added to the transaction table
--   * 'ResultNonexistingSenderAccount' the transfer contained an invalid sender. The transaction is not added to the
--     transaction table.
--   * 'ResultDuplicateAccountRegistrationID' the 'CredentialDeployment' contained an already registered registration id.
--     The transaction is not added to the transaction table.
--   * 'ResultCredentialDeploymentInvalidSignatures' the 'CredentialDeployment' contained invalid signatures.
--     The transaction is not added to the transaction table.
--   * 'ResultCredentialDeploymentInvalidIP' the 'CredentialDeployment' contained an unrecognized identity provider.
--     The transaction is not added to the transaction table.
--   * 'ResultCredentialDeploymentInvalidAR' the 'CredentialDeployment' contained unrecognized anonymity revokers. 
--     The transaction is not added to the transaction table.
--   * 'ResultCredentialDeploymentExpired' the 'CredentialDeployment' was expired. The transaction is not added to
--     the transaction table.
--   * 'ResultChainUpdateInvalidSequenceNumber' the update contained an invalid 'UpdateSequenceNumber'.
--   * 'ResultChainUpdateInvalidEffectiveTime' the update contained an invalid effective time. In particular the effective time
--      was before the timeout of the update.
--   * 'ResultChainUpdateInvalidSignatures' the update contained invalid signatures.
--   * 'ResultEnergyExceeded' the stated energy of the transaction exceeds the maximum allowed for the block.
doReceiveTransaction :: (TreeStateMonad m,
                         TimeMonad m,
                         SkovQueryMonad m) => BlockItem -> m UpdateResult
doReceiveTransaction tr = unlessShutDown $ do
    now <- currentTime
    ur <- snd <$> doReceiveTransactionInternal TV.Single tr (utcTimeToTimestamp now) 0
    when (ur == ResultSuccess) $ purgeTransactionTable False =<< currentTime
    return ur

-- |Add a transaction to the transaction table.  The 'Slot' should be
-- the slot number of the block that the transaction was received with.
-- This function should only be called when a transaction is received as part of a block.
-- The difference from the above function is that this function returns an already existing
-- transaction in case of a duplicate, ensuring more sharing of transaction data.
-- This function also verifies the incoming transactions and adds them to the internal
-- transaction verification cache such that the verification result can be used by the 'Scheduler'.
-- The @origin@ parameter means if the transaction was received individually or as part of a block.
-- The function returns the 'BlockItem' if it was "successfully verified" and added to the transaction table.
-- Note. "Successfully verified" depends on the 'TransactionOrigin', see 'definitelyNotValid' below for details.
doReceiveTransactionInternal :: (TreeStateMonad m) => TV.TransactionOrigin m -> BlockItem -> Timestamp -> Slot -> m (Maybe (BlockItem, Maybe TV.VerificationResult), UpdateResult)
doReceiveTransactionInternal origin tr ts slot = do
    ctx <- getVerificationCtx =<< getBlockState
    addCommitTransaction tr ctx ts slot >>= \case
        Added bi@WithMetadata{..} verRes -> do
          ptrs <- getPendingTransactions
          case wmdData of
            NormalTransaction tx -> do
              -- Transactions received individually should always be added to the ptt.
              -- If the transaction was received as part of a block we only add it to the ptt if
              -- the transaction nonce is at least the `nextNonce` recorded for sender account.
              -- 
              -- The pending transaction table records transactions that are pending from the perspective of the focus block (which is always above the last finalized block).
              -- It is an invariant of the pending table and focus block that the next recorded nonce for any sender in the pending table is
              -- the same as the next account nonce from the perspective of the focus block.
              -- 
              -- When receiving transactions individually, the pre-validation done in addCommitTransaction already checks that the transaction nonce is the next available one.
              -- This is always at least the nonce that is recorded in the focus block for the account.
              -- The invariant then ensures that the next nonce for the sender in the pending table is the same as that in the focus block for the account.
              --
              -- However when receiving transactions as part of a block pre-validation only ensures that the nonce is at least the last finalized one
              -- (or at least the one in the parent block, depending on whether the parent block exists or not).
              -- In the case the parent block is above the focus block, or the parent block does not exist,
              -- this nonce would in general be above the nonce recorded in the focus block for the account.
              -- Hence to maintain the invariant we have to inform the pending table what the next available nonce is in the focus block.
              let add nextNonce = putPendingTransactions $! addPendingTransaction nextNonce WithMetadata{wmdData=tx,..} ptrs
              case origin of
                TV.Single -> add $ transactionNonce tx
                TV.Block _ -> do
                  focus <- getFocusBlock
                  st <- blockState focus
                  macct <- getAccount st $! transactionSender tx
                  nextNonce <- fromMaybe minNonce <$> mapM (getAccountNonce . snd) macct
                  -- If a transaction with this nonce has already been run by
                  -- the focus block, then we do not need to add it to the
                  -- pending transactions. Otherwise, we do.
                  when (nextNonce <= transactionNonce tx) $ add nextNonce
            CredentialDeployment _ -> do
                  putPendingTransactions $! addPendingDeployCredential wmdHash ptrs
            ChainUpdate cu -> do
                focus <- getFocusBlock
                st <- blockState focus
                nextSN <- getNextUpdateSequenceNumber st (updateType (uiPayload cu))
                when (nextSN <= updateSeqNumber (uiHeader cu)) $
                    putPendingTransactions $! addPendingUpdate nextSN cu ptrs
          -- The actual verification result here is only used if the transaction was received individually.
          -- If the transaction was received as part of a block we don't use the result for anything.
          return (Just (bi, Just verRes), transactionVerificationResultToUpdateResult verRes)
        -- Return the cached verification result if the transaction was either `Received` or `Committed`.
        -- The verification result is used by the `Scheduler` if this transaction was part of a block.
        -- Note. the `Scheduler` will re-verify the transaction if required,
        -- that is if any of the keys used for signing were updated between the transaction was
        -- point of execution.
        -- If the transaction was received individually and it was already verified and stored beforehand
        -- then `ResultDuplicate` will be returned externally.
        Duplicate tx mVerRes -> return (Just (tx, mVerRes), ResultDuplicate)
        ObsoleteNonce -> return (Nothing, ResultStale)
        NotAdded verRes -> return (Nothing, transactionVerificationResultToUpdateResult verRes)
  where
      getVerificationCtx state = do
        gd <- getGenesisData
        let isOriginBlock = case origin of
                TV.Single -> False
                TV.Block _ -> True
        pure $ Context state (gdMaxBlockEnergy gd) isOriginBlock
      -- We use the last finalized block for transactions received individually.
      -- For transactions received as part of a block we try use the parent block
      -- if it's eligible. That is, the parent block must be ´Alive´ otherwise we fallback
      -- to use the last finalized block.
      getBlockState = do
        case origin of
          TV.Single -> blockState . fst =<< getLastFinalized
          TV.Block bs -> pure bs

-- |Clear the skov instance __just before__ handling the protocol update. This
-- clears all blocks that are not finalized but otherwise maintains all existing
-- state invariants. This prepares the state for @migrateExistingSkov@.
doClearSkov :: (TreeStateMonad m, SkovMonad m) => m ()
doClearSkov = isShutDown >>= \case
    False -> return ()
    True -> do
        lfb <- lastFinalizedBlock
        -- Archive the state
        archiveBlockState =<< blockState lfb
        -- Make the last finalized block the focus block,
        -- adjusting the pending transaction table.
        updateFocusBlockTo lfb
        -- Clear out all of the non-finalized and pending blocks.
        clearOnProtocolUpdate

-- |Terminate the skov instance __after__ the protocol update has taken effect.
-- After this point the skov instance is useful for queries only.
doTerminateSkov :: (TreeStateMonad m, SkovMonad m) => m ()
doTerminateSkov = isShutDown >>= \case
    False -> return ()
    True -> clearAfterProtocolUpdate

doPurgeTransactions :: (TimeMonad m, TreeStateMonad m) => m ()
doPurgeTransactions = do
        now <- currentTime
        purgeTransactionTable True now


-- |Maps the underlying 'TransactionVerificationResult' to the according 'UpdateResult' type.
-- See the 'VerificationResult' for more information.
transactionVerificationResultToUpdateResult :: TV.VerificationResult -> UpdateResult
-- 'Ok' mappings
transactionVerificationResultToUpdateResult (TV.Ok _) = ResultSuccess
-- 'MaybeOk' mappings
transactionVerificationResultToUpdateResult (TV.MaybeOk (TV.CredentialDeploymentInvalidIdentityProvider _)) = ResultCredentialDeploymentInvalidIP
transactionVerificationResultToUpdateResult (TV.MaybeOk TV.CredentialDeploymentInvalidAnonymityRevokers) = ResultCredentialDeploymentInvalidAR
transactionVerificationResultToUpdateResult (TV.MaybeOk (TV.ChainUpdateInvalidNonce _)) = ResultNonceTooLarge
transactionVerificationResultToUpdateResult (TV.MaybeOk TV.ChainUpdateInvalidSignatures) = ResultChainUpdateInvalidSignatures
transactionVerificationResultToUpdateResult (TV.MaybeOk TV.NormalTransactionInsufficientFunds) = ResultInsufficientFunds
transactionVerificationResultToUpdateResult (TV.MaybeOk (TV.NormalTransactionInvalidSender _)) = ResultNonexistingSenderAccount
transactionVerificationResultToUpdateResult (TV.MaybeOk TV.NormalTransactionInvalidSignatures) = ResultVerificationFailed
transactionVerificationResultToUpdateResult (TV.MaybeOk (TV.NormalTransactionInvalidNonce _)) = ResultNonceTooLarge
-- 'NotOk' mappings
transactionVerificationResultToUpdateResult (TV.NotOk (TV.CredentialDeploymentDuplicateAccountRegistrationID _)) = ResultDuplicateAccountRegistrationID
transactionVerificationResultToUpdateResult (TV.NotOk TV.CredentialDeploymentInvalidSignatures) = ResultCredentialDeploymentInvalidSignatures
transactionVerificationResultToUpdateResult (TV.NotOk (TV.ChainUpdateSequenceNumberTooOld _)) = ResultChainUpdateSequenceNumberTooOld
transactionVerificationResultToUpdateResult (TV.NotOk TV.ChainUpdateEffectiveTimeBeforeTimeout) = ResultChainUpdateInvalidEffectiveTime
transactionVerificationResultToUpdateResult (TV.NotOk TV.CredentialDeploymentExpired) = ResultCredentialDeploymentExpired
transactionVerificationResultToUpdateResult (TV.NotOk TV.NormalTransactionDepositInsufficient) = ResultTooLowEnergy
transactionVerificationResultToUpdateResult (TV.NotOk TV.NormalTransactionEnergyExceeded) = ResultEnergyExceeded
transactionVerificationResultToUpdateResult (TV.NotOk (TV.NormalTransactionDuplicateNonce _)) = ResultDuplicateNonce
transactionVerificationResultToUpdateResult (TV.NotOk TV.Expired) = ResultStale
transactionVerificationResultToUpdateResult (TV.NotOk TV.InvalidPayloadSize) = ResultSerializationFail

