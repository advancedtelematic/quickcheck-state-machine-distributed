module Main where

import           Control.Distributed.Process
                   (NodeId(..))
import           Data.String
                   (fromString)
import           Network.Transport
                   (EndPointAddress(..))
import           System.Environment
                   (getArgs, getProgName)

import           Control.Distributed.Process.Node
                   (initRemoteTable, newLocalNode, runProcess)
import           Lib
import           Network.Transport.TCP
                   (createTransport, defaultTCPParameters)
import           System.Exit
                   (exitFailure, exitSuccess)

------------------------------------------------------------------------

main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs

  case args of
    ["master", host, port] -> do
      Right transport <- createTransport host port (\sn -> (host, sn)) defaultTCPParameters
      nid <- newLocalNode transport initRemoteTable
      runProcess nid masterP
      exitSuccess
    ["slave", host, port, masterPeer] -> do
      let master = parsePeer masterPeer
      Right transport <- createTransport host port (\sn -> (host, sn)) defaultTCPParameters
      nid <- newLocalNode transport initRemoteTable
      runProcess nid (workerP master)
      exitSuccess
    _ -> do
      putStrLn $ "usage: " ++ prog ++ " (master | slave) host port"
      exitFailure
  where
  parsePeer address =
    NodeId (EndPointAddress (fromString (address ++ ":0")))
