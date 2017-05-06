{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
module IOHK.Node
    ( startNode
    , Options(..)
    , defaultOptions
    ) where

import           Network.Transport.TCP (createTransport, defaultTCPParameters, encodeEndPointAddress)
import           Network.Socket (HostName, ServiceName)
import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable (Serializable)
import           Control.Distributed.Process.Node (newLocalNode, initRemoteTable, forkProcess)
import           Control.Monad
import           Control.Concurrent (MVar, putMVar, takeMVar, newEmptyMVar, threadDelay)
import           Data.Binary
import           Data.Typeable (Typeable)
import           Data.Maybe (isNothing)
import           System.Clock
import           System.IO
import           GHC.Generics

data Options = Options
    { optsHost    :: HostName
    , optsPort    :: ServiceName
    , optsSendFor :: Int
    , optsWaitFor :: Int
    , optsSeed    :: Int
    } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
    { optsHost    = "127.0.0.1"
    , optsPort    = "9000"
    , optsSendFor = 10
    , optsWaitFor = 3
    , optsSeed    = 1
    }

type Payload = (ProcessId, Int, Double)

data Timeout = Timeout
    deriving (Show, Generic, Typeable)

instance Binary Timeout

startNode :: Options
          -> [(HostName, ServiceName)]
          -> [Double]
          -> IO ()
startNode Options{..} remotes nums = do
    Right t <- createTransport optsHost optsPort defaultTCPParameters
    node <- newLocalNode t initRemoteTable
    done <- newEmptyMVar :: IO (MVar (Double, Int))

    receiver <- forkProcess node $ do
        register "receiver" =<< getSelfPid
        result <- receivePayloads
        liftIO $ putMVar done result

    broadcaster <- forkProcess node $ do
        self <- getSelfPid
        pids <- expect :: Process [ProcessId]
        broadcastPayloads pids $
            zipWith3 (,,) (repeat self) [1..] (cycle nums)

    forkProcess node $ do
        pids <- connectRemotes remotes
        send broadcaster pids
        started <- currentTime

        finished <- waitUntil (\t -> t - started >= sendFor) $ \now -> do
            send receiver Timeout
            send broadcaster Timeout
            return now

        terminate


    (result, count) <- takeMVar done
    debug $ "received: " ++ show count
    putStrLn $ show $ round result

  where
    sendFor = TimeSpec (fromIntegral optsSendFor) 0
    waitFor = TimeSpec (fromIntegral optsWaitFor) 0

currentTime :: Process TimeSpec
currentTime = liftIO $ getTime Monotonic

waitUntil :: (TimeSpec -> Bool) -> (TimeSpec -> Process a) -> Process a
waitUntil cond action = do
    t <- currentTime

    if cond t
    then action t
    else do
        liftIO $ threadDelay $ 100 * millisecond
        waitUntil cond action

broadcast :: Serializable a => [ProcessId] -> a -> Process ()
broadcast pids a =
    forM_ pids (flip send a)

broadcastPayloads :: [ProcessId] -> [Payload] -> Process ()
broadcastPayloads pids (p : ps) = do
    broadcast pids p
    mTimeout <- expectTimeout 0 :: Process (Maybe Timeout)

    when (isNothing mTimeout) $
        broadcastPayloads pids ps
broadcastPayloads _ [] =
    return ()

receivePayloads :: Process (Double, Int)
receivePayloads =
    go 0 0
  where
    go !acc n = do
        result <- receiveWait
            [ match (\(pay :: Payload) -> return (Right pay))
            , match (\(t   :: Timeout) -> return (Left t))
            ]
        case result of
            Right (_, i, x) -> go (acc + (fromIntegral i) * x) (n + 1)
            Left _          -> return (acc, n)

connectRemotes :: [(HostName, ServiceName)] -> Process [ProcessId]
connectRemotes remotes =
    go remotes []
  where
    go remotes@((host, port) : rest) pids = do
        whereisRemoteAsync (NodeId $ encodeEndPointAddress host port 0) "receiver"
        -- The timeout here can't be too short, or it'll miss the reply.
        -- TODO: Allow replies to be processed out of order?
        result <- expectTimeout $ 100 * millisecond
        case result of
            Just (WhereIsReply _ (Just pid)) ->
                go rest (pid : pids)
            Nothing ->
                go remotes pids
            _ ->
                go remotes pids
    go [] pids =
        return pids

second :: Int
second = 1000 * millisecond

millisecond :: Int
millisecond = 1000

debug :: String -> IO ()
debug = hPutStrLn stderr
