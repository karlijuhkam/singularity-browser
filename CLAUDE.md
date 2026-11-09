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
    Model/           Space, Folder, BrowserTab (TabKind enum: .web, .terminal, .artifact)
    Persistence/     Paths (~/Singularity layout), SpaceStore (JSON), HistoryStore (jsonl), Slug
    Palette/         FuzzyMatcher, URLInput (URL vs search text)
    Terminal/        ProcessInspector (foreground program, argv[0], cwd), TerminalTitle, HomePath
    Artifacts/       ArtifactFiles (path containment, MIME types, page listing), ArtifactAuth (token checks)
  Singularity/       The app executable.
    App/             @main app, AppState (@Observable, the single source of truth), menu commands
    Sidebar/         Space rail, tab list (pinned / folders / open), editors
    Web/             WebViewRegistry (one WKWebView per tab), WebTabController (KVO + delegates)
    Palette/         Command palette overlay (Cmd+T / Cmd+K)
    Terminal/        TerminalRegistry, TerminalSession (SwiftTerm view + login shell + title polling)
    Artifacts/       ArtifactServer (FlyingFox, static files only), ArtifactWatcher (FSEvents),
                     ArtifactHost(s) (per-Space token + server + watcher), ArtifactBridge (window.singularity)
Tests/SingularityCoreTests/   Swift Testing
```

Key decisions:
- **Space** = UUID, name, colour, slug (fixed at creation; renaming changes only the display name), cwd. Each Space has its own `WKWebsiteDataStore(forIdentifier: space.id)`, so cookies and storage are isolated.
- **Not sandboxed.** Terminal tabs need to spawn login shells. Hardened runtime is on.
- On disk: `~/Singularity/state.json` (Space order and selection) and `~/Singularity/spaces/<slug>/{space.json, history.jsonl, favicons/}`. Writes are atomic and debounced.
- **Known exception to "everything under ~/Singularity/":** each Space's cookies, logins and site data live in WebKit's store at `~/Library/WebKit/dev.roosa.Singularity/WebsiteDataStore/<space id>/`. WebKit chooses that location and the app cannot move it. Consequences: copying `~/Singularity/` does not carry logins over; deleting `~/Singularity/` by hand leaves the cookies behind (deleting a Space in the app does remove them); and the stores are tied to the bundle ID, so **never change `dev.roosa.Singularity`**, or every Space starts logged out. Changing the signing identity is fine.
- **Artifact server auth (decided with the owner; the brief asked for a Bearer header on every request).** WebKit cannot add headers to page sub-requests, so: the app loads each artifact tab's first request with `Authorization: Bearer <token>`; the server answers that with `Set-Cookie: singularity_token=…; HttpOnly; SameSite=Strict`; sub-requests and `fetch()` then use the cookie. The token is random per Space per launch, never in files, never readable by page JS, and the cookie lives only in that Space's WebKit store. (Setting the cookie natively via `WKHTTPCookieStore` does not work: WebKit silently drops cookies for a bare-IP domain.) The server also refuses non-loopback Host headers (DNS rebinding) and sends no CORS headers.
- `window.singularity` exists only on the Space's artifact origin (the script checks `location.origin`, and the native handler checks the message's `securityOrigin`). `prompt()` always asks (native sheet), then bracketed-pastes into the Space's most recently used running terminal and presses Return. Phase 5 replaces "always ask" with the Space policy.
- WKWebViews are created lazily (only when a tab is first shown) and kept alive across Space switches.
- Later phases (see the brief): per-Space artifact server on 127.0.0.1 with a bearer token; MCP via a `singularity-mcp` stdio launcher → Unix socket at `~/Singularity/.run/mcp.sock`; approval policy + `agent-log.jsonl`.

## Build / run / test
No Xcode project: SwiftPM + scripts. The scripts need full Xcode (macOS 27 SDK; SwiftUI's `@State` macro plugin and current SwiftTerm both require it). Xcode is installed on the external drive at `/Volumes/Zealot/Xcode.app`. `scripts/env.sh` points builds at it with `DEVELOPER_DIR`. The system default stays on the Command Line Tools on purpose, so `git` keeps working when the drive is unplugged. **Do not run `xcode-select -s`.** Override the location with `XCODE_APP=…`.
- `scripts/build-app.sh`: builds, assembles and signs `build/Singularity.app` (ad-hoc, or `SIGN_IDENTITY=…`)
- `scripts/run.sh`: build, then quit any running copy and launch
- `scripts/test.sh`: unit tests (Swift Testing)
- Plain `swift build` in a fresh shell uses the Command Line Tools and fails. Run `source scripts/env.sh` first, or use the scripts.
- The tab model is called `BrowserTab` because SwiftUI has its own `Tab` type.
