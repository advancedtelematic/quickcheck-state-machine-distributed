module Test where

import           Control.Exception
                   (evaluate)
import           System.Environment
                   (withArgs)
import           Test.Hspec
import           Test.Hspec.Core.QuickCheck
                   (modifyMaxSuccess)
import           Test.Hspec.Core.Runner
                   (Summary, hspecResult)
import           Test.QuickCheck
                   (property)

------------------------------------------------------------------------

tests :: Spec
tests = do
  describe "Prelude.head" $ do
    it "returns the first element of a list" $ do
      head [23 ..] `shouldBe` (23 :: Int)

    it "returns the first element of an *arbitrary* list" $
      property $ \x xs -> head (x:xs) == (x :: Int)

    it "throws an exception if used with an empty list" $ do
      evaluate (head []) `shouldThrow` anyException

  describe "reverse" $ do
    it "applied twice is identity" $
      property $ \xs -> (reverse . reverse) xs == (xs :: [Int])

runTests :: String -> IO Summary
runTests descr = withArgs ["--match=" ++ descr] $ hspecResult $ modifyMaxSuccess (const 100000) tests
