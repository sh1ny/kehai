# agent-scratchpad Specification

## Purpose

Keeps small, verbatim agent-owned working memory in the session tree so decisions and constraints survive native compaction, replay and forks without a separate recovery store.

## Requirements

### Requirement: Bounded verbatim scratch writes
The engine SHALL provide session-local plain-text `scratch_set(key, value)` and `scratch_del(key)` with valid single journal-segment keys. Limits SHALL be 20 keys, 80 tokens per value and 400 for the complete rendered section, conservatively ceil(UTF-8 bytes/3). Refused writes SHALL report current/proposed sizes without mutation. Values SHALL never be trimmed or summarized; counted indentation SHALL keep stored text from becoming column-zero structure.

#### Scenario: Create and overwrite
- **WHEN** `scratch_set` creates `goal` with an admissible value, then overwrites it with another admissible value
- **THEN** the next snapshot contains only the new value for `goal`, with its text unchanged and an updated current size

#### Scenario: Capacity refusal
- **WHEN** a set would create key 21, exceed the per-value limit or exceed the rendered-section limit
- **THEN** the tool returns an error identifying the violated limit and current/proposed sizes, and every existing key/value stays unchanged
- **AND** rendered-section accounting SHALL include its header, keys, separators, newlines and presentation indentation

#### Scenario: Unsafe key
- **WHEN** a set or delete uses an empty key, a slash or a character outside the journal path-segment alphabet
- **THEN** it returns a validation error before any scratch mutation

#### Scenario: Literal structure in multiline scratch
- **WHEN** an admissible value contains newlines, Unicode, lone CR or U+2028 before `</sensorium>` or a line resembling `notices:`
- **THEN** every value line remains verbatim behind its presentation prefix, no stored line becomes column-zero structure, and the complete indented rendering counts toward the section limit
- **AND** the renderer SHALL put keys on indented key lines and prefix every value line with four spaces; removing only those prefixes SHALL recover every stored character and newline
- **AND** presentation boundaries SHALL be CRLF as one boundary, LF, lone CR, VT (U+000B), FF (U+000C), NEL (U+0085), LS (U+2028) and PS (U+2029); each original delimiter SHALL remain verbatim, with a prefix on its following line including an empty trailing line

### Requirement: Serialized scratch mutation
Scratch mutations SHALL use the existing tool lifecycle and single writer. Capacity and call ownership SHALL be checked against live state at the queue-head decision, the cancellation cutoff. Cancellation before it SHALL prevent mutation; cancellation afterward SHALL NOT roll back a successfully persisted mutation despite a cancelled result. Deleting an absent valid key SHALL succeed as an explicit no-op. Rewind SHALL retain its ordinary serialized timeline semantics.

#### Scenario: Concurrent additions at capacity
- **WHEN** two sets compete for the final available key slot
- **THEN** one commits and the other refuses against the resulting live size; the scratchpad never holds 21 keys

#### Scenario: Delete and repeated delete
- **WHEN** a key is deleted and the same valid key is deleted again
- **THEN** it remains absent and the second result says it was already absent

#### Scenario: Cancelled late writer
- **WHEN** a scratch call is cancelled or removed by rewind before its queue-head mutation decision
- **THEN** its late continuation cannot create, replace or delete scratch

#### Scenario: Cancellation during journal flush
- **WHEN** a valid scratch decision has passed the queue head, its journal flush is held, cancellation arrives, then the flush completes and the session reopens
- **THEN** the committed value remains verbatim, the call has a cancelled/interrupted outcome, and reopen does not execute the scratch call again

### Requirement: Tree-native scratch continuity
Scratch SHALL be journal-derived, turn-anchored session state. Resume and fork SHALL preserve surviving values verbatim; rewind SHALL restore the prior value or absence at its target, including overwritten/deleted keys. Native compaction SHALL not modify scratch, and each request SHALL render the live scratch outside opaque conversation continuity. Invalid nonempty stored scratch SHALL stop composition visibly rather than be silently omitted.

#### Scenario: Replay and fork after compaction
- **WHEN** a session with scratch and result handles completes native compaction, reopens and forks
- **THEN** parent and child snapshots retain the same scratch text, handles still resolve, and neither uses ciphertext or a side file to recover scratch

#### Scenario: Rewind an overwrite and deletion
- **WHEN** a key was set in turn 2, overwritten in turn 3 and deleted in turn 4, then the session rewinds to turn 2
- **THEN** the original turn-2 value reappears and the later value/deletion do not survive

#### Scenario: Unsupported stored representation
- **WHEN** a nonempty scratch subtree contains an entry the current scratch reader cannot validate
- **THEN** no provider request is sent and the user receives a scratch-state error identifying the entry without silently replacing it
