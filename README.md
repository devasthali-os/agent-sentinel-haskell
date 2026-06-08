# agent-sentinel — Type-Safe Agent Policy Sentinel (Haskell)

A thin, strongly-typed Haskell library that sits between an AI agent and an LLM
and enforces composable policies on **every** request and response.
Phantom types and unexported constructors make whole classes of policy bugs
*unrepresentable*:

> **If it compiles, the sentinel ran.**

See `docs/README.md` for the doc index. The PRD (`docs/001/001-prd.md`) includes
**§4 Market Context** comparing agent-sentinel to Cedar, Rego, CEL, and other
type-safe policy languages. Design detail lives in `docs/001/001-spec.md`.

## What it guarantees (at compile time)

| # | Bug class eliminated | Mechanism |
|---|---|---|
| 1 | Calling the model without applying a policy | `runModel :: Governed 'Checked ModelRequest -> IO ...`; only `enforceRequest` mints a `'Checked` request |
| 2 | Sending un-redacted PII to the model | Redaction runs *inside* `enforceRequest`; `Redact` is property-tested to never leak the secret substring |
| 3 | Consuming an unchecked model response | `runModel` returns a `Governed 'Raw ModelResponse` (no public accessor); text is readable only via `unGoverned` on a `Governed 'Checked` produced by `enforceResponse` |
| 4 | Forgetting to handle a `Decision`/`Violation` | total sum types + `-Werror=incomplete-patterns`; decisions are data, not exceptions |
| 5 | Building an invalid domain value | raw newtype constructors unexported; only `mkX :: Text -> Either Violation X` |

The documented `should-not-compile` proofs for classes 1 & 3 live in the header
of `test/Sentinel/NoBypassSpec.hs`.

## Architecture

```
app/adtech-agent        composition root: builds the adtech policy, picks a backend
   │
   ├── Sentinel.Enforce   enforceRequest / enforceResponse / unGoverned   (no-bypass core)
   ├── Sentinel.Model     ModelBackend port (returns Governed 'Raw response)
   │       └── Sentinel.Model.Mock   deterministic offline backend
   │       └── Sentinel.Ollama       http-client backend (POST /api/generate)
   ├── Sentinel.Policy    Policy value + combinators + Monoid composition
   ├── Sentinel.Redact    span redaction + email/phone/secret detectors
   ├── Sentinel.Adtech    flagship policy bundle (PII + protected-class + brand-safety)
   └── Sentinel.Types     newtypes + smart ctors, Decision/Violation, Stage (DataKinds)
```

The legacy Servant demo has been moved to `legacy/introv-haskell/` and is **not**
built by this package (see `legacy/introv-haskell/README.md`).

---

## Toolchain (required)

This project pins **resolver `lts-22.43` (GHC 9.6.6)** via `stack.yaml`. GHC 9.6.6
has native bindists for **both** `x86_64-darwin` and `aarch64-darwin`, so the
build is identical on Intel and Apple Silicon. The machine's legacy GHC 8.2.2 has
**no** aarch64 bindist (that support landed in GHC 9.2+), which is exactly why the
modern resolver is required.

Use a **modern stack (≥ 3.x)**. Do not use a legacy `/usr/local/bin/stack 1.6.x`
or the system `cabal`/`ghc`.

```bash
# Install modern stack to a user-local path (independent of any legacy stack)
curl -sSL https://get.haskellstack.org/ | sh -s - -d ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"     # ensure modern stack precedes legacy
stack --version                           # expect >= 3.x
```

## Build & test (works identically on macOS Intel x86_64 and Apple Silicon M3 aarch64)

```bash
export PATH="$HOME/.local/bin:$PATH"

# Resolver lts-22.43 -> GHC 9.6.6 is auto-installed for the host arch
stack build                               # -Wall -Werror=incomplete-patterns, clean

stack test                                # OFFLINE deterministic suite (no Ollama, no network)
```

> **Apple Silicon note:** the steps above are byte-for-byte the same on an M3.
> The pinned `lts-22.43` / GHC 9.6.6 resolves both architectures identically;
> `stack` downloads the correct GHC bindist for the host automatically. No
> Rosetta and no x86-only assumptions are involved.

## Run the example end-to-end

```bash
export PATH="$HOME/.local/bin:$PATH"

# Offline, deterministic mock backend (default)
stack run adtech-agent -- --mock
stack run adtech-agent -- --mock --scenario pii
stack run adtech-agent -- --mock --scenario protected-class
stack run adtech-agent -- --mock --scenario disallowed-claim
```

Example trace (clean scenario):

```
=== adtech-agent (mock, scenario=Clean) ===
[request policy]  PII redaction: 0 spans
[request policy]  protected-class check: PASS
[enforceRequest]  Right (Governed 'Checked)
[model]           raw response received (pending response policy)
[response policy] disallowed-claims check: PASS
[response policy] PII leak check: PASS
[enforceResponse] Right (Governed 'Checked)
RESULT: ALLOW
OUTPUT: "Lace up and chase your next PR with our cushioned trainer."
```

## Run against a real Ollama (optional; not required for CI)

```bash
# In one terminal
ollama pull llama3.2:1b                    # small, fast default
# ollama pull llama3.2:3b                   # optional, higher quality

# In another terminal
export PATH="$HOME/.local/bin:$PATH"
stack run adtech-agent -- --ollama
```

If Ollama is unreachable, the backend surfaces a **typed transport error**
(never a silent `Allow`) and the example tells you to use `--mock`.

### Segregated Ollama integration test

The Ollama integration spec is **off by default** so `stack test` stays fully
offline. Enable it only when a local Ollama server is running:

```bash
export PATH="$HOME/.local/bin:$PATH"
OLLAMA_INTEGRATION=1 stack test
```
