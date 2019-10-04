{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Exception          (catch)
import           Control.Lens
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.List                  (intercalate)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (mapMaybe)
import           Data.Scientific            (toRealFloat)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, splitOn, unpack)
import qualified Data.Text.Encoding         as TE
import           Data.Time                  (UTCTime, getCurrentTime)
import           Database.InfluxDB          (Field (..), InfluxException (..),
                                             Key, Line (..), LineField,
                                             WriteParams, host, server, write,
                                             writeParams)
import qualified JSONPointer                as JP
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..),
                                             MessageCallback (..),
                                             Property (..), ProtocolLevel (..),
                                             QoS (..), SubOptions (..), Topic,
                                             connectURI, mqttConfig, subOptions,
                                             subscribe, waitForClient)
import           Network.MQTT.Topic         (match)
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, progDesc,
                                             short, showDefault, strOption,
                                             switch, value, (<**>))
import           System.Log.Logger          (Priority (INFO), errorM, infoM,
                                             rootLoggerName, setLevel,
                                             updateGlobalLogger)
import           System.Timeout             (timeout)
import           Text.Read                  (readEither)

import           InfluxerConf
import           Spool

data Options = Options {
  optInfluxDBHost :: Text
  , optInfluxDB   :: String
  , optConfFile   :: String
  , optSpoolFile  :: String
  , optV5         :: Bool
  , optClean      :: Bool
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbhost" <> showDefault <> value "localhost" <> help "influxdb host")
  <*> strOption (long "dbname" <> showDefault <> value "influxer" <> help "influxdb database")
  <*> strOption (long "conf" <> showDefault <> value "influx.conf" <> help "config file")
  <*> strOption (long "spool" <> showDefault <> value "influx.spool" <> help "spool file to store failed influxing")
  <*> switch (long "mqtt5" <> short '5' <> help "Use MQTT5 by default")
  <*> switch (long "clean" <> short 'c' <> help "Use a clean sesssion by default")

parseValue :: ValueParser -> BL.ByteString -> Either String LineField
parseValue AutoVal v    = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue FloatVal v   = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue IntVal v     = FieldInt . floor . toRealFloat <$> readEither (BC.unpack v)
parseValue StringVal v  = (Right . FieldString . TE.decodeUtf8 . BL.toStrict) v
parseValue BoolVal v
  | v `elem` ["ON", "on", "true", "1"] = Right $ FieldBool True
  | otherwise = Right $ FieldBool False
parseValue IgnoreVal _  = Left "ignored"

logErr :: String -> IO ()
logErr = errorM rootLoggerName

handle :: WriteParams -> Spool -> [Watch] -> MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()
handle wp spool ws _ t v _ = do
  ts <- getCurrentTime
  case extract ts $ foldr (\(Watch _ p e) o -> if p `match` t then e else o) undefined ws of
    Left "ignored" -> pure ()
    Left x -> logErr $ mconcat ["error on ", unpack t, " -> ", show v, ": " , x]
    Right l -> do
      exc <- deadlined 15000000 (tryWrite l)
      case exc of
        Just excuse -> do
          logErr $ mconcat ["influx error on ", unpack t, " -> ", show v, ": ", (intercalate " " . lines) excuse]
          insertSpool spool ts excuse l
        Nothing     -> pure ()

  where
    deadlined :: Int -> IO (Maybe String) -> IO (Maybe String)
    deadlined n a = do
      tod <- timeout n a
      case tod of
               Nothing -> pure $ Just "timed out"
               Just x  -> pure x

    tryWrite :: Line UTCTime -> IO (Maybe String)
    tryWrite l = catch (Nothing <$ write wp l) (\e -> pure $ Just (show (e :: InfluxException)))

    extract :: UTCTime -> Extractor -> Either String (Line UTCTime)
    extract ts (ValEx vp tags fld mn) = case parseValue vp v of
                              Left x  -> Left x
                              Right v' -> Right $ Line (fk . mname $ mn) (Map.fromList $ mvals <$> tags)
                                          (Map.singleton (fk $ mname fld) v') (Just ts)

    extract ts (JSON (JSONPExtractor m tags pats)) = jsonate ts (mname m) (mvals <$> tags) pats =<< eitherDecode v

    mname :: MeasurementNamer -> Text
    mname (ConstName t') = t'
    mname (FieldNum 0)   = t
    mname (FieldNum x)   = (splitOn "/" t) !! (x-1)

    mvals :: (Text, MeasurementNamer) -> (Key, Key)
    mvals (a,m) = (fk a, fk . mname $ m)

    fk :: IsString k => Text -> k
    fk = fromString.unpack

    -- extract all the desired fields
    jsonate :: UTCTime -> Text -> [(Key,Key)] -> [(Text,Text,ValueParser)] -> Value -> Either String (Line UTCTime)
    jsonate ts m tags l ob = case mapMaybe j1 l of
                          [] -> Left "I've got no values"
                          vs -> Right $ Line (fk m) (Map.fromList tags) (Map.fromList vs) (Just ts)
      where
        j1 :: (Text,Text,ValueParser) -> Maybe (Key, LineField)
        j1 (tag, pstr, vp) = let (Right p) = JP.unescape pstr in
                               case JP.resolve p ob of
                                 Left _   -> Nothing
                                 Right v' -> (fk tag,) <$> jt vp v'

        jt FloatVal (Number x)  = Just $ FieldFloat . toRealFloat $ x
        jt AutoVal (Number x)   = Just $ FieldFloat . toRealFloat $ x
        jt AutoVal (Bool x)     = Just $ FieldBool x
        jt IntVal (Number x)    = Just $ FieldInt . floor . toRealFloat $ x
        jt BoolVal (Bool x)     = Just $ FieldBool x
        jt StringVal (String x) = Just $ FieldString x
        jt _ _                  = Nothing

runWatcher :: WriteParams -> Spool -> Bool -> Bool -> Source -> IO ()
runWatcher wp spool p5 clean (Source uri watchers) = do
  mc <- connectURI mqttConfig{_msgCB=SimpleCallback $ handle wp spool watchers,
                              _protocol=prot p5, _cleanSession=clean,
                              _connProps=[PropSessionExpiryInterval 3600]} uri
  let tosub = [(t,subOptions{_subQoS=QoS2}) | (Watch w t _) <- watchers, w]
  (subrv,_) <- subscribe mc tosub mempty
  infoM rootLoggerName $ "Subscribed: " <> (intercalate ", " . map (\((t,_),r) -> show t <> "@" <> s r) $ zip tosub subrv)
  logErr . show =<< waitForClient mc

  where
    s = either show show
    prot True  = Protocol50
    prot False = Protocol311

run :: Options -> IO ()
run Options{..} = do
  (InfluxerConf srcs) <- parseConfFile optConfFile
  let wp = writeParams (fromString optInfluxDB) & server.host .~ optInfluxDBHost
  spool <- newSpool wp optSpoolFile
  mapConcurrently_ (runWatcher wp spool optV5 optClean) srcs

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)

  run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Influx the mqtt")
