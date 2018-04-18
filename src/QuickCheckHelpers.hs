module QuickCheckHelpers
  ( generateRequests
  , shrinkRequests
  , monadicProcess
  )
  where

import           Control.Distributed.Process
                   (Process)
import           Test.QuickCheck
                   (Gen, Property, Testable, choose, shrinkList, sized,
                   suchThat, ioProperty)
import           Test.QuickCheck.Monadic
                   (PropertyM, monadic)

import           Utils

------------------------------------------------------------------------

generateRequests
  :: (model -> Gen req)
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> Gen [req]
generateRequests generator preconditions transitions model0 = do
  size0 <- sized (\k -> choose (0, k))
  go size0 model0
  where
  go 0    _     = return []
  go size model = do
    msg <- generator model `suchThat` preconditions model
    (msg :) <$> go (size - 1) (transitions model (Left msg))

shrinkRequests
  :: (model -> req -> [req])
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> [req] -> [[req]]
shrinkRequests shrinker preconditions transitions model0
  = filter (valid model0)
  . shrinkList (shrinker model0)
  where
    valid _     []           = True
    valid model (req : reqs) = preconditions model req &&
                               valid (transitions model (Left req)) reqs

monadicProcess :: Testable a => PropertyM Process a -> Property
monadicProcess = monadic (ioProperty . runLocalProcess)
