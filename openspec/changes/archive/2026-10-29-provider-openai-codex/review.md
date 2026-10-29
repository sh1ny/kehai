# Review

## Metadata

- **Round:** 3
- **Prior round:** round 2 APPROVE_WITH_CHANGES on the superseded Codex-client design, changes applied.
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** Current `proposal.md`, `design.md`, `tasks.md`, all three capability specs and `review.md`, limited to M1–M7, S1–S2 and contradictions associated with their edits. Previously accepted items remain accepted.
- **Upstream verification:** No fresh upstream spot-check was performed in this re-check. The previous review recorded successful checks of the official errors-and-recovery and preview-limitations pages, but could not verify the pinned pi source. Its exact JSON shape, line citations and backend-verification comment remain independently unverified, as do the historical source claims. No files were written, and implementation tests or strict validation were not run.

## Findings

### Critical (blocking)

None.

### Moderate

**M1 — A pending login can undo logout or replace a newer account registration.**

The original design read the registration before browser authorization, verified against that snapshot, then took the lock only to write the completed login. Atomic replacement prevented torn records but did not prevent stale operations from overwriting newer decisions.

**Re-check:** Remains resolved. D3 retains the generation and registration comparison under `auth.lock`. D6a step 2 advances the generation whenever a record exists, including host-only and tokenless-registration records, for ordinary logout and `--forget`. The no-record exception is consistent with D3 creating the host record under the lock before authorization begins.

The *Tokenless logout during a pending login* scenario and its test-map row cover host-only logout, host-only `--forget`, and logout of a disabled registration during pending consent recovery. Task 5.3 and the state descriptions agree. No new M1 contradiction was found.

**M2 — `--forget` does nothing in the recovery state where it is needed.**

The original D6a returned immediately when no token set existed, making registration removal unreachable after ordinary logout or terminal refresh clearing.

**Re-check:** Remains resolved. D6a step 2 removes an existing registration without a network request and advances the generation. Credential-store’s *Forget after logout* scenario and its CLI test-map row retain coverage.

**M3 — Declined plan permission discards the registration and provides no effective consent-recovery path.**

The original design stored nothing after a verified exchange lacking `chatgpt.tokens.use.direct`, losing the registration and offering only ordinary login as recovery.

**Re-check:** Resolved. The second follow-up corrects all three remaining qualifications:

- Provider-auth’s *Credentials observed per request* explicitly covers both model and models requests. A tokenless disabled registration discards cached credentials and returns `not permitted` naming `--enable-plan-usage`, without a backend request; other tokenless states return `reauth required`.
- Doctor’s *Not logged in* scenario now excludes disabled registrations. Its separate *Plan usage not enabled* scenario names `kehai login openai --enable-plan-usage`, lists no models and exits non-zero. The doctor test-map rows preserve this distinction.
- The *No subscription credentials* test-map row now explicitly excludes disabled registrations, while the separate *Plan usage disabled* row requires `not_permitted` without a request.

These requirements agree with D2’s retained disabled registration and consent recovery, D4’s scope-loss handling, D5’s per-request distinction, D6’s record invariant, credential-store’s qualified tokenless scenario and model-provider’s two separate scenarios. No remaining M3 contradiction was found.

**M4 — The tool request shape does not implement the cited preview rules.**

The original D7 emitted bare function definitions in top-level `tools`, without evidence that the preview route accepted them.

**Re-check:** Remains resolved at design level. D7 specifies one leading `additional_tools` input item, omits top-level `tools`, and preserves `function_call` / `function_call_output` pairing by `call_id`. The spec, request assertions and task 6.4 agree. Task 8.2 requires an actual completed two-turn tool round trip.

Independent verification of the precise pinned pi shape remains unavailable from the earlier review; real-route acceptance remains explicitly pending.

**M5 — `response.incomplete` is exposed as a completion despite the explicit success boundary.**

The original D10 mapped incomplete responses to `Completed(incomplete(reason))`, creating ambiguity about success and tool execution.

**Re-check:** Remains resolved. D10 and the spec require usage followed by `Failed(incomplete)` with a sanitized reason. Tool calls are held until `response.completed` and discarded on unsuccessful termination. The test map retains incomplete-after-text, incomplete-after-tool-call and connection-drop coverage.

**M6 — Successful connection setup has an uncovered indefinite-wait path.**

The original timeout contract did not explicitly cover waiting for response headers or the first SSE event after request transmission.

**Re-check:** Remains resolved. D10 retains the response-silence deadline covering headers, the first event and subsequent events, with upload-stall coverage, backpressure suspension, cancellation arbitration, `sent:true` expiry and no resend. The spec, resource table, test map and task 6.4 retain both missing-response cases.

**M7 — The credential-boundary requirement contradicts the mandatory login output.**

The original boundary prohibited `state` and `nonce` in all command output while login required printing the full authorize URL.

**Re-check:** Remains resolved. Credential-store narrowly permits the intentional authorize URL display and browser-launcher argument, including `state` and `nonce`. D3 and provider-auth reference the exception. The output, environment and rejected-paste exclusions remain covered.

### Suggestions

**S1 — The retained historical comparison does not meet the project’s stated comparison contract.**

The earlier historical subsection omitted the detailed PKCE, redirect, scope and refresh/expiry comparison.

**Re-check:** Remains addressed. The historical table retains those dimensions alongside state, token-valid endpoint, service-change failure, reversal cost and API-key fallback. This accepts preservation of the comparison; it does not independently validate its historical source claims.

**S2 — The Windows security test name overstates what its test proves.**

The earlier test changed entropy under the same Windows user while claiming to prove cross-user isolation.

**Re-check:** Remains addressed. The scenario and test are named *Wrong DPAPI entropy cannot decrypt*. Risks and task 1.1 distinguish that test from cross-user isolation, which is recorded as a DPAPI platform property.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

All seven Required Changes are fully applied at design level, and S1–S2 are addressed. The second M3 follow-up resolves the remaining tokenless-request, doctor and test-map conflicts. No new contradiction associated with these edits was found. Real-route acceptance and the previously unverified upstream source claims remain subject to the recorded verification limits.

## Required Changes

1. **Resolve M1:** Retain D3’s commit-time comparison. Amend D6a so ordinary logout and `--forget` invalidate pending logins by advancing the generation under `auth.lock`, including host-only and registration-without-tokens states. Update the relevant state descriptions and tests. Explicitly cover a pending first login followed by logout, a pending login with a tokenless registration followed by logout, and host-only `--forget`. **Applied — accepted by reviewer.**
2. **Resolve M2:** Change D6a’s no-token branch so `--forget` still atomically removes an existing registration under the lock, without revocation. Add a scenario and CLI test for ordinary logout followed by `logout --forget`, asserting only the host id and generation remain. **Applied — accepted by reviewer.**
3. **Resolve M3:** Retain the disabled-registration state and explicit consent recovery. Qualify credential-store’s *Logged in only with a token set* and model-provider’s *No subscription credentials* so disabled registrations yield `not_permitted` with `--enable-plan-usage`, while other absent-token states yield `reauth_required`. Align their test-map expectations with D5 and provider-auth. **Applied — accepted by reviewer**, including the second follow-up’s qualifications to provider-auth’s *Credentials observed per request*, doctor’s *Not logged in* scenario and the corresponding test-map expectations.
4. **Resolve M4:** Specify a tool representation supported by the preview rules, with matching call/result mapping, request-shape assertions and an actual completed tool round trip in task 8.2. **Applied — accepted by reviewer; independent pinned-source verification remains unavailable.**
5. **Resolve M5:** Make `response.incomplete` unsuccessful, preserving usage and a sanitized reason, and prohibit tool execution from incomplete output. Align D10, specs and tests. **Applied — accepted by reviewer.**
6. **Resolve M6:** Cover response headers, the first SSE event and subsequent events with an explicit response-silence deadline, including backpressure, cancellation, sent classification and no resend. Add both missing-response tests. **Applied — accepted by reviewer.**
7. **Resolve M7:** Permit only the intentional authorize URL display/browser handoff while preserving all other credential-output exclusions, and test both sides of that boundary. **Applied — accepted by reviewer.**

CHANGES_APPLIED: yes

## Rebuttals

Author's record of applied changes (round 3):

1. **M1:** D3 steps 1 and 8 snapshot `generation` and the registration at start and, under `auth.lock` at commit, reload and reject on any change (nothing stored, the obtained refresh token revoked best-effort). The record gains `generation`, advanced by login, logout and `--forget`, never by refresh. Concurrent first sign-ins: the first commit wins, the second is rejected. New provider-auth requirement *Stale login rejected* (4 scenarios); Flow & State Gaps rewritten; T2/T3, State & Ownership, Failure table and ledger updated; 4 test rows. **— accepted by reviewer**, together with the follow-up’s tokenless generation advance.
2. **M2:** D6a step 2 handles the no-token case: with `--forget` and a registration it writes only `host_id` and `generation + 1`, with no network request. New credential-store scenario *Forget after logout* plus CLI test row. **— accepted by reviewer**
3. **M3:** D2 *Plan-usage state*: a verified sign-in without `chatgpt.tokens.use.direct` stores the registration with `plan_usage: "disabled"` and no tokens. `kehai login openai --enable-plan-usage` sends the saved client id, the full scopes and `prompt=consent` (`force_reconsent` only after OpenAI confirms deployment); ordinary sign-ins send neither. D4: losing the scope on refresh clears tokens, marks plan usage disabled and returns `not_permitted`. D5: no request while disabled. D6 record, doctor and proposal updated. New provider-auth requirement *Plan usage consent* (7 scenarios), doctor scenario *Plan usage not enabled*; the old plan-scope scenarios were moved there. 8 test rows. **— accepted by reviewer**, together with both follow-ups’ qualifications and test-map alignment.
4. **M4:** D7 removes top-level `tools`. Tools go in one leading `{type:"additional_tools", role:"developer", tools:[…]}` input item, with pi's verified shape cited (`api/openai-responses-shared.ts:157-245`), standard `function_call`/`function_call_output` items, and bare tools and namespaces rejected. *Token-sharing request rules* and its scenario are updated, and the fake asserts the shape. Task 8.2 now requires a real two-turn round trip: a `ToolCall` with `Completed(tool_use)`, then text with `Completed(end_turn)`. **— accepted by reviewer**, with the pinned pi source independently unverified; real-route acceptance remains pending task 8.2.
5. **M5:** D10: `Completed{end_turn | tool_use}` only. `response.incomplete` → `Usage` + `Failed(incomplete)` with a validated reason. Function calls are held and emitted only on `response.completed`, so a failed or incomplete turn emits no `ToolCall`. New kind `incomplete`; new requirement *Incomplete response* (after text, after a tool call); *Complete tool calls* gains *Tool call then connection drop*. 3 test rows. **— accepted by reviewer**
6. **M6:** D10 *Response-silence deadline*: it starts when the body is flushed, restarts on the headers and on each event, stops while the subscriber pauses, and on expiry gives `Failed(idle_timeout, sent:true)` with no resend; cancellation stops it first. The spec requirement is rewritten, with scenarios *Headers withheld*, *Headers without events* and *Paused subscriber is not a stall*. Resource Bounds updated; 3 test rows. **— accepted by reviewer**
7. **M7:** *Credentials never leave the boundary* now allows only the authorize URL (with `state`/`nonce`), printed once and passed as the launcher argument. New scenarios *Authorize URL handoff* (no other output, error or environment carries state, nonce, verifier or code) and *Rejected pasted URL is not echoed*. D3 step 3 and the provider-auth *Authorize URL is always shown* text reference the exception. 2 test rows. **— accepted by reviewer**
- **S1:** *Upstream sources compared* restores the historical table (codex, omp, oc@ec3ae17, nm against Kehai): PKCE, state, redirect, scopes, token-valid endpoint, refresh/expiry, service-change failure, reversal cost, API-key fallback. **— accepted by reviewer**
- **S2:** The scenario and test are renamed *Wrong DPAPI entropy cannot decrypt*. Cross-user isolation is recorded as a DPAPI platform property in Risks and ADR 0009 (task 1.1), not as test evidence. **— accepted by reviewer**

Strict validation passes; 123 scenarios map one-to-one to 123 test-map rows. **— author-reported historical result; not independently rerun.**

Author's record of the follow-up (round-3 re-check):

- **M1:** D6a step 2 now writes the record back with `generation + 1` whenever a record exists, for host-only and tokenless-registration records, with or without `--forget`. With no record nothing is written, because a pending login always stores the host id first. New provider-auth scenario *Tokenless logout during a pending login*, whose test covers a pending first login followed by logout, host-only `--forget`, and logout of a disabled registration during a pending `--enable-plan-usage`. *Logout without credentials* now asserts the generation advance. Flow & State Gaps and State & Ownership are updated. **— accepted by reviewer**
- **M3:** Credential-store *Logged in only with a token set* is qualified: `reauth required` only when the registration is not marked plan usage disabled, otherwise `not permitted` naming `--enable-plan-usage`. Model-provider *No subscription credentials* is qualified the same way, and a new scenario *Plan usage disabled* gives `not_permitted`. Test-map rows are aligned. **— accepted by reviewer**, with the remaining test-map and provider-auth qualifications completed in the second follow-up.

Strict validation passes; 125 scenarios map one-to-one to 125 test-map rows. **— author-reported result; not independently rerun.**

Author's record of the second follow-up:

- **M3:** provider-auth *Credentials observed per request* now fails a tokenless record with `not permitted` naming `--enable-plan-usage` when the registration is marked plan usage disabled, and with `reauth required` otherwise. The doctor *Not logged in* scenario is qualified to records without a disabled registration; *Plan usage not enabled* covers the disabled one. The *No subscription credentials* and doctor *Not logged in* test-map rows are qualified to match. D5 already states the same split. **— accepted by reviewer.** The current artifacts contain these qualifications, the per-request rule covers both model and models requests, and the remaining M3 contradictions are resolved.