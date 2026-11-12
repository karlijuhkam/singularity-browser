# Ideas

Things that came up while building but were not in the v1 brief.

**Owner decision, 2026-11-10: everything in this file is approved to be built, except the section "Decided against".** An agent picking up work here does not need to ask whether an item is in scope; this decision is the scope change. What still applies:

- Build in the order listed, one item at a time, unless the owner says otherwise.
- The projects under "Approved: projects" each need a written design the owner has approved before code is written (`docs/superpowers/specs/`). Open questions noted on an item go to the owner.
- The hard constraints and "don't loosen without the owner" rules in `CLAUDE.md` still hold, including asking before adding a dependency.
- When an item is finished, remove it from this file.
- New ideas go under "New, not yet decided" and are **not** approved until the owner says so.

## Approved: projects

- **Claude Chat plugin (top priority).** Owner decision 2026-11-11. A ready-made plugin that gives a Claude chat inside Singularity through the Agent SDK, on the user's own Claude subscription; this is the "AI only inside plugins, round 2" from `CLAUDE.md`. Needs its own design. Open questions for the owner: where a plugin shows a chat (plugins cannot own a panel or tab today), and how it reaches Claude (plugin backgrounds have no network; running the user's installed `claude` as a declared command would keep the login with Claude Code, so Singularity holds no key or token). It appears in the welcome flow's plugin list once it ships inside the app.
- **Projects in a Space.** Owner decision 2026-11-11, design approved: `docs/superpowers/specs/2026-11-11-projects-design.md`. A Space lists projects (name + folder); a new terminal starts in one, chosen from a picker or taken from the sidebar folder it is opened in; folders double as task groups. **Built 2026-11-12** (plan `docs/superpowers/plans/2026-11-12-projects.md`). Checked by tests and off-screen pictures only; left for the owner's hands: the picker with the keyboard (⌥⌘T outside a folder, Return, Escape, typing to filter), ⇧⌥⌘T inside a task folder, the folder header's Project menu and "New Terminal", "Add Project…" in Edit Space, and a split terminal beside a project terminal.

## Approved, but blocked outside the project

- **Ghostty as the terminal engine.** Approved, but it cannot be built sensibly yet. Last checked 2026-11-10: `libghostty-vt` 1.0.0 (2026-11-06) is the only stable library; it is the emulation core (parser, screen state, key encoding) with no drawing, fonts or PTY. The API that has those (`include/ghostty.h`) calls itself internal, for Ghostty's own macOS app only, with no stability promise. A Swift framework "that handles the entire terminal view" is planned without a date. So building on it would still mean writing our own renderer, and SwiftTerm already covers all of that. Before starting, check again whether Ghostty ships a stable embeddable terminal *view*. If it does, build it; if not, leave this item and tell the owner.

## New, not yet decided

Nothing here gets built without an explicit decision from the owner.

- **React shipped inside Singularity, for TSX artifacts.** TS/TSX artifacts are built (`docs/superpowers/specs/2026-11-10-ts-artifacts-design.md`) but ship no packages: a TSX page that uses React needs an import map pointing at files next to it or at a CDN. Bundling React (MIT) would make `app.tsx` work with nothing else, and is a new dependency, so it waits for the owner. Arbitrary npm packages would need the plugins' "declared and pinned" rule.
- **Arc favourites and split views in the Arc import.** The import (`docs/superpowers/specs/2026-11-11-arc-import-design.md`) leaves out Arc's favourites (they belong to an Arc profile, not a Space) and turns a split view into plain tabs. Both could be mapped if the owner misses them.
- **Console and network for artifact tabs.** `read_console` / `read_network` only cover web tabs (as designed). Agents that build artifacts would get a lot from seeing their own page's errors; the artifact origin changes port on every launch, so it needs its own switch rather than a per-site one.
- **Cross-engine checks by agents (instead of shipping more browser engines).** Raised 2026-11-11: the owner wants an agent to check their own work in other engines and say what broke. Embedding a second engine was considered and not chosen: on macOS it means Chromium via CEF, which would need a second implementation of everything built on WebKit APIs (page agent, plugin prelude, console/network collector, per-Space data stores, navigation guard), its own security updates, and breaks "WKWebView only". The cheap route needs no app code: an agent in a terminal tab runs Playwright (Chromium, Firefox, WebKit) against the dev server, collects console errors, failed requests and screenshots, and writes an HTML report into the Space's artifact folder. Limits: those browsers don't have the Space's logins, and Playwright's WebKit/Firefox are its own patched builds (the Singularity tab is the truer Safari check). Not tried yet; spike it first. Possible app features if the spike shows repeated friction: a `check_engines` agent tool, a built-in report view, or attaching to the user's installed Chrome over CDP (Chrome DevTools Protocol) for real console/network data.
- **Device choice and screen sharing in site settings.** Left out of the site settings panel: WebKit has no public API for either (see the "As built" section of `docs/superpowers/specs/2026-11-10-devtools-site-settings-design.md`). Revisit if WebKit adds one.

## Decided against

Do not build. Kept so the question isn't reopened without new facts.

- **Web-extension compatibility.** Decision: native plugins instead. Spikes in Nov 2026. Safari: the 1Password Safari extension wasn't usable in a WKWebView app; PlugInKit found 0 plugins, so there is no native messaging. Chrome: the 1Password Chrome extension under WKWebExtension lacked APIs (e.g. `chrome.notifications`), and shims weren't enough. So Singularity plugins (`docs/plugins/AUTHORING.md`) replace extensions.
