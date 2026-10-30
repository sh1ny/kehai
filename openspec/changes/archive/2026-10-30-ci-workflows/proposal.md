# Proposal

## Why

kehai has no continuous integration: `format:check`, `analyze`, the test suite, OpenSpec validation and the secrets scan run only when an agent or the user remembers to run them locally, and only on whichever OS that machine has. A public repository that targets native Windows and Linux needs every pull request checked on both, before review, without spending a developer machine on it.

This is an off-roadmap chore. It serves no M1 exit criterion directly; it supports all of them by making the existing local gates (`mise run check`, `openspec:validate`, `secrets`) run on every push to `main` and every pull request.

## What Changes

- New workflow `.github/workflows/ci.yml`, triggered on push to `main` and on every pull request. A two-OS matrix (`ubuntu-latest`, `windows-latest`) installs the tools pinned in `mise.toml` with the official `jdx/mise-action`, then runs `mise run format:check`, `mise run analyze` and `dart test --exclude-tags slow`. The Ubuntu job also runs `mise run openspec:validate` and `mise run secrets`.
- New workflow `.github/workflows/nightly.yml`, on a daily schedule and on `workflow_dispatch`, running the full `dart test` (including the `slow` tag) on the same two OSes.
- Both workflows pin every third-party action to a full commit SHA with a version comment, grant only `contents: read`, cache the mise tool installs and the pub cache, and (for CI) cancel superseded pull-request runs.
- No product code, test, tag or `mise.toml` task changes. Platform gating stays in the tests (`@TestOn`, `skip:` on `Platform.isWindows`), so both OSes run the same command.

## Capabilities

### New Capabilities

None. CI is repository tooling; it adds no behavior a kehai user or client observes. The change sets `skip_specs: true`.

### Modified Capabilities

None.

## Impact

- New files: `.github/workflows/ci.yml`, `.github/workflows/nightly.yml`.
- GitHub: adds two required-able check jobs on pull requests (branch protection is left to the user), plus a nightly run. Actions minutes on a public repository are free.
- Third-party code executed in CI: `actions/checkout`, `actions/cache`, `jdx/mise-action`, each pinned by SHA, and the tool versions already pinned in `mise.toml`.
- Existing tests may surface latent OS- or environment-dependent failures on clean runners; those are reported, not patched in this change.
