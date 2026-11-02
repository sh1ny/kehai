# ADR 0014: Reusable building blocks as separate packages

Status: accepted (2026-11-02)
Supersedes: none

## Context

M1 entry 6 proved Kehai can deliver a real change, while M2 needs terminal and perception capabilities that may lack adequate Dart equivalents. Reusable infrastructure must not grow a dependency on harness types or become a speculative parallel product program. This supplements ADR 0004 and the strategy; the one-tree, central-result and unified-job foundations remain unchanged.

## Decision

- Prefer an adequate existing Dart package. Create a building block only when a concrete Kehai change demonstrates the need and records why existing options are inadequate. No Rust, including transitive building-block implementations; C FFI only where needed.
- New building blocks are standalone MIT packages. They import no `kehai` library, expose no Kehai-specific types, and own their tests, version and package metadata. Kehai consumes them through ordinary package dependencies; package internals do not become another session authority.
- Incubate a new package in this Dart workspace at `packages/<name>`, with its own `pubspec.yaml`, tests and MIT license. Add workspace/build configuration only when the consuming change needs it; this decision creates no package now.
- Extract it to its own repository and OpenSpec project once its API settles **or** a second consumer exists. Preserve independent tests/versioning and migrate consumers to an ordinary dependency on that project, without a copied implementation or reverse import into Kehai.
- Publishing to pub.dev is a deliberate per-package owner decision, not an automatic result of incubation or extraction. Review API stability, licensing, packaging and support before publication; published versions cannot be deleted, only retracted.

## M2 integration directions (not implementation receipts)

For PTY/process containment, reuse Kumiko's `packages/process_containment`: extract it to its own repository/OpenSpec project **before** Kehai consumes it, so both projects share a dependency rather than copies. Its Windows Job Objects are a candidate to replace `taskkill` tree termination, not a claim of equivalent cleanup yet. The consuming design must inspect/pin source, verify MIT compatibility and independent boundaries, and prove AOT delivery of required ConPTY/native assets through build hooks on supported targets. Kumiko requires its own planning change for extraction and a Kehai runtime adapter; do not edit Kumiko as part of this close.

For VT parsing, build a new pure-Dart, `vte`-equivalent parser plus minimal line buffer only when terminal integration needs it, producing honest text from PTY output. Do not reuse Kumiko's Rust `alacritty_terminal`. Tree-sitter C FFI bindings (with grammar native assets) and a pure-Dart o200k token counter remain optional, evidence-gated possibilities, not required packages or prerequisites for M2. Provider counts and honest estimates remain available.

Kumiko is intended eventually to run Kehai as its default harness through `kehai rpc` v1. The package boundary does not change that RPC contract or move engine/session ownership into Kumiko.

## Consequences

- **Rejected:** infrastructure coupled to Kehai imports/types. It is initially cheaper but makes a second consumer depend on harness policy and complicates extraction.
- **Rejected:** a package factory or publish-everything policy. It creates speculative maintenance/API commitments before dogfood evidence warrants them.
- **Rejected:** copying Kumiko's containment implementation or adopting its Rust terminal backend. Shared extraction avoids divergent fixes, and the no-Rust constraint remains strict.
- **Cost:** independent tests, versions, licenses, native packaging checks and eventual repository/OpenSpec maintenance. Initial workspace incubation keeps iteration local without relaxing boundaries.
- **Reversal cost: medium before publication, high afterwards.** An unpublished API can be reshaped with its consumers; extraction adds repository/dependency migration. Published APIs require deliberate compatibility and deprecation handling because releases cannot simply be deleted.
