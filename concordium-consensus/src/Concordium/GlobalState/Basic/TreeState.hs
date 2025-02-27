{-# LANGUAGE DataKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
-- FIXME: This is to suppress compiler warnings for derived instances of BlockStateOperations.
-- This may be fixed in GHC 9.0.1.
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Concordium.GlobalState.Basic.TreeState where

import Concordium.Utils
import Control.Exception
import Control.Monad.State
import Data.Foldable
import Data.Functor.Identity
import Data.List (intercalate, partition)
import Data.Maybe (fromMaybe)
import Lens.Micro.Platform

import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as Map
import qualified Data.PQueue.Prio.Min as MPQ
import qualified Data.Sequence as Seq

import Concordium.GlobalState.Basic.BlockPointer
import Concordium.GlobalState.Block
import Concordium.GlobalState.BlockMonads
import Concordium.GlobalState.BlockPointer
import qualified Concordium.GlobalState.BlockState as BS
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.PurgeTransactions
import Concordium.GlobalState.Statistics (ConsensusStatistics, initialConsensusStatistics)
import Concordium.GlobalState.TransactionTable
import qualified Concordium.GlobalState.TreeState as TS
import Concordium.GlobalState.Types
import Concordium.TimeMonad (TimeMonad)
import qualified Concordium.TransactionVerification as TVer
import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.Types.Transactions
import Concordium.Types.Updates

-- |Datatype representing an in-memory tree state.
-- The first type parameter, @pv@, is the protocol version.
-- The second type parameter, @bs@, is the type of the block state.
data SkovData (pv :: ProtocolVersion) bs = SkovData
    { -- |Map of all received blocks by hash.
      _blockTable :: !(HM.HashMap BlockHash (TS.BlockStatus (BasicBlockPointer pv bs) PendingBlock)),
      -- |Table of blocks finalized by height.
      _finalizedByHeightTable :: !(HM.HashMap BlockHeight (BasicBlockPointer pv bs)),
      -- |Map of (possibly) pending blocks by hash
      _possiblyPendingTable :: !(HM.HashMap BlockHash [PendingBlock]),
      -- |Priority queue of pairs of (block, parent) hashes where the block is (possibly) pending its parent, by block slot
      _possiblyPendingQueue :: !(MPQ.MinPQueue Slot (BlockHash, BlockHash)),
      -- |List of finalization records with the blocks that they finalize, starting from genesis
      _finalizationList :: !(Seq.Seq (FinalizationRecord, BasicBlockPointer pv bs)),
      -- |Branches of the tree by height above the last finalized block
      _branches :: !(Seq.Seq [BasicBlockPointer pv bs]),
      -- |Genesis data
      _genesisData :: !GenesisConfiguration,
      -- |Block pointer to genesis block
      _genesisBlockPointer :: !(BasicBlockPointer pv bs),
      -- |Current focus block
      _focusBlock :: !(BasicBlockPointer pv bs),
      -- |Pending transaction table
      _pendingTransactions :: !PendingTransactionTable,
      -- |Transaction table
      _transactionTable :: !TransactionTable,
      -- |Consensus statistics
      _statistics :: !ConsensusStatistics,
      -- |Runtime parameters
      _runtimeParameters :: !RuntimeParameters,
      -- |Transaction table purge counter
      _transactionTablePurgeCounter :: !Int,
      -- |State where we store the initial state for the new protocol update.
      -- TODO: This is not an ideal solution, but seems simplest in terms of abstractions.
      -- If we only had the one state implementation this would not be necessary, and we could simply
      -- return the value in the 'updateRegenesis' function. However as it is, it is challenging to properly
      -- specify the types of these values due to the way the relevant types are parameterized.
      _nextGenesisInitialState :: !(Maybe bs)
    }

makeLenses ''SkovData

instance IsProtocolVersion pv => Show (SkovData pv bs) where
    show SkovData{..} =
        "Finalized: "
            ++ intercalate "," (take 6 . show . bpHash . snd <$> toList _finalizationList)
            ++ "\n"
            ++ "Branches: "
            ++ intercalate "," (('[' :) . (++ "]") . intercalate "," . map (take 6 . show . bpHash) <$> toList _branches)

-- |Initial skov data with default runtime parameters (block size = 10MB).
initialSkovDataDefault :: (IsProtocolVersion pv, BS.BlockStateQuery m, bs ~ BlockState m) => GenesisConfiguration -> bs -> TransactionTable -> Maybe PendingTransactionTable -> m (SkovData pv bs)
initialSkovDataDefault = initialSkovData defaultRuntimeParameters

-- |Create initial skov data based on a genesis block, its state, and the initial transaction table.
initialSkovData ::
    (IsProtocolVersion pv, BS.BlockStateQuery m, bs ~ BlockState m) =>
    RuntimeParameters ->
    GenesisConfiguration ->
    bs ->
    -- |Initial transaction table. All transactions should either be finalized,
    -- or received, but not committed.
    TransactionTable ->
    -- |The initial pending transaction table. If the supplied __transaction
    -- table__ has transactions that are not finalized the pending table must be
    -- supplied to record these, satisfying the usual properties. See
    -- documentation of the 'PendingTransactionTable' for details.
    Maybe PendingTransactionTable ->
    m (SkovData pv bs)
initialSkovData rp gd genState genTT mPending =
    return $!
        SkovData
            { _blockTable = HM.singleton gbh (TS.BlockFinalized gb gbfin),
              _finalizedByHeightTable = HM.singleton 0 gb,
              _possiblyPendingTable = HM.empty,
              _possiblyPendingQueue = MPQ.empty,
              _finalizationList = Seq.singleton (gbfin, gb),
              _branches = Seq.empty,
              _genesisData = gd,
              _genesisBlockPointer = gb,
              _focusBlock = gb,
              _pendingTransactions = fromMaybe emptyPendingTransactionTable mPending,
              _transactionTable = genTT,
              _statistics = initialConsensusStatistics,
              _runtimeParameters = rp,
              _transactionTablePurgeCounter = 0,
              _nextGenesisInitialState = Nothing
            }
  where
    gbh = bpHash gb
    gbfin = FinalizationRecord 0 gbh emptyFinalizationProof 0
    gb = makeGenesisBasicBlockPointer gd genState

-- |Newtype wrapper that provides an implementation of the TreeStateMonad using a non-persistent tree state.
-- The underlying Monad must provide instances for:
--
-- * `BlockStateTypes`
-- * `BlockStateQuery`
-- * `BlockStateOperations`
-- * `BlockStateStorage`
-- * `MonadState (SkovData bs)`
--
-- This newtype establishes types for the @GlobalStateTypes@. The type variable @bs@ stands for the BlockState
-- type used in the implementation.
newtype PureTreeStateMonad bs m a = PureTreeStateMonad {runPureTreeStateMonad :: m a}
    deriving
        ( Functor,
          Applicative,
          Monad,
          MonadIO,
          BlockStateTypes,
          BS.AccountOperations,
          BS.ModuleQuery,
          BS.BlockStateQuery,
          BS.BlockStateOperations,
          BS.BlockStateStorage,
          BS.ContractStateOperations,
          TimeMonad
        )

deriving instance (MonadProtocolVersion m) => MonadProtocolVersion (PureTreeStateMonad bs m)

deriving instance (Monad m, MonadState (SkovData pv bs) m) => MonadState (SkovData pv bs) (PureTreeStateMonad bs m)

instance (IsProtocolVersion pv, pv ~ MPV m, bs ~ BlockState m) => GlobalStateTypes (PureTreeStateMonad bs m) where
    type BlockPointerType (PureTreeStateMonad bs m) = BasicBlockPointer (MPV m) bs

instance (bs ~ BlockState m, BlockStateTypes m, Monad m, MonadState (SkovData pv bs) m, IsProtocolVersion pv, pv ~ MPV m) => BlockPointerMonad (PureTreeStateMonad bs m) where
    blockState = return . _bpState
    bpParent = return . runIdentity . _bpParent
    bpLastFinalized = return . runIdentity . _bpLastFinalized

instance
    (bs ~ BlockState m, BS.BlockStateStorage m, Monad m, MonadIO m, MonadState (SkovData (MPV m) bs) m, MonadProtocolVersion m) =>
    TS.TreeStateMonad (PureTreeStateMonad bs m)
    where
    makePendingBlock key slot parent bid pf n lastFin trs statehash transactionOutcomesHash time = do
        return $ makePendingBlock (signBlock key slot parent bid pf n lastFin trs statehash transactionOutcomesHash) time
    getBlockStatus bh = use (blockTable . at' bh)
    getRecentBlockStatus bh = do
        st <- use (blockTable . at' bh)
        case st of
            Just bs@(TS.BlockFinalized bp _) -> do
                (lf, _) <- TS.getLastFinalized
                if bp == lf
                    then return (TS.RecentBlock bs)
                    else return TS.OldFinalized
            Just bs -> return (TS.RecentBlock bs)
            Nothing -> return TS.Unknown

    makeLiveBlock block parent lastFin st arrTime energy = do
        let blockP = makeBasicBlockPointer block parent lastFin st arrTime energy
        blockTable . at' (getHash block) ?= TS.BlockAlive blockP
        return blockP
    markDead bh = blockTable . at' bh ?= TS.BlockDead
    type MarkFin (PureTreeStateMonad bs m) = ()
    markFinalized bh fr =
        use (blockTable . at' bh) >>= \case
            Just (TS.BlockAlive bp) -> do
                blockTable . at' bh ?= TS.BlockFinalized bp fr
                finalizedByHeightTable . at (bpHeight bp) ?= bp
            _ -> return ()
    markPending pb = blockTable . at' (getHash pb) ?= TS.BlockPending pb
    getGenesisBlockPointer = use genesisBlockPointer
    getGenesisData = use genesisData
    getLastFinalized =
        use finalizationList >>= \case
            _ Seq.:|> (finRec, lf) -> return (lf, finRec)
            _ -> error "empty finalization list"
    getNextFinalizationIndex = FinalizationIndex . fromIntegral . Seq.length <$> use finalizationList
    addFinalization newFinBlock finRec = finalizationList %= (Seq.:|> (finRec, newFinBlock))
    getFinalizedAtIndex finIndex = fmap snd . Seq.lookup (fromIntegral finIndex) <$> use finalizationList
    getRecordAtIndex finIndex = fmap fst . Seq.lookup (fromIntegral finIndex) <$> use finalizationList
    getFinalizedAtHeight bHeight = preuse (finalizedByHeightTable . ix bHeight)
    wrapupFinalization _ _ = return ()
    getBranches = use branches
    putBranches brs = branches .= brs
    takePendingChildren bh = possiblyPendingTable . at' bh . non [] <<.= []
    addPendingBlock pb = do
        let parent = blockPointer (bbFields (pbBlock pb))
        possiblyPendingTable . at' parent . non [] %= (pb :)
        possiblyPendingQueue %= MPQ.insert (blockSlot (pbBlock pb)) (getHash pb, parent)
    takeNextPendingUntil slot = tnpu =<< use possiblyPendingQueue
      where
        tnpu ppq = case MPQ.minViewWithKey ppq of
            Just ((sl, (pbh, parenth)), ppq') ->
                if sl <= slot
                    then do
                        (myPB, otherPBs) <- partition ((== pbh) . pbHash) <$> use (possiblyPendingTable . at' parenth . non [])
                        case myPB of
                            [] -> tnpu ppq'
                            (realPB : _) -> do
                                possiblyPendingTable . at' parenth . non [] .= otherPBs
                                possiblyPendingQueue .= ppq'
                                return (Just realPB)
                    else do
                        possiblyPendingQueue .= ppq
                        return Nothing
            Nothing -> do
                possiblyPendingQueue .= ppq
                return Nothing

    getFocusBlock = use focusBlock
    putFocusBlock bb = focusBlock .= bb
    getPendingTransactions = use pendingTransactions
    putPendingTransactions pts = pendingTransactions .= pts
    getAccountNonFinalized addr nnce =
        use (transactionTable . ttNonFinalizedTransactions . at' addr) >>= \case
            Nothing -> return []
            Just anfts ->
                let (_, atnnce, beyond) = Map.splitLookup nnce (anfts ^. anftMap)
                in  return $ case atnnce of
                        Nothing -> Map.toAscList beyond
                        Just s -> (nnce, s) : Map.toAscList beyond

    getNextAccountNonce addr =
        use (transactionTable . ttNonFinalizedTransactions . at' addr) >>= \case
            Nothing -> return (minNonce, True)
            Just anfts ->
                case Map.lookupMax (anfts ^. anftMap) of
                    Nothing -> return (anfts ^. anftNextNonce, True) -- all transactions are finalized
                    Just (nonce, _) -> return (nonce + 1, False)

    getCredential txHash =
        preuse (transactionTable . ttHashMap . ix txHash) >>= \case
            Just (WithMetadata{wmdData = CredentialDeployment{..}, ..}, status) ->
                case status of
                    Received _ verRes -> return $ Just (WithMetadata{wmdData = biCred, ..}, verRes)
                    Committed _ verRes _ -> return $ Just (WithMetadata{wmdData = biCred, ..}, verRes)
                    _ -> return Nothing
            _ -> return Nothing

    getNonFinalizedChainUpdates uty sn =
        use (transactionTable . ttNonFinalizedChainUpdates . at' uty) >>= \case
            Nothing -> return []
            Just nfcus ->
                let (_, atsn, beyond) = Map.splitLookup sn (nfcus ^. nfcuMap)
                in  return $ case atsn of
                        Nothing -> Map.toAscList beyond
                        Just s -> (sn, s) : Map.toAscList beyond

    addCommitTransaction bi@WithMetadata{..} verResCtx ts slot = do
        tt <- use transactionTable
        case tt ^. ttHashMap . at' wmdHash of
            Nothing -> do
                -- If the transaction was not present in the `TransactionTable` then we verify it now
                -- and add it based on the verification result.
                -- Only transactions which can possibly be valid at the stage of execution are being added
                -- to the `TransactionTable`.
                -- Verifying the transaction here as opposed to `doReceiveTransactionInternal` avoids
                -- verifying a transaction that is both received individually and as part of a block twice.
                verRes <- TS.runTransactionVerifierT (TVer.verify ts bi) verResCtx
                if TVer.definitelyNotValid verRes (verResCtx ^. TS.isTransactionFromBlock)
                    then return $ TS.NotAdded verRes
                    else do
                        let (added, newTT) = addTransaction bi slot verRes tt
                        if added
                            then do
                                transactionTablePurgeCounter += 1
                                transactionTable .=! newTT
                                return (TS.Added bi verRes)
                            else return TS.ObsoleteNonce
            Just (_, Finalized{}) -> return TS.ObsoleteNonce
            Just (tr', results) -> do
                -- The `Finalized` case is not reachable as the cause would be that a finalized transaction
                -- is also part of a later block which would be rejected when executing the block.
                let mVerRes = case results of
                        Received _ verRes -> Just verRes
                        Committed _ verRes _ -> Just verRes
                when (slot > results ^. tsSlot) $ transactionTable . ttHashMap . at' wmdHash . mapped . _2 %= updateSlot slot
                return $ TS.Duplicate tr' mVerRes

    addVerifiedTransaction bi@WithMetadata{..} okRes = do
        let verRes = TVer.Ok okRes
        tt <- use transactionTable
        case tt ^. ttHashMap . at' wmdHash of
            Nothing
                | added -> do
                    transactionTablePurgeCounter += 1
                    transactionTable .=! newTT
                    return (TS.Added bi verRes)
                | otherwise -> return TS.ObsoleteNonce
              where
                (added, newTT) = addTransaction bi 0 verRes tt
            Just (_, Finalized{}) -> return TS.ObsoleteNonce
            Just (tr', results) -> do
                let mVerRes = case results of
                        Received _ verRes' -> Just verRes'
                        Committed _ verRes' _ -> Just verRes'
                return $ TS.Duplicate tr' mVerRes

    type FinTrans (PureTreeStateMonad bs m) = ()
    finalizeTransactions bh slot = mapM_ finTrans
      where
        finTrans WithMetadata{wmdData = NormalTransaction tr, ..} = do
            let nonce = transactionNonce tr
                sender = accountAddressEmbed (transactionSender tr)
            anft <- use (transactionTable . ttNonFinalizedTransactions . at' sender . non emptyANFT)
            assert (anft ^. anftNextNonce == nonce) $ do
                let nfn = anft ^. anftMap . at' nonce . non Map.empty
                let wmdtr = WithMetadata{wmdData = tr, ..}
                assert (Map.member wmdtr nfn) $ do
                    -- Remove any other transactions with this nonce from the transaction table.
                    -- They can never be part of any other block after this point.
                    forM_ (Map.keys (Map.delete wmdtr nfn)) $
                        \deadTransaction -> transactionTable . ttHashMap . at' (getHash deadTransaction) .= Nothing
                    -- Mark the status of the transaction as finalized.
                    -- Singular here is safe due to the precondition (and assertion) that all transactions
                    -- which are part of live blocks are in the transaction table.
                    transactionTable
                        . ttHashMap
                        . singular (ix wmdHash)
                        . _2
                        %= \case
                            Committed{..} -> Finalized{_tsSlot = slot, tsBlockHash = bh, tsFinResult = tsResults HM.! bh, ..}
                            _ -> error "Transaction should be in committed state when finalized."
                    -- Update the non-finalized transactions for the sender
                    transactionTable . ttNonFinalizedTransactions . at' sender ?= (anft & (anftMap . at' nonce .~ Nothing) & (anftNextNonce .~ nonce + 1))
        finTrans WithMetadata{wmdData = CredentialDeployment{}, ..} = do
            transactionTable
                . ttHashMap
                . singular (ix wmdHash)
                . _2
                %= \case
                    Committed{..} -> Finalized{_tsSlot = slot, tsBlockHash = bh, tsFinResult = tsResults HM.! bh, ..}
                    _ -> error "Transaction should be in committed state when finalized."
        finTrans WithMetadata{wmdData = ChainUpdate cu, ..} = do
            let sn = updateSeqNumber (uiHeader cu)
                uty = updateType (uiPayload cu)
            nfcu <- use (transactionTable . ttNonFinalizedChainUpdates . at' uty . non emptyNFCU)
            assert (nfcu ^. nfcuNextSequenceNumber == sn) $ do
                let nfsn = nfcu ^. nfcuMap . at' sn . non Map.empty
                let wmdcu = WithMetadata{wmdData = cu, ..}
                assert (Map.member wmdcu nfsn) $ do
                    -- Remove any other updates with the same sequence number, since they weren't finalized
                    forM_ (Map.keys (Map.delete wmdcu nfsn)) $
                        \deadUpdate -> transactionTable . ttHashMap . at' (getHash deadUpdate) .= Nothing
                    -- Mark this update as finalized.
                    transactionTable
                        . ttHashMap
                        . singular (ix wmdHash)
                        . _2
                        %= \case
                            Committed{..} -> Finalized{_tsSlot = slot, tsBlockHash = bh, tsFinResult = tsResults HM.! bh, ..}
                            _ -> error "Transaction should be in committed state when finalized."
                    -- Update the non-finalized chain updates
                    transactionTable
                        . ttNonFinalizedChainUpdates
                        . at' uty
                        ?= (nfcu & (nfcuMap . at' sn .~ Nothing) & (nfcuNextSequenceNumber .~ sn + 1))

    commitTransaction slot bh tr idx =
        transactionTable . ttHashMap . at' (getHash tr) %= fmap (_2 %~ addResult bh slot idx)

    purgeTransaction WithMetadata{..} =
        use (transactionTable . ttHashMap . at' wmdHash) >>= \case
            Nothing -> return True
            Just (_, results) -> do
                lastFinSlot <- blockSlot . _bpBlock . fst <$> TS.getLastFinalized
                if lastFinSlot >= results ^. tsSlot
                    then do
                        -- remove from the table
                        transactionTable . ttHashMap . at' wmdHash .= Nothing
                        -- if the transaction is from a sender also delete the relevant
                        -- entry in the account non finalized table
                        case wmdData of
                            NormalTransaction tr -> do
                                let nonce = transactionNonce tr
                                    sender = accountAddressEmbed (transactionSender tr)
                                transactionTable
                                    . ttNonFinalizedTransactions
                                    . at' sender
                                    . non emptyANFT
                                    . anftMap
                                    . at' nonce
                                    . non Map.empty
                                    %= Map.delete WithMetadata{wmdData = tr, ..}
                            _ -> return () -- do nothing.
                        return True
                    else return False

    markDeadTransaction bh tr =
        -- We only need to update the outcomes. The anf table nor the pending table need be updated
        -- here since a transaction should not be marked dead in a finalized block.
        transactionTable . ttHashMap . at' (getHash tr) . mapped . _2 %= markDeadResult bh
    lookupTransaction th =
        preuse (transactionTable . ttHashMap . ix th . _2)

    getConsensusStatistics = use statistics
    putConsensusStatistics stats = statistics .= stats

    {-# INLINE getRuntimeParameters #-}
    getRuntimeParameters = use runtimeParameters

    purgeTransactionTable ignoreInsertions currentTime = do
        purgeCount <- use transactionTablePurgeCounter
        RuntimeParameters{..} <- use runtimeParameters
        when (ignoreInsertions || purgeCount > rpInsertionsBeforeTransactionPurge) $ do
            transactionTablePurgeCounter .= 0
            lastFinalizedSlot <- TS.getLastFinalizedSlot
            transactionTable' <- use transactionTable
            pendingTransactions' <- use pendingTransactions
            let currentTransactionTime = utcTimeToTransactionTime currentTime
                oldestArrivalTime =
                    if currentTransactionTime > rpTransactionsKeepAliveTime
                        then currentTransactionTime - rpTransactionsKeepAliveTime
                        else 0
                currentTimestamp = utcTimeToTimestamp currentTime
                (newTT, newPT) = purgeTables lastFinalizedSlot oldestArrivalTime currentTimestamp transactionTable' pendingTransactions'
            transactionTable .= newTT
            pendingTransactions .= newPT

    clearOnProtocolUpdate = do
        -- clear pending blocks
        possiblyPendingTable .= HM.empty
        possiblyPendingQueue .= MPQ.empty
        -- clear non-finalized blocks.
        branches .=! Seq.empty
        let nonFinDead TS.BlockPending{} = TS.BlockDead
            nonFinDead TS.BlockAlive{} = TS.BlockDead
            nonFinDead o = o
        blockTable %=! fmap nonFinDead
        -- mark transactions that are not finalized as received since
        -- they are no longer committed to any blocks.
        transactionTable
            . ttHashMap
            %=! HM.map
                ( \(bi, s) -> case s of
                    Committed{..} -> (bi, Received{..})
                    _ -> (bi, s)
                )

    clearAfterProtocolUpdate = do
        oldTT <- use transactionTable
        -- since this is the basic state we have to maintain the old
        -- finalized transactions in memory
        let newTT =
                emptyTransactionTable
                    & ttHashMap
                        .~ HM.filter
                            ( \(_, s) -> case s of
                                Finalized{} -> True
                                _ -> False
                            )
                            (oldTT ^. ttHashMap)
        transactionTable .=! newTT
        pendingTransactions .=! emptyPendingTransactionTable
        nextGenesisInitialState .=! Nothing
        BS.collapseCaches

    getNonFinalizedTransactionVerificationResult bi = do
        table <- use transactionTable
        return $ getNonFinalizedVerificationResult bi table

    storeFinalState bs = nextGenesisInitialState ?= bs
