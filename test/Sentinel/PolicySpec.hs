module Sentinel.PolicySpec (spec) where

import qualified Data.Text as T
import           Test.Hspec

import           Sentinel.Fixtures
import           Sentinel.Policy
import           Sentinel.Redact (emailSpans, maskFor)
import           Sentinel.Types

spec :: Spec
spec = describe "Sentinel.Policy" $ do

  describe "primitive combinators" $ do
    it "allowAll allows everything" $
      runPolicy allowAll (subjectFromText "anything") `shouldBe` Allow

    it "denyList denies on a matching substring" $
      stepPolicy (denyList ["forbidden"]) (subjectFromText "this is forbidden")
        `shouldBe` Left (DeniedByList "forbidden")

    it "denyList allows when no term matches" $
      stepPolicy (denyList ["forbidden"]) (subjectFromText "all good")
        `shouldBe` Right (subjectFromText "all good")

    it "denyIf denies when the predicate fires" $
      stepPolicy (denyIf (const (Just (MalformedValue "boom"))))
                 (subjectFromText "x")
        `shouldBe` Left (MalformedValue "boom")

    it "transformWith rewrites the subject text" $ do
      let p = transformWith (\subj -> setSubjectText (T.toUpper (subjectText subj)) subj)
      stepPolicy p (subjectFromText "hi")
        `shouldBe` Right (subjectFromText "HI")

    it "redactWith applies detected spans" $ do
      let p   = redactWith (emailSpans . subjectText)
          inp = subjectFromText "mail me a@b.com"
      stepPolicy p inp
        `shouldBe` Right (setSubjectText ("mail me " <> maskFor "email") inp)

    it "requireRole denies when the role is absent" $ do
      let req = ReqSubject (requestWithPrompt "x")
      stepPolicy (requireRole (forceRight (mkRole "admin"))) req
        `shouldBe` Left (MissingRole "admin")

    it "requireRole allows when the role is present" $ do
      let req = ReqSubject (requestWithPrompt "x")
      stepPolicy (requireRole (forceRight (mkRole "copywriter"))) req
        `shouldBe` Right req

  describe "composition semantics" $ do
    it "Deny is absorbing / short-circuiting" $ do
      let denied  = denyIf (const (Just (DisallowedClaim "d")))
          other   = transformWith (setSubjectText "changed")
      stepPolicy (denied <> other) (subjectFromText "x")
        `shouldBe` Left (DisallowedClaim "d")

    it "a later Deny still denies the composite" $ do
      let t      = transformWith (\s -> setSubjectText (subjectText s <> "!") s)
          denied = denyIf (const (Just (DisallowedClaim "late")))
      stepPolicy (t <> denied) (subjectFromText "x")
        `shouldBe` Left (DisallowedClaim "late")

    it "transforms chain left to right" $ do
      let f = transformWith (\s -> setSubjectText (subjectText s <> "a") s)
          g = transformWith (\s -> setSubjectText (subjectText s <> "b") s)
      stepPolicy (f <> g) (subjectFromText "x")
        `shouldBe` Right (subjectFromText "xab")

    it "mempty is the left identity (semantically)" $ do
      let p = transformWith (\s -> setSubjectText (subjectText s <> "!") s)
          s = subjectFromText "x"
      stepPolicy (mempty <> p) s `shouldBe` stepPolicy p s

    it "mempty is the right identity (semantically)" $ do
      let p = denyList ["nope"]
          s = subjectFromText "nope here"
      stepPolicy (p <> mempty) s `shouldBe` stepPolicy p s
