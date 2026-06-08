-- | STORY-07 — documented @should-not-compile@ cases proving the no-bypass
-- guarantee (spec §10.1 bug classes 1 & 3).
--
-- The guarantee is structural: 'Sentinel.Enforce.Governed' is exported as an
-- /abstract/ type (its constructor is hidden). The only way to obtain a
-- @Governed 'Checked@ value is through 'enforceRequest' / 'enforceResponse', and
-- the only thing 'Sentinel.Model.runModel' returns is a @Governed 'Raw
-- ModelResponse@ — which has no public accessor. The snippets below therefore
-- fail to type-check. They are kept as comments so the suite itself stays green
-- and offline; uncommenting any one of them makes `stack build` fail with the
-- quoted error.
--
-- === Negative case 1 — calling the model with an ungoverned request
-- (bug class 1: forgetting to apply a policy before calling the model)
--
-- @
-- bypassRequest :: ModelBackend -> ModelRequest -> IO (Governed 'Raw ModelResponse)
-- bypassRequest b req = runModel b req
-- @
--
-- Expected error (GHC 9.6.6):
--
-- @
--   • Couldn't match expected type ‘Governed 'Checked ModelRequest’
--                 with actual type ‘ModelRequest’
-- @
--
-- There is no constructor in scope to build a @Governed 'Checked ModelRequest@,
-- and 'enforceRequest' is the only producer — so the model cannot be called
-- without first running the request policy.
--
-- === Negative case 2 — reading raw model output without response enforcement
-- (bug class 3: returning an unchecked model response to the agent)
--
-- This is the /real/ bypass this design eliminates. 'runModel' returns a
-- @Governed 'Raw ModelResponse@, and the only way to get a 'ModelResponse' out
-- of it is to run 'enforceResponse' (the sole producer of a @'Checked@ value,
-- on which 'unGoverned' is defined):
--
-- @
-- bypassResponse :: ModelBackend -> Governed 'Checked ModelRequest -> IO Text
-- bypassResponse b g = mrespText <$> runModel b g
--   -- TYPE ERROR: runModel returns 'Governed 'Raw ModelResponse', and
--   -- 'mrespText' expects a bare 'ModelResponse'.
-- @
--
-- Expected error (GHC 9.6.6):
--
-- @
--   • Couldn't match type ‘Governed 'Raw ModelResponse’ with ‘ModelResponse’
--     Expected: Governed 'Raw ModelResponse -> Text
--       Actual: ModelResponse -> Text
-- @
--
-- Equivalently, @unGoverned <$> runModel b g@ fails because 'unGoverned' is
-- @'Checked@-only, not @'Raw@.
--
-- === Negative case 3 — fabricating a checked value directly
--
-- @
-- forge :: ModelResponse -> Governed 'Checked ModelResponse
-- forge = Governed
-- @
--
-- Expected error: @Data constructor not in scope: Governed@ (the constructor is
-- unexported), so a checked value cannot be forged outside 'Sentinel.Enforce'.
-- Note 'rawResponse' /is/ exported, but it only mints a @'Raw@ value, which is
-- itself unreadable until enforced.
module Sentinel.NoBypassSpec (spec) where

import qualified Data.Text as T
import           Test.Hspec

import           Sentinel.Adtech (adtechRequestPolicy, adtechResponsePolicy)
import           Sentinel.Enforce
import           Sentinel.Fixtures
import           Sentinel.Model (ModelBackend (..))
import           Sentinel.Model.Mock (mockBackend)
import           Sentinel.Types

spec :: Spec
spec = describe "no-bypass guarantee (STORY-07)" $ do

  it "the ONLY way to call the model is via an enforced request" $ do
    -- Positive counterpart of negative case 1: the model is reachable only
    -- after enforceRequest mints a Governed 'Checked value.
    let req = requestWithPrompt "Draft ad copy for running shoes."
    case enforceRequest adtechRequestPolicy req of
      Left v         -> expectationFailure ("unexpected Deny: " <> show v)
      Right governed -> do
        raw <- runModel mockBackend governed
        -- 'raw' is Governed 'Raw: its text is unreadable until enforced.
        case enforceResponse adtechResponsePolicy raw of
          Left v          -> expectationFailure ("unexpected Deny: " <> show v)
          Right governed' ->
            T.null (mrespText (unGoverned governed')) `shouldBe` False

  it "response enforcement DENIES a disallowed-claim response end-to-end" $ do
    -- Exercises the real response path (negative case 2's positive counterpart):
    -- a raw response carrying a disallowed claim cannot be read; it yields Left.
    let raw = rawResponseWithText "this trainer is guaranteed to win, 100% risk-free"
    case enforceResponse adtechResponsePolicy raw of
      Left v  -> vReason v `shouldBe` DisallowedClaim "guaranteed"
      Right _ -> expectationFailure "expected a disallowed-claim Deny"

  it "response enforcement ALLOWS a clean response and yields governed text" $ do
    let raw = rawResponseWithText "Lace up and chase your next personal record."
    case enforceResponse adtechResponsePolicy raw of
      Left v          -> expectationFailure ("unexpected Deny: " <> show v)
      Right governed' ->
        T.null (mrespText (unGoverned governed')) `shouldBe` False
