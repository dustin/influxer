module Main where

import           Control.Concurrent.STM     (TQueue, TVar, atomically, flushTQueue, modifyTVar', newTQueueIO, newTVarIO,
                                             peekTQueue, readTVar, swapTVar, writeTQueue)
import           Control.Lens
import           Control.Monad              (forever)
import           Control.Monad.Catch        (SomeException, bracket, catch)
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Foldable              (for_)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, mapMaybe)
import           Data.Scientific            (toRealFloat)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, splitOn, unpack)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import           Data.Time                  (UTCTime, getCurrentTime)
import           Database.InfluxDB          (Field (..), InfluxException (..), Key, Line (..), LineField, Measurement,
                                             WriteParams, host, precision, retentionPolicy, scaleTo, server,
                                             writeByteString, writeParams)
import           Database.InfluxDB.Line     (encodeLines)
import           Effectful
import           Effectful.Reader.Static
import qualified JSONPointer                as JP
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..), MQTTException, MessageCallback (..),
                                             Property (..), ProtocolLevel (..), QoS (..), Topic, connectURI, mqttConfig,
                                             normalDisconnect, publishq, subscribe, svrProps, waitForClient)
import           Network.MQTT.Topic         (unTopic)
import           Network.MQTT.Types         (PublishRequest (..))
import           Network.URI                (URI, parseURI)
import           Options.Applicative        (Parser, execParser, flag, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import qualified System.Timeout             as Timeout

import           Async
import           Influxer
import           InfluxerConf
import           LogStuff
import           Spool

data Options = Options {
  optInfluxDBHost :: Text
  , optInfluxDB   :: String
  , optConfFile   :: FilePath
  , optSpoolFile  :: String
  , optProtocol   :: ProtocolLevel
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
  <*> flag Protocol311 Protocol50 (long "mqtt5" <> short '5' <> help "Use MQTT5 by default")
  <*> switch (long "clean" <> short 'c' <> help "Use a clean sesssion by default")
  <*> switch (long "verbose" <> short 'v' <> help "Log more stuff")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-prefix" <> showDefault <> value "tmp/influxer" <> help "MQTT topic prefix")

type Entry = (Maybe Text, Line UTCTime)

type MQTTCB = MQTTClient -> PublishRequest -> IO ()

type OpQueue = TQueue (UTCTime, Entry)

fk :: IsString k => Text -> k
fk = fromString.unpack

handle :: (IOE :> es, LogFX :> es) => OpQueue -> TVar Int -> [Watch] -> (Eff es () -> IO ()) -> MQTTCB
handle opq counter ws unl _ PublishRequest{..} = unl $ do
  logDbgL ["Processing ", tshow t, " mid", tshow _pubPktID, " ", tshow _pubProps]
  x <- supervise (unTopic t) handle'
  logDbgL ["Finished processing ", unTopic t, " mid", tshow _pubPktID," with ", tshow x]
  case x of
    Left e  -> logErrorL ["error on supervised handler for ", unTopic t, ": ", tshow e]
    Right _ -> plusplus

  where
    txtt = (TE.decodeUtf8 . BL.toStrict) _pubTopic
    t = fk txtt
    v = _pubBody

    handle' = do
      ts <- liftIO getCurrentTime
      case extract ts $ bestMatch t ws of
        Left "ignored" -> pure ()
        Left x -> logErrorL ["error on ", unTopic t, " -> ", tshow v, ": ", tshow x]
        Right l -> (liftIO . atomically) $ writeTQueue opq (ts, l)

    plusplus = liftIO . atomically $ modifyTVar' counter succ

    extract _ IgnoreExtractor = Left "unexpected message"

    extract ts (ValEx vp tags fld mn) = do
      v' <- parseValue vp v
      (retention, measurement) <- mname mn
      tags' <- traverse mvals tags
      fld' <- nname fld
      pure (retention, Line measurement (Map.fromList tags') (Map.singleton (fk fld') v') (Just ts))

    extract ts (JSON (JSONPExtractor m tags pats)) = do
      m' <- mname m
      tags' <- traverse mvals tags
      jsonate ts m' tags' pats =<< eitherDecode v

    mname :: MeasurementNamer -> Either String (Maybe Text, Measurement)
    mname (MeasurementNamer x n) = (x,) . fk <$> nname n

    -- A filter can't promise a field exists (e.g., a/# also matches a), so this has to be
    -- resolved before the entry is queued, where the failure can be handled per message.
    nname :: Namer -> Either String Text
    nname (ConstName t') = Right t'
    nname (FieldNum 0)   = Right txtt
    nname (FieldNum x)   = case drop (x - 1) (splitOn "/" txtt) of
                             (f:_) -> Right f
                             []    -> Left ("topic has no field $" <> show x)

    mvals :: (Text, Namer) -> Either String (Key, Key)
    mvals (a,m) = (fk a,) . fk <$> nname m

    -- extract all the desired fields
    jsonate :: UTCTime -> (Maybe Text, Measurement)
            -> [(Key,Key)]
            -> [(Text,Text,ValueParser)]
            -> Value
            -> Either String Entry
    jsonate ts (ret, m) tags l ob = case mapMaybe j1 l of
                                      [] -> Left "I've got no values"
                                      vs -> Right (ret, Line m (Map.fromList tags) (Map.fromList vs) (Just ts))
      where
        j1 :: (Text,Text,ValueParser) -> Maybe (Key, LineField)
        j1 (tag, pstr, vp) = let (Right p) = JP.unescape pstr in
                               case JP.resolve p ob of
                                 Left _   -> Nothing
                                 Right v' -> (fk tag,) <$> jt vp v'

        jt FloatVal (Number x)  = Just $ FieldFloat . toRealFloat $ x
        jt AutoVal (Number x)   = Just $ FieldFloat . toRealFloat $ x
        jt AutoVal (Bool x)     = Just $ FieldBool x
        jt IntVal (Number x)    = Just $ FieldInt . floor @Double . toRealFloat $ x
        jt BoolVal (Bool x)     = Just $ FieldBool x
        jt StringVal (String x) = Just $ FieldString x
        jt _ _                  = Nothing


-- | Publish a stat.  These are advisory, so losing one isn't worth disturbing anything else.
--
-- QoS0 keeps a stalled broker from holding up the inserter while it waits for an ack.
publishStat :: (IOE :> es, LogFX :> es) => MQTTClient -> Topic -> Int -> Eff es ()
publishStat mc t v = catch @_ @MQTTException publish failed
  where
    publish = liftIO $ publishq mc t (BC.pack $ show v) False QoS0 [PropMessageExpiryInterval 120]
    failed e = logErrorL ["publishing stat to ", unTopic t, ": ", tshow e]

runWatcher :: (IOE :> es, LogFX :> es, SpoolFX :> es, Reader Options :> es) => WriteParams -> Source -> Eff es ()
runWatcher wp src@(Source uri stats watchers) = do
  Options{..} <- ask
  -- Each source gets its own queue and counter so stats can be attributed to it.
  opq <- liftIO newTQueueIO
  cnt <- liftIO $ newTVarIO 0
  prevCnt <- liftIO $ newTVarIO 0
  mc <- withRunInIO $ \unl -> connectURI mqttConfig{_msgCB=LowLevelCallback $ handle opq cnt watchers unl,
                                                    _protocol=optProtocol, _cleanSession=optClean,
                                                    _connProps=[PropSessionExpiryInterval 3600,
                                                                PropTopicAliasMaximum 1024,
                                                                PropRequestProblemInformation 1,
                                                                PropRequestResponseInformation 1]} uri
  cprops <- liftIO $ svrProps mc
  logInfoL ["Connected to ", tshow uri, ": ", tshow cprops]
  let tosub = subs src
  (subrv,_) <- liftIO $ subscribe mc tosub mempty
  logInfo $ "Subscribed: " <> (T.intercalate ", " . map (\((t,_),r) -> tshow t <> "@" <> s r) $ zip tosub subrv)
  async (runInserter wp opq (reportBatch mc)) >>= link
  withAsync (periodicallyReport mc cnt prevCnt) $ \_ -> liftIO $ waitForClient mc

  where
    s = either tshow tshow

    periodicallyReport mc v pv = forever $ do
      delaySeconds 60
      (v', pv') <- liftIO . atomically $ do
        v' <- readTVar v
        pv' <- swapTVar pv v'
        pure (v', pv')
      logDbgL ["Processed ", tshow (v' - pv'), " messages from ", tshow uri]
      for_ stats $ \prefix -> publishStat mc (processedTopic prefix) v'

    reportBatch mc mk n = for_ stats $ \prefix -> case batchTopic prefix mk of
      Nothing -> logErrorL ["can't report batches for retention policy ", tshow mk]
      Just t  -> publishStat mc t n

runReporter :: (IOE :> es, LogFX :> es, SpoolFX :> es, Reader Options :> es) => Eff es ()
runReporter = forever $ do
  Options{optMQTTURL} <- ask
  catch (bracket connto disco loop) (\e -> logErrorL ["connecting to ", tshow optMQTTURL, " - ", tshow (e :: SomeException)])
  delaySeconds 5

  where
    connto = do
      Options{..} <- ask
      liftIO $ connectURI mqttConfig{_protocol=optProtocol, _cleanSession=True, _connProps=[]} optMQTTURL

    disco = liftIO . normalDisconnect

    loop mc = forever $ do
      delaySeconds 60
      c <- countSpool
      Options{..} <- ask
      liftIO $ publishq mc (optMQTTPrefix <> "spool") (BC.pack $ show c) True QoS1 [PropMessageExpiryInterval 120]

runInserter :: (IOE :> es, LogFX :> es, SpoolFX :> es) => WriteParams -> OpQueue -> (Maybe Text -> Int -> Eff es ()) -> Eff es ()
runInserter wp opq reportBatch = forever do
      todo <- (liftIO . atomically) (peekTQueue opq *> flushTQueue opq)
      mapM_ eachBatch . Map.assocs $ Map.fromListWith (<>) [(r, [(ts, l)]) | (ts, (r,l)) <- todo]

    where
        ls = encodeLines (scaleTo (wp ^. precision)) . fmap snd
        eachBatch (mk, todo) = do
          reportBatch mk (length todo)
          tryBatch mk todo
        tryBatch mk todo = catch @_ @InfluxException mightInsert failed
          where

            mightInsert = do
              m <- timeout (seconds 30) (liftIO $ writeByteString (wp & retentionPolicy .~ (fk <$> mk)) (ls todo))
              case m of
                Nothing -> insertSpool mk todo "timed out"
                Just _  -> pure ()

            failed ex = do
              let errs = (deLine . show) ex
              logErr $ "influxdb live error " <> tshow errs
              insertSpool mk todo errs

        timeout n m = withRunInIO $ \r -> Timeout.timeout n (r m)

run :: Options -> IO ()
run opts@Options{..} = do
  (InfluxerConf srcs) <- parseConfFile optConfFile
  let wp = writeParams (fromString optInfluxDB) & server.host .~ optInfluxDBHost
  -- MQTT callbacks and async workers run Eff actions from other threads.
  runEff . withUnliftStrategy (ConcUnlift Persistent Unlimited) . runLogFX optVerbose . runNewSpool wp optSpoolFile $ do
    runReader opts do
      async runReporter >>= link
      mapConcurrently_ (runWatcher wp) srcs

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Influx the mqtt")
