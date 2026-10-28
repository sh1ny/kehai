# ADR 0004: Dart-native headless engine with projection clients

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

Native Windows without WSL and Linux are primary; release architecture also includes Linux arm64 and macOS. Kumiko will later consume the same engine, not embed a different session implementation. [Dart AOT](https://dart.dev/tools/dart-compile) and [FFI](https://dart.dev/interop/c-interop) supply the intended execution/native boundary.

## Decision

Use Dart 3.x native AOT. Separate engine (session/journal/loop/tools/providers/jobs/collectors), tui (nocterm projection only) and cli (arguments/completions). M1 uses a dumb line client over RPC and contains no TUI. CPU-heavy or synchronous native work runs in disposable worker isolates, with bounded typed messages and revision checks; isolates do not share mutable Dart memory.

Use C FFI for tree-sitter/native PTY, ConPTY on Windows, bundled ripgrep and real detected shells. Native dependencies are packaged per target; a native executable is not a guarantee that all assets are embedded in one file. No embedded interpreter, QuickJS/Python runtime or WSL requirement.

## Consequences

- **Rejected:** Rust core with Dart/Flutter wrappers; extra cross-language session contracts/toolchains are not justified by measured need.
- **Rejected:** engine state inside nocterm widgets or Kumiko; clients would become competing authorities.
- **Rejected:** in-process shell emulation; large compatibility/runtime surface with no current requirement.
- **Cost:** qualify native assets, PTY cleanup and terminal behavior per OS; cross-compilation is not universally available.
- **Reversal cost: high** for language/client boundaries; **medium** for individual native adapters. M1 platform exercises and M2 renderer measurements are the evidence gates; no performance result is claimed yet.
