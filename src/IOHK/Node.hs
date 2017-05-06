{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
module IOHK.Node (startNode) where

import           Network.Transport (EndPointAddress(..))
import           Network.Transport.TCP (createTransport, defaultTCPParameters, encodeEndPointAddress)
import           Network.Socket (HostName, ServiceName)
import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable (Serializable)
import           Control.Distributed.Process.Node (newLocalNode, initRemoteTable, runProcess, forkProcess)
import           Control.Monad
import           Control.Monad.Extra (whileM)
import           Control.Concurrent (MVar, putMVar, takeMVar, newEmptyMVar, threadDelay)
import qualified Data.ByteString.Char8 as BS
import           Data.Binary
import           Data.Typeable (Typeable)
import           Data.Maybe (isNothing)
import           System.Clock
import           System.IO
import           GHC.Generics

type Payload = (ProcessId, Int, Double)

data Timeout = Timeout
    deriving (Show, Generic, Typeable)

instance Binary Timeout

startNode :: HostName
          -> ServiceName
          -> [(HostName, ServiceName)]
          -> [Double]
          -> Int
          -> Int
          -> IO ()
startNode host port remotes nums sendfor waitfor = do
    Right t <- createTransport host port defaultTCPParameters
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

        forever $ do
            t <- currentTime
            if t - started >= sendfor'
            then do
                send receiver Timeout
                send broadcaster Timeout
                terminate
            else
                liftIO $ threadDelay $ 100 * millisecond

    (result, count) <- takeMVar done
    debug $ "received: " ++ show count
    putStrLn $ show $ round result

  where
    currentTime = liftIO $ getTime Monotonic
    sendfor' = TimeSpec (fromIntegral sendfor) 0
    waitfor' = TimeSpec (fromIntegral waitfor) 0

broadcast :: Serializable a => [ProcessId] -> a -> Process ()
broadcast pids a =
    forM_ pids (flip send a)

broadcastPayloads :: [ProcessId] -> [Payload] -> Process ()
broadcastPayloads pids (p : ps) = do
    broadcast pids p
    mTimeout <- expectTimeout 0 :: Process (Maybe Timeout)

    when (isNothing mTimeout) $
        broadcastPayloads pids ps

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
    go [] pids =
        return pids

second :: Int
second = 1000 * millisecond

millisecond :: Int
millisecond = 1000

debug :: String -> IO ()
debug = hPutStrLn stderr
