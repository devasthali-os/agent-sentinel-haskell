-- | Policies as composable, typed, first-class values (spec §5.2, finding R4).
--
-- Composition semantics (documented and property-tested):
--
--   * __Deny is absorbing / short-circuiting__: once any policy yields
--     @Deny r@, the composite is @Deny r@ and later policies do not run.
--   * __Transforms chain left-to-right__: the (possibly transformed) subject
--     produced by one policy is fed to the next.
--   * __Redactions accumulate and never un-redact__: each redaction is applied
--     to the threaded subject before the next policy runs, so a masked secret
--     can never be re-detected or re-exposed downstream.
--   * __Allow is the identity__ and @mempty@ is allow-all.
--   * Order is significant and documented; combinators are pure.
--
-- Composition is associative with respect to its effect on a subject, because
-- 'stepPolicy' is a homomorphism into Kleisli arrows of 'Either' 'Reason'.
module Sentinel.Policy
  ( Policy(..)
  , mkPolicy
  , allowAll
  , allowList
  , denyList
  , denyIf
  , redactWith
  , transformWith
  , requireRole
  , requireScope
  , composeP
  , stepPolicy
  , firstHit
  ) where

import           Data.Text (Text)
import qualified Data.Text as T

import           Sentinel.Redact (applyRedactions)
import           Sentinel.Types

-- | A named policy mapping a subject to a decision.
data Policy = Policy
  { policyName :: Text
  , runPolicy  :: Subject -> Decision Subject
  }

-- | Shown by name (the function field is opaque); useful for QuickCheck output.
instance Show Policy where
  show p = "Policy " <> show (policyName p)

-- | Build a named policy.
mkPolicy :: Text -> (Subject -> Decision Subject) -> Policy
mkPolicy = Policy

-- | The allow-everything policy; identity element of composition.
allowAll :: Policy
allowAll = Policy "allow-all" (const Allow)

-- | Reduce a single policy's decision to its effect on the threaded subject:
-- @Left reason@ for a denial, or @Right subject'@ for the (possibly modified)
-- subject. This is the associative core of composition.
stepPolicy :: Policy -> Subject -> Either Reason Subject
stepPolicy p s = case runPolicy p s of
  Allow        -> Right s
  Deny r       -> Left r
  Transform s' -> Right s'
  Redact spans -> Right (setSubjectText (applyRedactions spans (subjectText s)) s)

-- | Sequential composition with the documented semantics. Deny short-circuits;
-- otherwise the threaded subject flows through both policies.
composeP :: Policy -> Policy -> Policy
composeP p1 p2 = Policy name $ \s ->
  case stepPolicy p1 s of
    Left r  -> Deny r
    Right s1 -> case stepPolicy p2 s1 of
      Left r   -> Deny r
      Right s2 -> if s2 == s then Allow else Transform s2
  where
    name = policyName p1 <> " <> " <> policyName p2

instance Semigroup Policy where
  (<>) = composeP

instance Monoid Policy where
  mempty = allowAll

-- | Deny if the subject's text contains any listed (case-insensitive) term.
denyList :: [Text] -> Policy
denyList terms = Policy "denyList" $ \s ->
  case firstHit terms (subjectText s) of
    Just t  -> Deny (DeniedByList t)
    Nothing -> Allow

-- | Deny unless the subject's text contains at least one listed term.
allowList :: [Text] -> Policy
allowList terms = Policy "allowList" $ \s ->
  case firstHit terms (subjectText s) of
    Just _  -> Allow
    Nothing -> Deny (DeniedByList "no allow-listed term present")

-- | The first listed term that appears (case-insensitively) in the haystack.
firstHit :: [Text] -> Text -> Maybe Text
firstHit terms hay =
  let lower = T.toLower hay
  in case filter (\t -> T.toLower t `T.isInfixOf` lower) terms of
       (t : _) -> Just t
       []      -> Nothing

-- | Deny when the predicate yields a reason; otherwise allow.
denyIf :: (Subject -> Maybe Reason) -> Policy
denyIf f = Policy "denyIf" $ \s -> maybe Allow Deny (f s)

-- | Redact the spans computed from the subject; allow if there are none.
redactWith :: (Subject -> [RedactionSpan]) -> Policy
redactWith f = Policy "redactWith" $ \s ->
  case f s of
    []    -> Allow
    spans -> Redact spans

-- | Apply a pure transform to the subject.
transformWith :: (Subject -> Subject) -> Policy
transformWith f = Policy "transformWith" (Transform . f)

-- | Require the subject (a request) to carry a role, else deny.
requireRole :: Role -> Policy
requireRole role = Policy "requireRole" $ \case
  ReqSubject req
    | role `elem` mrRoles req -> Allow
    | otherwise               -> Deny (MissingRole (unRole role))
  RespSubject _               -> Deny (MissingRole (unRole role))

-- | Require the subject (a request) to carry a scope, else deny.
requireScope :: Scope -> Policy
requireScope scope = Policy "requireScope" $ \case
  ReqSubject req
    | scope `elem` mrScopes req -> Allow
    | otherwise                 -> Deny (MissingScope (unScope scope))
  RespSubject _                 -> Deny (MissingScope (unScope scope))
