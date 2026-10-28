---
name: specwright-commit
description: "MANDATORY during the OpenSpec apply phase: /opsx:apply, openspec-apply-change, `openspec instructions apply`, or the user asks to implement/apply an OpenSpec change. Commits each completed task on the change branch, verifies the commits when all tasks are done, then hands off to archive or to the PR."
metadata:
  version: 0.9.1
user-invocable: false
allowed-tools: Bash(git *) Bash(openspec *)
---

# Specwright Commit

Wraps the vanilla apply loop. The vanilla workflow still owns change selection, instructions and progress; this skill owns commits.

Commit type: the branch prefix, except `bugfix` → `fix`. Below, `<type>(<change-name>)` means that.

## 1. Before the first task
- Note any files that are already untracked or modified and not part of the change (`git status --porcelain`). They belong to the user: never commit them, and do not count them against the clean-tree check later.
- `git branch --show-current`. On `<prefix>/<change-name>` → use both parts in every message. On main → stop and offer to run `specwright-branch` now (the change's uncommitted artifacts carry over) or to continue without commits. Any other branch → confirm with the user first.
- **Planning repo** (below). Store-backed: planning files are committed in the store, on its `<prefix>/<change-name>` branch; task code is committed here. Note the store's pre-existing files too. `<store main>`: `planning_store.main_branch` in `openspec/specwright.yaml`, else `main`, else `master`.
- Store-backed: every commit call, in either repo, starts with the store branch check: `test "$(git -C "<store toplevel>" branch --show-current)" = <branch> &&`. If it fails, make no commit in either repo and stop, naming the store's current branch.
- Store-backed: **Reconcile** (below) before the planning commit, before ticking each task and before committing it.
- Uncommitted planning files → one call in the planning repo (store-backed: start it with `cd "<store toplevel>" && test "$(git branch --show-current)" = <branch> &&`): `git add -- <P>/changes/<change-name>/ && git commit -F <msgfile> -- <P>/changes/<change-name>/` with subject `<type>(<change-name>): add planning artifacts`. Never stage all of `<P>/`: other files there belong to the user.

## 2. After each task is ticked `[x]`
One commit per task, in **one shell call**: `git branch --show-current` must still print the change branch (stop if not), then `git add -- <paths> && git commit -F <msgfile> -- <paths>`.
- `<paths>`: the files this task changed plus `tasks.md`, by name. Store-backed: `tasks.md` is in the store, so the task gets two commits with the same subject: first the code files here, then `<P>/changes/<change-name>/tasks.md` in the store (`cd "<store toplevel>" &&` plus the branch check). A task that changed no code gets the store commit alone, with a `Code-Changes: none` line before the trailers. Never `git add -A` / `git add .`. An unexpected changed file is a question for the user, not something to sweep in.
- Subject: `<type>(<change-name>): task X.Y <task text>` with the full task text. Write the full message (subject, body, trailers) to a temp file with your file tool, never through a shell, so backticks, quotes and `$` stay literal. Then run `bash <skill dir>/scripts/fit-subject.sh <msgfile>` (`<skill dir>`: this skill's folder): it cuts the subject in the file at the last whole word within 72 characters and prints it. Commit with `git commit -F <msgfile>`. Store-backed: the store commit of the pair reuses the same file, so both commits carry the identical subject.
- `fit-subject.sh` exit 1 (not even the first word fits): make no commit for this task, leave its files uncommitted, and report the task, the subject and the 72-character limit. Exit 2 (missing file, or line 1 is not a task subject): fix the message file and run it again.
- Follow the user's commit identity and trailer rules (CLAUDE.md / AGENTS.md).
- Nothing to commit → note the task as no-op for the final report.
- **Release Notes**: with `release.enabled` true in `openspec/specwright.yaml`, a task that changes what the change ships updates the proposal's `## Release Notes` section in the same task commit (the proposal is a planning file: store-backed, it goes in the store commit). Every commit that edits the section, pre-ship and PR fix commits included, first runs `release.sh notes --proposal <proposal.md>` (`<specwright-release>/scripts/release.sh`) and must exit 0. An edit confined to the section keeps the design review verdict.
- When a `specwright-implementer` returns, before verifying its group: check for shells or background tasks it left running (your harness's task or process list), stop any you find and say so in the report, then run `git status --porcelain` again. A late writer may have changed or added files, so verify only after this.
- When a `specwright-implementer` did a group, commit its tasks one by one in order after verifying: each task's files with that task (a file two tasks touched goes with the later one). Re-run each task's green verification yourself; its report is not evidence. A red-confirmation task is the one exception: the test is green by now, so accept the report's exact command and failure output for it, and say so in the commit body.
- Drift amendments to proposal, specs, design or review.md: commit them by name in the planning repo as `<type>(<change-name>): amend <artifact>` before resuming tasks.

### Reconcile (store-backed)
A failed or interrupted step can leave a task ticked in the store with no store commit. Find these gaps before new work, so a later commit never absorbs an earlier tick. One read-only call: `git log <main>..HEAD --format=%B` here, `git -C "<store toplevel>" log <store main>..HEAD --format=%B` and `git -C "<store toplevel>" diff HEAD -- <P>/changes/<change-name>/tasks.md` (against `HEAD`, so a tick left staged by a failed commit counts too).
- A **gap** is a task ticked `[x]` in `tasks.md` with no store commit whose subject contains `task X.Y `. The task this session just ticked and is committing now is not a gap: the normal loop never asks about it.
- Gap with a code commit (`task X.Y ` in this repo's log) and the uncommitted `tasks.md` diff ticks only that task → commit `tasks.md` in the store with the code commit's subject, then continue.
- Gap without a code commit → never assume it changed no code. Commit nothing, tick nothing, stop and ask whether task X.Y changed code. No code → the store commit with its original subject and `Code-Changes: none`. Changed code → commit its code files by name first, then the store tick.
- The diff ticks more than one gap task → make no commit, list the tasks and ask how to record them.

## 3. When every task is `[x]`
One call: `git log <main>..HEAD --oneline && git status --porcelain`. Every checked `X.Y` needs a commit whose subject contains `task X.Y ` (with the trailing space, so 1.1 does not match 1.10), and the tree must be clean apart from the files noted in step 1 (and build or test byproducts such as `__pycache__`, which you may delete if you created them). Report `<N> tasks, <M> task commits, tree clean`, listing the pre-existing files you left alone. Store-backed: **Reconcile** first; then every ticked task needs a code commit or a store commit with `Code-Changes: none`, and a store commit containing `task X.Y `. Run the same check in the store (`git -C "<store toplevel>" log <store main>..HEAD --oneline && git -C "<store toplevel>" status --porcelain`) and report each repo on its own line: `code: <N> tasks, <M> task commits, tree clean` and `store: ...`. No handoff below until both repos pass. On a gap, stop and offer: commit the leftovers (by name), amend (only if the user picks it), or investigate.

**Pre-ship review.** Once the check passes, load the `specwright-review` skill and run its **Pre-ship review** on the finished change. The hand-off below waits until the review passes (no unwaived P0/P1 finding); its fix rounds and amendments are committed under these rules. With `review.preship: false` in `openspec/specwright.yaml`, skip it: no pre-ship review, and the hand-off follows the check.

Then read `finish` in `openspec/specwright.yaml` (default `local`):
- `local` → suggest `/opsx:archive`; the user runs it.
- `pr` → resolve the run login (`github.login`, else one `bash <specwright-pr>/scripts/as.sh --resolve`, `<specwright-pr>` being that skill's folder; exit 3 stops and tells the user), hand off to `specwright-pr` **ship** stating `run login: <login>`, then offer **watch**. Archive after review settles, on the same branch, before the PR is merged: **watch** offers it once the PR is ready.

Never commit on main, push from this skill, batch tasks into one commit, amend unprompted, or start archive yourself.

## Planning repo

OpenSpec decides where planning lives: in this repo, in a folder nested in it, or in a store (a separate git repo). Resolve it at the start of every run, before any write; never assume `./openspec/`.

1. **Root:** `openspec list --json` from the code checkout, plus `--store <id>` when the session selected a store. It needs no change name, writes nothing and still works after archive. `root` null with an error whose `message` starts with `Declared in` or `Invalid store declaration in` → stop before any git or file write and show that `message` and `fix`.
2. **Repo**, in one call: `git rev-parse --path-format=absolute --git-common-dir --show-toplevel && git -C "<root.path>" rev-parse --path-format=absolute --git-common-dir --show-toplevel`.
   - The second fails (root not in a git work tree) → stop and ask: initialise git there, or abort.
   - Different common dir → **store-backed**: the planning repo is the store checkout at its toplevel.
   - Same common dir and toplevel → **repo-local** (including a root nested in this checkout, such as `planning/`): one repo, as before.
   - Same common dir, different toplevel → the root is in another worktree of this repo, where a commit would land on that worktree's branch. Stop before any write, name both worktrees (path and branch) and ask.
3. Announce once: `Code repo: <toplevel>; planning repo: <toplevel> (store <root.store_id>)` or `(same repo)`.

**Paths.** `<P>` is `<root.path>/openspec` made relative to the planning repo's toplevel (`openspec` in the usual layout, `planning/openspec` for a nested root). Stage and `ls-tree` planning files as `<P>/...` in the planning repo.

**Where commands run.** Git, `gh` and `as.sh` commands on the store run in one shell call that starts with `cd "<store toplevel>" &&` (`as.sh` only fences the repo it starts in). `openspec templates` and `openspec schema validate` have no root selection: run them with `cd "<root.path>" &&`. `git -C` is for read-only queries only (`rev-parse`, `status`, `log`, `ls-tree`).

**Archive name.** Use `archivedAs` from the archive output when you have it. Otherwise it is the change name if that starts with `YYYY-MM-DD-`, else `YYYY-MM-DD-<change-name>`: `<P>/changes/archive/<archived-name>/`.

**Referenced stores.** A `references:` list in the root's `config.yaml` does not move the planning root: a repo with its own root stays repo-local. Referenced stores are read-only: never branch, commit, stash, push, open a PR or write a file in one. Read them only through `openspec context --json` (each `members` entry with `role: referenced_store` gives its `path` and a `fetch` command such as `openspec show <spec-id> --type spec --store <id>`). A member whose `status` has `reference_unresolved` (the store is not registered on this machine) is named in the report as `unresolved reference: <id>` with its `fix`, and the step continues without it; never guess its path.
