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
import           Data.Text                  (Text, unpack)
import qualified Data.Text.Encoding         as TE
import           Data.Time                  (UTCTime, getCurrentTime)
import           Database.InfluxDB          (Field (..), InfluxException (..),
                                             Key, Line (..), LineField,
                                             WriteParams, host, server, write,
                                             writeParams)
import qualified JSONPointer                as JP
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..),
                                             QoS (..), Topic, connectURI,
                                             mqttConfig, subscribe,
                                             waitForClient)
import           Network.URI                (uriFragment)
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, progDesc,
                                             showDefault, strOption, value,
                                             (<**>))
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
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbhost" <> showDefault <> value "localhost" <> help "influxdb host")
  <*> strOption (long "dbname" <> showDefault <> value "influxer" <> help "influxdb database")
  <*> strOption (long "conf" <> showDefault <> value "influx.conf" <> help "config file")
  <*> strOption (long "spool" <> showDefault <> value "influx.spool" <> help "spool file to store failed influxing")

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

handle :: WriteParams -> Spool -> [Watch] -> MQTTClient -> Topic -> BL.ByteString -> IO ()
handle wp spool ws _ t v = do
  ts <- getCurrentTime
  case extract ts $ foldr (\(Watch _ p e) o -> if topicMatches p t then e else o) undefined ws of
    Left "ignored" -> pure ()
    Left x -> logErr $ mconcat ["error on ", unpack t, " -> ", show v, ": " , x]
    Right l -> do
      exc <- deadlined 15000000 (tryWrite l)
      case exc of
        Just excuse -> do
          logErr $ mconcat ["influx error on ", unpack t, " -> ", show v, ": ", excuse]
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
    extract ts (ValEx vp) = case parseValue vp v of
                              Left x  -> Left x
                              Right v' -> Right $ Line (fk t) mempty (Map.singleton "value" v') (Just ts)

    extract ts (JSON (JSONPExtractor m pats)) = jsonate ts m pats =<< eitherDecode v

    fk :: IsString k => Text -> k
    fk = fromString.unpack

    -- extract all the desired fields
    jsonate :: UTCTime -> Text -> [(Text,Text,ValueParser)] -> Value -> Either String (Line UTCTime)
    jsonate ts m l ob = case mapMaybe j1 l of
                          [] -> Left "I've got no values"
                          vs -> Right $ Line (fk m) mempty (Map.fromList vs) (Just ts)
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

runWatcher :: WriteParams -> Spool -> Source -> IO ()
runWatcher wp spool (Source uri watchers) = do
  mc <- connectURI mqttConfig{_connID=cid (uriFragment uri), _msgCB=Just $ handle wp spool watchers} uri
  let tosub = [(t,QoS2) | (Watch w t _) <- watchers, w]
  subrv <- subscribe mc tosub
  infoM rootLoggerName $ "Subscribed: " <> (intercalate ", " . map (\((t,_),r) -> show t <> "@" <> maybe "ERR" show r) $ zip tosub subrv)
  logErr . show =<< waitForClient mc

  where
    cid ['#']    = "influxer"
    cid ('#':xs) = xs
    cid _        = "influxer"

run :: Options -> IO ()
run Options{..} = do
  (InfluxerConf srcs) <- parseConfFile optConfFile
  let wp = writeParams (fromString optInfluxDB) & server.host .~ optInfluxDBHost
  spool <- newSpool wp optSpoolFile
  mapConcurrently_ (runWatcher wp spool) srcs

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)

  run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Influx the mqtt")
