module Main (main) where

import IOHK.Node
import System.Environment (getArgs)
import Data.List.Split
import System.Random

main :: IO ()
main = do
    [host, port, remotes, seed] <- getArgs
    let gen = mkStdGen (read seed)
    startNode host port (map parse (splitOn "," remotes)) (randoms gen) sendfor waitfor
  where
    parse addr =
        let [host, port] = splitOn ":" addr in (host, port)
    sendfor = 5
    waitfor = 5

