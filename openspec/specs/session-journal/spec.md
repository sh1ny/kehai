# session-journal Specification

## Purpose

Defines how a Kehai session is durably persisted: one append-only journal of four-field property records. It has a single writer, explicit crash recovery and an explicit migration path, so the session tree can always be rebuilt from it.

## Requirements

### Requirement: Four-field journal records
Each session SHALL persist its history as one UTF-8 JSONL journal in which every line is one JSON object with exactly the keys `turn`, `path`, `op` and `value`. `turn` is a non-negative integer, `path` a string, `op` a string from the operation vocabulary and `value` any JSON value. A line ends with a single newline, which marks the record as committed.

#### Scenario: Appended record has exactly four fields
- **WHEN** the engine appends a property update setting `body/t1/user` to `{"text":"hi"}` in turn 1
- **THEN** the journal's last line parses to an object whose key set is exactly `turn`, `path`, `op`, `value`, with `turn` 1, `path` `body/t1/user`, `op` `set` and `value` `{"text":"hi"}`, followed by one newline

#### Scenario: Record with an extra or missing field is rejected
- **WHEN** a journal line holds `{"turn":1,"path":"body/x","op":"set","value":1,"id":"a"}` or omits `value`
- **THEN** opening the session fails with an error naming the line number and byte offset and the reason `invalid record`, and no record is appended

### Requirement: Operation vocabulary
The journal SHALL accept exactly four operations. `set` replaces the value at a path, creating missing parent maps. `merge` sets the given keys on a map at a path, creating it when absent. `del` removes an existing path and its subtree. `rewind` restores turn-anchored state to the end of an earlier turn. Any other `op` is invalid.

#### Scenario: Each operation updates the tree
- **WHEN** records `set body/a = {"x":1}`, `merge body/a = {"y":2}`, `del body/a/x` are applied in order
- **THEN** the materialized value at `body/a` is `{"y":2}`

#### Scenario: Invalid operation use is rejected before append
- **WHEN** the engine is asked to apply `op` `patch`, `del` of a path that does not exist, or `merge` onto a path holding a non-map value
- **THEN** the request fails with an error naming the op and path, and the journal's byte length is unchanged

### Requirement: Path identity
A path SHALL be a `/`-separated list of 1 to 32 segments. Each segment is 1 to 128 characters from `A-Z a-z 0-9 _ . : -`. The first segment names a top-level subtree from the format version's root set (`meta`, `body`, `scratch`, `checkpoints`, `jobs`, `collectors`, `results`). The empty path denotes the root and is valid only for the origin record and for `rewind`.

#### Scenario: Valid path addresses one node
- **WHEN** the engine sets `body/t3/calls/c1:read/status` to `"running"`
- **THEN** the materialized tree holds `"running"` at that exact nested location and nowhere else

#### Scenario: Malformed path is rejected
- **WHEN** a set targets `body//x`, `unknown/x`, `body/a b`, or a 33-segment path
- **THEN** the request fails with `invalid path` naming the offending segment or rule, and nothing is appended

### Requirement: Validate, persist, append, then publish
The engine SHALL validate each record against the current tree before writing. It persists any result bytes the record references, then durably appends the record (written and flushed to stable storage). Only then does it publish the change to subscribers or acknowledge it to the caller. A failure at any step leaves the tree and subscribers unchanged.

#### Scenario: Acknowledged record survives a crash
- **WHEN** an append is acknowledged and the process is then killed
- **THEN** reopening the session materializes a tree containing that record's effect

#### Scenario: Storage failure is not published
- **WHEN** the durable append fails (for example the disk is full or the file is read-only)
- **THEN** the caller receives a storage error, subscribers receive no update for that record, the in-memory tree equals its state before the request, and further appends are refused until the session is reopened

### Requirement: Single writer per session
At most one writer SHALL hold a session open at a time, across processes and across isolates or openers in the same process. A second opener is refused without disturbing the holder's lock. An owner left behind by a dead process is taken over only after the operating system confirms no live process holds the session.

#### Scenario: Second writer is refused
- **WHEN** a second open-for-write of the same session directory is attempted from another process, from another isolate in the same process, or twice from one isolate
- **THEN** it fails with `session locked` naming the session directory and the holder's process id, the first writer can still append, and a third process is still refused afterwards

#### Scenario: Concurrent openers race
- **WHEN** two isolates of one process and one other process all open the same session for writing at the same moment
- **THEN** exactly one open succeeds and the others fail with `session locked`

#### Scenario: Takeover race inside one process
- **WHEN** two isolates of one process both read a dead process's owner record, one completes the takeover, and the other then continues its takeover
- **THEN** the second isolate fails with `session locked` naming this process, and only the first holds the session

#### Scenario: Close racing a reopen
- **WHEN** a writer in one process is closing, another isolate of that process opens the session for writing during the close, and a second process then opens it too
- **THEN** at every moment at most one writer holds the session, and the second process succeeds only if no other writer is open at that point

#### Scenario: Crash while changing ownership
- **WHEN** a process is killed after creating the ownership gate but before writing its content, and the session is then opened for writing
- **THEN** after the 2 s gate wait the open fails with `session gate held by pid unknown` naming the gate file to remove, and after the user removes it the open succeeds

#### Scenario: Dead owner is taken over
- **WHEN** a writer process is killed while holding a session, and the session is then opened for writing
- **THEN** the open succeeds and reports that it replaced the owner record of the dead process

### Requirement: Read-only materialization is observational
Read-only materialization SHALL not require the writer lock. While a writer is active it SHALL report its result as observed, not acknowledged, because a record may be on disk before its flush completes. Operations that need acknowledged state, such as fork, SHALL take it from the writer.

#### Scenario: Read-only materialization alongside a writer
- **WHEN** one engine holds a session open for writing and a test materializes the same session read-only
- **THEN** the read-only materialization returns the tree of the complete records on disk, marked `observed` with the writer active, without error

#### Scenario: Record visible before a failed flush
- **WHEN** a record is written, a reader materializes before the flush completes, and the flush then fails
- **THEN** the reader's result is marked `observed`, the writer reports a storage error and publishes nothing for that record, and a fork taken through the writer does not contain the record

### Requirement: Bounded writer admission and subscribers
The writer SHALL accept at most a fixed number of pending operations and reject more with `writer busy`, without queueing them. Each update subscriber SHALL have a bounded buffer. A subscriber that falls behind is disconnected with `resync required` and its last delivered offset. The writer never waits on a subscriber.

#### Scenario: Burst within the bound
- **WHEN** 32 callers submit operations concurrently
- **THEN** all 32 are appended in one order, and each subscriber receives 32 updates in that order

#### Scenario: Queue full or slow subscriber
- **WHEN** more operations than the pending bound are submitted at once, or a paused subscriber's buffer fills
- **THEN** the excess operations fail immediately with `writer busy` and append nothing, or that subscriber's stream ends with `resync required` and its last delivered offset while appends and other subscribers continue

### Requirement: Torn trailing record recovery
A final journal line without its terminating newline is uncommitted. Read-only materialization SHALL ignore it and report its byte count. Opening for write SHALL first copy the torn bytes into a recovery file in the session directory, then truncate the journal to the last newline. It SHALL report the recovery file's path and byte count.

#### Scenario: Torn tail is preserved and truncated on write open
- **WHEN** a journal ends with 37 bytes of a partial record after the last newline, and the session is opened for writing
- **THEN** a recovery file holds exactly those 37 bytes, the journal ends at the last newline, the open result reports a torn tail of 37 bytes with the recovery file path, and the tree equals the materialization of the complete records

#### Scenario: Valid JSON without newline is still torn
- **WHEN** the final line is a complete, valid record lacking the trailing newline
- **THEN** it is treated as torn: excluded from the tree and moved to the recovery file on write open

### Requirement: Interior corruption stops writes
A newline-terminated line that is not a valid record, or a record that cannot be applied to the tree it follows, SHALL make the session unwritable. Opening for write fails, and read-only materialization fails rather than skipping the line. The error names the line number, byte offset and reason. The journal file is not modified.

#### Scenario: Corrupt interior line
- **WHEN** line 5 of a 10-line journal is replaced with `{"turn":1,"path":` followed by a newline
- **THEN** both read-only materialization and open-for-write fail with an error naming line 5 and its byte offset, and the journal's bytes are unchanged

#### Scenario: Unappliable interior record
- **WHEN** a committed line is a well-formed `del body/missing` whose path does not exist at that point in history
- **THEN** opening fails naming that line and the reason `path not found`, and nothing is appended

### Requirement: Explicit journal migration
The journal format version SHALL be recorded in the tree at `meta/format`. A separate migration command SHALL rewrite a session journal to a target version by applying registered per-record transformations. It keeps the original journal under a versioned name, writes the new journal atomically and executes no recorded provider, tool or workspace effect. Opening a session whose format is not current SHALL fail and name the migration command.

#### Scenario: Migration preserves the original
- **WHEN** the migration command migrates a session from a registered older format to the current one
- **THEN** the original journal exists byte-identical under its versioned name, the new journal opens at the current format, result files are untouched, and the command prints the old and new record counts

#### Scenario: Outdated format with a torn tail
- **WHEN** a session in a registered older format ends with a 20-byte torn record and the migration command runs
- **THEN** the original journal, torn bytes included, is preserved byte-identical under its versioned name, the 20 torn bytes are saved in a recovery file, the new journal holds the migrated complete records only, and the command reports the torn-tail recovery

#### Scenario: Unsupported or outdated format
- **WHEN** a session whose `meta/format` is older than current is opened, or the migration command is given a format with no registered path
- **THEN** opening fails with `format <n> requires migration` naming the command, or the command fails with `no migration from <n> to <m>`, and no file is changed
