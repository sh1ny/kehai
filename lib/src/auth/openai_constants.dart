/// Constants for the OpenAI "Sign in with ChatGPT" token-sharing flow.
///
/// Each constant cites its source. `docs` pages are the OpenAI developer pages
/// named in design.md "Upstream sources compared" (overview, `sign-in`,
/// `sessions`, `inference`, `limits`, `tokens`, `errors`), read on 2026-10-29.
/// `pi@c466a35` and `oc@77a0fd6` are the pinned official-flow implementations
/// named there, cited as file line. Kehai-chosen bounds cite their design
/// decision.
library;

// ---------------------------------------------------------------------------
// Endpoints and registration (design D2)
// ---------------------------------------------------------------------------

/// The OpenID issuer (`docs` sign-in; pi@c466a35 :19-20).
const String openAiIssuer = 'https://auth.openai.com';

/// The authorize endpoint path under the issuer (`docs` sign-in; pi@c466a35
/// :19-20; oc@77a0fd6 :23-24).
const String openAiAuthorizePath = '/api/accounts/authorize';

/// The token endpoint path under the issuer (`docs` sign-in; pi@c466a35
/// :19-20; oc@77a0fd6 :23-24).
const String openAiTokenPath = '/api/accounts/oauth/token';

/// The OIDC discovery document path under the issuer (design D3b).
const String openAiDiscoveryPath = '/.well-known/openid-configuration';

/// The client id sent on the first sign-in to request a registration (`docs`
/// sign-in, sessions; pi@c466a35 :16; oc@77a0fd6 :21).
const String openAiDynamicClientId = 'dynamic_agent_client';

/// The app name hint sent at registration only (`docs` sign-in; design D2,
/// pi@c466a35 :17 and oc@77a0fd6 :22 use their own names).
const String openAiAgentNameHint = 'Kehai';

/// The `urn:uuid:` prefix of the persisted host id (`docs` overview, sign-in;
/// oc@77a0fd6 :106; pi@c466a35 :225-230).
const String openAiHostIdPrefix = 'urn:uuid:';

/// The full scope string requested at sign-in (`docs` sign-in; pi@c466a35
/// :21; oc@77a0fd6 :25-26).
const String openAiScope =
    'openid profile email offline_access resource.invoke '
    'chatgpt.tokens.use.direct';

/// The scope that grants ChatGPT plan usage (`docs` sign-in, errors;
/// pi@c466a35 :170; oc@77a0fd6 :178).
const String openAiPlanUsageScope = 'chatgpt.tokens.use.direct';

/// The `resource` parameter sent on authorize, exchange and refresh (`docs`
/// sign-in, sessions; pi@c466a35 :27). It stays this value even when tests
/// override the API base (design D11).
const String openAiResource = 'https://api.openai.com/v1';

/// The Responses and models API base (`docs` inference; design D7).
const String openAiApiBase = 'https://api.openai.com/v1';

// ---------------------------------------------------------------------------
// Loopback redirect (design D3)
// ---------------------------------------------------------------------------

/// The exact redirect path; only the port may vary (`docs` sign-in).
const String openAiCallbackPath = '/auth/callback';

/// The loopback host of the redirect; never `localhost` (`docs` sign-in;
/// pi@c466a35 :23).
const String openAiRedirectHost = '127.0.0.1';

/// The first-choice redirect port (`docs` sign-in; pi@c466a35 :23, :246;
/// design D3).
const int openAiRedirectPort = 1455;

/// The fallback redirect port, used only with a stored registration (`docs`
/// sign-in permits the port to vary on later sign-ins; design D3).
const int openAiFallbackRedirectPort = 1457;

/// The authorize parameter value that forces the consent screen when plan
/// usage is re-enabled (`docs` errors, "ChatGPT plan use isn't enabled";
/// design D2).
const String openAiReconsentParam = 'prompt';

/// The value paired with [openAiReconsentParam]. Switching to
/// `force_reconsent` is a change of these two constants once OpenAI confirms
/// it for the integration (`docs` errors; design D2).
const String openAiReconsentValue = 'consent';

// ---------------------------------------------------------------------------
// Randomness and lifetimes (design D2, D4, D3b)
// ---------------------------------------------------------------------------

/// The PKCE verifier length in random bytes; 86 base64url characters, within
/// RFC 7636's 43-128 (design D2; `docs` sign-in requires S256).
const int openAiPkceVerifierBytes = 64;

/// The `state` and `nonce` length in random bytes (design D2; pi@c466a35
/// :50).
const int openAiStateBytes = 32;

/// How long before expiry an access token is refreshed (`tokens`; design D4;
/// pi@c466a35 :29 uses 3 min).
const Duration openAiRefreshDueWindow = Duration(minutes: 5);

/// The clock skew allowed on the ID token `exp` claim (design D3b).
const Duration openAiIdTokenExpSkew = Duration(seconds: 60);

// ---------------------------------------------------------------------------
// Refresh error classification (design D4, D10)
// ---------------------------------------------------------------------------

/// Token-endpoint error codes after which the refresh token is dead and the
/// user must sign in again (`docs` errors; design D4).
const Set<String> openAiTerminalRefreshCodes = {
  'invalid_grant',
  'invalid_refresh_token',
  'token_expired',
  'refresh_token_expired',
  'refresh_token_invalidated',
  'refresh_token_reused',
};

/// The token-endpoint code for a client configuration problem (`docs`
/// errors; design D4).
const String openAiInvalidClientCode = 'invalid_client';

/// Codes mapped to `usage_limit`, with no retry-after (`docs` errors;
/// design D10; the workplace code is from pi@c466a35
/// api/openai-responses.ts:259-261).
const Set<String> openAiUsageLimitCodes = {
  'subscription_sharing_usage_limit_exceeded',
  'subscription_sharing_workplace_individual_usage_limit_exceeded',
};

/// Codes mapped to `not_permitted`: do not retry (`docs` errors; design D10).
const Set<String> openAiNotPermittedCodes = {
  'subscription_sharing_user_not_eligible',
  'subscription_sharing_route_not_supported',
  'chatpass_v2_scope_not_authorized',
  'chatpass_v2_invalid_authorization_context',
};

/// Codes mapped to `server`, with credentials preserved (`docs` errors;
/// design D10).
const Set<String> openAiUnavailableCodes = {
  'subscription_sharing_usage_unavailable',
  'subscription_sharing_user_unavailable',
};

/// The code mapped to `invalid_request` that carries `error.param` (`docs`
/// errors; design D10).
const String openAiUnsupportedCapabilityCode =
    'subscription_sharing_unsupported_capability';

/// The code mapped to `context_overflow` (design D10; `docs` errors).
const String openAiContextLengthExceededCode = 'context_length_exceeded';

/// The `401` code that triggers one refresh and repeat (`docs` errors;
/// design D10).
const String openAiInvalidUserCode = 'subscription_sharing_invalid_user';

// ---------------------------------------------------------------------------
// Storage (design D6)
// ---------------------------------------------------------------------------

/// The DPAPI entropy constant, 16 bytes (design D6).
const String openAiDpapiEntropy = 'kehai-openai-v1';

// ---------------------------------------------------------------------------
// Resource bounds (design D10, "Resource Bounds")
// ---------------------------------------------------------------------------

/// The serialized request body cap (oc@77a0fd6 :297 "rejects uncompressed
/// bodies over ~1 MiB"; design D7).
const int openAiMaxRequestBodyBytes = 1024 * 1024;

/// The cap on one SSE `data:` event (design D10, Resource Bounds).
const int openAiMaxSseEventBytes = 8 * 1024 * 1024;

/// The cap on the accumulated arguments of one tool call (design D10,
/// Resource Bounds).
const int openAiMaxToolCallArgumentBytes = 8 * 1024 * 1024;

/// The most tool calls held until `response.completed` (design D10, Resource
/// Bounds).
const int openAiMaxHeldToolCalls = 128;

/// The cap on an error response body read (design D4, Resource Bounds).
const int openAiMaxErrorBodyBytes = 64 * 1024;

/// The cap on token, discovery, key-set and revocation bodies (design D3b,
/// Resource Bounds).
const int openAiMaxAuthBodyBytes = 64 * 1024;

/// The cap on the models response body (design D8, Resource Bounds).
const int openAiMaxModelsBodyBytes = 4 * 1024 * 1024;

/// The timeout of each auth and models request, and of connecting (design
/// D3b, D10, Resource Bounds).
const Duration openAiRequestTimeout = Duration(seconds: 30);

/// The default response-silence deadline (design D10, Resource Bounds).
const Duration openAiSilenceDeadline = Duration(seconds: 300);

/// The browser login wait (design D3, Resource Bounds).
const Duration openAiLoginDeadline = Duration(minutes: 10);

/// The timeout of the best-effort revocation after a stale login (design D3
/// step 8, Resource Bounds).
const Duration openAiStaleRevocationTimeout = Duration(seconds: 5);

/// The longest pasted callback line accepted (design D3, Resource Bounds;
/// the paste fallback follows pi@c466a35 :274).
const int openAiMaxPastedLineBytes = 16 * 1024;

/// The interval between `auth.lock` attempts (design D5, Resource Bounds).
const Duration openAiLockPollInterval = Duration(milliseconds: 100);

/// The deadline for acquiring `auth.lock` (design D5, Resource Bounds).
const Duration openAiLockDeadline = Duration(seconds: 30);
