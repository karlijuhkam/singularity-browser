# Singularity

A native macOS browser organised in **Spaces**. Its sidebar holds three kinds of tabs side by side: **web pages**, **terminals** (where your own coding agents run) and **HTML artifacts** generated on your Mac. An external agent, such as Claude Code running in one of those terminals, can drive the browser through an MCP server, with your approval. There is no built-in AI, no chat and no API keys. Without an agent it is just a calm sidebar browser.

Swift and SwiftUI, WKWebView (Safari's engine), macOS 14 or later. Nothing is synced and nothing leaves your Mac.

---

## 5-minute setup

### 1. Get the app (1 min)

- **Release build:** unzip `Singularity-<version>.zip` and move `Singularity.app` to `/Applications`.
- **From source:** you need full Xcode. `scripts/env.sh` looks for it at `/Volumes/Zealot/Xcode.app`; set `XCODE_APP=/path/to/Xcode.app` to use another copy. Then run:

  ```sh
  scripts/run.sh          # builds build/Singularity.app and launches it
  ```

### 2. Make it yours (2 min)

- **Spaces** are the circles on the left. Each Space has its own tabs, logins and cookies. Click **+** to add one; right-click → **Edit Space…** to rename it, change its colour or set its terminal folder.
- **⌘T** opens the command palette. Type a URL, a search, a tab name or a command such as "New Folder" or "Split Right with…".
- **Pin** a tab or move it into a **folder** by dragging it there in the sidebar, or by right-clicking it.
- **Coming from Arc?** File → **Import from Arc…** brings its Spaces, pinned tabs and folders over (not the logins).
- **⌥⌘T** opens a **terminal** in the Space's folder. It runs your normal login shell with your `.zshrc`.
- **Split view:** drag a tab from the sidebar onto the edge of the page, or right-click → **Open in Split View**. Drag a pane's title bar to move it, and drag the gaps to resize.

All preferences are in **Singularity → Settings…** (⌘,): search engine, terminal font, agent permissions for every Space, the exact `claude mcp add` command for your copy of the app, and per-Space "clear history / cookies / agent log".

### 3. Connect Claude Code (2 min)

1. In Singularity, right-click a Space → **Edit Space…** → switch on **Allow agents**, then choose what agents may do:
   - **Read only:** look at tabs and pages, and take screenshots.
   - **Ask before acting** (recommended): you confirm each click, typing, page opened or tab closed. Form submissions and going to another site always ask.
   - **Allow everything:** no questions asked, but every action is still logged.
2. Register the MCP server once, for all your projects. **Settings → Agents** has this command with the right path and a Copy button:

   ```sh
   claude mcp add -s user singularity -- /Applications/Singularity.app/Contents/MacOS/singularity-mcp
   ```

   For a source build, use `…/Singularity-Browser/build/Singularity.app/Contents/MacOS/singularity-mcp`. If Singularity isn't running, the command starts it.
3. Open a terminal tab in that Space (⌥⌘T), run `claude`, and try:

   > Using the singularity browser tools, find the "Install" button on swift.org and click it.

   A sheet asks you to confirm: **Allow**, **Allow on swift.org** (stops asking for that site until you quit), or **Deny**. **Show Tab** brings the page up behind the sheet first. You can see what agents did under **Agent activity** in the sidebar.
4. Optional, for debugging your own sites: let agents read a page's **console errors and failed network calls**. It is off unless you switch it on twice: "Let agents see console and network" for the Space (Edit Space…), and again for the site in the **site settings** (the button at the right of the address). What agents read there can contain passwords and tokens, so switch it on for your dev servers, not for your bank.

---

## What's in it

### Tabs

| Kind | What it is |
|---|---|
| Web | A normal web page. Each Space has its own cookies and logins. Right-click → Inspect Element opens the Web Inspector (console, network, elements). Pages can use the camera and microphone after asking you; the site settings button next to the address remembers Allow or Block per site, and switches plugins off for a site. Downloads go to ~/Downloads and are listed at the bottom of the sidebar while the app runs. A page that can't be loaded says why, with a Try Again button, and sites behind a name and password show a login dialog (remembered until you quit). |
| Terminal | Your login shell in a pseudo-terminal (SwiftTerm). The tab title follows the running program. `TERM_PROGRAM=Singularity` and `SINGULARITY_SPACE=<slug>` are set. ⌘W or ⌘Q asks first while a program (such as an agent) runs. With [herdr-core](https://github.com/herdrdev/herdr-core) installed, Settings → Terminal can run shells through it, so they keep running when Singularity quits. |
| Artifact | An HTML file in the Space's `artifacts/` folder. A new file opens as a tab by itself, and an open tab reloads when its files change. TypeScript and TSX files work without a build step: they are compiled as the page asks for them (`import "./util"` finds `util.ts`), and `app.tsx` on its own opens as a page. Packages such as React are not included; point an import map at them. |

**Artifacts** are served by a small web server for each Space, on `127.0.0.1` with a random port and a token for each launch. They behave like a normal website: ES modules and `fetch()` work. Artifact pages also get `window.singularity`:

```js
await singularity.prompt("Summarise the open tabs");   // pastes into the Space's terminal and presses Return
singularity.open("https://example.com");               // opens a web tab in this Space
```

`prompt()` follows the Space's agent policy: it's refused under read only, sent straight away under allow everything, and asks under ask before acting. "Show Artifacts Folder in Finder" in the palette opens the folder.

### Agents (MCP)

Tools, for each Space where agents are allowed (Claude Code shows `work.read_page` as `mcp__singularity__work_read_page`):

| Tool | Does |
|---|---|
| `list_spaces` | Spaces open to agents, with their policy |
| `<space>.list_tabs` | All tabs, with tab_id, title, URL, and which are on screen |
| `<space>.open` / `navigate` / `close` | Open a URL in a background tab, load a URL in a tab, close a tab |
| `<space>.read_page` | An outline of the page; interactive elements carry refs like `[12] button "Add to cart"` |
| `<space>.find` | Search the page for text or elements |
| `<space>.click` / `type` | Act on a ref (`type` can also submit the form) |
| `<space>.screenshot` | A PNG of the page |

- **Untrusted content:** everything taken from a page is wrapped in `<untrusted_page_content>`, and the browser never follows instructions found in pages.
- **Approvals:** these are enforced inside the app, so they apply whatever client is connected.
- **Agent log:** every action goes into `~/Singularity/spaces/<slug>/agent-log.jsonl`, with time, client, tool, arguments, your decision and the result. Text typed into password fields is never logged.

### Plugins

A plugin is a folder that adds something to web pages, such as a button in a field, with a background program that runs in a macOS sandbox with no network. You approve what each plugin may do before it runs, and any change to its files pauses it until you approve again.

To add one: Settings → Plugins → Add Plugin…, choose the plugin's folder, read the approval sheet, approve, then switch it on for the Spaces you want.

The **1Password** plugin (`Plugins/1password`) fills logins after you click its button and pick a login from a menu. It needs the 1Password app with Settings → Developer → "Integrate with 1Password CLI" switched on, and the `op` command line tool (`brew install 1password-cli`).

To write your own (an agent can do it from the guide), see [docs/plugins/AUTHORING.md](docs/plugins/AUTHORING.md). `Plugins/template` is a minimal starting point.

### Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘K | Command palette (new tab, search, commands) |
| ⌘, | Settings |
| ⌘L | Open location (load in the current tab) |
| ⌥⌘T | New terminal |
| ⌘W | Close tab |
| ⌘1 … ⌘8, ⌘9 | Switch to Space 1–8, or to the last Space |
| ⌃⇥ / ⌃⇧⇥ | Next / previous tab |
| ⌘R, ⌘[, ⌘] | Reload, back, forward |
| ⌘F, ⌘G / ⇧⌘G | Find on the page, next / previous match |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / actual size |
| ⌘P | Print |
| ⌘\ / ⇧⌘\ | Split with the previous tab / remove the tab from its split |
| ⌥⌘ + arrows | Move focus between split panes |

### Where your data lives

```
~/Singularity/
├─ state.json                   Space order, selected Space
├─ settings.json                preferences (Settings window)
├─ .run/mcp.sock                the agents' socket (only while the app runs)
└─ spaces/<slug>/
   ├─ space.json                tabs, folders, splits, settings
   ├─ history.jsonl             visited pages (for the palette)
   ├─ agent-log.jsonl           agent actions
   ├─ artifacts/                your HTML artifacts
   └─ favicons/
```

One exception: each Space's **cookies and logins** live in WebKit's own store at `~/Library/WebKit/dev.roosa.Singularity/WebsiteDataStore/<space id>/`. Copying `~/Singularity` doesn't move your logins, and deleting a Space in the app removes them.

---

## Building

| Script | What it does |
|---|---|
| `scripts/run.sh` | Debug build, assembled and signed into `build/Singularity.app`, then launched (quits the running copy first) |
| `scripts/test.sh` | Unit tests (Swift Testing) |
| `scripts/build-app.sh` | Just the debug `.app` (`SIGN_IDENTITY=…` to choose a certificate) |
| `scripts/release.sh` | Universal release build: signed with a Developer ID, notarized and stapled → `dist/Singularity-<version>.zip` |
| `scripts/icon/make_icns.sh` | Rebuilds `Resources/AppIcon.icns` from the orb renders (`render_orb.py` ports the singularity.rroosa.ee shader) |

**First release only:**
1. Create a **Developer ID Application** certificate in the Apple Developer team that should appear as Singularity's developer (the script defaults to `TEAM_ID=T748B76PPL`): developer.apple.com → Certificates, IDs & Profiles → "+". Download it and double-click to install.
2. Store notarization credentials, which asks for an app-specific password:
   `xcrun notarytool store-credentials singularity-notary --apple-id <you> --team-id <team>`.

`scripts/release.sh --skip-notarize` signs with any certificate, for testing the build without them.

The project is SwiftPM only; there's no Xcode project. Scope, architecture and decisions are in `CLAUDE.md`, and ideas for later are in `IDEAS.md`.
