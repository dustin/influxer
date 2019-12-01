{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (STM, TVar, atomically, modifyTVar,
                                             newTVarIO, orElse, readTVar,
                                             registerDelay, retry, swapTVar)
import           Control.Lens
import           Control.Monad              (forever, when)
import           Control.Monad.Catch        (SomeException, bracket, catch)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.IO.Unlift    (withRunInIO)
import           Control.Monad.Logger       (LogLevel (..), LoggingT,
                                             MonadLogger, filterLogger,
                                             logWithoutLoc, runStderrLoggingT)
import           Control.Monad.Reader       (ReaderT (..), ask, asks,
                                             runReaderT)
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.List                  (intercalate)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, fromMaybe, mapMaybe)
import           Data.Scientific            (toRealFloat)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, pack, splitOn, unpack)
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
                                             subOptions, subscribe, svrProps,
                                             waitForClient)
import           Network.MQTT.Topic         (match)
import           Network.MQTT.Types         (PublishRequest (..),
                                             RetainHandling (..))
import           Network.URI                (URI, parseURI)
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, maybeReader,
                                             option, progDesc, short,
                                             showDefault, strOption, switch,
                                             value, (<**>))
import           Text.Read                  (readEither)
import           UnliftIO.Async             (async, link, mapConcurrently_,
                                             waitCatch, waitCatchSTM, withAsync)
import           UnliftIO.Timeout           (timeout)

import           InfluxerConf
import           LogStuff
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

data HandleContext = HandleContext {
  counter :: TVar Int
  , wp    :: WriteParams
  , spool :: Spool
  , opts  :: Options
  }

type Influxer = ReaderT HandleContext (LoggingT IO)

parseValue :: ValueParser -> BL.ByteString -> Either String LineField
parseValue AutoVal v    = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue FloatVal v   = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue IntVal v     = FieldInt . floor . toRealFloat <$> readEither (BC.unpack v)
parseValue StringVal v  = (Right . FieldString . TE.decodeUtf8 . BL.toStrict) v
parseValue BoolVal v
  | v `elem` ["ON", "on", "true", "1"] = Right $ FieldBool True
  | otherwise = Right $ FieldBool False
parseValue IgnoreVal _  = Left "ignored"

logAt :: MonadLogger m => LogLevel -> Text -> m ()
logAt l = logWithoutLoc "" l

logErr :: MonadLogger m => Text -> m ()
logErr = logAt LevelError

logInfo :: MonadLogger m => Text -> m ()
logInfo = logAt LevelInfo

logDbg :: MonadLogger m => Text -> m ()
logDbg = logAt LevelDebug

lstr :: Show a => a -> Text
lstr = pack . show

seconds :: Int -> Int
seconds = (* 1000000)

delaySeconds :: MonadIO m => Int -> m ()
delaySeconds = liftIO . threadDelay . seconds

supervise :: String -> Influxer a -> Influxer (Either SomeException a)
supervise name f = do
  p <- async f
  mt <- liftIO $ do
    v <- registerDelay (seconds 20)
    atomically $ (Just <$> waitCatchSTM p) `orElse` checkTimeout v

  case mt of
    Nothing -> do
      logErr $ mconcat ["timed out waiting for supervised job '", pack name, "'... will continue waiting"]
      rv <- waitCatch p
      logErr $ mconcat ["supervised task '", pack name, "' finally finished"]
      pure rv
    Just x -> pure x

  where
    checkTimeout :: TVar Bool -> STM (Maybe a)
    checkTimeout v = do
      v' <- readTVar v
      when (not v') retry
      pure Nothing

type MQTTCB = MQTTClient -> PublishRequest -> IO ()

handle :: HandleContext -> [Watch] -> (Influxer () -> IO ()) -> MQTTCB
handle HandleContext{..} ws unl _ PublishRequest{..} = unl $ do
  logDbg $ mconcat ["Processing ", lstr t, " mid", lstr _pubPktID, " ", lstr _pubProps]
  x <- supervise (unpack t) handle'
  logDbg $ mconcat ["Finished processing ", lstr t, " mid", lstr _pubPktID, " with ", lstr x]
  case x of
    Left e  -> logErr $ mconcat ["error on supervised handler for ", t, ": ", lstr e]
    Right _ -> plusplus counter

  where
    t = (TE.decodeUtf8 . BL.toStrict) _pubTopic
    v = _pubBody

    handle' :: Influxer ()
    handle' = do
      ts <- liftIO $ getCurrentTime
      case extract ts $ foldr (\(Watch _ _ p e) o -> if p `match` t then e else o) undefined ws of
        Left "ignored" -> pure ()
        Left x -> logErr $ mconcat ["error on ", t, " -> ", lstr v, ": " , pack x]
        Right l -> do
          exc <- deadlined (seconds 15) (liftIO $ tryWrite l)
          case exc of
            Just excuse -> do
              logErr $ mconcat ["influx error on ", t, " -> ", lstr v, ": ", pack $ deLine excuse]
              insertSpool spool ts excuse l
            Nothing     -> pure ()

    plusplus :: TVar Int -> Influxer ()
    plusplus tv = liftIO . atomically $ modifyTVar tv succ

    deadlined :: Int -> Influxer (Maybe String) -> Influxer (Maybe String)
    deadlined n a = fromMaybe (Just "timed out") <$> timeout n a

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

runWatcher :: Source -> Influxer ()
runWatcher (Source uri watchers) = do
  Options{..} <- asks opts
  hc <- ask
  mc <- withRunInIO $ \unl -> connectURI mqttConfig{_msgCB=LowLevelCallback $ handle hc watchers unl,
                                                    _protocol=prot optV5, _cleanSession=optClean,
                                                    _connProps=[PropSessionExpiryInterval 3600,
                                                                PropTopicAliasMaximum 1024,
                                                                PropRequestProblemInformation 1,
                                                                PropRequestResponseInformation 1]} uri
  cprops <- liftIO $ svrProps mc
  logInfo $ mconcat ["Connected to ", lstr uri, ": ", lstr cprops]
  let baseOpts = subOptions{_retainHandling=SendOnSubscribeNew}
      tosub = [(t,baseOpts{_subQoS=q qos}) | (Watch qos w t _) <- watchers, w]
  (subrv,_) <- liftIO $ subscribe mc tosub mempty
  logInfo $ "Subscribed: " <> pack (intercalate ", " . map (\((t,_),r) -> show t <> "@" <> s r) $ zip tosub subrv)
  cnt <- asks counter
  withAsync (periodicallyLog cnt) $ \_ -> liftIO $ waitForClient mc

  where
    s = either show show

    q QOS0 = QoS0
    q QOS1 = QoS1
    q QOS2 = QoS2

    periodicallyLog v = forever $ do
      delaySeconds 60
      v' <- liftIO . atomically $ swapTVar v 0
      logInfo $ mconcat ["Processed ", lstr v', " messages from ", lstr uri]

runReporter :: Influxer ()
runReporter = forever $ do
  Options{optMQTTURL} <- asks opts
  catch (bracket connto disco loop) (\e -> logErr $ mconcat ["connecting to ",
                                                             lstr optMQTTURL, " - ",
                                                             lstr (e :: SomeException)])
  delaySeconds 5

  where
    connto = do
      Options{..} <- asks opts
      liftIO $ connectURI mqttConfig{_protocol=prot optV5, _cleanSession=True, _connProps=[]} optMQTTURL

    disco = liftIO . normalDisconnect

    loop mc = forever $ do
      delaySeconds 60
      sp <- asks spool
      c <- count sp
      Options{..} <- asks opts
      liftIO $ publishq mc (optMQTTPrefix <> "spool") (BC.pack $ show c) True QoS1 [PropMessageExpiryInterval 120]

run :: Options -> IO ()
run opts@Options{..} = do
  (InfluxerConf srcs) <- parseConfFile optConfFile
  let wp = writeParams (fromString optInfluxDB) & server.host .~ optInfluxDBHost
  counter <- newTVarIO 0
  runStderrLoggingT . logfilt $ do
    spool <- newSpool wp optSpoolFile
    let hc = (HandleContext counter wp spool opts)
    flip runReaderT hc $ do
      async runReporter >>= link
      mapConcurrently_ runWatcher srcs

  where
    logfilt = filterLogger (\_ -> flip (if optVerbose then (>=) else (>)) LevelDebug)

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Influx the mqtt")
