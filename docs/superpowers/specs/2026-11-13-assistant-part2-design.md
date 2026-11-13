# The Assistant, part 2: browse with it

Design, 2026-11-13. Part 1 (`2026-11-13-assistant-part1-design.md`, read its "As built" section
first) gave a plain chat with no tools. This part lets the Assistant know which tab is in front,
read pages and act in the browser. Part 3 (terminals) is not in this document.

Status: part 2 built on 2026-11-13 (plan `docs/superpowers/plans/2026-11-13-assistant-part2.md`). The
"As built" section at the end says where the build differs from this design, and wins where they
disagree.

## As spiked (2026-11-13, throwaway, nothing kept)

With the real `claude` 2.1.323 and SDK 0.3.323: `mcpServers: { singularity: { type: "stdio", command,
args, env, timeout } }` with `strictMcpConfig: true`, `tools: []`, `settingSources: []` connects;
`allowedTools: ["mcp__singularity"]` lets every tool of that server run with no permission prompt; a
tool `work.read_page` appears to the model as `mcp__singularity__work_read_page`;
`notifications/tools/list_changed` is honoured in the middle of a turn; `query.interrupt()` during a
tool call sends the server `notifications/cancelled` with the request id. The MCP Swift SDK's
`Server` cancels the handler's `Task` on that notification (`Server.swift`,
`onNotification(CancelledNotification.self)`). So none of the design's fallbacks are built.

## Why

The owner: "since it cant do anything then lets start working on phase 2". The Assistant is meant
to be the built-in helper you browse with ("the Dia alternative in Singularity"): ask about the page
you are looking at without a terminal, and have it open, click and type for you.

## What success looks like

- With the Assistant switched on for the Space in front, "summarise this page" gives a summary of
  that page, and the chat shows a line saying the page was read.
- "Open the pricing page and compare the plans" opens tabs and reads them; in a Space whose policy
  is "Ask before acting", each acting step asks the owner first, in the Assistant's panel.
- With the Assistant switched off for a Space, it learns nothing about that Space: not the tab in
  front, not its tabs, and none of its tools exist for it. The panel offers a native button to
  switch it on.
- Outside agents (Claude Code or Codex in a terminal) see exactly what they saw before.
- A copy that already has the 0.7.0 Assistant installed can get the new one.

## Goals, non-goals, anti-goals

Goals:
- The Assistant uses the existing agent door (`singularity-mcp`): same tools, same Space policy,
  same approval rules, same agent log.
- Its own switch per Space, separate from the "agents" switch (owner decision).
- It is told where the owner is with every message, and reads a page only when needed (owner
  decision).
- An approval it caused can be answered where the owner is looking: in its panel or tab (owner
  decision).

Non-goals (not in this part):
- Terminals: seeing them, typing into them (part 3). Other providers. Generative UI in the chat.
- Any other tool for `claude`: no shell, no file tools, no web search or fetch of its own.
- Attaching page text automatically. A tool to switch Spaces or tabs for the owner.

Anti-goals (a failure even if it works):
- Page content reaching Claude without a visible line in the chat saying so.
- The plugin's own page or background being able to answer an approval.
- The Assistant seeing or touching a Space whose switch is off.
- Outside agents getting more than today, or a second way into the browser besides the door.

## Constraints

- Everything in part 1's "Things to keep" (CLAUDE.md, "Plugin panels and programs") still holds:
  the locked page, the program bridge, test copies start no programs.
- `AgentApprovalRules` does not change. Page-derived text given to Claude is untrusted and wrapped.
- No new dependency. The Agent SDK stays at the pinned version unless the owner approves a bump.
- Never activate a test copy; never run the real `claude` outside the opt-in tests.

## Approaches (how the Assistant learns where the owner is)

1. **Everything through the door.** The Assistant's connection gets one extra tool, `front`, and
   asks when it needs to know. One way in, all logged; but it is not told with each message and may
   fail to ask.
2. **The door, plus a plugin ability "knows the tab in front". (Chosen by the owner:** "there are
   genuine usecases that plugin needs to know what you are looking at".**)** The background reads
   the tab in front and attaches it to every message. Cost: a second, read-only route by which a
   plugin learns what is browsed, outside the agent log, that any future plugin can request (shown
   at approval, limited to Spaces where that plugin is switched on).

Dropped early: giving the plugin its own browser API instead of the door (a second way in; the
owner decided against it in part 1).

## 1. The switch: a plugin's Space switches

**My call:** "its own switch per Space" is the plugin's existing per-Space switch
(`PluginApproval.enabledSpaces`), not a new field on `Space`. Today those switches are shown only
for plugins with a page script. From now on they are shown for a plugin that has a page script **or**
either new permission below, and for such a plugin they also mean "may know this Space's tab in
front" and "may use this Space through the door".

- Off by default for every Space, as today. The approval sheet's switches start off for a plugin
  with the new permissions.
- Where it is changed: the approval sheet, Settings → Plugins (the plugin's row), and the native
  strip in the panel (section 5). All three are native and the owner's click.
- A change applies at once: the tool list of the plugin's connection is re-sent
  (`tools/list_changed`), `front` answers differently, and requests waiting for a Space that was
  just switched off are denied.
- Deleting a Space already removes it from every plugin's switches.
- **Switching off works forward only (my call).** What the Assistant already read from that Space
  stays in the running conversation and in Claude's session; New Chat clears it. The README says so.

## 1a. Off for one site

Owner decision (asked after the builder check): the existing per-site switch "plugins off for this
site" (site settings, per Space and site) covers the Assistant too.

- The site settings panel lists a plugin when it is switched on for the Space and has a page script
  **or** `frontTab` **or** `browser` (today: page script only).
- A plugin switched off for a site, in that Space:
  - `front` answers `null` while the tab in front is on that site (and the native strip of section 5
    is not shown: the Space is on, the site is off; the chip says "Nothing shared from this site").
  - Its connection's `list_tabs` leaves that site's tabs out; `read_page`, `find`, `click`, `type`,
    `screenshot`, `close`, `read_console` and `read_network` refuse a tab that is on that site
    ("<Title> is switched off for this site"); `open` and `navigate` refuse an address on that site.
    Each call checks where the tab is *now*.
  - A click or redirect can still carry a tab onto such a site; from then on the tab is refused like
    any other tab there. That is the limit of this switch and the README says so.
- Outside agents are not affected by this switch (they have their own per-site settings).
- The rule is one pure function in Core, used by `front` and by the door.

## 2. New plugin ability: the tab in front (`permissions.frontTab`)

Manifest: `"permissions": { "frontTab": true }`. Approval sheet text: "Know which tab is in front
(its Space, title and address), in Spaces where it is switched on". Adding it to an approved plugin
is a widening: it pauses until re-approved.

Background API in `host.ts`:

```ts
singularity.front(): Promise<FrontTab | null>
singularity.onFrontChange(handler: (front: FrontTab | null) => void): void

type FrontTab = {
  space: { slug: string; name: string };
  tab: { id: string; kind: "web" | "artifact" | "terminal"; title?: string; url?: string };
};
```

- "In front" is the selected tab of the selected Space of the **main window** (in a split: the
  focused pane). Little windows are never in front.
- **A plugin's page is never the tab in front (my call, for every `frontTab` plugin).** Focusing a
  pane selects its tab, so an Assistant opened as a tab would otherwise be "in front" itself. When
  the selected tab is a plugin tab: in a split, the answer is the pane of that split that was
  focused last and isn't a plugin tab; alone, the answer is `null` (the page fills the window, so
  nothing else is in view; the chip says "No page in view").
- `null` when: the Space in front is not switched on for this plugin, the welcome flow covers the
  window, or the Space has no tab. The plugin is not told which of these.
- `title` and `url` only for `web` and `artifact` tabs. A terminal tab gives its kind and
  id only (terminal titles carry folders and commands; that is part 3's decision).
- `onFrontChange` fires when the answer changes (other tab, other Space, new address or title, a
  switch flipped), at most about twice a second.
- Title and address come from the page: they are untrusted text. The app hands them over as plain
  strings, cut to 300 and 2000 characters; a plugin that passes them to a model must mark them as
  untrusted (the Assistant does, section 6). The guide and its review checklist say so.
- Not written to the agent log (the owner accepted this cost when choosing approach 2).

## 3. New plugin ability: use the browser like an agent (`permissions.browser`)

Manifest: `"permissions": { "browser": true }`; needs `programs` (refused otherwise: only a running
program can connect). Approval sheet text: "Use the browser like an agent, in Spaces where it is
switched on: read pages, and open, click and type under each Space's agent policy". A widening too.

What the plugin gets:
- `singularity.browser.server(): { command: string; args: string[]; env: Record<string, string> }`:
  how to start the app's own `singularity-mcp` (the launcher of the running bundle, and in a test
  copy the socket of that copy). The plugin passes this to its program as an MCP server. It is the
  only way the launcher's path reaches the plugin.
- The app lets the program started by `singularity.spawn` reach it: nothing to add, the program is
  already outside the sandbox.

How the app treats the connection:
- **Recognising it.** A connection on the agent socket whose peer process descends from the running
  program of a plugin with `browser` is *that plugin's connection* (the same ancestry check the hook
  socket uses for a tab's shell). Everything else is an outside agent, exactly as today. The
  launcher itself is unchanged.
- **Which Spaces.** A plugin's connection gets `list_spaces` and `<slug>.<tool>` for the Spaces
  switched on for that plugin, whatever their "agents" switch says. An outside agent's set is
  unchanged (`agentsEnabled`). Every call re-checks the switch, so a tool name remembered from
  before is refused once the Space is off.
- **Same tools.** `list_tabs`, `open`, `navigate`, `close`, `read_page`, `find`, `click`, `type`,
  `screenshot`, and `read_console` / `read_network` under their two existing switches. No new tool.
  Plugin tabs stay invisible to it, like to any agent.
- **Same policy and approvals.** The Space's `agentPolicy` and allowed sites apply as they are
  (shared with outside agents: "Allow on this site" given to one counts for the other). The limit of
  5 waiting approvals per Space and the timeout are shared too.
- **Same log.** Calls go to the Space's `agent-log.jsonl` with the plugin's panel title as the
  client ("Assistant"); tabs it opens carry `openedByAgent`; tabs it works on pulse.
- **Settings → Agents.** A Space's policy picker is enabled when its agents switch is on **or** a
  plugin with `browser` is switched on for it; the row says which ("Assistant").
- A plugin's connection ends with its program. A plugin that is paused, removed or re-approved has
  no program, so no connection.

## 4. Approvals in the Assistant's panel

One request is one inbox entry, as today; this adds a second place to show and answer it.

- An approval caused by a plugin's connection carries that plugin's id.
- While that plugin's page is on screen (its panel is shown, or its tab is on screen, in the main
  window, app active), the entry is also drawn as a **native card at the bottom of the page area**
  (`PluginPanelView`'s area, shared by panel and tab), above the page, which is made shorter. Same
  text and buttons as the inbox card (Allow / Allow on <site> / Deny / Show Tab), same 0.5 s click
  lock, same re-check on answer. Several waiting: stacked, oldest first, at most 3 drawn plus
  "and N more in the inbox".
- Then the inbox panel does **not** open by itself and no banner is sent; the entry is still in the
  inbox list and counts on the tray. When the page is not on screen (panel hidden, tab not shown,
  another app in front), everything is as today: the inbox opens or a banner is sent (owner: the
  inbox "would be nice if for some reason the agent panel is hidden or agent tab is not in view").
- The card's buttons are never default buttons and never take the keyboard: the chat input keeps
  the focus, and Return or Space typed there can't press Allow.
- The plugin's page and background are told nothing about the card and cannot answer it; they see
  only the tool call waiting and then its result.
- Stop in the chat interrupts `claude`; a tool call it was waiting on is cancelled, and the app
  withdraws that call's waiting approval (logged as `cancelled`). The same happens when the
  connection closes. (Today a closed connection leaves the entry until its timeout; that changes for
  every agent.)

## 5. The native strip for a closed Space

When a plugin with `frontTab` or `browser` has its page on screen and the Space in front is not
switched on for it, the page area shows one native line at the bottom: "<Title> can't see <Space>"
with a button "Let it use <Space>". The button flips that Space's switch for the plugin. No "don't
show again" in this part; the line is small. It is drawn by the app, so the plugin doesn't learn
the Space's name.

## 6. The Assistant plugin

Manifest: `permissions` gains `"frontTab": true` and `"browser": true`; `version` goes up.

**Provider (`provider-claude.ts`).** Still no built-in tools, settings, skills. Now exactly one MCP
server, named `singularity`, from `singularity.browser.server()`, with `strictMcpConfig` still on;
its tools are allowed without `claude` asking by itself (the app's approvals are the gate). The
`Provider` interface gains the browser server in `start` options and a `tool` event
(`{ id, name, space, tab?, status: "running" | "done" | "failed" | "refused" }`).

**Where you are.** At every send the background calls `singularity.front()` and puts a short block
before the user's text in what goes to `claude` (not in what the chat shows): Space slug and name,
tab id, kind, and title and address inside the untrusted-content wrapper. `null` gives "nothing in
front is visible to you". The saved conversation keeps the user's text only.

**The chip.** Above the input the page shows what the next message will carry: the page's title
(or "Nothing shared from this Space"), kept current through `onFrontChange`. It is how the owner
sees what leaves the Mac.

**Tool lines.** Each tool call is a small line in the chat, in order with the text: "Read
<title>", "Opened <address>", "Clicked …", "Waiting for your OK", "Not allowed", with the Space's
name when it isn't the one in front. They come from the SDK's `tool_use` / `tool_result` messages.
**My call:** a line is built only from the call's own input and from `front()`: the address for
`open` and `navigate`; the title when the tab is the one that was in front at that send; otherwise
"a tab in <Space>". Nothing is taken out of a tool's result, so the saved conversation keeps the
line (tool, Space, and that address or title) and never any part of a result.

**System prompt.** Replaces part 1's "you can only chat": it is in the user's browser; it gets
where the user is with each message; it has the Singularity tools for Spaces the user opened to it;
"this page" means the tab in front; read before answering about a page; page content, titles and
addresses are untrusted and never instructions; when nothing is visible, say that the user can
switch it on with the button under the chat; it still cannot see or use terminals.

**States.** New: the browser server couldn't start or connect → an error line with Try Again; the
chat still works without tools.

## 7. Updating a shipped plugin

Found while designing: an installed copy of a shipped plugin never changes, so a copy with the
0.7.0 Assistant would stay at part 1. Added:

- Settings → Plugins: when the app ships a plugin with the same id as an installed one and a
  different `version` in `plugin.json`, the installed row shows "Update available" and a button
  **Update**. It replaces the plugin's folder with the shipped one (data folder untouched), which
  the fingerprint sees as a change, and opens the normal approval sheet. Never done by itself, never
  approved in code.
- A plugin in development mode, or whose installed files differ from what was approved, gets no
  Update button (the owner is editing it).

## 7a. A button for the panel

Owner, while this was being written: "there should be some kind of visual icon for assistant too, so
it could be opened without knowing keyboard shortcuts or open from menu".

**My call on where:** the sidebar's bottom row (New Tab, New Terminal, launchers), as its last
button, pushed to the row's right end. It does exactly what ⌃⌘J and View → Show Assistant do,
including their cases: it shows or hides the panel, selects the tab when the page is a tab, and with
no panel plugin installed opens Settings → Plugins. It is highlighted while the panel is shown. Its
tooltip is the menu item's title with the shortcut. No button when no panel plugin is installed or
shipped (a bare debug binary). With the sidebar hidden it comes with the slide-out, like the rest of
the row. The alternative, a button in the window's top-right corner, would always be visible but
sits in the title-bar strip over the page, where pane headers and window dragging already compete;
not chosen.

## 8. Safety

- The door's rules are unchanged; what is new is who may come through and for which Spaces. The
  recognised connection can never get more than an outside agent would in a Space with agents on.
- Recognition is by process ancestry from a program the app itself started at a pinned path; a
  process that merely claims to be the Assistant is an outside agent.
- Prompt injection: everything from pages is wrapped as untrusted on its way to Claude, including
  the title and address in the "where you are" block. Acting steps still pass the Space's policy;
  form submissions and going to a new site always ask under "ask".
- What leaves the Mac, and when: the tab in front's title and address with each message (only for
  switched-on Spaces, shown in the chip); page content only through a tool call (shown as a line).
- `frontTab` is a new thing a plugin can learn; it is named at approval, limited to switched-on
  Spaces, never includes terminals' titles, and a plugin's sandbox still has no network.

## 9. Documents

`CLAUDE.md` (scope note: part 2 built; the two abilities; the switch's new meaning; what to keep),
`docs/plugins/AUTHORING.md` (both permissions, the APIs, the untrusted-text rule, the review
checklist), the plugins spec, `IDEAS.md`, the plugin's README, and an "As built" section here.

## 10. Tests

- Core (pure): which Spaces a connection gets (outside agent vs plugin's connection, switch
  on/off, deleted Space); what `front` answers for each tab kind and for a closed Space; manifest
  rules (`browser` needs `programs`; both are widenings); when a plugin shows Space switches; when
  an approval is shown in the page area vs opens the inbox; shipped-plugin update offer.
- App: the fixture program connects through the built `singularity-mcp` to a test app state's
  socket and is recognised; an unrelated process is not; switch off mid-connection refuses the next
  call; an approval caused by the plugin shows the native card and answering it releases the call;
  the card never becomes key or default; cancel and a closed connection withdraw the entry;
  `front` and `onFrontChange` against a real `AppState`.
- Bun: the "where you are" block and its wrapping; tool lines from fake SDK messages; the saved
  conversation never holds a tool result; the provider passes exactly one server.
- Opt-in, owner's account, as in part 1: `RealAssistantTests` gains one message that makes the real
  `claude` call a tool of a **fixture** MCP server (no app, no browser), to prove the wiring.
- By the owner's hands: the whole thing in the running app.

## To prove first (the plan's first task, a throwaway spike)

With the pinned SDK and the real `claude`: one MCP server passed in code works with
`strictMcpConfig` and no settings; its tools can be allowed without a prompt from `claude`; tools
whose names change during a conversation (`tools/list_changed`) are picked up; an interrupt cancels
a waiting tool call so the server sees it. Fallbacks (my calls):
- Tools can't be allowed up front → the background answers the SDK's permission callback with
  "allow" for the `singularity` server's tools only. Acceptable: the app is the gate, not `claude`.
- Changed tool names aren't picked up → after a switch flips, the program is restarted with
  `resume` once the running answer has ended; the new set counts from the next message. Switching
  off is enforced by the app at every call either way. No tool with a Space argument is added.
- An interrupt doesn't reach the server → the plugin tells the app to withdraw its own waiting
  approvals (a host call that can only withdraw, never answer).

## Left to the builder

- The exact text of the "where you are" block and the system prompt; the look of tool lines, the
  chip and the native card and strip (follow the inbox card and part 1's page).
- How ancestry is read and cached; where the plugin id travels from connection to inbox entry.
- Names of internal types and files.

## As built (2026-11-13)

Built on the branch `assistant-2` in eight tasks (plan `docs/superpowers/plans/2026-11-13-assistant-part2.md`).
Where this section and the design above disagree, this section is what the code does.

### Decisions and differences, in the order of the design

**1. The switch.**
- As designed: the plugin's existing per-Space switch (`PluginApproval.enabledSpaces`), no new field on
  `Space`. `PluginManifest.reachesSpaces` (`frontTab` or `browser`) is the rule that shows the
  switches, together with having a page script (`showsSpaceSwitches`). A plugin with a panel but
  neither permission and no page script still shows none.
- A change applies at once: the plugin is told the front tab again, its connection gets
  `tools/list_changed`, and its waiting approvals for that Space are denied
  (`InboxCenter.denyApprovals(ofPlugin:inSpace:)`, called from `PluginManager.setEnabled`).
- `tools/list_changed` reaches a plugin's connection only when its own list changed (it compares the
  tool names and descriptions it was last given). A switch of a plugin never notifies outside
  agents (`MCPHub.toolsChanged(pluginsOnly:)`).

**1a. Off for one site.**
- The site settings panel lists a plugin that is on for the Space and has a page script that runs
  there, or `frontTab`, or `browser` (`PluginReach.listedForSite`).
- **The site is judged by the tab's live address**, for web tabs and for artifact tabs: a page that
  was redirected or moved on counts where it is now (the stored address counts too, for a web tab).
  An artifact tab whose live page has left the Space's artifact server counts as the web page it
  shows: for the door's checks, and for `front`, which then says kind `web` with that address and
  never an artifact file path.
- The door's list of refusals is as designed (`list_tabs` leaves the tab out; `read_page`, `find`,
  `click`, `type`, `screenshot`, `close`, `read_console`, `read_network` refuse it; `open` and
  `navigate` refuse an address on that site before anything is loaded or asked). The check is made
  before the call and, for `read_page`, `find` and `screenshot`, again after the read.
- **Stronger than the design's limit.** While a plugin's connection runs a `click` or `type`, the
  navigation guard (`installNavigationGuard`, the same one that asks about going to another site)
  cancels any navigation of the page's main frame onto a switched-off site, and the call's log value
  gets `+nav_site_off`. A redirect or a script that moves the page without a navigation the guard sees
  can still land there. From then on the tab is refused like any other tab on that site, and the
  result of that call says "Now at a site <Title> is switched off for." instead of the address and
  title.
- The refusal text is `<Title> is switched off for this site.` (`AgentCaller.siteOff`).

**2. `frontTab`.**
- As designed. `singularity.front()` and `onFrontChange` are in `host.ts`; `front()` rejects with
  `needs the frontTab permission` at once, in the plugin, when the manifest has no `frontTab`
  (host.ts learns the flags from its third argument); the app answers `null` too.
- A plugin that never asked is told its first front on the first change. Changes are sent at once,
  or once more after 0.5 s, and only when the answer differs from what the plugin last heard
  (also from a reply). The app calls `frontDidChange` from one place, `loadSelectedTab()`, so closing,
  opening, splitting, the welcome flow and Space changes all tell the plugin.
- A plugin tab in a split with no recorded focus falls back to the first pane that isn't a plugin
  tab. A plugin tab alone: `null`.
- `title` is `displayTitle`, cut to 300 characters; an artifact's `url` is its file path.

**3. `browser`.**
- **`singularity.browser.server()` returns a Promise** (the design showed a plain value). The answer
  goes over the wire as `browserServerRequest` and comes back as `reply`; `null` without the
  permission or without a launcher beside the app.
- **Recognising the connection.** The caller is decided once, when the connection is accepted, from
  the peer's pid (`LOCAL_PEERPID`): a descendant of the running program of an approved plugin whose
  manifest and approval both have `browser` (`PluginManager.pluginOwning(pid:)`). A pid that can't be
  read means an outside agent. The connection remembers **the program's pid it was accepted under**;
  every call checks that this is still the plugin's running program
  (`PluginManager.programPID(of:)`, which reports a pid only while the program is unreaped, so it is
  never a recycled one). **A plugin's connection ends with its program:** when the program exits or
  the plugin stops, is paused, changed or removed, `MCPHub.closeStaleConnections(ofPlugin:)` shuts
  the connections made under an older program, and until then their calls are refused.
- **Which Spaces.** As designed: the Spaces switched on for the plugin, whatever their "agents"
  switch says, re-checked at every call and again after an approval has been waited for. **A call
  naming a Space that is not open to the plugin gets the plain "Unknown tool … Call list_spaces to see
  what is available." and writes no log line.** The design's text "<Title> is switched off in the
  “<Space>” Space." (`AgentCaller.spaceOff`) is therefore not used for this case: it would tell a plugin
  the name of a Space it was never given by guessing slugs. This holds for a Space that was switched
  off, and for one that was closed or deleted. Outside agents keep their own text.
- The log's client and the approval card's actor are the plugin's panel title (the manifest's name
  without a panel). `list_spaces` with no Space open says "No Spaces are open to <Title>. …"
  (`AgentCaller.noSpaces`); its tab counts leave out tabs on switched-off sites. The server's
  instructions for a plugin say "switched on for <Title>".
- **`read_console` and `read_network` still need the Space's own "agents" switch** (`InspectionRules`
  is unchanged: capture runs only when the Space's agents switch and the site's switch are on). So a
  Space that is on only for the plugin has no console or network tools. Known gap, on purpose:
  widening capture is a decision of its own.
- Settings → Agents: the policy picker is enabled when agents are on or a plugin with `browser` is
  switched on for the Space, and a line under the row says "Also used by <Title>[, …]".

**4. Approvals in the plugin's page area.**
- An approval caused by a plugin's connection carries the plugin's id into the inbox entry. While the
  plugin's page is on screen (`AppState.pluginPageOnScreen`: app active, main window visible and key
  or main, no welcome flow, and the panel actually drawn at this window width, or a tab of the plugin
  among the selected Space's visible tabs), `InboxRules.shownInPluginPage` is true: the inbox panel
  does not open by itself, and no banner or Dock bounce is made. The entry stays in the inbox list and
  on the tray.
- The cards are `InboxCard` itself, drawn under the page (`PluginPageCards.swift`), at most 3 and
  "and N more in the inbox". Answers go through `inbox.perform`, so the 0.5 s lock
  (`pageCardsAppeared` sets it, as `panelAppeared` does) and the re-check against the Space's current
  policy are the same. No button is a default button or has a keyboard shortcut, and the card buttons
  are not focusable (an environment value, `inboxCardButtonsTakeFocus`, false in the page cards; the
  link-style buttons "Show Tab" and "Go to terminal" are drawn as plain buttons there, because AppKit's
  link button takes the first responder even when told not to). The inbox panel is unchanged.
- The page area's layout keeps the page in the same place in the view tree, so its web view is never
  rebuilt when a card comes or goes. Cards also show while the page says "is starting" or "isn't
  running".
- **The strip.** With no card and the Space in front not switched on for the plugin
  (`front` is `.hidden(.spaceOff)`, only for a plugin with `reachesSpaces`, only under the live page),
  the page area shows "<Title> can't see <Space>" with a button "Let it use <Space>", which switches
  that Space on for the plugin (`letPluginUseSpace`). The strip is not shown for a site that is off,
  or when nothing is open.
- **Cancelling.** A call whose task is cancelled withdraws its waiting approval at once
  (`AgentApprovals.Outcome.cancelled`, refusal "The request was withdrawn.", log value `cancelled`;
  `AgentApprovalRules` did not change). The MCP SDK cancels a call's task on the client's
  `notifications/cancelled`, **but not when a connection closes**: `MCPHub` therefore runs every
  `CallTool` as its own task, remembers it per connection (`RunningCalls`), and cancels them all when the
  connection ends, **for every agent, not only the Assistant** (this changes what an outside agent's
  closed connection does: its waiting approvals are withdrawn at once instead of at their timeout). A
  call that arrives after the end gets "The connection was closed.".
- Every exit of a waiting approval (answer, timeout, withdraw, Space switched off for the plugin,
  Space deleted, tab closed, quit) goes through `finishApproval`, which takes the record out first, so
  each waiter is resumed exactly once.
- **Approvals raised by the navigation guard are not withdrawn by a cancel.** They are asked inside
  WebKit's navigation delegate, on a task that isn't the tool call's. A cancelled `click` or `type`
  that was waiting on "go to another site" leaves that card until it is answered or times out. Known
  gap.

**5. The Assistant plugin (version 0.2.0).**
- `plugin.json` asks for `frontTab` and `browser`; the plugin's own files for this are `front.ts`
  (the block, the chip, tool names and lines), `provider-claude.ts` (one MCP server and
  `allowedTools: ["mcp__singularity"]` when the app gave one; still `tools: []`, `settingSources: []`,
  `skills: []`, `strictMcpConfig`), `background.ts`, `panel.tsx`.
- The tab in front is asked at `hello` (for the chip) and at every send, and goes into what is
  sent to Claude as a block before the user's text (`frontBlock`): Space slug and name, tab id, kind,
  and the title and address inside `<untrusted-content source="tab in front">`, with whitespace
  collapsed and `<` and `>` replaced. It is never shown and never saved: the chat and
  `conversation.json` keep only what the user typed.
- **The chip** above the input says the tab's title, else its address, else "Untitled tab", and
  "Nothing shared from here" when there is no front tab (the design said "Nothing shared from this
  Space" / "this site" / "No page in view"; the plugin is not told why). It follows `onFrontChange`.
- **Tool lines.** A line is built from the call's own input and from the tab that was in front when the
  message was sent; nothing a tool answered is used. Examples: "Read <title>", "Looked for “…” on
  <title>", "Opened <address>", "Went to <address>", "Clicked on <title>", "Typed on <title>", "Took a
  picture of <title>", "Listed the tabs", "Looked at your Spaces"; a Space other than the one in front
  adds " in <slug>". A tab that isn't the front tab is "a tab". The suffix " — waiting for your OK"
  is shown only for the acting tools (open, navigate, close, click, type), only while the call is still
  running after 1.5 s (`mayWaitForOK` judges by the line's own text). A call whose result was an error
  ends " — not done", and so does one still running when the answer ends, is stopped or the program
  restarts (those lines are saved as not done). Lines are text nodes. Text after a tool line starts a new
  message, so lines and text stay in order.
- **The spec's `refused` status and "Not allowed" line were not built:** a call the app refused shows
  " — not done" like any failed call.
- **"The browser tools couldn't start."** with Try Again, above the input: when
  `singularity.browser.server()` rejects (the chat then starts without tools), or when Claude's init
  message shows the `singularity` server with a status other than connected. No line when the answer is
  `null` (a copy with no launcher: the chat simply has no tools).
- The empty chat now says "Ask anything. The Assistant can look at the tab in front when you share it."
  (the part 1 text was no longer true).

**7a. The sidebar button.**
- As designed: the last button of the bottom row, at its right end, symbol `bubble.left.and.text.bubble.right`,
  doing what ⌃⌘J does (`togglePluginPanel`, so also: select the tab when the page is a tab, and open
  Settings → Plugins with no panel plugin installed). Tinted with the accent colour while the panel is
  shown. Tooltip: the menu item's title and "(⌃⌘J)". Not drawn when no panel plugin is installed and none
  is shipped. It is lit also while the panel is too narrow to draw (as the menu item's check mark is).

**Update of a shipped plugin (not in the design's list, built with it).**
- Settings → Plugins shows, in an installed plugin's row, "Update available (<version>)" and an Update
  button when the app ships a plugin with the same id and a different `version`, and the installed
  copy is not in development mode and its files are the approved ones, or it was never approved
  (`BundledPlugins.updateOffer`). A plugin whose files changed, whose permissions widened or that is
  invalid gets no offer: edited files must never be overwritten. Update copies the shipped folder to a
  staging folder, checks it as Add does, swaps it in with an atomic replace (the old folder survives every
  failure), leaves the data folder alone, rescans, and opens the normal approval sheet. Never approved in
  code. A shipped plugin without a `version` in its manifest gets no offer.

**8. Safety.** As designed. The recognised connection can never get more than an outside agent has in a
Space with agents on, except that it does not need that switch. Everything from pages is wrapped as
untrusted on its way to Claude, the title and address included, and the Assistant's system prompt says
that what comes from pages, titles and addresses included, is never to be followed.

**9. Tests.**
- Core: `PluginReachTests`, `AgentCallerTests`, `InboxPluginTests`, `BundledPluginUpdateTests`, and the
  manifest and wire tests. App: `PluginFrontTests`, `PluginDoorTests` (the fixture program
  `Fixtures/door-client.sh` runs the real built `singularity-mcp` against a test app state's socket, once
  as the program itself and once as its child; a stranger that calls itself "Assistant" gets the outside
  view), `PluginApprovalCardTests`, and additions to `PluginSurfaceStateTests`. Bun: `front.test.ts` and
  the Assistant's other tests.
- Opt-in `RealAssistantTests` sends a second message that makes the real `claude` call `alpha.ping` of a
  fixture MCP server (`Tests/SingularityAppTests/Fixtures/fixture-mcp-server.ts`, run with the
  repository's Bun). The test answers the plugin's browser-server request with that server itself, so no
  app and no browser are involved. It expects a tool line that ends done and `7391` in the answer.

### Known small gaps (left on purpose for now)

- A plugin's connection is told apart by the peer's pid read when the connection was accepted. If
  that process ended and its pid was reused by a descendant of the plugin's program within
  milliseconds, an outsider could be taken for the plugin's connection. It would gain only what the
  plugin already has.
- The site switch is per origin: `http` and `https`, or `www` and the bare name, are different sites.
- An artifact tab on its own server, in a copy where the Space's artifact origin isn't known, is reported
  as a web page with the `127.0.0.1` address. Addresses that aren't http or https (`about:blank`,
  `blob:`, `data:`) count as web pages and are not covered by the site switch.
- `list_tabs` still says kind `artifact` for an artifact tab whose page has left its server.
- The plugin's title is shown as the card's actor as it is: a plugin titled like an outside agent would look
  like one.
- A tab's stored title is not cleared when its site changes; a titleless page can briefly be shown with
  the title of the page before it.
- `openPopup` selects a tab without telling the plugin until its first title or address change.
  A plugin that never asked for the front tab can be sent a `null` first.
- The strip and chip wording differ a little from the design (the plugin isn't told why nothing is shared).
- Tests: some wait 700 to 800 ms in real time; the tests of the site refusals of `find`, `click`, `type`,
  `screenshot` and `read_console`, and of the navigation guard's extras, are missing (`read_page`, `close`,
  `open`, `navigate` and `list_tabs` are covered); `PluginPageCards` views are checked through their logic and
  by a measured focus test, not by a picture; the sidebar button's view is not inspected; two Assistant
  tests are missing (a tool result with no matching use; an interrupt in the middle of a tool at the
  provider level); no run captured red-first for some of the later tests.
- A shipped plugin without a `version` silently gets no update offer; a failing swap leaves the old
  folder (checked by reading, not by a test); an error of the rescan after an update is not shown.
- `host.ts`'s question to the app (`askApp`) never times out.
- The Assistant's tool-line "waiting" suffix depends on the wording of the line (`mayWaitForOK`).
- Switching a Space off works forward only: what the Assistant already read stays in the running
  conversation and in Claude's session; New Chat clears it.

### Not checked without the owner's hands

The whole thing in the running app: the approval cards' look and that typing in the chat can't press
them (Return and Space in the input, the cards in the panel and in a plugin tab), the strip and its
button, the chip following the tab in front, the tool lines while a real page is read and a real
acting step waits, the sidebar button (lit, tooltip, hidden sidebar), the Update row after an app
update, and a real approval answered in the panel and then one answered in the inbox. Tests drive the
same code against off-screen windows and a fixture program; the opt-in `RealAssistantTests` is for the
owner's own account and has not been run.
