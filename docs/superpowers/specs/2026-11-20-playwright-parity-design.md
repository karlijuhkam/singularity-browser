# Agent door at Playwright parity: design

Status: **approved for building on 2026-11-20.** The owner chose option A (our own tool names,
Playwright's abilities) and option 3 (real input where WebKit allows it, measured first), then
said: build it, and when it works like Playwright, merge to main and release. Everything marked
"my call" is the builder's and stands until the owner's review.

## Intent: why

The owner wasn't sure how good the browser support for agents is. A bench of 17 local fixture
pages (2026-11-20) run through the door (`<slug>.*` tools) and through Playwright MCP 0.0.86 showed
that the door handles plain pages, forms, open shadow DOM and SPAs, but fails where real sites
are hard:

- **iframes are invisible** (payment fields, sign-in widgets, embeds): `PageAgentScript` is main
  frame only.
- **`alert`/`confirm`/`prompt` in an agent's background tab are answered silently** (OK, Cancel,
  null) and the agent is never told.
- **File inputs** show as a textbox, and `type` fails with "InvalidState".
- **No keys** (Escape, arrows, shortcuts), **no drag**, **no hover**, **no waiting** for content.
- **Masked inputs** that build their value from `keydown` stay empty, while the tool says "Typed".
- Every click is `el.click()` in JavaScript (`isTrusted=false`): it goes through cookie banners
  and hits hidden elements; some sites ignore such clicks.
- `<select>` options and table structure are not in `read_page`.
- **Bug:** a `window.open` pop-up from an agent's click becomes the selected, visible tab in the
  owner's window, without `opened_by_agent`, and the click's answer doesn't mention it.

Playwright handled all of these (closed shadow roots fail in both). Goal: an agent in Singularity,
outside or the Assistant, can do the same real-site work it could do with Playwright MCP, under
the same Space policy, approvals and agent log as today.

## Goals

1. Frames: read and act inside iframes, same-origin and cross-origin, nested.
2. Trusted clicks and keys where WebKit allows it; honest answers where it doesn't.
3. Dialogs and file choosers become a waiting state the agent sees and answers.
4. New tools: `press_key`, `wait_for`, `handle_dialog`, `file_upload`, `hover`, `drag`.
5. `type` gets `slowly` (real keystrokes, one per character).
6. `read_page`/`find` show `<select>` options, listbox/combobox options, table rows, slider
   values, `draggable` items and clickable elements that have no role (`cursor: pointer`).
7. The pop-up bug is fixed.
8. The Assistant knows the new tools: names, tool lines, prompt.

## Non-goals

- Playwright's tool names or ref format (owner: option A). Tools stay `<slug>.<tool>`, refs stay
  numbers in the main frame.
- `evaluate` / `run_code` (arbitrary JavaScript): it would bypass the per-element checks (does this
  click submit a form? leave the site?). Goes to `IDEAS.md` under "New, not yet decided". **My call.**
- `fill_form`, `select_option`, `resize`, `navigate_back`, `tabs select`, `pdf`: covered by
  existing tools or not worth a tool per Space (the owner has about nine Spaces; each tool is
  listed once per Space). `type` already picks `<select>` options. **My call.**
- Console and network stay as they are (failures only, two switches): an owner decision of
  2026-11-10.
- Closed shadow roots: unreachable for both.

## Anti-goals

- An agent's key or click must never reach anything but its page: not the owner's focused
  terminal, not a menu shortcut (⌘W, ⌘Q), not the inbox's key monitor.
- An agent action must never put a modal panel or sheet in front of the owner.
- No loosening of approvals: every new acting tool goes through `authorize`, the navigation guard
  and cancellation, like `click` and `type`.

## What the spikes measured (scratch programs, 2026-11-20)

- `NSEvent` mouse down/up and key down/up handed straight to a `WKWebView` (`web.mouseDown(with:)`,
  `web.keyDown(with:)`) reach the page as **trusted** events, with no window, in an off-screen
  window, and in a window that is not key, in an app that is not active. Nothing is activated.
- Coordinates: CSS px × `pageZoom` (× `magnification`), in a flipped `WKWebView` (y from the top);
  converted with `webView.convert(_:to: nil)` when the view is in a window. Correct for a view that
  doesn't fill its window, after scrolling, at `pageZoom` 1.5, and two iframes deep (adding each
  iframe's client rect plus border/padding).
- A direct `mouseDown` did not change the window's first responder.
- Keys reach the page after a trusted click in it, even when the web view isn't first responder.
- **Leak:** keys the page doesn't consume are re-sent by WebKit through `NSApp.sendEvent`: a letter
  landed in another window's text field and ⌘W fired the menu item. Synthesized events are
  recognised by their exact `timestamp` (WebKit keeps it) and swallowed by a local event monitor:
  then nothing leaked in any mode.
- `mouseMoved` (hover) and `mouseDragged` (drag) produced **no** page events; a native drag attempt
  also broke later key delivery in the windowless case. Hover and drag therefore stay synthetic.
- Frames: a user script with `forMainFrameOnly: false` in our content world runs in every frame. The
  parent's script posts `{__sgAgent: nonce, token}` to `iframe.contentWindow`; the child's
  capture-phase listener (added at document start) calls `stopImmediatePropagation()` and reports the
  token to a message handler in our world, whose `WKScriptMessage.frameInfo` is then usable with
  `callAsyncJavaScript(_:arguments:in: frame, contentWorld:)`. Works cross-origin; the page's own
  `message` listeners never saw it.

## Approaches considered

1. Better synthetic JS events only: works everywhere, but `isTrusted=false`, clicks pass overlays.
2. Native events only: hover and drag don't work natively (measured).
3. **Chosen (owner):** native click and keys, synthetic hover and drag, measured first; the answer
   says when an event was synthetic.

## Design

### Frames

- `PageAgentScript` is injected into every frame (`forMainFrameOnly: false`), in its world.
- Each document mints a random frame id at document start; refs live per document.
- `snapshot` in a frame lists an `iframe` element as `iframe "<title or src>":` and, for each child
  frame that answered the handshake, the native side inserts that frame's snapshot indented under
  it. Refs inside a frame are written `[f<N>:<ref>]` (N = the native frame number, stable for the
  life of that frame document); main-frame refs stay `[12]`.
- `ref` arguments accept an integer or a string (`"12"`, `"[12]"`, `"f2:5"`).
- Handshake: the parent posts to each `iframe.contentWindow` with a per-load nonce; at most 50
  frames per page and 2 levels deep, at most 300 ms waiting for answers (my call). A frame that
  doesn't answer is listed as `iframe "<src>" (not readable)`.
- **Per-site off applies per frame:** for a plugin's connection, a frame whose origin is on a site
  the plugin is switched off for is listed as `iframe (switched off)` and refused as a target.
- Clicking in a frame: the frame computes its element's centre; the native side adds the iframe
  element's content-box offset at each level up.
- `find` searches every readable frame.

### Native input (`AgentInput`, new file in `Sources/Singularity/MCP/`)

- `click(ref, double)`: scroll into view, read the centre point; **hit-test** with
  `elementFromPoint` at each frame level: if the point lands on something that is not the element
  or inside it, the call fails with `Element is covered by <description>` (Playwright's behaviour).
  An element with no box (hidden, e.g. a CSS-hover submenu) gets the old `el.click()` and the answer
  says `(the element is not visible; clicked it with a script)`. **My call** (keeps today's hover
  menus working). Then mouse down/up `NSEvent`s (double = two pairs with clickCount 1, 2).
- `press_key(key)`: Playwright's key names (`Enter`, `Escape`, `Tab`, `Backspace`, `Delete`,
  `ArrowUp/Down/Left/Right`, `Home`, `End`, `PageUp/PageDown`, `Space`, `F1`…`F12`, single
  characters) with modifiers `Shift+`, `Control+`, `Alt+`, `Meta+`. Goes to the page's focused
  element. **Refused:** `Meta+V`, `Meta+C`, `Meta+X`, `Shift+Insert` (they would read or replace the
  owner's clipboard) (my call).
- `type(…, slowly: true)`: focus the element with a trusted click, select its contents (`select()`
  for inputs, `selectAll` for editors), delete, then one key down/up per character (characters
  without a key code are sent with keyCode 0 and the character). `slowly` false keeps today's value
  setter. `submit` sends a trusted Enter (the navigation guard and approvals see form submissions as
  before; Enter in a form counts as a form submission for the approval).
- Every synthesized `NSEvent` gets a unique timestamp kept in a set for 2 s; one app-wide local key
  monitor (installed first) swallows any key event with such a timestamp, and the inbox's typing
  monitor ignores them too.
- After any native event the window's first responder is restored if it changed.
- `hover(ref)`: synthetic `pointerover/pointerenter/mouseover/mouseenter/pointermove/mousemove` at
  the centre (and `pointerleave/mouseleave` on the element hovered before). Answer says it was
  simulated. A read for approvals (it changes nothing the owner keeps; my call), refused nowhere.
- `drag(start_ref, end_ref)`: synthetic: `pointerdown/mousedown`, a few `pointermove/mousemove`
  steps, `pointerup/mouseup`, plus HTML5 `dragstart/dragenter/dragover/drop/dragend` with one
  shared `DataTransfer`. Acting (approval kind `click`). Answer says it was simulated.

### Waiting states: dialogs and file choosers

- `WebTabController` keeps at most one `pendingModal` per tab: `.dialog(kind, message, defaultText,
  continuation)` or `.fileChooser(multiple, allowsDirectories, continuation)`.
- **Held when** the tab is agent-busy (a call is running on it) or the tab was opened by an agent
  and isn't on screen. Otherwise: today's behaviour (sheet if on screen, cancelled if not), except
  that a file chooser for a tab with no window is now cancelled instead of an app-modal panel.
- Held for at most 120 s (my call), then answered as today's off-screen answer (OK / Cancel / null,
  no files). Also answered that way when the tab closes, navigates, the call is cancelled, the
  Space is switched off for the caller, or the app quits. A continuation is always resumed once.
- While a modal waits, JavaScript in that page is blocked: every page-agent call first checks for
  it, and actions race their JavaScript against a modal appearing.
- Every tool answer about a tab with a waiting modal starts with
  `A dialog is waiting on this tab: confirm “Delete item?”. Answer it with <slug>.handle_dialog.`
  or `A file chooser is waiting on this tab (one file). Answer it with <slug>.file_upload.`
  Message text is page content: wrapped with `UntrustedContent.wrap`.
- While a modal waits, acting tools other than the answering one are refused with that line.
- `handle_dialog(tab_id, accept, prompt_text?)`: acting, approval kind `.dialog` (the card shows
  the dialog's text; under "ask" the usual rules incl. "Allow on <site>"), then the navigation
  guard while the page continues.
- `file_upload(tab_id, paths)`: answers a waiting chooser that this connection's own call opened.
  Paths: absolute, existing regular readable files (symlinks resolved and shown), at most 20, one
  unless `multiple`; an empty list cancels the chooser. **Asks in every policy except read-only,
  never "Allow on <site>", never remembered** (new kind `.fileUpload`, like `.terminalSend`; my
  call). The card lists the resolved paths. Plugins' connections may use it under the same rule.

### Other tool changes

- `wait_for(tab_id, text?, text_gone?, seconds?)`: polls every 250 ms (all readable frames) until
  `text` appears or `text_gone` is gone, at most 30 s; with only `seconds` it waits that long (max
  30). A read.
- `click` gets `double` (bool). Answers now say how the event was delivered when it wasn't native.
- `screenshot`, `read_page`, `find`: unchanged arguments; frames and the new snapshot detail.
- Pop-ups: `openPopup` doesn't select the new tab when the source tab is agent-busy; such a tab is
  `openedByAgent`, and the click's answer names it: `Opened a new tab tab_id <id> (<url>).` Its
  first navigation goes through the navigation guard's site check like any agent navigation.
- Server instructions and `list_spaces` note mention dialogs, frames and `wait_for`.

### Approvals (Core, `AgentApprovalRules`)

- New kinds: `.pressKey` (like `type`; Enter in a form → form submission), `.dialog` (acting on
  the page's site), `.fileUpload` (always asks unless read-only, no site option), `.hover` (read),
  `.waitFor` (read), `.drag` (acting).
- Password fields: keys sent into one are masked on the card and in the log, as `type` does.

### The Assistant (`Plugins/assistant/`)

- `front.ts`: `TOOLS` gets `press_key`, `wait_for`, `handle_dialog`, `file_upload`, `hover`,
  `drag` (the split of `mcp__singularity__work_press_key` depends on it); `toolLine` gets lines
  (`Pressed Escape on …`, `Waited on …`, `Answered a dialog on …`, `Chose files on …`,
  `Pointed at something on …`, `Dragged on …`); `mayWaitForOK` matches the acting ones.
- `provider-claude.ts`: a few sentences in the browser prompt about dialogs, file choosers,
  frames and `wait_for`.
- Version 0.5.0 (no new permission: the Update offer and the normal approval sheet follow).
- `front.test.ts` and the provider tests cover the new names.

### Tests

- The bench pages move into `Tests/SingularityAppTests/Fixtures/bench/` and become app tests
  (`AgentParityTests`) driving `AgentToolbox` against a local fixture server, in off-screen windows
  that never become key and with no window: select, combobox, modal, dialogs, SPA wait, iframe
  (same and cross origin), shadow, upload, lazy, hover, keys, form, drag, masked input,
  contenteditable, new tab/pop-up, scroll box, overlay.
- Core tests for the new approval kinds and the key-name parser.
- A leak test: synthesized keys never reach another view or a menu item.
- The bench is re-run by hand on a built bundle (background tab and a visible tab).

## Left to the builder

File layout inside `Sources/Singularity/MCP/`, the exact snapshot text for tables and options,
step counts for synthetic drag, and how the frame handshake is cached between calls.

## Docs to update

`CLAUDE.md` (Page agent, approvals, the Assistant), `IDEAS.md` (`evaluate` under "New, not yet
decided"), `docs/plugins/AUTHORING.md` only if it lists door tools.
