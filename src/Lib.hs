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
                   expect, getSelfPid, liftIO, match, matchAny,
                   receiveTimeout, register, say, send, terminate,
                   unregister, whereisRemoteAsync)
import           Data.Binary
import           Data.Maybe (fromMaybe)
import           Data.Foldable
                   (foldl')
import           Data.Typeable
import           GHC.Generics
                   (Generic)
import           System.Random
                   (getStdRandom, randomR)
import           Text.Printf

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

data Message = CallForDuty ProcessId
             | CallForDutyAck ProcessId
             | AskForTask ProcessId
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
  pid <- waitForMaster nid
  send pid $ CallForDuty self
  CallForDutyAck peer <- expect
  go self peer
  where
    go self peer = do
      send peer $ AskForTask self
      m <- expect
      case m of
        DeliverTask task@(Task n) -> do
          -- do some work
          liftIO $ do
            t <- getStdRandom $ randomR (0, n * 1000000) -- n secs
            threadDelay t
          say $ printf "done: %s" (show task)
          send peer $ TaskFinished self task
          go self peer
        WorkDone -> return ()
        msg -> do
          say $ printf "did not understand %s" (show msg)
          go self peer

    waitForMaster masterNid = do
      say $ printf "waiting for master on %s" (show masterNid)
      whereisRemoteAsync masterNid "taskQueue"
      mpid <- receiveTimeout 100000
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

------------------------------------------------------------------------

masterP :: Process ()
masterP = do
  self <- getSelfPid
  say $ printf "master alive on %s" (show self)
  register "taskQueue" self
  let n = 15
      q = foldl' (\akk -> (enqueue akk) . Task) mempty [1..n]
  go self n q
  where
    go :: ProcessId -> Int -> Queue Task -> Process ()
    go self n q = do
      m <- expect
      case m of
        CallForDuty peer -> do
          send peer $ CallForDutyAck self
          go self n q
        AskForTask peer -> do
          case dequeue q of
            (Just task, q') -> do
              send peer (DeliverTask task)
              go self n q'
            (Nothing, q') -> do
              send peer WorkDone
              if n == 0
              then shutdown
              else go self n q'
        TaskFinished peer task -> do
          say $ printf "work %s done by %s" (show task) (show peer)
          if n == 0
          then shutdown
          else go self (pred n) q
        msg -> do
          say $ printf "did not understand %s" (show msg)
          go self n q

    shutdown = do
      unregister "taskQueue"
