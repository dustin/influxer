{-# LANGUAGE OverloadedStrings #-}

module InfluxerConf (
  InfluxerConf(..),
  Source(..),
  Watch(..),
  Extractor(..),
  QOS(..),
  JSONPExtractor(..),
  ValueParser(..),
  MeasurementNamer(..),
  parseConfFile) where

import           Control.Applicative        ((<|>))
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, manyTill, noneOf,
                                             option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (char, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)


import           Network.URI


type Parser = Parsec Void Text

newtype InfluxerConf = InfluxerConf [Source] deriving(Show)

data Source = Source URI [Watch] deriving(Show)

data QOS = QOS0 | QOS1 | QOS2 deriving(Show)

data Watch = Watch QOS Bool Text Extractor deriving(Show)

type Tags = [(Text,MeasurementNamer)]

data Extractor = ValEx ValueParser Tags MeasurementNamer MeasurementNamer | JSON JSONPExtractor deriving(Show)

data MeasurementNamer = ConstName Text | FieldNum Int deriving (Show)

data JSONPExtractor = JSONPExtractor MeasurementNamer Tags [(Text, Text, ValueParser)] deriving(Show)

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

parsemn :: Parser MeasurementNamer
parsemn = (ConstName <$> lexeme qstr) <|> (FieldNum <$> ref)
  where
    ref :: Parser Int
    ref = lexeme ("$" >> L.decimal)

parseTags :: Parser Tags
parseTags = option [] $ between (symbol "[") (symbol "]") (tag `sepBy` (symbol ","))
  where
    tag = (,) <$> (pack <$> lexeme (some (noneOf ['\n', ' ', '=']))) <* symbol "=" <*> parsemn

parseWatch :: Parser Watch
parseWatch = do
  cons <- (True <$ symbol "watch") <|> (False <$ symbol "match")
  q <- option QOS2 parseQoS
  t <- lexeme qstr
  x <- (ValEx <$> try parseValEx <*> parseTags <*> parseField <*> parseMsr) <|> symbol "jsonp" *> (JSON <$> jsonpWatch)
  pure $ Watch q cons t x

  where

    parseField :: Parser MeasurementNamer
    parseField = option (ConstName "value") ("field=" *> parsemn)

    parseMsr :: Parser MeasurementNamer
    parseMsr = option (FieldNum 0) ("measurement=" *> parsemn)

    parseQoS = (QOS0 <$ lexeme "qos0") <|> (QOS1 <$ lexeme "qos1") <|> (QOS2 <$ lexeme "qos2")

    jsonpWatch :: Parser JSONPExtractor
    jsonpWatch = between (symbol "{") (symbol "}") parsePee

      where parsePee = do
              m <-  symbol "measurement" *> parsemn
              tags <- parseTags
              xs <- some parseX
              pure $ JSONPExtractor m tags xs

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
