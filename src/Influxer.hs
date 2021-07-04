{-# LANGUAGE OverloadedStrings #-}

module Influxer where

import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Scientific            (toRealFloat)
import qualified Data.Text.Encoding         as TE
import           Database.InfluxDB          (Field (..), LineField)
import           Network.MQTT.Client        (QoS (..), SubOptions (..), subOptions)
import           Network.MQTT.Topic         (Filter, Topic, match)
import           Network.MQTT.Types         (RetainHandling (..))
import           Text.Read                  (readEither)


import           InfluxerConf

parseValue :: ValueParser -> BL.ByteString -> Either String LineField
parseValue AutoVal v    = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue FloatVal v   = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue IntVal v
  | '.' `BC.elem` v     = FieldInt . floor . toRealFloat <$> readEither (BC.unpack v)
  | otherwise           = FieldInt <$> readEither (BC.unpack v)
parseValue StringVal v  = (Right . FieldString . TE.decodeUtf8 . BL.toStrict) v
parseValue BoolVal v
  | v `elem` ["ON", "on", "true", "1"] = Right $ FieldBool True
  | otherwise = Right $ FieldBool False
parseValue IgnoreVal _  = Left "ignored"

bestMatch :: Topic -> [Watch] -> Extractor
bestMatch t = foldr exes IgnoreExtractor
  where
    exes (Watch _ p e) o = mf p e o
    exes (Match   p e) o = mf p e o
    mf p e o = if p `match` t then e else o

subs :: Source -> [(Filter, SubOptions)]
subs (Source _ ws) = [(t,baseOpts{_subQoS=q qos}) | (Watch qos t _) <- ws]
  where
    baseOpts = subOptions{_retainHandling=SendOnSubscribeNew}
    q QOS0 = QoS0
    q QOS1 = QoS1
    q QOS2 = QoS2
