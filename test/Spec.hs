{-# LANGUAGE OverloadedStrings #-}

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           Network.MQTT.Client   (QoS (..), SubOptions (..), subOptions)
import           Network.MQTT.Types    (RetainHandling (..))
import           Network.URI           (parseURI)

import           Influxer
import           InfluxerConf

testParser :: Assertion
testParser = do
  cfg@(InfluxerConf srcs) <- parseConfFile "test/test.conf"
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

  let ss = foldMap subs srcs
      baseOpts = subOptions{_retainHandling=SendOnSubscribeNew}
  assertEqual "" [("oro/+/tele/SENSOR", baseOpts {_subQoS = QoS2}),
                  ("sj/#", baseOpts {_subQoS = QoS1})] ss

tests :: [TestTree]
tests = [
  testCase "example conf" testParser
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
