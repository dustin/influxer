{-# LANGUAGE OverloadedStrings #-}

module Spool (Spool, newSpool, insertSpool, closeSpool) where

import qualified Data.ByteString.Lazy   as BL
import qualified Data.Text.Encoding     as TE
import           Data.Time              (UTCTime)
import           Database.InfluxDB      (Line (..), scaleTo)
import           Database.InfluxDB.Line (Precision (..), encodeLine)
import           Database.SQLite.Simple hiding (bind, close)
import qualified Database.SQLite.Simple as SQLite

data Spool = Spool Connection

createStatement :: Query
createStatement = mconcat ["create table if not exists spool (id integer primary key autoincrement,",
                           "line text)"]

insertStatement :: Query
insertStatement = "insert into spool (line) values (?)"

newSpool :: String -> IO Spool
newSpool fn = do
  conn <- open fn
  execute_ conn createStatement

  pure $ Spool conn

insertSpool :: Spool -> Line UTCTime -> IO ()
insertSpool (Spool c) l = do
  execute c insertStatement (Only . TE.decodeUtf8 . BL.toStrict . encodeLine (scaleTo Millisecond) $ l)

closeSpool :: Spool -> IO ()
closeSpool (Spool c) = SQLite.close c
