{-# LANGUAGE OverloadedStrings #-}

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           InfluxerConf

testTopicMatching :: [TestTree]
testTopicMatching = let allTopics = ["a", "a/b", "a/b/c/d", "b/a/c/d"]
                        tsts = [("a", ["a"]), ("a/#", ["a/b", "a/b/c/d"]), ("+/b", ["a/b"]),
                                ("+/+/c/+", ["a/b/c/d", "b/a/c/d"])] in
    map (\(p,want) -> testCase (show p) $ assertEqual "" want (filter (topicMatches p) allTopics)) tsts

tests :: [TestTree]
tests = [
  testGroup "topic matching" testTopicMatching
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
