# ADR 0009: OpenAI subscription credentials and protocol authority

Status: accepted
Accepted: 2026-10-29
Date: 2026-10-29
Supersedes: none

## Context

[ADR 0006](0006-subscription-auth-workflow-and-process-boundaries.md) requires the credential backend to be recorded (Credential Manager split or DPAPI-protected file), requires the Codex-era login references to be compared at pinned revisions, and requires the endpoint a subscription token is valid for to be verified rather than assumed. The `provider-openai-codex` change settles them ([design](../../openspec/changes/provider-openai-codex/design.md), D6 and *Upstream sources compared*). The credential record is an on-disk format the user's login depends on, and the protocol authority decides which constants Kehai may use, so both are recorded here. ADR 0006 holds: OpenAI's docs establish that the token-sharing token is valid for `https://api.openai.com/v1/responses`, so nothing is superseded.

## Decision

### Protocol authority

OpenAI's *Sign in with ChatGPT: token sharing for open-source apps* developer pages, read on 2026-10-29, are authoritative for auth and for the request rules. The pages are not revision-pinned, so this ADR records the read date, and each constant in `lib/src/auth/openai_constants.dart` names its page: overview (<https://developers.openai.com/siwc/token-sharing-open-source>), `sign-in`, `profiles-and-sessions`, `models-and-inference`, `preview-limitations`, `token-reference` and `errors-and-recovery`.

The official-flow implementations `earendil-works/pi@c466a35957e73876651d014d6c36d5ea47148344` and `anomalyco/opencode@77a0fd6f3b247235b09941d55ff0faf72be1dae4` are corroboration at those pinned revisions. Where the docs are silent (paste fallback, request body cap, `supported_in_api`, an extra usage-limit code), Kehai follows an official-flow implementation and cites it. No constant is taken from a snippet: each cites the page or file read.

**Eligibility condition.** The program covers open-source and locally hosted apps; paid or remotely hosted use needs OpenAI's interest form. Kehai qualifies as long as it stays open-source and local. Changing either needs a new decision.

### Rejected: the Codex client route

The Codex CLI's own client id `app_EMoamEEZ73f0CkXaXp7hrann` with `https://chatgpt.com/backend-api/codex` is rejected. OpenAI does not sanction it for third parties, and its docs tell apps not to call `backend-api`. The comparison ADR 0006 requires, kept for audit (from the change's first draft, at the pinned revisions; short forms codex, omp, oc@ec3ae17, nm):

| Fact | codex@7c11b80 | omp@76772d0 | oc@ec3ae17 | nm@bec2ad6 | **Kehai (official flow)** |
|---|---|---|---|---|---|
| PKCE | 64-byte verifier, S256 | 96-byte verifier | 43-char verifier, biased alphabet | 64-byte verifier | 64-byte verifier, S256 |
| State | 32 bytes | 16 bytes hex | none | 16 bytes hex | 32 bytes, plus a 32-byte nonce |
| Redirect | `http://127.0.0.1:1455/auth/callback`, fallback `1457` | `localhost:1455`, no fallback | `localhost:1455` | `localhost:1455`, paste fallback | `127.0.0.1:1455`, `1457` only when registered, paste fallback |
| Scopes | `openid profile email offline_access api.connectors.read api.connectors.invoke` | codex's full set | `openid profile email offline_access` | `openid profile email offline_access` | `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct` |
| Token-valid endpoint | `chatgpt.com/backend-api/codex` | same | same | same | `api.openai.com/v1/responses` |
| Refresh / expiry | JSON body; at `exp - 5 min` or 8 days after the last refresh | form; 60 s skew | form; at expiry | form | form with `resource`; at `expires_at - 5 min`, and once after a `401` |
| Service-change failure | client id or backend cut off for third parties, with no published contract | same | same | same | preview program changes, surfaced as named errors |
| Reversal cost | n/a | n/a | n/a | n/a | medium |
| API-key fallback | separate API-key login | separate provider | separate provider | none | none in M1 |

All four reuse that client with `/oauth/authorize` and `/oauth/token` on `auth.openai.com`, and call `chatgpt.com/backend-api/codex` with `chatgpt-account-id` and `originator` headers and a pinned `client_version` that gates models. Revisions: `openai/codex@7c11b80`, `can1357/oh-my-pi@76772d0`, `anomalyco/opencode@ec3ae17` (historical), `numman-ali/opencode-openai-codex-auth@bec2ad6`. oh-my-pi's current `main` (`e78a34c881c34528c09348420ab2eb0ea879e2d9`) still ships only this route; current pi and OpenCode keep it as a separate provider beside their official one.

### Credential record v1

UTF-8 JSON:

```
{version:1, provider:"openai", host_id, generation,
 registration?:{issuer, client_id, subject, email, plan?, plan_usage:"enabled"|"disabled"},
 tokens?:{id_token, access_token, refresh_token, expires_at (ISO-8601 UTC), scopes, saved_at, last_refresh}}
```

- The user is logged in iff `tokens` is present. `tokens` is present only with `plan_usage: "enabled"`; a load that finds both `tokens` and `"disabled"` is `credentials unreadable`.
- `plan_usage` is set from the granted scopes: a verified sign-in without `chatgpt.tokens.use.direct` is kept as a registration with `plan_usage: "disabled"` and no tokens, and the refresher sets `disabled` when the scope disappears. `--enable-plan-usage`, or an ordinary login that is granted the scope, sets `enabled`; `--forget` removes it with the registration.
- `generation` is an integer advanced by every login, logout and `--forget` commit, never by a refresh. It is the stale-login check: a login pending in another process is rejected at its commit.
- One record per Kehai home: one registration at a time (M1). `host_id` is kept by logout and `--forget`.

### Location and backends

- **Home:** `KEHAI_HOME`, else `~/.kehai` (`%USERPROFILE%\.kehai` on Windows).
- **Windows:** `auth.dpapi`, holding `CryptProtectData` output (current-user scope, `CRYPTPROTECT_UI_FORBIDDEN`, a fixed 16-byte entropy constant `kehai-openai-v1`), written by temp, flush and rename. DPAPI output is integrity-protected: a blob substituted by anyone other than the same user fails to decrypt, giving `credentials unreadable`. The default home sits under the profile ACL; a `KEHAI_HOME` pointed at a shared, writable location is outside the supported trust model in M1, and ACL validation (`GetNamedSecurityInfoW`) is not built. The rename-over relies on Dart's `File.rename` replacing an existing file, proven by the *atomic replacement* test; if that fails the backend switches to `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` through `win32`.
- **Unix:** `auth.json` with mode `0600`. The directory is created and then `chmod 0700`'d through libc FFI. The temp file is created through libc `open(path, O_WRONLY|O_CREAT|O_EXCL, 0600)`, so it is never readable by others, not even briefly; it is written, `fsync`ed and renamed over `auth.json`.
- **Fail-closed selection:** a failure of `CryptProtectData`/`CryptUnprotectData`, `open` or `chmod` stops with `secure credential storage unavailable` or `credentials unreadable`. There is never a plaintext fallback, and an unsupported Unix ABI also fails closed.

### Trusted home path (Unix)

Before any load, store, or lock creation or acquisition:

- The home's own final component must not be a symlink; symlinked ancestors are allowed. `Directory(home).resolveSymbolicLinksSync()` gives the canonical path.
- The OpenSSH `safe_path` ownership rule (`auth.c`), through libc FFI `stat` for `st_uid` and `st_mode` and `geteuid()`: the home is owned by the current user; every ancestor up to `/` is owned by root or the current user; no ancestor has a `0022` bit unless it is root-owned with the sticky bit (`01000`), as `/tmp` is. A failure names the component, its owner uid and its mode.
- `struct stat` is read only for `st_mode` and `st_uid`, at fixed offsets for the three Unix targets: Linux x86_64 (24, 28), Linux aarch64 (16, 24), macOS (`stat$INODE64`: `st_mode` 16-bit at 4, `st_uid` at 16). On older glibc with only `__xstat`, Kehai falls back to `__xstat(_STAT_VER, ...)` (1 on x86_64, 0 on aarch64). Any other ABI fails closed. At first use Kehai compares `st_mode & 07777` from FFI with Dart's `FileStat.statSync(home).mode & 07777`; a mismatch fails closed.
- Before every load and store, the home must not be a symlink, must be a directory and must have no `0077` bit; `auth.json` must not be a symlink, must be a regular file and must have no `0077` bit. With the ownership rule above, this check-then-open cannot be raced by another user.
- The canonical path is used for `auth.json`, temp files and `auth.lock`.

Root and the user's own processes are inside the trust boundary. Rejected: `openat`/`fstatat` directory-handle operations for every file access, which would route all reads, writes, renames and locks through FFI for no gain once every ancestor is trusted.

### Cross-process lock

`auth.lock` is an exclusive `RandomAccessFile` lock in the canonical home, taken by refresh, login and logout, with non-blocking attempts every 100 ms and a 30 s deadline (`network`-class failure "credential lock busy"). It serializes refresh across processes, as the docs require ("serialize refreshes ... so two processes do not race a rotating token"); the OS releases it when a holder dies. Reads need no lock because the atomic replace shows either the old or the new complete record.

### `additional_tools` request shape

`preview-limitations` says to "group function/custom tools in namespaces or supply them through `additional_tools` input items", with no JSON example. The item shape is pi's (`api/openai-responses-shared.ts:157-245`): one `{type:"additional_tools", role:"developer", tools:[{type:"function", name, description, parameters, strict:false}, ...]}` item at the head of `input`, which pi's comment says it verified in October 2026 against the OpenAI, Codex and Copilot backends. This is single-source evidence. The fake server asserts the shape; only the user-verified turn with a completed tool round trip (task 8.2) settles that the real route accepts it. A rejection surfaces as `invalid_request` with its parameter.

### Cross-user DPAPI isolation

Isolation between Windows users rests on DPAPI's documented current-user scope. It is a platform property, not test evidence: the *Wrong DPAPI entropy cannot decrypt* test proves only the entropy binding under one user.

## Consequences

- **Rejected:** Windows Credential Manager split across several entries of at most 2.5 KB. Multi-entry writes are not atomic, so a crash mid-write leaves a mismatched token set; a DPAPI file gives one atomic blob with the same protection scope (the current user's logon secret).
- **Rejected:** the host id in a separate plain file; one record keeps one atomic write and one lock.
- **Rejected:** macOS Keychain or Linux Secret Service now. They need more FFI or a D-Bus dependency, and the strategy permits the `0600` file on Unix.
- **Rejected:** `dart:io` file creation followed by `chmod` through `Process.run`, which leaves a window with umask permissions and depends on an external binary.
- **Rejected:** the Codex client id and `chatgpt.com/backend-api` (above).
- **Accepted limitation:** the token-sharing program is a preview and can change parameters, request rules and error codes. Each change maps to a visible, named error, and the user-verified acceptance run (task 8.2) exercises the real path. If the program closes or changes terms, M1's subscription exit criterion is blocked and escalated to the user; an API-key fallback is not a passing substitute.
- **Accepted limitation:** the `additional_tools` shape and the 1 MiB body cap (from `oc@77a0fd6`, line 297) each rest on one implementation.
- **Accepted limitation:** a Unix home on a filesystem without POSIX modes fails closed with an explicit message; `KEHAI_HOME` can point elsewhere. A crash between a refresh response and the store loses the rotated token and needs a re-login.
- **Cost:** FFI for `stat`, `chmod`, `open` and DPAPI, and a self-validation step on Unix.
- **Reversal cost: medium.** The record is an on-disk format the user's login depends on, but it is regenerable by logging in again, so a format change can require re-login. Reversing the protocol authority or the Codex-route rejection is a new decision against OpenAI's published rules.
