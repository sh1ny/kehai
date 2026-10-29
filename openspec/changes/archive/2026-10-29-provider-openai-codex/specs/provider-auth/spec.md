# Spec Delta

## Purpose

Signs the user in with their ChatGPT plan through OpenAI's official Sign in with ChatGPT token-sharing flow, without an API key. Keeps that sign-in valid through silent refresh, and reports account and model availability, failing visibly when the service or credentials stop working.

## ADDED Requirements

### Requirement: Sign in with ChatGPT
`kehai login openai` SHALL run OpenAI's documented native-app authorization-code flow: PKCE `S256`, a fresh `state` and `nonce`, scopes `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, resource `https://api.openai.com/v1` and the host id as `ext_agent_host_id`. It exchanges the callback's code for id, access and refresh tokens, verifies and stores them, and prints the account. It SHALL NOT request or store an API key.

#### Scenario: Successful login
- **WHEN** the user runs `kehai login openai` and approves sign-in, and the auth server redirects to the callback with a valid `code`, the matching `state` and an issued client id
- **THEN** the command stores the registration and the token set, prints the account email, and exits zero

#### Scenario: State mismatch
- **WHEN** the callback receives a request whose `state` differs from the one sent
- **THEN** no token exchange is attempted, the browser page reports the failure, and the command exits non-zero with `login failed: state mismatch`

#### Scenario: Authorization denied
- **WHEN** the callback carries the matching `state` and an `error` parameter, such as `access_denied`
- **THEN** no code is exchanged, the command exits non-zero naming that error code, and nothing is stored

#### Scenario: Code rejected
- **WHEN** the token endpoint rejects the code exchange with `invalid_grant`
- **THEN** the code is discarded, nothing is stored, and the command exits non-zero telling the user to run `kehai login openai` again

#### Scenario: No API key requested
- **WHEN** a login completes
- **THEN** no request to the auth server asks for an API key, and the stored record contains no API key field

### Requirement: Dynamic client registration
Kehai SHALL create a host id (`urn:uuid:` with a random UUIDv4) before the first sign-in and keep it across logins and logouts. Without a stored registration, the request SHALL use client id `dynamic_agent_client` and agent name hint `Kehai`, and the callback SHALL carry an issued client id, saved as the registration and used for the exchange. With one, the request SHALL use its client id without a name hint, and a callback naming a different client id SHALL be rejected.

#### Scenario: First sign-in registers a client
- **WHEN** no registration is stored and the callback carries `client_id=oaiapp_abc`
- **THEN** the authorize URL used `client_id=dynamic_agent_client` with `agent_name_hint=Kehai`, the code exchange uses `oaiapp_abc`, and the stored registration holds `oaiapp_abc`

#### Scenario: Registration incomplete
- **WHEN** no registration is stored and the callback carries a code but no client id
- **THEN** no code is exchanged, nothing is stored, and the command exits non-zero with `login failed: registration incomplete`

#### Scenario: Later sign-in reuses the client
- **WHEN** a registration with `oaiapp_abc` is stored and the user logs in again
- **THEN** the authorize URL uses `client_id=oaiapp_abc` without `agent_name_hint`, and a callback that omits the client id is exchanged with `oaiapp_abc`

#### Scenario: Different client returned
- **WHEN** a registration with `oaiapp_abc` is stored and the callback carries `client_id=oaiapp_xyz`
- **THEN** no code is exchanged, nothing is stored, and the command exits non-zero

#### Scenario: Host id is stable
- **WHEN** the user logs in, logs out with `--forget`, and logs in again
- **THEN** both authorize URLs carry the same `ext_agent_host_id`

### Requirement: Token verification and plan-usage grant
Before storing anything from a login, Kehai SHALL verify the ID token: an RS256 signature under a key from the issuer's published key set, the issuer, an audience that includes the issued client id, expiry, the sent `nonce`, and a non-empty `sub`. `sub` is the account identity and email is display-only. With a stored registration, the verified `sub` SHALL equal its subject. The granted scopes decide the plan-usage state (*Plan usage consent*).

#### Scenario: Verified login
- **WHEN** the token response carries an ID token signed by a published key with the expected issuer, audience, nonce and a subject, and the scopes include `chatgpt.tokens.use.direct`
- **THEN** the stored registration carries that subject and email

#### Scenario: Invalid ID token
- **WHEN** the ID token's signature, issuer, audience, expiry or nonce fails verification, or its algorithm is not RS256
- **THEN** nothing is stored, and the command exits non-zero with `login failed: invalid ID token` naming the failed check

#### Scenario: Different account
- **WHEN** a registration for subject `A` is stored and the verified ID token's subject is `B`
- **THEN** nothing is stored, and the command exits non-zero naming `kehai logout openai --forget` as the way to switch accounts

### Requirement: Plan usage consent
A verified sign-in whose granted scopes lack `chatgpt.tokens.use.direct` SHALL store the registration marked plan usage disabled, store no token set, and send no model request. `kehai login openai --enable-plan-usage` SHALL re-run sign-in with the saved client id, the full scope set and `prompt=consent`. An ordinary sign-in SHALL NOT request consent. A refresh that loses the scope SHALL clear the token set and mark plan usage disabled.

#### Scenario: Plan usage not granted
- **WHEN** a verified sign-in's granted scopes lack `chatgpt.tokens.use.direct`
- **THEN** the registration is stored marked plan usage disabled, no token set is stored, and the command exits non-zero saying ChatGPT plan usage was not allowed and naming `kehai login openai --enable-plan-usage`

#### Scenario: Enable plan usage
- **WHEN** the registration is marked plan usage disabled, the user runs `kehai login openai --enable-plan-usage`, and the grant now includes `chatgpt.tokens.use.direct`
- **THEN** the authorize URL carried the saved client id, the full scope set and `prompt=consent`, the token set is stored, and the registration is marked plan usage enabled

#### Scenario: Consent declined again
- **WHEN** an `--enable-plan-usage` sign-in's grant still lacks `chatgpt.tokens.use.direct`
- **THEN** no token set is stored, the registration stays marked plan usage disabled, and the command exits non-zero

#### Scenario: Enable without a registration
- **WHEN** the user runs `kehai login openai --enable-plan-usage` and no registration is stored
- **THEN** no listener is bound, nothing is stored, and the command exits non-zero naming `kehai login openai`

#### Scenario: Ordinary sign-in does not force consent
- **WHEN** the user runs `kehai login openai` without `--enable-plan-usage`
- **THEN** the authorize URL carries no `prompt` and no `force_reconsent` parameter

#### Scenario: Inference without plan usage
- **WHEN** the registration is marked plan usage disabled and a model request is made
- **THEN** no backend request is sent, and the request fails with `not permitted` naming `kehai login openai --enable-plan-usage`

#### Scenario: Plan usage dropped on refresh
- **WHEN** a refresh succeeds but its scope set lacks `chatgpt.tokens.use.direct`
- **THEN** the failure is `not permitted`, its message says ChatGPT plan usage is no longer granted and names `kehai login openai --enable-plan-usage`, the token set is cleared, and the registration is marked plan usage disabled

### Requirement: Stale login rejected
Login, logout and `--forget` SHALL each advance a stored credential generation when they commit; a refresh SHALL NOT. A login SHALL record the generation and registration when it starts. At commit, under the credential lock, it SHALL reload the record; if either changed, it SHALL store nothing, best-effort revoke the refresh token it obtained, and exit non-zero saying another login or logout happened meanwhile.

#### Scenario: Logout during a pending login
- **WHEN** login A waits for the browser, another process runs `kehai logout openai`, and login A's callback then arrives
- **THEN** login A stores nothing, the record still holds no token set, and login A exits non-zero naming `kehai login openai`

#### Scenario: Account replaced during a pending login
- **WHEN** login A waits for the browser, and another process runs `kehai logout openai --forget` and then signs in as account B
- **THEN** login A stores nothing, the record keeps account B's registration and token set, and login A exits non-zero

#### Scenario: Concurrent first sign-ins
- **WHEN** two logins start with no registration stored, and both receive issued client ids
- **THEN** the first to commit stores its registration, and the second stores nothing, sends a revocation for its refresh token, and exits non-zero telling the user to run `kehai login openai` again

#### Scenario: Tokenless logout during a pending login
- **WHEN** a login waits for the browser while the record holds no token set (only the host id, or a registration marked plan usage disabled), and another process runs `kehai logout openai` or `kehai logout openai --forget`
- **THEN** the waiting login stores nothing when its callback arrives and exits non-zero naming `kehai login openai`

#### Scenario: Refresh during a pending login
- **WHEN** another process refreshes the stored token set while a login waits for the browser
- **THEN** the login commits normally

### Requirement: Loopback callback port
The callback SHALL listen only on `127.0.0.1`, with path `/auth/callback`, on port `1455`. The `redirect_uri` sent always names the port actually bound, and the same URI is used in the code exchange. Kehai SHALL NOT signal or stop other processes holding those ports.

When a registration is stored and `1455` is busy, Kehai uses port `1457` (OpenAI permits only the port to vary, and only on later sign-ins). When no registration is stored and `1455` is busy, the login fails.

#### Scenario: Primary port free
- **WHEN** port `1455` is free
- **THEN** the authorize URL's `redirect_uri` is `http://127.0.0.1:1455/auth/callback`

#### Scenario: Port busy on a later sign-in
- **WHEN** a registration is stored, another process holds port `1455` and `1457` is free
- **THEN** the callback binds `1457`, the `redirect_uri` is `http://127.0.0.1:1457/auth/callback`, and the other process receives no request from Kehai

#### Scenario: Port busy on first sign-in
- **WHEN** no registration is stored and another process holds port `1455`
- **THEN** the command exits non-zero with a message that names port `1455` and says another login (for example the Codex CLI) may be holding it

#### Scenario: Both ports busy
- **WHEN** a registration is stored and both `1455` and `1457` are held by other processes
- **THEN** the command exits non-zero with a message that names both ports

### Requirement: Authorize URL is always shown
The login SHALL print the full authorize URL once, before waiting for the callback, and SHALL try to open the system browser with it unless `--no-browser` is given. This is the only output allowed to carry `state` and `nonce` (credential-store *Credentials never leave the boundary*). A browser that fails to open SHALL NOT fail the login.

#### Scenario: Browser cannot open
- **WHEN** the system browser command fails or is missing
- **THEN** the URL is still printed, the command keeps waiting for the callback, and a sign-in completed from that URL succeeds

#### Scenario: No-browser flag
- **WHEN** the user runs `kehai login openai --no-browser`
- **THEN** no browser process is started, and the authorize URL is printed

### Requirement: Pasted redirect URL
While the login waits, and standard input is a terminal, Kehai SHALL accept the final redirect URL pasted by the user, for when the browser runs on another machine. A pasted URL is accepted only if its scheme, host, port and path equal the `redirect_uri` sent. Its parameters are then handled exactly like a callback request. Whichever arrives first, callback or paste, is used, and the other is ignored.

#### Scenario: Pasted redirect completes login
- **WHEN** the user pastes `http://127.0.0.1:1455/auth/callback?code=…&state=…&client_id=…` with the matching state
- **THEN** the login completes as if the callback had been received

#### Scenario: Pasted URL for another address
- **WHEN** the user pastes a URL whose host, port or path differs from the `redirect_uri`
- **THEN** it is rejected with a message naming the expected prefix, nothing is exchanged, and the login keeps waiting

### Requirement: Login deadline and cancellation
A login SHALL wait at most 10 minutes for the callback or a pasted URL. The atomic credential replacement is the login's only commit point.
- **Before the commit starts:** a timeout, Ctrl-C or failure aborts every pending step (key fetch, exchange, lock wait) and stores nothing.
- **Once the commit starts:** cancellation is deferred until it finishes, and the login reports success.

The listener is closed, including idle connections the browser opened, on every exit.

#### Scenario: Callback never arrives
- **WHEN** no callback or pasted URL arrives within 10 minutes
- **THEN** the command exits non-zero with `login timed out`, the callback port is released, and existing stored credentials are unchanged

#### Scenario: User interrupts
- **WHEN** the user presses Ctrl-C while the login waits
- **THEN** the listener closes, nothing is stored, and the command exits non-zero

#### Scenario: Interrupt during exchange or lock wait
- **WHEN** Ctrl-C arrives after the callback was accepted, while the token exchange, the key fetch or the credential lock is pending
- **THEN** the pending request is aborted or its result discarded, no credential file is written at any later time, prior credentials are unchanged, and the command exits non-zero

#### Scenario: Interrupt during commit
- **WHEN** Ctrl-C arrives after the atomic replacement has started
- **THEN** the replacement completes, and the command prints the signed-in account and exits zero

### Requirement: Silent proactive refresh
Before credentials are used, Kehai SHALL refresh them without prompting when the access token expires within 5 minutes. The refresh sends grant `refresh_token` with the stored refresh token, the registration's client id and resource `https://api.openai.com/v1`, and no scope. It SHALL replace the access token, expiry, scopes and refresh token together, keeping a stored value only for a field the response omits.

#### Scenario: Near-expiry refresh
- **WHEN** a request needs credentials and the access token expires in 2 minutes
- **THEN** one refresh request is sent first, the new access token and the replacement refresh token are stored, and the request uses the new access token

#### Scenario: Refresh omits a token
- **WHEN** the refresh response contains a new access token but no refresh token
- **THEN** the stored refresh token stays the previous one

#### Scenario: Transient refresh failure
- **WHEN** the refresh request cannot be sent (connection refused, DNS failure), or the token endpoint returns `5xx`
- **THEN** stored credentials are unchanged, and the caller gets a `network` or `server` failure that is not marked `reauth required`

#### Scenario: Refresh response lost
- **WHEN** the refresh request was sent but the connection failed before a response arrived
- **THEN** stored credentials are unchanged, the caller gets a `network` failure marked `rotation uncertain`, and Kehai sends no other refresh within that call

#### Scenario: Refresh after a lost response
- **WHEN** a later refresh, after a `rotation uncertain` failure, is rejected with `refresh_token_reused`
- **THEN** the failure is `reauth required`, and its message says an earlier refresh may have rotated the token and names `kehai login openai`

### Requirement: Credentials observed per request
Before each new model or models request, Kehai SHALL load the stored record, then decide whether to refresh.
- No token set: discard cached credentials and fail without a backend request, with `not permitted` naming `--enable-plan-usage` if plan usage is disabled, else `reauth required`.
- A replaced record supersedes the cached account and tokens.
- A stream already started finishes with the token it began with.

#### Scenario: Request after external logout
- **WHEN** a running Kehai process holds fresh cached credentials, another process runs `kehai logout openai`, and the first process then starts a new request
- **THEN** no backend request is sent, and the new request fails with `reauth required` naming `kehai login openai`

#### Scenario: Request after account replacement
- **WHEN** a running process last used account A, and another process runs `kehai logout openai --forget` and then `kehai login openai` as account B
- **THEN** the first process's next request carries account B's access token

#### Scenario: Stream in progress during logout
- **WHEN** a logout happens while a stream started earlier is still receiving events
- **THEN** that stream continues to its terminal event, and only the next request observes the logout

### Requirement: Single-flight refresh
Concurrent callers in one process that need a refresh SHALL share one refresh request. After acquiring the credential lock, a refresher SHALL reload the stored record. If another refresher already replaced the token, it SHALL use that token and send no refresh.

#### Scenario: Parallel requests
- **WHEN** five model requests start at once with an expired access token
- **THEN** exactly one refresh request is sent, and all five use the same new access token

#### Scenario: Shared refresh fails
- **WHEN** five callers share one refresh and that refresh fails with a `server` failure
- **THEN** exactly one refresh request was sent, all five callers receive that same failure, and a sixth caller arriving afterwards starts a new refresh request

### Requirement: Refresh after unauthorized
When a model or models request returns `401`, Kehai SHALL refresh once, then repeat that request once. A request rejected with `401` was not admitted, so repeating it is safe. A second `401` SHALL surface as `reauth required`. It SHALL NOT clear stored tokens, since a `401` alone does not confirm revocation.

#### Scenario: Recovered 401
- **WHEN** a request returns `401` and the following refresh succeeds
- **THEN** the request is sent again once with the new access token, and its response is returned

#### Scenario: Persistent 401
- **WHEN** the repeated request also returns `401`
- **THEN** no further refresh or retry happens, the failure is `reauth required`, and the stored token set is unchanged

### Requirement: Terminal refresh failure
A refresh answered with `401`, or with `400` and code `invalid_grant`, `invalid_refresh_token`, `token_expired`, `refresh_token_expired`, `refresh_token_invalidated` or `refresh_token_reused`, SHALL produce a `reauth required` failure whose message says why and names `kehai login openai`. Under the lock, Kehai SHALL clear the token set if it still holds the rejected refresh token, keeping the registration and host id. It SHALL NOT retry automatically.

#### Scenario: Reused refresh token
- **WHEN** the token endpoint rejects a refresh with code `refresh_token_reused`
- **THEN** the failure is `reauth required`, its message says the refresh token was already used and names `kehai login openai`, the stored token set is cleared, and no second refresh is attempted

#### Scenario: Token replaced meanwhile
- **WHEN** a refresh is rejected as terminal, but another process stored a new token set before the lock was retaken
- **THEN** the new token set is kept, and the caller's next request uses it

### Requirement: Rejected client and other refresh errors
A refresh rejected with `invalid_client` SHALL produce an `invalid request` failure telling the user to run `kehai logout openai --forget` and log in again. Any other `400` SHALL produce an `invalid request` failure carrying its code. Neither is marked `reauth required`, clears tokens, or is retried.

#### Scenario: Client rejected
- **WHEN** a refresh is rejected with `invalid_client`
- **THEN** the failure is `invalid request`, names `kehai logout openai --forget`, and is not marked `reauth required`

#### Scenario: Unknown 400
- **WHEN** a refresh returns `400` with an unrecognized code
- **THEN** the failure is `invalid request`, includes that code, and is not marked `reauth required`

### Requirement: Logout revokes the session
With a token set stored, `kehai logout openai` SHALL revoke the refresh token with a form `POST` to the issuer's discovered revocation endpoint (token, `token_type_hint=refresh_token`, the registration's client id), then clear it locally. Only an empty `200` confirms revocation; otherwise the tokens are still cleared and the command says revocation was not confirmed, pointing to ChatGPT settings. Both exit zero. With no token set, nothing is revoked.

#### Scenario: Revocation confirmed
- **WHEN** the revocation endpoint answers `200`
- **THEN** the command prints that the user is logged out, and the stored token set is cleared

#### Scenario: Revocation not confirmed
- **WHEN** the revocation request fails with a network error or a non-`200` status
- **THEN** the stored token set is still cleared, the command says remote revocation was not confirmed and points to ChatGPT settings, and it exits zero

### Requirement: Doctor report
`kehai doctor` SHALL report:
- the credential backend and file path;
- whether the user is logged in, and whether ChatGPT plan usage is enabled;
- the account email and subject, and the plan when the ID token carries one;
- the access-token expiry;
- whether a refresh, if one was needed, succeeded;
- the models the account can use.

It SHALL exit zero only when credentials load, are valid or refresh successfully, and the model list is non-empty.

#### Scenario: Healthy subscription
- **WHEN** the user is logged in and the models endpoint lists models
- **THEN** doctor prints the account email, the backend, the expiry and each model's id, and exits zero

#### Scenario: Not logged in
- **WHEN** no token set is stored and the registration, if any, is not marked plan usage disabled
- **THEN** doctor prints `not logged in`, suggests `kehai login openai`, and exits non-zero

#### Scenario: Plan usage not enabled
- **WHEN** the registration is marked plan usage disabled
- **THEN** doctor prints `ChatGPT plan usage not enabled`, names `kehai login openai --enable-plan-usage`, lists no models, and exits non-zero

#### Scenario: Empty model list
- **WHEN** the models endpoint returns no listed models
- **THEN** doctor reports `no models available` for this account and exits non-zero
