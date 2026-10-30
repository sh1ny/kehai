# Tasks

## Test map

The change sets `skip_specs: true` (repository tooling, no spec-level behavior), so it has no `#### Scenario:` to map. Verification is mechanical, per task below: YAML parses, every `uses:` is SHA-pinned, `openspec validate` passes, and the pull request's own CI run completes on both OSes.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| n/a (skip_specs) | n/a | `.github/workflows/*.yml` | YAML parse + SHA-pin check + PR CI run | n/a: no spec scenarios; CI configuration is checked mechanically and by its own run |

## 1. Pull-request and main CI workflow

- [x] 1.1 Write `.github/workflows/ci.yml` per design D1-D6: triggers `push` to `main` and `pull_request`; top-level `permissions: contents: read`; `concurrency` cancelling superseded PR runs only; matrix `ubuntu-latest`/`windows-latest` with `fail-fast: false` and `timeout-minutes: 30`; steps checkout (`persist-credentials: false`) → mise-action (pinned mise `version`) → Linux-only `mise run secrets` → pub cache → `mise run get` → `mise run format:check` → `mise run analyze` → `dart test --exclude-tags slow` → Linux-only `mise run openspec:validate`. Verify: the file parses as YAML, and every `uses:` line matches `@[0-9a-f]{40} # v`.

## 2. Nightly full-suite workflow

- [x] 2.1 Write `.github/workflows/nightly.yml`: `schedule` (`17 3 * * *`) and `workflow_dispatch`; same permissions, setup, pins and caches as 1.1; matrix on both OSes with `timeout-minutes: 120`, running `mise run get` then the full `dart test` (slow tag included). Verify: the file parses as YAML, every `uses:` is SHA-pinned, and `ci.yml` and `nightly.yml` pin identical SHAs for each shared action.

## 3. Integration check

- [x] 3.1 Run `mise exec -- openspec validate --all --strict` and `mise run format:check` locally; both pass.

## 4. Fixes found by the PR's own CI run

- [x] 4.1 Add `.gitattributes` with `* text=auto eol=lf` and drop the workflow-level `core.autocrlf false` step from both workflows. Verify: `test/fixtures/anchors/*.txt` check out with LF on Windows, and `test/tools/read_tool_test.dart` passes locally and on `windows-latest`.
- [x] 4.2 End `bin/kehai.dart` with an explicit `exit` after flushing output, because on the Windows runner `login openai --no-browser` printed its result but never exited (a cancelled standard-input read stayed pending). Verify: `test/cli/cli_test.dart` "login openai --no-browser signs in through a pasted redirect URL" passes locally and on `windows-latest`.

## Workflow follow-up

- After the PR opens (specwright-pr ship/watch), confirm its CI run finished with both `check (ubuntu-latest)` and `check (windows-latest)` jobs green; diagnose any failure from the Actions log and fix it here only if it is workflow environment setup.
- `nightly.yml` can only be dispatched once it is on `main` (GitHub registers `workflow_dispatch` and `schedule` from the default branch); after merge, run it once by hand to confirm the slow tests pass on both runners.
- Branch protection (making the two `check` jobs required) is the repository owner's choice and is not part of this change.
