-- | Precise domain vocabulary for the sentinel engine (spec §5.1, §8).
--
-- Parse-don't-validate at the boundary: the raw newtype constructors are
-- /not/ exported. Values can only be built through the smart constructors
-- (@mkX :: Text -> Either Violation X@), so an invalid domain value is
-- unrepresentable downstream (spec §10.1 bug class 5).
module Sentinel.Types
  ( -- * Domain newtypes (raw constructors intentionally hidden)
    Prompt
  , unPrompt
  , mkPrompt
  , SystemPrompt
  , unSystemPrompt
  , mkSystemPrompt
  , ModelName
  , unModelName
  , mkModelName
  , Principal
  , unPrincipal
  , mkPrincipal
  , Role
  , unRole
  , mkRole
  , Scope
  , unScope
  , mkScope
    -- * Request / response payloads
  , ModelRequest(..)
  , ModelResponse(..)
    -- * Policy decisions and violations (data, never exceptions)
  , Decision(..)
  , Reason(..)
  , Violation(..)
  , toViolation
  , reasonDetail
  , RedactionSpan(..)
    -- * Phantom-typing stage (promoted via DataKinds)
  , Stage(..)
    -- * Subject under policy
  , Subject(..)
  , subjectText
  , setSubjectText
  ) where

import           Data.Char (isAlphaNum)
import           Data.Text (Text)
import qualified Data.Text as T

-- | A user/agent prompt. Invariant: non-empty after trimming.
newtype Prompt = Prompt Text
  deriving (Eq, Show)

unPrompt :: Prompt -> Text
unPrompt (Prompt t) = t

mkPrompt :: Text -> Either Violation Prompt
mkPrompt t
  | T.null (T.strip t) = Left (toViolation (EmptyValue "prompt"))
  | otherwise          = Right (Prompt t)

-- | A system prompt. May be empty; bounded length.
newtype SystemPrompt = SystemPrompt Text
  deriving (Eq, Show)

maxSystemPromptLen :: Int
maxSystemPromptLen = 8192

unSystemPrompt :: SystemPrompt -> Text
unSystemPrompt (SystemPrompt t) = t

mkSystemPrompt :: Text -> Either Violation SystemPrompt
mkSystemPrompt t
  | T.length t > maxSystemPromptLen =
      Left (toViolation (MalformedValue "system prompt exceeds maximum length"))
  | otherwise = Right (SystemPrompt t)

-- | An Ollama-style model name with shape @name[:tag]@.
newtype ModelName = ModelName Text
  deriving (Eq, Show)

unModelName :: ModelName -> Text
unModelName (ModelName t) = t

mkModelName :: Text -> Either Violation ModelName
mkModelName raw
  | T.null t          = Left (toViolation (EmptyValue "model"))
  | validShape t      = Right (ModelName t)
  | otherwise         = Left (toViolation (MalformedValue ("invalid model name: " <> raw)))
  where
    t = T.strip raw
    validShape s = case T.splitOn ":" s of
      [nm]      -> okPart nm
      [nm, tag] -> okPart nm && okPart tag
      _         -> False
    okPart p = not (T.null p) && T.all okChar p
    okChar c = isAlphaNum c || c `elem` ['.', '_', '-']

-- | An identity making the request.
newtype Principal = Principal Text
  deriving (Eq, Show)

unPrincipal :: Principal -> Text
unPrincipal (Principal t) = t

mkPrincipal :: Text -> Either Violation Principal
mkPrincipal = nonEmpty Principal "principal"

-- | A role granted to the principal.
newtype Role = Role Text
  deriving (Eq, Show)

unRole :: Role -> Text
unRole (Role t) = t

mkRole :: Text -> Either Violation Role
mkRole = nonEmpty Role "role"

-- | A capability scope granted to the principal.
newtype Scope = Scope Text
  deriving (Eq, Show)

unScope :: Scope -> Text
unScope (Scope t) = t

mkScope :: Text -> Either Violation Scope
mkScope = nonEmpty Scope "scope"

-- | Shared helper for the simple non-empty smart constructors.
nonEmpty :: (Text -> a) -> Text -> Text -> Either Violation a
nonEmpty ctor field t
  | T.null (T.strip t) = Left (toViolation (EmptyValue field))
  | otherwise          = Right (ctor (T.strip t))

-- | A fully-parsed request. Every field is an already-validated newtype, so
-- no raw 'Text' reaches downstream logic.
data ModelRequest = ModelRequest
  { mrPrincipal :: Principal
  , mrRoles     :: [Role]
  , mrScopes    :: [Scope]
  , mrSystem    :: SystemPrompt
  , mrPrompt    :: Prompt
  , mrModel     :: ModelName
  } deriving (Eq, Show)

-- | A model response. Constructed only by a backend.
data ModelResponse = ModelResponse
  { mrespModel :: ModelName
  , mrespText  :: Text
  } deriving (Eq, Show)

-- | The outcome of running a policy against a subject. Decisions are data,
-- not exceptions. Exhaustive sum so that @-Wincomplete-patterns@ catches any
-- unhandled case (spec §10.1 bug class 4).
data Decision a
  = Allow
  | Deny Reason
  | Transform a
  | Redact [RedactionSpan]
  deriving (Eq, Show)

-- | A named reason carrying its relevant detail.
data Reason
  = EmptyValue Text
  | MalformedValue Text
  | ProtectedClassTargeting Text
  | DisallowedClaim Text
  | MissingRole Text
  | MissingScope Text
  | DeniedByList Text
  deriving (Eq, Show)

-- | A policy violation: a structured value the host can audit (spec §11).
data Violation = Violation
  { vReason :: Reason
  , vDetail :: Text
  } deriving (Eq, Show)

-- | Extract the human-readable detail carried by a reason.
reasonDetail :: Reason -> Text
reasonDetail = \case
  EmptyValue t              -> t
  MalformedValue t          -> t
  ProtectedClassTargeting t -> t
  DisallowedClaim t         -> t
  MissingRole t             -> t
  MissingScope t            -> t
  DeniedByList t            -> t

-- | Build a 'Violation' from a 'Reason', surfacing its detail.
toViolation :: Reason -> Violation
toViolation r = Violation r (reasonDetail r)

-- | A half-open redaction range @[rsStart, rsEnd)@ over a 'Text', with a
-- label used to build the mask. Invariant on accumulation:
-- @0 <= rsStart <= rsEnd <= length@.
data RedactionSpan = RedactionSpan
  { rsStart :: Int
  , rsEnd   :: Int
  , rsLabel :: Text
  } deriving (Eq, Ord, Show)

-- | Pipeline stage, promoted to a kind via @DataKinds@ for phantom typing of
-- 'Sentinel.Enforce.Governed'.
data Stage = Raw | Checked

-- | The thing under policy: either a request payload or a response payload.
data Subject
  = ReqSubject ModelRequest
  | RespSubject ModelResponse
  deriving (Eq, Show)

-- | The governable text of a subject (the prompt for requests, the generated
-- text for responses).
subjectText :: Subject -> Text
subjectText (ReqSubject r)  = unPrompt (mrPrompt r)
subjectText (RespSubject r) = mrespText r

-- | Replace the governable text of a subject. Used by redaction and transform
-- enforcement. The request prompt is rebuilt through the 'mkPrompt' smart
-- constructor so its non-empty invariant is preserved; if the new text would be
-- invalid (e.g. an empty string), the existing valid prompt is kept unchanged.
-- (In practice redaction only ever replaces secrets with a non-empty mask, so
-- the fallback is defensive.)
setSubjectText :: Text -> Subject -> Subject
setSubjectText t (ReqSubject r)  =
  case mkPrompt t of
    Right p -> ReqSubject r { mrPrompt = p }
    Left _  -> ReqSubject r
setSubjectText t (RespSubject r) = RespSubject r { mrespText = t }
