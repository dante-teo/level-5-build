# ADR 0002: Revert to Electrobun

## Status

Accepted and implemented.

This ADR supersedes [ADR 0001: Native macOS Client for 1.0](0001-native-macos-client.md).

Current implementation note: the full migration sequence below has landed. Design-token parity, feature parity (durable local SQLite persistence, the inspect-only Review pane, per-project concurrent agent processes, native macOS `NSVisualEffectView` sidebar vibrancy via a small `bun:ffi` bridge), and CI/CD (`ci.yml`'s `app` job, `release.yml`'s `macos` job with codesign/notarize/Homebrew cask automation) landed in `legacy/electrobun-app/` first, then cutover promoted it to `app/` and deleted the native Swift scaffold. `app/` is now the Electrobun/React app described in `docs/ARCHITECTURE.md` and `docs/DESIGN.md`; there is no more native macOS client in this repository, and `legacy/` no longer exists.

## Context

The native macOS `app/` scaffold described in ADR 0001 shipped real functionality: an ACP runtime with both mock and real Devin backends, durable local persistence via SQLite/GRDB, an inspect-only native Review pane, and a signed and notarized release pipeline with Homebrew cask updates.

Despite that progress, the team has concluded that Electrobun/React better serves the product's iteration speed and LLM-assisted development velocity than the native Swift/SwiftUI stack. Concretely:

- A single JS/TS stack avoids context-switching between Swift and TypeScript across the codebase.
- The edit-reload loop in Electrobun/React is faster than Xcode/SwiftPM rebuilds.
- The training corpus and tooling ecosystem for JS/TS/React is presumed larger and more LLM-friendly than for Swift/SwiftUI, which matters directly for LLM-assisted development throughput.
- Electrobun/React development has no code-signing/notarization friction slowing down day-to-day iteration, unlike the unsandboxed Developer ID native app.

A second, independent driver points the same direction: Level5 Build needs to reach Windows and Linux, not only macOS. A native SwiftUI/AppKit app is architecturally macOS-only; reaching other platforms from it would mean either maintaining separate native clients per platform or replacing the UI/runtime layer with something cross-platform, which increases the eventual migration cost the longer native investment continues. Electrobun's web-tech stack (Bun, TypeScript, React) is not yet proven cross-platform for this product, but it is capable of reaching Windows and Linux in principle, unlike SwiftUI. Cross-platform reach is a reason for this direction, not a deliverable of the feature-parity or CI/CD branches below — those branches target macOS parity with the native app only; Windows/Linux builds, packaging, and testing are separate future scope.

Importantly, `legacy/electrobun-app/` was never actually behind on product surface area. It already had the sidebar, composer, approval modes, dashboard, and an ACP/Devin runtime (agent runtime, ACP client/transport, git status) before it was set aside. It also already has its own release scaffolding from before the native migration — code-signing/notarization config, DMG packaging, and Homebrew cask emission scripts — though that scaffolding is not currently wired into CI. It predates only the post-migration, native-only work: GRDB-backed durable persistence and the native inspect-only Review pane. That work will need to be built in `legacy/electrobun-app/`, and its existing release scaffolding will need to be wired back into CI, before it can resume as the shipped 1.0 path.

## Decision

`legacy/electrobun-app/` is promoted back to `app/` — the shipped 1.0 path — once feature/design parity and CI/CD land for it. Native `app/` is deleted, not archived, once cutover completes.

In the interim, both the native `app/` and `legacy/electrobun-app/` coexist side by side. The native app remains the shipped path until cutover; `legacy/electrobun-app/` is where parity work lands. Only the cutover branch (see Migration Sequence) removes the native `app/` path and promotes `legacy/electrobun-app/` to `app/`.

**Cutover has happened.** Native `app/` was deleted (`git rm -r app/`) and `legacy/electrobun-app/` was moved to `app/` (`git mv legacy/electrobun-app app`); `legacy/` no longer exists in this repository.

## Migration Sequence

The accepted sequence of branches is:

1. This ADR.
2. Design tokens.
3. Feature parity.
4. CI/CD.
5. Cutover.

## Consequences

This reverses ADR 0001's direction. What's given up: Swift/SwiftUI native integration depth, GRDB as a durable local store, and the advantages of a signed, unsandboxed native process model (native `Process` supervision, OSLog, native window/menu behavior).

What's gained: a single JS/TS/React codebase, Electrobun's existing release scripts, and a presumed faster LLM-assisted iteration loop.

Neither side of this trade is free. Of the native work already shipped (ACP runtime, GRDB persistence, Review pane, signed release pipeline), the ACP runtime and release scripts already have counterparts in `legacy/electrobun-app/` and don't need to be rebuilt from scratch — but GRDB-backed durable persistence and the Review pane are genuine gaps that must be built there, and the existing release scripts must be wired into CI, during the feature-parity and CI/CD branches before cutover is viable.
