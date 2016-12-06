{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Main where

import           Universum
#ifdef WITH_WALLET
import           Control.Monad.Reader   (MonadReader (..), ReaderT, asks, runReaderT)
import           Control.TimeWarp.Rpc   (NetworkAddress)
import           Control.TimeWarp.Timed (for, wait)
import           Data.List              ((!!))
import           Formatting             (build, int, sformat, (%))
import           Options.Applicative    (execParser)
import           System.IO              (hFlush, stdout)
import           Test.QuickCheck        (arbitrary, generate)

import           Pos.Constants          (slotDuration)
import           Pos.Crypto             (KeyPair (..), SecretKey, toPublic)
import           Pos.DHT                (DHTNodeType (..), dhtAddr, discoverPeers)
import           Pos.Genesis            (genesisSecretKeys, genesisUtxo)
import           Pos.Launcher           (BaseParams (..), LoggingParams (..),
                                         NodeParams (..), bracketDHTInstance,
                                         runNodeProduction, runTimeSlaveReal, stakesDistr)
import           Pos.Ssc.GodTossing     (GtParams (..), SscGodTossing)
import           Pos.Ssc.NistBeacon     (SscNistBeacon)
import           Pos.Ssc.SscAlgo        (SscAlgo (..))
import           Pos.Types              (makePubKeyAddress, txwF)
import           Pos.Wallet             (getBalance, submitTx)
import           Pos.WorkMode           (WorkMode)
#ifdef WITH_WEB
import           Pos.Wallet.Web         (walletServeWeb)
#endif

import           Command                (Command (..), parseCommand)
import           WalletOptions          (WalletAction (..), WalletOptions (..), optsInfo)

type CmdRunner = ReaderT (SecretKey, [NetworkAddress])

evalCmd :: WorkMode ssc m => Command -> CmdRunner m ()
evalCmd (Balance addr) = lift (getBalance addr) >>=
                         putText . sformat ("Current balance: "%int) >>
                         evalCommands
evalCmd (Send outputs) = do
    (sk, na) <- ask
    tx <- lift (submitTx sk na outputs)
    putText $ sformat ("Submitted transaction: "%txwF) tx
    evalCommands
evalCmd Help = do
    putText $
        unlines
            [ "Avaliable commands:"
            , "   balance <address>          -- check balance on given address"
            , "   send [<address> <coins>]+  -- create and send transaction with given outputs"
            , "                                 from current wallet address"
            , "   myaddress                  -- get current wallet address"
            , "   help                       -- show this message"
            , "   quit                       -- shutdown node wallet"
            ]
    evalCommands
evalCmd MyAddress = asks fst >>=
                    putText . sformat build . makePubKeyAddress . toPublic >>
                    evalCommands
evalCmd Quit = pure ()

evalCommands :: WorkMode ssc m => CmdRunner m ()
evalCommands = do
    putStr @Text "> "
    liftIO $ hFlush stdout
    line <- getLine
    let cmd = parseCommand line
    case cmd of
        Left err  -> putStrLn err >> evalCommands
        Right cmd -> evalCmd cmd

runWalletRepl :: WorkMode ssc m => WalletOptions -> m ()
runWalletRepl WalletOptions{..} = do
    -- Wait some time to ensure blockchain is fetched
    putText $ sformat ("Started node. Waiting for "%int%" slots...") woInitialPause
    wait $ for $ fromIntegral woInitialPause * slotDuration

    let sk = genesisSecretKeys !! woSecretKeyIdx
    na <- fmap dhtAddr <$> discoverPeers DHTFull
    putText "Welcome to Wallet CLI Node"
    runReaderT (evalCmd Help) (sk, na)

#ifdef WITH_WEB
runWalletApi :: WorkMode ssc m => Word16 -> m ()
runWalletApi = walletServeWeb
#endif

main :: IO ()
main = do
    opts@WalletOptions {..} <- execParser optsInfo

    KeyPair _ sk <- generate arbitrary
    vssKeyPair <- generate arbitrary
    let logParams =
            LoggingParams
            { lpRunnerTag     = "smart-wallet"
            , lpHandlerPrefix = woLogsPrefix
            , lpConfigPath    = woLogConfig
            }
        baseParams =
            BaseParams
            { bpLoggingParams      = logParams
            , bpPort               = woPort
            , bpDHTPeers           = woDHTPeers
            , bpDHTKeyOrType       = Right DHTFull
            , bpDHTExplicitInitial = woDhtExplicitInitial
            }

    bracketDHTInstance baseParams $ \inst -> do
        let timeSlaveParams =
                baseParams
                { bpLoggingParams = logParams { lpRunnerTag = "time-slave" }
                }

        systemStart <- runTimeSlaveReal inst timeSlaveParams

        let params =
                NodeParams
                { npDbPath      = Just woDbPath
                , npRebuildDb   = woRebuildDb
                , npSystemStart = systemStart
                , npSecretKey   = sk
                , npBaseParams  = baseParams
                , npCustomUtxo  = Just $ genesisUtxo $
                                  stakesDistr woFlatDistr woBitcoinDistr
                , npTimeLord    = False
                , npJLFile      = woJLFile
                }
            gtParams =
                GtParams
                { gtpRebuildDb  = False
                , gtpDbPath     = Nothing
                , gtpSscEnabled = False
                , gtpVssKeyPair = vssKeyPair
                }

            plugins :: WorkMode ssc m => [m ()]
            plugins = case woAction of
                Repl          -> [runWalletRepl opts]
#ifdef WITH_WEB
                Serve webPort -> [runWalletApi webPort]
#endif

        case woSscAlgo of
            GodTossingAlgo -> putText "Using MPC coin tossing" *>
                              runNodeProduction @SscGodTossing inst plugins params gtParams
            NistBeaconAlgo -> putText "Using NIST beacon" *>
                              runNodeProduction @SscNistBeacon inst plugins params ()
#else
main :: IO ()
main = panic "Wallet is disabled!"
#endif
