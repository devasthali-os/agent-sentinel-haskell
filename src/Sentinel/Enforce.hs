-- | The single enforcement chokepoint (spec §5.3, §10.1).
--
-- This module owns the 'Governed' type and is the /only/ place that can mint a
-- @'Checked@ value. The data constructor is deliberately __not__ exported, so:
--
--   * the model boundary ('Sentinel.Model.ModelBackend') accepts only a
--     @Governed 'Checked ModelRequest@, whose sole producer is 'enforceRequest';
--   * response text is readable only via 'unGoverned' on a
--     @Governed 'Checked ModelResponse@, whose sole producer is 'enforceResponse'.
--
-- Skipping enforcement is therefore a type error, not a code-review miss.
module Sentinel.Enforce
  ( -- | Exported as an abstract type: the constructor is hidden on purpose.
    Governed
  , rawResponse
  , enforceRequest
  , enforceResponse
  , unGoverned
  ) where

import           Sentinel.Policy (Policy, stepPolicy)
import           Sentinel.Types

-- | A value at phantom 'Stage' @s@. The constructor is unexported: only this
-- module can build a @'Checked@ value, and a @'Raw@ value can only be built via
-- 'rawResponse'.
newtype Governed (s :: Stage) a = Governed a

-- | Tag a freshly-produced 'ModelResponse' as @'Raw@ (i.e. unchecked). This is
-- safe to export: a @'Raw@ value can neither be unwrapped ('unGoverned' is
-- @'Checked@-only) nor sent to the model ('Sentinel.Model.runModel' takes a
-- @'Checked@ request). The /only/ way to read its text is to pass it through
-- 'enforceResponse' first.
rawResponse :: ModelResponse -> Governed 'Raw ModelResponse
rawResponse = Governed

-- | Run the request policy. Applies transforms and redactions inside, and
-- returns either the checked request or a structured violation.
enforceRequest
  :: Policy
  -> ModelRequest
  -> Either Violation (Governed 'Checked ModelRequest)
enforceRequest policy req =
  case stepPolicy policy (ReqSubject req) of
    Left reason             -> Left (toViolation reason)
    Right (ReqSubject req') -> Right (Governed req')
    Right (RespSubject _)   ->
      Left (toViolation (MalformedValue "request policy produced a response subject"))

-- | Run the response policy on a __raw__ governed response (the only thing
-- 'Sentinel.Model.runModel' can return). This is the sole producer of a
-- @Governed 'Checked ModelResponse@, so response-side enforcement cannot be
-- skipped: there is no public way to extract a 'ModelResponse' from a @'Raw@
-- value other than through this function.
enforceResponse
  :: Policy
  -> Governed 'Raw ModelResponse
  -> Either Violation (Governed 'Checked ModelResponse)
enforceResponse policy (Governed resp) =
  case stepPolicy policy (RespSubject resp) of
    Left reason               -> Left (toViolation reason)
    Right (RespSubject resp') -> Right (Governed resp')
    Right (ReqSubject _)      ->
      Left (toViolation (MalformedValue "response policy produced a request subject"))

-- | Read the underlying value. Defined only for @'Checked@; there is no
-- @unGoverned@ for @'Raw@ and no way to fabricate a @'Checked@ value outside
-- this module.
unGoverned :: Governed 'Checked a -> a
unGoverned (Governed a) = a
