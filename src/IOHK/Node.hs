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
import           Data.Time.Clock.POSIX (getPOSIXTime)
import           System.Clock (TimeSpec(..), Clock(Monotonic), getTime)
import           System.IO (hPutStrLn, stderr)
import           GHC.Generics (Generic)
import           Control.Monad.IO.Class (MonadIO)
import qualified Data.Sequence as Seq
import           Data.Sequence (Seq, (|>), ViewR((:>)))
import           Data.Ord (comparing)

data Options = Options
    { optsHost    :: HostName
    , optsPort    :: ServiceName
    , optsSendFor :: Int
    , optsWaitFor :: Int
    , optsSeed    :: Int
    , optsBuffer  :: Int
    } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
    { optsHost    = "127.0.0.1"
    , optsPort    = "9000"
    , optsSendFor = 5
    , optsWaitFor = 5
    , optsSeed    = 1
    , optsBuffer  = 10000
    }

-- | The message payload. Contains the sending process ID, the index
-- of the message and a random number between 0 and 1.
type Payload = (ProcessId, Int, Double)

-- | The message exchanged between nodes. Contains the 'Payload' and the
-- time at which the message was sent.
type Msg = (Payload, Timestamp)

-- | Unix timestamp.
type Timestamp = Int

-- | In-process message used to signal time is up.
data Timeout = Timeout
    deriving (Show, Generic, Typeable)

instance Binary Timeout

-- | Start the node and start broadcasting and receiving messages.
startNode :: Options                   -- ^ See 'Options'.
          -> [(HostName, ServiceName)] -- ^ Remotes to broadcast to.
          -> [Double]                  -- ^ List of numbers to broadcast.
          -> IO ()
startNode Options{..} remotes nums = do
    Right t <- createTransport optsHost optsPort defaultTCPParameters
    node <- newLocalNode t initRemoteTable

    -- Used to get results from the broadcasting and receiving processes.
    broadcastResult <- newEmptyMVar :: IO (MVar Int)
    receiveResult <- newEmptyMVar :: IO (MVar (Double, (Int, Int)))

    -- Receiver process.
    receiver <- forkProcess node $ do
        register "receiver" =<< getSelfPid
        result <- receiveMessages optsBuffer
        liftIO $ putMVar receiveResult result

    -- Broadcaster process. Only starts broadcasting when it receives the PIDs
    -- as a message.
    broadcaster <- forkProcess node $ do
        self <- getSelfPid
        pids <- expect :: Process [ProcessId]
        result <- broadcastMessages pids $
            zip3 (repeat self) [1..] (cycle nums)
        liftIO $ putMVar broadcastResult result

    -- Main process. Gets the PIDs of the remote nodes and sends them to the
    -- broadcaster process. Keeps track of time.
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

    countBroadcasted                        <- takeMVar broadcastResult
    (result, (countReceived, countDropped)) <- takeMVar receiveResult

    let droppedPercent :: Int =
            round $ (fromIntegral countDropped / fromIntegral countReceived * 100 :: Double)

    debug $ "Sent " ++ show countBroadcasted ++ " messages."
    debug $ "Received " ++ show countReceived ++ " messages."
    debug $ "Dropped " ++ show countDropped ++ " (" ++ show droppedPercent ++ "%) messages."

    putStrLn $ show countReceived ++ " " ++ show (round result :: Int)

  where
    sendFor = TimeSpec (fromIntegral optsSendFor) 0
    waitFor = TimeSpec (fromIntegral optsWaitFor) 0

-- | Get the current time.
currentTime :: Process TimeSpec
currentTime = liftIO $ getTime Monotonic

-- | Wait until the supplied condition is fulfilled, and run the action.
waitUntil :: (TimeSpec -> Bool)      -- ^ Condition to check with current time.
          -> (TimeSpec -> Process a) -- ^ Action to run if condition is true.
          -> Process a
waitUntil cond action = do
    t <- currentTime

    if cond t
    then action t
    else do
        liftIO $ threadDelay $ 100 * millisecond
        waitUntil cond action

-- | Broadcast payloads to the specified PIDs. A timestamp is attached to each
-- payload. When a 'Timeout' message is received, or if all payloads have been
-- broadcast, the function exits with the number of messages sent.
broadcastMessages :: [ProcessId] -> [Payload] -> Process Int
broadcastMessages pids ps =
    go ps 0
  where
    go (p : ps) n = do
        -- The current POSIX time in microseconds is the message timestamp.
        t <- round . (* microsecond) <$> liftIO getPOSIXTime :: Process Timestamp
        -- Send message to all PIDs.
        forM_ pids (flip send (p, t))
        -- If we have a 'Timeout' message in our inbox, exit, we're done.
        mTimeout <- expectTimeout 0 :: Process (Maybe Timeout)
        case mTimeout of
            Nothing ->
                go ps (n + 1)
            Just _ ->
                return n
    go [] n =
        return n

-- | Receive messages and compute the result. The return value is a tuple of
-- the result and the number of messages received and dropped.
receiveMessages :: Int -> Process (Double, (Int, Int))
receiveMessages bufsize =
    go Seq.empty (0, 0) 0 0.0
  where
    go :: Seq Msg     -- ^ A buffer of messages.
       -> (Int, Int)  -- ^ Number of messages received and dropped.
       -> Timestamp   -- ^ The earliest timestamp we can receive to keep ordering.
       -> Double      -- ^ The accumulator for our computation.
       -> Process (Double, (Int, Int))

    -- When the buffer is full, compute its result, and empty the buffer.
    go buf stats _ acc | Seq.length buf == bufsize =
        go Seq.empty stats t result
      where
        (t, result) = computeResult buf acc

    -- Receive a message or a timeout.
    go buf (n, nd) earliest acc = do
        result <- receiveWait
            [ match (\(pay :: Payload, t :: Timestamp) -> return (Right (pay, t)))
            , match (\(timeout :: Timeout)             -> return (Left timeout))
            ]
        case result of
            -- If the message was sent earlier than the earliest, drop it, since
            -- the window to use it in our computation has passed.
            Right (_, t) | t < earliest ->
                go buf (n, nd + 1) earliest acc
            -- The message was sent within our time window, add it to the buffer.
            Right msg ->
                go (buf |> msg) (n + 1, nd) earliest acc
            -- Timeout received, we're done. Compute the results from the current
            -- buffer and exit.
            Left _ ->
                return (snd (computeResult buf acc), (n, nd))

    -- Compute the new result based on the buffer and current result. Returns
    -- the latest timestamp from the buffer and the new result.
    computeResult :: Seq Msg -> Double -> (Timestamp, Double)
    computeResult buf acc =
        (latest, foldr f acc sortedBuf)
      where
        -- The computation to perform on each received (index, number) pair.
        f ((_, i, x), _) acc = acc + fromIntegral i * x
        -- The buffer sorted by timestamp.
        sortedBuf = Seq.unstableSortBy (comparing snd) buf
        -- The largest timestamp of the buffer, which becomes the earliest
        -- we can process to preserve ordering.
        _ :> (_, latest) = Seq.viewr sortedBuf

-- | Translates host + port pairs to PIDs.
connectRemotes :: [(HostName, ServiceName)] -> Process [ProcessId]
connectRemotes remotes =
    go remotes []
  where
    go remotes@((host, port) : rest) pids = do
        whereisRemoteAsync (NodeId $ encodeEndPointAddress host port 0) "receiver"
        result <- expectTimeout $ 100 * millisecond
        case result of
            Just (WhereIsReply _ (Just pid)) ->
                go rest (pid : pids)
            _ ->
                go remotes pids
    go [] pids =
        return pids

millisecond :: Num a => a
millisecond = 1000

microsecond :: Num a => a
microsecond = 1000 * millisecond

debug :: MonadIO m => String -> m ()
debug = liftIO . hPutStrLn stderr
