-- | Test-only fixtures and helpers. Uses 'error' on smart-constructor failure
-- because every literal here is valid by construction.
module Sentinel.Fixtures
  ( forceRight
  , requestWithPrompt
  , responseWithText
  , rawResponseWithText
  , subjectFromText
  ) where

import           Data.Text (Text)
import qualified Data.Text as T

import           Sentinel.Enforce (Governed, rawResponse)
import           Sentinel.Types

-- | Unwrap an 'Either' 'Violation', failing loudly in tests on a 'Left'.
forceRight :: Either Violation a -> a
forceRight (Right a) = a
forceRight (Left v)  = error ("fixture built an invalid value: " <> show v)

-- | A valid request whose prompt is the given text.
requestWithPrompt :: Text -> ModelRequest
requestWithPrompt promptText = ModelRequest
  { mrPrincipal = forceRight (mkPrincipal "agent-test")
  , mrRoles     = [forceRight (mkRole "copywriter")]
  , mrScopes    = [forceRight (mkScope "ad:create")]
  , mrSystem    = forceRight (mkSystemPrompt "system")
  , mrPrompt    = forceRight (mkPrompt promptText)
  , mrModel     = forceRight (mkModelName "llama3.2:1b")
  }

-- | A response carrying the given text.
responseWithText :: Text -> ModelResponse
responseWithText txt = ModelResponse
  { mrespModel = forceRight (mkModelName "llama3.2:1b")
  , mrespText  = txt
  }

-- | A raw governed response carrying the given text, ready for 'enforceResponse'.
rawResponseWithText :: Text -> Governed 'Raw ModelResponse
rawResponseWithText = rawResponse . responseWithText

-- | A request subject whose prompt is the given text (handy for policy tests).
subjectFromText :: Text -> Subject
subjectFromText = ReqSubject . requestWithPrompt . ensureNonEmpty
  where
    ensureNonEmpty t = if T.null (T.strip t) then "x" else t
