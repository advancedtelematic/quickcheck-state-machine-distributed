module Main where

import           Control.Distributed.Process.Backend.SimpleLocalnet
                   (initializeBackend, startMaster, startSlave)
import           Control.Distributed.Process.Node
                   (initRemoteTable)
import           System.Environment
                   (getArgs)

import           Lib

------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs

  case args of
    ["master", host, port] -> do
      backend <- initializeBackend host port initRemoteTable
      startMaster backend (master backend)
    ["slave", host, port] -> do
      backend <- initializeBackend host port initRemoteTable
      startSlave backend
