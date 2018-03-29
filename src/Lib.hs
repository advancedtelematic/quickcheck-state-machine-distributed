module Lib
    ( master
    ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Backend.SimpleLocalnet
                   (Backend, terminateAllSlaves)

------------------------------------------------------------------------

master :: Backend -> [NodeId] -> Process ()
master backend slaves = do
  liftIO . putStrLn $ "Slaves: " ++ show slaves
  terminateAllSlaves backend
