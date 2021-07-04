{-# LANGUAGE OverloadedStrings #-}

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           Network.URI           (parseURI)

import           InfluxerConf

testParser :: Assertion
testParser = do
  cfg <- parseConfFile "test/test.conf"
  let (Just u) = parseURI "mqtt://localhost/#influxerdev"
  assertEqual "" (InfluxerConf [Source u
                                [Watch QOS2 "oro/+/tele/SENSOR"
                                 (JSON (JSONPExtractor (FieldNum 1) [] [
                                           ("total","/ENERGY/Total",AutoVal),
                                           ("yesterday","/ENERGY/Yesterday",FloatVal),
                                           ("today","/ENERGY/Today",AutoVal),
                                           ("power","/ENERGY/Power",AutoVal),
                                           ("voltage","/ENERGY/Voltage",AutoVal),
                                           ("current","/ENERGY/Current",AutoVal)])),
                                 Match "sj/some/thing" (ValEx IgnoreVal [] (ConstName "value") (FieldNum 0)),
                                 Watch QOS1 "sj/#" (ValEx AutoVal [] (ConstName "value") (FieldNum 0))]])
    cfg

tests :: [TestTree]
tests = [
  testCase "example conf" testParser
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
