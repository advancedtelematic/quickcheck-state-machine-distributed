{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ExplicitForAll      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Scheduler where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (Process, ProcessId, expect, getSelfPid, send,
                   spawnLocal)
import           Control.Monad
                   (forever)
import           Control.Monad.IO.Class
                   (liftIO)
import           Control.Monad.Reader
                   (ask)
import           Control.Monad.State
                   (get, modify, put)
import           Data.Binary
                   (Binary)
import           Data.Map
                   (Map)
import qualified Data.Map                    as M
import           Data.Maybe
                   (catMaybes)
import           Data.Sequence
                   (Seq)
import qualified Data.Sequence               as S
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)
import           System.Random
                   (StdGen, mkStdGen, randomR)

import           Linearisability
                   (History)
import           StateMachine

------------------------------------------------------------------------

data SchedulerPid = SchedulerPid ProcessId
  deriving Generic

instance Binary SchedulerPid

data SchedulerSupervisor = SchedulerSupervisor ProcessId
  deriving Generic

instance Binary SchedulerSupervisor

data SchedulerCount = SchedulerCount Int
  deriving Generic

instance Binary SchedulerCount

data SchedulerHistory pid inv resp = SchedulerHistory (History pid inv resp)
  deriving Generic

instance (Binary pid, Binary inv, Binary resp) => Binary (SchedulerHistory pid inv resp)

------------------------------------------------------------------------

getSchedulerPid :: Bool -> Process (Maybe ProcessId)
getSchedulerPid False = return Nothing
getSchedulerPid True  = do
  SchedulerPid pid <- expect
  return (Just pid)

data SchedulerEnv input output model = SchedulerEnv
  { transition :: model -> Either input output -> model
  , invariant  :: model -> Bool
  }

data SchedulerState input output model = SchedulerState
  { mailboxes      :: Map (ProcessId, ProcessId) (Seq (Either input output))
  , stdGen         :: StdGen
  , schedulerModel :: model
  , messageCount   :: Int
  }

makeSchedulerState :: Int -> model -> SchedulerState input output model
makeSchedulerState seed model = SchedulerState
  { mailboxes      = M.empty
  , stdGen         = mkStdGen seed
  , schedulerModel = model
  , messageCount   = 0
  }

------------------------------------------------------------------------

type Scheduler input output model =
  StateMachine
    (SchedulerEnv input output model)
    (SchedulerState input output model)
    input output
    (Maybe (ProcessId, Either input output))

schedulerSM :: (Show input, Show output, Show model)
  => SchedulerMessage input output -> Scheduler input output model
schedulerSM SchedulerTick = do
  SchedulerState{..} <- get
  if messageCount == 0
  then halt
  else do
    let processPairs = M.keys mailboxes
    if null processPairs
    then return Nothing
    else do
      let (i, stdGen') = randomR (0, length processPairs - 1) stdGen
          processPair  = processPairs !! i
      put SchedulerState { stdGen = stdGen', .. }
      case S.viewl (mailboxes M.! processPair) of
        S.EmptyL        -> return Nothing
        msg S.:< queue' -> do
          SchedulerEnv {..} <- ask
          -- unless (invariant model) $ do
          --   tell (printf "scheduler: invariant broken by `%s'" (show msg))
          --   halt
          put SchedulerState
            { mailboxes      = M.insert processPair queue' mailboxes
            , schedulerModel = transition schedulerModel msg
            , messageCount   = messageCount - 1
            , ..
            }

          let (from, to) = processPair
          case msg of
            Left  req  -> do
              to ? req
              return (Just (from, msg))
            Right resp -> do
              to ! resp
              return (Just (to, msg))
schedulerSM (SchedulerRequest from request to) = do
  modify $ \s -> s { mailboxes = M.alter f (from, to) (mailboxes s) }
  return Nothing
    where
      f Nothing      = Just (S.singleton (Left request))
      f (Just queue) = Just (queue S.|> Left request)
schedulerSM (SchedulerResponse from response to) = do
  modify $ \s -> s { mailboxes = M.alter f (from, to) (mailboxes s) }
  return Nothing
    where
      f Nothing      = Just (S.singleton (Right response))
      f (Just queue) = Just (queue S.|> Right response)

schedulerP
  :: forall input output model
  .  Show model
  => (Show input, Binary input, Typeable input)
  => (Show output, Binary output, Typeable output)
  => SchedulerEnv input output model
  -> SchedulerState input output model
  -> Process ()
schedulerP env st = do
  self <- getSelfPid
  SchedulerSupervisor supervisor <- expect
  SchedulerCount count <- expect
  _ <- spawnLocal $ forever $ do
    liftIO (threadDelay 10000)
    send self (SchedulerTick :: SchedulerMessage input output)
  hist <- catMaybes <$> stateMachineProcess env st { messageCount = count } Nothing schedulerSM
  send supervisor (SchedulerHistory hist)
