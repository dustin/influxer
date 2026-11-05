{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

import           Control.Exception
import           Control.Monad              (replicateM)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Foldable              (fold)
import           Data.List                  (isInfixOf)
import qualified Data.Text                  as T
import           Database.InfluxDB          (Field (..), LineField)
import qualified Hedgehog                   as HH
import qualified Hedgehog.Corpus            as HH
import qualified Hedgehog.Gen               as Gen
import qualified Hedgehog.Range             as Range
import           Network.MQTT.Arbitrary
import           Network.MQTT.Client        (QoS (..), SubOptions (..),
                                             subOptions)
import           Network.MQTT.Topic
import           Network.MQTT.Types         (RetainHandling (..))
import           Network.URI                (parseURI)
import           Text.Megaparsec            (errorBundlePretty, parse)
import qualified Test.QuickCheck            as QC
import           Test.QuickCheck            (Arbitrary (..), arbitrary,
                                             arbitraryBoundedEnum, suchThat)
import           Test.Tasty
import qualified Test.Tasty.Hedgehog        as HH
import           Test.Tasty.HUnit
import qualified Test.Tasty.QuickCheck      as QC

import           Influxer
import           InfluxerConf
import           LogStuff

testParser :: Assertion
testParser = do
  cfg@(InfluxerConf srcs) <- parseConfFile "test/test.conf"
  let (Just u) = parseURI "mqtt://localhost/#influxerdev"
      (Just u2) = parseURI "mqtt://localhost/#influxerstats"
  assertEqual "" (InfluxerConf [Source u Nothing
                                [Watch QOS2 "oro/+/tele/SENSOR"
                                 (JSON (JSONPExtractor (MeasurementNamer Nothing (FieldNum 1)) [] [
                                           ("total","/ENERGY/Total",AutoVal),
                                           ("yesterday","/ENERGY/Yesterday",FloatVal),
                                           ("today","/ENERGY/Today",AutoVal),
                                           ("power","/ENERGY/Power",AutoVal),
                                           ("voltage","/ENERGY/Voltage",AutoVal),
                                           ("current","/ENERGY/Current",AutoVal)])),
                                 Match "sj/some/thing" (ValEx IgnoreVal [] (ConstName "value")
                                                         (MeasurementNamer Nothing (FieldNum 0))),
                                 Watch QOS0 "oro/something" (ValEx IntVal [("tag1",ConstName "a"),
                                                                           ("tag2",FieldNum 2)]
                                                             (ConstName "aval")
                                                             (MeasurementNamer Nothing (ConstName "amess"))),
                                 Watch QOS0 "oro/s/blah" (ValEx IntVal [("tag1",ConstName "a"),
                                                                        ("tag2",FieldNum 2)]
                                                           (ConstName "aval")
                                                           (MeasurementNamer (Just "short") (ConstName "amess"))),
                                 Watch QOS2 "oro/boo" (ValEx BoolVal [("tag1",ConstName "a")]
                                                       (ConstName "value")
                                                       (MeasurementNamer Nothing (FieldNum 0))),
                                 Match "oro/str" (ValEx StringVal [] (ConstName "value")
                                                   (MeasurementNamer Nothing ((FieldNum 0)))),
                                 Watch QOS1 "sj/#" (ValEx AutoVal [] (ConstName "value")
                                                                     (MeasurementNamer Nothing (FieldNum 0)))],
                                Source u2 (Just "some/prefix")
                                [Match "a/b" (ValEx AutoVal [] (ConstName "value")
                                               (MeasurementNamer Nothing (FieldNum 0)))]])
    cfg

  let ss = foldMap subs srcs
      baseOpts = subOptions{_retainHandling=SendOnSubscribeNew}
  assertEqual "" [("oro/+/tele/SENSOR", baseOpts {_subQoS = QoS2}),
                  ("oro/something", baseOpts{_subQoS = QoS0}),
                  ("oro/s/blah", baseOpts{_subQoS = QoS0}),
                  ("oro/boo", baseOpts{_subQoS = QoS2}),
                  ("sj/#", baseOpts {_subQoS = QoS1})] ss

testTrailing :: Assertion
testTrailing = do
  try (parseConfFile "test/trailing.conf") >>= \case
    Left (_ :: IOException) -> pure ()
    Right c -> assertFailure ("parsed: " <> show c)

testBadStatsPrefix :: Assertion
testBadStatsPrefix =
  case parse parseInfluxerConf "test" "from mqtt://localhost/ stats \"a/+\" { watch \"x\" auto }" of
    Left e  -> assertBool (errorBundlePretty e) ("bad stats prefix" `isInfixOf` errorBundlePretty e)
    Right c -> assertFailure ("parsed: " <> show c)

testSelfConsumedStats :: Assertion
testSelfConsumedStats = do
  rejected "catch-all" "s/processed" "watch \"#\" auto"
  rejected "under the prefix" "s/processed, s/batch" "watch \"s/#\" int"
  rejected "just the batch" "s/batch" "watch \"s/batch\" int"
  rejected "retention batch" "s/batch/weekly" "watch \"s/batch/+\" int measurement=\"weekly\".\"m\""
  rejected "broader than a match" "s/processed" "match \"s/batch\" ignore watch \"#\" auto"
  allowed "elsewhere" "watch \"home/#\" auto"
  allowed "ignored" "watch \"#\" ignore"
  allowed "ignored first" "match \"s/#\" ignore watch \"#\" auto"
  allowed "not subscribed" "match \"#\" auto watch \"home/#\" ignore"
  allowed "not a batch we report" "watch \"s/batch/other\" auto"

  where
    conf ws = "from mqtt://localhost/ stats \"s\" { " <> ws <> " }"
    rejected l t ws = case parse parseInfluxerConf "test" (conf ws) of
      Left e  -> assertBool (l <> ": " <> errorBundlePretty e)
                 (("consume its own stats on: " <> t) `isInfixOf` errorBundlePretty e)
      Right c -> assertFailure (l <> " parsed: " <> show c)
    allowed l ws = case parse parseInfluxerConf "test" (conf ws) of
      Left e  -> assertFailure (l <> ": " <> errorBundlePretty e)
      Right _ -> pure ()

testStatTopics :: Assertion
testStatTopics = do
  assertEqual "" "some/prefix/processed" (unTopic (processedTopic "some/prefix"))
  assertEqual "" (Just "some/prefix/batch") (unTopic <$> batchTopic "some/prefix" Nothing)
  assertEqual "" (Just "some/prefix/batch/weekly") (unTopic <$> batchTopic "some/prefix" (Just "weekly"))
  assertEqual "" Nothing (unTopic <$> batchTopic "some/prefix" (Just "a+b"))

data MatchInput = MatchInput Extractor Topic [Watch] deriving (Show, Eq)

instance Arbitrary MatchInput where
  arbitrary = do
    MatchingTopic (t, fs) <- arbitrary
    before <- QC.listOf (notMatching t)
    after <- arbitrary
    watchfun <- QC.infiniteListOf cons
    let allWatches = zipWith3 id watchfun (before <> fs <> after) extractors
        want = head $ drop (length before) extractors
    pure $ MatchInput want t allWatches

      where
        cons = QC.oneof [Watch <$> arbitraryBoundedEnum, pure Match]
        extractors = [ValEx AutoVal [] (FieldNum i) (MeasurementNamer Nothing (FieldNum i)) | i <- [0..]]
        notMatching t = arbitrary `suchThat` (not . (`match` t))

  shrink (MatchInput a t xs) = MatchInput a t <$> QC.shrinkList (const []) xs

propBestMatch :: MatchInput -> QC.Property
propBestMatch (MatchInput e t ws) = bestMatch t ws QC.=== e

data ParseInput = ParseInput String (Either String LineField) ValueParser BL.ByteString
  deriving (Eq, Show)

instance Arbitrary ParseInput where
  arbitrary = QC.oneof [ autoCase, floatCase, intiCase, intfCase, stringCase, trueCase, falseCase, ignoreCase ]
    where
      autoCase = do
        v <- arbitrary
        pure $ ParseInput "auto" (Right (FieldFloat v)) AutoVal (BC.pack . show $ v)
      floatCase = do
        v <- arbitrary
        pure $ ParseInput "float" (Right (FieldFloat v)) FloatVal (BC.pack . show $ v)
      intiCase = do
        v <- arbitrary
        pure $ ParseInput "int(i)" (Right (FieldInt v)) IntVal (BC.pack . show $ v)
      intfCase = do
        v <- QC.choose (-100000, 100000)
        pure $ ParseInput "int(f)" (Right (FieldInt v)) IntVal (BC.pack . (<>".0") . show $ v)
      stringCase = do
        str <- QC.listOf (QC.elements ['a'..'z'])
        pure $ ParseInput "str" (Right (FieldString (T.pack str))) StringVal (BC.pack str)
      -- bool cases
      yeses = ["ON", "on", "true", "1"]
      trueCase = ParseInput "bool(true)" (Right (FieldBool True)) BoolVal <$> QC.elements yeses
      falseCase = ParseInput "bool(false)" (Right (FieldBool False)) BoolVal <$> (BC.pack <$> arbitrary) `suchThat` (`notElem` yeses)
      ignoreCase = pure $ ParseInput "ignore" (Left "ignored") IgnoreVal "whatever"

propParseValue :: ParseInput -> QC.Property
propParseValue (ParseInput l f v b) = QC.label l $ parseValue v b QC.=== f

genSpaceyString :: Char -> HH.Gen String
genSpaceyString c = do
  nums <- Gen.list (Range.linear 1 5) (Gen.int $ Range.linear 1 5)
  let spaces = (`replicate` c) <$> nums
  stuff <- replicateM (length spaces + 1) (Gen.element HH.glass)
  pure . fold $ zipWith (<>) stuff ("":spaces)

propDeLine :: HH.Property
propDeLine = HH.property $ do
  ss <- HH.forAll (genSpaceyString '\n')
  let dl = deLine ss
  HH.assert (not (isInfixOf "  " dl))
  HH.assert (not (elem '\n' dl))

tests :: [TestTree]
tests = [
  testCase "example conf" testParser,
  testCase "broken trailing conf" testTrailing,
  testCase "bad stats prefix" testBadStatsPrefix,
  testCase "stat topics" testStatTopics,
  testCase "self-consumed stats" testSelfConsumedStats,
  QC.testProperty "best match" propBestMatch,
  QC.testProperty "parseValue" propParseValue,
  HH.testProperty "newlines are sufficiently eaten" propDeLine
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
