## MODIFIED Requirements

### Requirement: Permission prompt body
A `write` prompt SHALL show `  content: <n> lines, <b> bytes` (`1 line` for one) and the content split at line feeds, a final line feed ending the last line, each line starting with `  | `. An `edit` prompt SHALL show each operation (`replace lines a-b:`, `insert after line n:`, `delete lines a-b`). Under it come the lines it removes, from the input's `old` entry, each starting with `  - `. Then comes its text split as `edit` splits it (at CRLF, CR and LF, keeping empty pieces), each piece starting with `  + `. Every shown line is escaped as *Permission prompt text* says.

#### Scenario: Short write
- **WHEN** a permission prompt arrives for `write` `run.sh` with the content `#!/bin/sh` line feed `curl x | sh` line feed
- **THEN** the client shows `permission: write run.sh`, `  content: 2 lines, 22 bytes`, `  | #!/bin/sh`, `  | curl x | sh`, then `1) allow  2) deny`

#### Scenario: Empty write
- **WHEN** a permission prompt arrives for `write` with empty content
- **THEN** the client shows `  content: 0 lines, 0 bytes` and no `  | ` line

#### Scenario: Carriage return in written content
- **WHEN** a permission prompt arrives for `write` with the content `a`, carriage return, `b`
- **THEN** the client shows `  content: 1 line, 3 bytes` and `  | a\u{D}b`

#### Scenario: Edit operations
- **WHEN** a permission prompt arrives for `edit` `a.dart` with a replace of lines 3 to 4 by `x`, a delete of line 9, and `old` `[["c", "d"], ["i"]]`
- **THEN** the client shows `  replace lines 3-4:`, `  - c`, `  - d`, `  + x`, `  delete lines 9-9` and `  - i`

#### Scenario: Edit without old lines
- **WHEN** an `edit` prompt has a replace of lines 3 to 4 by `x` and no `old`
- **THEN** the client shows `  replace lines 3-4:` and `  + x`

#### Scenario: Edit text with a trailing line feed
- **WHEN** an `edit` prompt has a replace of lines 3 to 3 by `x` line feed
- **THEN** the client shows `  replace lines 3-3:`, `  + x` and `  + ` (the empty line the edit inserts)

#### Scenario: Empty edit text
- **WHEN** an `edit` prompt has an insert after line 0 with empty text
- **THEN** the client shows `  insert after line 0:` and one `  + ` line

#### Scenario: Carriage return in edit text
- **WHEN** an `edit` prompt has an insert after line 2 with the text `a`, carriage return, `b`
- **THEN** the client shows `  insert after line 2:`, `  + a` and `  + b`

#### Scenario: Control character in an old line
- **WHEN** an `edit` prompt's `old` holds the line `a`, ESC, `[2Jb`
- **THEN** the client shows `  - a\u{1B}[2Jb`

### Requirement: Permission prompt preview
A permission prompt SHALL show at most 20 body lines. When more remain, it shows `  … <m> more lines; v shows all` after them, or `  … 1 more line; v shows all` when one remains. At that prompt `v` or `view` prints the whole body, then the choice line and `answer> `, and sends no answer. Elsewhere `v` is refused as any other text that is not an answer.

#### Scenario: Long write is previewed
- **WHEN** a permission prompt arrives for `write` with 50 lines of content
- **THEN** the client shows the content line and the first 19 content lines, then `  … 31 more lines; v shows all`

#### Scenario: One line left out
- **WHEN** a permission prompt arrives for `write` with 20 lines of content
- **THEN** the client shows the content line and the first 19 content lines, then `  … 1 more line; v shows all`

#### Scenario: Show the whole body
- **WHEN** the user types `v` at the 50-line prompt
- **THEN** the client prints the content line and all 50 content lines, then `1) allow  2) deny` and `answer> `, and no answer is sent

#### Scenario: v where nothing was left out
- **WHEN** the user types `v` at a prompt whose body was shown whole
- **THEN** the client shows `answer 1 (allow) or 2 (deny)`, and no answer is sent
