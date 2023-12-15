{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | A common module for various helper definitions used for testing purposes.
module ConcordiumTests.KonsensusV1.Common where

import qualified Data.Vector as Vec
import System.Random

import qualified Concordium.Crypto.BlockSignature as Sig
import qualified Concordium.Crypto.DummyData as Dummy
import qualified Concordium.Crypto.SHA256 as Hash
import Concordium.KonsensusV1.TreeState.Types
import Concordium.KonsensusV1.Types
import Concordium.Types
import qualified Concordium.Types.Conditionally as Cond
import Concordium.Types.Option
import Concordium.Types.Parameters
import Concordium.Types.Transactions
import ConcordiumTests.KonsensusV1.TreeStateTest hiding (tests)
import Test.Hspec (Spec)

-- | Just an arbitrary chosen block hash used for testing.
myBlockHash :: BlockHash
myBlockHash = BlockHash $ Hash.hash "my block hash"

-- | A 'BlockPointer' which refers to a block with no meaningful state.
someBlockPointer :: SProtocolVersion pv -> BlockHash -> Round -> Epoch -> BlockPointer pv
someBlockPointer sProtocolVersion bh r e =
    BlockPointer
        { bpInfo =
            BlockMetadata
                { bmHeight = 0,
                  bmReceiveTime = timestampToUTCTime 0,
                  bmArriveTime = timestampToUTCTime 0,
                  bmEnergyCost = 0,
                  bmTransactionsSize = 0,
                  bmBlockStateHash = case sBlockHashVersionFor sProtocolVersion of
                    SBlockHashVersion0 -> Cond.CFalse
                    SBlockHashVersion1 -> Cond.CTrue stateHash
                },
          bpBlock = NormalBlock $ SignedBlock bakedBlock bh (Sig.sign sigKeyPair "foo"),
          bpState = dummyBlockState
        }
  where
    stateHash = StateHashV0 $ Hash.hash "empty state hash"
    -- A dummy block pointer with no meaningful state.
    bakedBlock =
        BakedBlock
            { bbRound = r,
              bbEpoch = e,
              bbTimestamp = 0,
              bbBaker = 0,
              bbQuorumCertificate = dummyQuorumCertificate $ BlockHash minBound,
              bbTimeoutCertificate = Absent,
              bbEpochFinalizationEntry = Absent,
              bbNonce = dummyBlockNonce,
              bbTransactions = Vec.empty,
              bbDerivableHashes = case sBlockHashVersionFor sProtocolVersion of
                SBlockHashVersion0 ->
                    DBHashesV0 $
                        BlockDerivableHashesV0
                            { bdhv0TransactionOutcomesHash = emptyTransactionOutcomesHashV1,
                              bdhv0BlockStateHash = stateHash
                            }
                SBlockHashVersion1 ->
                    DBHashesV1 $
                        BlockDerivableHashesV1
                            { bdhv1BlockResultHash = BlockResultHash $ Hash.hash "empty state hash"
                            }
            }

-- | A block pointer with 'myBlockHash' as block hash.
myBlockPointer :: SProtocolVersion pv -> Round -> Epoch -> BlockPointer pv
myBlockPointer sProtocolVersion = someBlockPointer sProtocolVersion myBlockHash

-- | A key pair created from the provided seeed.
sigKeyPair' :: Int -> Sig.KeyPair
sigKeyPair' seed = fst $ Dummy.randomBlockKeyPair $ mkStdGen seed

-- | The public key of the 'sigKeyPair''.
sigPublicKey' :: Int -> Sig.VerifyKey
sigPublicKey' seed = Sig.verifyKey $ sigKeyPair' seed

-- | An arbitrary chosen key pair
sigKeyPair :: Sig.KeyPair
sigKeyPair = fst $ Dummy.randomBlockKeyPair $ mkStdGen 42

-- | The public key of the 'sigKeyPair'.
sigPublicKey :: Sig.VerifyKey
sigPublicKey = Sig.verifyKey sigKeyPair

-- | Call a function for each protocol version starting from P6 where the new conensus was
-- introduced, returning a list of results. Notice the return type for the function must be
-- independent of the protocol version.
--
--  This is used to run a test against every protocol version.
forEveryProtocolVersion ::
    (forall pv. (IsProtocolVersion pv) => SProtocolVersion pv -> String -> Spec) ->
    Spec
forEveryProtocolVersion check =
    sequence_
        [ check SP1 "P1",
          check SP2 "P2",
          check SP3 "P3",
          check SP4 "P4",
          check SP5 "P5",
          check SP6 "P6",
          check SP7 "P7"
        ]

forEveryProtocolVersionConsensusV1 :: (forall pv. (IsProtocolVersion pv, IsConsensusV1 pv) => SProtocolVersion pv -> String -> Spec) -> Spec
forEveryProtocolVersionConsensusV1 check =
    forEveryProtocolVersion $ \spv pvString -> case consensusVersionFor spv of
        ConsensusV0 -> return ()
        ConsensusV1 -> check spv pvString
