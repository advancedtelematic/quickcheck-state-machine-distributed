{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           System.Environment
                   (getArgs, getProgName)
import           System.Exit
                   (exitFailure, exitSuccess)
import           System.Random
                   (randomIO)
import           Test.QuickCheck
                   (verboseCheckWith, stdArgs, maxSuccess)
import           Text.Read
                   (readMaybe)

import qualified Bank

------------------------------------------------------------------------

usage :: IO a
usage = do
  prog <- getProgName
  putStrLn $ "usage: " ++ prog ++ " bank (integer | random)"
  exitFailure

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["bank", mseed] -> do
      seed <- case mseed of
        "random" -> randomIO
        mint     -> case readMaybe mint of
          Nothing  -> usage
          Just int -> return int
      verboseCheckWith stdArgs { maxSuccess = 200 } (Bank.prop_bank seed)
      exitSuccess
    _ -> usage
