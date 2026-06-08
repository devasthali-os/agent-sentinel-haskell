-- | A 'ModelBackend' talking to a local Ollama server (spec §5.6, §12, R3).
--
-- Uses @http-client@ over plain HTTP (Ollama is local; no TLS dependency).
-- Transport and decode failures are surfaced as a typed 'OllamaError'
-- exception — they are never silently turned into a policy @Allow@.
module Sentinel.Ollama
  ( OllamaConfig(..)
  , defaultOllamaConfig
  , OllamaError(..)
  , ollamaBackend
  ) where

import           Control.Exception (Exception, throwIO, try)
import           Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Text as T
import           Data.Text (Text)

import           Network.HTTP.Client

import           Sentinel.Enforce (rawResponse, unGoverned)
import           Sentinel.Model (ModelBackend (..))
import           Sentinel.Types

-- | Connection settings for the Ollama generate endpoint.
data OllamaConfig = OllamaConfig
  { ocHost          :: String
  , ocPort          :: Int
  , ocModel         :: ModelName
  , ocTimeoutMicros :: Int
    -- ^ HTTP response timeout in microseconds. Local LLM generation (especially
    -- on a cold model load) can take well beyond @http-client@'s 30s default,
    -- so this defaults to a generous 180s.
  } deriving (Eq, Show)

-- | @localhost:11434@ for the given model, with a 180s response timeout.
defaultOllamaConfig :: ModelName -> OllamaConfig
defaultOllamaConfig model = OllamaConfig
  { ocHost          = "localhost"
  , ocPort          = 11434
  , ocModel         = model
  , ocTimeoutMicros = 180 * 1000 * 1000
  }

-- | A transport/decode failure, kept distinct from any policy decision.
data OllamaError
  = OllamaTransportError Text
  | OllamaDecodeError Text
  deriving (Eq, Show)

instance Exception OllamaError

-- | The shape we decode out of Ollama's @stream:false@ response. Only the
-- @response@ text is mapped into 'ModelResponse'.
newtype OllamaResponse = OllamaResponse { orText :: Text }

instance FromJSON OllamaResponse where
  parseJSON = withObject "OllamaResponse" $ \o ->
    OllamaResponse <$> o .: "response"

-- | Build a backend that POSTs to @http://host:port/api/generate@.
ollamaBackend :: OllamaConfig -> ModelBackend
ollamaBackend cfg = ModelBackend $ \governed -> do
  let req     = unGoverned governed
      payload = object
        [ "model"  .= unModelName (ocModel cfg)
        , "prompt" .= unPrompt (mrPrompt req)
        , "system" .= unSystemPrompt (mrSystem req)
        , "stream" .= False
        ]
      url = "http://" <> ocHost cfg <> ":" <> show (ocPort cfg) <> "/api/generate"

  let timeout = responseTimeoutMicro (ocTimeoutMicros cfg)
  manager <- newManager defaultManagerSettings
    { managerResponseTimeout = timeout }
  initReq <- parseRequest url
  let httpReq = initReq
        { method = "POST"
        , requestBody = RequestBodyLBS (Aeson.encode payload)
        , requestHeaders = [("Content-Type", "application/json")]
        , responseTimeout = timeout
        }

  result <- try (httpLbs httpReq manager)
  case result of
    Left err ->
      throwIO (OllamaTransportError (T.pack (show (err :: HttpException))))
    Right httpResp ->
      case Aeson.eitherDecode (responseBody httpResp) of
        Left decErr -> throwIO (OllamaDecodeError (T.pack decErr))
        Right ollama -> pure (rawResponse (ModelResponse (ocModel cfg) (orText ollama)))
