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
import           Data.Foldable              (asum)
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, manyTill, noneOf, option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (char, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)


import           Network.URI


type Parser = Parsec Void Text

newtype InfluxerConf = InfluxerConf [Source] deriving(Show, Eq)

data Source = Source URI [Watch] deriving(Show, Eq)

data QOS = QOS0 | QOS1 | QOS2 deriving(Show, Eq)

data Watch = Watch QOS Bool Text Extractor deriving(Show, Eq)

type Tags = [(Text,MeasurementNamer)]

data Extractor = ValEx ValueParser Tags MeasurementNamer MeasurementNamer
               | JSON JSONPExtractor
               | IgnoreExtractor deriving(Show, Eq)

data MeasurementNamer = ConstName Text | FieldNum Int deriving (Show, Eq)

data JSONPExtractor = JSONPExtractor MeasurementNamer Tags [(Text, Text, ValueParser)] deriving(Show, Eq)

data ValueParser = AutoVal | IntVal | FloatVal | BoolVal | StringVal | IgnoreVal deriving(Show, Eq)


parseInfluxerConf :: Parser InfluxerConf
parseInfluxerConf = InfluxerConf <$> some parseSrc

sc :: Parser () -- ‘sc’ stands for “space consumer”
sc = L.space space1 lineComment blockComment
  where
    lineComment  = L.skipLineComment "//"
    blockComment = L.skipBlockComment "/*" "*/"

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

qstr :: Parser Text
qstr = pack <$> (char '"' >> manyTill L.charLiteral (char '"'))

parseSrc :: Parser Source
parseSrc = do
  ustr <- lexeme "from" *> lexeme (some (noneOf ['\n', ' ']))
  let (Just u) = parseURI ustr
  ws <- between (lexeme "{") (lexeme "}") (some $ try parseWatch)
  pure $ Source u ws

symbp :: [(Parser b, a)] -> Parser a
symbp = asum . map (\(p,a) -> a <$ lexeme p)

parseValEx :: Parser ValueParser
parseValEx = symbp [("auto", AutoVal),
                    ("int", IntVal),
                    ("float", FloatVal),
                    ("bool", BoolVal),
                    ("string", StringVal),
                    ("ignore", IgnoreVal)]

parsemn :: Parser MeasurementNamer
parsemn = (ConstName <$> lexeme qstr) <|> (FieldNum <$> ref)
  where
    ref :: Parser Int
    ref = lexeme ("$" >> L.decimal)

parseTags :: Parser Tags
parseTags = option [] $ between (lexeme "[") (lexeme "]") (tag `sepBy` lexeme ",")
  where
    tag = (,) <$> (pack <$> lexeme (some (noneOf ['\n', ' ', '=']))) <* lexeme "=" <*> parsemn

parseWatch :: Parser Watch
parseWatch = do
  cons <- symbp [("watch", True), ("match", False)]
  q <- option QOS2 parseQoS
  t <- lexeme qstr
  x <- (ValEx <$> try parseValEx <*> parseTags <*> parseField <*> parseMsr)
       <|> lexeme "jsonp" *> (JSON <$> jsonpWatch)
  pure $ Watch q cons t x

  where

    parseField :: Parser MeasurementNamer
    parseField = option (ConstName "value") ("field=" *> parsemn)

    parseMsr :: Parser MeasurementNamer
    parseMsr = option (FieldNum 0) ("measurement=" *> parsemn)

    parseQoS = symbp [("qos0", QOS0), ("qos1", QOS1), ("qos2", QOS2)]

    jsonpWatch :: Parser JSONPExtractor
    jsonpWatch = between (lexeme "{") (lexeme "}") parsePee
      where parsePee = JSONPExtractor <$> (lexeme "measurement" *> parsemn) <*> parseTags <*> some parseX

    parseX = try ( (,,) <$> lexeme qstr <* lexeme "<-" <*> lexeme qstr <*> parseValEx)
      <|> (,,) <$> lexeme qstr <* lexeme "<-" <*> lexeme qstr <*> pure AutoVal

parseFile :: Parser a -> String -> IO a
parseFile f s = readFile s >>= (either (fail . errorBundlePretty) pure . parse f s) . pack

parseConfFile :: String -> IO InfluxerConf
parseConfFile = parseFile parseInfluxerConf
