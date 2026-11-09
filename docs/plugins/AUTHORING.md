# Writing a Singularity plugin

This guide is for agents first and people second. It describes what is on the `plugins-round1` branch. If the guide and the code disagree, the code wins; the sources are named in each section.

Spec and reasons: `docs/superpowers/specs/2026-11-09-plugins-design.md`. A working example: `Plugins/1password/`. The smallest example: `Plugins/template/`.

## What a plugin is

A plugin is a folder with two optional parts:

- a **page script** (`page.ts`) that runs inside web pages and adds small buttons and menus to them;
- a **background program** (`background.ts`) that runs on Singularity's bundled Bun, in a macOS sandbox with no network. It can ask Singularity to run a few declared programs.

The page script talks to the background program with `singularity.send(...)`. The user must approve a plugin before anything runs. Everything the plugin can do is listed in `plugin.json` and shown on the approval sheet.

Round 1 has no network for plugins and no built-in AI. A plugin cannot read pages, cookies or the DOM of sites it is not allowed on, and it cannot send what it sees anywhere.

## Quick start

1. Copy `Plugins/template/` to a new folder. **The folder name must equal `id` in `plugin.json`.**
2. Change `id`, `name`, `description`, `author` in `plugin.json`. Edit `page.ts` and `background.ts`.
3. In Singularity: Settings -> Plugins -> Add Plugin... -> choose the folder. Singularity copies it to `~/Singularity/plugins/<id>/`.
4. Read the approval sheet, switch on **Development mode** if you will keep editing, approve, and switch the plugin on for a Space.
5. Open a page that matches your sites. Errors from the page script appear in the page's console as `Plugin <id>: page script failed: ...`. Background logs appear in Settings -> Plugins (the last 50 lines).

## Folder layout

```
my-plugin/              folder name == id
  plugin.json           the manifest (required)
  background.ts         background program (optional)
  page.ts               page script (optional, one file, no imports)
  package.json          only if you use npm packages
  bun.lock              required with package.json
  README.md, icon.png   anything else is fine, but every file is fingerprinted
```

Rules for the folder:

- No symbolic links and no special files (FIFOs, sockets, devices).
- No `.npmrc`.
- Write plain, readable TypeScript. **No minified, obfuscated or generated code.** Reviewers reject it. (The app does not check this; people do.)
- `page.ts` is one file of at most 1 MB.

## The manifest: `plugin.json`

```json
{
  "id": "email-domain",
  "name": "Email domain",
  "version": "0.1.0",
  "description": "Shows which provider an email address uses.",
  "author": "Your name",
  "background": "background.ts",
  "page": { "script": "page.ts", "sites": ["https://*/*"] },
  "permissions": {
    "pageAdditions": ["https://*/*"],
    "fillForms": [],
    "commands": {},
    "network": []
  }
}
```

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | `^[a-z0-9][a-z0-9-]{0,39}$` (lowercase letters, digits, dashes; 1 to 40 characters). Must equal the folder name. |
| `name`, `version`, `description`, `author` | yes | Shown in Settings and on the approval sheet. |
| `background` | no | Path of the background file, relative to the folder. A regular file inside the folder, no `..`. |
| `page` | no | `{ "script": "page.ts", "sites": [patterns] }`. The script runs only on these sites. |
| `permissions` | yes | See below. Missing keys mean "none". An unknown key is an error. |

### Site patterns

Chrome-style match patterns, a subset: `<all_urls>`, or `scheme://host/path`.

- scheme: `*` (http or https), `http` or `https`
- host: `*`, `*.example.com` (the domain and all subdomains) or an exact name. No port, no user info.
- path: starts with `/`; `*` matches any run of characters. Ports are ignored.

Every entry of `page.sites` must also appear, as the same text, in `permissions.pageAdditions` (or `pageAdditions` must contain `<all_urls>`). A page script may not run where `pageAdditions` doesn't allow it.

### Permissions

| Permission | What it allows | What the approval sheet says |
|---|---|---|
| `pageAdditions` | Buttons and menus in pages on these sites (and the page script running there). | "Adds buttons to pages on <sites>" |
| `fillForms` | The background may fill login fields on these sites (see Fills). | "Fills login forms on <sites>" |
| `commands` | `{ "program": ["sub command", ...] }`. The background may run that program with arguments starting with one of the listed sub-commands. | "Runs /path/to/program (only: sub command, ...)" |
| `network` | Must be `[]` in round 1. | "Never uses the internet" |

Details:

- Sub-commands match word for word and case-sensitively at the start of the arguments. `"item list"` allows `item list --format json`. A program with an empty list, or an empty sub-command, is refused.
- A program name is a bare name: letters, digits, `.`, `_`, `-`, starting with a letter or digit. No slashes.
- The program is found on the user's login `PATH` when the plugin is approved, and that path is pinned. A different program with the same name later is not run.
- These program names are refused (also with a version suffix such as `python3.12`): `sh bash zsh fish dash ksh csh tcsh env sudo su curl wget ssh scp sftp nc ncat telnet ftp rsync osascript open python python3 perl ruby php node bun deno npx bunx rbash nodejs pip pip3 npm pnpm yarn xargs nice nohup exec command launchctl swift lua awk gawk tclsh expect`. In short: shells, interpreters, network tools and package managers.
- Asking for more later (a new site, a new program, a new sub-command) means the plugin needs approval again, even in development mode. Asking for less does not.

### Manifest errors

The first problem found is shown as "Problem: <text>". Check order: JSON shape, id format, id equals folder, permission keys, site patterns, page sites, network, commands, files, packages.

| Mistake | Exact message |
|---|---|
| Not valid JSON | `plugin.json isn't valid JSON` |
| Bad id | `“My Plugin” isn't a valid plugin id (lowercase letters, digits and dashes)` |
| id differs from folder | `its id “foo” doesn't match its folder name “bar”` |
| Unknown permission key | `it asks for an unknown permission “cookies”` |
| Bad site pattern | `“example.com” isn't a valid site pattern` |
| Page site not in `pageAdditions` | `its page script runs on https://a.com/* without permission` |
| `network` not empty | `it asks for internet access, which plugins can't have yet` |
| Refused or malformed command, or empty sub-command list | `it may not run “bash”` |
| `background` or `page.script` missing, absolute, or contains `..` | `the file background.ts is missing` |
| Symbolic link in the folder | `it contains a symbolic link (path/to/link)` |
| FIFO, socket or device | `it contains a special file (path)` |
| `.npmrc` present | `it contains .npmrc, which plugins may not have` |
| Dependencies without `bun.lock` | `it uses packages but has no bun.lock` |
| Range, tag, `file:`, git, URL or `npm:` alias; other dependency group; lock mismatch | `it uses “left-pad”, which isn't an exact npm registry version matching bun.lock` |
| `package.json` or `bun.lock` not valid | `package.json isn't valid` / `bun.lock isn't valid` |
| A file can't be read | `its files can't be read` |

## The background API

The background file is plain TypeScript run by Bun. It is the only file that imports `singularity`:

```ts
import { singularity } from "singularity";
```

`singularity` is not an npm package; Singularity defines it in memory.

```ts
type PageMessage = { tabID: string; frameHost: string; payload: unknown };
type CommandResult = { status: number; stdout: string; stderr: string; timedOut: boolean };

singularity.onPageMessage(handler: (message: PageMessage) => unknown | Promise<unknown>): void
singularity.run(command: string, args: string[]): Promise<CommandResult>
singularity.log(...values: unknown[]): void
```

**`onPageMessage(handler)`** handles every `singularity.send(payload)` from this plugin's page script. What the handler returns (or resolves to) is the answer; it must be JSON. `undefined` becomes `null`. A thrown error becomes `{ error: "<message>" }`. With no handler the answer is `{ error: "no handler" }`. Registering again replaces the handler. Several messages can be in progress at once.

- `frameHost` is the page's host, read from WebKit. Use it, not a host in `payload`. A web page can put anything in `payload`: check its shape.
- `tabID` is an opaque tab identifier.

**`run(command, args)`** asks Singularity to run a declared program. There is no shell; arguments are passed as they are. It always resolves, never rejects (except for wrong argument types). Look at `status` and `timedOut`:

- the program's own exit status and output when it ran;
- `status: 126` with `stderr: "not allowed by the manifest"` when the program or sub-command isn't declared;
- `status: 126` with `stderr: "too many commands running"` when 4 are already running (the call is refused at once, not queued);
- `timedOut: true` after 60 seconds (the program is stopped).

**`log(...)`** writes a line to the plugin log in Settings. `console.log`, `console.info`, `console.debug`, `console.warn`, `console.error` and `process.stdout.write` go to the log too (stdout carries the protocol, so printing there directly is not possible). Lines are cut to 8 KB. **Never log secrets**; log counts and error kinds.

Other things to know:

- **No storage API in round 1.** The plugin's data folder (`HOME` and `TMPDIR` point to it) is writable with ordinary file APIs, but there is no `singularity.storage`. Keep state in memory or in files there.
- **Unhandled promise rejections and uncaught exceptions are logged, not fatal.** If the file fails to load, the plugin exits with status 1 and may be restarted. More than 3 crashes in 60 seconds stops it.
- **Limits:** a single message larger than 16 MB, or more than 16 MB of messages the plugin hasn't read yet, stops the plugin. A page `send` payload is at most 256 KB.
- **Packages:** you may import npm packages (see Packages). Local files too: `import { x } from "./logic.ts"`.

### The sandbox

The background runs under `sandbox-exec` with a generated profile that denies everything except:

- running Bun itself, nothing else;
- reading its own folder (read-only: it cannot rewrite itself);
- reading and writing its data folder;
- reading a few system files Bun needs (ICU data, time zone data, some `sysctl` values).

So: **no network at all**, no starting other programs (only `singularity.run` can, for declared commands), and no other files. The environment is minimal and nothing is inherited from the app:

```
HOME=<data folder>  TMPDIR=<data folder>/tmp  LANG=en_US.UTF-8  NO_COLOR=1
BUN_RUNTIME_TRANSPILER_CACHE_PATH=0
```

There is no `PATH`. The plugin's own `.env` and `bunfig.toml` are not read.

## The page API

`page.ts` runs as a plain script inside the page, in its own isolated world (the page's scripts cannot see it). `singularity` is already a global there. The page API is exactly these five members:

```ts
singularity.siteMatches: boolean
singularity.send(payload: unknown): Promise<unknown>
singularity.addFieldButton(input: HTMLInputElement, options: {
  title: string;                       // tooltip and accessible name, max 200 characters
  iconURL?: string;                    // only "data:image/..." URLs are used
  onClick: (input: HTMLInputElement) => void | Promise<void>;
}): void
singularity.showMenu(anchor: Element, items: { title: string; subtitle?: string }[]): Promise<number | null>
singularity.fillLogin(fields: {
  usernameInput?: HTMLInputElement; passwordInput?: HTMLInputElement;
  username?: string; password?: string;
}): void
```

- **`siteMatches`**: true when the page matches both `page.sites` and `pageAdditions`. Your script is only run when it is true, so you rarely need it.
- **`send(payload)`**: `JSON.stringify`s the payload (at most 256 KB) and resolves with the background's answer. Rejects when the plugin isn't running (`the plugin isn't running or didn't answer`) or the message is too big (`the message is larger than 256 KB`).
- **`addFieldButton(input, options)`**: puts a small button inside the right edge of the input. One button per input: calling it again for the same input updates it, so calling it on every page change is fine. Throws `TypeError` if `input` isn't an `<input>` or `onClick` isn't a function. The button is drawn inside a closed shadow root, so the page can't read or click it.
- **`showMenu(anchor, items)`**: shows a menu next to `anchor`. At most 50 items; titles and subtitles are plain text, cut to 200 characters. Resolves with the picked index, or `null` if dismissed. An empty list shows "Nothing to show".
- **`fillLogin(fields)`**: sets the given fields as typing would (the native value setter, then `input` and `change` events). Throws `this plugin may not fill forms on this site` if the page doesn't match `fillForms`. Fields you leave out stay as they are.

DOM APIs (`document.querySelectorAll`, `MutationObserver`, `getComputedStyle`, ...) work as usual. `async`/`await` and top-level `await` work: the code runs inside an async function. Types are stripped, not checked.

### Rules for `page.ts`

1. **No imports and no exports at all**: not static, not `import()`, not `import.meta`. Even the text `import(` inside a string or comment is refused: rename it. `import type { X } from ...` is fine (it vanishes when compiled), but there is nothing to import from, so avoid it. Put shared code in the same file.
2. **No `eval`, `Function`, or string timers.** `eval(...)`, `new Function(...)`, the async and generator function constructors and `setTimeout("code", ...)` throw `running code from a string isn't available to plugins`.
3. **No network APIs.** `fetch`, `XMLHttpRequest`, `WebSocket`, `WebSocketStream`, `EventSource`, `Worker`, `SharedWorker`, `RTCPeerConnection`, `WebTransport`, `importScripts`, `navigator.sendBeacon`, `caches`/`CacheStorage`/`Cache` writes, worklets (`addModule`), `FontFace` and `document.fonts.add/load`, `navigator.serviceWorker.register`, `window.open` and `navigation.navigate` all throw `network isn't available to plugins`. Frames you create get no `contentWindow` or `contentDocument`.
4. **DOM routes cannot be blocked, and the app does not try to.** A script that may change the page can also make the page load things, and those requests can carry data: `new Image().src = ...`, inserting an `<img>`, `<script>` or `<link>` element, CSS `url(...)`, assigning `location`, submitting a form. **Reviewers must look for these. Using one to send data out is a reason to reject a plugin.**
5. `page.ts` is run only where `siteMatches` is true. Compile errors are shown in Settings -> Plugins and the script is left out.

Compiler messages (from `Resources/plugin-host/transpile-page.ts`):

| Mistake | Exact message |
|---|---|
| `import x from "./a"` or `import "x"` | `page.ts can't import other files in round 1 (it imports "./a")` |
| `export const x = 1` | `page.ts can't export anything: it runs as a plain script in the page` |
| `import(path)` anywhere, even in a string | `page.ts can't import other files in round 1 (it uses import())` |
| `import.meta`, `export {}` | `page.ts can't use import/export in round 1 (...)` |
| Syntax error | `page.ts has a syntax error: ...` |
| Over 1 MB | `page.ts is larger than 1 MB` |

### Clicks

`addFieldButton`'s `onClick` runs only for **genuine user clicks**: a trusted event (not `element.click()` or `dispatchEvent`) on the button, where Singularity drew it, as it drew it. A click is refused, silently, when:

- the page moved, resized, faded, masked, clipped, hid or covered the button (the button's host must still be a child of `<html>`, with exactly the style Singularity set, at the place it was put, with opacity 0.9 or more and visible);
- `<html>` or `<body>` (or the host) has a `filter`, `mask`, `clip-path` or `mix-blend-mode`;
- the host has `::before` or `::after` content;
- the button is bigger than 64 px.

So a page with `filter: grayscale(...)` on `<body>` refuses plugin buttons. This fails closed on purpose. One risk remains: an overlay with `pointer-events: none` drawn above the button lets the click through while the user sees the overlay. **Before releasing anything sensitive, make the user pick from a `showMenu` first.** The 1Password plugin always does: a click on the button opens a menu of logins, and only a pick fills.

### Fills

A background reply of the form

```ts
{ fill: { forHost: string, username?: string, password?: string } }
```

is delivered to the page only when all of these hold:

1. the frame's host equals `forHost` or is a subdomain of it (`www.github.com` may get a `github.com` login; `github.com` may not get a `www.github.com` login; `evilgithub.com` never does);
2. the frame's URL matches `fillForms` (in the manifest and as approved);
3. the request came from a genuine click (see Clicks): the `send` that asked for the fill happened within 2 seconds of a real click on the plugin's button or menu.

Otherwise the page gets `{ error: "fill blocked" }`. The fill guard ignores the URL scheme, so **use `https://` patterns in `fillForms` for sensitive sites**. Anything other than a well-formed `fill` object (wrong types) is blocked too. Set the fields with `singularity.fillLogin` in `page.ts`.

## Packages

You may use npm packages in the background file. The rules are strict because the install runs outside the sandbox:

- Only `dependencies` in `package.json`, each at an **exact version** (`"1.2.3"`) from the npm registry. Not allowed: ranges (`^1.2.0`), tags (`latest`), `file:`, `link:`, `workspace:`, git or GitHub specs, URLs, `npm:` aliases, other dependency groups, and keys such as `overrides`, `resolutions`, `workspaces`.
- `bun.lock` is required and must be committed. It must match `package.json`. No comments, no CR line endings. Create it with `bun install` on your own machine.
- No `.npmrc`.
- Packages that use npm aliases can't be used. That rules out `glob@10`, `rimraf@5`, `jackspeak` and anything depending on them.
- Singularity installs packages itself at approval, with `--ignore-scripts`, so install scripts never run. The approval sheet says how many packages are installed.
- `package.json` and `bun.lock` are at most 1 MB.
- A change to `package.json`, `bun.lock` or anything in `node_modules` needs a new approval, **even in development mode**.
- `page.ts` cannot import packages. If the page needs logic, put it in the background and `send`.

## Approval, fingerprints and development mode

- Every file in the folder is hashed, including dotfiles, `bun.lock` and `node_modules` at any depth. (Skipped: a top-level `.git/` and `.DS_Store` files.) The hash of everything is the plugin's **fingerprint**, recorded at approval.
- Any change to any file pauses the plugin (status "changed") until the user approves again.
- **Development mode** (a switch on the approval sheet and in Settings -> Plugins) lets edits to the plugin's own code through: saving a file restarts the plugin instead of pausing it. It does not cover widened permissions or any package file (see above). It can only be switched on while the plugin is approved as it is now.
- Widened permissions always need a new approval, in any mode.
- Approval is per plugin; the user also switches the plugin on per Space.
- The page script is re-compiled when `page.ts` changes. A page that is already loaded keeps the old script until it loads again.

Test loop for a new plugin: add, approve with development mode on, edit, save, reload the page.

## Known limitations

- An approved plugin's background program can read the command-line **arguments** (not the environment) of the user's other processes, because macOS's sandbox can't block that. Reviewers should keep this in mind, and plugins must never put secrets into arguments of programs they run.
- Tabs restored at launch may get plugin scripts only on their next load.
- Round 1 has no network, no storage API, no icons beyond `data:image/` URLs, and no page-script imports.

## Worked example: an email provider hint

A button inside email fields. Click it, and a menu says which provider the address is from. The page sends the typed value to the background; the background answers. No commands, no network, no filling.

`email-domain/plugin.json`:

```json
{
  "id": "email-domain",
  "name": "Email domain",
  "version": "0.1.0",
  "description": "Shows which provider an email address uses.",
  "author": "Your name",
  "background": "background.ts",
  "page": { "script": "page.ts", "sites": ["https://*/*"] },
  "permissions": {
    "pageAdditions": ["https://*/*"],
    "fillForms": [],
    "commands": {},
    "network": []
  }
}
```

`email-domain/background.ts`:

```ts
import { singularity } from "singularity";

const FREE = new Map([
  ["gmail.com", "Gmail"],
  ["outlook.com", "Outlook"],
  ["icloud.com", "iCloud"],
]);

singularity.onPageMessage(async ({ frameHost, payload }) => {
  const message = (payload ?? {}) as { type?: unknown; value?: unknown };
  if (message.type !== "provider" || typeof message.value !== "string") {
    return { error: "unknown request" };
  }
  const at = message.value.lastIndexOf("@");
  if (at < 1) return { error: "Type an email address first" };
  const domain = message.value.slice(at + 1).toLowerCase();
  singularity.log(`checked a domain on ${frameHost}`); // not the address itself
  const provider = FREE.get(domain);
  return { domain, provider: provider ?? "Not a common free provider" };
});
```

`email-domain/page.ts`:

```ts
async function onClick(input: HTMLInputElement): Promise<void> {
  const reply = (await singularity.send({ type: "provider", value: input.value })) as {
    domain?: string;
    provider?: string;
    error?: string;
  };
  const items = reply.error
    ? [{ title: reply.error }]
    : [{ title: reply.provider ?? "Unknown", subtitle: reply.domain }];
  await singularity.showMenu(input, items);
}

function decorate(): void {
  for (const input of document.querySelectorAll<HTMLInputElement>("input[type=email]")) {
    singularity.addFieldButton(input, { title: "Which provider?", onClick: () => onClick(input) });
  }
}

decorate();
let scanPending = false;
new MutationObserver(() => {
  if (scanPending) return;
  scanPending = true;
  setTimeout(() => {
    scanPending = false;
    decorate();
  }, 200);
}).observe(document.documentElement, { childList: true, subtree: true });
```

### Running a program

To run a program, declare it and call `run`. Illustrative example with `git`:

```json
"commands": { "git": ["--version"] }
```

```ts
const result = await singularity.run("git", ["--version"]);
if (result.status !== 0 || result.timedOut) return { error: "git failed" }; // don't pass stderr on blindly
return { version: result.stdout.trim() };
```

The approval sheet then shows `Runs /usr/bin/git (only: --version)`.

## Common mistakes

| You did | You get |
|---|---|
| Folder name differs from `id` | `its id “foo” doesn't match its folder name “bar”` |
| Id with capitals or spaces | `“Foo Bar” isn't a valid plugin id (lowercase letters, digits and dashes)` |
| `"cookies"` or any other key in `permissions` | `it asks for an unknown permission “cookies”` |
| `"network": ["api.example.com"]` | `it asks for internet access, which plugins can't have yet` |
| `"commands": { "curl": ["https"] }` or `bash`, `node`, `python3`, ... | `it may not run “curl”` |
| `"commands": { "op": [] }` | `it may not run “op”` |
| `page.sites` not listed in `pageAdditions` | `its page script runs on https://a.com/* without permission` |
| `"sites": ["example.com"]` (no scheme) | `“example.com” isn't a valid site pattern` |
| `"background": "src/main.ts"` but no such file | `the file src/main.ts is missing` |
| `import { singularity } from "singularity"` in `page.ts` | `page.ts can't import other files in round 1 (it imports "singularity")` |
| `export {}` or `export function` in `page.ts` | `page.ts can't export anything: it runs as a plain script in the page` or `page.ts can't use import/export in round 1 (...)` |
| `await import("./x.js")` in `page.ts` | `page.ts can't import other files in round 1 (it uses import())` |
| `fetch(...)` in `page.ts` | runtime error `network isn't available to plugins` |
| `eval(...)`, `new Function(...)`, `setTimeout("...")` | runtime error `running code from a string isn't available to plugins` |
| `fetch(...)` in `background.ts` | fails: the sandbox has no network |
| `singularity.run("ls", [])` without declaring `ls` | resolves with `status: 126`, `stderr: "not allowed by the manifest"` |
| 5 `run` calls at once | the 5th resolves with `status: 126`, `stderr: "too many commands running"` |
| `"dependencies": { "x": "^1.0.0" }` | `it uses “x”, which isn't an exact npm registry version matching bun.lock` |
| Dependencies but no `bun.lock` | `it uses packages but has no bun.lock` |
| `.npmrc` in the folder | `it contains .npmrc, which plugins may not have` |
| A symlink in the folder (even in `node_modules`) | `it contains a symbolic link (<path>)` |
| `singularity.fillLogin` on a site not in `fillForms` | `this plugin may not fill forms on this site` |
| Fill reply for the wrong host, or not after a real click | the page gets `{ "error": "fill blocked" }` |
| `onClick` triggered by `button.click()` in a script | nothing happens (not a genuine click) |
| Edited a file after approval, development mode off | the plugin is paused until it is approved again |
| Edited `bun.lock` with development mode on | the plugin is paused until it is approved again |
| Added a site to `pageAdditions` | the plugin needs approval again (even in development mode) |

## Review checklist for people (five minutes)

1. **Permissions vs purpose.** Read the approval sheet. Does each line match what the plugin says it does? `<all_urls>` for a plugin that only needs one site is a flag. Any `commands` entry should be a program the plugin obviously needs, with narrow sub-commands.
2. **DOM network routes in `page.ts`.** Search for `Image`, `.src`, `createElement`, `innerHTML`, `insertAdjacentHTML`, `<img`, `<script`, `<link`, `url(`, `location`, `.submit(`, `form`, `window.name`. Anything that could carry page data to a URL is a reason to reject.
3. **What goes to the background, and what comes back.** In `page.ts`, look at every `send(...)`. Is only the needed data sent (not the whole page text)? In `background.ts`, is the payload checked, and is `frameHost` used instead of a host from the payload?
4. **Fills happen only after a menu pick.** Any `fillLogin` or `fill` reply should come after a `showMenu` pick. Check that `fillForms` is as narrow as possible and uses `https://`.
5. **Secrets in logs.** Search for `log(` and `console.`. Counts and error kinds are fine; values are not. Check that `stderr` of programs isn't logged or returned blindly.
6. **Packages.** Open `package.json`: few dependencies, exact versions, known names. Look at `bun.lock` for unexpected packages. Be extra careful with anything large.
7. **Code quality.** Plain readable TypeScript. No minified, obfuscated or generated code, no strange encodings, no `atob`/base64 blobs.

If a plugin passes these, approving it is reasonable. If any step is unclear, ask the author or don't approve.
