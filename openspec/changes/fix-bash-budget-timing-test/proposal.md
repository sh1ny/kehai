# Proposal

## Why

The first nightly run on `main` (https://github.com/sh1ny/kehai/actions/runs/41108909672) failed on `windows-latest` in one test: `test/shell/bash_tool_test.dart` "budget expiry settles partial with the job id while the job runs". The call returned `partial` with a job id as intended, but took 4.38 s against a `lessThan(4 s)` bound. The test runs `sleep 4` under a 1 s budget, so only 3 s separate "returned on budget expiry" from "waited for the command", and a loaded Windows runner used them up. The tool behaved correctly; the test is flaky.

## What Changes

- Widen the gap in that test: the command sleeps 15 s and the call must return within 10 s, so the bound still fails if the call waits for the command, with 9 s of slack instead of 3 s.
- Give the test's final `waitFor` for the job to settle an explicit 60 s limit, since the default 20 s would be close to the new 15 s command.
- No product code changes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. The test's assertions about the `bash` tool's budget expiry stay the same; only its timing margins change, so the change sets `skip_specs: true`.

## Impact

- `test/shell/bash_tool_test.dart` only. That test runs about 11 s longer, since it now waits for a 15 s command to settle.
