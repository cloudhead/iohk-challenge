{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
module Main (main) where

import IOHK.Node
import System.Environment
import Data.List.Split
import System.Random
import System.Console.GetOpt
import System.IO
import System.Exit

options :: [OptDescr (Options -> Options)]
options =
    [ Option [] ["host"]
        (ReqArg (\o opts -> opts { optsHost = o })         "<host>")     "Listen host"
    , Option [] ["port"]
        (ReqArg (\o opts -> opts { optsPort = o })         "<port>")     "Listen port"
    , Option [] ["send-for"]
        (ReqArg (\o opts -> opts { optsSendFor = read o }) "<seconds>")  "Broadcast period duration"
    , Option [] ["wait-for"]
        (ReqArg (\o opts -> opts { optsWaitFor = read o }) "<seconds>")  "Grace period duration"
    , Option [] ["with-seed"]
        (ReqArg (\o opts -> opts { optsSeed = read o })    "<integer>")  "Random seed"
    ]

getOptions :: IO (Options, [(String, String)])
getOptions = do
    a <- getArgs
    case getOpt RequireOrder options a of
        (flags, remotes, []) ->
            return (foldr ($) defaultOptions flags, map parse remotes)
        (_, _, msgs) -> do
            hPutStr stderr $ "iohk-node: " ++ head msgs
            exitWith $ ExitFailure 1
  where
    parse addr =
        let [host, port] = splitOn ":" addr in (host, port)

main :: IO ()
main = do
    (opts@Options { optsSeed }, remotes) <- getOptions
    startNode opts remotes (randoms $ mkStdGen optsSeed)

