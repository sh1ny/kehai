# result-store Specification

## Purpose

Keeps every accepted result whole and truncates only once, centrally, at projection time with an explicit marker. The model and other views can then page or search the full result through a handle, without re-running anything.

## Requirements

### Requirement: Immutable full-result bytes
Accepted result bytes SHALL be stored whole in an immutable, content-addressed file in the session directory. Bytes are written as they arrive, and the store does not request the next producer chunk until the previous one is written. The file is complete and flushed before any record references it. No component other than the projection composer may cut, drop or rewrite result bytes.

#### Scenario: Large result stored whole
- **WHEN** a 50 MiB (52,428,800-byte), 1,000,000-line byte stream is delivered in 64 KiB chunks and stored as a result
- **THEN** the stored file is byte-identical to the input, its descriptor reports 52,428,800 bytes and 1,000,000 lines, the write is reported complete, and at no point has the producer delivered a chunk before the previous chunk was written

#### Scenario: Producer fails after emitting output
- **WHEN** the producer's byte stream delivers 10,000 bytes and then errors
- **THEN** the store finalizes the 10,000 persisted bytes under their content address and returns its descriptor, reported incomplete, together with the producer error, so the caller can record the call as `partial` or `error` with `complete: false` on its own result reference and page the accepted bytes through the handle

#### Scenario: Storage fails during write
- **WHEN** a disk write, flush or rename fails partway
- **THEN** the store returns a storage error stating the bytes accepted so far and the temporary file path, returns no descriptor, leaves no file under a final content-addressed name, and stops reading the producer

### Requirement: Tree-held result descriptors and handles
Each stored result SHALL be referenced by a descriptor node in the tree under `results/`. The descriptor holds only facts about the bytes: a handle `r/<id>`, the content hash, the byte count and the line count. Whether a producer completed belongs to each result reference that cites the handle, not to the descriptor. Handle resolution goes only through the current tree, so a rewound-away descriptor is unknown.

#### Scenario: Handle resolves through the tree
- **WHEN** a result is stored in turn 2 and its handle is resolved in turn 4
- **THEN** resolution returns the descriptor with matching hash, bytes and lines, and paging reads its bytes

#### Scenario: Identical bytes from a complete and a failed producer
- **WHEN** one call's producer emits `abc` and completes and another call's producer emits `abc` and then errors, in either order
- **THEN** both reference the same handle, the descriptor is unchanged by the second store, the first call's result reference records `complete: true` and the second's `complete: false`

#### Scenario: Unknown or broken handle
- **WHEN** a handle is resolved after a rewind removed its descriptor, or its bytes file is missing or has the wrong size
- **THEN** resolution fails with `unknown handle r/<id>` or `result bytes missing for r/<id>` respectively, and no partial content is returned as success

### Requirement: Central truncation envelope
The composer SHALL be the only place that renders a result for the model. It uses one envelope: header `[<tool> <status>] <summary>` (status `ok`, `error`, `partial`, `denied` or `timeout`), then the body. When cut, a final line states the range shown, the total and how to page via the handle. A result that fits carries no truncation line.

#### Scenario: Read result over the line cap
- **WHEN** a `read` result of 2,310 lines with handle `r/7f3a9c1b2d4e` is composed with the default cap
- **THEN** the body holds lines 1–400 and the last line is exactly `[truncated: showing lines 1–400 of 2,310; handle r/7f3a9c1b2d4e; read_more(r/7f3a9c1b2d4e, from=401)]`

#### Scenario: Result that fits has no truncation line
- **WHEN** a 12-line `read` result is composed
- **THEN** the output is the header plus all 12 lines, and no line begins with `[truncated:`

### Requirement: Head and tail cut for logs
For `bash` results over the cap, the composer SHALL keep whole lines from the start within 60% of its budget and from the end within 40%. A marker line `[… <N> lines omitted …]` sits at the cut, and the truncation line states both shown ranges and the total.

#### Scenario: Long log keeps head and tail
- **WHEN** a 10,000-line `bash` result is composed with a 1,000-line budget
- **THEN** the body shows lines 1–600, then `[… 9,000 lines omitted …]`, then lines 9,601–10,000, and the truncation line states `showing lines 1–600 and 9,601–10,000 of 10,000`

#### Scenario: Over-long single line
- **WHEN** a result holds one 2 GiB line without any newline and is composed
- **THEN** that line is cut at the per-line character cap and ends with `[line truncated: showing <shown> of <total> chars]`, the total line count is 1, and composing never holds more than the cap plus one read buffer of that line in memory

### Requirement: Explicit opt-out bounded by capacity
A call marked `notrunc` SHALL be composed in full, with no line or per-line cut, when its estimated size is within the capacity the caller supplies. Otherwise composing fails explicitly. The estimate is a heuristic pre-check: it never silently cuts and is not proof the provider will accept the request.

#### Scenario: notrunc within capacity
- **WHEN** a 3,000-line `read` result containing one 5,000-character line is composed with `notrunc` and a capacity larger than its estimate
- **THEN** all 3,000 lines are shown, the long line in full, and there is no truncation line of either kind

#### Scenario: notrunc over capacity
- **WHEN** a result's estimate exceeds the supplied capacity under `notrunc`
- **THEN** composing fails with `notrunc result of <estimate> tokens exceeds capacity <capacity>; use read_more` and no partial body is produced as success

### Requirement: Paging and search over stored results
`read_more(handle, from, lines)` SHALL return the requested lines from stored bytes, capped like a `read`, with a truncation line when more remain. `search_result(handle, pattern)` SHALL return matching lines as `<line>: <text>`, capped with an explicit `… +<N> more` line, within a time limit and a limit on concurrent searches. Each line is matched only within a bounded prefix, which the result states. Neither re-runs anything.

#### Scenario: Page and search a stored result
- **WHEN** `read_more(r/<id>, from=401, lines=100)` and `search_result(r/<id>, "FAIL")` run against a 2,310-line result with 3 matching lines
- **THEN** paging returns lines 401–500 with a truncation line offering `from=501`, and search returns exactly the 3 matching lines with their line numbers and no `more` line

#### Scenario: Out-of-range page or invalid pattern
- **WHEN** `read_more` is called with `from` beyond the last line, or `search_result` with an invalid regular expression
- **THEN** the call fails with `from <n> beyond last line <m>` or `invalid pattern: <reason>`, and returns no body

#### Scenario: Pathological pattern or huge line
- **WHEN** `search_result` runs a catastrophically backtracking pattern, or a result line is longer than the per-line search prefix
- **THEN** the search stops at its time limit with `search timed out after <limit>; narrow the pattern` and no match list presented as complete, or the output states `line <n> searched first <prefix> of <total> bytes`

#### Scenario: Search burst over the concurrency limit
- **WHEN** more searches than the concurrency limit are started at once, and one running search then times out
- **THEN** each excess search fails immediately with `search busy` without starting a worker, and after the timeout a new search is admitted
