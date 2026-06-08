module Sentinel.RedactSpec (spec) where

import qualified Data.Text as T
import           Test.Hspec

import           Sentinel.Redact
import           Sentinel.Types

spec :: Spec
spec = describe "Sentinel.Redact" $ do

  describe "applyRedactions" $ do
    it "replaces a detected span with the labelled mask" $ do
      let input = "contact me at jane@example.com please"
          out   = applyRedactions (emailSpans input) input
      out `shouldBe` "contact me at " <> maskFor "email" <> " please"

    it "leaves text without detected spans unchanged" $ do
      let input = "no secrets here"
      applyRedactions (emailSpans input) input `shouldBe` input

    it "coalesces overlapping spans into one mask" $ do
      let input = "abcdefgh"
          spans = [RedactionSpan 0 4 "x", RedactionSpan 2 6 "y"]
      applyRedactions spans input `shouldBe` maskFor "x+y" <> "gh"

    it "clamps out-of-range spans safely" $ do
      let input = "short"
          spans = [RedactionSpan (-3) 100 "all"]
      applyRedactions spans input `shouldBe` maskFor "all"

    it "drops degenerate (empty) spans" $ do
      let input = "keep me"
          spans = [RedactionSpan 2 2 "empty"]
      applyRedactions spans input `shouldBe` input

  describe "detectors" $ do
    it "emailSpans finds an email and the secret never survives" $ do
      let input = "reach jane.doe@example.com today"
          out   = applyRedactions (emailSpans input) input
      ("jane.doe@example.com" `T.isInfixOf` out) `shouldBe` False

    it "phoneSpans finds a phone number" $ do
      let input = "call 555-867-5309 now"
          out   = applyRedactions (phoneSpans input) input
      ("555-867-5309" `T.isInfixOf` out) `shouldBe` False

    it "secretSpans finds a prefixed API key" $ do
      let input = "key sk-abcdef0123456789 end"
          out   = applyRedactions (secretSpans input) input
      ("sk-abcdef0123456789" `T.isInfixOf` out) `shouldBe` False

    it "phoneSpans ignores short digit runs" $ do
      let input = "room 42 floor 3"
      phoneSpans input `shouldBe` []
