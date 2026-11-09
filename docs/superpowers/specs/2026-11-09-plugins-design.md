# Singularity plugins: design

Status: draft for the owner's approval · 2026-11-09

## Intent: why plugins

Singularity's core stays a calm browser with **no AI in it**. Everything beyond the core comes in as **plugins**: AI chat, password managers, and whatever else the owner wants. Two things make that different from other browsers:

- **Bring your own agent.** Dia ships its own agent; Singularity ships none. An Agent SDK chat plugin uses the owner's Claude subscription, and someone else's plugin can use another provider or a local model. The core never favours a provider.
- **Plugins are written by agents and read by humans.** The owner wants to ask an agent (in a Singularity terminal tab) to build a plugin and have it appear. Plugins must therefore be small, plain and readable: a person should be able to review one in a few minutes and see exactly what it is allowed to do.

Later, a **catalog** works like an app store: anyone can publish, and the owner installs what they like.

## The success test (owner's words)

**Filling passwords from 1Password.** On a login page in Singularity, a 1Password button appears inside the username and password fields. Clicking it unlocks with Touch ID, and the username and password are filled.

The concrete test page is **github.com/login** (form in the main page). Login forms inside iframes, such as Apple ID, are a stretch goal for round 1 *(builder's call, see "Builder's calls")*.

## Goals (round 1)

1. A **plugin format**: one folder, a short manifest, TypeScript source, with no build step.
2. **Installing** a plugin from a local folder, with an approval screen that shows its permissions in plain words. Plugins can be switched on per Space.
3. A plugin's **background program**, started and stopped by Singularity and kept in a sandbox.
4. **Additions inside web pages** (buttons in form fields), drawn so that page scripts can't see or fake them.
5. **Filling form fields** from the plugin.
6. The **1Password plugin**, which meets the success test, built on the `op` command-line tool.
7. A **plugin authoring guide and template** in the repo, so that an agent in a terminal tab can write a plugin, and the plugin reloads when its files change.

## Rounds after this one (planned, not part of round 1)

- **Round 2: plugin tabs and browser abilities.** Plugins can provide a tab type, such as the Claude chat. They get the same browser abilities agents have through MCP (list tabs, read pages, click, type), under the same per-Space approval policy and agent log, with no MCP setup. The **Claude chat plugin** runs on the owner's Claude subscription via the Agent SDK. This is also when **network access to declared destinations** arrives (the chat needs `api.anthropic.com`).
- **Round 3: catalog.** A public list that anyone can publish to (for example a git repository, where publishing is a pull request). Installing from it copies a plugin into `~/Singularity/plugins/`. There are no accounts and no telemetry.

## Non-goals

- **Safari and Chrome extension compatibility.** We tested it on 2026-11-09:
  - Safari extensions that talk to their own app (1Password) can't work, because macOS only lets Safari reach those app handlers ("0 plugins found" for any other app).
  - Chrome extensions load in WebKit, but WebKit implements only Safari's set of extension APIs. 1Password's Chrome extension crashes on Chrome-only APIs (`notifications`, `privacy`, `management`, `idle`, `downloads`, some `webNavigation` events), and some of them can't even be patched from outside.

  Simple cross-browser extensions might work one day; that's parked in IDEAS.md.
- Any AI inside the core.
- A catalog, publishing, plugin updates or signing in round 1.
- Plugins on other platforms.

## Anti-goals: this fails even if it "works" when…

- **…a plugin can steal logins.** No plugin can ever read the browser's cookies, sessions or website data, under any permission.
- **…a plugin sends page data somewhere you didn't agree to.** A plugin may reach only the network destinations it declared and that you approved at install. In round 1, plugins have **no network access at all**.
- **…a plugin can do more than its manifest says.** Every power is declared, shown at install and enforced by Singularity, never by the plugin's good behaviour.
- **…a plugin can't be reviewed.** That means minified bundles, generated blobs or code downloaded at runtime. A plugin is its plain source files.

## Constraints

- **Brief rules:** native Swift/SwiftUI core, WKWebView only, no sync/accounts/telemetry, everything under `~/Singularity/`.
- **Scope change:** this moves "browser extensions" and "AI chat" out of the brief's out-of-scope list, in the narrow form described here: Singularity-native plugins, and AI only *inside plugins*. CLAUDE.md must record that decision.
- **Platform:** macOS 14+ (none of this needs WebKit's macOS 15.4 extension APIs).
- **No new dependency** (including a bundled runtime) without the owner's approval.
- **Agent rules carry over:** every action a plugin takes on pages under round 2's browser abilities goes through the Space's approval policy and the agent log, as for MCP agents.

## Plugin format (decided)

```
~/Singularity/plugins/<plugin-id>/
├─ plugin.json          the manifest, short and readable
├─ background.ts        optional: the background program (TypeScript)
├─ page.ts              optional: what the plugin adds to web pages (TypeScript)
├─ icon.png             optional
└─ README.md            what it does, for humans
```

A sketch of `plugin.json` for 1Password:

```json
{
  "id": "1password",
  "name": "1Password",
  "version": "0.1.0",
  "description": "Fill logins from 1Password, unlocked with Touch ID.",
  "author": "Karli Juhkam",
  "background": "background.ts",
  "page": { "script": "page.ts", "sites": ["<all_urls>"] },
  "permissions": {
    "pageAdditions": ["<all_urls>"],
    "fillForms": ["<all_urls>"],
    "commands": { "op": ["item list", "item get"] },
    "network": []
  }
}
```

- **Language: TypeScript with no build step** (owner's direction: easy for agents, reviewable by humans). The background program runs `background.ts` directly on **Bun**. For `page.ts`, Singularity has Bun's built-in transpiler strip the types when it loads the plugin, so the page runs plain JavaScript and the plugin's author never runs a build step.
- **Runtime: Bun, bundled inside Singularity** (owner's decision). It ships in the app bundle at a pinned version (MIT licensed), so plugins work on any Mac with no setup. Consequences for the builder:
  - The Bun executable is signed with Singularity's identity (team T748B76PPL), with the hardened runtime and the JIT entitlements its JavaScript engine needs. `scripts/release.sh` handles this, and the release stays notarizable.
  - The release is universal, so it carries the arm64 and x86_64 Bun builds, combined or side by side; that adds roughly 60–120 MB.
  - Updating Bun is a deliberate version bump in the repo, never automatic.
- **npm packages** (owner's decision): allowed, **declared and pinned**. A plugin that needs packages has a `package.json` and a `bun.lock` with exact versions.
  - At approval, Singularity installs them with `bun install --frozen-lockfile --ignore-scripts`. The install runs from Singularity, not inside the plugin's sandbox, and package install scripts never run *(builder's call)*.
  - The approval screen lists each package with its version.
  - The lockfile counts towards the plugin's approval fingerprint; `node_modules` is generated from it and not reviewed file by file.
  - Round 1's 1Password plugin needs no packages; round 2's Agent SDK chat is the first to use this.
- **Permissions are the manifest's only powers.** Round 1 needs:
  - `pageAdditions` (sites): may add UI inside pages on these sites.
  - `fillForms` (sites): may fill form fields on these sites.
  - `commands` (name → allowed sub-commands): may run these programs on the Mac, through Singularity, and only with arguments starting with one of the listed sub-commands (see below).
  - `network` (destinations): in round 1 always empty; round 2 adds real destinations.
- **The approval screen** lists each permission in plain words ("Adds buttons to pages on all sites", "Fills login forms", "Runs the 1Password command-line tool on your Mac", "Never uses the internet") and shows the plugin's name, author and README. You approve once. Switching a plugin on or off per Space, and reviewing its permissions, happens in **Settings → Plugins** (a new tab).

## How plugins run (decided)

- **Background program:** Singularity starts one Bun process per enabled plugin. It runs inside a macOS sandbox profile generated from the manifest:
  - no network unless `network` is declared;
  - file access only to the plugin's own folder and a data folder (`~/Singularity/plugins-data/<id>/`);
  - it can't start other programs.
- **Commands through Singularity:** a plugin can't run programs itself. It asks Singularity to run one of its declared `commands`, and Singularity runs it *outside* the sandbox and returns the output. This is also what lets `op` reach the 1Password app for Touch ID. A sandboxed child process probably couldn't, and it's the first thing to check (risks, below).
- **Page additions:** each plugin's `page.ts` runs in **its own isolated script world** (a `WKContentWorld` per plugin), on the sites it declared. Page scripts can't see its code or variables, and neither can other plugins. Its UI lives in a closed shadow DOM: the page can tell an element is there, but can't read inside it. *(Builder's call:)* actions such as fill only run on **real user clicks** (`isTrusted`), never on scripted ones, and only fill fields in the frame whose site matches the login being filled. Messages between `page.ts` and `background.ts` go through Singularity, which records which frame and site each one came from.
- **What the plugin sees:** the 1Password plugin's background program necessarily sees the password it fills; it *is* the password manager. What's guaranteed is that it can't send the password anywhere (no network) or read anything else (no cookies, no other plugins). Once a field is filled, the page can read its value; that's true of every password manager.
- **What `commands` may name** *(builder's call)*:
  - General-purpose programs are refused at install: shells, script interpreters, `curl`, `wget`, `ssh`, `nc`, `osascript`, `open`, `node` and similar. With any of those, the sandbox would be pointless.
  - Each command lists its allowed sub-commands; Singularity refuses any call whose arguments don't start with one of them. 1Password gets only `item list` and `item get`, so it can't, for example, write page data into a vault item.
  - At approval, Singularity resolves the program's name to a full path, using the user's login shell like terminal tabs do. The approval screen shows that path, and it's pinned; if it changes, approval is asked again.
- **What approval covers** *(builder's call)*:
  - At approval, Singularity records a fingerprint (hash) of the manifest and every source file. If anything changes later, the plugin is paused and Settings → Plugins says "changed since you approved it", showing what changed, until you approve again.
  - **Development mode** is off by default and switched on per plugin by you. With it on, code changes reload without asking. A manifest change that adds or widens a permission always needs approval again, development mode or not.
  - Plugins an agent creates start like any other: shown for approval, development mode off.
- **Spaces** *(builder's call)*:
  - There is one background program per plugin.
  - On the approval screen you tick the Spaces the plugin may act in; the Space you're in is ticked by default. Page additions appear only in web views of those Spaces.
  - The plugin's data folder is shared across Spaces.
- **Logs and reloading:** a plugin's output and errors are visible in Settings → Plugins. In **development mode**, set per plugin, Singularity watches the plugin's folder and reloads it when files change, so an agent can edit and test without restarting the app.

## The plugin API (to be shaped by the builder)

A small TypeScript API that a plugin imports and uses. It's named and documented in the authoring guide, and covers:
- **in the background:** receiving messages from the page script, replying, running a declared command (`await singularity.run("op", [...args])`), and storing small data;
- **in the page:** finding fields, adding a button inside a field, showing a small menu next to it, filling fields (`username`, `password`), and messaging the background.

The 1Password plugin is the reference user of this API: build exactly what it needs, nothing speculative.

## The 1Password plugin (decided behaviour)

- **On a login form** (a password field, plus a username or email field near it), a small 1Password button appears inside the fields.
- **Clicking it** asks the background program for logins matching the site. It runs `op item list --categories Login --format json` and keeps items whose URLs match. The first `op` call triggers Touch ID through the 1Password app.
- **Matching** *(builder's call)*: an item matches when the page's host equals the host saved in 1Password, or is a subdomain of it (`github.com` matches `www.github.com`, not the reverse). That needs no public-suffix list. "Page" means the frame containing the form, never just the top page, so a phishing page that embeds a real login frame can't collect a fill.
- **One match:** fill straight away. **Several:** a small menu of titles and usernames; picking one fills. **None:** say so in the menu.
- **Filling** uses `op item get <id> --fields username,password --reveal --format json`, then fills both fields.
- **Permissions:** add buttons to pages and fill login forms on all sites, run `op`. **No network.**
- **One 1Password account** (owner): the plugin uses whatever `op` returns; no per-Space account setting.
- **Requirements, from your side:** the 1Password CLI (installed: `op` 2.39.0 via Homebrew), and in the 1Password app, Settings → Developer → "Integrate with 1Password CLI" switched on. That's a 1Password setting; you switch it on yourself.

## Agent authoring

- **In the repo:** `docs/plugins/AUTHORING.md`, written for agents and humans. It covers the format, the manifest, every permission and what it allows, the API, the review checklist and a worked example. Plus a minimal template plugin.
- **Where plugins go:** an agent asked to build a plugin writes it into `~/Singularity/plugins/<id>/`. Singularity notices the new folder and shows the approval screen. Nothing runs until you approve.
- **First plugin made this way:** the 1Password plugin itself, built by following the guide, as the guide's first real test.

## Testing

- **Unit tests (Core):** manifest parsing and validation (unknown permission, missing files, an invalid site pattern), sandbox profile generation from permissions, site matching.
- **Integration:**
  - a test plugin that tries a forbidden thing (network, running an undeclared command, reading another folder) and is stopped;
  - a test plugin that adds a button and fills a field on a local test page.
- **The success test, by hand:** a GitHub or Apple ID login page in Singularity, 1Password button, Touch ID, filled.

## Risks to settle first

1. **`op` and Touch ID when started by Singularity.** 1Password's CLI integration checks which app runs `op`. The very first build step is a small test: Singularity runs `op item list` on behalf of a plugin and Touch ID appears. If 1Password refuses an unsigned or ad-hoc app, a build signed with team T748B76PPL may be needed.
2. **The sandbox on Bun.** A macOS sandbox profile (`sandbox-exec`) must still let the bundled Bun start, use JIT, read its own files and the plugin's folder, and talk to Singularity over a pipe. Check this early.
3. **The Agent SDK on Bun** (matters in round 2): check early that the TypeScript Agent SDK runs under Bun, and how it starts the `claude` CLI under the `commands` rules. If it can't, round 2 needs a decision before building on it.
4. **Field detection** varies a lot between sites. Start with simple, common forms; perfect coverage isn't a round-1 goal.

## Builder's calls

Settled by the builder (Claude) after the design review; the owner can override any of them:
- the `commands` rules (refused programs, sub-command lists, pinned paths);
- approval fingerprints and how development mode works;
- the per-Space model;
- user-click-only fills and frame-site matching;
- GitHub as the concrete success test, with iframes as a stretch goal;
- exact-host-or-subdomain matching.

## Owner's decisions (from the design review)

- **Runtime:** Bun, bundled inside Singularity.
- **npm packages:** allowed, declared and pinned (`package.json` + `bun.lock`), installed by Singularity at approval.
- **1Password:** one account; no per-Space account mapping.
