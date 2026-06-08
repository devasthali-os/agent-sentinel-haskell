-- | Redaction helpers (spec §5.5, finding R5).
--
-- Guarantee (property-tested in the suite): for any input and the spans these
-- detectors produce, the detected secret substring does /not/ appear in the
-- output of 'applyRedactions'. The mask token is chosen so it can never equal
-- the original secret.
module Sentinel.Redact
  ( applyRedactions
  , emailSpans
  , phoneSpans
  , secretSpans
  , maskFor
  ) where

import           Data.Char (isAlphaNum, isDigit)
import           Data.List (sortOn)
import           Data.Text (Text)
import qualified Data.Text as T

import           Sentinel.Types (RedactionSpan (..))

-- | Build the fixed, non-reversible mask for a label, e.g. @‹REDACTED:email›@.
maskFor :: Text -> Text
maskFor label = "\x2039REDACTED:" <> label <> "\x203A"

-- | Apply a set of redaction spans to a text. Spans are clamped to the valid
-- range, sorted, and overlapping/adjacent spans are coalesced before each
-- region is replaced with its mask. Redaction never un-redacts.
applyRedactions :: [RedactionSpan] -> Text -> Text
applyRedactions spans input =
    rebuild 0 (coalesce (sortOn rsStart (clampAll spans)))
  where
    len = T.length input

    clampAll = foldr keep []
      where
        keep s acc =
          let st = max 0 (min len (rsStart s))
              en = max 0 (min len (rsEnd s))
          in if st < en then s { rsStart = st, rsEnd = en } : acc else acc

    rebuild :: Int -> [RedactionSpan] -> Text
    rebuild cursor [] = sliceFrom cursor
    rebuild cursor (s : rest) =
      between cursor (rsStart s) <> maskFor (rsLabel s) <> rebuild (rsEnd s) rest

    between a b = T.take (b - a) (T.drop a input)
    sliceFrom a = T.drop a input

-- | Merge overlapping or adjacent spans (input must be sorted by start).
coalesce :: [RedactionSpan] -> [RedactionSpan]
coalesce [] = []
coalesce (x : xs) = go x xs
  where
    go cur [] = [cur]
    go cur (y : ys)
      | rsStart y <= rsEnd cur =
          go cur { rsEnd = max (rsEnd cur) (rsEnd y)
                 , rsLabel = mergeLabel (rsLabel cur) (rsLabel y)
                 } ys
      | otherwise = cur : go y ys
    mergeLabel a b
      | a == b    = a
      | otherwise = a <> "+" <> b

-- | Detect email-like substrings (a non-space run containing @\@@ and a dot
-- after it). Illustrative, not an exhaustive classifier (spec R8).
emailSpans :: Text -> [RedactionSpan]
emailSpans = spansForTokens "email" isEmail
  where
    isEmail tok = case T.breakOn "@" tok of
      (local, rest)
        | T.null local                    -> False
        | T.null rest                     -> False
        | otherwise ->
            let domain = T.drop 1 rest
            in not (T.null domain)
                 && T.any (== '.') domain
                 && T.last domain /= '.'

-- | Detect phone-like substrings (a run of phone characters with 7–15 digits).
phoneSpans :: Text -> [RedactionSpan]
phoneSpans input = filterByDigits (runSpans "phone" isPhoneChar input)
  where
    isPhoneChar c = isDigit c || c `elem` ['+', '-', '(', ')']
    filterByDigits = filter enoughDigits
    enoughDigits s =
      let tok = sliceSpan input s
          d   = T.length (T.filter isDigit tok)
      in d >= 7 && d <= 15

-- | Detect secret-like tokens (known prefixes or long alphanumeric blobs).
secretSpans :: Text -> [RedactionSpan]
secretSpans = spansForTokens "secret" isSecret
  where
    isSecret tok =
      any (`T.isPrefixOf` tok) secretPrefixes
        || (T.length tok >= 24 && T.all isAlphaNum tok)
    secretPrefixes = ["sk-", "AKIA", "ghp_", "xoxb-", "AIza"]

-- | Build labelled spans for every whitespace-delimited token satisfying the
-- predicate.
spansForTokens :: Text -> (Text -> Bool) -> Text -> [RedactionSpan]
spansForTokens label predicate input =
  [ s | s <- tokenSpans label input, predicate (sliceSpan input s) ]

-- | Slice the substring covered by a span.
sliceSpan :: Text -> RedactionSpan -> Text
sliceSpan input s = T.take (rsEnd s - rsStart s) (T.drop (rsStart s) input)

-- | Spans of every maximal non-whitespace run.
tokenSpans :: Text -> Text -> [RedactionSpan]
tokenSpans label = runSpans label (not . isSpaceChar)
  where
    isSpaceChar c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

-- | Spans of every maximal run of characters satisfying the predicate.
runSpans :: Text -> (Char -> Bool) -> Text -> [RedactionSpan]
runSpans label predicate input = go 0 (T.unpack input)
  where
    go _ [] = []
    go i (c : cs)
      | predicate c =
          let runLen = 1 + length (takeWhile predicate cs)
          in RedactionSpan i (i + runLen) label : go (i + runLen) (drop (runLen - 1) cs)
      | otherwise = go (i + 1) cs
