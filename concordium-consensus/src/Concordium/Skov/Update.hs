{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Concordium.Skov.Update where

import Control.Monad
import Control.Monad.Except
import Data.Foldable
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import qualified Data.Sequence as Seq
import Data.Time (diffUTCTime)
import qualified Data.Vector as Vec
import GHC.Stack
import Lens.Micro.Platform

import Concordium.GlobalState.BakerInfo
import Concordium.GlobalState.Block hiding (PendingBlock)
import qualified Concordium.GlobalState.Block as GB (PendingBlock (..))
import Concordium.GlobalState.BlockMonads
import Concordium.GlobalState.BlockPointer hiding (BlockPointer)
import Concordium.GlobalState.BlockState
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.TreeState
import Concordium.Types
import Concordium.Types.Accounts
import Concordium.Types.HashableTo
import Concordium.Types.Transactions

import Concordium.Scheduler.TreeStateEnvironment

import Concordium.Afgjort.Finalize
import Concordium.Afgjort.Finalize.Types
import Concordium.Birk.LeaderElection
import Concordium.GlobalState.TransactionTable
import Concordium.Kontrol hiding (getGenesisData, getRuntimeParameters)
import Concordium.Kontrol.Bakers
import Concordium.Kontrol.UpdateLeaderElectionParameters
import Concordium.Logger
import Concordium.Scheduler.Types (updateSeqNumber)
import Concordium.Skov.Statistics
import Concordium.TimeMonad
import qualified Concordium.TransactionVerification as TV
import Concordium.Types.Updates (uiHeader, uiPayload, updateType)

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
        EQ ->
            if oBB == nBB
                then return $ foldl (\p f -> forwardPTT (blockTransactions f) p) pts forw
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
    FinalizerInfo
        { committeeVoterPower = finPower <$> parties committee,
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
    let purgeLoop =
            takeNextPendingUntil lfSlot >>= \case
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
        let pruneTrunk ::
                [BlockPointerType m] -> -- \^List of blocks to remove.
                [BlockPointerType m] -> -- \^List of finalized blocks.
                BlockPointerType m -> -- \^Finalized block to consider now.
                -- At the same height as the latest branch in the next argument
                Branches m ->
                m ([BlockPointerType m], [BlockPointerType m])
            -- \^ The return value is a list of blocks to mark dead (ordered by decreasing
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
                    return (b : blocks)
        finalizedBlocks <- doArchive =<< bpParent newFinBlock
        -- Prune the branches: mark dead any block that doesn't descend from
        -- the newly-finalized block.
        -- Instead of marking blocks dead immediately we accumulate them
        -- and a return a list. The reason for doing this is that we never
        -- have to look up a parent block that is already marked dead.
        let
            pruneBranches ::
                [BlockPointerType m] -> -- \^Accumulator of blocks to mark dead.
                [BlockPointerType m] -> -- \^Parents that remain alive.
                Branches m -> -- \^Branches to prune
                m (Branches m, [BlockPointerType m])
            -- \^The return value is a pair of new branches and the
            -- list of blocks to mark dead. The blocks are ordered
            -- by decreasing height.
            pruneBranches toRemove _ Seq.Empty = return (Seq.empty, toRemove)
            pruneBranches toRemove parents (brs Seq.:<| rest) = do
                (survivors, removals) <-
                    foldrM
                        ( \bp ~(keep, remove) -> do
                            parent <- bpParent bp
                            if parent `elem` parents
                                then return (bp : keep, remove)
                                else return (keep, bp : remove)
                        )
                        ([], toRemove)
                        brs
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

-- |Add a block where the parent block is known to be alive and the transactions have been verified.
-- If the block proves to be valid, it is added to the tree and this returns 'ResultSuccess'.
-- Otherwise, the block is marked dead and 'ResultInvalid' is returned.
--
-- This function ensures that
--
-- 1. If a finalization record is present then it's verified.
--
-- 2. The claimed state hash matches the one resulting from execution.
--
-- 3. The claimed transaction outcomes hash matches the one resulting from execution.
--
-- PRECONDITION: The parent of the block provided must be alive.
addBlockWithLiveParent ::
    forall m.
    (HasCallStack, TreeStateMonad m, SkovMonad m, FinalizationMonad m, OnSkov m) =>
    -- |A pending block with a live or finalized parent.
    PendingBlock ->
    -- |Verification results of transactions, corresponding to those in the block
    [Maybe TV.VerificationResult] ->
    -- |Parent block pointer
    BlockPointerType m ->
    m UpdateResult
addBlockWithLiveParent block txvers parentP = do
    -- Determine if the block's finalized data is valid and if so what
    -- its last finalized block pointer should be.
    case blockFinalizationData block of
        -- If the block contains no finalization data, it is trivially valid and
        -- inherits the last finalized pointer from the parent.
        NoFinalizationData -> do
            execute Nothing =<< bpLastFinalized parentP
        -- If the block contains a finalization record...
        BlockFinalizationData finRec@FinalizationRecord{finalizationBlockPointer = finBP, ..} -> do
            -- Get whichever block was finalized at the previous index.
            -- We do this before calling finalization because there is a (slightly) greater
            -- chance that this is the last finalized block, which saves a DB lookup.
            previousFinalized <- fmap finalizationBlockPointer <$> recordAtFinIndex (finalizationIndex - 1)
            -- send it for finalization processing
            finOK <-
                finalizationReceiveRecord True finRec >>= \case
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
            check "invalid finalization" (finOK && previousFinalized == Just (bpLastFinalizedHash parentP)) $
                finalizationUnsettledRecordAt finalizationIndex >>= \case
                    Nothing -> invalidBlock $ "no unsettled finalization at index " ++ show finalizationIndex
                    Just (_, committee, _) ->
                        -- Check that the finalized block at the given index
                        -- is actually the one named in the finalization record.
                        blockAtFinIndex finalizationIndex >>= \case
                            Just fbp -> do
                                check "finalization inconsistency" (bpHash fbp == finBP) $ do
                                    execute (Just $! makeFinalizerInfo committee finalizationProof) fbp
                            Nothing -> invalidBlock $ "no finalized block at index " ++ show finalizationIndex
  where
    invalidBlock :: String -> m UpdateResult
    invalidBlock reason = do
        logEvent Skov LLWarning $ "Block is not valid (" ++ reason ++ "): " ++ show block
        blockArriveDead blkHash
        return ResultInvalid
    check reason q a = if q then a else invalidBlock reason
    blkSlot = blockSlot block
    blkHash = getHash block
    -- Check the block nonce and execute the block.
    -- If the execution went well we add it to the tree and return 'ResultSuccess'.
    -- Otherwise we return 'ResultInvalid' for indicating that the block is not valid.
    execute mFinInfo lfbp = do
        parentState <- blockState parentP
        parentSeedState <- getSeedState parentState
        -- Update the seed state with the block nonce
        let newSeedState = updateSeedState blkSlot (blockNonce block) parentSeedState
            ts = zip (blockTransactions block) txvers
        slotTime <- getSlotTimestamp blkSlot
        executeFrom blkHash blkSlot slotTime parentP (blockBaker block) mFinInfo newSeedState ts >>= \case
            Left err -> do
                logEvent Skov LLWarning ("Block execution failure: " ++ show err)
                invalidBlock "execution failure"
            Right result -> do
                -- Check that the StateHash is correct
                stateHash <- getStateHash (_finalState result)
                check "Claimed stateHash did not match calculated stateHash" (stateHash == blockStateHash block) $ do
                    -- Check that the TransactionOutcomeHash is correct
                    tohash <- getTransactionOutcomesHash (_finalState result)
                    check "Claimed transactionOutcomesHash did not match actual transactionOutcomesHash" (tohash == blockTransactionOutcomesHash block) $ do
                        -- Add the block to the tree
                        blockP <- blockArrive block parentP lfbp result
                        -- Notify of the block arrival (for finalization)
                        finalizationBlockArrival blockP
                        onBlock blockP
                        -- Handle any blocks that are waiting for this one
                        children <- takePendingChildren blkHash
                        mapM_ processPendingChild children
                        return ResultSuccess

-- |Process a block that has been awaiting its parent to become live.
-- If the parent of the block is not alive or finalized then the block is marked as dead.
-- Otherwise the block is verified in the same manner as if the block was received while the
-- parent was alive or finalized.
-- Only if the above checks out then the block is executed and the block is marked as live.
processPendingChild ::
    forall m.
    (HasCallStack, TreeStateMonad m, SkovMonad m, FinalizationMonad m, OnSkov m) =>
    -- |A pending block.
    PendingBlock ->
    m ()
processPendingChild block = do
    -- We lookup the parent block here as opposed to pass it in via a parameter in the loop where
    -- we process the children of a pending block just added.
    -- The reason is that the parent block could become dead by having two children, one of which
    -- includes a finalization proof of a branch that does not include the parent. [This is not a
    -- normal scenario.] When that block is processed, the finalization record will render the
    -- parent block dead, so the processing for subsequent pending children should not be processed
    -- as if the parent is live.
    getRecentBlockStatus (blockPointer block) >>= \case
        RecentBlock (BlockAlive parentP) -> process parentP
        RecentBlock (BlockFinalized parentP _) -> process parentP
        _ -> deadBlock
  where
    invalidBlock :: String -> m ()
    invalidBlock reason = do
        logEvent Skov LLWarning $ "Pending block child is not valid (" ++ reason ++ "): " ++ show block
        blockArriveDead $ getHash block
        return ()
    deadBlock :: m ()
    deadBlock = do
        blockArriveDead $ getHash block
        return ()
    process parentP = do
        childStatus <- getRecentBlockStatus (getHash block)
        let isPending Unknown = True
            isPending (RecentBlock (BlockPending _)) = True
            isPending _ = False
        when (isPending childStatus) $
            -- Here, we need to do all of the checks on the pending block that would have been done
            -- for a block with a live parent when it was received, but may not have been done for
            -- a pending one.
            liveParentChecks block parentP >>= \case
                Left reason -> invalidBlock reason
                _ -> do
                    verRess <- mapM getNonFinalizedTransactionVerificationResult (blockTransactions block)
                    addBlockWithLiveParent block verRess parentP >>= \case
                        ResultSuccess -> onPendingLive
                        _ -> return ()

-- |This performs the following checks on a block, given the pointer to its parent block, which
-- is assumed to be alive:
--
-- 1. The slot number of the block exceeds the slot number of the parent block.
--
-- 2. The block baker is valid.
--
-- 3. The baker key matches the block's claimed key.
--
-- 4. The block nonce is valid.
--
-- 5. The block proof is valid.
--
-- If any check fails, @Left e@ is returned, where @e@ is a 'String' describing the failure.
-- Otherwise @Right ()@ is returned.
liveParentChecks ::
    (TreeStateMonad m, SkovMonad m) =>
    -- |Block to check
    PendingBlock ->
    -- |Parent pointer
    BlockPointerType m ->
    m (Either String ())
liveParentChecks block parentP = runExceptT $ do
    unless (blockSlot parentP < blockSlot block) $
        throwError $
            "block slot ("
                ++ show (blockSlot block)
                ++ ") not later than parent block slot ("
                ++ show (blockSlot parentP)
                ++ ")"
    -- get Birk parameters from the __parent__ block. The baker must have existed in that
    -- block's state in order that the current block is valid
    parentState <- blockState parentP
    -- Determine the baker and its lottery power
    gd <- getGenesisData
    bakers <- getSlotBakers gd parentState (blockSlot block)
    -- Determine the leadership election nonce
    parentSeedState <- getSeedState parentState
    let nonce = computeLeadershipElectionNonce parentSeedState (blockSlot block)
    -- Determine the election difficulty
    slotTime <- getSlotTimestamp (blockSlot block)
    elDiff <- getElectionDifficulty parentState slotTime
    case lotteryBaker bakers (blockBaker block) of
        Nothing -> throwError $ "unknown baker " ++ show (blockBaker block)
        Just (BakerInfo{..}, lotteryPower) -> do
            -- Check the baker key matches the claimed key.
            unless (_bakerSignatureVerifyKey == blockBakerKey block) $
                throwError "Baker key claimed in block did not match actual baker key"
            -- Check the block nonce
            unless
                ( verifyBlockNonce
                    nonce
                    (blockSlot block)
                    _bakerElectionVerifyKey
                    (blockNonce block)
                )
                $ throwError "invalid block nonce"
            -- Check the block proof.
            -- This ensures that the baker is entitled to bake this block.
            unless
                ( verifyProof
                    nonce
                    elDiff
                    (blockSlot block)
                    _bakerElectionVerifyKey
                    lotteryPower
                    (blockProof block)
                )
                $ throwError "invalid block proof"

-- |Add a valid, live block to the tree.
-- This is used by 'addBlockWithLiveParent' and 'doBakeForSlot', and should not
-- be called directly otherwise.
blockArrive ::
    (HasCallStack, TreeStateMonad m, SkovMonad m) =>
    -- |Block to add
    PendingBlock ->
    -- |Parent pointer
    BlockPointerType m ->
    -- |Last finalized pointer
    BlockPointerType m ->
    -- |Result of block execution (state, energy used, ...)
    ExecutionResult m ->
    m (BlockPointerType m)
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
    if insertIndex < branchLen
        then putBranches $ brs & ix (fromIntegral insertIndex) %~ (blockP :)
        else
            if insertIndex == branchLen
                then putBranches $ brs Seq.|> [blockP]
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
-- If the validity of the block could not be verified then the block is marked
-- as dead and the 'UpdateResult' contains whether the block was either stale or
-- simply invalid.
doReceiveBlock :: (TreeStateMonad m, SkovMonad m) => PendingBlock -> m (UpdateResult, Maybe VerifiedPendingBlock)
doReceiveBlock pb@GB.PendingBlock{pbBlock = BakedBlock{..}, ..} =
    isShutDown >>= \case
        True -> return (ResultConsensusShutDown, Nothing)
        False -> do
            (timeSpent, res) <- measureTime verify
            logEvent Skov LLInfo $ "Block " ++ show pbHash ++ " verified in " ++ show timeSpent
            return res
  where
    verify = do
        threshold <- rpEarlyBlockThreshold <$> getRuntimeParameters
        slotTime <- getSlotTimestamp (blockSlot pb)
        -- Check if the block is too early. We check that the threshold is not maxBound also, so that
        -- by setting the threshold to maxBound we can ensure blocks will never be considered early.
        -- This can be useful for testing.
        -- A more general approach might be to check for overflow generally, but this is simple and
        -- workable.
        if slotTime > addDuration (utcTimeToTimestamp pbReceiveTime) threshold && threshold /= maxBound
            then return (ResultEarlyBlock, Nothing)
            else -- Check if the block is already known.

                getRecentBlockStatus blockHash >>= \case
                    Unknown -> do
                        lfs <- getLastFinalizedSlot
                        -- The block must be later than the last finalized block, otherwise it is already
                        -- dead.
                        if lfs >= blockSlot pb
                            then rejectStaleBlock
                            else do
                                -- Get the parent if available
                                let parent = blockPointer bbFields
                                parentStatus <- getRecentBlockStatus parent
                                -- If the parent is unknown, try to check the signing key and block proof based on the last finalized block
                                case parentStatus of
                                    Unknown -> processPending slotTime Nothing
                                    RecentBlock (BlockPending ppb) -> processPending slotTime $ Just $ blockSlot ppb
                                    RecentBlock (BlockAlive parentB) -> processLive pb parentB
                                    RecentBlock (BlockFinalized parentB _) -> processLive pb parentB
                                    RecentBlock BlockDead -> rejectStaleBlock
                                    OldFinalized -> rejectStaleBlock
                    _ -> return (ResultDuplicate, Nothing)
    checkClaimedSignature a =
        if verifyBlockSignature pb
            then a
            else do
                rejectInvalidBlock "Dropping block where signature did not match claimed key or blockhash."
    blockHash = getHash pb
    -- Reject a block which is deemed invalid.
    -- Mark the block as dead.
    rejectInvalidBlock reason = do
        logEvent Skov LLWarning $ "Block is not valid (" ++ reason ++ "): " ++ show pb
        blockArriveDead blockHash
        return (ResultInvalid, Nothing)
    -- Reject a block which is deemed invalid.
    -- Mark the block as dead.
    rejectStaleBlock = do
        blockArriveDead blockHash
        return (ResultStale, Nothing)
    -- Verify the transactions of the block.
    -- Note. We only verify transactions here for pending blocks i.e. blocks awaiting its parent
    -- to be either alive or finalized.
    -- Blocks who already have a parent that is either finalized or alive have their
    -- transactions checked in 'doExecuteBlock'.
    verifyBlockTransactions slotTime contextState = do
        txListWithVerRes <-
            sequence
                <$> forM
                    (blockTransactions pb)
                    (\tr -> fst <$> doReceiveTransactionInternal (TV.Block contextState) tr slotTime (blockSlot pb))
        forM (unzip <$> txListWithVerRes) $ \(newTransactions, verificationResults) -> do
            purgeTransactionTable False =<< currentTime
            let block1 = GB.PendingBlock{pbBlock = BakedBlock{bbTransactions = newTransactions, ..}, ..}
            return (block1, verificationResults)
    -- Processes a pending block that cannot be immediately be executed.
    processPending slotTime maybeParentBlockSlot = do
        -- Check:
        -- - Claimed baker key is valid in committee (if possible to check).
        -- - Proof is valid (if possible to check).
        -- - Signature is correct with the claimed key.
        -- - Assert that transactions can be verified with reference to the last finalized block.
        lastFin <- fst <$> getLastFinalized
        lastFinBS <- blockState lastFin
        gd <- getGenesisData
        let continuePending = checkClaimedSignature $ do
                verifyBlockTransactions slotTime lastFinBS >>= \case
                    Nothing -> rejectInvalidBlock "Pending block contained invalid transactions"
                    Just (newBlock, _) -> (,Nothing) <$> addBlockAsPending newBlock
        getDefiniteSlotBakers gd lastFinBS (blockSlot pb) >>= \case
            Just bakers -> case lotteryBaker bakers (blockBaker pb) of
                Just (bkrInfo, bkrPower)
                    | bkrInfo ^. bakerSignatureVerifyKey /= blockBakerKey pb -> do
                        rejectInvalidBlock "Pending block is not signed by a valid baker"
                    | otherwise -> do
                        lastFinSS <- getSeedState lastFinBS
                        case predictLeadershipElectionNonce lastFinSS (blockSlot lastFin) maybeParentBlockSlot (blockSlot pb) of
                            Nothing -> continuePending -- Cannot check the proof (yet)
                            Just nonceList -> do
                                -- We get the election difficulty based on the last finalized block.
                                -- In principle, this could change before the block.
                                elDiff <- getElectionDifficulty lastFinBS slotTime
                                let verifyProofWithNonce nonce =
                                        verifyProof
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
                                        rejectInvalidBlock "Block proof of pending block was not verifiable"
                Nothing -> rejectInvalidBlock "Baker id not part of baker committee"
            Nothing -> continuePending
    -- Processes a block that is subject to become live.
    -- I.e. its parent is either alive or finalized.
    -- See documentation of 'liveParentChecks' for the concrete checks that are carried out in this case.
    -- Note: we do not verify transactions here as we do for `processPending` since the transactions will be
    -- verified as part of `doExecuteBlock` which is called subsequently.
    processLive block parentP =
        liveParentChecks block parentP >>= \case
            Left reason -> rejectInvalidBlock reason
            _ ->
                -- Check the signature on the block is valid.
                -- 'liveParentChecks' ensures that the baker key is
                -- registered on chain for the associated baker.
                checkClaimedSignature $
                    do
                        updateReceiveStatistics block
                        logEvent Skov LLInfo $ "Received block " ++ show block
                        return (ResultSuccess, Just $! VerifiedPendingBlock pb)

-- |Execute a 'VerifiedPendingBlock'.
-- Before adding the block to the tree we make sure that
-- the parent block live and verify the transactions of the block
-- we're about to add.
doExecuteBlock :: (TreeStateMonad m, FinalizationMonad m, SkovMonad m, OnSkov m) => VerifiedPendingBlock -> m UpdateResult
doExecuteBlock (VerifiedPendingBlock pb) = do
    isShutDown >>= \case
        True -> return ResultConsensusShutDown
        False -> do
            (timeSpent, res) <- measureTime $ do
                -- Resolve the parent block of the one we're about to add to the tree.
                -- We execute the provided block only if the parent is live.
                -- If the parent block is not live then we reject it.
                getRecentBlockStatus (blockPointer pb) >>= \case
                    RecentBlock (BlockAlive parentP) -> execute parentP
                    RecentBlock (BlockFinalized parentP _) -> execute parentP
                    _ -> rejectInvalidBlock
            logEvent Skov LLInfo $ "Block " ++ show blockHash ++ " executed in " ++ show timeSpent
            return res
  where
    execute parentP = do
        parentState <- blockState parentP
        verifyBlockTransactions pb parentState >>= \case
            Nothing -> rejectInvalidBlock
            Just (newBlock, verificationResults) -> addBlockWithLiveParent newBlock verificationResults parentP
    blockHash = getHash pb
    -- Verify the transactions of the block within the provided block state context.
    -- If transactions could successfully be verified then this function
    -- outputs a 'Just (PendingBlock, [VerificationResult])' which should either be immediately executed if the parent is
    -- alive or finalized.
    -- If the parent is pending as well or 'Unknown' then the block must be added as pending.
    -- If the transactions are deemed invalid we return 'Nothing'
    verifyBlockTransactions GB.PendingBlock{pbBlock = BakedBlock{..}, ..} contextState = do
        slotTime <- getSlotTimestamp (blockSlot pb)
        txListWithVerRes <-
            sequence
                <$> forM
                    (blockTransactions pb)
                    (\tr -> fst <$> doReceiveTransactionInternal (TV.Block contextState) tr slotTime (blockSlot pb))
        forM (unzip <$> txListWithVerRes) $ \(newTransactions, verificationResults) -> do
            purgeTransactionTable False =<< currentTime
            -- We wrap the processed transactions within the pending block as processing
            -- transactions ensures sharing of transactions in case of duplication.
            -- I.e. if a transaction has been received individually but also as part of the block
            -- we're about to execute.
            let block1 = GB.PendingBlock{pbBlock = BakedBlock{bbTransactions = newTransactions, ..}, ..}
            return (block1, verificationResults)
    -- Mark the block as dead and return 'ResultInvalid.
    rejectInvalidBlock = do
        blockArriveDead blockHash
        return ResultInvalid

-- |Receive and execute the block immediately.
-- See documentation for `doReceiveBlock` and `doExecuteBlock`
-- Returns 'ResultSuccess' if the block was added to the tree.
doReceiveExecuteBlock :: (TreeStateMonad m, SkovMonad m, FinalizationMonad m, OnSkov m) => PendingBlock -> m UpdateResult
doReceiveExecuteBlock block = do
    doReceiveBlock block >>= \case
        (ResultSuccess, Just vpb) -> doExecuteBlock vpb
        (ur, _) -> return ur

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
doReceiveTransaction ::
    ( TreeStateMonad m,
      TimeMonad m,
      SkovQueryMonad m
    ) =>
    BlockItem ->
    m UpdateResult
doReceiveTransaction tr = unlessShutDown $ do
    now <- currentTime
    ur <- snd <$> doReceiveTransactionInternal TV.Single tr (utcTimeToTimestamp now) 0
    when (ur == ResultSuccess) $ purgeTransactionTable False =<< currentTime
    return ur

-- |Add a transaction that has previously been verified, given the result of verification.
doAddPreverifiedTransaction ::
    (TreeStateMonad m, TimeMonad m) =>
    BlockItem ->
    TV.OkResult ->
    m UpdateResult
doAddPreverifiedTransaction blockItem okRes = do
    res <- addVerifiedTransaction blockItem okRes
    case res of
        Added WithMetadata{..} verRes -> do
            ptrs <- getPendingTransactions
            case wmdData of
                NormalTransaction tx -> do
                    -- Record the transaction in the pending transaction table.
                    focus <- getFocusBlock
                    st <- blockState focus
                    macct <- getAccount st $! transactionSender tx
                    nextNonce <- fromMaybe minNonce <$> mapM (getAccountNonce . snd) macct
                    when (nextNonce <= transactionNonce tx) $
                        putPendingTransactions $!
                            addPendingTransaction nextNonce WithMetadata{wmdData = tx, ..} ptrs
                CredentialDeployment _ -> do
                    putPendingTransactions $! addPendingDeployCredential wmdHash ptrs
                ChainUpdate cu -> do
                    focus <- getFocusBlock
                    st <- blockState focus
                    nextSN <- getNextUpdateSequenceNumber st (updateType (uiPayload cu))
                    when (nextSN <= updateSeqNumber (uiHeader cu)) $
                        putPendingTransactions $!
                            addPendingUpdate nextSN cu ptrs
            purgeTransactionTable False =<< currentTime
            return $! transactionVerificationResultToUpdateResult verRes
        Duplicate{} -> return ResultDuplicate
        ObsoleteNonce -> return ResultStale
        NotAdded verRes -> return $! transactionVerificationResultToUpdateResult verRes

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
                    let add nextNonce = putPendingTransactions $! addPendingTransaction nextNonce WithMetadata{wmdData = tx, ..} ptrs
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
                        putPendingTransactions $!
                            addPendingUpdate nextSN cu ptrs
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
doClearSkov =
    isShutDown >>= \case
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
doTerminateSkov =
    isShutDown >>= \case
        False -> return ()
        True -> clearAfterProtocolUpdate

doPurgeTransactions :: (TimeMonad m, TreeStateMonad m) => m ()
doPurgeTransactions = do
    now <- currentTime
    purgeTransactionTable True now
