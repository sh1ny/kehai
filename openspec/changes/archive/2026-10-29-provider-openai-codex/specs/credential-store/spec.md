# Spec Delta

## Purpose

Keeps provider credentials in platform-secure storage outside every session, so a login survives restarts without credentials ever entering the session tree, result bytes or logs.

## ADDED Requirements

### Requirement: Platform credential backend
Credentials SHALL be stored by exactly one backend chosen by platform:
- **Windows:** a file under the Kehai home whose contents are encrypted with DPAPI for the current user.
- **Linux and macOS:** a JSON file under the Kehai home with mode `0600`, inside a directory with mode `0700`.

The Kehai home is `~/.kehai`, or `KEHAI_HOME` when set. No other backend or location is used.

#### Scenario: Unix file is private
- **WHEN** a login stores credentials on Linux
- **THEN** `<kehai home>/auth.json` exists with mode `0600`, its directory has mode `0700`, and the file parses as JSON with `version` equal to `1` and holds the host id, the registration and the token set

#### Scenario: Windows file is encrypted
- **WHEN** a login stores credentials on Windows
- **THEN** the credential file exists, its bytes do not contain the access or refresh token text, and decrypting it as the same user yields the stored credentials

#### Scenario: Wrong DPAPI entropy cannot decrypt
- **WHEN** the Windows credential file's bytes are decrypted as the same user with an entropy value other than the one Kehai used to write them
- **THEN** decryption fails and the load reports `credentials unreadable` without exposing any token text

### Requirement: Credential record parts
The stored record SHALL hold a host id and a credential generation, and optionally a client registration (issued client id, account subject, email, plan-usage state) and a token set (id, access and refresh tokens, expiry, granted scopes). A token set is stored only while plan usage is enabled. The user is logged in only while a token set is stored.

#### Scenario: Logged in only with a token set
- **WHEN** the record holds a host id and a registration not marked plan usage disabled, but no token set
- **THEN** `kehai doctor` reports `not logged in`, and a model request fails with `reauth required` without a backend request. A registration marked plan usage disabled reports and fails as provider-auth *Plan usage consent* defines (`not permitted`, naming `kehai login openai --enable-plan-usage`)

### Requirement: Fail closed without a secure backend
When the platform's secure backend cannot be used, Kehai SHALL refuse to store or load credentials, rather than fall back to a less protected form. Examples: DPAPI fails on Windows, or a file mode cannot be set or verified on Unix.

#### Scenario: Unix permissions too open
- **WHEN** `auth.json` exists with any group or other permission bit set
- **THEN** loading fails with an error naming the file and its mode and telling the user to run `chmod 600`, and no token is read into memory

#### Scenario: Unsafe Unix home or link
- **WHEN** on Unix the Kehai home is a symbolic link, or has any group or other permission bit set, or `auth.json` is a symbolic link or not a regular file
- **THEN** loading and storing both fail with an error naming the path and the problem, no credential bytes are read, and nothing is written

#### Scenario: Secure write unavailable
- **WHEN** the backend cannot create the file with the required protection (for example, the encryption call or the mode-setting call fails)
- **THEN** the store fails with `secure credential storage unavailable`, no credential file is written or left behind, and the login command exits non-zero

### Requirement: Trusted credential home path
On Unix, before any credential read, write, or lock creation or acquisition, Kehai SHALL resolve the home to its canonical path. The home SHALL be owned by the current user. Every ancestor SHALL be owned by root or the current user, and SHALL have no group or other write permission unless it is root-owned with the sticky bit set. Otherwise Kehai refuses. Later operations use the canonical path.

#### Scenario: Home beneath a shared writable parent
- **WHEN** `KEHAI_HOME` names a directory whose parent is writable by group or others and has no sticky bit
- **THEN** login, refresh, logout and doctor fail with an error naming that parent and its mode, no credential file is read or written, and no lock file is created

#### Scenario: Home reached through a symlinked ancestor
- **WHEN** `KEHAI_HOME` passes through a symbolic link to a directory whose ancestors are all trusted
- **THEN** the canonical path is validated and used for the credential file and the lock, and storing and loading succeed

#### Scenario: Sticky shared parent
- **WHEN** an ancestor is root-owned and world-writable with the sticky bit set (for example `/tmp`), and the home itself is private and owned by the current user
- **THEN** that ancestor is accepted

#### Scenario: Ancestor owned by another user
- **WHEN** an ancestor of the canonical home is owned by a user other than root and the current user, even with mode `0755`
- **THEN** every credential operation fails with an error naming that ancestor and its owner, and no credential file is read or written and no lock file is created

#### Scenario: Sticky parent owned by another user
- **WHEN** an ancestor is world-writable with the sticky bit set but owned by a user other than root and the current user
- **THEN** that ancestor is rejected, with the same outcome as above

#### Scenario: Home owned by another user
- **WHEN** the home directory is owned by a user other than the current user
- **THEN** every credential operation fails, naming the home and its owner

### Requirement: Atomic credential replacement
Writing credentials SHALL replace the whole stored record atomically. A reader SHALL observe either the previous complete record or the new one. A write that fails SHALL leave the previous record intact.

#### Scenario: Successful replacement
- **WHEN** a refresh writes a record with a new access token
- **THEN** the next load returns the new access token and no temporary file remains in the Kehai home

#### Scenario: Interrupted write
- **WHEN** a write fails after the temporary file was created but before it replaced the record
- **THEN** the next load returns the previous record unchanged, and the temporary file is removed or ignored

### Requirement: Cross-process credential lock
Every operation that reads credentials in order to replace them SHALL hold one exclusive lock in the Kehai home for the whole operation, so two Kehai processes never interleave their read and write. Refresh and logout are such operations. The lock SHALL be held only for the operation and released on failure.

#### Scenario: Two processes refresh at once
- **WHEN** two Kehai processes both find the access token expired and refresh at the same time
- **THEN** exactly one refresh request reaches the token endpoint, and both processes end up using the same newly stored access token

#### Scenario: Holder dies
- **WHEN** a process holding the credential lock is killed
- **THEN** the next Kehai process acquires the lock without manual cleanup and loads the last complete record

### Requirement: Credentials never leave the boundary
Access, refresh and id tokens, authorization codes, PKCE verifiers, `nonce` and `state` values and `Authorization` header values SHALL appear only in the credential backend and in requests to the verified auth and model endpoints. They SHALL NOT appear in any session journal, result bytes, error message, log line, command output or subprocess environment. One exception: the authorize URL, carrying `state` and `nonce`, is printed once and passed to the browser launcher as its argument.

#### Scenario: Doctor output is token-free
- **WHEN** `kehai doctor` runs with valid credentials
- **THEN** its stdout and stderr contain none of the stored token strings

#### Scenario: Authorize URL handoff
- **WHEN** a login prints the authorize URL and starts the browser launcher, and then fails with a state mismatch
- **THEN** the URL with its `state` and `nonce` appears exactly once on stdout and as the launcher's argument, and no other output line, error message or launcher environment contains the `state`, `nonce`, PKCE verifier or received code

#### Scenario: Rejected pasted URL is not echoed
- **WHEN** the user pastes a redirect URL with a code for another address
- **THEN** the rejection message names the expected prefix and contains none of the pasted text

#### Scenario: Subprocess environment is token-free
- **WHEN** Kehai starts any subprocess (for example the browser launcher)
- **THEN** the subprocess environment contains none of the token strings

### Requirement: Locally composed failure text
Every auth or provider failure shown to the user or handed to a caller SHALL be composed only from a Kehai message template, the HTTP status, a server error code matching `^[a-z0-9_.]{1,64}$` and a server error parameter matching `^[A-Za-z0-9_.\[\]]{1,64}$`. A code that fails its pattern or contains a current secret becomes `unrecognized`; such a parameter is dropped. Server message text (including `detail` fields), bodies and headers SHALL NOT be relayed.

#### Scenario: Failure messages are token-free
- **WHEN** a token exchange, refresh or model request fails, and the server's response body echoes the submitted access token, refresh token, id token, authorization code or PKCE verifier in its message, error code or any other field
- **THEN** the reported error is built only from a Kehai message template, the HTTP status and an error code that passed validation, and it contains none of those strings

#### Scenario: Server message is not relayed
- **WHEN** a failing response carries a human-readable `message` field
- **THEN** that text does not appear in the reported error or in any failure value handed to a caller

#### Scenario: Suspicious error code
- **WHEN** a failing response's error code contains uppercase letters, exceeds 64 characters, or equals or contains a current token string
- **THEN** the reported code is `unrecognized`

### Requirement: Logout clears stored tokens
`kehai logout openai` SHALL remove the stored token set under the credential lock, keeping the host id and the client registration. `kehai logout openai --forget` SHALL also remove the registration, whether or not a token set is stored. Both SHALL succeed when nothing is left to remove. Remote revocation is defined by provider-auth *Logout revokes the session*.

#### Scenario: Logout with credentials
- **WHEN** the user runs `kehai logout openai` after logging in
- **THEN** the stored record holds no token set but keeps its host id and registration, and `kehai doctor` reports `not logged in`

#### Scenario: Logout without credentials
- **WHEN** the user runs `kehai logout openai` with no stored token set
- **THEN** it prints `not logged in`, exits zero, sends no revocation request, and advances the stored generation when a record exists

#### Scenario: Forget the registration
- **WHEN** the user runs `kehai logout openai --forget` while logged in
- **THEN** the refresh token is revoked, and the stored record keeps only its host id and generation, so the next login registers a new client

#### Scenario: Forget after logout
- **WHEN** the user runs `kehai logout openai` and then `kehai logout openai --forget`
- **THEN** the second command sends no revocation request, removes the registration, exits zero, and the stored record keeps only its host id and generation
