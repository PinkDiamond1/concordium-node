{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | This module tests calling a V0 contract from a V1 contract and sending a message from a V0 to V1 contract.
module SchedulerTests.SmartContracts.V1.CrossMessaging (tests) where

import Test.HUnit (assertEqual, assertFailure)
import Test.Hspec

import qualified Data.ByteString as BS
import qualified Data.ByteString.Short as BSS
import Data.Serialize (putByteString, putWord16le, putWord64le, runPut)
import Lens.Micro.Platform

import Concordium.Scheduler.Runner
import qualified Concordium.Scheduler.Types as Types
import qualified Concordium.TransactionVerification as TVer

import Concordium.GlobalState.Basic.BlockState
import Concordium.GlobalState.Basic.BlockState.Accounts as Acc
import Concordium.GlobalState.Basic.BlockState.Instances
import qualified Concordium.GlobalState.ContractStateV1 as StateV1
import Concordium.GlobalState.Instance
import Concordium.Wasm

import Concordium.Crypto.DummyData
import Concordium.GlobalState.DummyData
import Concordium.Scheduler.DummyData
import Concordium.Types.DummyData

import SchedulerTests.TestUtils

initialBlockState :: BlockState PV4
initialBlockState =
    blockStateWithAlesAccount
        100000000
        (Acc.putAccountWithRegIds (mkAccount thomasVK thomasAccount 100000000) Acc.emptyAccounts)

counterSourceFile :: FilePath
counterSourceFile = "./testdata/contracts/v1/call-counter.wasm"

version1 :: WasmVersion
version1 = V1

proxySourceFile :: FilePath
proxySourceFile = "./testdata/contracts/v1/send-message-v1.wasm"

version0 :: WasmVersion
version0 = V0

-- This test sets up two contracts. The counter contract on address 0,0 and the
-- proxy contract on address 1,0. Then it invokes a single method on the counter
-- contract. That method calls the forward method on the proxy contract which
-- forwards the call to the inc method of the counter contract, which finally
-- increments the counter.
testCases :: [TestCase PV4]
testCases =
    [ TestCase
        { tcName = "CrossMessaging via a proxy",
          tcParameters = (defaultParams @PV4){tpInitialBlockState = initialBlockState},
          tcTransactions =
            [   ( TJSON
                    { payload = DeployModule version1 counterSourceFile,
                      metadata = makeDummyHeader alesAccount 1 100000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (SuccessWithSummary ensureSuccess, emptySpec)
                ),
                ( TJSON
                    { payload = DeployModule version0 proxySourceFile,
                      metadata = makeDummyHeader alesAccount 2 100000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (SuccessWithSummary ensureSuccess, emptySpec)
                ),
                ( TJSON
                    { payload = InitContract 0 version1 counterSourceFile "init_counter" "",
                      metadata = makeDummyHeader alesAccount 3 100000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (SuccessWithSummary ensureSuccess, counterSpec 0)
                ),
                ( TJSON
                    { payload = InitContract 0 version0 proxySourceFile "init_proxy" "",
                      metadata = makeDummyHeader alesAccount 4 100000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (SuccessWithSummary ensureSuccess, emptySpec)
                ),
              -- run the nocheck entrypoint since the @inc10@ one checks the return value, and since
              -- we are invoking a V0 contract there is no return value.
                ( TJSON
                    { payload = Update 0 (Types.ContractAddress 0 0) "counter.inc10nocheck" callArgs,
                      metadata = makeDummyHeader alesAccount 5 700000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (SuccessWithSummary ensureSuccess, counterSpec 10)
                )
            ]
        }
    ]
  where
    forwardParameter = runPut $ do
        putWord64le 0 -- index of the counter
        putWord64le 0 -- subindex of the counter contract
        putWord16le (fromIntegral (BSS.length "counter.inc"))
        putByteString "counter.inc" -- receive name, actions for V0 contracts must still use the full name
        putWord16le 0 -- length of parameter
    callArgs = BSS.toShort $ runPut $ do
        putWord64le 1 -- contract index (the proxy contract)
        putWord64le 0 -- contract subindex
        putWord16le (fromIntegral (BS.length forwardParameter)) -- length of parameter
        putByteString forwardParameter
        putWord16le (fromIntegral (BSS.length "forward"))
        putByteString "forward" -- entrypoint name, calls for V1 contracts use just the entrypoint name
        putWord64le 0 -- amount

    -- ensure the transaction is successful
    ensureSuccess :: TVer.BlockItemWithStatus -> Types.TransactionSummary -> Expectation
    ensureSuccess _ Types.TransactionSummary{..} = checkSuccess "Update failed" tsResult

    checkSuccess msg Types.TxReject{..} = assertFailure $ msg ++ show vrRejectReason
    checkSuccess _ _ = return ()

    -- Check that the contract state contains n.
    counterSpec n bs = specify "Contract state" $
        case getInstance (Types.ContractAddress 0 0) (bs ^. blockInstances) of
            Nothing -> assertFailure "Instance at <0,0> does not exist."
            Just istance -> do
                case istance of
                    InstanceV0 _ -> assertFailure "Expected V1 instance since a V1 module is deployed, but V0 encountered."
                    InstanceV1 InstanceV{_instanceVModel = InstanceStateV1 s} -> do
                        -- the contract stores the state at key = [0u8; 8]
                        StateV1.lookupKey s (runPut (putWord64le 0)) >>= \case
                            Nothing -> assertFailure "Failed to find key [0,0,0,0,0,0,0,0]"
                            Just stateContents -> assertEqual ("State contains " ++ show n ++ ".") (runPut (putWord64le n)) stateContents

tests :: Spec
tests =
    describe "V1: Counter with cross-messaging." $
        mkSpecs testCases
