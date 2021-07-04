{-# LANGUAGE OverloadedStrings #-}

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           Network.MQTT.Client   (QoS (..), SubOptions (..), subOptions)
import           Network.MQTT.Types    (RetainHandling (..))
import           Network.MQTT.Topic
import qualified Data.Text as T
import           Network.URI           (parseURI)
import           Network.MQTT.Arbitrary

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

data MatchInput = MatchInput Extractor Topic [Watch] deriving (Show, Eq)

instance Arbitrary MatchInput where
  arbitrary = do
    MatchingTopic (t, fs) <- arbitrary
    before <- listOf (notMatching t)
    after <- arbitrary
    watchfun <- infiniteListOf cons
    let allWatches = zipWith3 id watchfun (before <> fs <> after) extractors
        want = head $ drop (length before) extractors
    pure $ MatchInput want t allWatches

      where
        cons = oneof [Watch <$> arbitraryBoundedEnum, pure Match]
        extractors = [ValEx AutoVal [] (FieldNum i) (FieldNum i) | i <- [0..]]
        notMatching t = arbitrary `suchThat` (not . (`match` t))

  shrink (MatchInput a t xs) = MatchInput a t <$> shrinkList (const []) xs

propBestMatch :: MatchInput -> Property
propBestMatch (MatchInput e t ws) = bestMatch t ws === e

tests :: [TestTree]
tests = [
  testCase "example conf" testParser,
  testProperty "best match" propBestMatch
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
