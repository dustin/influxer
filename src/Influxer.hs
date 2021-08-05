{-# LANGUAGE OverloadedStrings #-}

module Influxer where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.STM     (retry)
import           Control.Monad              (unless)
import           Control.Monad.Catch        (SomeException)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.IO.Unlift    (MonadUnliftIO (..))
import           Control.Monad.Logger       (MonadLogger)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Scientific            (toRealFloat)
import qualified Data.Text.Encoding         as TE
import           Database.InfluxDB          (Field (..), LineField)
import           Network.MQTT.Client        (QoS (..), SubOptions (..), subOptions)
import           Network.MQTT.Topic         (Filter, Topic, match)
import           Network.MQTT.Types         (RetainHandling (..))
import           Text.Read                  (readEither)
import           UnliftIO                   (STM, TVar, async, atomically, orElse, readTVar, registerDelay, waitCatch,
                                             waitCatchSTM)

import           InfluxerConf
import           LogStuff

seconds :: Int -> Int
seconds = (* 1000000)

delaySeconds :: MonadIO m => Int -> m ()
delaySeconds = liftIO . threadDelay . seconds

supervise :: (MonadUnliftIO m, MonadLogger m) => String -> m a -> m (Either SomeException a)
supervise name f = do
  p <- async f
  mt <- liftIO $ do
    v <- registerDelay (seconds 20)
    atomically $ (Just <$> waitCatchSTM p) `orElse` checkTimeout v

  case mt of
    Nothing -> do
      logErr $ "timed out waiting for supervised job " <> lstr name <> "... will continue waiting"
      rv <- waitCatch p
      logErr $ "supervised task " <> lstr name <> " finally finished"
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
