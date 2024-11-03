module Main where

import           Cleff
import           Cleff.Reader
import           Control.Concurrent.STM     (TQueue, TVar, atomically, flushTQueue, modifyTVar, newTQueueIO, newTVarIO,
                                             peekTQueue, swapTVar, writeTQueue)
import           Control.Lens
import           Control.Monad              (forever)
import           Control.Monad.Catch        (SomeException, bracket, catch)
import           Data.Aeson                 (Value (..), eitherDecode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
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
import qualified JSONPointer                as JP
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..), MessageCallback (..), Property (..),
                                             ProtocolLevel (..), QoS (..), Topic, connectURI, mqttConfig,
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

data HandleContext = HandleContext {
  counter :: TVar Int
  , opts  :: Options
  }

type MQTTCB = MQTTClient -> PublishRequest -> IO ()

type OpQueue = TQueue (UTCTime, Entry)

fk :: IsString k => Text -> k
fk = fromString.unpack

handle :: [IOE, LogFX, Reader HandleContext] :>> es => OpQueue -> [Watch] -> (Eff es () -> IO ()) -> MQTTCB
handle opq ws unl _ PublishRequest{..} = unl $ do
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

    plusplus = asks counter >>= \tv -> liftIO . atomically $ modifyTVar tv succ

    extract _ IgnoreExtractor = Left "unexpected message"

    extract ts (ValEx vp tags fld mn) = case parseValue vp v of
                              Left x  -> Left x
                              Right v' -> let (retention, measurement) = mname mn in
                                            Right (retention, Line measurement (Map.fromList $ mvals <$> tags)
                                                              (Map.singleton (fk $ nname fld) v') (Just ts))

    extract ts (JSON (JSONPExtractor m tags pats)) = jsonate ts (mname m) (mvals <$> tags) pats =<< eitherDecode v

    mname :: MeasurementNamer -> (Maybe Text, Measurement)
    mname (MeasurementNamer x n) = (x, fk $ nname n)

    nname :: Namer -> Text
    nname (ConstName t') = t'
    nname (FieldNum 0)   = txtt
    nname (FieldNum x)   = splitOn "/" txtt !! (x - 1)

    mvals :: (Text, Namer) -> (Key, Key)
    mvals (a,m) = (fk a, fk . nname $ m)

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


runWatcher :: [IOE, LogFX, Reader HandleContext] :>> es => OpQueue -> Source -> Eff es ()
runWatcher opq src@(Source uri watchers) = do
  Options{..} <- asks opts
  mc <- withRunInIO $ \unl -> connectURI mqttConfig{_msgCB=LowLevelCallback $ handle opq watchers unl,
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
  cnt <- asks counter
  withAsync (periodicallyLog cnt) $ \_ -> liftIO $ waitForClient mc

  where
    s = either tshow tshow

    periodicallyLog v = forever $ do
      delaySeconds 60
      v' <- liftIO . atomically $ swapTVar v 0
      logInfoL ["Processed ", tshow v', " messages from ", tshow uri]

runReporter :: [IOE, LogFX, SpoolFX, Reader HandleContext] :>> es => Eff es ()
runReporter = forever $ do
  Options{optMQTTURL} <- asks opts
  catch (bracket connto disco loop) (\e -> logErrorL ["connecting to ", tshow optMQTTURL, " - ", tshow (e :: SomeException)])
  delaySeconds 5

  where
    connto = do
      Options{..} <- asks opts
      liftIO $ connectURI mqttConfig{_protocol=optProtocol, _cleanSession=True, _connProps=[]} optMQTTURL

    disco = liftIO . normalDisconnect

    loop mc = forever $ do
      delaySeconds 60
      c <- countSpool
      Options{..} <- asks opts
      liftIO $ publishq mc (optMQTTPrefix <> "spool") (BC.pack $ show c) True QoS1 [PropMessageExpiryInterval 120]

runInserter :: [IOE, LogFX, SpoolFX, Reader HandleContext] :>> es => WriteParams -> OpQueue -> Eff es ()
runInserter wp opq = forever do
      todo <- (liftIO . atomically) (peekTQueue opq *> flushTQueue opq)
      mapM_ eachBatch . Map.assocs $ Map.fromListWith (<>) [(r, [(ts, l)]) | (ts, (r,l)) <- todo]

    where
        ls = encodeLines (scaleTo (wp ^. precision)) . fmap snd
        eachBatch (mk, todo) = do
          let logfn = case todo of
                        [_] -> logDbg
                        _   -> logInfo
          logfn $ "Inserting a batch of " <> tshow (length todo) <> maybe "" ((" r=" <>) . tshow) mk
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
  counter <- newTVarIO 0
  runIOE . runLogFX optVerbose . runNewSpool wp optSpoolFile $ do
    tq <- liftIO newTQueueIO
    runReader (HandleContext counter opts) do
      async (runInserter wp tq) >>= link
      async runReporter >>= link
      mapConcurrently_ (runWatcher tq) srcs

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Influx the mqtt")
