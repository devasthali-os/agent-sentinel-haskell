-- | A deterministic in-process 'ModelBackend' (spec §9, STORY-12).
--
-- The mock is the sole backend used by the offline test suite and by
-- @adtech-agent --mock@. Output is a pure function of the checked request, so
-- policy decisions are reproducible without any network.
module Sentinel.Model.Mock
  ( mockBackend
  ) where

import qualified Data.Text as T

import           Sentinel.Enforce (rawResponse, unGoverned)
import           Sentinel.Model (ModelBackend (..))
import           Sentinel.Types

-- | Deterministic backend. By default it returns brand-safe ad copy; if the
-- prompt asks for a \"bold\" pitch it returns copy containing disallowed
-- claims, so the response-side brand-safety policy can be demonstrated.
mockBackend :: ModelBackend
mockBackend = ModelBackend $ \governed ->
  let req    = unGoverned governed
      prompt = T.toLower (unPrompt (mrPrompt req))
      text
        | "bold" `T.isInfixOf` prompt =
            "Buy now: this trainer is guaranteed to win you every race, \
            \100% risk-free, a miracle cure for slow times!"
        | otherwise =
            "Lace up and chase your next PR with our cushioned trainer."
  in pure (rawResponse (ModelResponse (mrModel req) text))
