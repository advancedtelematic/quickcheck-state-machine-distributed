{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFoldable     #-}
{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}

module Lib
  ( masterP
  , workerP
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
import           Data.Foldable
                   (foldl')
import           Data.Monoid
                   ((<>))
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)
import           Test.Hspec.Core.Runner
                   (Summary(..))
import           Text.Printf
                   (printf)

import           StateMachine

import           Test

------------------------------------------------------------------------

newtype Enqueue a = Enqueue [a] deriving Show
newtype Dequeue a = Dequeue [a] deriving Show

data Queue a = Queue (Enqueue a) (Dequeue a) deriving Show

instance Monoid (Queue a) where
  mempty = mkQueue [] []
  mappend (Queue (Enqueue es) (Dequeue ds))
          (Queue (Enqueue fs) (Dequeue gs))
    = mkQueue (fs ++ reverse gs ++ es) (ds)

mkQueue :: [a] -> [a] -> Queue a
mkQueue es [] = Queue (Enqueue []) (Dequeue $ reverse es)
mkQueue es ds = Queue (Enqueue es) (Dequeue ds)

enqueue :: Queue a -> a -> Queue a
enqueue (Queue (Enqueue es) (Dequeue ds)) e = mkQueue (e:es) ds

dequeue :: Queue a -> (Maybe a, Queue a)
dequeue (Queue (Enqueue []) (Dequeue [])) = (Nothing, mempty)
dequeue (Queue (Enqueue es) (Dequeue (d:ds))) = (Just d, mkQueue es ds)
dequeue _ = error "unexpected invariant: front of queue is empty but rear is not"

------------------------------------------------------------------------

data Task = Task String
  deriving (Typeable, Generic, Show, Ord, Eq)

instance Binary Task

data Message
  = AskForTask ProcessId
  | DeliverTask Task
  | WorkDone
  | TaskFinished ProcessId Task TaskResult
  deriving (Typeable, Generic, Show)

data TaskResult = TaskResult Int Int
  deriving (Generic, Show)

instance Binary TaskResult

summaryFromTaskResult :: TaskResult -> Summary
summaryFromTaskResult (TaskResult exs fails) = Summary exs fails

instance Binary Message

------------------------------------------------------------------------

workerP :: NodeId -> Process ()
workerP nid = do
  self <- getSelfPid
  say $ printf "slave alive on %s" (show self)
  master <- waitForMaster nid
  send master (AskForTask self)
  stateMachineProcess (self, master) () workerSM

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

workerSM :: Message -> StateMachine (ProcessId, ProcessId) () Message ()
workerSM (DeliverTask task@(Task descr)) = do
  tell $ printf "running: %s" (show task)
  Summary exs fails <- liftIO $ runTests descr
  tell $ printf "done: %s" (show task)
  (self, master) <- ask
  master ! TaskFinished self task (TaskResult exs fails)
  master ! AskForTask self
workerSM WorkDone = halt
workerSM _ = error "invalid state transition"

------------------------------------------------------------------------

masterP :: [String] -> Process ()
masterP args = do
  self <- getSelfPid
  say $ printf "master alive on %s: %s" (show self) (unwords args)
  register "taskQueue" self
  let n = length args
      q = foldl' (\akk -> (enqueue akk) . Task) mempty args
  stateMachineProcess () (MasterState n  q  mempty) masterSM

data MasterState = MasterState
  { step    :: Int
  , queue   :: Queue Task
  , summary :: Summary
  }

masterSM :: Message -> StateMachine () MasterState Message ()
masterSM (AskForTask pid) = do
  q <- gets queue
  case dequeue q of
    (Just task, q') -> do
      modify (\s -> s { queue = q' })
      pid ! DeliverTask task
    (Nothing, _)    -> do
      pid ! WorkDone
      n <- gets step
      when (n == 0) halt
masterSM (TaskFinished pid task result) = do
  tell $ printf "%s: %s done with %s" (show task) (show result) (show pid)
  n <- gets step
  summary' <- gets summary
  let summary'' = summary' <> summaryFromTaskResult result
  if n == 0
  then do
    tell $ printf "summary: " <> show summary''
    halt
  else do
    modify (\s -> s { step = pred $ step s
                    , summary = summary''
                    })
masterSM _ = error "invalid state transition"
