-- | @adtech-agent@: the composition root demonstrating end-to-end sentinel
-- (spec §5.7, §6.3, STORY-14).
--
-- Wires @enforceRequest -> runModel -> enforceResponse@, printing the per-stage
-- 'Decision' / 'Violation' trace and the final governed output. Runs offline
-- with the deterministic mock backend by default (@--mock@); @--ollama@ targets
-- a local Ollama server.
module Main (main) where

import           Control.Exception (try)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           System.Environment (getArgs)
import           System.Exit (exitFailure)

import           Sentinel.Adtech
import           Sentinel.Enforce
import           Sentinel.Model (ModelBackend (..))
import           Sentinel.Model.Mock (mockBackend)
import           Sentinel.Ollama
import           Sentinel.Redact (emailSpans, phoneSpans, secretSpans)
import           Sentinel.Types

-- | Demo scenarios driving different policy outcomes.
data Scenario = Clean | Pii | ProtectedClass | BrandUnsafe
  deriving (Eq, Show)

data BackendChoice = MockBackend | OllamaBackend
  deriving (Eq, Show)

main :: IO ()
main = do
  args <- getArgs
  let backendChoice
        | "--ollama" `elem` args = OllamaBackend
        | otherwise              = MockBackend
      scenario = parseScenario args
  TIO.putStrLn $ "=== adtech-agent (" <> renderBackend backendChoice
               <> ", scenario=" <> tshow scenario <> ") ==="
  backend <- selectBackend backendChoice
  case buildRequest scenario of
    Left v   -> do
      TIO.putStrLn $ "[build] invalid request: " <> renderViolation v
      exitFailure
    Right req -> runPipeline backend req

-- | Parse the scenario flag (defaults to 'Clean').
parseScenario :: [String] -> Scenario
parseScenario args = case lookupScenario args of
  Just "pii"             -> Pii
  Just "protected-class" -> ProtectedClass
  Just "disallowed-claim" -> BrandUnsafe
  Just "clean"           -> Clean
  _                      -> Clean
  where
    lookupScenario [] = Nothing
    lookupScenario ("--scenario" : v : _) = Just v
    lookupScenario (a : rest)
      | Just v <- T.stripPrefix "--scenario=" (T.pack a) = Just (T.unpack v)
      | otherwise = lookupScenario rest

selectBackend :: BackendChoice -> IO ModelBackend
selectBackend MockBackend   = pure mockBackend
selectBackend OllamaBackend =
  case mkModelName "llama3.2:1b" of
    Right model -> pure (ollamaBackend (defaultOllamaConfig model))
    Left v      -> do
      TIO.putStrLn $ "[config] invalid model name: " <> renderViolation v
      exitFailure

renderBackend :: BackendChoice -> Text
renderBackend MockBackend   = "mock"
renderBackend OllamaBackend = "ollama"

-- | The end-to-end governed pipeline with a per-stage trace.
runPipeline :: ModelBackend -> ModelRequest -> IO ()
runPipeline backend req = do
  traceRequestRedaction req
  case enforceRequest adtechRequestPolicy req of
    Left v -> do
      TIO.putStrLn $ "[request policy]  protected-class check: DENY ("
                   <> renderReason (vReason v) <> ")"
      TIO.putStrLn $ "[enforceRequest]  Left (" <> renderViolation v <> ")"
      TIO.putStrLn "RESULT: DENY — request never sent to model"
    Right governedReq -> do
      TIO.putStrLn "[request policy]  protected-class check: PASS"
      TIO.putStrLn "[enforceRequest]  Right (Governed 'Checked)"
      modelResult <- try (runModel backend governedReq)
      case modelResult of
        Left err -> reportTransportError err
        Right rawResp -> do
          -- The response is 'Governed 'Raw': its text is NOT readable here (that
          -- read is exactly the bypass we eliminated). It can only flow into
          -- enforceResponse.
          TIO.putStrLn "[model]           raw response received (pending response policy)"
          enforceResponseStage rawResp

-- | Response-side enforcement and final output.
enforceResponseStage :: Governed 'Raw ModelResponse -> IO ()
enforceResponseStage rawResp =
  case enforceResponse adtechResponsePolicy rawResp of
    Left v -> do
      TIO.putStrLn $ "[response policy] disallowed-claims check: DENY ("
                   <> renderReason (vReason v) <> ")"
      TIO.putStrLn $ "[enforceResponse] Left (" <> renderViolation v <> ")"
      TIO.putStrLn "RESULT: DENY — model output withheld"
    Right governedResp -> do
      TIO.putStrLn "[response policy] disallowed-claims check: PASS"
      TIO.putStrLn "[response policy] PII leak check: PASS"
      TIO.putStrLn "[enforceResponse] Right (Governed 'Checked)"
      TIO.putStrLn "RESULT: ALLOW"
      TIO.putStrLn $ "OUTPUT: " <> tshow (mrespText (unGoverned governedResp))

-- | Report an Ollama transport error distinctly from any policy decision.
reportTransportError :: OllamaError -> IO ()
reportTransportError err = do
  TIO.putStrLn $ "[model:ollama]    TRANSPORT ERROR: " <> tshow err
  TIO.putStrLn "RESULT: ERROR — could not reach model (this is NOT an Allow)."
  TIO.putStrLn "Hint: start Ollama, or re-run with --mock for the offline demo."

-- | Print a small redaction trace for the request prompt.
traceRequestRedaction :: ModelRequest -> IO ()
traceRequestRedaction req = do
  let txt   = unPrompt (mrPrompt req)
      spans = emailSpans txt <> phoneSpans txt <> secretSpans txt
  if null spans
    then TIO.putStrLn "[request policy]  PII redaction: 0 spans"
    else TIO.putStrLn $ "[request policy]  PII redaction: "
                      <> tshow (length spans) <> " span(s)"

-- | Build the request for a scenario. All literals are valid by construction;
-- a smart-constructor failure is reported rather than crashing.
buildRequest :: Scenario -> Either Violation ModelRequest
buildRequest scenario = do
  principal <- mkPrincipal "agent-001"
  role      <- mkRole "copywriter"
  scope     <- mkScope "ad:create"
  system    <- mkSystemPrompt
                 "You are an adtech copy assistant. Follow brand-safety policy."
  model     <- mkModelName "llama3.2:1b"
  prompt    <- mkPrompt (scenarioPrompt scenario)
  pure ModelRequest
    { mrPrincipal = principal
    , mrRoles     = [role]
    , mrScopes    = [scope]
    , mrSystem    = system
    , mrPrompt    = prompt
    , mrModel     = model
    }

scenarioPrompt :: Scenario -> Text
scenarioPrompt = \case
  Clean ->
    "Draft ad copy for running shoes targeting marathon hobbyists."
  Pii ->
    "Draft ad copy for running shoes. Reply to jane.doe@example.com \
    \or call 555-867-5309. API key sk-abcdef0123456789."
  ProtectedClass ->
    "Draft ad copy for running shoes targeting people by religion and health condition."
  BrandUnsafe ->
    "Draft a BOLD, high-energy ad for running shoes."

renderViolation :: Violation -> Text
renderViolation v = "Violation " <> renderReason (vReason v)

renderReason :: Reason -> Text
renderReason = \case
  EmptyValue t              -> "EmptyValue " <> tshow t
  MalformedValue t          -> "MalformedValue " <> tshow t
  ProtectedClassTargeting t -> "ProtectedClassTargeting " <> tshow t
  DisallowedClaim t         -> "DisallowedClaim " <> tshow t
  MissingRole t             -> "MissingRole " <> tshow t
  MissingScope t            -> "MissingScope " <> tshow t
  DeniedByList t            -> "DeniedByList " <> tshow t

tshow :: Show a => a -> Text
tshow = T.pack . show
