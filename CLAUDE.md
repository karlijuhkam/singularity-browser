# Singularity Browser — guardrails for every session

A native macOS browser whose organising unit is the **Space**. The sidebar holds three kinds of tabs side by side: **web pages**, **terminals** (where the user's own coding agents run), and **locally generated HTML artifacts**. An *external* agent (e.g. Claude Code in a terminal tab) can drive the browser through an MCP server the app exposes. There is no built-in AI, no chat UI, no API keys.

## The scope rule
**If it is not a tab type, it is not in v1.**

If you want to add something that is not in the brief, write it to `IDEAS.md` instead of building it. Ask before adding any dependency not listed below.

## Explicitly out of scope for v1
Do not build, scaffold, or leave TODOs for:
sync of any kind · browser extensions (including WKWebExtension) · any built-in AI or chat UI · Windows/Linux/iOS · split view · Peek/Little Arc-style windows · bookmarks beyond pinned tabs and folders · history UI beyond what the command palette needs · reader mode · ad blocking · themes · API routes on the artifact server · databases · an entity store · calendar/email/notes integration · agent orchestration (Herdr already does that; we only host terminals).

## Hard constraints
- Swift + SwiftUI (AppKit where SwiftUI falls short). No Electron, no web-based app chrome.
- WKWebView only. macOS 14+, Apple Silicon first.
- No sync, accounts, telemetry. All data lives under `~/Singularity/`.
- Allowed dependencies: SwiftTerm (terminal), FlyingFox or Hummingbird (local HTTP server), the official MCP Swift SDK. Verify APIs before use; do not rely on memory.
- Boring, readable Swift. The owner reads TypeScript/PHP more fluently than Swift, so comment the non-obvious AppKit/WebKit parts.

## Architecture
```
Sources/
  SingularityCore/   Pure Swift, no AppKit/WebKit. Models, persistence, palette logic. Unit-tested.
    Model/           Space, Folder, BrowserTab (TabKind enum: .web now; .terminal/.artifact in later phases)
    Persistence/     Paths (~/Singularity layout), SpaceStore (JSON), HistoryStore (jsonl), Slug
    Palette/         FuzzyMatcher, URLInput (URL vs search text)
  Singularity/       The app executable.
    App/             @main app, AppState (@Observable, the single source of truth), menu commands
    Sidebar/         Space rail, tab list (pinned / folders / open), editors
    Web/             WebViewRegistry (one WKWebView per tab), WebTabController (KVO + delegates)
    Palette/         Command palette overlay (Cmd+T / Cmd+K)
Tests/SingularityCoreTests/   Swift Testing
```

Key decisions:
- **Space** = UUID, name, colour, slug (fixed at creation; renaming changes only the display name), cwd. Each Space has its own `WKWebsiteDataStore(forIdentifier: space.id)`, so cookies and storage are isolated.
- **Not sandboxed.** Terminal tabs need to spawn login shells. Hardened runtime is on.
- On disk: `~/Singularity/state.json` (Space order and selection) and `~/Singularity/spaces/<slug>/{space.json, history.jsonl, favicons/}`. Writes are atomic and debounced.
- WKWebViews are created lazily (only when a tab is first shown) and kept alive across Space switches.
- Later phases (see the brief): per-Space artifact server on 127.0.0.1 with a bearer token; MCP via a `singularity-mcp` stdio launcher → Unix socket at `~/Singularity/.run/mcp.sock`; approval policy + `agent-log.jsonl`.

## Build / run / test
No Xcode project. Only SwiftPM + scripts (works with Command Line Tools alone):
- `scripts/build-app.sh`: builds and assembles and signs `build/Singularity.app` (ad-hoc, or `SIGN_IDENTITY=…`)
- `scripts/run.sh`: build, then quit any running copy and launch
- `scripts/test.sh`: unit tests (adds the Swift Testing macro plugin path that CLT-only setups need)
- Without full Xcode, both scripts build against the macOS 26 SDK (`scripts/env.sh`): in the macOS 27 SDK `@State` is a macro whose plugin only ships with Xcode. Plain `swift build` therefore fails under CLT; use the scripts, or `source scripts/env.sh` first.
- The tab model is called `BrowserTab` because SwiftUI has its own `Tab` type.
