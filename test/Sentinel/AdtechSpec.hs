module Sentinel.AdtechSpec (spec) where

import qualified Data.Text as T
import           Test.Hspec

import           Sentinel.Adtech
import           Sentinel.Enforce
import           Sentinel.Fixtures
import           Sentinel.Model (ModelBackend (..))
import           Sentinel.Model.Mock (mockBackend)
import           Sentinel.Types

spec :: Spec
spec = describe "Sentinel.Adtech (offline, mock backend)" $ do

  describe "request policy" $ do
    it "redacts PII in a request and never leaks the email" $ do
      let req = requestWithPrompt "ad copy; email jane@example.com"
      case enforceRequest adtechRequestPolicy req of
        Left v         -> expectationFailure ("unexpected Deny: " <> show v)
        Right governed ->
          ("jane@example.com"
             `T.isInfixOf` unPrompt (mrPrompt (unGoverned governed)))
            `shouldBe` False

    it "denies protected-class targeting and never reaches the model" $ do
      let req = requestWithPrompt "target users by religion"
      case enforceRequest adtechRequestPolicy req of
        Left v  -> vReason v `shouldBe` ProtectedClassTargeting "religion"
        Right _ -> expectationFailure "expected a protected-class Deny"

  describe "response policy" $ do
    it "denies a disallowed claim" $ do
      let resp = rawResponseWithText "this is guaranteed to work"
      case enforceResponse adtechResponsePolicy resp of
        Left v  -> vReason v `shouldBe` DisallowedClaim "guaranteed"
        Right _ -> expectationFailure "expected a disallowed-claim Deny"

  describe "end-to-end with the mock backend" $ do
    it "allows a clean request and surfaces governed output" $ do
      let req = requestWithPrompt
                  "Draft ad copy for running shoes for marathon hobbyists."
      result <- runGoverned req
      case result of
        Right out -> (T.null out) `shouldBe` False
        Left v    -> expectationFailure ("unexpected Deny: " <> show v)

    it "denies a bold prompt whose copy contains disallowed claims" $ do
      let req = requestWithPrompt "Draft a BOLD ad for running shoes."
      result <- runGoverned req
      case result of
        Left v  -> vReason v `shouldBe` DisallowedClaim "guaranteed"
        Right o -> expectationFailure ("expected response Deny, got: " <> T.unpack o)

-- | Run the full governed pipeline over the mock backend, returning either the
-- first violation or the final governed text.
runGoverned :: ModelRequest -> IO (Either Violation T.Text)
runGoverned req =
  case enforceRequest adtechRequestPolicy req of
    Left v          -> pure (Left v)
    Right governed  -> do
      rawResp <- runModel mockBackend governed
      pure $ case enforceResponse adtechResponsePolicy rawResp of
        Left v          -> Left v
        Right governed' -> Right (mrespText (unGoverned governed'))
