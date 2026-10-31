## ADDED Requirements

### Requirement: Permission prompt text
A permission prompt SHALL show the call's command or path, its working directory and its resolved target whole, never cut. A line feed in the command or path starts a new `  | ` line; in the directory or target it is written as `\u{A}`. Every other control character (C0, DEL, C1) and lone surrogate (U+D800 to U+DFFF) is written as `\u{XXXX}`, and a backslash that starts `\u{` as `\u{5C}`. Every other character is printed as itself.

#### Scenario: Non-ASCII path
- **WHEN** a permission prompt arrives for `write` `кафе.txt`
- **THEN** the client shows `permission: write кафе.txt`

#### Scenario: Terminal control in a command
- **WHEN** a permission prompt arrives for `bash` with the command `echo a` followed by ESC, `[2J` and `b`
- **THEN** the client shows `permission: bash echo a\u{1B}[2Jb`, and no escape character reaches the terminal

#### Scenario: Text that looks like an escape
- **WHEN** a permission prompt arrives for `bash` `printf '\u{1B}'`
- **THEN** the client shows `permission: bash printf '\u{5C}u{1B}'`, so it cannot be read as an escaped control character

#### Scenario: Multi-line command
- **WHEN** a permission prompt arrives for `bash` with the two-line command `cd lib` and `dart test`
- **THEN** the client shows `permission: bash`, then `  | cd lib` and `  | dart test`

#### Scenario: Line feed in a directory or target
- **WHEN** a permission prompt arrives for `bash` `./build.sh` with the working directory `vendor/x` line feed `y`, and one for `write` whose resolved target is `out/a` line feed `b`
- **THEN** the client shows `  in vendor/x\u{A}y` and `  -> out/a\u{A}b`, each on one line

#### Scenario: Lone surrogate
- **WHEN** a permission prompt arrives for `bash` whose command holds a lone U+D800 between `a` and `b`
- **THEN** the client shows `permission: bash a\u{D800}b`
