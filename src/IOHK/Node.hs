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
import           Control.Distributed.Process.Node (newLocalNode, initRemoteTable, forkProcess)
import           Control.Monad (forM_)
import           Control.Concurrent (MVar, putMVar, takeMVar, newEmptyMVar, threadDelay)
import           Data.Binary (Binary)
import           Data.Typeable (Typeable)
import           System.Clock (TimeSpec(..), Clock(Monotonic), getTime)
import           System.IO (hPutStrLn, stderr)
import           GHC.Generics (Generic)
import           Control.Monad.IO.Class (MonadIO)

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
    broadcastResult <- newEmptyMVar :: IO (MVar Int)
    receiveResult <- newEmptyMVar :: IO (MVar (Double, Int))

    receiver <- forkProcess node $ do
        register "receiver" =<< getSelfPid
        result <- receivePayloads
        liftIO $ putMVar receiveResult result

    broadcaster <- forkProcess node $ do
        self <- getSelfPid
        pids <- expect :: Process [ProcessId]
        result <- broadcastPayloads pids 0 $
            zip3 (repeat self) [1..] (cycle nums)
        liftIO $ putMVar broadcastResult result

    forkProcess node $ do
        pids <- connectRemotes remotes
        send broadcaster pids
        started <- currentTime

        debug $ "Broadcasting..."
        finished <- waitUntil (\t -> t - started >= sendFor) $ \now -> do
            send broadcaster Timeout
            return now

        debug $ "Starting grace period..."
        waitUntil (\t -> t - finished >= waitFor) $ \_ ->
            send receiver Timeout

    countBroadcasted <- takeMVar broadcastResult
    (result, countReceived) <- takeMVar receiveResult
    debug $ "broadcast: " ++ show countBroadcasted
    debug $ "received: " ++ show countReceived

    print $ (countReceived, round result :: Int)

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

broadcastPayloads :: [ProcessId] -> Int -> [Payload] -> Process Int
broadcastPayloads pids n (p : ps) = do
    forM_ pids (flip send p)
    mTimeout <- expectTimeout 0 :: Process (Maybe Timeout)

    case mTimeout of
        Nothing ->
            broadcastPayloads pids (n + 1) ps
        Just _ ->
            return n
broadcastPayloads _ n [] =
    return n

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

millisecond :: Int
millisecond = 1000

debug :: MonadIO m => String -> m ()
debug = liftIO . hPutStrLn stderr
