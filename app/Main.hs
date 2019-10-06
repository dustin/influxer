{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (async, cancel, link,
                                             mapConcurrently_, waitCatch,
                                             waitCatchSTM)
import           Control.Concurrent.STM     (STM, TVar, atomically, modifyTVar,
                                             newTVarIO, orElse, readTVar,
                                             registerDelay, retry, swapTVar)
import           Control.Exception          (SomeException, bracket, catch)
import           Control.Lens
import           Control.Monad              (forever, when)
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.List                  (intercalate)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, mapMaybe)
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
                                             connectURI, mqttConfig,
                                             normalDisconnect, publishq,
                                             subOptions, subscribe,
                                             waitForClient)
import           Network.MQTT.Topic         (match)
import           Network.URI                (URI, parseURI)
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, maybeReader,
                                             option, progDesc, short,
                                             showDefault, strOption, switch,
                                             value, (<**>))
import           System.Log.Logger          (Priority (DEBUG, INFO), debugM,
                                             errorM, infoM, rootLoggerName,
                                             setLevel, updateGlobalLogger)
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
  , optVerbose    :: Bool
  , optMQTTURL    :: URI
  , optMQTTPrefix :: Topic
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbhost" <> showDefault <> value "localhost" <> help "influxdb host")
  <*> strOption (long "dbname" <> showDefault <> value "influxer" <> help "influxdb database")
  <*> strOption (long "conf" <> showDefault <> value "influx.conf" <> help "config file")
  <*> strOption (long "spool" <> showDefault <> value "influx.spool" <> help "spool file to store failed influxing")
  <*> switch (long "mqtt5" <> short '5' <> help "Use MQTT5 by default")
  <*> switch (long "clean" <> short 'c' <> help "Use a clean sesssion by default")
  <*> switch (long "verbose" <> short 'v' <> help "Log more stuff")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-prefix" <> showDefault <> value "tmp/influxer/" <> help "MQTT topic prefix")

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

logInfo :: String -> IO ()
logInfo = infoM rootLoggerName

logDebug :: String -> IO ()
logDebug = debugM rootLoggerName

seconds :: Int -> Int
seconds = (* 1000000)

delaySeconds :: Int -> IO ()
delaySeconds = threadDelay . seconds

supervise :: String -> IO a -> IO (Either SomeException a)
supervise name f = do
  p <- async f
  v <- registerDelay (seconds 20)
  mt <- atomically $ (Just <$> waitCatchSTM p) `orElse` checkTimeout v

  case mt of
    Nothing -> do
      logErr $ mconcat ["timed out waiting for supervised job '", name, "'... will continue waiting"]
      rv <- waitCatch p
      logErr $ mconcat ["supervised task '", name, "' finally finished"]
      pure rv
    Just x -> pure x

  where
    checkTimeout :: TVar Bool -> STM (Maybe a)
    checkTimeout v = do
      v' <- readTVar v
      when (not v') retry
      pure Nothing

type MQTTCB = MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()
data HandleContext = HandleContext {
  counter :: TVar Int
  , wp    :: WriteParams
  , spool :: Spool
  , ws    :: [Watch]
  }

handle :: HandleContext -> MQTTCB
handle HandleContext{..} _ t v _ =  do
  logDebug $ mconcat ["Processing topic ", show t]
  x <- supervise (unpack t) handle'
  case x of
    Left e  -> logErr $ mconcat ["error on supervised handler for ", unpack t, ": ", show e]
    Right _ -> plusplus counter

  where
    handle' = do
      ts <- getCurrentTime
      case extract ts $ foldr (\(Watch _ _ p e) o -> if p `match` t then e else o) undefined ws of
        Left "ignored" -> pure ()
        Left x -> logErr $ mconcat ["error on ", unpack t, " -> ", show v, ": " , x]
        Right l -> do
          exc <- deadlined (seconds 15) (tryWrite l)
          case exc of
            Just excuse -> do
              logErr $ mconcat ["influx error on ", unpack t, " -> ", show v, ": ", (intercalate " " . lines) excuse]
              insertSpool spool ts excuse l
            Nothing     -> pure ()

    plusplus :: TVar Int -> IO ()
    plusplus tv = atomically $ modifyTVar tv succ

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


prot :: Bool -> ProtocolLevel
prot True  = Protocol50
prot False = Protocol311

runWatcher :: WriteParams -> Spool -> Bool -> Bool -> Source -> IO ()
runWatcher wp spool p5 clean (Source uri watchers) = do
  counter <- newTVarIO 0
  mc <- connectURI mqttConfig{_msgCB=SimpleCallback $ handle (HandleContext counter wp spool watchers),
                              _protocol=prot p5, _cleanSession=clean,
                              _connProps=[PropSessionExpiryInterval 3600]} uri
  let tosub = [(t,subOptions{_subQoS=q qos}) | (Watch qos w t _) <- watchers, w]
  (subrv,_) <- subscribe mc tosub mempty
  logInfo $ "Subscribed: " <> (intercalate ", " . map (\((t,_),r) -> show t <> "@" <> s r) $ zip tosub subrv)
  l <- async $ periodicallyLog counter
  logErr . show =<< waitForClient mc
  cancel l

  where
    s = either show show

    q QOS0 = QoS0
    q QOS1 = QoS1
    q QOS2 = QoS2

    periodicallyLog v = forever $ do
      delaySeconds 60
      v' <- atomically $ swapTVar v 0
      logInfo $ mconcat ["Processed ", show v', " messages from ", show uri]

runReporter :: Options -> Spool -> IO ()
runReporter Options{..} spool = forever $ do
  catch (bracket connto normalDisconnect loop) (\e -> logErr $ mconcat ["connecting to ",
                                                                        show optMQTTURL, " - ",
                                                                        show (e :: SomeException)])
  delaySeconds 5

  where
    connto = connectURI mqttConfig{_protocol=prot optV5, _cleanSession=True, _connProps=[]} optMQTTURL

    loop mc = forever $ do
      delaySeconds 60
      c <- count spool
      publishq mc (optMQTTPrefix <> "spool") (BC.pack $ show c) True QoS1 [PropMessageExpiryInterval 120]

run :: Options -> IO ()
run opts@Options{..} = do
  updateGlobalLogger rootLoggerName (setLevel $ if optVerbose then DEBUG else INFO)

  (InfluxerConf srcs) <- parseConfFile optConfFile
  let wp = writeParams (fromString optInfluxDB) & server.host .~ optInfluxDBHost
  spool <- newSpool wp optSpoolFile
  async (runReporter opts spool) >>= link
  mapConcurrently_ (runWatcher wp spool optV5 optClean) srcs

main :: IO ()
main = do
  run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Influx the mqtt")
