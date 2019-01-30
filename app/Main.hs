{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Lens
import           Control.Monad              (mapM_)
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Map                   (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (mapMaybe)
import           Data.Scientific            (floatingOrInteger, toRealFloat)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, unpack)
import           Data.Time                  (UTCTime)
import           Database.InfluxDB          (Field (..), Key, Line (..),
                                             LineField, WriteParams (..), host,
                                             server, write, writeParams)
import qualified JSONPointer                as JP
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..),
                                             QoS (..), Topic, connectURI,
                                             mqttConfig, subscribe,
                                             waitForClient)
import           Text.Read                  (readEither)

import           InfluxerConf

handle :: WriteParams -> [Watch] -> MQTTClient -> Topic -> BL.ByteString -> IO ()
handle wp ws _ t v = case extract $ foldr (\(Watch p e) o -> if topicMatches p t then e else o) undefined ws of
                       Left x  -> putStrLn $ mconcat ["error on ", unpack t, " -> ", show v, ": " , x]
                       Right l -> write wp l
  where
    extract :: Extractor -> Either String (Line UTCTime)
    extract Auto = case readEither (BC.unpack v) of
                     Left x  -> Left x
                     Right v -> Right $ Line (fk t) mempty (Map.singleton "value" (st v)) Nothing

    extract (JSON (JSONPExtractor pre pats)) = jsonate pre pats =<< eitherDecode v

    -- st = either FieldFloat FieldInt . floatingOrInteger
    st = FieldFloat . toRealFloat

    fk :: IsString k => Text -> k
    fk = fromString.unpack

    -- extract all the desired fields
    jsonate :: Text -> [(Text,Text)] -> Value -> Either String (Line UTCTime)
    jsonate m l ob = Right $ Line (fk m) mempty (Map.fromList $ mapMaybe j1 l) Nothing
      where
        j1 :: (Text,Text) -> Maybe (Key, LineField)
        j1 (tag, pstr) = let (Right p) = JP.unescape pstr in
                           case JP.resolve p ob of
                             Left l  -> Nothing
                             Right v -> (fk tag,) <$> jt v
        jt (Number x) = Just $ st x
        jt _          = Nothing

runWatcher :: WriteParams -> Source -> IO ()
runWatcher wp (Source uri watchers) = do
  mc <- connectURI mqttConfig{_connID="influxer", _msgCB=Just $ handle wp watchers} uri
  subrv <- subscribe mc [(t,QoS2) | (Watch t _) <- watchers]
  print subrv
  print =<< waitForClient mc

main :: IO ()
main = do
  (InfluxerConf srcs) <- parseConfFile "influx.conf"
  let wp = writeParams "influxer" & server.host .~ "localhost"
  mapConcurrently_ (runWatcher wp) srcs
