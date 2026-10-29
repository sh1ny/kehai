# Tasks

## Test map

Platform-tagged tests are marked in the test name and run on the platform named:
- `[unix]` tests are skipped on Windows and run on the Linux (WSL) runner;
- `[windows]` tests run on native Windows only.

Ownership scenarios that need a second Unix user are driven through the injected `stat` seam (D6). One real FFI `stat` test proves the seam's production implementation.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| credential-store → Platform credential backend | Unix file is private | test/auth/credential_store_test.dart | [unix] stored auth.json is 0600 in a 0700 home with version 1 and all three parts | green |
| credential-store → Platform credential backend | Windows file is encrypted | test/auth/credential_store_test.dart | [windows] auth.dpapi holds no token text and round-trips | green |
| credential-store → Platform credential backend | Wrong DPAPI entropy cannot decrypt | test/auth/credential_store_test.dart | [windows] blob fails to decrypt under another entropy | green |
| credential-store → Credential record parts | Logged in only with a token set | test/cli/cli_test.dart | tokenless enabled registration reports not logged in and fails reauth; disabled one fails not_permitted | red |
| credential-store → Fail closed without a secure backend | Unix permissions too open | test/auth/credential_store_test.dart | [unix] group or other bits on auth.json refuse the load | green |
| credential-store → Fail closed without a secure backend | Unsafe Unix home or link | test/auth/credential_store_test.dart | [unix] symlinked home, symlinked or non-regular auth.json are refused | green |
| credential-store → Fail closed without a secure backend | Secure write unavailable | test/auth/credential_store_test.dart | failing protect or open call stores nothing and leaves no file | green |
| credential-store → Trusted credential home path | Home beneath a shared writable parent | test/auth/home_trust_test.dart | writable non-sticky parent is rejected before any access or lock | green |
| credential-store → Trusted credential home path | Home reached through a symlinked ancestor | test/auth/home_trust_test.dart | [unix] symlinked ancestor resolves to canonical path used for file and lock | green |
| credential-store → Trusted credential home path | Sticky shared parent | test/auth/home_trust_test.dart | root-owned sticky world-writable ancestor is accepted | green |
| credential-store → Trusted credential home path | Ancestor owned by another user | test/auth/home_trust_test.dart | ancestor owned by another user is rejected even at 0755 | green |
| credential-store → Trusted credential home path | Sticky parent owned by another user | test/auth/home_trust_test.dart | sticky ancestor owned by another user is rejected | green |
| credential-store → Trusted credential home path | Home owned by another user | test/auth/home_trust_test.dart | home owned by another user is rejected | green |
| credential-store → Atomic credential replacement | Successful replacement | test/auth/credential_store_test.dart | replacement returns new record and leaves no temp file | green |
| credential-store → Atomic credential replacement | Interrupted write | test/auth/credential_store_test.dart | failure before rename keeps the previous record | green |
| credential-store → Cross-process credential lock | Two processes refresh at once | test/auth/refresher_process_test.dart | two processes refreshing send exactly one refresh | green |
| credential-store → Cross-process credential lock | Holder dies | test/auth/refresher_process_test.dart | killed lock holder does not block the next process | green |
| credential-store → Credentials never leave the boundary | Doctor output is token-free | test/cli/cli_test.dart | doctor output contains no stored token | red |
| credential-store → Credentials never leave the boundary | Authorize URL handoff | test/auth/browser_login_test.dart | authorize url with state and nonce appears once on stdout and as launcher argument, nowhere else | red |
| credential-store → Credentials never leave the boundary | Rejected pasted URL is not echoed | test/auth/browser_login_test.dart | rejected pasted url is not echoed | red |
| credential-store → Credentials never leave the boundary | Subprocess environment is token-free | test/auth/browser_login_test.dart | browser launcher environment contains no token | red |
| credential-store → Locally composed failure text | Failure messages are token-free | test/auth/failure_text_test.dart | echoed secrets in message, code or param never surface | green |
| credential-store → Locally composed failure text | Server message is not relayed | test/auth/failure_text_test.dart | server message and detail fields are dropped | green |
| credential-store → Locally composed failure text | Suspicious error code | test/auth/failure_text_test.dart | uppercase, long or secret-bearing codes become unrecognized | green |
| credential-store → Logout clears stored tokens | Logout with credentials | test/cli/cli_test.dart | logout clears tokens, keeps host id and registration, doctor reports not logged in | red |
| credential-store → Logout clears stored tokens | Logout without credentials | test/cli/cli_test.dart | logout without tokens prints not logged in, exits zero, sends no revocation, advances generation | red |
| credential-store → Logout clears stored tokens | Forget the registration | test/cli/cli_test.dart | logout --forget while logged in revokes and keeps only host id and generation | red |
| credential-store → Logout clears stored tokens | Forget after logout | test/cli/cli_test.dart | logout then logout --forget sends no revocation and keeps only host id and generation | red |
| model-provider → Normalized turn stream | Text answer | test/provider/chatgpt_adapter_test.dart | text deltas then usage then completed end_turn | green |
| model-provider → Normalized turn stream | Stream ends early | test/provider/chatgpt_adapter_test.dart | early close ends with protocol failure | green |
| model-provider → Complete tool calls | Two parallel tool calls | test/provider/chatgpt_adapter_test.dart | two function calls emit two complete tool calls and tool_use | green |
| model-provider → Complete tool calls | Tool result round trip | test/provider/chatgpt_adapter_test.dart | tool call and output are sent paired by call id | green |
| model-provider → Complete tool calls | Tool call then connection drop | test/provider/chatgpt_adapter_test.dart | finished function call then drop emits no tool call and fails network | green |
| model-provider → Complete tool calls | Malformed arguments | test/provider/chatgpt_adapter_test.dart | malformed arguments pass through unchanged | green |
| model-provider → Incomplete response | Incomplete after text | test/provider/chatgpt_adapter_test.dart | incomplete after text yields usage then failed incomplete with reason | green |
| model-provider → Incomplete response | Incomplete after a tool call | test/provider/chatgpt_adapter_test.dart | incomplete after function call emits no tool call | green |
| model-provider → Opaque reasoning continuity | Reasoning passed back | test/provider/chatgpt_adapter_test.dart | reasoning item is forwarded byte-identical | green |
| model-provider → Opaque reasoning continuity | No reasoning returned | test/provider/chatgpt_adapter_test.dart | no reasoning item emits no opaque event | green |
| model-provider → Usage and token estimate | Usage reported | test/provider/chatgpt_adapter_test.dart | usage maps input cached output and reasoning | green |
| model-provider → Usage and token estimate | Usage absent | test/provider/chatgpt_adapter_test.dart | missing usage yields unknown counts | green |
| model-provider → Usage and token estimate | Estimate before sending | test/provider/estimate_test.dart | estimate is at least utf8 bytes over three | green |
| model-provider → Typed sanitized failures | Context too long | test/provider/chatgpt_adapter_test.dart | context_length_exceeded maps to context_overflow | green |
| model-provider → Typed sanitized failures | Usage limit reached | test/provider/chatgpt_adapter_test.dart | sharing usage limit codes map to usage_limit in http and event form without retry-after | green |
| model-provider → Typed sanitized failures | Plan usage not permitted | test/provider/chatgpt_adapter_test.dart | 403 and eligibility codes map to not_permitted | green |
| model-provider → Typed sanitized failures | Plan usage temporarily unavailable | test/provider/chatgpt_adapter_test.dart | 503 and unavailable codes map to server and keep credentials | green |
| model-provider → Typed sanitized failures | Unsupported capability | test/provider/chatgpt_adapter_test.dart | unsupported_capability maps to invalid_request with param | green |
| model-provider → Typed sanitized failures | Rate limited | test/provider/chatgpt_adapter_test.dart | plain 429 maps to rate_limited with retry-after | green |
| model-provider → Typed sanitized failures | Unknown server error body | test/provider/chatgpt_adapter_test.dart | html and detail bodies are excluded from the failure | green |
| model-provider → No automatic resend | Connection drops mid-stream | test/provider/chatgpt_adapter_test.dart | mid-stream drop fails network sent and sends nothing more | green |
| model-provider → No automatic resend | Connection refused | test/provider/chatgpt_adapter_test.dart | refused connection fails network not sent and does not retry | green |
| model-provider → Cancellation and idle deadline | Caller cancels | test/provider/chatgpt_adapter_test.dart | cancel token aborts and ends with cancelled | green |
| model-provider → Cancellation and idle deadline | Subscriber stops listening | test/provider/chatgpt_adapter_test.dart | subscription cancel closes the connection | green |
| model-provider → Cancellation and idle deadline | Backend stalls | test/provider/chatgpt_adapter_test.dart | stalled backend ends with idle_timeout | green |
| model-provider → Cancellation and idle deadline | Headers withheld | test/provider/chatgpt_adapter_test.dart | body read but no headers ends idle_timeout sent with one request | green |
| model-provider → Cancellation and idle deadline | Headers without events | test/provider/chatgpt_adapter_test.dart | sse headers without events ends idle_timeout with one request | green |
| model-provider → Cancellation and idle deadline | Paused subscriber is not a stall | test/provider/chatgpt_adapter_test.dart | subscriber paused beyond the deadline resumes and completes | green |
| model-provider → Bounded stream input | Oversized event | test/provider/sse_test.dart | event over 8 MiB fails protocol | green |
| model-provider → Bounded stream input | Normal large output | test/provider/chatgpt_adapter_test.dart | 2 MiB of deltas completes normally | green |
| model-provider → ChatGPT plan backend | Request shape | test/provider/chatgpt_adapter_test.dart | request targets v1 responses with bearer and sse accept | green |
| model-provider → ChatGPT plan backend | No subscription credentials | test/provider/chatgpt_adapter_test.dart | no token set without a disabled registration fails reauth_required without a request | green |
| model-provider → ChatGPT plan backend | Plan usage disabled | test/provider/chatgpt_adapter_test.dart | disabled registration fails not_permitted without a request | green |
| model-provider → ChatGPT plan backend | Request too large | test/provider/chatgpt_adapter_test.dart | body over 1 MiB fails context_overflow without a request | green |
| model-provider → Token-sharing request rules | Token-sharing body | test/provider/chatgpt_adapter_test.dart | body follows token-sharing rules with allowlisted keys | green |
| model-provider → Model listing | Models listed | test/provider/models_test.dart | listed models exclude non-list visibility and unsupported | green |
| model-provider → Model listing | Models endpoint fails | test/provider/models_test.dart | 503 fails server with no list | green |
| model-provider → Model listing | Oversized models response | test/provider/models_test.dart | body over 4 MiB fails protocol | green |
| provider-auth → Sign in with ChatGPT | Successful login | test/auth/browser_login_test.dart | verified callback stores registration and tokens and reports account | red |
| provider-auth → Sign in with ChatGPT | State mismatch | test/auth/browser_login_test.dart | state mismatch exchanges nothing | red |
| provider-auth → Sign in with ChatGPT | Authorization denied | test/auth/browser_login_test.dart | error parameter fails naming the code | red |
| provider-auth → Sign in with ChatGPT | Code rejected | test/auth/browser_login_test.dart | invalid_grant on exchange stores nothing | red |
| provider-auth → Sign in with ChatGPT | No API key requested | test/auth/browser_login_test.dart | no api key grant and no api key field | red |
| provider-auth → Dynamic client registration | First sign-in registers a client | test/auth/browser_login_test.dart | first login uses dynamic_agent_client and saves the issued id | red |
| provider-auth → Dynamic client registration | Registration incomplete | test/auth/browser_login_test.dart | first login without issued id stores nothing | red |
| provider-auth → Dynamic client registration | Later sign-in reuses the client | test/auth/browser_login_test.dart | later login reuses saved client without name hint | red |
| provider-auth → Dynamic client registration | Different client returned | test/auth/browser_login_test.dart | different issued id is rejected | red |
| provider-auth → Dynamic client registration | Host id is stable | test/auth/browser_login_test.dart | host id survives logout --forget | red |
| provider-auth → Token verification and plan-usage grant | Verified login | test/auth/jwt_test.dart | rs256 token with expected claims verifies and yields subject and email | green |
| provider-auth → Token verification and plan-usage grant | Invalid ID token | test/auth/jwt_test.dart | bad signature, alg, iss, aud, exp or nonce each fail naming the check | green |
| provider-auth → Token verification and plan-usage grant | Different account | test/auth/browser_login_test.dart | different subject fails naming logout --forget | red |
| provider-auth → Plan usage consent | Plan usage not granted | test/auth/browser_login_test.dart | grant without direct scope stores registration as plan usage disabled and no tokens | red |
| provider-auth → Plan usage consent | Enable plan usage | test/auth/browser_login_test.dart | enable-plan-usage sends saved client, full scopes and prompt=consent, then stores tokens | red |
| provider-auth → Plan usage consent | Consent declined again | test/auth/browser_login_test.dart | enable-plan-usage still without scope keeps plan usage disabled | red |
| provider-auth → Plan usage consent | Enable without a registration | test/auth/browser_login_test.dart | enable-plan-usage without registration binds nothing and fails | red |
| provider-auth → Plan usage consent | Ordinary sign-in does not force consent | test/auth/browser_login_test.dart | ordinary login url has no prompt or force_reconsent | red |
| provider-auth → Plan usage consent | Inference without plan usage | test/provider/chatgpt_adapter_test.dart | plan usage disabled fails not_permitted without a request | green |
| provider-auth → Plan usage consent | Plan usage dropped on refresh | test/auth/refresher_test.dart | refresh without direct scope is not_permitted, clears tokens, disables plan usage | green |
| provider-auth → Stale login rejected | Logout during a pending login | test/auth/browser_login_test.dart | logout committed during a pending login rejects the login | red |
| provider-auth → Stale login rejected | Account replaced during a pending login | test/auth/browser_login_test.dart | account replaced during a pending login keeps account b | red |
| provider-auth → Stale login rejected | Concurrent first sign-ins | test/auth/browser_login_test.dart | second of two first sign-ins stores nothing and revokes its token | red |
| provider-auth → Stale login rejected | Tokenless logout during a pending login | test/auth/browser_login_test.dart | host-only logout, host-only forget and disabled-registration logout each reject the pending login | red |
| provider-auth → Stale login rejected | Refresh during a pending login | test/auth/browser_login_test.dart | refresh during a pending login does not reject it | red |
| provider-auth → Loopback callback port | Primary port free | test/auth/browser_login_test.dart | free 1455 yields 127.0.0.1:1455 redirect | red |
| provider-auth → Loopback callback port | Port busy on a later sign-in | test/auth/browser_login_test.dart | busy 1455 with registration falls back to 1457 without contacting holder | red |
| provider-auth → Loopback callback port | Port busy on first sign-in | test/auth/browser_login_test.dart | busy 1455 without registration fails naming the port | red |
| provider-auth → Loopback callback port | Both ports busy | test/auth/browser_login_test.dart | both ports busy fails naming both | red |
| provider-auth → Authorize URL is always shown | Browser cannot open | test/auth/browser_login_test.dart | failing launcher still prints url and completes | red |
| provider-auth → Authorize URL is always shown | No-browser flag | test/auth/browser_login_test.dart | no-browser starts no launcher | red |
| provider-auth → Pasted redirect URL | Pasted redirect completes login | test/auth/browser_login_test.dart | pasted redirect url completes the login | red |
| provider-auth → Pasted redirect URL | Pasted URL for another address | test/auth/browser_login_test.dart | pasted url with another prefix is rejected and waiting continues | red |
| provider-auth → Login deadline and cancellation | Callback never arrives | test/auth/browser_login_test.dart | deadline expiry releases port and stores nothing | red |
| provider-auth → Login deadline and cancellation | User interrupts | test/auth/browser_login_test.dart | cancel while waiting stores nothing | red |
| provider-auth → Login deadline and cancellation | Interrupt during exchange or lock wait | test/auth/browser_login_test.dart | cancel during exchange, key fetch or lock wait never writes | red |
| provider-auth → Login deadline and cancellation | Interrupt during commit | test/auth/browser_login_test.dart | cancel during commit completes and reports success | red |
| provider-auth → Silent proactive refresh | Near-expiry refresh | test/auth/refresher_test.dart | token expiring within 5 minutes is refreshed first with form and resource | green |
| provider-auth → Silent proactive refresh | Refresh omits a token | test/auth/refresher_test.dart | omitted refresh token keeps the previous one | green |
| provider-auth → Silent proactive refresh | Transient refresh failure | test/auth/refresher_test.dart | unsent or 5xx refresh leaves credentials and is not reauth | green |
| provider-auth → Silent proactive refresh | Refresh response lost | test/auth/refresher_test.dart | sent refresh without response is rotation uncertain | green |
| provider-auth → Silent proactive refresh | Refresh after a lost response | test/auth/refresher_test.dart | reused after uncertain rotation is reauth with lost-rotation message | green |
| provider-auth → Credentials observed per request | Request after external logout | test/auth/refresher_test.dart | request after external logout fails reauth without backend call | green |
| provider-auth → Credentials observed per request | Request after account replacement | test/auth/refresher_test.dart | request after account replacement uses the new account | green |
| provider-auth → Credentials observed per request | Stream in progress during logout | test/provider/chatgpt_adapter_test.dart | logout during a stream lets it finish | green |
| provider-auth → Single-flight refresh | Parallel requests | test/auth/refresher_test.dart | five parallel callers share one refresh | green |
| provider-auth → Single-flight refresh | Shared refresh fails | test/auth/refresher_test.dart | shared failure reaches all waiters and is not cached | green |
| provider-auth → Refresh after unauthorized | Recovered 401 | test/provider/chatgpt_adapter_test.dart | 401 refreshes and repeats once | green |
| provider-auth → Refresh after unauthorized | Persistent 401 | test/provider/chatgpt_adapter_test.dart | second 401 is reauth_required and keeps tokens | green |
| provider-auth → Terminal refresh failure | Reused refresh token | test/auth/refresher_test.dart | refresh_token_reused is reauth, clears tokens and does not retry | green |
| provider-auth → Terminal refresh failure | Token replaced meanwhile | test/auth/refresher_test.dart | terminal failure keeps a token set stored meanwhile | green |
| provider-auth → Rejected client and other refresh errors | Client rejected | test/auth/refresher_test.dart | invalid_client is invalid_request naming logout --forget | green |
| provider-auth → Rejected client and other refresh errors | Unknown 400 | test/auth/refresher_test.dart | unknown 400 code is invalid_request | green |
| provider-auth → Logout revokes the session | Revocation confirmed | test/auth/logout_test.dart | logout posts revocation form and reports logged out | red |
| provider-auth → Logout revokes the session | Revocation not confirmed | test/auth/logout_test.dart | failed revocation still clears tokens and says not confirmed | red |
| provider-auth → Doctor report | Healthy subscription | test/cli/cli_test.dart | doctor prints account backend expiry models and exits zero | red |
| provider-auth → Doctor report | Not logged in | test/cli/cli_test.dart | doctor without tokens or a disabled registration reports not logged in and exits non-zero | red |
| provider-auth → Doctor report | Plan usage not enabled | test/cli/cli_test.dart | doctor with plan usage disabled names enable-plan-usage and exits non-zero | red |
| provider-auth → Doctor report | Empty model list | test/cli/cli_test.dart | doctor with no listed models reports no models available | red |

## 1. ADR, dependencies and fakes

- [x] 1.1 Write `docs/adr/0009-openai-subscription-credentials-and-protocol-authority.md` (`Status: accepted`, today's date, `Supersedes: none`). It covers design D6 and the protocol-authority rule from *Upstream sources compared*:
  - D6: record v1 and its location; the DPAPI file versus a Credential Manager split; the `0600` Unix file; fail-closed selection; the trusted home path; `auth.lock`;
  - the authority rule: OpenAI's Sign in with ChatGPT docs, read 2026-10-29; pi and OpenCode as corroboration at their pinned revisions; the Codex client route rejected, with the historical comparison table; the eligibility condition;
  - the record's `generation` and `plan_usage` fields, the `additional_tools` shape and its single-source evidence, and cross-user DPAPI isolation as a platform property rather than test evidence.

  In `openspec/architecture.md`, add the ADR's row to the index, replace "entry 2 splits the secret or uses a DPAPI-protected file" with the recorded choice, and add source-map rows for the docs pages and the two official implementations. Verify with `mise run openspec:validate`, and confirm the index lists 0009.
- [x] 1.2 Add dependencies with `dart pub add args ffi win32 pointycastle` and record the resolved versions. Create `lib/src/auth/openai_constants.dart` holding every constant from the design's comparison table, each with a comment citing its docs page or source revision and line. Verify with `mise run analyze`.
- [x] 1.3 Write `test/support/fake_openai.dart`, an `HttpServer` driven by per-test scripts:
  - **auth server:** discovery, JWKS from a per-run RSA key, authorize redirect with an issued client id, `/api/accounts/oauth/token` code and refresh grants, revocation;
  - **auth extras:** a scripted granted-scope set, recording of `prompt`/`force_reconsent` and of revocation requests;
  - **API:** `/v1/responses` SSE scripts (including `response.incomplete`), `/v1/models`, scripted error bodies (including `{"detail"}`), stalls between events, a stall after reading the body before headers, headers with no events, mid-stream drops, request recording, and an assertion that tools arrive only in a leading `additional_tools` item;
  - a helper that signs ID tokens with chosen claims.

  Verify with a smoke test, `test/support/fake_openai_test.dart`, that a scripted SSE response round-trips through `HttpClient`.

## 2. Failure text, PKCE and ID tokens

- [x] 2.1 Write the failing tests in `test/auth/failure_text_test.dart` (three rows) and confirm they fail because `FailureText` is missing.
- [x] 2.2 Implement `lib/src/auth/failure_text.dart` per design D12: templates, the code and parameter checks, the secret set, and dropping `message`/`detail`. Verify that `failure_text_test.dart` passes and flip its rows green.
- [x] 2.3 Implement `lib/src/auth/pkce.dart` (64-byte verifier, base64url, S256; 32-byte state and nonce) with a unit test asserting the lengths, the alphabet and the S256 vector from RFC 7636 Appendix B. Verify the test passes.
- [x] 2.4 Write the failing `test/auth/jwt_test.dart` (two rows, plus key selection by `kid` and the RS256-only rule). Then implement:
  - `lib/src/auth/jwt.dart`: decoding, RS256 verification through `pointycastle`, and the claim checks per D3b;
  - `lib/src/auth/oidc.dart`: discovery and key-set fetch, with 64 KiB bounds, 30 s timeouts, and the issuer and host checks.

  Verify the tests pass and flip the rows green.

## 3. Credential store

- [x] 3.1 Write the failing `test/auth/home_trust_test.dart` (six rows) against an injected `stat` seam, plus one real-FFI `[unix]` test asserting that FFI `st_mode` agrees with `FileStat.mode` on a temp dir.
- [x] 3.2 Implement `lib/src/auth/home_trust.dart` per design D6 *Trusted home path*:
  - canonicalization, the home-not-a-symlink check, and the ownership/mode/sticky rule;
  - FFI `stat`/`__xstat` and `geteuid` at per-ABI offsets, self-validated, failing closed on an unknown ABI.

  Verify on Linux via the WSL runner (`dart test test/auth/home_trust_test.dart`), and on Windows that the `[unix]` tests skip. Flip the rows green.
- [x] 3.3 Write the failing `test/auth/credential_store_test.dart` rows: Unix file, permissions, unsafe links, secure write unavailable, atomic replacement, interrupted write, and the two `[windows]` DPAPI rows.
- [x] 3.4 Implement `lib/src/auth/credential_store.dart` (record v1 with `host_id`, `registration`, `tokens`) and its two backends:
  - `posix_file_backend.dart`: FFI `open` with `O_CREAT|O_EXCL` and mode 0600, `chmod` 0700, temp, fsync, rename;
  - `dpapi_backend.dart`: `CryptProtectData`/`CryptUnprotectData`, `CRYPTPROTECT_UI_FORBIDDEN`, entropy `kehai-openai-v1`, `LocalFree`.

  Run `credential_store_test.dart` on native Windows and on the WSL runner. Prove that `File.rename` replaces an existing file on Windows; if it does not, switch to `MoveFileExW` per D6. Flip the rows green.
- [x] 3.5 Implement the `auth.lock` acquisition (100 ms polls, 30 s deadline, cancellation check) in `credential_store.dart`, with a unit test for the lock-busy failure. Verify that test passes.

## 4. OAuth client and refresher

- [x] 4.1 Write the failing `test/auth/refresher_test.dart` rows against `fake_openai`:
  - near-expiry refresh, omitted token, transient, lost response, after lost response, and that a refresh leaves `generation` unchanged;
  - external logout, account replacement;
  - parallel and shared-failure refreshes;
  - reused token, plan usage dropped, token replaced meanwhile, client rejected, unknown 400.
- [x] 4.2 Implement `lib/src/auth/oauth_client.dart`:
  - form code exchange, refresh with `resource` and no scope, and revocation, per D2, D4 and D6a;
  - required response fields;
  - 64 KiB body bounds and 30 s timeouts;
  - `sent`/`rotationUncertain` classification;
  - the terminal codes and `invalid_client`.
- [x] 4.3 Implement `lib/src/auth/refresher.dart` per D4 and D5:
  - the per-request load;
  - the 5-minute due rule;
  - single-flight with `whenComplete` clearing;
  - lock plus reload, and the rotation merge;
  - the scope check, marking `plan_usage: "disabled"` when the scope disappears;
  - clearing on a terminal outcome only when the refresh token is unchanged.

  Verify that `refresher_test.dart` passes and flip its rows green.
- [x] 4.4 Write `test/auth/refresher_process_test.dart`, which spawns two Dart processes (fixtures under `test/fixtures/`) against one fake server and one home. Then make it pass: one refresh for two processes, and a killed holder that does not block the next. Run it on Windows and the WSL runner, and flip both rows green.

## 5. Login and logout

- [x] 5.1 Write the failing `test/auth/browser_login_test.dart` rows:
  - A fake browser launcher follows the authorize URL to the fake auth server, which redirects to the callback with an issued client id.
  - The paste path feeds lines through an injected stdin stream.
  - Deadlines and the cancel token are injected, with short durations.
  - Busy ports are held by test sockets.
  - Stale-login cases commit a logout, `--forget` or second login into the same home while the first login waits, then release its callback.
- [ ] 5.2 Implement `lib/src/auth/login_controller.dart` (cancel token, commit point per D3) and `lib/src/auth/browser_login.dart` per D3:
  - host id creation, and the start snapshot of `generation` and registration;
  - registration-aware authorize parameters, and `--enable-plan-usage` (`prompt=consent`, saved client required);
  - binding 1455, then 1457 only with a registration;
  - printing the URL once (the only output carrying `state`/`nonce`) and the launcher (`rundll32`, `open`, `xdg-open`, with an environment stripped of secrets);
  - the paste reader;
  - the callback order: state, error, client id, code;
  - exchange, verification (D3b), the subject check, and the plan-usage state;
  - the commit check under the lock (reload, compare, advance `generation`), and best-effort revocation of a discarded refresh token;
  - static pages, `close(force: true)`, and the 10-minute deadline.

  Verify that `browser_login_test.dart` passes on Windows and the WSL runner, and flip its rows green.
- [ ] 5.3 Write the failing `test/auth/logout_test.dart` rows, then implement logout per D6a: discovery, the revocation form, clearing in `finally`, advancing `generation` (also with no token set, for host-only and tokenless-registration records), and `--forget` with or without a token set. Verify the tests pass and flip the rows green.

## 6. Provider interface and ChatGPT plan adapter

- [x] 6.1 Write `lib/src/provider/provider.dart` per D10: `ModelProvider`, `ModelRequest`, the sealed `ProviderEvent` types, `ProviderFailure` (with `not_permitted` and `param`), `CancelToken`, `ModelInfo` and `TokenEstimate`. Add `estimate.dart`, with `test/provider/estimate_test.dart` written first; make it pass and flip its row green.
- [x] 6.2 Write the failing `test/provider/sse_test.dart`: the oversized-event row, plus framing cases (multi-line `data:`, comments, CRLF, split chunks). Implement `lib/src/provider/sse.dart` with the 8 MiB event bound. Verify it passes and flip the row green.
- [x] 6.3 Write the failing `test/provider/chatgpt_adapter_test.dart` rows against `fake_openai`.
- [x] 6.4 Implement `lib/src/provider/chatgpt_adapter.dart` per D7, D10 and D12:
  - request mapping from the body-key allowlist (no top-level `tools`; one leading `additional_tools` item), headers, and the 1 MiB cap;
  - the event mapping, `response.incomplete` → `Failed(incomplete)`, and the code-then-status error mapping;
  - held tool calls (8 MiB, 128 calls) emitted only on `response.completed`, opaque reasoning passthrough, usage mapping;
  - `not_permitted` without a request when plan usage is disabled;
  - one 401 refresh-and-repeat;
  - both cancellation paths;
  - the 300 s response-silence deadline (from body flushed; restarted on headers and each event; stopped while paused) and the 30 s connect timeout.

  Verify that `chatgpt_adapter_test.dart` passes and flip its rows green.
- [x] 6.5 Write the failing `test/provider/models_test.dart`, then implement `listModels` (`/v1/models`, `visibility == "list"`, `supported_in_api`, 4 MiB read bound). Verify it passes and flip its rows green.
- [ ] 6.6 Export the provider interface and the auth entry points from `lib/kehai.dart`, and add API doc comments per the dart-write-documentation skill. Verify with `mise run analyze`.

## 7. CLI

- [ ] 7.1 Write the failing `test/cli/cli_test.dart`. It runs `dart run bin/kehai.dart` as a process with `KEHAI_HOME` set to a temp dir, and the loopback-only `KEHAI_OPENAI_ISSUER`/`KEHAI_OPENAI_API_BASE` pointing at `fake_openai`. Include a test that a non-loopback override is rejected with exit 64.
- [ ] 7.2 Implement `bin/kehai.dart` and `lib/src/cli/` per D1:
  - `CommandRunner` with `login openai [--no-browser] [--enable-plan-usage]`, `logout openai [--forget]` and `doctor`;
  - exit codes 0, 1 and 64;
  - doctor sections: backend and path, login state and plan-usage state, account (email, subject, plan when known), expiry, refresh result, and models capped at 200 lines with a count;
  - loopback-only overrides.

  Verify that `cli_test.dart` passes on Windows and the WSL runner, and flip its rows green.

## 8. Integration and acceptance

- [ ] 8.1 Run `mise run check` on native Windows and on the WSL Linux runner (copy to ext4, low concurrency, clean up afterwards). Run `mise run openspec:validate` and `mise run secrets`. All must pass. Record the test counts per platform.
- [ ] 8.2 Add `tool/provider_smoke.dart`, which runs a real tool round trip through `ChatGptAdapter` and prints the normalized events, with no token output. Turn 1 sends one trivial tool (`echo`, one string parameter) and instructions to call it; it must end with a `ToolCall` and `Completed(tool_use)`. Turn 2 sends the call and its output by `call_id` and must end with text and `Completed(end_turn)`. Any other outcome exits non-zero, naming it. Ask the user to run the acceptance check on native Windows, and on Linux if available:
  1. `kehai login openai` (browser, allowing ChatGPT plan usage), then `kehai doctor` showing the account and the model list;
  2. `dart run tool/provider_smoke.dart`, completing both turns: an actual tool call, then a text answer, each with usage;
  3. a second `kehai doctor` after forcing expiry (edit `expires_at` back), proving a silent refresh;
  4. `kehai logout openai`, reporting confirmed revocation, then `kehai login openai --no-browser` completed by pasting the redirect URL, proving the reused client and the paste path.

  Record each result as the user reports it: user-verified, and never marked passed on the user's behalf.

## Workflow follow-up

- Pre-ship review, PR and merge follow `specwright-commit` and `specwright-pr` once all tasks are done.
- The M1 exit criterion for subscription login is marked passed only by the user's reported results in 8.2, at milestone close.
