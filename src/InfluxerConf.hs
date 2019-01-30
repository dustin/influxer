{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module InfluxerConf where

import           Control.Applicative        (empty, (<|>))
import qualified Data.ByteString.Lazy       as BL
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Text                  (Text, dropEnd, dropWhileEnd, pack,
                                             splitOn)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, endBy, eof,
                                             manyTill, noneOf, option, parse,
                                             sepBy, some, try)
import           Text.Megaparsec.Char       (alphaNumChar, char, space, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)

import           Network.URI


type Parser = Parsec Void Text

newtype InfluxerConf = InfluxerConf [Source] deriving(Show)

data Source = Source URI [Watch] deriving(Show)

data Watch = Watch Text Extractor deriving(Show)

data Extractor = ValEx ValueParser | JSON JSONPExtractor deriving(Show)

data JSONPExtractor = JSONPExtractor Text [(Text, ValueParser, Text)] deriving(Show)

data ValueParser = AutoVal | IntVal | FloatVal | BoolVal deriving(Show)


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
  ustr <- (symbol "from") *> lexeme (some (noneOf ['\n', ' ']))
  let (Just u) = parseURI ustr
  ws <- between (symbol "{") (symbol "}") (some $ try parseWatch)
  pure $ Source u ws

parseValEx :: Parser ValueParser
parseValEx = AutoVal <$ symbol "auto"
             <|> IntVal <$ symbol "int"
             <|> FloatVal <$ symbol "float"
             <|> BoolVal <$ symbol "bool"

parseWatch :: Parser Watch
parseWatch = do
  t <- (symbol "watch") *> lexeme qstr
  x <- (ValEx <$> try parseValEx) <|> symbol "jsonp" *> (JSON <$> jsonpWatch)
  pure $ Watch t x

  where

    jsonpWatch :: Parser JSONPExtractor
    jsonpWatch = between (symbol "{") (symbol "}") parsePee

      where parsePee = do
              m <-  (symbol "measurement" *> lexeme qstr)
              xs <- some parseX
              pure $ JSONPExtractor m xs


    parseX = (,,) <$> lexeme qstr <* symbol "<-" <*> parseValEx <*> lexeme qstr

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
