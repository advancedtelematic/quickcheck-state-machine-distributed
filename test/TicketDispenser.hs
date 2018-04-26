{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TicketDispenser where

import           Control.Distributed.Process
                   (Process, ProcessId, expect, getSelfPid, liftIO,
                   monitor, send, spawnLocal)
import           Control.Monad
                   (forM_, unless)
import           Control.Monad.Reader
                   (ask)
import           Control.Monad.Trans
                   (lift)
import           Data.Binary
                   (Binary)
import           GHC.Generics
                   (Generic)
import           Prelude                     hiding
                   (readFile)
import           System.IO.Strict
                   (readFile)
import           Test.QuickCheck
                   (Gen, Property, forAllShrink, frequency)
import           Test.QuickCheck.Monadic
                   (PropertyM)
import           Text.Printf
                   (printf)

import           Linearisability
import           QuickCheckHelpers
import           Scheduler
import           StateMachine

------------------------------------------------------------------------

data Request
  = TakeTicket
  | Reset
  deriving (Eq, Show, Generic)

instance Binary Request

data Response
  = Number Int
  | Ok
  deriving (Eq, Show, Generic)

instance Binary Response

------------------------------------------------------------------------

type Model = Maybe Int

initModel :: Model
initModel = Nothing

next :: Model -> Either Request Response -> Model
next m (Left req)    = case req of
  TakeTicket -> succ <$> m
  Reset      -> Just 0
next m (Right _resp) = m

pre :: Model -> Request -> Bool
pre Nothing  TakeTicket = False
pre (Just _) TakeTicket = True
pre _        Reset      = True

post :: Model -> Request -> Response -> Bool
post m TakeTicket (Number i) = Just i == (succ <$> m)
post _ Reset      Ok         = True
post _ _          _          = False

invariant :: Model -> Bool
invariant _ = True

generator :: Model -> Gen Request
generator Nothing  = return Reset
generator (Just _) = frequency
  [ (1, return Reset)
  , (8, return TakeTicket)
  ]

genRequests :: Gen [Request]
genRequests = generateRequests generator pre next initModel

genParallelRequests :: Gen ([Request], [Request])
genParallelRequests = generateParallelRequests generator pre next initModel

shrRequests :: [Request] -> [[Request]]
shrRequests = shrinkRequests (const (const [])) pre next initModel

shrParallelRequests :: ([Request], [Request]) -> [([Request], [Request])]
shrParallelRequests = shrinkParallelRequests (const (const [])) pre next initModel

clientP :: ProcessId -> Process ()
clientP pid = stateMachineProcess_ pid () True clientSM

ticketDispenserFile :: FilePath
ticketDispenserFile = "/tmp/ticket-dispenser.txt"

reset :: IO ()
reset = writeFile ticketDispenserFile (show (0 :: Int))

takeTicket :: IO Int
takeTicket = do
  n <- read <$> readFile ticketDispenserFile
  writeFile ticketDispenserFile (show (n + 1))
  return (n + 1)

clientSM :: Request -> StateMachine ProcessId () Request Response ()
clientSM req = case req of
  Reset      -> do
    liftIO reset
    pid <- ask
    pid ! Ok
  TakeTicket -> do
    n <- liftIO takeTicket
    pid <- ask
    pid ! Number n

setup :: ProcessId -> Int -> Process (ProcessId, ProcessId, ProcessId)
setup self seed = do
  schedulerPid <- spawnLocal (schedulerP (SchedulerEnv next (const True))
                                (makeSchedulerState seed initModel))
  client1Pid <- spawnLocal (clientP self)
  client2Pid <- spawnLocal (clientP self)
  mapM_ (`send` SchedulerPid schedulerPid) [client1Pid, client2Pid]
  return (client1Pid, client2Pid, schedulerPid)

rop_ticketDispenser :: Property
rop_ticketDispenser =
  forAllShrink genRequests shrRequests $ \reqs -> monadicProcess $ do
    self <- lift getSelfPid
    (client1Pid, _, schedulerPid) <- lift (setup self 25)
    lift $ send schedulerPid (SchedulerSupervisor self)
    lift $ send schedulerPid (SchedulerCount (length reqs * 2))
    let seqPairs = foldr (\_ ih -> (self, client1Pid) : (self, client1Pid) : ih) [] reqs
    lift (send schedulerPid (SchedulerSequential seqPairs))

    lift $ forM_ reqs $ \req ->
      send schedulerPid (SchedulerRequest self req client1Pid
                          :: SchedulerMessage Request Response)

    SchedulerHistory hist <- lift expect
      :: PropertyM Process (SchedulerHistory ProcessId Request Response)

    case wellformed [client1Pid] hist of
      Right () -> return ()
      Left err -> fail (printf "history isn't well-formed: %s" (show err))

    unless (linearisable next post initModel hist) $
      fail (printf "Can't linearise:\n%s\n"
             (trace next initModel hist))

prop_ticketDispenserParallel :: Property
prop_ticketDispenserParallel =
  forAllShrink genParallelRequests shrParallelRequests $ \(prefix, suffix) -> monadicProcess $ do
    self <- lift getSelfPid
    (client1Pid, client2Pid, schedulerPid) <- lift (setup self 15)
    lift $ mapM_ monitor [client1Pid, client2Pid, schedulerPid]
    lift $ send schedulerPid (SchedulerSupervisor self)
    let count = (length prefix + length suffix) * 2
    lift $ send schedulerPid (SchedulerCount count)

    let seqPairs = foldr (\_ ih -> (self, client1Pid) : (self, client1Pid) : ih) [] prefix
    lift (send schedulerPid (SchedulerSequential seqPairs))

    lift $ forM_ prefix $ \req ->
      send schedulerPid (SchedulerRequest self req client1Pid
                          :: SchedulerMessage Request Response)

    lift $ forM_ (zip (cycle [True, False]) suffix) $ \(client, req) ->
      send schedulerPid (SchedulerRequest self req (if client then client1Pid else client2Pid)
                          :: SchedulerMessage Request Response)

    SchedulerHistory hist <- lift expect
      :: PropertyM Process (SchedulerHistory ProcessId Request Response)

    case wellformed [client1Pid, client2Pid] hist of
      Right () -> return ()
      Left err -> fail (printf "history isn't well-formed: %s" (show err))

    unless (linearisable next post initModel hist) $
      fail (printf "Can't linearise:\n%s\n"
             (trace next initModel hist))
