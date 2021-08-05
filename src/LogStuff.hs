{-# LANGUAGE OverloadedStrings #-}

module LogStuff where

import           Control.Monad.Logger (LogLevel (..), LogStr, MonadLogger, ToLogStr (..), logWithoutLoc)
import           Data.List            (intercalate)
import           Network.MQTT.Topic   (Topic (..))

instance ToLogStr Topic where
  toLogStr = toLogStr . unTopic

logAt :: (MonadLogger m, ToLogStr msg) => LogLevel -> msg -> m ()
logAt = logWithoutLoc ""

logErr :: (MonadLogger m, ToLogStr msg) => msg -> m ()
logErr = logAt LevelError

logInfo :: (MonadLogger m, ToLogStr msg) => msg -> m ()
logInfo = logAt LevelInfo

logDbg :: (MonadLogger m, ToLogStr msg) => msg -> m ()
logDbg = logAt LevelDebug

lstr :: Show a => a -> LogStr
lstr = toLogStr . show

deLine :: String -> String
deLine = dedupSpace . intercalate " " . lines

dedupSpace :: String -> String
dedupSpace s = let (l, r) = span (/= ' ') s in
                 case r of
                   "" -> l
                   _  -> l <> " " <> dedupSpace (dropWhile (== ' ') r)
