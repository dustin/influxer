{-# LANGUAGE OverloadedStrings #-}

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           InfluxerConf

tests :: [TestTree]
tests = []

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
