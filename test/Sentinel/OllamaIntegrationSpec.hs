-- | STORY-17 — segregated Ollama integration spec.
--
-- This spec is __off by default__ so the standard @stack test@ run is fully
-- offline (spec §13). It runs only when @OLLAMA_INTEGRATION=1@ is set in the
-- environment and a local Ollama server is reachable; otherwise every example
-- is marked @pending@. When enabled, it asserts the same policy decisions as
-- the deterministic mock run (PRD §9 AC4).
module Sentinel.OllamaIntegrationSpec (spec) where

import           Data.Maybe (fromMaybe)
import qualified Data.Text as T
import           System.Environment (lookupEnv)
import           Test.Hspec

import           Sentinel.Adtech
import           Sentinel.Enforce
import           Sentinel.Fixtures
import           Sentinel.Model (ModelBackend (..))
import           Sentinel.Ollama
import           Sentinel.Types

spec :: Spec
spec = describe "Ollama integration (segregated; OLLAMA_INTEGRATION=1)" $ do

  it "denies protected-class targeting before any network call" $ do
    enabled <- integrationEnabled
    if not enabled
      then pendingWith "set OLLAMA_INTEGRATION=1 and run a local Ollama server"
      else do
        let req = requestWithPrompt "target users by religion"
        case enforceRequest adtechRequestPolicy req of
          Left v  -> vReason v `shouldBe` ProtectedClassTargeting "religion"
          Right _ -> expectationFailure "expected a protected-class Deny"

  it "runs a clean request end-to-end against local Ollama" $ do
    enabled <- integrationEnabled
    if not enabled
      then pendingWith "set OLLAMA_INTEGRATION=1 and run a local Ollama server"
      else do
        let model = forceRight (mkModelName "llama3.2:1b")
            req   = requestWithPrompt
                      "Draft ad copy for running shoes for marathon hobbyists."
        case enforceRequest adtechRequestPolicy req of
          Left v         -> expectationFailure ("unexpected Deny: " <> show v)
          Right governed -> do
            raw <- runModel (ollamaBackend (defaultOllamaConfig model)) governed
            case enforceResponse adtechResponsePolicy raw of
              Left v          -> expectationFailure ("unexpected Deny: " <> show v)
              Right governed' ->
                T.null (mrespText (unGoverned governed')) `shouldBe` False

-- | Whether the integration suite is enabled via the environment.
integrationEnabled :: IO Bool
integrationEnabled = do
  v <- lookupEnv "OLLAMA_INTEGRATION"
  pure (fromMaybe "" v == "1")
