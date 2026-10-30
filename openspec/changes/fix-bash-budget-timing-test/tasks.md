# Tasks

## Test map

The change sets `skip_specs: true` (test timing margins only, no spec-level behavior), so it has no `#### Scenario:` to map. The changed test is itself the verification.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| n/a (skip_specs) | n/a | test/shell/bash_tool_test.dart | budget expiry settles partial with the job id while the job runs | n/a: no spec scenarios; the existing test keeps its assertions with wider margins |

## 1. Test margins

- [ ] 1.1 In `test/shell/bash_tool_test.dart`, change the budget-expiry test to run `echo start; sleep 15; echo end`, assert `clock.elapsed < 10 s`, and pass `limit: const Duration(seconds: 60)` to its final `waitFor`, per design D1. Verify: `dart test -j 1 test/shell/bash_tool_test.dart --exclude-tags slow` passes locally on Windows, and the PR's `check (windows-latest)` and `check (ubuntu-latest)` jobs pass.

## Workflow follow-up

- After merge, dispatch `nightly.yml` on `main` once and confirm both jobs pass.
