{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- Testing the SimpleTransfer transaction.
NOTE: See also 'SchedulerTests.SimpleTransfersTest'.
-}
module SchedulerTests.SimpleTransferSpec where

import Test.Hspec

import Concordium.Scheduler.Runner
import qualified Concordium.Scheduler.Types as Types

import Concordium.GlobalState.Basic.BlockState
import Concordium.GlobalState.Basic.BlockState.Accounts as Acc
import Concordium.Wasm

import Concordium.Crypto.DummyData
import Concordium.GlobalState.DummyData
import Concordium.Scheduler.DummyData
import Concordium.Types.DummyData

import SchedulerTests.TestUtils

initialBlockState :: BlockState PV1
initialBlockState =
    blockStateWithAlesAccount
        10000000000
        (Acc.putAccountWithRegIds (mkAccount thomasVK thomasAccount 10000000000) Acc.emptyAccounts)

testCases :: [TestCase PV1]
testCases =
    [ -- NOTE: Could also check resulting balances on each affected account or contract, but
      -- the block state invariant at least tests that the total amount is preserved.
      TestCase
        { tcName = "Transfers from a contract to accounts.",
          tcParameters = (defaultParams @PV1){tpInitialBlockState = initialBlockState},
          tcTransactions =
            [   ( TJSON
                    { payload = DeployModule V0 "./testdata/contracts/send-tokens-test.wasm",
                      metadata = makeDummyHeader alesAccount 1 100000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (Success emptyExpect, emptySpec)
                ),
                ( TJSON
                    { payload = InitContract 0 V0 "./testdata/contracts/send-tokens-test.wasm" "init_send" "",
                      metadata = makeDummyHeader alesAccount 2 100000,
                      keys = [(0, [(0, alesKP)])]
                    },
                  (Success emptyExpect, emptySpec)
                ),
                ( TJSON
                    { payload = Update 11 (Types.ContractAddress 0 0) "send.receive" "",
                      metadata = makeDummyHeader alesAccount 3 70000,
                      keys = [(0, [(0, alesKP)])]
                    },
                    ( SuccessE
                        [ Types.Updated
                            { euAddress = Types.ContractAddress 0 0,
                              euInstigator = Types.AddressAccount alesAccount,
                              euAmount = 11,
                              euMessage = Parameter "",
                              euReceiveName = ReceiveName "send.receive",
                              euContractVersion = V0,
                              euEvents = []
                            },
                          Types.Transferred
                            { etFrom = Types.AddressContract (Types.ContractAddress 0 0),
                              etAmount = 11,
                              etTo = Types.AddressAccount alesAccount
                            }
                        ],
                      emptySpec
                    )
                )
            ]
        }
    ]

tests :: Spec
tests =
    describe "SimpleTransfer from contract to account." $
        mkSpecs testCases
