# Developer tools and site settings: design

Status: **built on 2026-11-10.** The owner handed the open design choices to the builder
("I'll allow you to choose where design choices are needed and will review in the end"), so the
calls marked "my call" below stand until that review. What was built, and what was left out and
why, is under "As built" at the end.

## Intent: why

Singularity is mainly a browser for developers. The owner's daily tools are the **network
calls**, the **console** and **inspecting elements**. Two things are missing:

1. The owner's agents (Claude Code in a terminal tab) can read a page, but can't see *why* it is
   broken: the console error or the failed request. Today the owner copies those from the Web
   Inspector into the terminal by hand.
2. There is no place for per-site settings. Camera and microphone prompts are WebKit's defaults
   and are not remembered, and there is no way to switch a plugin off for one site.

## Already shipped (branch `ship-prep`)

- Right-click → Inspect Element (the full Web Inspector: console, network, elements).
- Camera and microphone work; WebKit asks on every use, nothing is remembered.

## Goals

1. **Agents can read console problems.** Errors and warnings, uncaught exceptions and unhandled
   promise rejections of a page, with source file and line when known.
2. **Agents can read failed network calls.** Requests that failed or answered with status ≥ 400:
   method, URL, status, the **request payload** and the **response body** (owner: "body and
   payload too, headers optional").
3. **Off unless switched on, twice.** A per-Space master switch *and* a per-site switch (owner:
   "per-space, per-site switch"). Both must be on for a site before anything is captured.
4. **A site settings button next to the address** (owner: "a button near url, more settings for
   page is needed anyway"). It opens a panel for the site of the current tab.
5. **Camera, microphone and screen per site**: Ask / Allow / Block, remembered per Space and
   site, plus the **choice of device** (owner: "both would be nice").
6. **Per-site plugin switches** in the same panel (owner: "plugins maybe?").

## Non-goals

- Our own inspector UI. The Web Inspector already does that for the human.
- Successful requests, timing waterfalls, WebSocket frames, HAR export.
- Agents *changing* anything through these tools (no request replay, no running scripts).
- Site settings beyond the list in "The panel" (no per-site zoom, JavaScript or cookie switches).
- Sync or export of site settings.

## Anti-goals: this fails even if it "works" when…

- An agent can read console or network data of a site the owner did not switch on.
- Captured data contains a login the owner did not mean to share and nothing warned them.
  Response bodies and payloads can hold tokens and passwords; the panel must say so in plain
  words where the switch is.
- A page can use the capture to learn something about the browser or other sites.
- Switching capture on changes how a normal site behaves in a way the owner notices.

## Constraints

- Swift + SwiftUI, WKWebView only, no new dependencies (CLAUDE.md).
- WKWebView has **no public API for network or console inspection.** The only route is a script
  the app injects into the page's own JavaScript world that wraps `console.error/warn`, `fetch`
  and `XMLHttpRequest` and listens for `error` / `unhandledrejection`. Consequences the builder
  must design around, and the doc must be honest about:
  - The page can see and tamper with the wrapper, so everything captured is **untrusted page
    content** and goes through `UntrustedContent.wrap` like `read_page` output.
  - Only requests made by page scripts are seen. Failed images, stylesheets and navigations can
    be seen as "failed to load <URL>" (via `error` events), without status or body.
  - The script is injected **only** into pages of switched-on sites, never everywhere.
- All data stays in memory, per tab, and is dropped when the tab closes or navigates to another
  site. Nothing is written to disk. Not in `agent-log.jsonl` either (the log records *that* a
  read happened, not what was read).
- Reads go through `AgentApprovals.check` like every tool call.

## How agents use it (decided, names are the builder's call)

Two new tools per Space, shown only when the Space's master switch is on:

- `<slug>.read_console(tab, since?)`: recent console problems of a tab.
- `<slug>.read_network(tab, since?)`: recent failed requests of a tab.

Behaviour:

- On demand only; nothing is pushed to agents.
- `since` is a cursor from the previous answer, so an agent can ask "anything new?".
- If the tab's site is not switched on, the tool answers with a clear refusal that tells the
  agent what the owner has to do ("ask the user to turn on 'Let agents see console and
  network' for example.com in site settings"). It never returns partial data.
- Limits (my call): the last 200 console entries and 100 requests per tab; each body and payload
  cut at 64 KB with a note that it was cut; binary bodies replaced by their type and size.
- Headers (my call, owner said optional): included, with the values of `Authorization`,
  `Cookie`, `Set-Cookie`, `Proxy-Authorization` and any header whose name contains `token`,
  `secret` or `key` replaced by `[hidden]`.
- Treated as **reads** by the approval rules: they pass under every policy, including read only.
  The two switches are the approval.

## The switches (decided)

- **Space:** "Let agents see console and network" in Edit Space and in Settings → Agents, off
  by default. Only offered when agents are enabled for the Space.
- **Site:** the same sentence in the site settings panel, off by default, stored per Space and
  site. Shown disabled, with the reason, while the Space switch is off.
- "Site" means scheme + host + port (an origin), the same notion `AgentApprovals` uses for
  "Allow on this site". `http://localhost:3000` and `http://localhost:5173` are different sites.
- The name avoids "development mode", which already means something for plugins.
- While capture is on for the page being shown, the site settings button shows it (a small
  dot or tint), so the owner never forgets it is on.

## The panel (decided list; layout is the builder's call)

A button next to the address in the sidebar opens a popover for the current tab's site, with:

1. **Connection**: "Secure connection" / "Not secure" and the site name.
2. **Camera**, **Microphone**, **Screen sharing**: Ask (default) / Allow / Block each.
3. **Device**: which camera, microphone and speakers this site gets.
4. **Agents**: the console and network switch, with a line saying that payloads and responses
   can contain passwords and tokens.
5. **Plugins**: one switch per plugin that is approved for this Space and matches this site. Off
   means the plugin's page script is not injected on this site. These switches only narrow what
   a plugin may do; they never grant anything.

Terminal and artifact tabs have no panel (the button is hidden).

Storage: per Space, in `space.json`, as a map from site to its settings. Removing a Space
removes them. Settings → Data & privacy gets "Reset site settings" per Space.

## Risks to settle first (builder: spike these before planning the rest)

1. **Device choice.** WebKit has no public API to pick the camera or microphone for a page; the
   page chooses among what `enumerateDevices()` lists. Check what is possible. If nothing clean
   exists, drop "Device" from round 1 and say so; do not fake it with script injection.
2. **Screen sharing.** `getDisplayMedia` in WKWebView may need a delegate method that is not
   public. Check on macOS 14 and current. If it can't be supported cleanly, show the row as
   "not supported yet" or leave it out.
3. **Remembering camera/microphone answers.** `requestMediaCapturePermissionFor` (public) can
   grant or deny without a prompt. Check that granting without WebKit's prompt works for both.
4. **Wrapping `fetch`/XHR without breaking sites.** Reading a response body means cloning the
   response; streaming responses (server-sent events, large downloads) must not be buffered or
   stalled. Capture bodies only for status ≥ 400 or network failure, and only up to the limit.
5. **Frames.** Decide whether an embedded frame of a switched-on site, inside a site that is
   not switched on, is captured. My call: capture follows the **tab's** main site only, and
   frames of other sites are never captured.

## Testing

- Core, unit-tested: the site-settings model and its JSON, the "is capture allowed" rule
  (Space switch × site switch × origin match), header redaction, body truncation, the cursor.
- A fixture page (console error, uncaught exception, rejected promise, fetch 404 with a JSON
  body, XHR 500, a failing image, an event stream that must keep streaming) driven through a
  real WKWebView, as `scripts/probe-plugin-frames.sh` does for plugins.
- Owner's hands-on check: turn it on for a local dev server, break something, ask Claude Code in
  a terminal tab "why is the page broken?".

## Builder's calls (mine; the owner can overrule any of them)

- Tool names `read_console` / `read_network`, the limits and the header redaction list.
- Reads pass under every policy; the two switches are the gate.
- Origin (scheme + host + port) as the unit of "site".
- Capture follows the tab's main site; other sites' frames are never captured.
- Nothing captured is written to disk.
- Round 1 may ship without device choice or screen sharing if the spikes say WebKit can't do
  them cleanly.

## Settled after the builder's read-through (all my calls)

- **When a switch takes effect.** User scripts are fixed when a page starts loading, so the
  agents switch and the plugin switches apply from the **next load** of that site. The panel
  says so and offers a Reload button. Switching off also stops the tools answering at once,
  and drops what was captured.
- **The capture script runs in the page's own world, on purpose.** It has to, to see the page's
  `fetch` calls. So a page on a switched-on site can notice it and can feed it fake entries.
  That is accepted: only sites the owner switched on get it, and agents receive everything as
  untrusted page content. The anti-goal "a page can learn something about the browser" means
  pages of sites that are *not* switched on must see no trace of it.
- **Which tabs.** `tab` must be a web tab of that Space. Terminal and artifact tabs, and tabs
  of other Spaces, are refused. Capture starts empty when the site is switched on; nothing from
  before is available.
- **The button.** At the right edge of the address row in the sidebar, as its own button
  (the row's click-to-edit area ends before it). Hidden when the tab has no http(s) address.
  `http://localhost` and `http://127.0.0.1` show as "Local", not as "Not secure".
- **Camera, microphone, screen.** Allow skips WebKit's question for that site; macOS still asks
  once for the whole app. Block answers "denied" to the page without asking. Stored per Space
  and per site (origin). No extra confirmation when choosing Allow.
- **Reset and master switch.** "Reset site settings" clears everything for the Space, the
  agents switch included. Turning the Space switch off keeps the per-site choices but makes
  them inert.
- **Plugin switches.** Keyed by plugin id, kept across re-approval, and they stop only the
  page script; the plugin's background program keeps running.
- **Log.** Each `read_console` / `read_network` call appears in the Agent activity pane and
  `agent-log.jsonl` as tool + tab, without the content.
- **Cursor and caps.** The cursor is a counter that only grows. If older entries were dropped,
  the answer starts with "N earlier entries were dropped". 64 KB applies to each payload and
  each body separately; a tab keeps at most 4 MB in total, dropping the oldest first.

## As built (2026-11-10)

Built as designed, with these differences. All are the builder's calls, for the owner's review.

- **Device choice: left out.** WebKit has no public API to choose the camera, microphone or
  speakers for a page; the page picks among what `enumerateDevices()` lists. The design said not
  to fake it with script injection, so the panel has no Device row.
- **Screen sharing: left out.** The public `WKUIDelegate` only has a permission callback for
  camera and microphone (`requestMediaCapturePermissionFor`); the one for `getDisplayMedia` is
  private. The panel has no Screen row.
- **Camera and microphone.** "Allow" covers the page of the tab only: a frame from another site
  inside it still gets WebKit's question. "Block" covers everything in the page.
- **Capture is main frame only.** Frames are never captured, also frames of the same site.
- **Two scripts, not one.** A collector in the page's world, and a relay in a content world of
  the app's own that holds the message handler. A handler in the page's world would have been
  visible to every page the web view loads, which the anti-goal forbids. Both scripts compare
  `location.origin` with the switched-on sites before doing anything, and the app checks the
  sender of every message against the two switches again (`CaptureBridge`).
- **Request payloads sent as a `Request` object or a stream are not captured** (reading them
  would mean copying every such request up front). The entry says so.
- **A tab that hasn't been loaded since launch** answers "nothing was collected" instead of
  being loaded by the read.
- **Plugin switches** are applied in the plugin's prelude (the page script doesn't start), for
  the page and for frames inside it (a frame also looks at the tab's site). There is no second,
  native check per message: the switch only narrows, so a miss can't grant anything.
- **Reset site settings** is in Settings → Data & privacy, under "Clear…" per Space.

Where things are: `Sources/SingularityCore/Sites/` (model, rules, the capture store; unit
tests in `SiteTests.swift`), `Sources/Singularity/Sites/` (the scripts, the bridge, the panel),
`AgentToolbox.readCapture`, `Tests/SingularityAppTests/PageCaptureTests.swift` (the fixture page
in a real web view).

Owner's hands-on checks still open: the look of the panel; Allow and Block for camera and
microphone on a real site; a plugin switched off for one site; "why is the page broken?" asked
of Claude Code on a local dev server.
