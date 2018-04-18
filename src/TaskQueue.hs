{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}

module TaskQueue where

import           Data.Binary
                   (Binary)
import           Data.Monoid
                   ((<>))
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)

------------------------------------------------------------------------

newtype Enqueue a = Enqueue [a]
newtype Dequeue a = Dequeue [a]

data Queue a = Queue (Enqueue a) (Dequeue a)

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

newtype TaskId = TaskId Integer
  deriving (Typeable, Generic, Show)

instance Binary TaskId

data Task a = Task TaskId a
  deriving (Typeable, Generic)

instance Binary a => Binary (Task a)

data TaskResult a =
    TaskSuccess TaskId a
  | TaskFailure TaskId a
  deriving (Generic, Typeable)

taskId :: TaskResult a -> TaskId
taskId (TaskSuccess id' _) = id'
taskId (TaskFailure id' _) = id'

data TaskSummary a = TaskSummary [TaskResult a]
  deriving (Generic, Typeable)

instance Monoid (TaskSummary a) where
  mempty = TaskSummary mempty
  TaskSummary lhs `mappend` TaskSummary rhs = TaskSummary $ lhs <> rhs

instance Binary a => Binary (TaskResult a)
