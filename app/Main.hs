{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (NodeId(..))
import           Control.Distributed.Process.Node
                   (initRemoteTable, newLocalNode, runProcess)
import           Data.Maybe
                   (fromMaybe)
import           Data.String
                   (fromString)
import           Network.Transport
                   (EndPointAddress(..))
import           Network.Transport.TCP
                   (createTransport, defaultTCPParameters)
import           System.Environment
                   (getArgs, getProgName, lookupEnv)
import           System.Exit
                   (exitFailure, exitSuccess)

import           Lib

------------------------------------------------------------------------

main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs

  masterHost <- fromMaybe "127.0.0.1" <$> lookupEnv "MASTER_SERVICE_HOST"
  masterPort <- fromMaybe "8080"      <$> lookupEnv "MASTER_SERVICE_PORT"

  let masterNodeId =
        NodeId (EndPointAddress (fromString (masterHost ++ ":" ++ masterPort ++ ":0")))

  case args of
    "master" : host : args' -> do
      transport <- makeTransport host masterHost masterPort
      nid <- newLocalNode transport initRemoteTable
      runProcess nid (masterP args')
      threadDelay (3 * 1000000)
      exitSuccess
    ["slave", host, port] -> do
      transport <- makeTransport host host port
      nid <- newLocalNode transport initRemoteTable
      runProcess nid (workerP masterNodeId)
      threadDelay (3 * 1000000)
      exitSuccess
    _ -> do
      putStrLn $ "usage: " ++ prog ++ " (master host | slave host port)"
      exitFailure
  where
  makeTransport host externalHost port = do
    etransport <- createTransport host port (\port' -> (externalHost, port')) defaultTCPParameters
    case etransport of
      Left  err       -> do
        putStrLn (show err)
        exitFailure
      Right transport -> return transport
