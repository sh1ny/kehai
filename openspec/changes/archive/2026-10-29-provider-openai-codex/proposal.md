# Proposal

## Why

Kehai cannot talk to a model yet, and M1 requires a ChatGPT subscription, not an API key ([ADR 0006](../../../docs/adr/0006-subscription-auth-workflow-and-process-boundaries.md)). OpenAI now offers an official route for this: **Sign in with ChatGPT token sharing** lets open-source and locally hosted apps use a user's ChatGPT plan through the public Responses API, without approval. Kehai, an open-source local engine, qualifies.

The Codex-era references that ADR 0006 named instead reuse the Codex CLI's OAuth client and call `chatgpt.com/backend-api/codex`. That route is unsanctioned for third parties, and OpenAI's docs say not to point apps at `backend-api`. This change adopts the official flow and records that choice.

The program is a preview and can change, so login, credential storage, refresh and the request rules are pinned to OpenAI's published docs and fail visibly. That has to hold before the agent loop (change 4) is built on them.

This is change 2 of 6 in milestone **M1 — self-hosting skeleton** ([roadmap](../../roadmap.md)). It delivers the exit criterion *"`kehai login openai` completes subscription OAuth **without an API key**, stores/refreshes tokens silently using the OS keychain or `~/.kehai/auth.json` with Unix `0600` (Windows: secure keychain), and `kehai doctor` shows account and model list"*. That criterion is user-verified. The change also gives change 4 the normalized provider interface its loop consumes.

## What Changes

- **`kehai` CLI entrypoint** (`bin/kehai.dart`). It is the first executable and has three commands:
  - `kehai login openai [--no-browser] [--enable-plan-usage]`;
  - `kehai logout openai [--forget]`;
  - `kehai doctor`.

  `kehai rpc` and the line client remain change 4.
- **Sign in with ChatGPT, as OpenAI documents it for native and CLI apps:**
  - **Flow:** authorization code with PKCE (S256), `state` and `nonce`, against `auth.openai.com`, through a loopback callback on `127.0.0.1:1455`.
  - **Registration:** the first sign-in registers a user-owned client (`dynamic_agent_client`, agent name `Kehai`, a stable per-machine host id). Kehai saves the issued `client_id` and reuses it on later sign-ins.
  - **Grant:** scopes `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, with resource `https://api.openai.com/v1`. A sign-in whose grant lacks `chatgpt.tokens.use.direct` keeps the verified registration with plan usage disabled and runs no inference. `--enable-plan-usage` asks for consent again with the saved client, as OpenAI's recovery guidance directs.
  - **Verification:** the ID token is verified against OpenAI's published signing keys (issuer, audience, expiry, nonce), and its `sub` is the account identity.
  - **Concurrent changes:** a login commits only if no other login, logout or `--forget` committed while it waited, so a stale login never undoes a newer one.
  - **Headless use:** the authorize URL is always printed. When the browser cannot reach the callback (SSH, another machine), the user pastes the final redirect URL. There is no device-code flow; OpenAI does not document one for token sharing.
  - **No API key** is requested, exchanged or stored.
- **Secure credential storage**, outside the session tree and failing closed:
  - **Windows:** a DPAPI-protected file (current-user scope), chosen instead of splitting the record across Credential Manager entries, which are capped at about 2.5 KB.
  - **Linux and macOS:** `~/.kehai/auth.json`, created with mode `0600` in a `0700` home on a trusted path. It is refused if group or other permission bits are set.
  - If no permitted secure backend is available, nothing is written.
  - The record holds the host id, the client registration (with its plan-usage state) and the token set.
- **Silent refresh:**
  - **Triggers:** before the one-hour access token expires, and once after a `401`.
  - **Concurrency:** refreshes are single-flight across concurrent callers and Kehai processes, as OpenAI requires, because refresh tokens rotate. The replacement refresh token is persisted.
  - **Terminal failure:** an unusable refresh token clears the stored tokens and produces a sanitized "run `kehai login openai`" error.
- **Logout:**
  - It revokes the refresh token at OpenAI's revocation endpoint and clears the local tokens.
  - It keeps the client registration and host id, as the docs direct.
  - `--forget` also removes the registration, so a different ChatGPT account can sign in. It works after an ordinary logout too.
- **Normalized provider interface:**
  - **Events:** streaming text and reasoning-summary deltas, complete tool calls, and opaque reasoning items passed back between turns.
  - **Accounting:** usage (input, cached, output and reasoning tokens), stop reason, and a conservative token estimate where no exact count exists.
  - **Failures:** typed and sanitized (reauth required, usage limit, rate limited, not permitted, context overflow, invalid request, server, network, idle timeout, cancelled, incomplete, protocol).
  - **Tool calls** are delivered only with a successfully completed response, so an incomplete or failed turn never authorizes a tool run.
  - **Deadlines:** one response-silence deadline covers the wait for headers, the first event and every later event.
- **ChatGPT plan adapter.** It implements that interface against `https://api.openai.com/v1`: `/responses` over SSE and `/models`.
  - **Request rules:** the token-sharing rules from the docs (`store: false`, `stream: true`, full history in `input`, top-level `instructions`, function tools supplied through an `additional_tools` input item, and the forbidden fields omitted).
  - **Safety:** the adapter never retries a request that may have been admitted, and never journals or logs a credential.
- **`kehai doctor`:** shows the credential backend and location, the account (email, subject, plan when known), token expiry, refresh health and the available model list. It exits non-zero, with a sanitized reason, when any of these is unavailable.
- **API-key fallback: none in M1.** The plan token and an API key reach the same `/v1/responses` endpoint, but API-key use still needs its own key storage, entry flow, error mapping and model rules, and cannot count toward subscription acceptance. It moves to M2. `OPENAI_API_KEY` is ignored.

Out of scope:
- **Change 3:** tools and the job supervisor.
- **Change 4:** the agent loop, retry/backoff policy, journaling provider turns and usage, and the RPC/line client. This change defines the values change 4 will journal but writes nothing to a session.
- **M2+:**
  - a pricing or model registry;
  - Anthropic OAuth;
  - the Responses WebSocket transport;
  - request compression;
  - several saved ChatGPT accounts at once;
  - the Codex app-server integration route.
- **Not built:** macOS Keychain and Linux Secret Service backends. The file backend already satisfies the strategy on Unix.

## Capabilities

### New Capabilities
- `credential-store`: platform-secure, external storage of the provider record (Windows DPAPI file, Unix `0600` file on a trusted home path), fail-closed backend selection, atomic replacement, cross-process locking, and the guarantee that credentials never reach the session tree, results or logs.
- `provider-auth`: Sign in with ChatGPT (dynamic client registration, browser loopback with paste fallback, ID-token verification, plan-usage state and consent recovery, stale-login rejection), silent single-flight refresh with rotation, terminal-failure reauth errors, revoking logout, and the `kehai doctor` account and model report.
- `model-provider`: the normalized streaming model interface (events, tool calls, usage, stop reasons, token estimate, typed sanitized failures, cancellation and response-silence deadline) and its ChatGPT plan adapter on the Responses API, including model listing.

### Modified Capabilities
None. `session-tree`, `session-journal` and `result-store` are unchanged; provider turns are journaled in change 4.

## Impact

- **Code:**
  - new `bin/kehai.dart`;
  - `lib/src/auth/` (sign-in, ID-token verification, refresh, revocation, credential backends);
  - `lib/src/provider/` (interface, SSE parsing, ChatGPT plan adapter);
  - `lib/src/cli/` (command wiring and doctor);
  - tests under `test/auth/`, `test/provider/` and `test/cli/`, using local fake OAuth and Responses servers.
- **Dependencies:**
  - `args` for the CLI.
  - `win32` and `ffi` for DPAPI on Windows, and for libc `open` (mode `0600`), `chmod`, `stat` and `geteuid` on Unix. Both reach only system libraries; no native assets are bundled.
  - `pointycastle` (pure Dart) for RS256 ID-token signature verification, which `dart:io` and `crypto` lack.
  - No HTTP package: `dart:io` `HttpClient` and `HttpServer` suffice.
- **External services:**
  - `auth.openai.com`: authorize, token, revocation, discovery and signing keys;
  - `api.openai.com/v1`: responses and models.

  Both are official, but the token-sharing program is a preview. design.md records its limits, the breakage signals and the reversal cost.
- **On-disk:** a new credential file format, version 1, under `~/.kehai/` (Windows: DPAPI-protected). It is not session state, and the user can delete it.
- **ADR:** a new ADR records the credential storage format and backends, and that OpenAI's Sign in with ChatGPT documentation is the authority for the auth and request protocol, rejecting the Codex client route.
