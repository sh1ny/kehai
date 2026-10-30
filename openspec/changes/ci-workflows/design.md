# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | No | Two independent YAML workflow files; no kehai component, process or isolate is added or changed. |
| T2 State (persistent state, caches, 3+ state machine) | No | The only state is GitHub's Actions cache (mise installs, pub cache): disposable, keyed on `mise.toml` / `pubspec.lock`, rebuilt on any miss. No product state. |
| T3 Concurrency (background work, workers/isolates, async, retries) | No | The two matrix jobs are independent and share nothing; `concurrency` only cancels a superseded run. No kehai concurrency changes. |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | No | No stored format, public API or IPC changes. The GitHub Actions integration consumes the existing `mise.toml` tasks unchanged and exposes nothing kehai depends on. |
| T5 Volume (grows without a fixed bound) | No | Caches are bounded by GitHub (10 GB per repo, LRU eviction) and by mise-action's `cache_max_age_days`. |
| T6 Risk (security, money, data loss, unrecoverable user data) | No | Workflows use `pull_request` (not `pull_request_target`), top-level `permissions: contents: read`, no secrets beyond the default read-only `GITHUB_TOKEN`, and every third-party action is pinned to a commit SHA. `gitleaks` only reads the tree. Nothing writes to the repository, releases or packages. |

TIER: LIGHT

## Context

See proposal.md for scope. Relevant current state:

- Every tool is pinned in `mise.toml:4-10` (Dart 3.13.7, jj, ripgrep, gh, gitleaks, Node 24, OpenSpec 1.14.1), and the checks already exist as mise tasks: `format:check`, `analyze` (`mise.toml:30-31`), `openspec:validate` (`mise.toml:41-43`), `secrets` (`mise.toml:45-47`). `[env]` sets `DART_DATA_HOME` (`mise.toml:12-15`), so commands must run with the mise environment loaded.
- `dart_test.yaml:1-5` defines the `slow` tag (10x timeout); it is used by `test/shell/bash_tool_test.dart` and `test/tools/read_tool_test.dart`.
- Platform gating lives in the tests: `@TestOn('!windows')` (`test/hooks/hook_program_test.dart:3`) and `skip:` values on `Platform.isWindows` (`test/auth/credential_store_test.dart:94-95`, `test/auth/home_trust_test.dart:169`, `test/jobs/cancel_test.dart:141`). One command therefore serves both OSes.
- Search tests need `rg` on `PATH` (`lib/src/tools/search.dart:91` errors otherwise); the mise install puts ripgrep there.
- `mise run analyze` needs resolved packages; `dart analyze` does not run `pub get` itself, so the job runs `mise run get` first.
- No `.github/` directory exists yet; no in-force ADR (`docs/adr/0001`-`0010`) covers CI.
- The project's M1 design rules (Dart 3.x AOT, no Rust core, no embedded script runtime, no durable session state outside the tree) are unaffected: this change adds no runtime code.

## Decisions

### D1: One matrix job definition per workflow, OS-specific steps gated by `runner.os`

- **Choice:** `ci.yml` has one job `check` with `strategy.matrix.os: [ubuntu-latest, windows-latest]` and `fail-fast: false`, producing the two jobs. `openspec:validate` and `secrets` carry `if: runner.os == 'Linux'`. `nightly.yml` mirrors it with a `test` job running the full `dart test`.
- **Rejected:** two hand-written jobs per workflow (`linux`, `windows`) because the shared steps (checkout, mise, cache, get, format, analyze, test) would be duplicated and drift; the only difference is two Linux-only steps.
- **Reversal cost:** low.

### D2: Tools come only from mise, via `jdx/mise-action` with its built-in cache

- **Choice:** `jdx/mise-action` at v5.2.4 (`6be3c7ed4c21d4f76b208d351d95aac273ebb76d`) with `version` pinned to a specific mise release, `install: true`, default `cache: true` (keyed on `mise.toml`), default `env: true` so `DART_DATA_HOME` and the tool `PATH` reach later steps. All of `mise.toml`'s tools install on both OSes, matching what a developer gets from `mise install`.
- **Rejected:** `dart-lang/setup-dart` plus per-tool setup actions, because it bypasses the `mise.toml` pins that `AGENTS.md` makes authoritative and would let CI's tool versions drift from local ones. Also rejected: installing only Dart on Windows via `install_args`, because tests shell out to `rg` and a POSIX shell, and a partial install is a second, divergent environment for a small cached saving.
- **Reversal cost:** low.

### D3: Pub cache via `actions/cache`, keyed on OS and `pubspec.lock`

- **Choice:** `actions/cache` v6.1.0 (`55cc8345863c7cc4c66a329aec7e433d2d1c52a9`) on the OS's default pub cache (`~/.pub-cache` on Linux, `~\AppData\Local\Pub\Cache` on Windows, chosen with a `runner.os` expression), key `pub-${{ runner.os }}-${{ hashFiles('pubspec.lock') }}` with an OS-level restore key, before `mise run get`.
- **Rejected:** no pub cache, because every job would re-download all dependencies; also rejected: redirecting `PUB_CACHE` into the workspace, because `gitleaks dir .` and `dart format .` would then scan downloaded third-party sources.
- **Reversal cost:** low.

### D4: Same check order as `mise run check`, secrets scan before dependencies land

- **Choice:** checkout → mise → (Linux) `mise run secrets` on the fresh checkout → pub cache → `mise run get` → `mise run format:check` → `mise run analyze` → `dart test --exclude-tags slow` → (Linux) `mise run openspec:validate`. Tests run as a plain `dart test` (the mise env is exported to the step), exactly the command developers use.
- **Rejected:** `mise run check`, because it includes the slow tests (`mise.toml:33-39`) that belong to nightly, and a single step hides which gate failed.
- **Reversal cost:** low.

### D5: Least privilege and supply-chain pinning

- **Choice:** top-level `permissions: contents: read`; `pull_request` trigger only; every `uses:` pinned to a 40-character SHA with a `# vX.Y.Z` comment (`actions/checkout` v7.0.1 `3d3c42e5aac5ba805825da76410c181273ba90b1`); `actions/checkout` with `persist-credentials: false`; mise-action's `github_token` kept at its default (the read-only job token, used only to avoid GitHub API rate limits when downloading tool releases, not persisted).
- **Rejected:** tag references (`@v7`), because a moved tag would silently run new code; `pull_request_target`, because it runs fork PRs with a write token.
- **Reversal cost:** low.

### D6: Cancellation and time bounds

- **Choice:** CI `concurrency: group: ci-${{ github.event.pull_request.number || github.ref }}`, `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` — a new push to a PR cancels its older run; pushes to `main` are never cancelled, so every `main` commit keeps a result. Nightly uses its own group without cancellation. Job `timeout-minutes`: 30 for CI, 120 for nightly (slow tests run with a 10x timeout). Nightly runs at `17 3 * * *` UTC (off the hour to avoid the scheduler's top-of-hour congestion).
- **Rejected:** cancelling on every ref including `main`, because a fast sequence of merges would leave `main` commits without a CI result.
- **Reversal cost:** low.

## Risks / Trade-offs

- [A clean runner exposes a latent OS- or environment-dependent test failure] → Report it from the Actions log; fix only workflow environment setup in this change, never the tests (owned by other changes).
- [Windows runners use `core.autocrlf=true`, so `dart format --set-exit-if-changed` sees CRLF files] → The developer machine uses the same setting (`git config core.autocrlf` is `true` in the user's system gitconfig) and `format:check` passes there; if CI disagrees, the workflow-level fix is a pre-checkout `git config --global core.autocrlf false`, recorded as a deviation.
- [A pinned SHA goes stale] → Accepted; updates are a deliberate edit (Dependabot for actions can be added later).
- [Scheduled workflows on public repos are disabled after 60 days without repository activity] → Accepted; `workflow_dispatch` re-runs it on demand.

## ADRs

- **In force, constraining this change:** none (0001-0010 cover the engine, not repository tooling).
- **To record during apply:** none (CI configuration is tactical and reversible).
