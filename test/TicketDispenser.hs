{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TicketDispenser where

import           Control.Distributed.Process
                   (Process, ProcessId, expect, getSelfPid, liftIO,
                   send, spawnLocal)
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
import           System.Directory
                   (removePathForcibly)
import           System.IO.Strict
                   (readFile)
import           System.IO.Temp
                   (emptySystemTempFile)
import           Test.QuickCheck
                   (Gen, Property, expectFailure, forAllShrink,
                   frequency)
import           Text.Printf
                   (printf)

import           Linearisability
import           QuickCheckHelpers
import           Scheduler
import           StateMachine

------------------------------------------------------------------------

-- In this example we will implement and test a ticket dispenser; think
-- of one of those machines in the pharmacy which gives you a piece of
-- paper with your number in line on it.
--
-- This example also appears in the "Testing a Database for Race
-- Conditions with QuickCheck" and "Testing the Hard Stuff and Staying
-- Sane" papers.


-- Our ticket dispenser support two actions; you can take a ticket and
-- reset the dispenser (refill it with new paper tickets).
data Request
  = TakeTicket
  | Reset
  deriving (Eq, Show, Generic)

instance Binary Request

-- If you take a ticket the dispenser will return you a number, and if
-- you reset it you get an acknowledgement.
data Response
  = Number Int
  | Ok
  deriving (Eq, Show, Generic)

instance Binary Response

------------------------------------------------------------------------

-- We use a maybe integer as a model, where nothing means that the
-- dispenser hasn't been reset or filled with paper yet.

type Model = Maybe Int

initModel :: Model
initModel = Nothing

-- The transition function describes how actions advance the model. When
-- we take a ticket the counter is incremented by one, and when we reset
-- the counter is set to zero.

transition :: Model -> Either Request Response -> Model
transition m (Left req)    = case req of
  TakeTicket -> succ <$> m
  Reset      -> Just 0
transition m (Right _resp) = m

-- Pre-conditions describe in what state an action is allowed, and is
-- used to generate well-formed (or legal) programs.

precondition :: Model -> Request -> Bool
precondition Nothing  TakeTicket = False
precondition (Just _) TakeTicket = True
precondition _        Reset      = True

-- The assertions about our ticket dispenser are made by
-- post-conditions. Post-conditions provide a way to make sure that the
-- responses given by the implementation match the model.

postcondition :: Model -> Request -> Response -> Bool
postcondition m TakeTicket (Number i) = Just i == (succ <$> m)
postcondition _ Reset      Ok         = True
postcondition _ _          _          = False

-- We can also make assertions using a global invariant of the model,
-- but in the ticket dispenser case we don't need this.

invariant :: Model -> Bool
invariant _ = True

------------------------------------------------------------------------

-- To generate programs (lists of requests) we need to describe what
-- actions can occure with what frequency for each state.

generator :: Model -> Gen Request
generator Nothing  = return Reset
generator (Just _) = frequency
  [ (1, return Reset)
  , (8, return TakeTicket)
  ]

-- From that the library can, using the state machine model and the
-- precondition, generate whole well-formed programs.

genRequests :: Gen [Request]
genRequests = generateRequests generator precondition transition initModel

-- The library also provides a way of shrinking whole programs given how
-- to shrink individual requests.

shrink1 :: Model -> Request -> [Request]
shrink1 _ _ = []

shrRequests :: [Request] -> [[Request]]
shrRequests = shrinkRequests shrink1 precondition transition initModel

------------------------------------------------------------------------

-- We are now done with the modelling and QuickCheck specific parts, and
-- can proceed with the actual implementation of the ticket dispenser.

-- Haskell's typed actors, distributed-processes, are used to implement
-- the programs we want to test, or as a thin layer on top of the
-- programs we want to test (which may we written without using
-- distributed-processes).

-- We don't write our programs using distributed-process' Process monad
-- directly, but instead we use a StateMachine monad which is
-- essentially a RWS (reader writer state) as described in the following
-- blog post:
--
--   http://yager.io/Distributed/Distributed.html
--
-- The reason for this is that it allows us to run the distributed
-- process in "testing mode", where we drop in a deterministic user-land
-- message scheduler in place of distributed-process' scheduler. By
-- being able to deterministically control the flow of messages between
-- our actors we can easier test for race conditions. See the paper
-- "Finding Race Conditions in Erlang with QuickCheck and PULSE" for
-- more information about deterministic scheduling.

clientP :: ProcessId -> FilePath -> Process ()
clientP pid dbFile = stateMachineProcess_ (pid, dbFile) () True clientSM

-- The True above indicates that we want to run in "testing mode". After
-- we are done with testing we can deploy the distributed process using
-- the real scheduler, i.e. passing False instead.

-- The actual implementation uses a file to store the next ticket
-- number. The reader part of the state machine monad contains the
-- process id to which we send the responses and a file path to the
-- ticket database.

clientSM :: Request -> StateMachine (ProcessId, FilePath) () Request Response ()
clientSM req = case req of
  Reset      -> do
    (pid, db) <- ask
    liftIO (reset db)
    pid ! Ok
  TakeTicket -> do
    (pid, db) <- ask
    n <- liftIO (takeTicket db)
    pid ! Number n
  where
    reset :: FilePath -> IO ()
    reset db = writeFile db (show (0 :: Int))

    takeTicket :: FilePath -> IO Int
    takeTicket db = do
      n <- read <$> readFile db
      writeFile db (show (n + 1))
      return (n + 1)

-- For testing, we will set up two clients (so we can test for race
-- conditions) and a deterministic scheduler.

setup :: ProcessId -> Int -> Process (ProcessId, ProcessId, ProcessId, FilePath)
setup self seed = do
  schedulerPid <- spawnLocal (schedulerP (SchedulerEnv transition invariant)
                                (makeSchedulerState seed initModel))
  dbFile <- liftIO (emptySystemTempFile "ticket-dispenser")
  client1Pid <- spawnLocal (clientP self dbFile)
  client2Pid <- spawnLocal (clientP self dbFile)
  mapM_ (`send` SchedulerPid schedulerPid) [client1Pid, client2Pid]
  return (client1Pid, client2Pid, schedulerPid, dbFile)

-- Now we have everything we need to write QuickCheck properties.
-- We start with a sequential property, which assures that using a
-- single client the implementation matches the model.

-- We use QuickCheck's @forAllShrink@ combinator together with the
-- generator and shrinker for requests that we defined above. The
-- library provides a new combinator for writing properties involving
-- @Process@es, called @monadicProcess :: Testable a => PropertyM
-- Process a -> Property@. It's analogue to QuickCheck's @monadicIO@
-- combinator.

prop_ticketDispenser :: Property
prop_ticketDispenser =
  forAllShrink genRequests shrRequests $ \reqs -> monadicProcess $ lift $ do

    -- The tests themselves will have a process id, which will be the
    -- used to communicate with the implementation of the ticket
    -- dispenser.
    self <- getSelfPid
    (client1Pid, _, schedulerPid, dbFile) <- setup self 25

    -- Next we tell the scheduler where to send the result, how many
    -- messages it should expect, and which messages should be sent in a
    -- sequential fashion (all messages will be sent sequentially in
    -- this property, as we only are using one client).
    send schedulerPid (SchedulerSupervisor self)
    send schedulerPid (SchedulerCount (length reqs * 2))
    send schedulerPid (SchedulerSequential [])

    -- Send the generated requests from the tests, via the scheduler, to
    -- the client.
    forM_ reqs $ \req ->
      send schedulerPid (SchedulerRequest self req client1Pid
                          :: SchedulerMessage Request Response)

    -- Once all requests have been processed the scheduler will send us
    -- a trace/history of the messages.
    SchedulerHistory hist <- expect

    -- Clean up after ourselves.
    liftIO (removePathForcibly dbFile)

    -- Finally we check if the model agrees with the responeses from the
    -- implementation. The way this is done is by starting from the
    -- initial model, for each request and response pair we advance the
    -- model and check the post-condition for that pair.
    unless (linearisable transition postcondition initModel hist) $
      fail (printf "Can't linearise:\n%s\n"
             (trace transition initModel hist))

------------------------------------------------------------------------

-- The above property passes, even though there's a bug in the
-- implementation. Have a look at how @takeTicket@ is implemented! It
-- first reads a file and then writes to it. If two of those actions
-- happen concurrently one write might overwrite the other causing a
-- race condition!

-- We shall now see how the state machine approach can catch race
-- conditions for nearly no extra work.

-- First we need to explain how to generate and shrink
-- parallel/concurrent programs. We will model concurrent programs as a
-- pair of normal programs, where the first component is a sequential
-- prefix (run on one thread) that sets some state up (in our case
-- resets the ticket dispenser). The second component is the concurrent
-- part which will be run using multiple threads.

genParallelRequests :: Gen ([Request], [Request])
genParallelRequests = generateParallelRequests generator precondition transition initModel

shrParallelRequests :: ([Request], [Request]) -> [([Request], [Request])]
shrParallelRequests = shrinkParallelRequests shrink1 precondition transition initModel

-- The concurrent/parallel property looks quite similar to the
-- sequential one, except we generate and shrink parallel programs.

prop_ticketDispenserParallel :: Property
prop_ticketDispenserParallel = expectFailure $
  forAllShrink genParallelRequests shrParallelRequests $ \(prefix, suffix) -> monadicProcess $ lift $ do
    self <- getSelfPid

    -- First difference, is that we will use two clients this time.
    (client1Pid, client2Pid, schedulerPid, dbFile) <- setup self 15
    send schedulerPid (SchedulerSupervisor self)
    let count = (length prefix + length suffix) * 2
    send schedulerPid (SchedulerCount count)

    -- We need to tell the scheduler to run the prefix sequentially.
    let seqPairs = foldr (\_ ih -> (self, client1Pid) : (self, client1Pid) : ih) [] prefix
    send schedulerPid (SchedulerSequential seqPairs)

    -- Send the generates prefix requests from the tests, via the
    -- scheduler, to the first client.
    forM_ prefix $ \req ->
      send schedulerPid (SchedulerRequest self req client1Pid
                          :: SchedulerMessage Request Response)

    -- Send the generated parallel suffix from an alternation between
    -- the two clients.
    forM_ (zip (cycle [True, False]) suffix) $ \(client, req) ->
      send schedulerPid (SchedulerRequest self req (if client then client1Pid else client2Pid)
                          :: SchedulerMessage Request Response)

    SchedulerHistory hist <- expect

    liftIO (removePathForcibly dbFile)

    -- When we have a concurrent history, we try to find a possible
    -- sequential interleaving of requests and responses that respects
    -- the post-conditions. This technique was first described in the
    -- paper "Linearizability: A Correctness Condition for Concurrent
    -- Objects".
    unless (linearisable transition postcondition initModel hist) $
      fail (printf "Can't linearise:\n%s\n"
             (trace transition initModel hist))

------------------------------------------------------------------------

-- Example output:
{-
> quickCheck prop_ticketDispenserParallel
+++ OK, failed as expected. (after 3 tests and 3 shrinks):
Exception:
  user error (Can't linearise:
  Nothing
    ==> Reset  [8]
  Just 0
    <== Ok  [8]
  Just 0
    ==> TakeTicket  [8]
  Just 1
    ==> TakeTicket  [8]
  Just 2
    <== Number 2  [8]
  Just 2
    <== Number 1  [8]

  )
([Reset],[TakeTicket,TakeTicket])
-}
