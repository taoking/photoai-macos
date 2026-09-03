# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Toolchain

The package declares `swift-tools-version: 6.4` and `platforms: [.macOS(.v27)]`, which the default
system Xcode (26.x / Swift 6.3) cannot even parse. Every `swift`/`xcodebuild` invocation must point
at the Xcode 27 beta:

```sh
export DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer   # local beta path
```

Without it you get `package is using Swift tools version 6.4.0 but the installed version is 6.3.3`.

## Commands

```sh
swift build
swift test                                   # Swift Testing, ~90 tests / 17 suites
swift test --filter CatalogTests             # one suite
swift test --filter ratingShortcutTest       # one test
swift run PhotoAIMac
xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' -quiet test
```

Two tests are opt-in behind environment variables (they need a real Sony ARW file):

```sh
PHOTOAI_RUN_REAL_RAW=1 PHOTOAI_REAL_RAW_PATH=/path/to/Sony.ARW swift test
```

UI verification must run against a freshly assembled bundle, never `swift run` alone and never a
stale `.app` — a whole debugging round was once wasted on a two-week-old binary:

```sh
./Scripts/build-debug-app.sh && open .build/PhotoAI-Mac.app     # rebuild, assemble, ad-hoc sign
./Scripts/create-release-artifacts.sh                           # Release zip + SHA-256 into dist/
```

CI (`.github/workflows/source-hygiene.yml`) only runs `git diff --check` on Linux; it makes no claim
about building. All real verification is local.

## Product invariants

These are hard constraints from `PhotoAI-Mac-PLAN.md` §3 and are enforced throughout the code —
violating one is a bug, not a style choice.

- **Originals are never modified.** Edits live only as an `EditRecipe` in the catalog JSON; export
  re-renders (decode → adjustments → LUT → crop/rotate → write) to a *new* file. Deletion means
  `FileManager.trashItem`, and the catalog record is dropped only after the trash move succeeded.
- **Local-first.** No login, no server, no API keys. Foundation Models and Media Intelligence are
  wrapped in `#if canImport(...)` plus runtime availability checks, and every feature has a
  deterministic local fallback (see `FallbackSearchParser` in `SearchAndOCR.swift`).
- **Nothing happens without explicit user action.** Folders are indexed only from a user-picked
  `NSOpenPanel` (stored as a security-scoped bookmark); Apple Photos is never authorized, read, or
  thumbnailed until the user clicks into it; trash and Pick-marking need a confirmation step.
- **Destructive/AI suggestions are advisory.** `CleanupWorkflowStore` and `CullingWorkflowStore`
  produce explainable candidate lists; they never mutate ratings/flags or files on their own.

## Architecture

SwiftUI + AppKit, a single SwiftPM executable target, no third-party dependencies.
`PhotoAIMacApp.swift` owns ~16 `@MainActor` `ObservableObject` stores and injects them all as
environment objects — that file is the map of the system. There is no DI container; a store is
reachable from a view iff it is listed there.

**Catalog is the single source of truth.** `CatalogStore` holds `[PhotoSource]` + `[PhotoAsset]` in
memory and persists a `CatalogSnapshot` to
`~/Library/Application Support/PhotoAI-Mac/catalog.json` (siblings: `people.json`, `luts.json`,
`export-presets.json`, `PhotoPreviews/`). Key mechanics:

- `CatalogPersistence` writes atomically and keeps a `.bak` of the last *decodable* snapshot, so a
  crash-corrupted primary never overwrites the recovery point.
- `CatalogSnapshot.migrateInPlace()` migrates by `schemaVersion` (currently 3) and tolerates missing
  fields; a newer-than-known version is clamped, not rejected. Adding a persisted field means
  bumping the version and adding a migration branch.
- **Asset identity must stay stable.** On rescan, `merge(_:for:)` re-attaches the existing `UUID`
  for the same `sourceID + relativePath` and carries over rating, flag, color label, comment,
  favorite, recipe, and OCR text. People, OCR, selection, and culling sessions all reference assets
  by that UUID, so regenerating it silently breaks them.
- Folder access is via security-scoped bookmarks with a `lastKnownPath` fallback; a source that
  resolves to nothing becomes `.missing` rather than losing its assets.

**Performance is a correctness concern here.** Repeated sidebar switching on a ~900-item library
once pegged the main thread, so several caches exist deliberately and must not be undone:

- `CatalogStore.assets(for:filter:)` is memoized in `queryCache` keyed by destination+filter, with
  `assetIndexByID` for O(1) lookup and `duplicateAssetIDsCache` for the duplicates filter. Any
  mutation path goes through `persist()`/`invalidateQueryCache()`. `queryComputationCount` exists so
  tests can assert a re-render did *not* recompute.
- `ThumbnailStore` deliberately keeps `completedKeys` non-`@Published` and delivers results through
  per-cell callbacks; publishing per-thumbnail completion re-renders the whole grid. Off-screen
  cells unregister their callbacks.
- `ApplePhotosStore` caches `visibleAssets` and guards async album loads with cancellation *and* a
  generation counter (latest-selection-wins).
- `PhotoCullingSessionStore` snapshots indices, statistics, and groups once at session start;
  next/previous is O(1) array indexing with no disk access. A 100,000-item gate test asserts
  <100 ms per step.
- RAW and video decoding never happens on the main thread — `PhotoPreviewStore` (2400 px previews,
  memory + on-disk TIFF cache) and `ImageProcessingPipeline` do it in detached tasks.

**Views.** `AppShellView.swift` is a ~2300-line file holding the sidebar, every library pane, the
photo viewer, grid cells, and the inspector as `private struct`s; `PhotoCullingView` and
`EditorView` are separate. Navigation goes through `AppShellModel.select(_:)` — bypassing it leaves
the editor presented over the library and produces a blank main pane. `AppShellModel` tracks the set
of focused text fields (`activeTextInputs`); unmodified single-key menu shortcuts (space, arrows,
digits, P/X/U/E/F) are disabled while any is active, because AppKit menu key-equivalents otherwise
swallow keystrokes before the text field sees them. Fields must deregister in `onDisappear`, not
only on focus loss.

`KeyboardShortcutReference.all` is the single source of truth for shortcuts — the culling legend,
the Settings cheat sheet, and VoiceOver announcements all read from it. Update it whenever you touch
a key binding in `AppCommands` or `PhotoCullingView`.

## Conventions

- UI strings, doc comments, docs, and plan files are **Chinese**; type/member names are English.
  Non-obvious comments explain *why* a mechanism exists (usually a past bug) — preserve them.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`) in plain `struct`
  suites, `@MainActor` where they touch stores. No XCTest anywhere. Tests build fixtures in
  temporary directories and assert original bytes are unchanged; never commit real photos.
- Work is organized into numbered phases. Each phase gets a branch `agent/phase-N-<topic>`,
  conventional commits (`feat:`/`fix:`/`test:`/`docs:`/…), a `docs/phase-N-*-validation.md` recording
  every check as **PASS / NOT RUN / BLOCKED** with evidence, a checklist update in `plan.md`, and a
  draft PR. Do not claim a verification that was not actually run — "NOT RUN" is the expected and
  accepted outcome for anything needing hardware or data that isn't present.
- Never commit signing config, Team IDs, personal photos/RAW, or full home paths
  (`Config/LocalSigning.xcconfig` is gitignored).
