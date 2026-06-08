# Software Design Specification — Type-Safe Agent Policy Governance Engine (Haskell)

## 1. Overview

| Field | Value |
|---|---|
| **Feature ID** | 001 |
| **Feature Name** | Type-Safe Agent Policy Governance Engine |
| **Date** | 2026-06-08 |
| **Author** | Spec Agent (Staff Engineer), on behalf of Platform/Security Engineering |
| **Related PRD** | `docs/001/001-prd.md` (v1.0) |
| **Status** | Design — passed self-review (no open High findings) |

**One-line summary:** A thin, strongly-typed Haskell library that sits between an AI agent and an LLM and enforces composable governance policies on every request and response, using phantom types and unexported constructors to make whole classes of governance bugs (un-applied policy, leaked PII, unchecked prompt/response) *unrepresentable* — *if it compiles, the governance ran.*

This document specifies the design of a Haskell **library + example executable + test suite**. There are **no UI mockups** — this is a backend/library product. The "user-facing surfaces" are the public Haskell API, the example CLI output, and the Ollama HTTP wire format, which are illustrated as code/text artifacts where relevant.

---

## 2. Problem & Goals

### 2.1 Problem
Governance of agent↔LLM traffic is usually written as ad-hoc imperative guards (`if` checks, string filters, try/catch) scattered across call sites. Its default failure mode is silent bypass: a developer forgets to call the check on a new code path, PII is redacted in one path but not another, or a raw response is consumed before brand-safety runs. "Did we enforce the policy?" becomes a runtime question rather than a compile-time guarantee.

### 2.2 Goals (traced to PRD)
| # | Goal | PRD trace |
|---|---|---|
| G1 | No request reaches the model, and no response reaches the agent, without passing typed enforcement. | PRD G1, FR1, FR5 |
| G2 | Governance policies are composable, typed, first-class values. | PRD G2, FR2, FR3 |
| G3 | Identified classes of governance bugs eliminated at compile time (≥ 4). | PRD G3, FR4, FR5 |
| G4 | Credible regulated-domain flagship example (adtech). | PRD G4, FR6 |
| G5 | Reproducible build on macOS Intel + Apple Silicon; fully testable offline. | PRD G5, NFR1–NFR3 |

### 2.3 Success Metrics
The headline framing is **"classes of bugs eliminated by the type system."** Each bug class in §10 must be a *compile error or unrepresentable state*, demonstrated by a documented `should-not-compile` negative case, not a runtime hope. Performance is explicitly **not** a metric (PRD NFR6).

---

## 3. Architecture Overview

The engine is a small, layered library. The dependency direction points inward toward `Governance.Types`; the model backend and Ollama transport are at the edge (hexagonal / ports-and-adapters).

```
                          ┌──────────────────────────────────────────────────┐
                          │                  app/  adtech-agent               │
                          │   (composition root: builds policy, picks backend)│
                          └───────────────┬───────────────────────┬──────────┘
                                          │ uses                   │ selects
                                          ▼                        ▼
        ┌───────────────────────────────────────────┐   ┌────────────────────────┐
        │            Governance.Enforce              │   │     Governance.Model     │
        │  enforceRequest  :: Policy -> ModelRequest  │   │  ModelBackend            │
        │     -> Either Violation (Governed 'Checked) │   │   { runModel ::          │
        │  enforceResponse :: Policy -> ModelResponse │   │     Governed 'Checked    │
        │     -> Either Violation (Governed 'Checked) │   │       ModelRequest       │
        │  newtype Governed (s::Stage) a  (ctor HIDDEN)│  │     -> IO ModelResponse }│
        │  unGoverned :: Governed 'Checked a -> a      │  └───────────┬─────────────┘
        └───────┬───────────────────────────┬────────┘              │ implemented by
                │ uses                       │ uses                  ▼
                ▼                            ▼              ┌────────────────────────┐
       ┌──────────────────┐        ┌──────────────────┐    │   Governance.Ollama      │
       │ Governance.Policy│        │ Governance.Redact│    │  ollamaBackend ::        │
       │  Policy (Subject │        │  redactSpans,    │    │   OllamaConfig ->        │
       │   -> Decision) + │        │  PII / secret    │    │   ModelBackend           │
       │  combinators,    │        │  scrubbing       │    │  (http-client + aeson,   │
       │  monoidal compose│        └────────┬─────────┘    │   POST /api/generate)    │
       └────────┬─────────┘                 │              └───────────┬─────────────┘
                │ uses                       │ uses                     │ HTTP (localhost)
                ▼                            ▼                          ▼
        ┌──────────────────────────────────────────┐          ┌─────────────────────┐
        │              Governance.Types             │          │  Ollama server      │
        │  Prompt/SystemPrompt/ModelName/Principal/ │          │  llama3.2:1b (3b opt)│
        │  Role/Scope (newtypes + smart ctors);     │          └─────────────────────┘
        │  ModelRequest/ModelResponse; Decision;    │
        │  Violation/Reason; data Stage = Raw|Checked│
        └──────────────────────────────────────────┘
```

### 3.1 Data flow (happy path + denials)
1. The agent constructs a `ModelRequest` from parsed domain values (smart constructors guarantee validity).
2. `enforceRequest policy req` runs the request policy. It returns either:
   - `Left Violation` (e.g. `Deny` on protected-class targeting) → the request **never** reaches the model; the agent handles the violation as data; **or**
   - `Right (Governed 'Checked ModelRequest)` with PII redacted and transforms applied inside enforcement.
3. The agent passes the `Governed 'Checked ModelRequest` to `runModel`. **There is no other way to call the model** — the backend's input type only accepts checked requests.
4. The backend returns a **raw** `ModelResponse` (`IO ModelResponse`, not wrapped).
5. `enforceResponse policy resp` must run before the agent can read the text. It returns `Left Violation` (e.g. disallowed claim) or `Right (Governed 'Checked ModelResponse)`.
6. Only `unGoverned` on a `'Checked` value yields the underlying text the agent consumes.

---

## 4. Technology Stack

| Layer | Technology | Justification |
|---|---|---|
| Language / compiler | **GHC 9.6.6** | Pinned via resolver. Has native bindists for **both** `x86_64-darwin` and `aarch64-darwin`. The machine's legacy GHC 8.2.2 has **no** aarch64 (Apple Silicon) bindist — that support landed in GHC 9.2+ — so building on M3 with the system toolchain is impossible. (PRD NFR1, NFR2; Risk: legacy toolchain.) |
| Build / toolchain | **stack** with resolver **`lts-22.43`** (modern stack 3.x installed at `~/.local/bin/stack`) | A single resolver pins compiler + every dependency version, giving deterministic, reproducible builds from a clean checkout with no x86-only assumptions. stack auto-downloads the correct GHC bindist for the host arch. (PRD NFR2.) |
| Package definition | **hpack** (`package.yaml`) generating the `.cabal`, plus `stack.yaml` pinning the resolver | hpack reduces boilerplate and keeps stanzas DRY (shared `ghc-options`, dependency lists). The generated `.cabal` is committed for tooling compatibility. |
| Domain modeling | newtypes + smart constructors, GADTs/`DataKinds` phantom stage | Parse-don't-validate; encode "checked" in the type. (PRD FR5, NFR7.) |
| JSON | **aeson** | Encode Ollama request, decode response. |
| HTTP transport | **http-client** (plain HTTP, **no** `http-client-tls`) | Ollama is local (`http://localhost:11434`); no TLS is needed, keeping the dependency footprint lean. (PRD NFR4.) |
| Text | **text** | Efficient prompt/response handling, `OverloadedStrings`. |
| Testing | **hspec** + **QuickCheck** | hspec for deterministic example-based specs; QuickCheck for policy-law property tests. |
| (optional) integration | hspec spec tagged/segregated, hitting local Ollama | Kept out of default CI; offline suite is authoritative. (PRD NFR3.) |

### 4.1 Install (documented for both arches)
```bash
# Modern stack to a user-local path (independent of legacy stack 1.6.1)
curl -sSL https://get.haskellstack.org/ | sh -s - -d ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"          # ensure modern stack precedes legacy
stack --version                                # expect >= 3.x

# Build & test (resolver lts-22.43 → GHC 9.6.6 auto-installed for host arch)
stack build                                    # works identically on x86_64 + aarch64
stack test                                     # offline deterministic suite

# Ollama (example / integration only — NOT required for CI)
ollama pull llama3.2:1b                         # small, fast default
# ollama pull llama3.2:3b                        # optional, higher quality
```

---

## 5. Component Design

The governance engine is a **new, separate** stack package named **`agent-governance`** rooted at the repo root. The legacy `introv-haskell.cabal` + `src/Main.hs` (an unrelated Servant demo) is **not** part of this product. **Recommendation:** leave the legacy file untouched but ensure the new package builds independently. To avoid `src/` collision, the new library sources live under `src/Governance/` and the legacy `src/Main.hs` is **not** referenced by the new package's stanzas (hpack lists only the governance modules / the legacy file is moved to `legacy/` if stack's source-dir globbing would otherwise pick it up — see §14 Open Question OQ-1, resolved). The new package owns `package.yaml`, `stack.yaml`, `app/`, and `test/`.

### 5.1 `Governance.Types`
- **Responsibility:** Precise domain vocabulary. Parse-don't-validate at the boundary.
- **Interfaces (exported):**
  - newtypes with **smart constructors** (raw constructors **not** exported): `Prompt`, `SystemPrompt`, `ModelName`, `Principal`, `Role`, `Scope`. Each exposes `mkX :: Text -> Either Violation X` (or `Maybe`) and an accessor.
  - Records: `ModelRequest { mrPrincipal, mrRoles, mrScopes, mrSystem, mrPrompt, mrModel }`, `ModelResponse { mrespModel, mrespText }`.
  - `data Decision a = Allow | Deny Reason | Transform a | Redact [RedactionSpan]` — explicit sum type; decisions are **data, not exceptions**.
  - `data Violation = Violation { vReason :: Reason, vDetail :: Text }`; `newtype Reason = Reason Text` (or a sum of named reasons).
  - `data RedactionSpan = RedactionSpan { rsStart :: Int, rsEnd :: Int, rsLabel :: Text }`.
  - `data Stage = Raw | Checked` — promoted via `DataKinds` for phantom typing (the *kind* used by `Governed`).
- **Dependencies:** `text` only.
- **Data model:** see §8.

### 5.2 `Governance.Policy`
- **Responsibility:** Represent a policy as a composable, typed first-class value and provide combinators to build a policy set without touching the engine core (PRD FR3, G2).
- **Interfaces:**
  - `newtype Policy = Policy { runPolicy :: Subject -> Decision Subject }` plus metadata (`policyName :: Text`). `Subject` is the thing under policy (a request payload or response payload); the engine applies request and response policies to the relevant subject.
  - Combinators: `allowList`, `denyList`, `denyIf :: (Subject -> Maybe Reason) -> Policy`, `redactWith :: (Subject -> [RedactionSpan]) -> Policy`, `transformWith :: (Subject -> Subject) -> Policy`, `requireRole :: Role -> Policy`, `requireScope :: Scope -> Policy`, and `composeP :: Policy -> Policy -> Policy` (sequential composition).
  - **Monoid instance** where sensible: `mempty = allow-everything`; `(<>)` = sequential composition with the semantics below.
- **Composition semantics (documented):**
  - **`Deny` is absorbing:** once any policy in a composition yields `Deny r`, the composite result is `Deny r`; later policies are short-circuited. (Matches PRD intent that denials are terminal.)
  - **Transforms chain:** `Transform f` then `Transform g` ⇒ the subject is updated by `f` then fed to `g` (left-to-right). The composite continues evaluating subsequent policies against the transformed subject.
  - **Redactions accumulate:** redaction spans from each policy are unioned/merged (overlapping spans coalesced) and applied together; redaction never *un*-redacts.
  - **`Allow` is the identity** under composition (`Allow <> p = p`).
  - Determinism: combinators are pure; order is significant and documented.
- **Dependencies:** `Governance.Types`.

### 5.3 `Governance.Enforce` — the no-bypass core
- **Responsibility:** The single chokepoint. Owns the `Governed` type and is the **only** module that can mint a `'Checked` value.
- **Interfaces (carefully controlled exports):**
  - `newtype Governed (s :: Stage) a = Governed a` — **the constructor `Governed` is NOT exported.** Only the type and the functions below are exported.
  - `enforceRequest :: Policy -> ModelRequest -> Either Violation (Governed 'Checked ModelRequest)` — runs the request policy, applies transforms/redactions, returns the checked request or a violation.
  - `enforceResponse :: Policy -> ModelResponse -> Either Violation (Governed 'Checked ModelResponse)` — same for responses.
  - `unGoverned :: Governed 'Checked a -> a` — **only** defined/usable for `'Checked` (the type signature pins `'Checked`; there is no `unGoverned` for `'Raw`, and no way to fabricate a `'Checked` outside this module).
- **Why this is no-bypass:** the model boundary (§5.4) accepts only `Governed 'Checked ModelRequest`. The only producer of that type is `enforceRequest`. Symmetrically, the agent can only read response text via `unGoverned` on a `Governed 'Checked ModelResponse`, whose only producer is `enforceResponse`. Skipping enforcement is therefore a **type error**, not a code-review miss.
- **Dependencies:** `Governance.Types`, `Governance.Policy`, `Governance.Redact`.

### 5.4 `Governance.Model`
- **Responsibility:** Define the model boundary as a port so a model can never be called with ungoverned input.
- **Interfaces:** `data ModelBackend = ModelBackend { runModel :: Governed 'Checked ModelRequest -> IO ModelResponse }`. Note the return is a **raw** `ModelResponse` — forcing response-side enforcement before consumption.
- **Dependencies:** `Governance.Types`, `Governance.Enforce` (for the `Governed` type only).

### 5.5 `Governance.Redact`
- **Responsibility:** Redaction helpers guaranteeing a secret span is replaced so the secret substring cannot leak.
- **Interfaces:** `applyRedactions :: [RedactionSpan] -> Text -> Text`; helper detectors `emailSpans`, `phoneSpans`, `secretSpans :: Text -> [RedactionSpan]`. Replacement uses a fixed mask (e.g. `‹REDACTED:label›`) chosen so it cannot equal the original secret.
- **Guarantee (property-tested):** for any input and detected spans, the detected secret substring does **not** appear in `applyRedactions spans input`. (PRD FR6a; §10 bug class 2.)
- **Dependencies:** `Governance.Types`, `text`.

### 5.6 `Governance.Ollama`
- **Responsibility:** A `ModelBackend` implementation talking to local Ollama.
- **Interfaces:** `data OllamaConfig = OllamaConfig { ocHost :: String, ocPort :: Int, ocModel :: ModelName }` (default `localhost:11434`); `ollamaBackend :: OllamaConfig -> ModelBackend`.
- **Behavior:** `runModel` serializes the checked request to the Ollama generate payload and `POST`s to `http://<host>:<port>/api/generate` with `"stream": false` using `http-client` (plain HTTP) + `aeson`, then decodes `response` into a `ModelResponse`. No TLS dependency.
- **Dependencies:** `Governance.Types`, `Governance.Model`, `Governance.Enforce`, `http-client`, `aeson`, `bytestring`, `text`.

### 5.7 `app/adtech-agent` (example executable)
- **Responsibility:** Composition root demonstrating the flagship adtech scenario end-to-end.
- **Behavior:**
  - Builds the **request policy**: redact PII (email/phone) + `Deny` requests targeting protected-class attributes (race, religion, health, sexual orientation, etc.).
  - Builds the **response policy**: brand-safety / disallowed-claims check on generated ad copy (deny `"guaranteed"`, `"miracle cure"`, `"100% risk-free"`, …) + redact any leaked PII.
  - Wires end-to-end: `enforceRequest` → `runModel` → `enforceResponse`, printing the `Decision`/`Violation` and the final governed output.
  - Supports `--mock` (deterministic mock backend) and `--ollama` (real backend) modes via a CLI flag so the example runs offline by default.
- **Dependencies:** the whole library.

---

## 6. API Design

This is a library; the "API" is the public Haskell surface plus the one external HTTP call. There are no inbound REST endpoints.

### 6.1 Public Haskell API (the contract that enforces no-bypass)
| Function | Signature | Notes |
|---|---|---|
| `mkPrompt` | `Text -> Either Violation Prompt` | Smart constructor; raw ctor hidden. |
| `enforceRequest` | `Policy -> ModelRequest -> Either Violation (Governed 'Checked ModelRequest)` | Only producer of a checked request. |
| `enforceResponse` | `Policy -> ModelResponse -> Either Violation (Governed 'Checked ModelResponse)` | Only producer of a checked response. |
| `runModel` (field of `ModelBackend`) | `Governed 'Checked ModelRequest -> IO ModelResponse` | Sole model entry; ungoverned input is a type error. |
| `unGoverned` | `Governed 'Checked a -> a` | Defined only for `'Checked`. |
| `composeP` / `(<>)` | `Policy -> Policy -> Policy` | Add policies by composition; engine core unchanged (PRD G2). |

### 6.2 External HTTP call (Ollama) — wire artifact
**Request** `POST http://localhost:11434/api/generate`:
```json
{
  "model": "llama3.2:1b",
  "prompt": "Draft ad copy for running shoes targeting marathon hobbyists.",
  "system": "You are an adtech copy assistant. Follow brand-safety policy.",
  "stream": false
}
```
**Response (`stream:false`, fields elided):**
```json
{
  "model": "llama3.2:1b",
  "created_at": "2026-06-08T15:00:00Z",
  "response": "Lace up and chase your next PR with...",
  "done": true
}
```
Only `model` and `response` are mapped into `ModelResponse`.

### 6.3 Example CLI output artifact (user-facing surface)
```
$ adtech-agent --mock
[request policy]  PII redaction: 1 span (email) → ‹REDACTED:email›
[request policy]  protected-class check: PASS
[enforceRequest]  Right (Governed 'Checked)
[model:mock]      "Run further. Every stride counts. Try our cushioned trainer."
[response policy] disallowed-claims check: PASS
[response policy] PII leak check: PASS
[enforceResponse] Right (Governed 'Checked)
RESULT: ALLOW
OUTPUT: "Run further. Every stride counts. Try our cushioned trainer."

$ adtech-agent --mock --scenario protected-class
[request policy]  protected-class check: DENY (targets attribute: religion)
[enforceRequest]  Left (Violation ProtectedClassTargeting "religion")
RESULT: DENY — request never sent to model
```

---

## 7. Mockups

**Not applicable.** This is a backend/library product with no UI. User-facing surfaces are illustrated as code/text artifacts in §6.2 (Ollama wire format) and §6.3 (example CLI output).

---

## 8. Data Model

All types are in-memory Haskell values; there is **no persistence layer** (PRD non-goal). "Constraints/indexes" map to type-level invariants and smart-constructor guards.

| Type | Fields | Invariants (enforced by) |
|---|---|---|
| `Prompt` | `Text` | non-empty after trim (smart ctor `mkPrompt`) |
| `SystemPrompt` | `Text` | may be empty; bounded length (smart ctor) |
| `ModelName` | `Text` | matches `name[:tag]` shape (smart ctor) |
| `Principal` | `Text` | non-empty identifier (smart ctor) |
| `Role` | `Text` | from a known set or non-empty (smart ctor) |
| `Scope` | `Text` | non-empty (smart ctor) |
| `ModelRequest` | `mrPrincipal :: Principal`, `mrRoles :: [Role]`, `mrScopes :: [Scope]`, `mrSystem :: SystemPrompt`, `mrPrompt :: Prompt`, `mrModel :: ModelName` | all fields are already-parsed newtypes (no raw `Text` reaches downstream) |
| `ModelResponse` | `mrespModel :: ModelName`, `mrespText :: Text` | constructed only by a backend |
| `Decision a` | `Allow \| Deny Reason \| Transform a \| Redact [RedactionSpan]` | exhaustive sum (`-Wincomplete-patterns`) |
| `Violation` | `vReason :: Reason`, `vDetail :: Text` | data, not exception |
| `RedactionSpan` | `rsStart :: Int`, `rsEnd :: Int`, `rsLabel :: Text` | `0 <= rsStart <= rsEnd <= length`; merged on accumulation |
| `Governed (s::Stage) a` | wraps `a` | ctor unexported; `s` phantom; only `'Checked` constructible via enforce |
| `Stage` (kind) | `Raw \| Checked` | promoted via `DataKinds` |

**"Migrations":** none — no database. The analogue of schema versioning is the **stability of the public API** (the no-bypass contract); breaking it is a major-version change.

---

## 9. Integration Points

| Integration | Direction | Detail |
|---|---|---|
| **Ollama HTTP API** | outbound | `POST http://localhost:11434/api/generate`, `stream:false`, plain HTTP via `http-client`. Example/integration only; **not** required for CI. |
| **Mock model backend** | in-process | Deterministic `ModelBackend` returning canned/echoing responses; sole backend used by the offline test suite and `--mock`. |
| **Host application** | inbound (library consumer) | Imports the library; receives `Decision`/`Violation` as structured data to log/audit (PRD NFR5). The engine does no logging itself. |
| **No Kafka, no DB, no external API** | — | Out of scope per PRD §10. |

---

## 10. Security & Compliance — Threat Model & Type-Safety Rationale

This is the spec's most important section: the product's value **is** the set of bug classes the type system eliminates.

### 10.1 Bug classes eliminated, mapped to mechanism
| # | Bug class | Why it is impossible | Mechanism |
|---|---|---|---|
| 1 | **Forgetting to apply a policy before calling the model** | `runModel :: Governed 'Checked ModelRequest -> IO ...`; the only producer of `Governed 'Checked` is `enforceRequest`. Calling the model without enforcing is a **type error**. | Phantom `Stage` + unexported `Governed` constructor + typed model port. |
| 2 | **Sending un-redacted PII / unchecked prompt to the model** | Redaction happens *inside* `enforceRequest`; there is no path that yields a `'Checked` request without running the request policy. The redaction helper is property-tested to never leak the secret substring. | Enforcement is the sole mint of `'Checked`; `Governance.Redact` guarantee. |
| 3 | **Returning an unchecked model response to the agent** | `runModel` returns a **raw** `ModelResponse`; the agent can only read text via `unGoverned` on a `Governed 'Checked ModelResponse`, produced only by `enforceResponse`. | Raw return type + `'Checked`-only `unGoverned`. |
| 4 | **Forgetting to handle a Decision/Violation case** | `Decision` and `Violation` are total sum types; `enforce*` returns `Either Violation _`. Unhandled cases are compile warnings/errors. | Exhaustive pattern matching, `-Wincomplete-patterns`, `-Werror` on that warning; decisions are data, not exceptions. |
| 5 | **Constructing an invalid domain value (malformed Prompt / targeting attr)** | Raw newtype constructors are unexported; only smart constructors (`mkPrompt`, …) can build values, and they return `Either Violation`. | Parse-don't-validate, smart constructors. |

Each class is demonstrated by tests (positive) **and** at least one **documented `should-not-compile`** negative case for classes 1 and 3 (PRD success metric for G1/G3).

### 10.2 Threat model — assumptions & out of scope
- **Assumptions / trust boundary:** The engine trusts the host process and the model host. It governs *content of requests/responses crossing the agent↔model boundary*, not the transport or the runtime.
- **In scope:** preventing bypass of policy on the agent↔model hop; PII redaction; protected-class denial; brand-safety/disallowed-claims denial; explicit violation data.
- **Out of scope (explicitly):** It is **not a sandbox** (does not constrain what the host process does), **not a network firewall** (localhost HTTP to Ollama is unencrypted by design), does **not** authenticate the model host, and does **not** defend against a malicious *in-process* caller who edits the library source (the guarantee is against accidental bypass by honest engineers, the PRD's stated failure mode). Performance/DoS is out of scope (PRD NFR6).

### 10.3 PII & audit
- PII (emails/phones and configured secrets) is redacted in-place before leaving the process; redaction masks are non-reversible within the engine.
- The engine emits **no logs**; it returns structured `Decision`/`Violation` values for the host to audit (PRD NFR5, non-goal: no log-shipping pipeline).

---

## 11. Observability

- **Decisions/violations as data:** every enforcement returns `Either Violation (Governed 'Checked _)`; the host can log/metric these. `Violation` carries `Reason` + detail for structured logging.
- **Naming:** `Policy` carries `policyName` so an audit log can attribute a decision to a named policy.
- **No engine-internal logging/metrics/tracing** (PRD NFR4/NFR5: minimal surface; host owns logging). Health checks are N/A (library, not a service); the example CLI prints a per-stage trace (§6.3) for demonstrability.

---

## 12. Error Handling & Resilience

- **Control flow = data, never exceptions:** policy outcomes are `Decision`/`Violation`; `enforce*` returns `Either`. No `error`/`throw` for governance control flow (PRD FR4).
- **Ollama transport errors:** `http-client` IO exceptions (connection refused, timeout) are caught at the `Governance.Ollama` boundary and surfaced as a typed result — `runModel` either returns a `ModelResponse` or the backend raises a clearly-typed transport error the example handles and reports; transport failure must **not** be mistaken for a policy `Allow`. (Resilience to a missing Ollama = the offline mock path; no retries/circuit breakers in scope — PRD NFR6.)
- **Graceful degradation:** if Ollama is unavailable, the example instructs the user to use `--mock`; CI never depends on Ollama.
- **No DLQ / no Kafka** (out of scope).

---

## 13. Deployment

- **Artifact:** a Haskell library + example executable; consumed as a source dependency (stack/hpack). No container/service is shipped (PRD non-goal: no SaaS).
- **Environments:** developer machines (macOS Intel + Apple Silicon) and CI.
- **CI/CD notes:** CI runs `stack build` + `stack test` (offline deterministic suite) on the pinned resolver; ideally on both `x86_64` and `aarch64` macOS runners. The Ollama integration spec is **excluded** from default CI (tagged/segregated) and run manually or on a dedicated job where Ollama is present. The committed `stack.yaml` resolver + generated `.cabal` ensure reproducibility.

---

## 14. Assumptions & Open Questions

- **A1** Consumers are Haskell-capable engineers; idiomatic Haskell API is acceptable (PRD A2).
- **A2** Ollama + `llama3.2:1b` available locally for E2E; CI uses only the mock (PRD A3).
- **A3** PII / protected-class / disallowed-claims lists are illustrative in-code typed values, not the product's intelligence (PRD A4, Risk: word-list scope creep).
- **A4** Determinism is asserted on **policy decisions**, not raw LLM text (PRD A5).
- **A5** `lts-22.43` / GHC 9.6.6 bindists remain available for both arches (PRD A6).
- **OQ-1 (RESOLVED):** *Will the legacy `src/Main.hs` collide with the new library's source dir?* — Resolution: the new `package.yaml` lists governance modules explicitly under `src/Governance/`; if stack's default source globbing would compile the legacy `Main.hs`, move it to `legacy/` (recommended: leave it in place and exclude it). The new package must build independently regardless. No open question remains.
- **OQ-2 (RESOLVED):** *`Either` vs `Maybe` for smart constructors?* — Use `Either Violation` so failures carry a `Reason` (consistent with the rest of the pipeline). Resolved.

---

## 15. Risks & Technical Debt

| Risk | Mitigation |
|---|---|
| Leaky `Governed` constructor erodes the no-bypass guarantee | Constructor unexported; explicit module export list reviewed; `should-not-compile` test guards regressions. |
| Legacy GHC 8.2.2 toolchain / Apple Silicon divergence | Pin GHC 9.6.6 via `lts-22.43`; build+test on both arches. |
| Ollama flakiness/non-determinism in CI | Mock boundary is authoritative; integration spec segregated. |
| Word-list governance mistaken for the product | Keep lists minimal/illustrative; the product is the typed structure (PRD NFR4). |
| Redaction misses a PII pattern | Property test the *substring-non-leak* invariant; document that detectors are illustrative, not exhaustive classifiers. |
| **Tech debt:** legacy Servant package remains in repo | Acceptable; isolated and unreferenced by the new package. Revisit removal later. |

---

## Review Summary

Self-review performed as a critical Staff Engineer peer. Findings below; all **High** findings resolved inline (no open High findings remain).

| # | Finding | Severity | Resolution |
|---|---|---|---|
| R1 | **No-bypass on the response side initially under-specified** — early draft let `runModel` return a `Governed 'Checked` response, which would let the agent skip `enforceResponse`. | **High** | **Resolved inline (§3.1, §5.4, §10.1 #3):** `runModel` returns a **raw** `ModelResponse`; `unGoverned` works only for `'Checked`; the sole producer of a checked response is `enforceResponse`. Response bypass is now a type error. |
| R2 | **Legacy `src/Main.hs` source-dir collision** could break an independent build of the new package. | **High** | **Resolved inline (§5, §14 OQ-1):** new package lists governance modules explicitly / legacy file excluded or moved to `legacy/`; new package must build independently. |
| R3 | **Transport failure could be confused with policy `Allow`** if Ollama errors were swallowed. | **High** | **Resolved inline (§12):** transport errors are caught at the `Governance.Ollama` boundary and surfaced as a typed error distinct from any `Allow`; never silently treated as success. |
| R4 | Composition semantics (Deny absorbing, transforms chaining, redactions accumulating) were ambiguous and could make `(<>)` non-associative or order-dependent in surprising ways. | Med | **Resolved (§5.2):** documented precise semantics — Deny absorbing/short-circuit, transforms left-to-right, redactions merged; `Allow` identity; order significant and documented. Property tests assert Deny-absorption and idempotence. |
| R5 | `RedactionSpan` integrity: overlapping/adjacent spans or out-of-range indices could corrupt output or partially leak. | Med | **Resolved (§8, §5.5):** invariant `0 <= start <= end <= length`; overlapping spans coalesced on accumulation; property test asserts the secret substring never survives. |
| R6 | Smart-constructor return type (`Maybe` vs `Either`) inconsistency could lose the failure reason. | Med | **Resolved (§14 OQ-2):** standardize on `Either Violation` so reasons propagate. |
| R7 | Observability: no engine logging could hinder audit. | Low | **Accepted by design (§11):** host owns logging (PRD NFR5/non-goal); engine returns structured data + `policyName`. |
| R8 | PII detectors are not exhaustive classifiers; could miss novel PII formats. | Low | **Documented (§15):** detectors are illustrative; the *guarantee* is the substring-non-leak invariant for detected spans, not perfect PII recall. Matches PRD scope (word lists not the product). |
| R9 | Cross-arch CI may only have x86_64 runners available, leaving aarch64 unverified in automation. | Low | **Documented (§13):** prefer both-arch runners; at minimum the pinned resolver guarantees identical bindist selection; manual aarch64 verification acceptable if runners unavailable. |

**Outcome:** 3 High findings — all resolved inline before finalizing. No open High findings remain. Spec is ready for execution planning.
