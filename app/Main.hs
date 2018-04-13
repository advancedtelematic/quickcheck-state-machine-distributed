{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (NodeId(..))
import           Control.Distributed.Process.Node
                   (initRemoteTable, newLocalNode, runProcess)
import           Data.Binary
                   (Binary)
import           Data.Foldable
                   (foldl')
import           Data.Maybe
                   (fromMaybe)
import           Data.Proxy
                   (Proxy(Proxy))
import           Data.String
                   (fromString)
import           GHC.Generics
                   (Generic)
import           Network.Transport
                   (EndPointAddress(..))
import           Network.Transport.TCP
                   (createTransport, defaultTCPParameters)
import           System.Environment
                   (getArgs, getProgName, lookupEnv)
import           System.Exit
                   (exitFailure, exitSuccess)
import           Test.Hspec.Core.Runner
                   (Summary(..))

import           Lib
import           TaskQueue
import           Test

------------------------------------------------------------------------

type TestTask = String

data TestResult = TestResult Int Int
  deriving (Generic, Show)

instance Monoid TestResult where
  mempty = TestResult 0 0
  TestResult a b `mappend` TestResult c d = TestResult (a+c) (b+d)

instance Binary TestResult

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

      let testTasks = zipWith Task (map TaskId [0..]) args'
          n = length testTasks
          q = foldl' enqueue mempty testTasks
          initState = MasterState n q (mempty :: TaskResult TestResult)
          resultAction :: TaskResult TestResult -> IO ()
          resultAction (TaskResult tasks result') = do
            putStrLn $ "tasks completed: " ++ show tasks
            putStrLn $ "test summary: "    ++ show result'
      runProcess nid (masterP initState resultAction)

      threadDelay (3 * 1000000)
      exitSuccess
    ["slave", host, port] -> do
      transport <- makeTransport host host port
      nid       <- newLocalNode transport initRemoteTable

      let testAction :: Task TestTask -> IO (TaskResult TestResult)
          testAction (Task _ test) = do
            Summary exs fails <- runTests test
            return $ TaskResult mempty $ TestResult exs fails
      runProcess nid $ workerP (Proxy :: Proxy (WorkerMessage TestResult)) masterNodeId testAction

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
