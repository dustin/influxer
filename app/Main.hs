{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Exception          (IOException, catch)
import           Control.Lens
import           Control.Monad              (mapM_)
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Map                   (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (mapMaybe)
import           Data.Scientific            (toRealFloat)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, unpack)
import           Data.Time                  (UTCTime)
import           Database.InfluxDB          (Field (..), InfluxException (..),
                                             Key, Line (..), LineField,
                                             WriteParams (..), host, server,
                                             write, writeParams)
import qualified JSONPointer                as JP
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..),
                                             QoS (..), Topic, connectURI,
                                             mqttConfig, subscribe,
                                             waitForClient)
import           Text.Read                  (readEither)

import           InfluxerConf

parseValue :: ValueParser -> BL.ByteString -> Either String LineField
parseValue AutoVal v  = FieldFloat . toRealFloat <$> (readEither $ BC.unpack v)
parseValue FloatVal v = FieldFloat . toRealFloat <$> (readEither $ BC.unpack v)
parseValue IntVal v   = FieldInt . floor . toRealFloat <$> (readEither $ BC.unpack v)
parseValue BoolVal v
  | v `elem` ["ON", "on", "true", "1"] = Right $ FieldBool True
  | otherwise = Right $ FieldBool False
parseValue IgnoreVal _ = Left "ignored"

handle :: WriteParams -> [Watch] -> MQTTClient -> Topic -> BL.ByteString -> IO ()
handle wp ws _ t v = case extract $ foldr (\(Watch p e) o -> if topicMatches p t then e else o) undefined ws of
                       Left "ignored" -> pure ()
                       Left x -> putStrLn $ mconcat ["error on ", unpack t, " -> ", show v, ": " , x]
                       Right l -> catch (write wp l)
                                  (\e -> putStrLn $ mconcat ["error on ", unpack t, " -> ", show v, ": " ,
                                                             show (e :: InfluxException)])
  where
    extract :: Extractor -> Either String (Line UTCTime)
    extract (ValEx vp) = case parseValue vp v of
                                Left x  -> Left x
                                Right v' -> Right $ Line (fk t) mempty (Map.singleton "value" v') Nothing

    extract (JSON (JSONPExtractor pre pats)) = jsonate pre pats =<< eitherDecode v

    fk :: IsString k => Text -> k
    fk = fromString.unpack

    -- extract all the desired fields
    jsonate :: Text -> [(Text,Text,ValueParser)] -> Value -> Either String (Line UTCTime)
    jsonate m l ob = Right $ Line (fk m) mempty (Map.fromList $ mapMaybe j1 l) Nothing
      where
        j1 :: (Text,Text,ValueParser) -> Maybe (Key, LineField)
        j1 (tag, pstr, vp) = let (Right p) = JP.unescape pstr in
                               case JP.resolve p ob of
                                 Left l  -> Nothing
                                 Right v -> (fk tag,) <$> jt vp v

        jt FloatVal (Number x) = Just $ FieldFloat . toRealFloat $ x
        jt AutoVal (Number x)  = Just $ FieldFloat . toRealFloat $ x
        jt AutoVal (Bool x)    = Just $ FieldBool x
        jt IntVal (Number x)   = Just $ FieldInt . floor . toRealFloat $ x
        jt BoolVal (Bool x)    = Just $ FieldBool x
        jt _ _                 = Nothing

runWatcher :: WriteParams -> Source -> IO ()
runWatcher wp (Source uri watchers) = do
  mc <- connectURI mqttConfig{_connID="influxer", _msgCB=Just $ handle wp watchers} uri
  subrv <- subscribe mc [(t,QoS2) | (Watch t _) <- watchers]
  print subrv
  print =<< waitForClient mc

main :: IO ()
main = do
  -- TODO: flags
  (InfluxerConf srcs) <- parseConfFile "influx.conf"
  let wp = writeParams "influxer" & server.host .~ "localhost"
  mapConcurrently_ (runWatcher wp) srcs
