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

import           Control.Arrow
                   (first, second)
import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (NodeId(..), Process, ProcessId, WhereIsReply(..),
                   expect, getSelfPid, liftIO, match, matchAny,
                   receiveTimeout, receiveWait, register, say, send,
                   terminate, unregister, whereisRemoteAsync)
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
import           Data.Maybe
                   (fromMaybe)
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)
import           System.Random
                   (getStdRandom, randomR)
import           Text.Printf
                   (printf)

import           StateMachine

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

data Task = Task Int -- XXX
  deriving (Typeable, Generic, Show, Ord, Eq)

instance Binary Task

data Message
  = AskForTask ProcessId
  | DeliverTask Task
  | WorkDone
  | TaskFinished ProcessId Task
  deriving (Typeable, Generic, Show)

instance Binary Message

------------------------------------------------------------------------

workerP :: NodeId -> Process ()
workerP nid = do
  self <- getSelfPid
  say $ printf "slave alive on %s" (show self)
  master <- waitForMaster nid
  send master (AskForTask self)
  stateMachineProcess (self, master) () slaveSM

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

slaveSM :: Message -> StateMachine (ProcessId, ProcessId) () Message ()
slaveSM (DeliverTask task@(Task n)) = do
  -- do some work
  t <- liftIO (getStdRandom (randomR (0, n * 1000000))) -- n secs
  liftIO (threadDelay t)
  tell (printf "done: %s" (show task))
  (self, master) <- ask
  master ! TaskFinished self task
  master ! AskForTask self
slaveSM WorkDone = halt

------------------------------------------------------------------------

masterP :: Process ()
masterP = do
  self <- getSelfPid
  say $ printf "master alive on %s" (show self)
  register "taskQueue" self
  let n = 15
      q = foldl' (\akk -> (enqueue akk) . Task) mempty [1..n]
  stateMachineProcess () (n, q) masterSM

masterSM :: Message -> StateMachine () (Int, Queue Task) Message ()
masterSM (AskForTask pid) = do
  q <- gets snd
  case dequeue q of
    (Just task, q') -> do
      modify (second (const q'))
      pid ! DeliverTask task
    (Nothing, _)    -> do
      pid ! WorkDone
      n <- gets fst
      when (n == 0) halt
masterSM (TaskFinished pid task) = do
  tell (printf "work %s done by %s" (show task) (show pid))
  n <- gets fst
  if n == 0
  then halt
  else modify (first pred)
