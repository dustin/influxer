module InfluxerConf (
  InfluxerConf(..),
  Source(..),
  Watch(..),
  Extractor(..),
  QOS(..),
  JSONPExtractor(..),
  ValueParser(..),
  Namer(..),
  MeasurementNamer(..),
  parseConfFile) where

import           Control.Applicative        ((<|>))
import           Data.Foldable              (asum)
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Network.MQTT.Topic
import           Network.URI
import           Text.Megaparsec            (Parsec, between, manyTill, noneOf, option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (char, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)


type Parser = Parsec Void Text

newtype InfluxerConf = InfluxerConf [Source] deriving(Show, Eq)

data Source = Source URI [Watch] deriving(Show, Eq)

data QOS = QOS0 | QOS1 | QOS2 deriving(Show, Eq, Bounded, Enum)

data Watch = Watch QOS Filter Extractor
           | Match Filter Extractor
           deriving (Show, Eq)

type Tags = [(Text,Namer)]

data Namer = ConstName Text | FieldNum Int deriving (Show, Eq)

data MeasurementNamer = MeasurementNamer (Maybe Text) Namer deriving (Show, Eq)

data Extractor = ValEx ValueParser Tags Namer MeasurementNamer
               | JSON JSONPExtractor
               | IgnoreExtractor deriving(Show, Eq)

data JSONPExtractor = JSONPExtractor MeasurementNamer Tags [(Text, Text, ValueParser)] deriving(Show, Eq)

data ValueParser = AutoVal | IntVal | FloatVal | BoolVal | StringVal | IgnoreVal deriving(Show, Eq)

parseInfluxerConf :: Parser InfluxerConf
parseInfluxerConf = InfluxerConf <$> some parseSrc

lexeme :: Parser a -> Parser a
lexeme = L.lexeme (L.space space1 (L.skipLineComment "//") (L.skipBlockComment "/*" "*/"))

qstr :: Parser Text
qstr = pack <$> (char '"' >> manyTill L.charLiteral (char '"'))

-- between, but lexeme-wrapping surrounding parsers.
bt :: Parser a -> Parser b -> Parser c -> Parser c
bt a b = between (lexeme a) (lexeme b)

parseSrc :: Parser Source
parseSrc = do
  u <- maybe (fail "bad URL") pure . parseURI =<< lexeme "from" *> lexeme (some (noneOf ['\n', ' ']))
  Source u <$> bt "{" "}" (some parseWatch)

symbp :: [(Parser b, a)] -> Parser a
symbp = asum . map (\(p,a) -> a <$ lexeme p)

parseValEx :: Parser ValueParser
parseValEx = symbp [("auto", AutoVal),
                    ("int", IntVal),
                    ("float", FloatVal),
                    ("bool", BoolVal),
                    ("string", StringVal),
                    ("ignore", IgnoreVal)]

parsenamer :: Parser Namer
parsenamer = (ConstName <$> lexeme qstr) <|> (FieldNum <$> lexeme ("$" >> L.decimal))

parsemnamer :: Parser MeasurementNamer
parsemnamer = try qualified <|> notQualified
  where
    qualified = qstr <* "." >>= \r -> MeasurementNamer (Just r) <$> parsenamer
    notQualified = MeasurementNamer Nothing <$> parsenamer

parseTags :: Parser Tags
parseTags = option [] $ bt "[" "]" (tag `sepBy` lexeme ",")
  where
    tag = (,) <$> (pack <$> lexeme (some (noneOf ['\n', ' ', '=']))) <* lexeme "=" <*> parsenamer

parseWatch :: Parser Watch
parseWatch = do
  cons <- Match <$ m <|> Watch <$> w
  t <- lexeme aFilter
  x <- (ValEx <$> try parseValEx <*> parseTags <*> parseField <*> parseMsr)
       <|> lexeme "jsonp" *> (JSON <$> jsonpWatch)
  pure $ cons t x

  where
    m = lexeme "match"
    w = lexeme "watch" *> option QOS2 (symbp [("qos0", QOS0), ("qos1", QOS1), ("qos2", QOS2)])
    aFilter = qstr >>= maybe (fail "bad filter") pure . mkFilter

    parseField :: Parser Namer
    parseField = option (ConstName "value") ("field=" *> parsenamer)

    parseMsr :: Parser MeasurementNamer
    parseMsr = option (MeasurementNamer Nothing (FieldNum 0)) ("measurement=" *> parsemnamer)

    jsonpWatch :: Parser JSONPExtractor
    jsonpWatch = bt "{" "}" parsePee
      where parsePee = JSONPExtractor <$> (lexeme "measurement" *> parsemnamer) <*> parseTags <*> some parseX

    parseX = (,,) <$> lexeme qstr <* lexeme "<-" <*> lexeme qstr <*> option AutoVal parseValEx

parseFile :: Parser a -> String -> IO a
parseFile f s = readFile s >>= (either (fail . errorBundlePretty) pure . parse f s) . pack

parseConfFile :: String -> IO InfluxerConf
parseConfFile = parseFile parseInfluxerConf
