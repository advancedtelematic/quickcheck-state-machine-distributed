{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Bank where

import           Control.Distributed.Process
                   (Process, ProcessId, expect, getSelfPid, send,
                   spawnLocal)
import           Control.Monad
                   (forM_, unless)
import           Control.Monad.State
                   (get, lift, modify)
import           Data.Binary
                   (Binary)
import           Data.Map
                   (Map)
import qualified Data.Map                         as M
import           GHC.Generics
                   (Generic)
import           Test.QuickCheck
                   (Gen, Property, arbitrary, elements, forAllShrink,
                   frequency, getPositive, shrink)
import           Test.QuickCheck.Monadic
                   (PropertyM)

import           Linearisability
import           QuickCheckHelpers
import           Scheduler
import           StateMachine

------------------------------------------------------------------------

type Account = ProcessId
type Money   = Integer

data BankRequestF acc
  = OpenAccount acc
  | Deposit acc Money
  | Withdraw acc Money
  | CheckBalance acc
  | Transfer acc Money acc
  deriving (Eq, Show, Generic, Functor)

type BankRequest = BankRequestF ProcessId

fromPid :: BankRequestF pid -> pid
fromPid req = case req of
  OpenAccount pid  -> pid
  Deposit pid _    -> pid
  Withdraw pid _   -> pid
  CheckBalance pid -> pid
  Transfer pid _ _ -> pid

instance Binary BankRequest

data BankResponse
  = AccountCreated
  | DepositMade
  | WithdrawalMade
  | TransferMade
  | AccountAlreadyExists
  | AccountDoesntExist
  | InsufficientFunds
  | Balance Money
  deriving (Eq, Show, Generic)

instance Binary BankResponse

------------------------------------------------------------------------

type ModelF acc = Map acc Money

type Model = ModelF ProcessId

initModel :: Model
initModel = initModel'

initModel' :: ModelF acc
initModel' = M.empty

next :: Model -> Either BankRequest BankResponse -> Model
next = next'

next' :: Ord acc => ModelF acc -> Either (BankRequestF acc) BankResponse -> ModelF acc
next' model (Left req) = case req of
  OpenAccount acc       | acc `notElem` M.keys model -> M.insert acc 0 model
                        | otherwise                  -> model
  Deposit     acc money -> M.insertWith (+) acc money model
  Withdraw    acc money -> M.insertWith (\new old -> old - new) acc money model
  CheckBalance _        -> model
  Transfer from money to -> next' (next' model (Left (Withdraw from money)))
                                 (Left (Deposit to money))
next' model (Right _resp) = model

invariant :: Model -> Bool
invariant = all (\balance -> balance >= 0) . M.elems

precondition :: Ord acc => ModelF acc -> BankRequestF acc -> Bool
precondition model req = case req of
  OpenAccount _acc   -> True
  Deposit acc _money -> acc `elem` M.keys model
  Withdraw acc money -> acc `elem` M.keys model && model M.! acc >= money
  CheckBalance acc   -> acc `elem` M.keys model
  Transfer from money to
    -> from `elem` M.keys model
    && to `elem` M.keys model
    && model M.! from >= money
    && from /= to

post :: Ord acc => ModelF acc -> BankRequestF acc -> BankResponse -> Bool
post model req resp = case req of
  OpenAccount acc
    | M.lookup acc model == Nothing -> resp == AccountCreated
    | otherwise                     -> resp == AccountAlreadyExists
  Deposit _acc _money -> resp == DepositMade
  Withdraw acc money
    | M.lookup acc model >= Just money -> resp == WithdrawalMade
    | otherwise                        -> resp == InsufficientFunds

  CheckBalance acc -> resp == Balance (model M.! acc)
  Transfer from money _to
    | M.lookup from model >= Just money -> resp == TransferMade
    | otherwise                         -> resp == InsufficientFunds

generator1 :: [acc] -> ModelF acc -> Gen (BankRequestF acc)
generator1 workers model
  | M.null model = OpenAccount <$> elements workers
  | otherwise    = frequency
      [ (1, OpenAccount  <$> elements (M.keys model ++ workers))
      , (5, Deposit      <$> elements (M.keys model)
                         <*> fmap getPositive arbitrary)
      , (5, Withdraw     <$> elements (M.keys model)
                         <*> fmap getPositive arbitrary)
      , (8, Transfer     <$> elements (M.keys model)
                         <*> fmap getPositive arbitrary
                         <*> elements (M.keys model))
      , (5, CheckBalance <$> elements (M.keys model))
      ]

generator :: Ord acc => [acc] -> Gen [BankRequestF acc]
generator workers = generateRequests (generator1 workers) precondition next' initModel'

shrinker1 :: ModelF acc -> BankRequestF acc -> [BankRequestF acc]
shrinker1 _ (Deposit acc money)      = [ Deposit  acc  money'    | money' <- shrink money ]
shrinker1 _ (Withdraw acc money)     = [ Withdraw acc  money'    | money' <- shrink money ]
shrinker1 _ (Transfer from money to) = [ Transfer from money' to | money' <- shrink money ]
shrinker1 _ _                        = []

shrinker :: Ord acc => ModelF acc -> [BankRequestF acc] -> [[BankRequestF acc]]
shrinker model = shrinkRequests shrinker1 precondition next' model

------------------------------------------------------------------------

clientP :: Bool -> Process ()
clientP testing = do
  mscheduler <- Scheduler.getSchedulerPid testing
  stateMachineProcess_ () () mscheduler clientSM

clientSM :: BankResponse -> StateMachine () () BankRequest BankRequest ()
clientSM _ = return ()

bankP :: Bool -> Process ()
bankP testing = do
  mscheduler <- Scheduler.getSchedulerPid testing
  stateMachineProcess_ () initModel mscheduler bankSM

bankSM :: BankRequest -> StateMachine () Model BankRequest BankResponse ()
bankSM req = do
  case req of
    OpenAccount acc    -> do
      bank <- get
      case M.lookup acc bank of
        Nothing -> do
          modify (M.insert acc 0)
          acc ! AccountCreated
        Just _ ->
          acc ! AccountAlreadyExists
    Deposit acc money  -> do
      modify (M.insertWith (\new old -> new + old) acc money)
      acc ! DepositMade
    Withdraw acc money -> do
      modify (M.insertWith (\new old -> old - new) acc money)
      acc ! WithdrawalMade
    CheckBalance acc   -> do
      bank <- get
      case M.lookup acc bank of
        Nothing  -> acc ! AccountDoesntExist
        Just bal -> acc ! Balance bal
    Transfer from money to -> do
      modify (M.insertWith (\new old -> old - new) from money)
      modify (M.insertWith (\new old -> new + old) to   money)
      from ! TransferMade

------------------------------------------------------------------------

setup :: Int -> Process ([ProcessId], ProcessId, ProcessId)
setup seed = do
  schedulerPid <- spawnLocal (schedulerP (SchedulerEnv next Bank.invariant)
                                (makeSchedulerState seed initModel))
  bankPid    <- spawnLocal (bankP   True)
  client1Pid <- spawnLocal (clientP True)
  client2Pid <- spawnLocal (clientP True)
  mapM_ (flip send (SchedulerPid schedulerPid)) [bankPid, client1Pid, client2Pid]
  return ([client1Pid, client2Pid], bankPid, schedulerPid)

prop_bank :: Int -> Property
prop_bank seed =
  forAllShrink (Bank.generator [True, False]) (shrinker initModel') $ \reqs -> monadicProcess $ do
    self <- lift getSelfPid
    ([client1Pid, client2Pid], bankPid, schedulerPid) <- lift (setup seed)
    lift $ send schedulerPid (SchedulerSupervisor self)
    lift $ send schedulerPid (SchedulerCount (length reqs * 2))

    let reqs' = map (fmap (\b -> if b then client1Pid else client2Pid)) reqs

    lift $ forM_ reqs' $ \req ->
      send schedulerPid (SchedulerRequest (fromPid req) req bankPid
                          :: SchedulerMessage BankRequest BankResponse)

    SchedulerHistory hist <- lift expect
      :: PropertyM Process (SchedulerHistory ProcessId BankRequest BankResponse)

    unless (linearisable next post initModel hist) $
      fail (prettyPrintHistoryProcessId hist)
