# Spec Delta

## Purpose

Lets the model read files as numbered lines with block content anchors, and change them only through edits whose anchors still match the file on disk. Every stale or moved anchor is rejected loudly.

## ADDED Requirements

### Requirement: Numbered read with block anchors
`read` SHALL render each line as `<n>:<text>`. Lines are grouped into blocks of 16 starting at line 1, and each block's first line is rendered `<n>#<HASH>:<text>`. HASH is the block's 4-hex anchor hash. Line endings and a UTF-8 BOM are not shown. A final newline does not add an empty line. The summary names the path, line count and dominant line ending.

#### Scenario: Read a 40-line file
- **WHEN** a 40-line LF file is read
- **THEN** lines 1, 17 and 33 are rendered `1#<HASH>:`, `17#<HASH>:` and `33#<HASH>:` followed by their text, every other line is `<n>:<text>`, and the result has exactly 40 lines

#### Scenario: Empty file
- **WHEN** a zero-byte file is read
- **THEN** the call settles `ok` with summary stating 0 lines and an empty body

#### Scenario: Path is not a readable text file
- **WHEN** `read` targets a missing path, a directory, or a file whose first 8 KiB contains a NUL byte
- **THEN** the call settles `error` with `no such file <path>`, `<path> is a directory; use ls`, or `binary file <path> (<bytes> bytes)` respectively

### Requirement: Anchor hash definition
A block's anchor hash SHALL be xxHash32 with seed 0 of the block's text, keeping the low 16 bits as 4 uppercase hex digits. The text is the block's lines with a leading BOM removed, CRLF and CR read as line ends, trailing spaces, tabs and CRs stripped from each line, then joined with `\n`. Line numbers are not hashed.

#### Scenario: Hash matches the reference vectors
- **WHEN** the anchor hash is computed for the published xxHash32 reference inputs and for a block whose lines differ only in trailing whitespace or CRLF versus LF endings
- **THEN** it equals the low 16 bits of the reference xxHash32 values, and the whitespace-only and line-ending variants hash identically

#### Scenario: Streamed hash equals the definition
- **WHEN** a block holds lines with interior and trailing runs of mixed spaces and tabs longer than 64 KiB, positioned so that runs, CRLF pairs and the BOM straddle read-chunk boundaries
- **THEN** each block's hash equals xxHash32 of that block's text built whole in memory per the definition, and the same file read with other chunk sizes gives the same hashes

#### Scenario: Content change in one block
- **WHEN** the recorded test vector's block 17 has one character changed inside line 20
- **THEN** block 17's hash equals that vector's recorded changed value, which differs from its original, and every other block's hash is unchanged

### Requirement: Read window snaps to blocks
`read` SHALL accept an optional 1-based `offset` and a `limit` in lines. A window starts at the start of the block containing `offset`, so every shown block carries its anchor. A file over 64 MiB read without `limit` is refused rather than cut. An offset past the last line is an error. Reading uses bounded memory whatever the line lengths.

#### Scenario: Offset inside a block
- **WHEN** a 100-line file is read with `offset` 20 and `limit` 10
- **THEN** the result starts at `17#<HASH>:` and ends at line 32, the end of the last block the window reaches, and its summary states `lines 17–32 of 100`

#### Scenario: Offset beyond the file or oversized file
- **WHEN** a 100-line file is read with `offset` 101, or a 70 MiB file is read without `limit`
- **THEN** the call settles `error` with `offset 101 beyond last line 100`, or `file is 70.0 MiB; read it with offset and limit`, and no body is stored

#### Scenario: One huge line
- **WHEN** a 2 GiB file with no newline is read with `limit` 1
- **THEN** the stored result holds the whole line with its anchor, the composer shows it cut at the per-line cap, and the read never holds more than 1 MiB of the file in memory

#### Scenario: Newline-dense file
- **WHEN** a 64 MiB file holding only `\n` bytes is read without `limit`, or with `limit` 100,000,000
- **THEN** the stored result has one rendered line per line of the file, with an anchor on every 16th, and the read's working memory stays under 1 MiB whatever the line count or `limit`

#### Scenario: File changes during a read
- **WHEN** the file's size or modification time changes between hashing its blocks and rendering them
- **THEN** the call settles `error` with `file changed during read; read it again`, and no result is recorded as `ok`

### Requirement: Anchored edit operations
`edit` SHALL take a path, the anchors of the blocks it touches, and operations on line numbers as last read: `replace` (start to end, inclusive), `insert` (after a line, 0 for the head) and `delete`. All line numbers refer to the file as read, not as shifted by earlier operations in the same call. Operations are applied bottom-up and written atomically.

#### Scenario: Replace and insert in one edit
- **WHEN** a file read with anchors `1#AAAA` and `17#BBBB` is edited with `replace` 3–4 and `insert` after 20, naming both anchors
- **THEN** both operations apply against the original numbering, the file is replaced in one rename, and the result re-renders the touched blocks of the new file with fresh anchors

#### Scenario: Overlapping or out-of-range operations
- **WHEN** an edit holds `replace` 5–8 and `delete` 7–9, or targets line 120 of a 100-line file
- **THEN** the edit is rejected with `operations overlap at lines 7–8` or `line 120 does not exist (file has 100 lines)`, and the file is unchanged

#### Scenario: Edit that changes nothing
- **WHEN** an edit's operations reproduce the file's current content exactly
- **THEN** the edit is rejected with `edit made no change` and the file is not rewritten

### Requirement: Stale and moved anchors rejected loudly
At mutation time `edit` SHALL re-read the file and recompute every touched block's hash. It rejects the whole edit, changing nothing, when a named anchor no longer matches the block at that line or names no block start. It also rejects an edit that leaves a touched block unnamed. It never remaps or guesses a new position.

#### Scenario: Line inserted above a block
- **WHEN** a file was read with anchor `17#BBBB`, someone then inserts one line at line 2, and an edit naming `17#BBBB` replaces line 18
- **THEN** the edit is rejected with `stale anchor 17#BBBB: lines 17–32 now hash <NEW>; read the file again`, and the file is byte-identical to before the edit

#### Scenario: Several stale anchors reported together
- **WHEN** an edit names `1#AAAA` and `33#CCCC` and both blocks changed on disk
- **THEN** the rejection lists both anchors with their current hashes and the file is unchanged

#### Scenario: Missing or malformed anchor
- **WHEN** an edit replaces lines 20–21 but names only `1#AAAA`, or names `18#BBBB`, which is not a block start
- **THEN** it is rejected with `no anchor for block 17 (lines 17–32)` or `18#BBBB is not a block anchor; blocks start at 1, 17, 33, …`, and the file is unchanged

### Requirement: Edit preserves untouched bytes
An edit SHALL leave every untouched line byte-identical, including its own line ending and the file's BOM. New lines take the ending of the line they replace or follow, else the file's first ending, else LF. The final-newline state is kept unless the edit changes the last line. Non-UTF-8 files are refused.

#### Scenario: CRLF file with one LF line
- **WHEN** a CRLF file with a BOM whose line 9 ends in LF has line 3 replaced
- **THEN** the BOM, the LF ending of line 9 and the CRLF endings of all other untouched lines are unchanged, and the new line 3 ends in CRLF

#### Scenario: Invalid UTF-8
- **WHEN** an edit targets a file containing invalid UTF-8 bytes
- **THEN** it is rejected with `<path> is not valid UTF-8; edit refused` and the file is unchanged

#### Scenario: File too large to edit
- **WHEN** an edit targets a 20 MiB file
- **THEN** it is rejected with `file too large to edit (20.0 MiB, limit 16 MiB)` and the file is unchanged

### Requirement: Atomic file replacement
`edit` and `write` SHALL write the new content to a temporary file in the target's directory, flush it and rename it over the target. The target keeps its permission bits. A failure at any step leaves the target unchanged and removes the temporary file.

#### Scenario: Write a new file
- **WHEN** `write` creates `tool/new/gen.dart` under a missing directory `tool/new`
- **THEN** the directory is created, the file holds exactly the given text, and the result states `created` with its bytes and lines

#### Scenario: Rename fails
- **WHEN** the rename over the target fails (for example the target is locked on Windows)
- **THEN** the call settles `error` naming the rename failure, the target is byte-identical to before, and no temporary file remains
