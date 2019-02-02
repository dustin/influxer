{-# LANGUAGE OverloadedStrings #-}

module InfluxerConf (
  InfluxerConf(..),
  Source(..),
  Watch(..),
  Extractor(..),
  JSONPExtractor(..),
  ValueParser(..),
  parseConfFile,
  topicMatches) where

import           Control.Applicative        ((<|>))
import           Data.Text                  (Text, pack, splitOn)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, manyTill, noneOf,
                                             parse, some, try)
import           Text.Megaparsec.Char       (char, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)


import           Network.URI


type Parser = Parsec Void Text

newtype InfluxerConf = InfluxerConf [Source] deriving(Show)

data Source = Source URI [Watch] deriving(Show)

data Watch = Watch Bool Text Extractor deriving(Show)

data Extractor = ValEx ValueParser | JSON JSONPExtractor deriving(Show)

data JSONPExtractor = JSONPExtractor Text [(Text, Text, ValueParser)] deriving(Show)

data ValueParser = AutoVal | IntVal | FloatVal | BoolVal | StringVal | IgnoreVal deriving(Show)


parseInfluxerConf :: Parser InfluxerConf
parseInfluxerConf = InfluxerConf <$> some parseSrc

sc :: Parser () -- ‘sc’ stands for “space consumer”
sc = L.space space1 lineComment blockComment
  where
    lineComment  = L.skipLineComment "//"
    blockComment = L.skipBlockComment "/*" "*/"

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

qstr :: Parser Text
qstr = pack <$> (char '"' >> manyTill L.charLiteral (char '"'))

parseSrc :: Parser Source
parseSrc = do
  ustr <- symbol "from" *> lexeme (some (noneOf ['\n', ' ']))
  let (Just u) = parseURI ustr
  ws <- between (symbol "{") (symbol "}") (some $ try parseWatch)
  pure $ Source u ws

parseValEx :: Parser ValueParser
parseValEx = AutoVal <$ symbol "auto"
             <|> IntVal <$ symbol "int"
             <|> FloatVal <$ symbol "float"
             <|> BoolVal <$ symbol "bool"
             <|> StringVal <$ symbol "string"
             <|> IgnoreVal <$ symbol "ignore"

parseWatch :: Parser Watch
parseWatch = do
  cons <- (True <$ symbol "watch") <|> (False <$ symbol "match")
  t <- lexeme qstr
  x <- (ValEx <$> try parseValEx) <|> symbol "jsonp" *> (JSON <$> jsonpWatch)
  pure $ Watch cons t x

  where

    jsonpWatch :: Parser JSONPExtractor
    jsonpWatch = between (symbol "{") (symbol "}") parsePee

      where parsePee = do
              m <-  symbol "measurement" *> lexeme qstr
              xs <- some parseX
              pure $ JSONPExtractor m xs


    parseX = try ( (,,) <$> lexeme qstr <* symbol "<-" <*> lexeme qstr <*> parseValEx)
      <|> (,,) <$> lexeme qstr <* symbol "<-" <*> lexeme qstr <*> pure AutoVal

parseFile :: Parser a -> String -> IO a
parseFile f s = do
  c <- pack <$> readFile s
  case parse f s c of
    (Left x)  -> fail (errorBundlePretty x)
    (Right v) -> pure v

parseConfFile :: String -> IO InfluxerConf
parseConfFile = parseFile parseInfluxerConf

topicMatches :: Text -> Text -> Bool
topicMatches pat top = cmp (splitOn "/" pat) (splitOn "/" top)

  where
    cmp [] []   = True
    cmp [] _    = False
    cmp _ []    = False
    cmp ["#"] _ = True
    cmp (p:ps) (t:ts)
      | p == t = cmp ps ts
      | p == "+" = cmp ps ts
      | otherwise = False
