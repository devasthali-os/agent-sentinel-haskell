-- | The model boundary as a port (spec §5.4).
--
-- A backend can never be called with ungoverned input: 'runModel' accepts only
-- a @Governed 'Checked ModelRequest@. It returns a @Governed 'Raw ModelResponse@
-- — an /unchecked/ response whose text cannot be read until it has passed
-- through 'Sentinel.Enforce.enforceResponse'. Response-side enforcement is
-- therefore type-enforced, not a matter of discipline.
module Sentinel.Model
  ( ModelBackend(..)
  ) where

import           Sentinel.Enforce (Governed)
import           Sentinel.Types (ModelRequest, ModelResponse, Stage (..))

-- | A pluggable model backend (mock or Ollama).
newtype ModelBackend = ModelBackend
  { runModel :: Governed 'Checked ModelRequest -> IO (Governed 'Raw ModelResponse)
  }
