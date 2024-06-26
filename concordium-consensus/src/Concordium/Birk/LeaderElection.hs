module Concordium.Birk.LeaderElection where

import Data.ByteString
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as L
import Data.Ratio

import Concordium.Crypto.SHA256
import qualified Concordium.Crypto.VRF as VRF
import Concordium.Types

newtype BlockLuck = BlockLuck Double deriving (Eq, Ord)

-- | Luck of the genesis block
genesisLuck :: BlockLuck
genesisLuck = BlockLuck 1

-- | Zero luck
zeroLuck :: BlockLuck
zeroLuck = BlockLuck 0

electionProbability :: LotteryPower -> ElectionDifficulty -> Double
electionProbability alpha diff = 1 - (1 - getDoubleFromElectionDifficulty diff) ** (fromIntegral (numerator alpha) / fromIntegral (denominator alpha))

leaderElectionMessage :: LeadershipElectionNonce -> Slot -> ByteString
leaderElectionMessage nonce (Slot sl) =
    L.toStrict $
        toLazyByteString $
            stringUtf8 "LE"
                <> byteString (hashToByteString nonce)
                <> word64BE sl

leaderElection ::
    LeadershipElectionNonce ->
    ElectionDifficulty ->
    Slot ->
    BakerElectionPrivateKey ->
    LotteryPower ->
    IO (Maybe BlockProof)
leaderElection nonce diff slot key lotPow = do
    let msg = leaderElectionMessage nonce slot
    let proof = VRF.prove key msg
    let hsh = VRF.proofToHash proof
    return $
        if VRF.hashToDouble hsh < electionProbability lotPow diff
            then Just proof
            else Nothing

verifyProof ::
    LeadershipElectionNonce ->
    ElectionDifficulty ->
    Slot ->
    BakerElectionVerifyKey ->
    LotteryPower ->
    BlockProof ->
    Bool
verifyProof nonce diff slot verifKey lotPow proof =
    VRF.verify verifKey (leaderElectionMessage nonce slot) proof
        && VRF.hashToDouble (VRF.proofToHash proof)
            < electionProbability lotPow diff

electionLuck :: ElectionDifficulty -> LotteryPower -> BlockProof -> BlockLuck
electionLuck diff lotPow proof =
    BlockLuck $ 1 - VRF.hashToDouble (VRF.proofToHash proof) / electionProbability lotPow diff

blockNonceMessage :: LeadershipElectionNonce -> Slot -> ByteString
blockNonceMessage nonce (Slot slot) =
    L.toStrict $
        toLazyByteString $
            stringUtf8 "NONCE"
                <> byteString (hashToByteString nonce)
                <> word64BE slot

computeBlockNonce ::
    LeadershipElectionNonce -> Slot -> BakerElectionPrivateKey -> BlockNonce
computeBlockNonce nonce slot key = VRF.prove key (blockNonceMessage nonce slot)

verifyBlockNonce ::
    LeadershipElectionNonce ->
    Slot ->
    BakerElectionVerifyKey ->
    BlockNonce ->
    Bool
verifyBlockNonce nonce slot verifKey prf =
    VRF.verify verifKey (blockNonceMessage nonce slot) prf
