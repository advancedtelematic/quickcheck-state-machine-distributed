{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ExplicitForAll      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Lib
  ( masterP
  , workerP
  , MasterState (..)
  , WorkerMessage
  )
  where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (NodeId(..), Process, ProcessId, WhereIsReply(..),
                   getSelfPid, liftIO, match, matchAny, receiveTimeout,
                   register, say, send, whereisRemoteAsync)
import           Control.Monad
                   (when)
import           Control.Monad.Reader
                   (ask)
import           Control.Monad.State
                   (gets, modify)
import           Data.Binary
                   (Binary)
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)
import           Text.Printf
                   (printf)

import           StateMachine
import           TaskQueue

------------------------------------------------------------------------

data WorkerMessage a
  = AskForTask ProcessId
  | TaskFinished ProcessId (TaskResult a)
  deriving (Typeable, Generic)

instance Binary a => Binary (WorkerMessage a)

data MasterMessage a
  = DeliverTask (Task a)
  | WorkDone
  deriving (Typeable, Generic)

instance Binary a => Binary (MasterMessage a)

------------------------------------------------------------------------

workerP :: forall a b. (Binary a, Typeable a, Binary b, Typeable b)
        => NodeId
        -> (Task a -> IO (TaskResult b))
        -> Process ()
workerP nid workload = do
  self <- getSelfPid
  say $ printf "slave alive on %s" (show self)
  master <- waitForMaster nid
  send master (AskForTask self :: WorkerMessage b)
  stateMachineProcess_ (self, master) () Nothing (workerSM @a @b workload)

waitForMaster :: NodeId -> Process ProcessId
waitForMaster masterNid = do
  say $ printf "waiting for master on %s" (show masterNid)
  whereisRemoteAsync masterNid "taskQueue"
  mpid <- receiveTimeout 1000
    [ match (\(WhereIsReply _ (Just pid)) -> do
                say $ printf "found master on %s" (show pid)
                return pid)
    , match (\(WhereIsReply _ Nothing)    -> do
                say $ printf "didn't find master."
                liftIO (threadDelay 1000000)
                waitForMaster masterNid)
    , matchAny (\msg                      -> do
                   say $ printf "unknown message: %s" (show msg)
                   waitForMaster masterNid)
    ]
  maybe (waitForMaster masterNid) return mpid

workerSM :: (Task a -> IO (TaskResult b))
         -> MasterMessage a
         -> StateMachine (ProcessId, ProcessId) () (WorkerMessage b) (WorkerMessage b) ()
workerSM mapAction (DeliverTask task@(Task taskId' _)) = do
  tell $ printf "running: %s" (show taskId')
  result' <- liftIO $ mapAction task
  tell $ printf "done: %s" (show taskId')
  (self, master) <- ask
  case result' of
    TaskSuccess _ result'' -> master ! (TaskFinished self $ TaskSuccess taskId' result'')
    TaskFailure _ result'' -> master ! (TaskFinished self $ TaskFailure taskId' result'')
  master ! AskForTask self
workerSM _ WorkDone = halt

------------------------------------------------------------------------

data MasterState a b = MasterState
  { step    :: Int
  , queue   :: Queue (Task a)
  , summary :: TaskSummary b
  }

masterP :: (Binary a, Typeable a, Binary b, Typeable b, Monoid b)
        => MasterState a b
        -> (TaskResult  b -> TaskSummary b -> TaskSummary b)
        -> (TaskSummary b -> IO ())
        -> Process ()
masterP initState reduceAction finalAction = do
  self <- getSelfPid
  say $ printf "master alive on %s" (show self)
  register "taskQueue" self
  stateMachineProcess_ () initState Nothing (masterSM reduceAction finalAction)

masterSM :: (TaskResult  b -> TaskSummary b -> TaskSummary b)
         -> (TaskSummary b -> IO ())
         -> WorkerMessage b
         -> StateMachine () (MasterState a b) (MasterMessage a) (MasterMessage a) ()
masterSM _ finalAction (AskForTask pid) = do
  q <- gets queue
  case dequeue q of
    (Just task, q') -> do
      modify (\s -> s { queue = q' })
      pid ! DeliverTask task
    (Nothing, _)    -> do
      pid ! WorkDone
      n <- gets step
      when (n == 0) $ do
        summary' <- gets summary
        liftIO $ finalAction summary'
        halt
masterSM reduceAction finalAction (TaskFinished pid result') = do
  tell $ printf "%s done with %s" (show pid) (show $ taskId result')
  n        <- gets step
  summary' <- gets summary
  let summary'' = reduceAction result' summary'
  if n == 0
  then do
    liftIO $ finalAction summary''
    halt
  else do
    modify (\s -> s { step    = pred $ step s
                    , summary = summary''
                    })
