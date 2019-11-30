{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Spool (Spool, newSpool, insertSpool, closeSpool, count) where

import           Control.Concurrent      (threadDelay)
import           Control.Lens
import           Control.Monad           (forever, unless, when)
import           Control.Monad.Catch     (MonadCatch, catch)
import           Control.Monad.IO.Class  (MonadIO (..))
import           Control.Monad.IO.Unlift (MonadUnliftIO)
import           Control.Monad.Logger    (MonadLogger, logErrorN, logInfoN)
import qualified Data.ByteString.Lazy    as BL
import qualified Data.Text               as T
import           Data.Time               (UTCTime, getCurrentTime)
import           Database.InfluxDB       (InfluxException (..), Line (..),
                                          WriteParams, precision, scaleTo,
                                          writeByteString)
import           Database.InfluxDB.Line  (encodeLine)
import           Database.SQLite.Simple  hiding (bind, close)
import qualified Database.SQLite.Simple  as SQLite
import           UnliftIO.Async          (Async, async, cancel, link)

import           LogStuff

data Spool = Spool {
  wp         :: WriteParams
  , conn     :: Connection
  , inserter :: Async ()
  }

createStatement :: Query
createStatement = mconcat ["create table if not exists spool (id integer primary key autoincrement,",
                           "ts timestamp,",
                           "last_attempt timestamp,",
                           "last_error text,",
                           "line blob)"]

insertStatement :: Query
insertStatement = "insert into spool (ts, last_attempt, last_error, line) values (?, ?, ?, ?)"

retryStmt :: Query
retryStmt = "select id, line from spool where last_attempt < datetime('now', '-1 minute') limit 100"

reschedStmt :: Query
reschedStmt = "update spool set last_attempt = ?, last_error = ? where id = ?"

removeStmt :: Query
removeStmt = "delete from spool where id = ?"

countStmt :: Query
countStmt = "select count(*) from spool"

newSpool :: (MonadCatch m, MonadLogger m, MonadUnliftIO m) => WriteParams -> String -> m Spool
newSpool wp fn = do
  conn <- liftIO $ open fn
  liftIO $ do
    execute_ conn "pragma auto_vacuum = incremental"
    execute_ conn createStatement

  inserter <- async $ runInserter wp conn
  link inserter

  pure $ Spool{..}

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay

runInserter :: (MonadCatch m, MonadLogger m, MonadIO m) => WriteParams -> Connection -> m ()
runInserter wp conn = forever insertSome

  where
    insertSome :: (MonadLogger m, MonadIO m, MonadCatch m) => m ()
    insertSome = do
      rows <- liftIO (query_ conn retryStmt :: IO [(Int,BL.ByteString)])
      catch (do
                liftIO $ writeByteString wp . mconcat . map ((<>"\n") . snd) $ rows
                liftIO $ withTransaction conn $ executeMany conn removeStmt (map (Only . fst) rows)
                unless (null rows) $ logInfoN $ "retry: processed backlog of " <> (T.pack . show $ length rows)
            ) (reschedule (map fst rows))

      when (null rows) $ do
        liftIO $ execute_ conn "pragma incremental_vacuum(100)"
        sleep 60000000

    reschedule :: (MonadLogger m, MonadIO m) => [Int] -> InfluxException -> m ()
    reschedule ids e = do
      logErrorN $ "retry: retry batch insertion error: " <> (T.pack . deLine . show) e
      ts <- liftIO getCurrentTime
      liftIO $ withTransaction conn $ executeMany conn reschedStmt [(ts,(deLine . show) e,r) | r <- ids]
      sleep 15000000 -- slow down processing when we're rescheduling.

insertSpool :: MonadIO m => Spool -> UTCTime -> String -> Line UTCTime -> m ()
insertSpool Spool{..} ts err l =
  liftIO $ execute conn insertStatement (ts, ts, err, BL.toStrict . encodeLine (scaleTo (wp ^. precision)) $ l)

count :: MonadIO m => Spool -> m Int
count Spool{..} = liftIO (query_ conn countStmt) >>= \[[c]] -> pure c

closeSpool :: MonadIO m => Spool -> m ()
closeSpool Spool{..} = do
  cancel inserter
  liftIO $ SQLite.close conn
