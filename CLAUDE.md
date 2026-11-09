# Singularity Browser — guardrails for every session

A native macOS browser whose organising unit is the **Space**. The sidebar holds three kinds of tabs side by side: **web pages**, **terminals** (where the user's own coding agents run), and **locally generated HTML artifacts**. An *external* agent (e.g. Claude Code in a terminal tab) can drive the browser through an MCP server the app exposes. There is no built-in AI, no chat UI, no API keys.

## The scope rule
**If it is not a tab type, it is not in v1.**

If you want to add something that is not in the brief, write it to `IDEAS.md` instead of building it. Ask before adding any dependency not listed below.

## Explicitly out of scope for v1
Do not build, scaffold, or leave TODOs for:
sync of any kind · browser extensions (including WKWebExtension) · any built-in AI or chat UI · Windows/Linux/iOS · Peek/Little Arc-style windows · bookmarks beyond pinned tabs and folders · history UI beyond what the command palette needs · reader mode · ad blocking · themes · API routes on the artifact server · databases · an entity store · calendar/email/notes integration · agent orchestration (Herdr already does that; we only host terminals).

**Scope change (owner decision, after Phase 4):** tiling / split view is *in* v1, built before Phase 5: nested splits (any pane splits right or down), Arc-style split groups, created via context menu, drag and drop, keyboard and palette.

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
    Agent/           AgentToolName (<slug>.<tool> naming), UntrustedContent (wrapping page text for agents),
                     AgentPolicy (readOnly / ask / allowAll + the approval rules table), AgentLog (agent-log.jsonl)
    Model/SplitLayout.swift  SplitNode tree, SplitGroup, split/remove/swap/neighbour ops, sidebar rows (SidebarItem)
  Singularity/       The app executable.
    App/             @main app, AppState (@Observable, the single source of truth), menu commands
    Sidebar/         Space rail, tab list (pinned / folders / open), editors
    Web/             WebViewRegistry (one WKWebView per tab), WebTabController (KVO + delegates)
    Palette/         Command palette overlay (Cmd+T / Cmd+K)
    Terminal/        TerminalRegistry, TerminalSession (SwiftTerm view + login shell + title polling)
    Artifacts/       ArtifactServer (FlyingFox, static files only), ArtifactWatcher (FSEvents),
                     ArtifactHost(s) (per-Space token + server + watcher), ArtifactBridge (window.singularity)
    MCP/             MCPSocketListener (Unix socket), MCPHub (one MCP SDK Server per connection),
                     AgentToolbox (tool definitions + implementations), PageAgentScript (read_page/find/click/type JS)
    Agent/           AgentApprovals (policy checks, one confirmation sheet at a time, "Allow on this site"),
                     AgentViews (agent badge, busy tint, Agent activity pane)
    Split/           SplitViews (recursive panes + draggable gaps), PaneContainerView (hosts a tab's view; drop
                     overlay during tab drags; click-to-focus monitor), PaneDragHandle (pane header drag source)
  singularity-mcp/   Stdio launcher agents start: relays bytes to ~/Singularity/.run/mcp.sock, starts the app if needed
Tests/SingularityCoreTests/   Swift Testing
```

Key decisions:
- **Space** = UUID, name, colour, slug (fixed at creation; renaming changes only the display name), cwd. Each Space has its own `WKWebsiteDataStore(forIdentifier: space.id)`, so cookies and storage are isolated.
- **Not sandboxed.** Terminal tabs need to spawn login shells. Hardened runtime is on.
- On disk: `~/Singularity/state.json` (Space order and selection) and `~/Singularity/spaces/<slug>/{space.json, history.jsonl, favicons/}`. Writes are atomic and debounced.
- **Known exception to "everything under ~/Singularity/":** each Space's cookies, logins and site data live in WebKit's store at `~/Library/WebKit/dev.roosa.Singularity/WebsiteDataStore/<space id>/`. WebKit chooses that location and the app cannot move it. Consequences: copying `~/Singularity/` does not carry logins over; deleting `~/Singularity/` by hand leaves the cookies behind (deleting a Space in the app does remove them); and the stores are tied to the bundle ID, so **never change `dev.roosa.Singularity`**, or every Space starts logged out. Changing the signing identity is fine.
- **Artifact server auth (decided with the owner; the brief asked for a Bearer header on every request).** WebKit cannot add headers to page sub-requests, so: the app loads each artifact tab's first request with `Authorization: Bearer <token>`; the server answers that with `Set-Cookie: singularity_token=…; HttpOnly; SameSite=Strict`; sub-requests and `fetch()` then use the cookie. The token is random per Space per launch, never in files, never readable by page JS, and the cookie lives only in that Space's WebKit store. (Setting the cookie natively via `WKHTTPCookieStore` does not work: WebKit silently drops cookies for a bare-IP domain.) The server also refuses non-loopback Host headers (DNS rebinding) and sends no CORS headers.
- `window.singularity` exists only on the Space's artifact origin (the script checks `location.origin`, and the native handler checks the message's `securityOrigin`). `prompt()` always asks (native sheet), then bracketed-pastes into the Space's most recently used running terminal and presses Return. Phase 5 replaces "always ask" with the Space policy.
- **MCP.** Agents run `Singularity.app/Contents/MacOS/singularity-mcp` (stdio). It contains no MCP logic: the app runs an MCP `Server` (official Swift SDK) per socket connection, reusing the SDK's `StdioTransport` on the socket's file descriptor. Tools: `list_spaces` plus `<slug>.<tool>` for Spaces with `agentsEnabled` (per-Space toggle in Edit Space, off by default); `tools/list_changed` is sent when that set changes. Claude Code shows `work.read_page` as `mcp__singularity__work_read_page` (dots become underscores; verified). The socket folder is 0700, the socket 0600, and peers must have the same uid.
- **Page agent.** `PageAgentScript` is injected at document start into every web/artifact tab in an isolated `WKContentWorld`, so pages can't see or tamper with it. Refs come from a WeakMap (element → number) and are stable for the life of a page load. Everything page-derived that is returned to an agent goes through `UntrustedContent.wrap`. Agent-opened tabs load in the background (not selected) at 1280×800.
- **Approvals (Phase 5).** Every agent tool call and every `window.singularity.prompt()` goes through `AgentApprovals.check` *inside the app*, so the policy holds for any client (an agent once drove `singularity-mcp` directly). Rules live in `AgentApprovalRules` (Core, tested): reads always pass; readOnly refuses acting; allowAll passes; ask shows a sheet (Allow / Allow on <site> / Deny, 2-minute timeout = deny) unless the page's site was allowed, and **always** asks for form submissions, artifact prompts and going to a site not yet allowed. `click` inspects the element first (submits a form? link to another site?), and while a click/type runs `WebTabController.agentNavigationGuard` holds any navigation that wasn't approved. Every call is appended to `<space>/agent-log.jsonl` (password text never logged) and shown in the sidebar's Agent activity pane; tabs opened by agents carry `openedByAgent` (sparkles badge), tabs being worked on pulse. The approval timeout is a setting (`agentApprovalTimeoutSeconds` in `~/Singularity/settings.json`); set it to e.g. 5 for tests.
- **Split view.** `Space.splits: [SplitGroup]`; a tab is in at most one. Arc-style: the content area shows the selected tab's whole split, or the tab alone; the sidebar shows a split as one row of chips. Every tab of a visible split is loaded. Things that bit us, keep them:
  - A tab's web/terminal view can only be in one place. During layout changes SwiftUI may update an outgoing pane next to the new one, so `HostedView` lets only the *newest* `PaneContainerView` own a view.
  - WKWebView takes almost any drop, so panes put a transparent `PaneDropOverlay` on top only while a tab is dragged (private UTI `dev.roosa.singularity.tab`, declared in Info.plist).
  - Pane headers sit in the window's invisible title-bar strip, where macOS starts a window drag before asking the view (`mouseDownCanMoveWindow` is not enough). `PaneDragHandleView` switches `window.isMovable` off while hovered. Never put SwiftUI `.help()` on chrome in that strip: it adds an overlay view that eats the click.
- **Settings window** (⌘,, SwiftUI `Settings` scene, `Sources/Singularity/Settings/`): General (search engine: `AppSettings.searchTemplate`, a URL with `%s`), Terminal (font, size, close on exit), Agents (all Spaces' agent switch + policy via `AppState.updateSpace`, approval timeout, the `claude mcp add` command for this copy of the app), Data & privacy (paths, per-Space clear history / site data / agent log). Stored in `~/Singularity/settings.json` (`AppSettings`, tolerant decoding); always change it through `AppState.updateSettings`.
- WKWebViews are created lazily (only when a tab is first shown) and kept alive across Space switches.
- Later phases (see the brief): per-Space artifact server on 127.0.0.1 with a bearer token; MCP via a `singularity-mcp` stdio launcher → Unix socket at `~/Singularity/.run/mcp.sock`; approval policy + `agent-log.jsonl`.

## Build / run / test
No Xcode project: SwiftPM + scripts. The scripts need full Xcode (macOS 27 SDK; SwiftUI's `@State` macro plugin and current SwiftTerm both require it). Xcode is installed on the external drive at `/Volumes/Zealot/Xcode.app`. `scripts/env.sh` points builds at it with `DEVELOPER_DIR`. The system default stays on the Command Line Tools on purpose, so `git` keeps working when the drive is unplugged. **Do not run `xcode-select -s`.** Override the location with `XCODE_APP=…`.
- `scripts/build-app.sh`: builds, assembles and signs `build/Singularity.app` (ad-hoc, or `SIGN_IDENTITY=…`)
- `scripts/run.sh`: build, then quit any running copy and launch
- `scripts/test.sh`: unit tests (Swift Testing)
- `scripts/release.sh`: universal release build → Developer ID signing → notarization → staple → `dist/`. `--skip-notarize` signs with the team's Apple Development certificate. **Singularity is signed by team `T748B76PPL` (Karli Juhkam, personal)**: the script only considers certificates whose OU is `TEAM_ID` (default T748B76PPL). This Mac also holds certificates of another company's team that must never sign Singularity. Identities are chosen by SHA-1 fingerprint (duplicate certificate names are ambiguous). Notarization needs a Developer ID Application certificate in team T748B76PPL and the `singularity-notary` notarytool profile, both set up by the owner.
- App icon: `scripts/icon/render_orb.py` is a numpy port of the orb shader on singularity.rroosa.ee; `make_icon.py` puts it on a macOS tile; `make_icns.sh` builds `Resources/AppIcon.icns` (white orb, dark tile). As on the site, the orb is white in dark mode and black in light mode: while running, `AppDelegate` swaps the Dock icon to `DockIcon-dark/-light.png`, and empty tabs show `Orb-dark/-light.png`. `Resources/*.png` are copied into the bundle.
- Plain `swift build` in a fresh shell uses the Command Line Tools and fails. Run `source scripts/env.sh` first, or use the scripts.
- **Bun** (owner-approved dependency, runs plugins): `scripts/fetch-bun.sh` downloads the pinned version of both arch zips, verifies their pinned SHA-256s and lipos them into `Vendor/bun/bun` (git-ignored, ~100 MB). `build-app.sh` and `release.sh` call it, copy the binary to `Contents/Helpers/bun` and sign it with `Resources/Bun.entitlements` (JIT, needed by JavaScriptCore under the hardened runtime) before signing the app. To upgrade, change the version and both checksums in the script.
- The tab model is called `BrowserTab` because SwiftUI has its own `Tab` type.
