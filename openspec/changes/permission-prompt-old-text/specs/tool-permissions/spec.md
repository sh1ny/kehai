## ADDED Requirements

### Requirement: Edit prompts show the lines they remove
When the gate prompts for an `edit`, it SHALL read the file as `edit` reads it and add `old` to the prompt input: one entry per operation, in `ops` order. A `replace` or `delete` whose lines all exist gets those lines, without terminators; every other entry is null. When the file cannot be read as `edit` reads it, or two `replace` or `delete` ranges overlap, the input has no `old`, so `old` never holds more lines than the file.

#### Scenario: Replace and delete show the old lines
- **WHEN** an `edit` of a file holding `a`, `b`, `c`, `d` (each ending in a line feed) prompts with a replace of lines 2 to 3 and an insert after line 4
- **THEN** the prompt input has `old` `[["b", "c"], null]`

#### Scenario: Line numbers past the end
- **WHEN** an `edit` prompt has a delete of lines 9 to 9 of a 4-line file
- **THEN** its `old` entry is null, and `edit` refuses the call later, as it does now

#### Scenario: Overlapping operations
- **WHEN** an `edit` prompt has 1,000 deletes of lines 1 to 4 of a 4-line file
- **THEN** the prompt input has no `old`, and `edit` refuses the call later with `operations overlap at lines 1–4`, before any effect

#### Scenario: File not readable as text
- **WHEN** the file an `edit` prompt names does not exist, is not valid UTF-8 or is over 16 MiB
- **THEN** the prompt input has no `old`

### Requirement: Edit approval is bound to the file shown
When the user allows an `edit` whose file the gate read, the permission record SHALL carry `sha256`, the hex SHA-256 of the bytes read. When `edit` reads the file to apply the call, it refuses the call with envelope status `denied` and `the file changed after it was approved; ask again` if the bytes it read hash differently. A change after that read is caught only by the size and modification time check every atomic write already makes. A record without `sha256` adds no check.

#### Scenario: File changed after approval
- **WHEN** the user allows an `edit` and the file is changed before the edit runs
- **THEN** the call settles `denied` with `the file changed after it was approved; ask again`, and the file keeps the other change

#### Scenario: Unchanged file
- **WHEN** the user allows an `edit` and the file is unchanged when it runs
- **THEN** the edit applies, and the call's `permission` records `sha256`
