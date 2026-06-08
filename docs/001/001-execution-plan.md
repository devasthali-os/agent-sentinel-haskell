# Execution Plan — Type-Safe Agent Policy Governance Engine (Haskell)

## 1. Overview

| Field | Value |
|---|---|
| **Feature ID** | 001 |
| **Date** | 2026-06-08 |
| **Estimated Duration** | ~10–13 dev-days (single engineer), sequenced by dependency |
| **Related Spec** | `docs/001/001-spec.md` |
| **Related PRD** | `docs/001/001-prd.md` |

Stories are sized **small** (≈0.5–1.5 days each) and ordered so each builds on a green predecessor. Every story lists explicit acceptance criteria (AC). Status starts as `todo`.

---

## 2. Epics & Stories

### EPIC A — Toolchain & Project Foundation
Reproducible cross-platform build; new `agent-governance` package independent of legacy Servant code.

| ID | Title | Priority | Est (d) | Deps | Status |
|---|---|---|---|---|---|
| STORY-01 | Pin toolchain & scaffold stack/hpack package | P0 | 1.0 | — | todo |
| STORY-02 | Isolate legacy Servant package; verify independent build | P0 | 0.5 | STORY-01 | todo |
| STORY-03 | CI: offline `stack build`+`stack test`, cross-arch notes | P0 | 1.0 | STORY-01 | todo |

**STORY-01 — Pin toolchain & scaffold package**
- Description: Create `stack.yaml` (resolver `lts-22.43` / GHC 9.6.6), `package.yaml` (hpack) for library `agent-governance` with stanzas for `src/`, `app/adtech-agent`, `test/`. Generate the `.cabal`. Add `-Wall` and `-Werror=incomplete-patterns` to `ghc-options`. Document the modern-stack install for x86_64 + aarch64 in a README.
- AC:
  1. `stack build` succeeds from a clean checkout on the host arch (GHC 9.6.6 auto-installed).
  2. `package.yaml` enables `DataKinds`, `OverloadedStrings`, and sets the warning flags from the spec (§10.1 #4).
  3. README documents install + build + `ollama pull llama3.2:1b` exactly as spec §4.1.

**STORY-02 — Isolate legacy Servant package**
- Description: Ensure the new package does not compile `src/Main.hs`. Leave the legacy file in place (recommended) by listing governance modules explicitly, or move it to `legacy/` if globbing picks it up (spec §5, OQ-1).
- AC:
  1. `stack build` compiles only `Governance.*` modules + `app` + `test`; legacy `Main.hs` is not built.
  2. New package builds with no reference to `introv-haskell` deps (servant/warp/etc.).

**STORY-03 — CI offline + cross-arch**
- Description: CI workflow running `stack build` and `stack test` (offline deterministic suite) on the pinned resolver. Document/attempt both `x86_64` and `aarch64` macOS runners; integration spec excluded by default (spec §13).
- AC:
  1. CI is green with **no** Ollama and no network access to a model.
  2. Integration spec is excluded from the default CI job (tag/segregation).
  3. CI config notes how to run on both arches (or documents the limitation per finding R9).

---

### EPIC B — Typed Core (domain + no-bypass enforcement)
The heart of the product: precise types and the single enforcement chokepoint.

| ID | Title | Priority | Est (d) | Deps | Status |
|---|---|---|---|---|---|
| STORY-04 | `Governance.Types`: domain newtypes, smart ctors, Decision/Violation/Stage | P0 | 1.0 | STORY-01 | todo |
| STORY-05 | `Governance.Enforce`: `Governed` phantom type + enforce request/response | P0 | 1.0 | STORY-04 | todo |
| STORY-06 | `Governance.Model`: typed `ModelBackend` port | P0 | 0.5 | STORY-05 | todo |
| STORY-07 | `should-not-compile` negative cases for no-bypass | P0 | 0.5 | STORY-05, STORY-06 | todo |

**STORY-04 — `Governance.Types`**
- Description: newtypes (`Prompt`, `SystemPrompt`, `ModelName`, `Principal`, `Role`, `Scope`) with **unexported** raw constructors and `mkX :: Text -> Either Violation X`; records `ModelRequest`/`ModelResponse`; `Decision a` sum; `Violation`/`Reason`; `RedactionSpan`; `data Stage = Raw | Checked` (DataKinds). (Spec §5.1, §8.)
- AC:
  1. Raw newtype constructors are not in the module export list; only smart ctors + accessors exported.
  2. `mkPrompt ""` returns `Left (Violation …)`; valid input returns `Right`.
  3. `Decision` and `Violation` derive `Eq`/`Show`; module compiles with `-Wall` clean.

**STORY-05 — `Governance.Enforce` (no-bypass core)**
- Description: `newtype Governed (s::Stage) a` with **unexported** constructor; `enforceRequest`/`enforceResponse :: Policy -> X -> Either Violation (Governed 'Checked X)`; `unGoverned :: Governed 'Checked a -> a` (only `'Checked`). Enforcement applies the policy, transforms, and redactions inside. (Spec §5.3, §10.1.)
- AC:
  1. `Governed` constructor is not exported; no public way to build `Governed 'Checked` except `enforce*`.
  2. `enforceRequest` returns `Left Violation` on Deny and `Right` (with redactions/transforms applied) on Allow.
  3. `unGoverned` typechecks only for `'Checked`; there is no `unGoverned` for `'Raw`.

**STORY-06 — `Governance.Model` port**
- Description: `data ModelBackend = ModelBackend { runModel :: Governed 'Checked ModelRequest -> IO ModelResponse }`; returns **raw** response (spec §5.4).
- AC:
  1. `runModel` input type is `Governed 'Checked ModelRequest`; passing a raw/ungoverned value is a type error.
  2. `runModel` returns raw `ModelResponse` (forces response-side enforcement).

**STORY-07 — Negative compile cases (no-bypass proof)**
- Description: Documented `should-not-compile` snippets proving bug classes 1 & 3 (spec §10.1): (a) calling `runModel` with an ungoverned request; (b) reading response text without `enforceResponse`. Wire via a test that asserts these do not compile (e.g. `-fdefer-type-errors` check, or doctest/markdown with documented expected error).
- AC:
  1. At least one negative case for "ungoverned request to model" is documented and shown not to compile.
  2. At least one negative case for "unchecked response consumed" is documented and shown not to compile.

---

### EPIC C — Policy primitives & composition
Composable typed policies with documented monoidal semantics.

| ID | Title | Priority | Est (d) | Deps | Status |
|---|---|---|---|---|---|
| STORY-08 | `Governance.Policy`: Policy value + combinators | P0 | 1.0 | STORY-04 | todo |
| STORY-09 | Composition semantics + Monoid instance | P0 | 0.5 | STORY-08 | todo |
| STORY-10 | `Governance.Redact`: span redaction + detectors | P0 | 1.0 | STORY-04 | todo |

**STORY-08 — `Governance.Policy` primitives**
- Description: `newtype Policy` with `runPolicy` + `policyName`; combinators `allowList`, `denyList`, `denyIf`, `redactWith`, `transformWith`, `requireRole`, `requireScope`, `composeP` (spec §5.2).
- AC:
  1. Each combinator produces a `Policy` value usable without changing `enforce*` (PRD G2).
  2. `requireRole`/`requireScope` yield `Deny` when the subject lacks the role/scope.

**STORY-09 — Composition semantics + Monoid**
- Description: Implement `(<>)`/`mempty` with documented semantics: Deny absorbing/short-circuit, transforms left-to-right, redactions merged, Allow identity (spec §5.2, finding R4).
- AC:
  1. `mempty <> p == p` and `p <> mempty == p` (property-tested).
  2. A composition containing a Deny yields Deny regardless of later policies (Deny-absorption, property-tested).
  3. Composition is associative for the documented semantics (property-tested).

**STORY-10 — `Governance.Redact`**
- Description: `applyRedactions`, `emailSpans`, `phoneSpans`, `secretSpans`; non-reversible mask; coalesce overlapping spans; validate span ranges (spec §5.5, §8, finding R5).
- AC:
  1. `applyRedactions` replaces every detected span with a fixed mask `‹REDACTED:label›`.
  2. Overlapping/adjacent spans are coalesced; out-of-range spans rejected/clamped safely.
  3. The detected secret substring never appears in the output (property-tested).

---

### EPIC D — Adtech flagship & model backends
The regulated-domain example, wired end-to-end, mock + Ollama.

| ID | Title | Priority | Est (d) | Deps | Status |
|---|---|---|---|---|---|
| STORY-11 | Adtech policy bundle (request + response) | P0 | 1.0 | STORY-08, STORY-10 | todo |
| STORY-12 | Mock `ModelBackend` (deterministic) | P0 | 0.5 | STORY-06 | todo |
| STORY-13 | `Governance.Ollama` backend (http-client + aeson) | P0 | 1.0 | STORY-06 | todo |
| STORY-14 | `adtech-agent` example exe (`--mock` / `--ollama`) | P0 | 1.0 | STORY-11, STORY-12, STORY-13 | todo |

**STORY-11 — Adtech policy bundle**
- Description: Request policy = redact PII (email/phone) + `Deny` protected-class targeting (race, religion, health, sexual orientation, …); response policy = disallowed-claims deny (`guaranteed`, `miracle cure`, `100% risk-free`, …) + PII-leak redaction. Built **only** from EPIC C primitives (PRD FR6, G2).
- AC:
  1. A request with PII yields a checked request with PII redacted (PRD §9 AC1).
  2. A request targeting a protected class yields `Left (Violation …)` and is never sent (PRD §9 AC2).
  3. A response containing a disallowed claim yields `Left (Violation …)` (PRD §9 AC3).
  4. No change to `enforce*`/`runPolicy` core was required to add the bundle.

**STORY-12 — Mock backend**
- Description: Deterministic `ModelBackend` (echo/canned) for offline tests and `--mock` (spec §9).
- AC:
  1. Mock returns deterministic output for a given checked request.
  2. Offline test suite uses only the mock; no network.

**STORY-13 — Ollama backend**
- Description: `ollamaBackend :: OllamaConfig -> ModelBackend` POSTing to `http://localhost:11434/api/generate` with `stream:false` via `http-client` (no TLS) + `aeson`; map `model`/`response` to `ModelResponse`; transport errors surfaced as typed errors, never as `Allow` (spec §5.6, §12, finding R3).
- AC:
  1. Encodes the request JSON exactly as spec §6.2 and decodes `response`.
  2. Connection failure produces a clearly-typed error distinct from a policy decision.
  3. No dependency on `http-client-tls`.

**STORY-14 — `adtech-agent` example**
- Description: Composition root wiring `enforceRequest` → `runModel` → `enforceResponse`, printing Decision/Violation + final governed output; `--mock` (default) and `--ollama` flags; scenario flags for protected-class/disallowed-claim demos (spec §5.7, §6.3).
- AC:
  1. `adtech-agent --mock` runs end-to-end offline and prints the per-stage trace + final output.
  2. `adtech-agent --ollama` runs against local Ollama when present.
  3. Protected-class and disallowed-claim scenarios print an explicit Deny without surfacing model output.

---

### EPIC E — Test suite & hardening
Deterministic specs, property laws, segregated integration.

| ID | Title | Priority | Est (d) | Deps | Status |
|---|---|---|---|---|---|
| STORY-15 | hspec unit specs: allow/deny/redact/transform/no-bypass + adtech | P0 | 1.0 | STORY-11, STORY-12 | todo |
| STORY-16 | QuickCheck property laws (idempotence, Deny-absorbing, redaction-non-leak, governed-reflects-policy) | P0 | 1.0 | STORY-09, STORY-10 | todo |
| STORY-17 | Segregated Ollama integration spec (tagged, off by default) | P1 | 0.5 | STORY-13, STORY-14 | todo |

**STORY-15 — Deterministic unit specs**
- Description: Offline hspec specs over the mock backend: allow, deny, redact, transform, no-bypass behavior; adtech policies (PII redaction, protected-class denial, brand-safety denial). (PRD FR7, NFR3.)
- AC:
  1. Specs cover allow/deny/redact/transform + the three adtech outcomes.
  2. Suite passes offline with no Ollama; coverage of core modules > 80% (PRD DoD).

**STORY-16 — Property laws**
- Description: QuickCheck properties: enforcement idempotent; Deny absorbing under composition; redaction never leaks the secret substring; a `Governed` value always reflects an applied policy. (Spec §5.2, §5.5, §10.)
- AC:
  1. All four property classes implemented and green.
  2. Properties run in the offline default suite.

**STORY-17 — Integration spec (segregated)**
- Description: hspec integration spec hitting local Ollama, tagged so it is **not** in default CI; asserts policy outcomes match the mock run (PRD §9 AC4, A5). (Spec §13.)
- AC:
  1. Spec is excluded from the default `stack test` CI run.
  2. When run with Ollama present, policy decisions match the deterministic mock outcomes.

---

## 3. Execution Phases

### Phase 1 — Foundation (infra, build, CI)
**Stories:** STORY-01 → STORY-02 → STORY-03.
Rationale: Nothing can be verified without a reproducible, cross-arch build and a green offline CI. Isolating the legacy Servant package (R2) and pinning GHC 9.6.6 (legacy-toolchain risk) are prerequisites for everything else.

### Phase 2 — Core Features
**Stories (ordered):** STORY-04 → STORY-05 → STORY-06 → STORY-07 (no-bypass core proven) → STORY-08 → STORY-09 → STORY-10 (policy + redaction) → STORY-11 → STORY-12 (adtech bundle + mock).
Rationale: Build the typed spine first (Types → Enforce → Model) and immediately lock the no-bypass guarantee with negative compile cases (the product's core value). Then policy primitives/composition and redaction, which the adtech bundle composes from. The mock backend unblocks offline testing without Ollama.

### Phase 3 — Integration & Hardening
**Stories (ordered):** STORY-13 → STORY-14 (Ollama + example end-to-end) → STORY-15 → STORY-16 (deterministic + property suites) → STORY-17 (segregated integration).
Rationale: Wire the real backend and example last, then harden with the full deterministic + property suites that gate DoD, and finally add the off-by-default Ollama integration spec.

---

## 4. Definition of Done
- Compiles cleanly on the pinned resolver (GHC 9.6.6) with `-Wall` and `-Werror=incomplete-patterns`.
- Unit tests pass; **coverage > 80%** of core modules; property tests pass.
- Offline deterministic suite is green with **no** Ollama/network (PRD NFR3).
- No-bypass guarantee demonstrated by documented `should-not-compile` cases (PRD G1/G3).
- Adtech flagship passes all PRD §9 acceptance criteria (mock; Ollama when present).
- Builds on macOS Intel **and** Apple Silicon from the pinned resolver (PRD NFR1/NFR2).
- Code reviewed and approved; README/spec updated; no critical vulnerabilities.

---

## 5. Risks & Blockers
| Risk / Blocker | Mitigation |
|---|---|
| Apple Silicon CI runner unavailable | Pinned resolver guarantees identical bindist selection; verify aarch64 manually if no runner (spec R9). |
| Legacy `src/Main.hs` collides with new package | STORY-02 isolates it; new package builds independently (spec R2). |
| `should-not-compile` cases hard to assert in CI | Use documented expected-error snippets / `-fdefer-type-errors` probe; treat as docs + manual gate if needed (STORY-07). |
| Ollama absent during E2E | `--mock` default; integration spec segregated; CI never depends on Ollama. |
| Redaction misses a PII format | Guarantee is the substring-non-leak invariant for detected spans, not perfect recall (spec R8). |

## 6. Assumptions
- A1 — Haskell-capable consumers; idiomatic API acceptable (PRD A2).
- A2 — `lts-22.43` / GHC 9.6.6 bindists available for both arches (PRD A6).
- A3 — PII/protected-class/disallowed-claims lists are illustrative typed values (PRD A4).
- A4 — Determinism asserted on policy decisions, not raw LLM text (PRD A5).
- A5 — Ollama + `llama3.2:1b` available locally for E2E only (PRD A3).
