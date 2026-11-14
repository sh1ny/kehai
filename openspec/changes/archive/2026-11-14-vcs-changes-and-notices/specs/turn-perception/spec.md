# Spec Delta

## MODIFIED Requirements

### Requirement: Ordered self-contained perception
Snapshots SHALL follow source order: turn, budget, vcs, changes_since_last_turn, diagnostics, tests, processes, plan, scratch, checkpoints, notices. They SHALL default to self-contained `full` mode, preserving unchanged facts without earlier blocks, with honest availability and counted verbatim scratch presentation.

#### Scenario: Unchanged memory after earlier block removal
- **WHEN** scratch is unchanged across successive requests and the earlier generated block is absent from the new input
- **THEN** the new block is marked `full` and still contains all current scratch text
- **AND** full fallback SHALL preserve facts after compaction, resume, fork and rewind; delta-only-since-full SHALL NOT discard the only available baseline
- **AND** scratch SHALL preserve all stored text behind counted per-line presentation indentation

#### Scenario: Known jobs but unavailable collectors
- **WHEN** a shell job is live, VCS collection succeeded, and diagnostics collection is not implemented in this milestone change
- **THEN** processes describes the real tree-owned job and vcs describes the collected repository, while diagnostics explicitly says unavailable, not zero errors
- **AND** live processes SHALL use tree-owned state; logs SHALL explicitly say unavailable because result references publish at exit, without tail I/O or a new live-log producer

#### Scenario: Unchanged VCS facts every request
- **WHEN** the working copy is unchanged between two requests
- **THEN** the second block still carries the full `vcs` section and `changes_since_last_turn: none`, not an omitted section

#### Scenario: Empty versus failed
- **WHEN** the supported job projection has no live jobs and another supplied collector observation has failed
- **THEN** processes says `none` and the failed section says unavailable with its reason or stale with its last known observation
- **AND** every supported empty section SHALL say `none`; every unavailable section SHALL name why

#### Scenario: Concurrent recovery notices
- **WHEN** compaction recovery and ignored legacy-window notices both apply
- **THEN** both bounded notice codes fit within the notice allocation without duplicating the separate recovery message or refusing composition
- **AND** notices SHALL use bounded codes and the existing compaction recovery message SHALL retain its separate request placement

## ADDED Requirements

### Requirement: Bounded notice vocabulary
Notices SHALL be drawn from a fixed code set: `compaction_recovery`, `legacy_window_ignored`, `vcs_timeout`, `vcs_failed`, `user_edits` and `baseline_reset`. Each code appears at most once per block, in that fixed order. A set that exceeds the notice allocation SHALL end with an explicit `… +N more` and SHALL NOT refuse composition.

#### Scenario: Every code at once
- **WHEN** all six notice conditions apply to one request
- **THEN** the notices section fits its 80-token allocation, lists each applicable code once in fixed order, and composition succeeds

#### Scenario: No notice applies
- **WHEN** no notice condition applies
- **THEN** the section reads `notices: none`

#### Scenario: Repeated condition
- **WHEN** two files are attributed `by: user` in the same request
- **THEN** `user_edits` appears exactly once

### Requirement: Collected observations are admitted, not recomputed
The admitted step observation SHALL record the VCS observation, its availability state and the change baseline used to render that request's block. Clients reconnecting later SHALL see that recorded data. Current status previews SHALL NOT be stored as step observations.

#### Scenario: Reconnect after the working copy changed
- **WHEN** a step was admitted with `M 2` and the user later edits three more files before a client reconnects
- **THEN** that step's observation still shows `M 2` and its recorded baseline, not the current working copy

#### Scenario: Status preview
- **WHEN** a client requests read-only status between requests
- **THEN** status collects a current VCS preview under the same deadline, writes no journal record and records no baseline
