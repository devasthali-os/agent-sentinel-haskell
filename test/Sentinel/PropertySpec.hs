module Sentinel.PropertySpec (spec) where

import           Data.Text (Text)
import qualified Data.Text as T
import           Test.Hspec
import           Test.Hspec.QuickCheck (prop)
import           Test.QuickCheck

import           Sentinel.Adtech (adtechRequestPolicy)
import           Sentinel.Enforce
import           Sentinel.Fixtures
import           Sentinel.Policy
import           Sentinel.Redact (emailSpans, phoneSpans, secretSpans)
import           Sentinel.Types

spec :: Spec
spec = describe "Sentinel property laws" $ do

  prop "redaction never leaks a detected email substring" $
    forAll genTextWithEmail $ \(email, text) ->
      not (email `T.isInfixOf` redactWith' emailSpans text)

  prop "redaction never leaks a detected phone substring" $
    forAll genTextWithPhone $ \(phone, text) ->
      not (phone `T.isInfixOf` redactWith' phoneSpans text)

  prop "redaction never leaks a detected secret/apiKey substring" $
    forAll genTextWithSecret $ \(secret, text) ->
      not (secret `T.isInfixOf` redactWith' secretSpans text)

  prop "Deny is absorbing under composition (left)" $
    forAll genWords $ \w ->
      forAll genPolicy $ \other ->
        let denied = denyIf (const (Just (DisallowedClaim "x")))
            s      = subjectFromText w
        in stepPolicy (denied <> other) s == Left (DisallowedClaim "x")

  prop "enforcement is idempotent on its own output" $
    forAll genWords $ \w ->
      let s = subjectFromText w
      in case stepPolicy adtechRequestPolicy s of
           Left _   -> True
           Right s1 -> stepPolicy adtechRequestPolicy s1 == Right s1

  prop "a Governed request always reflects the applied redaction policy" $
    forAll genTextWithEmail $ \(email, text) ->
      let policy = redactWith (emailSpans . subjectText)
          req    = requestWithPrompt text
      in case enforceRequest policy req of
           Left _         -> False  -- a redaction policy never denies
           Right governed ->
             not (email `T.isInfixOf` unPrompt (mrPrompt (unGoverned governed)))

  prop "composition is associative (semantically)" $
    forAll genWords $ \w ->
      forAll genPolicy $ \a ->
        forAll genPolicy $ \b ->
          forAll genPolicy $ \c ->
            let s = subjectFromText w
            in stepPolicy ((a <> b) <> c) s == stepPolicy (a <> (b <> c)) s

  prop "mempty is a two-sided identity (semantically)" $
    forAll genWords $ \w ->
      forAll genPolicy $ \a ->
        let s = subjectFromText w
        in stepPolicy (mempty <> a) s == stepPolicy a s
             && stepPolicy (a <> mempty) s == stepPolicy a s

-- | Apply a single detector's redaction effect to a text and return the result.
redactWith' :: (Text -> [RedactionSpan]) -> Text -> Text
redactWith' detector text =
  case stepPolicy (redactWith (detector . subjectText)) (subjectFromText text) of
    Left _  -> text
    Right s -> subjectText s

-- | A non-empty lowercase word.
genWord :: Gen Text
genWord = T.pack <$> listOf1 (elements ['a' .. 'z'])

-- | A short sentence of words.
genWords :: Gen Text
genWords = T.unwords <$> listOf1 genWord

-- | An email plus a surrounding sentence containing it.
genTextWithEmail :: Gen (Text, Text)
genTextWithEmail = do
  local  <- genAlnum
  domain <- genAlnum
  let email = local <> "@" <> domain <> ".com"
  (,) email <$> embed email

-- | A phone number plus a surrounding sentence containing it.
genTextWithPhone :: Gen (Text, Text)
genTextWithPhone = do
  a <- genDigits 3
  b <- genDigits 3
  c <- genDigits 4
  let phone = a <> "-" <> b <> "-" <> c
  (,) phone <$> embed phone
  where
    genDigits n = T.pack <$> vectorOf n (elements ['0' .. '9'])

-- | A secret/API key plus a surrounding sentence containing it.
genTextWithSecret :: Gen (Text, Text)
genTextWithSecret = do
  body <- T.pack <$> listOf1 (elements (['a' .. 'z'] ++ ['0' .. '9']))
  let secret = "sk-" <> body
  (,) secret <$> embed secret

-- | Surround a token with random words on both sides.
embed :: Text -> Gen Text
embed token = do
  prefix <- genWords
  suffix <- genWords
  pure (prefix <> " " <> token <> " " <> suffix)

genAlnum :: Gen Text
genAlnum = T.pack <$> listOf1 (elements (['a' .. 'z'] ++ ['0' .. '9']))

-- | A small grab-bag of policies for the algebraic laws.
genPolicy :: Gen Policy
genPolicy = elements
  [ allowAll
  , denyList ["zzz"]
  , transformWith (\s -> setSubjectText (subjectText s <> "!") s)
  , redactWith (emailSpans . subjectText)
  , denyIf (const Nothing)
  ]
