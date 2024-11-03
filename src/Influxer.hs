module Influxer where

import           Cleff
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (waitCatchSTM)
import           Control.Concurrent.STM     (STM, TVar, atomically, orElse, readTVar, registerDelay, retry)
import           Control.Monad              (unless)
import           Control.Monad.Catch        (SomeException)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Scientific            (toRealFloat)
import           Data.Text                  (Text)
import qualified Data.Text.Encoding         as TE
import           Database.InfluxDB          (Field (..), LineField)
import           Network.MQTT.Client        (QoS (..), SubOptions (..), subOptions)
import           Network.MQTT.Topic         (Filter, Topic, match)
import           Network.MQTT.Types         (RetainHandling (..))
import           Text.Read                  (readEither)

import           Async
import           InfluxerConf
import           LogStuff

seconds :: Int -> Int
seconds = (* 1000000)

delaySeconds :: MonadIO m => Int -> m ()
delaySeconds = liftIO . threadDelay . seconds

supervise :: [IOE, LogFX] :>> es => Text -> Eff es a -> Eff es (Either SomeException a)
supervise name f = do
  p <- async f
  mt <- liftIO $ do
    v <- registerDelay (seconds 20)
    atomically $ (Just <$> waitCatchSTM p) `orElse` checkTimeout v

  case mt of
    Nothing -> do
      logErrorL ["timed out waiting for supervised job ", name, "... will continue waiting"]
      rv <- waitCatch p
      logErrorL ["supervised task ",  name, " finally finished"]
      pure rv
    Just x -> pure x

  where
    checkTimeout :: TVar Bool -> STM (Maybe a)
    checkTimeout v = do
      v' <- readTVar v
      unless v' retry
      pure Nothing

parseValue :: ValueParser -> BL.ByteString -> Either String LineField
parseValue AutoVal v    = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue FloatVal v   = FieldFloat . toRealFloat <$> readEither (BC.unpack v)
parseValue IntVal v
  | '.' `BC.elem` v     = FieldInt . floor @Double . toRealFloat <$> readEither (BC.unpack v)
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
