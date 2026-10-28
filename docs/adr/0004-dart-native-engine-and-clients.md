# ADR 0004: Dart-native headless engine with projection clients

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

Linux is the primary real self-hosting workflow. Native Windows without WSL must support the M1 line client and subscription login; full tool parity is an M2 exit. Later release targets include Linux arm64 and macOS. Kumiko will consume the same engine, not embed another session implementation. [Dart AOT](https://dart.dev/tools/dart-compile) supplies the native execution boundary.

## Decision

Use Dart 3.x native AOT, no Rust core or embedded script runtime. The headless engine owns session/journal/loop/tools/providers/jobs. `kehai rpc` exposes local NDJSON stdio; M1's readline client is a thin projection that streams tokens and one line per tool call. CLI handles arguments, login and doctor. Nocterm is M2+; no TUI implementation or renderer qualification blocks M1.

Use real detected shells, including Git Bash or PowerShell on Windows, and bundled or detected ripgrep. Full PTY/ConPTY, tree-sitter/FFI and native-asset packaging are not M1 prerequisites unless essential to its real workflow. Later blocking CPU/native work stays off engine/UI event loops, using bounded worker messages and stale-state checks; isolates do not contain native memory corruption. Package required native assets per target when introduced; a native executable is not an all-assets-in-one-file promise. No WSL, shell emulation, QuickJS/Python runtime or TypeScript-extension compatibility.

## Consequences

- **Rejected:** Rust core with Dart/Flutter wrappers; extra cross-language session contracts/toolchains lack demonstrated need.
- **Rejected:** engine authority in nocterm or Kumiko; clients would become competing session owners.
- **Rejected:** full terminal/native packaging breadth as the self-hosting gate; M1 needs working line-client/login scope, not a terminal platform.
- **Cost:** qualify M1 Windows login/client and primary Linux workflow, then native assets, cleanup and full Windows tools when introduced. Cross-compilation is not universally available.
- **Reversal cost: high** for language/client boundaries; **medium** for individual adapters. Later renderer measurements are evidence gates, not claimed results. Apply the shared [per-M1 design contract](../../openspec/architecture.md#decisions-and-per-m1-design-contract), including the narrowly authorized entry-6 M2 bridge.
