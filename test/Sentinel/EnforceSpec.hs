module Sentinel.EnforceSpec (spec) where

import qualified Data.Text as T
import           Test.Hspec

import           Sentinel.Enforce
import           Sentinel.Fixtures
import           Sentinel.Policy
import           Sentinel.Redact (emailSpans)
import           Sentinel.Types

spec :: Spec
spec = describe "Sentinel.Enforce" $ do

  describe "enforceRequest" $ do
    it "returns Right and applies redaction on allow" $ do
      let policy = redactWith (emailSpans . subjectText)
          req    = requestWithPrompt "mail a@b.com please"
      case enforceRequest policy req of
        Left v          -> expectationFailure ("unexpected Deny: " <> show v)
        Right governed  ->
          ("a@b.com" `T.isInfixOf` unPrompt (mrPrompt (unGoverned governed)))
            `shouldBe` False

    it "returns Left on a Deny decision" $ do
      let policy = denyList ["forbidden"]
          req    = requestWithPrompt "this is forbidden"
      case enforceRequest policy req of
        Left v  -> vReason v `shouldBe` DeniedByList "forbidden"
        Right _ -> expectationFailure "expected a Deny"

  describe "enforceResponse" $ do
    it "returns Right on allow and unGoverned yields the text" $ do
      let resp = rawResponseWithText "safe copy"
      case enforceResponse allowAll resp of
        Left v         -> expectationFailure ("unexpected Deny: " <> show v)
        Right governed ->
          mrespText (unGoverned governed) `shouldBe` "safe copy"

    it "returns Left when the response policy denies" $ do
      let policy = denyList ["guaranteed"]
          resp   = rawResponseWithText "guaranteed to win"
      case enforceResponse policy resp of
        Left v  -> vReason v `shouldBe` DeniedByList "guaranteed"
        Right _ -> expectationFailure "expected a Deny"
