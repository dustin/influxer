{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Spool (Spool, newSpool, insertSpool, closeSpool) where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (Async, async, cancel, link)
import           Control.Exception        (catch)
import           Control.Lens
import           Control.Monad            (forever, unless)
import qualified Data.ByteString.Lazy     as BL
import           Data.Time                (UTCTime, getCurrentTime)
import           Database.InfluxDB        (InfluxException (..), Line (..),
                                           WriteParams, precision, scaleTo,
                                           writeByteString)
import           Database.InfluxDB.Line   (encodeLine)
import           Database.SQLite.Simple   hiding (bind, close)
import qualified Database.SQLite.Simple   as SQLite
import           System.Log.Logger        (errorM, infoM)

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

newSpool :: WriteParams -> String -> IO Spool
newSpool wp fn = do
  conn <- open fn
  execute_ conn createStatement

  inserter <- async $ runInserter wp conn
  link inserter

  pure $ Spool{..}

runInserter :: WriteParams -> Connection -> IO ()
runInserter wp conn = forever insertSome

  where
    insertSome = do
      rows <- query_ conn retryStmt :: IO [(Int,BL.ByteString)]
      catch (do
                writeByteString wp . mconcat . map ((<>"\n") . snd) $ rows
                withTransaction conn $ executeMany conn removeStmt (map (Only . fst) rows)
                unless (null rows) $ infoM "retry" ("processed backlog of " <> show (length rows))
            ) (reschedule (map fst rows))


      threadDelay (if null rows then 0 else 60000000)

    reschedule :: [Int] -> InfluxException -> IO ()
    reschedule ids e = do
      errorM "retry" ("retry batch insertion error: " <> show e)
      ts <- getCurrentTime
      withTransaction conn $ executeMany conn reschedStmt [(ts,show e,r) | r <- ids]

insertSpool :: Spool -> UTCTime -> String -> Line UTCTime -> IO ()
insertSpool Spool{..} ts err l =
  execute conn insertStatement (ts, ts, err, BL.toStrict . encodeLine (scaleTo (wp ^. precision)) $ l)

closeSpool :: Spool -> IO ()
closeSpool Spool{..} = do
  cancel inserter
  SQLite.close conn
