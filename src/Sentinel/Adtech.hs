-- | The flagship adtech policy bundle (spec §5.7, STORY-11).
--
-- Built __only__ from the 'Sentinel.Policy' / 'Sentinel.Redact' primitives
-- — no change to the enforcement core was needed to add it (PRD G2). The word
-- lists are illustrative typed values, not the product's intelligence (spec A3).
module Sentinel.Adtech
  ( adtechRequestPolicy
  , adtechResponsePolicy
  , protectedClassTerms
  , disallowedClaimTerms
  ) where

import           Data.Text (Text)

import           Sentinel.Policy
import           Sentinel.Redact (emailSpans, phoneSpans, secretSpans)
import           Sentinel.Types

-- | Request policy: redact PII (email/phone/secrets), then deny any targeting
-- of protected-class attributes. Deny short-circuits, so a denied request is
-- never sent to the model.
adtechRequestPolicy :: Policy
adtechRequestPolicy = redactPII <> denyProtectedClass

-- | Response policy: deny disallowed brand-safety claims, then redact any PII
-- the model may have leaked back into the copy.
adtechResponsePolicy :: Policy
adtechResponsePolicy = denyDisallowedClaims <> redactPII

-- | Redact emails, phones, and secret-like tokens found in the subject text.
redactPII :: Policy
redactPII = redactWith $ \s ->
  let txt = subjectText s
  in emailSpans txt <> phoneSpans txt <> secretSpans txt

-- | Deny when the prompt targets a protected-class attribute.
denyProtectedClass :: Policy
denyProtectedClass = denyIf $ \s ->
  ProtectedClassTargeting <$> firstHit protectedClassTerms (subjectText s)

-- | Deny when the generated copy contains a disallowed claim.
denyDisallowedClaims :: Policy
denyDisallowedClaims = denyIf $ \s ->
  DisallowedClaim <$> firstHit disallowedClaimTerms (subjectText s)

-- | Illustrative protected-class targeting attributes.
protectedClassTerms :: [Text]
protectedClassTerms =
  [ "race"
  , "religion"
  , "religious"
  , "ethnicity"
  , "national origin"
  , "sexual orientation"
  , "gender identity"
  , "health condition"
  , "disability"
  , "pregnancy"
  ]

-- | Illustrative disallowed brand-safety claims.
disallowedClaimTerms :: [Text]
disallowedClaimTerms =
  [ "guaranteed"
  , "guarantee"
  , "miracle cure"
  , "100% risk-free"
  , "risk-free"
  , "cure-all"
  , "no side effects"
  ]
