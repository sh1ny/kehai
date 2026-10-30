# Proposal

## Why

Kehai can store a session and talk to a model, but it cannot yet act on a workspace. Change 4's agent loop needs tools that read and edit files, run the project's real commands, search the tree and ask the user a question. Every one of them must run under one job lifecycle that survives rewind, resume and Ctrl-C ([ADR 0003](../../../docs/adr/0003-unified-job-lifecycle.md)). ADR 0003 assigns the supervisor, the rewind reconciler and the resume finalization of jobs to this change, because change 1's rewind ran before any job existed.

This is change 3 of 6 in milestone **M1 — self-hosting skeleton** ([roadmap](../../roadmap.md)). It advances three agent-verified exit criteria:

- *Read files, hash-anchor edit, run `dart test`, `dart analyze` and `jj` through bash, grep/find the tree, and ask a structured question.*
- *Every tool result uses central truncation/full-result handles, never tool-local cuts.* Change 1 proved the property-test half.
- *A hung hook process (test fixture) cannot block turn progress.*

## What Changes

- **Tool runtime.**
  - **Roster:** a fixed, versioned tool roster exposed as provider `ToolSpec`s (`read`, `edit`, `write`, `bash`, `grep`, `find`, `ls`, `ask`, `job`, plus the existing `read_more` and `search_result` over stored results).
  - **Call node:** each call is a tree node with `status` (`pending` → `running` → `settled` | `failed` | `cancelled`), `input` and a result reference `{handle, complete}`.
  - **Arguments:** validated against the tool's schema before anything runs.
  - **Output:** every tool streams its full output into the result store. Only the central composer renders it for the model, using the change 1 envelope and caps. No tool cuts output.
  - **Parallelism:** independent calls of one turn run in parallel, within an admission bound.
- **`read`.** Returns `N:TEXT` lines in the Hashline style. The first line of every 16-line block carries the block's anchor (`17#9C01:TEXT`), a 4-hex content hash of that block.
  - **Hash:** the xxHash32/normalization rules of oh-my-pi's hashline at the pinned revision, applied per block instead of per file, as the roadmap's "anchor every N lines" requires. The user chose this on 2026-10-29.
- **`edit`.** Targets line ranges as read and names the anchor of every block it touches. It re-reads the file at mutation time. Any anchor whose block no longer hashes the same (changed, or shifted by lines inserted or removed above it), or any touched block left unnamed, rejects the whole edit loudly. The error names each failing anchor and its current hash. Nothing is remapped, guessed or kept in a snapshot side store. Untouched lines keep their own line endings and the BOM. **`write`** creates or replaces a whole file.
- **`bash`.** Runs the command in a real detected shell: `bash` on Linux and macOS; on native Windows, Git Bash when found, else PowerShell. The shell is named in the tool description and each result. Stdout and stderr stream to the result store as they arrive.
  - **Foreground budget:** a command still running when the budget expires is not killed. It becomes a job, and the call settles with the job handle while output keeps persisting.
  - **Environment:** provider credentials are excluded from the child environment by default.
- **`job`.** Reports the status of a job, waits for it, snapshots its output so far, or cancels it. This is how the model follows a command that outlived its foreground budget.
- **`grep`, `find`, `ls`.** `grep` and `find` use a detected or configured `rg`; a missing `rg` is a visible error, never a slow fallback. Output is `path:line: text` (grep) or one path per line (find, ls), uncut.
- **`ask`.** A structured question (prompt, optional choices, free-text allowed or not) whose answer is a typed result. The engine reaches the user through an answerer interface. Change 4 wires it to the line client; this change ships it with test answerers only.
- **Permissions.**
  - **Allowlist:** a short built-in read-only autoapprove allowlist, extended only by a user-owned allowlist in the user's Kehai configuration, never by repository content. It covers:
    - `read`, `grep`, `find` and `ls` inside the workspace;
    - `read_more`, `search_result`, `job` status and `ask` (the question is itself the prompt);
    - a few `bash` forms proven read-only (`pwd`, `ls`, `cat`, `head`, `tail`, `wc`, `rg` on workspace paths).
  - **Not built in:** `git` and `jj`. Repository configuration (fsmonitor, external diff, textconv) can make them run programs, so the user lists the forms they trust, such as `jj status`, `dart analyze` and `dart test`.
  - **Credential files:** Kehai's own credential files are never readable through the file tools, not even under `--yolo`.
  - **Shell proof:** a `bash` command is autoapproved only when the whole command parses as an allowlisted read-only form. Substitutions, redirections, pipelines into non-allowlisted commands and mixed commands ask.
  - **Everything else:** asks through the same answerer, unless the user started with an explicit `--yolo`.
  - **Decisions:** every approval, denial and yolo grant is a tree fact on the call node. A denied call settles with envelope status `denied`.
- **Unified job supervisor** (ADR 0003): one owner for job admission, the foreground budget, streaming persistence, cancellation and deadlines.
  - **Job node:** shell commands, over-budget calls and hook processes are all `jobs/<id>` nodes of one shape (`cmd`, `state`, `started`, `signal` intent, `stdout`/`stderr` handles, exit), with tool-call and job ids.
  - **Runtime handles:** process handles are ephemeral runtime capabilities, never persisted.
  - **Cancellation:** Ctrl-C (exposed as an engine call for change 4) cancels live work, terminates the process tree as far as the platform allows, and records any cleanup failure or uncertain outcome visibly.
- **Rewind reconciler.** After every rewind, one generic pass compares live runtime jobs with the tree. A job whose node was removed is killed. A node restored to a live state that no runtime owns is finalized as `cancelled` with reason `rewound`. A callback from a removed or superseded job is rejected, never applied. There are no tool-specific rewind handlers and no claim of external rollback.
- **Resume finalization.** Opening a session for write finalizes every tool-call and job node still `pending` or `running` before any command is accepted: `cancelled` with reason `interrupted`, or `failed` if it had already failed. This extends change 1's request finalization. Nothing is relaunched.
- **Minimal hook deadline seam** (ADR 0006): a user-configured pre-tool hook process runs under an engine-enforced deadline.
  - **Optional hook:** a timeout is a visible no-op.
  - **Deny-class hook:** a timeout, crash or nonzero exit denies the call.
  - **Hung hook:** it is killed at its deadline and can never block a turn.
  - **Default deadline:** set above hook-process startup measured on Linux and native Windows (Git Bash and PowerShell), as the architecture's resource bounds require.
  - A hung-process test fixture proves the deadline. There is no plugin protocol.
- **User configuration file** `<kehai home>/config.json`. It holds the user allowlist, the hook definitions and an `rg` path override; repository files can never change them.

Out of scope:
- **Change 4:** the agent loop, turn and budget rendering, RPC and the line client, which wires `ask` and permission prompts to a terminal. Retry policy also stays there.
- **Change 5:** skills, AGENTS.md, commands and typed subagents. Subagents will run as jobs of this supervisor.
- **M2+:**
  - full Windows tool parity;
  - PTY/ConPTY;
  - LSP;
  - diagnostics/VCS delta footers;
  - jj checkpoints;
  - a full plugin protocol;
  - MCP;
  - `summarize_result`;
  - a sandbox.

  Local commands run with the user's privileges.

## Capabilities

### New Capabilities
- `tool-calls`: the tool roster, argument validation, the call-node lifecycle in the tree, parallel admission, result streaming into the store and composition through the central envelope.
- `file-tools`: `read` with Hashline-compatible anchors, anchor-targeted `edit` that loudly rejects stale or moved anchors, and whole-file `write`.
- `workspace-search`: `rg`-backed `grep` and `find`, and `ls`, with uncut path output and a visible missing-`rg` error.
- `shell-tool`: real detected shell execution, the shell's identity, credential-free child environments, and the foreground budget that turns a long command into a job.
- `user-ask`: the structured `ask` tool and the answerer interface it shares with permission prompts.
- `tool-permissions`: the user configuration file, the built-in read-only allowlist, the user-owned allowlist, whole-command read-only proof for shell commands, ask-otherwise, explicit `--yolo`, and decisions recorded in the tree.
- `job-supervisor`: the unified job node, admission and deadlines, streaming persistence, cancellation, the `job` tool, the generic rewind reconciler, stale-callback rejection and resume finalization of tool and job nodes.
- `hook-deadlines`: the user-configured pre-tool hook process run under an engine-enforced deadline, with optional (no-op) and deny-class (fail-closed) policies.

### Modified Capabilities
None. The change 1 contracts (`result-store` envelope, caps, paging and search; `session-tree` rewind and request finalization; `session-journal` writer) are consumed unchanged.

## Impact

- **New code:** `lib/src/tools/` (runtime, roster, read/edit/write, search, ask), `lib/src/shell/` (shell detection, process launch, tree kill), `lib/src/jobs/` (supervisor, reconciler, resume finalization), `lib/src/permissions/`, `lib/src/hooks/`, and a `lib/src/config/` user-configuration reader. They are exported from `lib/kehai.dart` for change 4.
- **Session writer:** gains a guarded append, a record applied only while a named node still holds an expected value. This rejects stale job callbacks inside the single writer queue, without a second writer. It is an internal API; the journal format is unchanged (no format bump).
- **Tree shape:** tool-call nodes under `body`, job nodes under `jobs`. Both are inside v1 roots and turn-anchored, so rewind and fork already cover them.
- **External tools:** a real shell and `rg`, both pinned in `mise.toml` for development. On Windows, Git Bash or PowerShell.
- **Tests:** new suites under `test/tools/`, `test/jobs/`, `test/permissions/` and `test/hooks/`, with process fixtures under `test/fixtures/` (a hung hook, a long-running and a child-spawning command). The Linux runs use WSL as already approved.
- **Dependencies:** none expected. Any parsing helper is small and in-repo.
