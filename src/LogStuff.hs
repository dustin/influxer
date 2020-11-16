module LogStuff where

import           Data.List (intercalate)

deLine :: String -> String
deLine = dedupSpace . intercalate " " . lines

dedupSpace :: String -> String
dedupSpace s = let (l, r) = span (/= ' ') s in
                 case r of
                   "" -> l
                   _  -> l <> " " <> dedupSpace (dropWhile (== ' ') r)
