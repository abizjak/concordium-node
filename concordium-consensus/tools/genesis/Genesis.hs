{-# OPTIONS_GHC -fno-cse #-}
{-# LANGUAGE
    DeriveDataTypeable,
    OverloadedStrings #-}
module Main where

import System.Exit
import System.Console.CmdArgs
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as OrdMap
import Data.Aeson
import qualified Data.Serialize as S
import Control.Monad
import Text.Printf
import Data.Time.Format
import Lens.Micro.Platform

import Data.Text
import qualified Data.HashMap.Strict as Map
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Bakers
import qualified Concordium.GlobalState.SeedState as SS
import Concordium.ID.Types
import Concordium.Types

data Genesis
    = GenerateGenesisData {gdSource :: FilePath,
                           gdOutput :: FilePath,
                           gdIdentity :: Maybe FilePath,
                           gdCryptoParams :: Maybe FilePath,
                           gdAdditionalAccounts :: Maybe FilePath,
                           gdControlAccounts :: Maybe FilePath,
                           gdBakers :: Maybe FilePath}
      | PrintGenesisData { gdSource :: FilePath }
    deriving (Typeable, Data)


generateGenesisData :: Genesis
generateGenesisData = GenerateGenesisData {
    gdSource = def &= typ "INFILE" &= argPos 0,
    gdOutput = def &= typ "OUTFILE" &= argPos 1,
    gdIdentity = def &=
                 explicit &=
                 name "identity-providers" &=
                 opt (Nothing :: Maybe FilePath) &=
                 typFile &=
                 help "JSON file with identity providers.",
    gdCryptoParams = def &=
                     explicit &=
                     name "crypto-params" &=
                     opt (Nothing :: Maybe FilePath) &=
                     typFile &=
                     help "JSON file with cryptographic parameters for the chain.",
    gdAdditionalAccounts = def &=
                           explicit &=
                           name "additional-accounts" &=
                           opt (Nothing :: Maybe FilePath) &=
                           typFile &=
                           help "JSON file with additional accounts (not baker, not control)",
    gdControlAccounts = def &=
                        explicit &=
                        name "control-accounts" &=
                        opt (Nothing :: Maybe FilePath) &=
                        typFile &=
                        help "JSON file with special control accounts.",
    gdBakers = def &=
               explicit &=
               name "bakers" &=
               opt (Nothing :: Maybe FilePath) &=
               typFile &=
               help "JSON file with baker information."
 } &= help "Parse JSON genesis parameters from INFILE and write serialized genesis data to OUTFILE"
  &= explicit &= name "make-genesis"

printGenesisBlock :: Genesis
printGenesisBlock = PrintGenesisData {
    gdSource = def &= typ "INFILE" &= argPos 0
 } &= help "Parse genesis data from INFILE and print it to stdout."
  &= explicit &= name "print-genesis"

mode :: Mode (CmdArgs Genesis)
mode = cmdArgsMode $ modes [generateGenesisData, printGenesisBlock]
    &= summary "Concordium genesis v1"
    &= help "Generate genesis data or display the genesis block."

modifyValueWith :: Text -> Value -> Value -> Maybe Value
modifyValueWith key val (Object obj) = Just (Object (Map.insert key val obj))
modifyValueWith _ _ _ = Nothing

maybeModifyValue :: Maybe FilePath -> Text -> Value -> IO Value
maybeModifyValue Nothing _ obj = return obj
maybeModifyValue (Just source) key obj = do
  inBS <- LBS.readFile source
  case eitherDecode inBS of
    Left e -> do
      putStrLn e
      exitFailure
    Right v' ->
      case modifyValueWith key v' obj of
        Nothing -> do
          putStrLn "Base value not an object."
          exitFailure
        Just v -> return v

main :: IO ()
main = cmdArgsRun mode >>=
    \case
        GenerateGenesisData{..} -> do
            inBS <- LBS.readFile gdSource
            case eitherDecode inBS of
                Left e -> do
                    putStrLn e
                    exitFailure
                Right v -> do
                  vId <- maybeModifyValue gdIdentity "identityProviders" v
                  vCP <- maybeModifyValue gdCryptoParams "cryptographicParameters" vId
                  vAdditionalAccs <- maybeModifyValue gdAdditionalAccounts "initialAccounts" vCP
                  vAcc <- maybeModifyValue gdControlAccounts "controlAccounts" vAdditionalAccs
                  value <- maybeModifyValue gdBakers "bakers" vAcc
                  case fromJSON value of
                    Error err -> do
                      putStrLn err
                      exitFailure
                    Success params -> do
                      let genesisData = parametersToGenesisData params
                      let totalGTU = genesisTotalGTU genesisData
                      putStrLn "Successfully generated genesis data."
                      putStrLn $ "Genesis time is set to: " ++ showTime (genesisTime genesisData)
                      putStrLn $ "There are the following " ++ show (Prelude.length (genesisAccounts genesisData)) ++ " initial accounts in genesis:"
                      forM_ (genesisAccounts genesisData) $ \account ->
                        putStrLn $ "\tAccount: " ++ show (_accountAddress account) ++ ", balance = " ++ showBalance totalGTU (_accountAmount account)

                      putStrLn $ "\nIn addition there are the following " ++ show (Prelude.length (genesisControlAccounts genesisData)) ++ " control accounts:"
                      forM_ (genesisControlAccounts genesisData) $ \account ->
                        putStrLn $ "\tAccount: " ++ show (_accountAddress account) ++ ", balance = " ++ showBalance totalGTU (_accountAmount account)

                      LBS.writeFile gdOutput (S.encodeLazy $ genesisData)
                      putStrLn $ "Wrote genesis data to file " ++ show gdOutput
                      exitSuccess
        PrintGenesisData{..} -> do
          source <- LBS.readFile gdSource
          case S.decodeLazy source of
            Left err -> putStrLn $ "Cannot parse genesis data:" ++ err
            Right genData@GenesisData{..} -> do
              putStrLn "Genesis data."
              putStrLn $ "Genesis time is set to: " ++ showTime genesisTime
              putStrLn $ "Slot duration: " ++ show (durationToNominalDiffTime genesisSlotDuration)
              putStrLn $ "Genesis nonce: " ++ show (SS.currentSeed genesisSeedState)
              putStrLn $ "Epoch length in slots: " ++ show (SS.epochLength genesisSeedState)
              putStrLn $ "Election difficulty: " ++ show genesisElectionDifficulty

              let totalGTU = genesisTotalGTU genData

              putStrLn ""
              putStrLn $ "Mint per slot amount: " ++ show genesisMintPerSlot
              putStrLn $ "Genesis total GTU: " ++ show totalGTU
              putStrLn $ "Maximum block energy: " ++ show genesisMaxBlockEnergy

              putStrLn ""
              putStrLn "Finalization parameters: "
              let FinalizationParameters{..} = genesisFinalizationParameters
              putStrLn $ "  - minimum skip: " ++ show finalizationMinimumSkip
              putStrLn $ "  - committee max size: " ++ show finalizationCommitteeMaxSize
              putStrLn $ "  - waiting time: " ++ show (durationToNominalDiffTime finalizationWaitingTime)
              putStrLn $ "  - ignore first wait: " ++ show finalizationIgnoreFirstWait
              putStrLn $ "  - old style skip: " ++ show finalizationOldStyleSkip
              putStrLn $ "  - skip shrink factor: " ++ show finalizationSkipShrinkFactor
              putStrLn $ "  - skip grow factor: " ++ show finalizationSkipGrowFactor
              putStrLn $ "  - delay shrink factor: " ++ show finalizationDelayShrinkFactor
              putStrLn $ "  - delay grow factor: " ++ show finalizationDelayGrowFactor
              putStrLn $ "  - allow zero delay: " ++ show finalizationAllowZeroDelay

              putStrLn ""
              putStrLn $ "Cryptographic parameters: " ++ show genesisCryptographicParameters

              putStrLn $ "Genesis bakers:"
              putStrLn $ "  - bakers total stake: " ++ show (genesisBakers ^. bakerTotalStake)
              forM_ (OrdMap.toAscList (genesisBakers ^. bakerMap)) $ \(bid, BakerInfo{..}) -> do
                putStrLn $ "  - baker: " ++ show bid
                putStrLn $ "    * stake: " ++ showBalance (genesisBakers ^. bakerTotalStake) _bakerStake
                putStrLn $ "    * account: " ++ show _bakerAccount
                putStrLn $ "    * election key: " ++ show _bakerElectionVerifyKey
                putStrLn $ "    * signature key: " ++ show _bakerSignatureVerifyKey
                putStrLn $ "    * aggregation key: " ++ show _bakerAggregationVerifyKey

              putStrLn ""
              putStrLn "Genesis normal accounts:"
              forM_ genesisAccounts (showAccount totalGTU)

              putStrLn ""
              putStrLn "Genesis control accounts:"
              forM_ genesisControlAccounts (showAccount totalGTU)

  where showTime t = formatTime defaultTimeLocale rfc822DateFormat (timestampToUTCTime t)
        showBalance totalGTU balance =
            printf "%d (= %.4f%%)" (toInteger balance) (100 * (fromIntegral balance / fromIntegral totalGTU) :: Double)
        showAccount totalGTU Account{..} = do
          putStrLn $ "  - " ++ show _accountAddress
          putStrLn $ "     * balance: " ++ showBalance totalGTU _accountAmount
          putStrLn $ "     * threshold: " ++ show (akThreshold _accountVerificationKeys)
          putStrLn $ "     * keys: "
          forM (OrdMap.toList (akKeys _accountVerificationKeys)) $ \(idx, k) ->
            putStrLn $ "       - " ++ show idx ++ ": " ++ show k
