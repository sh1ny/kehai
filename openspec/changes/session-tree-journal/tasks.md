# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| session-journal → Four-field journal records | Appended record has exactly four fields | test/session/record_test.dart | appended record has exactly four fields | green |
| session-journal → Four-field journal records | Record with an extra or missing field is rejected | test/session/journal_test.dart | record with an extra or missing field is rejected on open | green |
| session-journal → Operation vocabulary | Each operation updates the tree | test/session/tree_ops_test.dart | set, merge and del update the tree | green |
| session-journal → Operation vocabulary | Invalid operation use is rejected before append | test/session/writer_test.dart | invalid op use is rejected before append | green |
| session-journal → Path identity | Valid path addresses one node | test/session/path_test.dart | valid path addresses exactly one node | green |
| session-journal → Path identity | Malformed path is rejected | test/session/path_test.dart | malformed paths are rejected with the offending rule | green |
| session-journal → Validate, persist, append, then publish | Acknowledged record survives a crash | test/session/crash_test.dart | acknowledged record survives a killed process | green |
| session-journal → Validate, persist, append, then publish | Storage failure is not published | test/session/writer_test.dart | storage failure is not published and breaks the writer | green |
| session-journal → Single writer per session | Second writer is refused | test/session/ownership_test.dart | second writer is refused from process, isolate and same isolate | green |
| session-journal → Single writer per session | Concurrent openers race | test/session/ownership_test.dart | concurrent openers race and exactly one wins | green |
| session-journal → Single writer per session | Takeover race inside one process | test/session/ownership_test.dart | takeover race inside one process yields one owner | green |
| session-journal → Single writer per session | Close racing a reopen | test/session/ownership_test.dart | close racing a reopen never yields two writers | green |
| session-journal → Single writer per session | Crash while changing ownership | test/session/ownership_test.dart | stale empty gate is refused with removal hint | green |
| session-journal → Single writer per session | Dead owner is taken over | test/session/ownership_test.dart | dead owner process is taken over | green |
| session-journal → Read-only materialization is observational | Read-only materialization alongside a writer | test/session/materialize_test.dart | read-only materialization alongside a writer is observed | green |
| session-journal → Read-only materialization is observational | Record visible before a failed flush | test/session/materialize_test.dart | record visible before a failed flush is not acknowledged | green |
| session-journal → Bounded writer admission and subscribers | Burst within the bound | test/session/writer_queue_test.dart | burst of 32 operations is ordered for all subscribers | green |
| session-journal → Bounded writer admission and subscribers | Queue full or slow subscriber | test/session/writer_queue_test.dart | full queue rejects with writer busy and slow subscriber resyncs | green |
| session-journal → Torn trailing record recovery | Torn tail is preserved and truncated on write open | test/session/journal_test.dart | torn tail is preserved and truncated on write open | green |
| session-journal → Torn trailing record recovery | Valid JSON without newline is still torn | test/session/journal_test.dart | valid record without newline is torn | green |
| session-journal → Interior corruption stops writes | Corrupt interior line | test/session/journal_test.dart | corrupt interior line stops open and read | green |
| session-journal → Interior corruption stops writes | Unappliable interior record | test/session/journal_test.dart | unappliable interior record stops open | green |
| session-journal → Explicit journal migration | Migration preserves the original | test/tool/migrate_journal_test.dart | migration preserves the original | green |
| session-journal → Explicit journal migration | Outdated format with a torn tail | test/tool/migrate_journal_test.dart | outdated format with a torn tail migrates complete records | green |
| session-journal → Explicit journal migration | Unsupported or outdated format | test/tool/migrate_journal_test.dart | outdated open and unregistered migration change no file | green |
| session-tree → Deterministic materialization | Random histories replay to identical trees | test/property/replay_property_test.dart | random histories replay to identical trees | red |
| session-tree → Deterministic materialization | Failing seed is reproducible | test/property/replay_property_test.dart | failing seed is reported and reproducible | red |
| session-tree → Session origin record | New session starts with an origin record | test/session/origin_test.dart | new session starts with one origin record | green |
| session-tree → Session origin record | Missing or repeated origin is rejected | test/session/origin_test.dart | missing or repeated origin is rejected | green |
| session-tree → Turn anchoring | Turns advance by one | test/session/turn_test.dart | turns advance by one | green |
| session-tree → Turn anchoring | Skipped or past turn is rejected | test/session/turn_test.dart | skipped or past turn is rejected | green |
| session-tree → Journal-only rewind | Rewind removes later turn-anchored state | test/session/rewind_test.dart | rewind restores end-of-turn state and keeps meta | green |
| session-tree → Journal-only rewind | Invalid rewind target is rejected | test/session/rewind_test.dart | invalid rewind target is rejected | green |
| session-tree → Journal-only rewind | Rewind survives replay | test/session/rewind_test.dart | two rewinds survive replay | green |
| session-tree → Journal-only fork | Fork is independent of the parent | test/session/fork_test.dart | fork survives parent deletion with readable handles | red |
| session-tree → Journal-only fork | Fork keeps current session settings | test/session/fork_test.dart | fork keeps current meta with replaced identity keys | red |
| session-tree → Journal-only fork | Fork failure leaves no child | test/session/fork_test.dart | fork failure leaves no child directory | red |
| session-tree → Request admission and outcome correlation | Duplicate after rewind is not re-executed | test/session/requests_test.dart | duplicate after rewind returns recorded outcome | green |
| session-tree → Request admission and outcome correlation | Simultaneous duplicate admissions | test/session/requests_test.dart | simultaneous duplicate admissions admit exactly once | green |
| session-tree → Request admission and outcome correlation | Request id collision | test/session/requests_test.dart | request id collision is rejected including concurrently | green |
| session-tree → Resume finalizes interrupted requests | Admitted request becomes interrupted | test/session/requests_test.dart | admitted request becomes interrupted on reopen | green |
| session-tree → Resume finalizes interrupted requests | Recovery append fails | test/session/requests_test.dart | recovery append failure fails the open | green |
| result-store → Immutable full-result bytes | Large result stored whole | test/results/result_store_test.dart | 50 MiB result stored whole with backpressure | green |
| result-store → Immutable full-result bytes | Producer fails after emitting output | test/results/result_store_test.dart | producer failure finalizes the accepted prefix | green |
| result-store → Immutable full-result bytes | Storage fails during write | test/results/result_store_test.dart | storage failure returns no descriptor and names the temp file | green |
| result-store → Tree-held result descriptors and handles | Handle resolves through the tree | test/results/handles_test.dart | handle resolves through the tree | green |
| result-store → Tree-held result descriptors and handles | Identical bytes from a complete and a failed producer | test/results/handles_test.dart | identical bytes keep per-occurrence completion in both orders | green |
| result-store → Tree-held result descriptors and handles | Unknown or broken handle | test/results/handles_test.dart | unknown or broken handle fails explicitly | green |
| result-store → Central truncation envelope | Read result over the line cap | test/results/composer_test.dart | read over the line cap gets the exact truncation line | green |
| result-store → Central truncation envelope | Result that fits has no truncation line | test/results/composer_test.dart | fitting result has no truncation line | green |
| result-store → Head and tail cut for logs | Long log keeps head and tail | test/results/composer_test.dart | bash log keeps 60% head and 40% tail | green |
| result-store → Head and tail cut for logs | Over-long single line | test/results/composer_test.dart | 2 GiB newline-free line is cut with bounded memory | green |
| result-store → Explicit opt-out bounded by capacity | notrunc within capacity | test/results/composer_test.dart | notrunc within capacity shows everything | green |
| result-store → Explicit opt-out bounded by capacity | notrunc over capacity | test/results/composer_test.dart | notrunc over capacity fails explicitly | green |
| result-store → Paging and search over stored results | Page and search a stored result | test/results/reader_test.dart | page and search a stored result | green |
| result-store → Paging and search over stored results | Out-of-range page or invalid pattern | test/results/reader_test.dart | out-of-range page and invalid pattern fail | green |
| result-store → Paging and search over stored results | Pathological pattern or huge line | test/results/search_test.dart | pathological pattern times out and huge line states its prefix | green |
| result-store → Paging and search over stored results | Search burst over the concurrency limit | test/results/search_test.dart | search burst over the limit is rejected and slots are freed | green |

## 1. ADR and architecture index

- [x] 1.1 Write `docs/adr/0008-journal-format-v1.md` (MADR-short, `Status: accepted`, dated, `Supersedes: none`) recording what design.md *ADRs* lists: op vocabulary, path grammar and root set, origin record, turn rule, `meta`-exempt timeline rewind, `meta/requests` anchoring, newline commit marker and torn-tail policy, content-addressed `r/<12hex>` descriptors with completion on the occurrence, copy-on-fork with current `meta`, the gate/owner single-writer protocol, `observed` disk reads, the migration contract, and the macOS `fsync` limitation; add its row to the ADR index in `openspec/architecture.md`. Verify: the file exists with those sections and `openspec validate --all --strict` passes.

## 2. Package scaffold

- [x] 2.1 Create the Dart package at the repo root: `pubspec.yaml` (`name: kehai`, SDK `^3.13.0`), `analysis_options.yaml` including `package:lints/recommended.yaml` with strict casts/inference/raw types, `lib/kehai.dart`, and add dependencies with `dart pub add crypto path` and `dart pub add --dev test lints`; make sure `.gitignore` covers `.dart_tool/` and `build/`. Verify: `mise run analyze` and `mise run format:check` pass, and `mise run test` runs a placeholder test in `test/smoke_test.dart`.

## 3. Records, paths and tree operations

- [x] 3.1 Write failing tests for record encoding (exact four keys, key order, single newline), path validation (segment alphabet and length, 1–32 segments, root set, empty path rules) and the pure tree operations `set`/`merge`/`del` with their error cases, and verify they fail for the missing implementation (rows: appended record has exactly four fields; valid path; malformed paths; set, merge and del).
- [x] 3.2 Implement `lib/src/session/record.dart`, `path.dart` and `tree.dart` (mutable JSON tree, deep-copied values, canonical serialization with sorted keys); verify the 3.1 tests pass and flip their rows green.

## 4. Journal file, writer, origin and turns

- [x] 4.1 Write failing tests for: the origin record (new session, missing or repeated origin), the turn rule, rejection of invalid op use before append, an extra/missing-field line failing open, torn-tail handling (preserve and truncate on write open, valid record without newline is torn), interior corruption and unappliable records stopping both open modes with line and offset, read-only materialization flagged `observed`, and storage failure (simulated via an injectable file layer: a failing `writeFrom`/`flush`) leaving the tree unpublished and the writer `broken`; verify each fails for the right reason.
- [x] 4.2 Implement `lib/src/session/journal.dart` (line reader to last newline, validation with line/offset errors, torn-tail recovery to `recovery/torn-<offset>-<utc>.bin`), `materialize.dart` (meta fold plus timeline) and `writer.dart` (append, `flush`, then fold, publish and complete; `broken` state). Verify the 4.1 tests pass and flip their rows green.
- [x] 4.3 Write the failing crash test: spawn `dart run test/fixtures/append_then_wait.dart <dir>`, wait for its acknowledged-append marker on stdout, kill it, and reopen. Then add the `observed` failed-flush test (pause hook between write and flush, then fail the flush). Make both pass and flip their rows green.
- [x] 4.4 Write failing tests for the bounded queue (32 concurrent operations ordered for every subscriber; operation 65 rejected synchronously with `writer busy` and nothing appended) and for subscriber overflow (a paused subscriber gets `ResyncRequired(lastOffset)` at 1,024 while appends and other subscribers continue); implement them in `writer.dart`; verify they pass and flip the rows green.

## 5. Single-writer gate protocol

- [x] 5.1 Write failing tests in `test/session/ownership_test.dart` using injected pause hooks plus a helper process `test/fixtures/hold_session.dart`:
  - a second writer refused from another process, from another isolate and from the same isolate;
  - a three-way concurrent open with exactly one winner;
  - the two-isolate takeover race;
  - close racing a reopen across two isolates and a foreign process;
  - a stale empty `session.gate` refused after 2 s with `pid unknown`, then succeeding after removal;
  - a killed owner process being taken over and reported.

  Verify each fails for the right reason.
- [x] 5.2 Implement `lib/src/session/ownership.dart` per design D5 (gate acquisition with a 2 s retry, owner records renamed into place, a liveness-only lock, release that closes the lock handle first and then deletes the record under the gate after a nonce check) and wire it into writer open/close; verify the 5.1 tests pass on Windows and flip the rows green.

## 6. Rewind, requests and resume

- [x] 6.1 Write failing tests: rewind restores end-of-turn-K state and keeps `meta` (one appended line, earlier lines unchanged); invalid rewind targets; two rewinds survive replay; duplicate after rewind returns the recorded outcome without appending; simultaneous duplicate admissions admit exactly once; collisions (sequential and concurrent); admitted becomes `interrupted`/`effect-uncertain` on reopen and a later duplicate returns it; a recovery append failure fails the open. Verify they fail.
- [x] 6.2 Implement rewind (timeline cut plus replay, D3), `admit`/`complete`/`fail` as single queue operations (D4), and open-time request finalization; verify the 6.1 tests pass and flip the rows green.

## 7. Result store and handles

- [x] 7.1 Write failing tests:
  - a 50 MiB, 1,000,000-line stream in 64 KiB chunks stored byte-identical, with a probe proving no chunk is delivered before the previous one is written;
  - a producer error after 10,000 bytes finalizing a pageable prefix;
  - a storage failure (injected) returning `storageFailed` with bytes accepted and the temp path, and no final-name file;
  - handle resolution through the tree;
  - identical bytes from complete and failed producers in both orders, each keeping its own `complete` on its result reference;
  - unknown and broken handles.

  Verify they fail.
- [x] 7.2 Implement `lib/src/results/result_store.dart` (`ResultWrite` outcomes, SHA-256 content addressing, temp file then rename, dedupe, descriptor `{handle, sha256, bytes, lines}`, collision check) and handle resolution; verify the 7.1 tests pass and flip the rows green.

## 8. Fork

- [x] 8.1 Write failing tests: a fork at turn 2 survives parent deletion with every handle readable and the parent journal byte-identical beforehand; the fork keeps current `meta` with only `meta/session`, `meta/lineage` and `meta/requests` replaced, and `body` limited to turn 2; a missing parent result file makes the fork fail naming the handle with no child directory left. Verify they fail.
- [ ] 8.2 Implement `writer.fork(atTurn)` per D8 (queue-head acknowledged state, `.fork-<id>.tmp` directory, SHA-256-verified copies, a single origin record, rename into place, cleanup on failure); verify the 8.1 tests pass and flip the rows green.

## 9. Composer, paging and search

- [x] 9.1 Write failing composer tests: the exact `read` truncation line for 2,310 lines; no truncation line for 12 lines; `bash` head/tail 1–600, the `[… 9,000 lines omitted …]` marker and 9,601–10,000 on a 1,000-line budget; a 2 GiB newline-free line (generated on the fly into a temp result, not held in memory) cut with a `[line truncated: …]` marker within a bounded-allocation probe; `notrunc` within capacity, including a 5,000-character line, and over capacity with the exact error. Verify they fail.
- [x] 9.2 Implement `lib/src/results/line_scanner.dart` (64 KiB reads, retained prefix plus counted remainder) and `composer.dart` (envelope, default policies, `ceil(bytes/3)` heuristic estimate, `notrunc`); verify the 9.1 tests pass and flip the rows green.
- [x] 9.3 Write failing paging and search tests: `read_more` from 401 for 100 lines offering `from=501`; search returning 3 matches with line numbers; `from` beyond the last line; an invalid pattern; a catastrophically backtracking pattern timing out at 5 s; a line longer than 64 KiB stating its searched prefix; a burst of 5 concurrent searches where the 5th gets `search busy`, and after one times out a new search is admitted. Implement `reader.dart` and `search.dart` (worker isolate, 4 slots, 201-message cap, kill at deadline, slot freed in `finally`); verify they pass and flip the rows green.

## 10. Migration script

- [x] 10.1 Write failing tests in `test/tool/migrate_journal_test.dart` with a test-registered fixture migration `0 → 1`:
  - the original is preserved byte-identical as `journal.v0.jsonl`, the new journal opens at format 1, results are untouched, and the record counts are printed;
  - an outdated format with a 20-byte torn tail migrates its complete records, saves the torn bytes to `recovery/` and keeps the backup byte-identical;
  - an outdated open fails naming the command, an unregistered path fails, and neither changes any file;
  - an interrupted migration (`.migrating` plus a backup and no journal) is reported on open and completed by a rerun.

  Verify they fail.
- [x] 10.2 Implement `lib/src/session/migration.dart` (registry, record transformations, claim through the D5 protocol, torn-tail recovery, `.migrating` then renames) and `tool/migrate_journal.dart` (`--session`, `--to`, `--check`, exit codes per the `dart-build-cli-app` skill); verify the 10.1 tests pass and flip the rows green.

## 11. Randomized replay properties

- [ ] 11.1 Write `test/support/reference_model.dart` (a deep-copied snapshot per turn, rewind by snapshot pick, independent of D3) and `test/property/replay_property_test.dart`: 500 seeded histories by default (`KEHAI_PROPERTY_RUNS`, `KEHAI_PROPERTY_SEED`) mixing set/merge/del, new turns, rewinds, request admit/complete/duplicate, result stores and forks. Assert that the live tree, two disk materializations and the reference model are equal with byte-identical canonical serialization, plus torn-tail truncation at random byte offsets and interior byte flips. The failure message names the seed and index. Verify a deliberately injected rewind bug makes it fail with a reproducible seed, then remove the bug and flip both rows green.

## 12. Integration checks

- [ ] 12.1 Run `mise run check` (format, analyze with `--fatal-infos`, the full test suite) and `mise run openspec:validate` on native Windows; both pass.
- [ ] 12.2 Run the full test suite on Linux under WSL, the user-approved test runner (a runner only; Kehai itself stays native on Windows), to exercise the POSIX lock semantics behind the ownership tests. Copy the tree into the WSL ext4 filesystem rather than running from `/mnt/f`, and run with `--concurrency=1` so the run stays light. Record the command and result in the PR description. When the run finishes, pass or fail, delete the copied tree, its `.dart_tool`/pub cache additions made for this run, and every test temp directory under `/tmp`, then show `df -h ~` to confirm the space came back. If WSL is unavailable, stop and tell the user rather than marking this done.
- [ ] 12.3 Confirm with `rg -n "substring|take\(|truncat" lib/` that no code outside `lib/src/results/composer.dart` and `line_scanner.dart` cuts result text (ADR 0002); record the check output in the PR description.
