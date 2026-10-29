# Spec Delta

## Purpose

Lets the model search file contents, find files by name and list directories in the workspace. Plain-text results are stored whole and are cut only by the central composer.

## ADDED Requirements

### Requirement: Ripgrep resolution
`grep` and `find` SHALL run `rg`. It comes from the `rgPath` set in the user configuration, else from `PATH`. A missing or unrunnable `rg` is a visible error naming both ways to fix it, never a fallback to a slower in-process search.

#### Scenario: rg found on PATH
- **WHEN** no `rgPath` is configured and `rg` is on `PATH`
- **THEN** `grep` runs that `rg` and the call's summary names the `rg` version it used

#### Scenario: rg missing
- **WHEN** `rgPath` is unset and no `rg` is on `PATH`, or `rgPath` names a file that does not exist
- **THEN** the call settles `error` with `rg not found; install ripgrep or set rgPath in <config path>` and no search runs

### Requirement: Content search
`grep` SHALL take a pattern and optional path, glob, case-insensitivity and literal flags. It returns one line per match as `<path>:<line>: <text>`, with paths relative to the workspace root and in rg's order. Ignore files are respected as rg does by default. No matches settles `ok` with an empty body and the summary `no matches`.

#### Scenario: Matches rendered per line
- **WHEN** `grep` searches `class SessionWriter` under `lib`
- **THEN** the result contains `lib/src/session/writer.dart:130: final class SessionWriter {` and the summary states the match and file counts

#### Scenario: No matches or invalid pattern
- **WHEN** `grep` searches a pattern found nowhere, or the invalid regex `(`
- **THEN** the first settles `ok` with summary `no matches` and an empty body; the second settles `error` with rg's own error text

### Requirement: File finding
`find` SHALL take a glob and an optional path. It returns one workspace-relative path per line, as `rg --files` lists them with that glob, respecting ignore files unless `hidden` or `no_ignore` is set. The output is never cut by the tool.

#### Scenario: Find Dart tests
- **WHEN** `find` runs with glob `**/*_test.dart` under `test`
- **THEN** every listed path ends in `_test.dart`, `test/session/journal_test.dart` is among them, and the summary states the count

#### Scenario: Missing search path
- **WHEN** `find` runs under a path that does not exist
- **THEN** the call settles `error` with `no such directory <path>` and rg is not started

### Requirement: Directory listing
`ls` SHALL list one directory, not recursively, one entry per line, sorted by name. Directories end in `/` and symbolic links in `@`. Hidden entries are included. The summary states the entry count.

#### Scenario: List a directory
- **WHEN** `ls` runs on `lib`
- **THEN** the body is exactly `kehai.dart` and `src/`, in that order

#### Scenario: Not a directory
- **WHEN** `ls` runs on a file or a missing path
- **THEN** the call settles `error` with `<path> is not a directory` or `no such directory <path>`
