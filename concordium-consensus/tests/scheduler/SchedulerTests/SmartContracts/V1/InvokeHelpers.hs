{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A helper module that defines some scaffolding for running V1 contract tests via invoke.
module SchedulerTests.SmartContracts.V1.InvokeHelpers where

import Test.HUnit (assertFailure)

import Control.Monad.Reader
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as OrdMap
import qualified Data.Set as Set

import qualified Concordium.Crypto.SHA256 as Hash
import qualified Concordium.Scheduler.Types as Types

import Concordium.GlobalState.BlockState
import Concordium.GlobalState.Persistent.BlobStore
import Concordium.GlobalState.Persistent.BlockState
import Concordium.GlobalState.Persistent.BlockState.Modules (PersistentInstrumentedModuleV)
import qualified Concordium.GlobalState.Wasm as GSWasm
import qualified Concordium.Scheduler.WasmIntegration as WasmV0
import qualified Concordium.Scheduler.WasmIntegration.V1 as WasmV1
import Concordium.Types.SeedState (initialSeedState)
import Concordium.Wasm

import Concordium.Crypto.DummyData
import Concordium.GlobalState.DummyData
import Concordium.Types.DummyData

import SchedulerTests.TestUtils

type ContextM = PersistentBlockStateMonad PV4 (PersistentBlockStateContext PV4) (BlobStoreM' (PersistentBlockStateContext PV4))

type PersistentModuleInterfaceV v = GSWasm.ModuleInterfaceA (PersistentInstrumentedModuleV v)

-- empty state, no accounts, no modules, no instances
initialBlockState :: ContextM (HashedPersistentBlockState PV4)
initialBlockState =
    initialPersistentState
        (initialSeedState (Hash.hash "") 1000)
        dummyCryptographicParameters
        [mkAccount alesVK alesAccount 1000]
        dummyIdentityProviders
        dummyArs
        dummyKeyCollection
        dummyChainParameters

callerSourceFile :: FilePath
callerSourceFile = "./testdata/contracts/v1/caller.wasm"

emptyContractSourceFile :: FilePath
emptyContractSourceFile = "./testdata/contracts/empty.wasm"

-- |Deploy a V1 module in the given state. The source file should be a raw Wasm file.
-- If the module is invalid this will raise an exception.
deployModuleV1 ::
    -- |Source file.
    FilePath ->
    -- |State to add the module to.
    PersistentBlockState PV4 ->
    ContextM ((PersistentModuleInterfaceV V1, WasmModuleV V1), PersistentBlockState PV4)
deployModuleV1 sourceFile bs = do
    ws <- liftIO $ BS.readFile sourceFile
    let wm = WasmModuleV (ModuleSource ws)
    case WasmV1.processModule True wm of
        Nothing -> liftIO $ assertFailure "Invalid module."
        Just miv -> do
            (_, modState) <- bsoPutNewModule bs (miv, wm)
            bsoGetModule modState (GSWasm.miModuleRef miv) >>= \case
                Just (GSWasm.ModuleInterfaceV1 miv') -> return ((miv', wm), modState)
                _ -> liftIO $ assertFailure "bsoGetModule failed to return put module."

-- |Deploy a V0 module in the given state. The source file should be a raw Wasm file.
-- If the module is invalid this will raise an exception.
deployModuleV0 ::
    -- |Source file.
    FilePath ->
    -- |State to add the module to.
    PersistentBlockState PV4 ->
    ContextM ((PersistentModuleInterfaceV V0, WasmModuleV V0), PersistentBlockState PV4)
deployModuleV0 sourceFile bs = do
    ws <- liftIO $ BS.readFile sourceFile
    let wm = WasmModuleV (ModuleSource ws)
    case WasmV0.processModule wm of
        Nothing -> liftIO $ assertFailure "Invalid module."
        Just miv -> do
            (_, modState) <- bsoPutNewModule bs (miv, wm)
            bsoGetModule modState (GSWasm.miModuleRef miv) >>= \case
                Just (GSWasm.ModuleInterfaceV0 miv') -> return ((miv', wm), modState)
                _ -> liftIO $ assertFailure "bsoGetModule failed to return put module."

-- |Initialize a contract from the supplied module in the given state, and return its address.
-- The state is assumed to contain the module.
initContractV1 ::
    -- |Sender address
    Types.AccountAddress ->
    -- |Contract to initialize.
    InitName ->
    -- |Parameter to initialize with.
    Parameter ->
    -- |Initial balance.
    Types.Amount ->
    PersistentBlockState PV4 ->
    (PersistentModuleInterfaceV GSWasm.V1, WasmModuleV GSWasm.V1) ->
    ContextM (Types.ContractAddress, PersistentBlockState PV4)
initContractV1 senderAddress initName initParam initAmount bs (miv, _) = do
    let cm = Types.ChainMetadata 0
    let initContext =
            InitContext
                { initOrigin = senderAddress,
                  icSenderPolicies = []
                }
    let initInterpreterEnergy = 1_000_000_000
    (cbk, _) <- getCallbacks
    artifact <- getModuleArtifact (GSWasm.miModule miv)
    case WasmV1.applyInitFun cbk artifact cm initContext initName initParam False initAmount initInterpreterEnergy of
        Nothing ->
            -- out of energy
            liftIO $ assertFailure "Initialization ran out of energy."
        Just (Left failure, _) ->
            liftIO $ assertFailure $ "Initialization failed: " ++ show failure
        Just (Right WasmV1.InitSuccess{..}, _) -> do
            let receiveMethods = OrdMap.findWithDefault Set.empty initName (GSWasm.miExposedReceive miv)
            let ins =
                    NewInstanceData
                        { nidInitName = initName,
                          nidEntrypoints = receiveMethods,
                          nidInterface = miv,
                          nidInitialState = irdNewState,
                          nidInitialAmount = initAmount,
                          nidOwner = senderAddress
                        }
            bsoPutNewInstance bs ins

-- |Initialize a contract from the supplied module in the given state, and return its address.
-- The state is assumed to contain the module.
initContractV0 ::
    -- |Sender address
    Types.AccountAddress ->
    -- |Contract to initialize.
    InitName ->
    -- |Parameter to initialize with.
    Parameter ->
    -- |Initial balance.
    Types.Amount ->
    PersistentBlockState PV4 ->
    (PersistentModuleInterfaceV GSWasm.V0, WasmModuleV GSWasm.V0) ->
    ContextM (Types.ContractAddress, PersistentBlockState PV4)
initContractV0 senderAddress initName initParam initAmount bs (miv, _) = do
    let cm = Types.ChainMetadata 0
    let initContext =
            InitContext
                { initOrigin = senderAddress,
                  icSenderPolicies = []
                }
    let initInterpreterEnergy = 1_000_000_000
    artifact <- getModuleArtifact (GSWasm.miModule miv)
    case WasmV0.applyInitFun artifact cm initContext initName initParam False initAmount initInterpreterEnergy of
        Nothing ->
            -- out of energy
            liftIO $ assertFailure "Initialization ran out of energy."
        Just (Left failure, _) ->
            liftIO $ assertFailure $ "Initialization failed: " ++ show failure
        Just (Right SuccessfulResultData{..}, _) -> do
            let receiveMethods = OrdMap.findWithDefault Set.empty initName (GSWasm.miExposedReceive miv)
            let ins =
                    NewInstanceData
                        { nidInitName = initName,
                          nidEntrypoints = receiveMethods,
                          nidInterface = miv,
                          nidInitialState = newState,
                          nidInitialAmount = initAmount,
                          nidOwner = senderAddress
                        }
            bsoPutNewInstance bs ins
