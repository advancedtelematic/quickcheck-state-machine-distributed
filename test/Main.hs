module Main where

import           Test.Tasty
import Test.Tasty.QuickCheck 

import           Bank
                   (prop_bank)
import           TicketDispenser
                   (prop_ticketDispenser, prop_ticketDispenserParallel)

------------------------------------------------------------------------

main :: IO ()
main = defaultMain $ testGroup "Properties"
  [ testGroup "Ticket dispenser"
    [ testProperty "sequential" prop_ticketDispenser
    , testProperty "parallel"   prop_ticketDispenserParallel
    ]
  , testGroup "Bank"
    [ testProperty "sequential" prop_bank ]
  ]
