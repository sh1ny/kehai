# ADR 0006: Supervised process plugins and explicit integration boundaries

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

Extensions must not crash the UI or hold a turn hostage. Any-language process plugins fit a Dart-native core without an embedded runtime. Local execution is not a security sandbox.

## Decision

Lazy persistent local plugins use versioned stdio NDJSON and may provide hooks/tools/commands plus declarative picker/form/status/panel/tool-card descriptions, not arbitrary widgets. Engine orchestration enforces deadlines independently: mandatory policy hook failure denies, optional enrichment failure is visible no-op. No new approval framework is required. Later plugin collectors use the same boundary.

MCP uses experimental `dart_mcp` local stdio with supervisor-enforced deadlines; LSP uses `json_rpc_2` with a separate Content-Length adapter. Own thin Anthropic/OpenAI-compatible/Gemini/Bedrock providers; use LiteLLM for the rest. Subscription OAuth is later, not M1. Credentials resolve from OS keychain/environment only for the relevant adapter. Resolved provider/OAuth credentials, authorization headers, credential-bearing URLs and launch-environment dumps must never persist in tree, payloads or error logs. Persist adapter errors only as allowlisted structured fields plus a sanitized provider body, redacting known credential/auth material before storage; raw provider exceptions/request dumps are never durable. Preserve useful sanitized failure category/status/message rather than suppressing integration failures.

Construct least-needed environments for shell/plugins/MCP/LSP without inherited provider keys by default. Explicit user-configured environment opt-in must explain that these processes can expose supplied secrets. Raw tool stderr is user-process output, not a harness-generated diagnostic: source and intentional user output may contain secrets and remain subject to the full-result contract. The guarantee is against accidental harness inclusion of configured credentials, not all-user-output redaction or a sandbox.

Configured provider/proxy is the only harness outbound prompt sink. No telemetry/accounts/cloud service. MCP/plugins remain local; remote MCP would need separate explicit authorization. User-installed subprocesses run with user privileges and may themselves access the network. Core fork means rebuilding changed core, never an external-plugin in-process escape hatch.

## Consequences

- **Rejected:** in-process Dart/TypeScript plugins or embedded QuickJS/Python; they share crash/runtime failure domains and expand compatibility maintenance.
- **Rejected:** executable plugin UI; declarative descriptions keep rendering/client state under core ownership.
- **Rejected:** mandatory remote plugin service or automatic remote MCP discovery; unnecessary disclosure/service boundary.
- **Cost:** protocol versioning, bounded framing, supervision and visible default behavior; deadlines cannot rely only on cooperative cancellation.
- **Reversal cost: high** for the extension/trust contract; **medium** for adapter packages. M3 must demonstrate a non-Dart plugin and mid-hook death without session loss. Sources: [dart_mcp](https://pub.dev/documentation/dart_mcp/latest/), [json_rpc_2](https://pub.dev/documentation/json_rpc_2/latest/).
