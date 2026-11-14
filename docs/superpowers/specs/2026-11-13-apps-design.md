# Apps: artifacts with a local Worker and a database: design

Status: **built on 2026-11-14** (plan `docs/superpowers/plans/2026-11-14-apps.md`). The owner
approved this design and the keychain exception on 2026-11-14. Brainstormed with the owner on
2026-11-13. What the owner decided is under "Decided by the owner"; everything under "Builder's
calls" is mine and open to overruling. **"As built", at the end, says where the code differs and
overrides the text above it.**

## Intent: why

The owner runs his work through agents. What is missing is a place where information stays in
front of him without asking an agent each time, for example an app for running his company. Today
an artifact is a static page: it can't keep data, can't call an API that needs a key, and can't
run code of its own.

He also wants a place to prototype. An idea should be running in Singularity in minutes, with no
project setup, and if it proves itself, moving it out to a real deployment should be cheap. The
destination is Cloudflare (Workers and D1).

The usual path of one app: first an agent brings the data through its own MCP connections and
writes it into the app's database; later the same place in the app is promoted to call the real
API with a key.

## Decided by the owner

- Approach A of three (see Approaches): a Worker-shaped app in the artifacts folder, run by
  Singularity in the bundled Bun, sandboxed.
- Both halves are built together: local Worker and database, and connections to outside APIs.
- The server side has no network of its own; outside requests go through Singularity, to hosts
  the owner allowed for that app. (Proposed by me, accepted with "go with A".)
- The destination for moving out is Cloudflare.
- Built in a git worktree (`.claude/worktrees/apps`, branch `worktree-apps`, from `main`).

## Goals

1. A folder in a Space's `artifacts/` with a `wrangler.jsonc` is an **app**: its page is an
   artifact tab as today, and requests the folder has no file for go to its Worker.
2. The Worker is ordinary Cloudflare Worker code: `export default { fetch(request, env, ctx) }`.
3. `env.DB` is a database with D1's API, kept in a SQLite file in the Space's folder. An agent can
   write the same file from a terminal while the app runs.
4. The Worker can call outside APIs with plain `fetch()`, only to hosts the owner allowed for
   that app. A key the owner stored is added by Singularity; by default the code never sees it.
5. It starts by itself: no install, no build step, no terminal tab to keep open. Editing a file
   takes effect at the next request.
6. Moving out is a documented, short job an agent can do: the Worker and the SQL move unchanged.

## Non-goals (round 1)

- Our own UI framework. The page is written as TS/TSX artifacts already are.
- Packages managed by Singularity. A `node_modules` the author put in the folder is used as found.
- Other Cloudflare bindings: KV, R2, Durable Objects, Queues, cron triggers (`scheduled`),
  `env.ASSETS`, service bindings, `run_worker_first`.
- Streaming responses, server-sent events, WebSockets. A response is complete before it is sent.
- History-API routing for the page (use hash routes), a fixed port per Space.
- Pages rendered by the Worker. Pages are files; the Worker is the API behind them. A tab that
  sits on a path with no file is still marked "file is missing", as today, and the guide says so.
- An export or deploy command. Moving out is a guide (see below), not a button.
- A "New App" command or any UI to create apps. Agents write the folder.
- Sign-in for the app. Locally the owner is the only user; on Cloudflare it is his to add.

## Anti-goals

- A key reaching an agent's context, a file in the app folder, a log or the page, unless the
  owner marked that key as readable by the code.
- The Worker reaching the network around Singularity, or a host the owner did not allow.
- Anything that weakens the artifact server's token, Host check or path rules, or the plugin
  sandbox profile's meaning for plugins.
- A local dialect: code that runs here but needs rewriting for Cloudflare.
- A test or trial touching the real keychain or a real outside service.

## Constraints

- No new dependency: bundled Bun (`bun:sqlite` is built in), FlyingFox, `sandbox-exec`,
  `URLSession`, Security.framework for the keychain.
- Verify APIs before use, not from memory: D1's client API and result shapes, wrangler's config
  keys and its migrations table, Bun's `bun:sqlite` and JSONC import (Bun 1.4.4).
- Checked on 2026-11-13 with the repository's Bun and a copy of the plugin sandbox profile:
  `bun:sqlite` opens, writes and uses WAL inside the sandbox with only the data folder writable;
  the network is denied; `sqlite3` outside the sandbox can write the same file meanwhile.
- A bare debug binary has no Bun: app requests answer with a plain "needs the app bundle" error,
  as TS artifacts do.

## What an app is

```
~/Singularity/spaces/work/artifacts/firma/
  wrangler.jsonc        makes the folder an app; names the Worker and its bindings
  worker.ts             export default { async fetch(request, env, ctx) { … } }
  migrations/0001_init.sql
  app.tsx               the page, a TS/TSX artifact as today
  importmap.json

~/Singularity/spaces/work/app-data/firma/
  DB.sqlite             env.DB (one file per D1 binding, named after the binding)
```

- **The app is the nearest enclosing folder with `wrangler.jsonc` (or `wrangler.json`).** Its
  identity is its path inside `artifacts/` (`firma`). A renamed folder is a new app: no allowed
  hosts, no keys, a new empty data folder. The old data folder stays on disk.
- **The data folder is outside `artifacts/`**, so the server can never serve it.
- `wrangler.jsonc` is read by the host script inside the sandbox, not by the app: `main`
  (default `worker.ts`), `d1_databases[].binding`, `vars`. Other keys are ignored. Swift only
  needs to know that the file exists.

## Requests

For a request under an app's folder, in this order:

1. Host check and token as today, for every request.
2. A GET or HEAD the folder has a file for is answered as today (static, compiled TS/TSX, Range).
3. Everything else goes to the Worker: any method, any path with no file.

Rules for what reaches the Worker:

- **Same origin only.** `Sec-Fetch-Site`, when present, must be `same-origin` or `none`. Any
  method other than GET or HEAD must also carry an `Origin` equal to the server's own. Reason: the
  auth cookie is `SameSite=Strict`, but "site" ignores the port, so a page on another 127.0.0.1
  port in the same Space would otherwise be able to POST.
- **The Worker sees the app as if it were at the root**: `/firma/api/invoices` arrives as
  `/api/invoices`. The page therefore uses relative URLs (`fetch("api/invoices")`), which work
  unchanged at a domain's root on Cloudflare.
- **Our credentials are removed** before the Worker sees the request: the `Authorization` header
  with the Space token and the `singularity_token` cookie. A `Set-Cookie` for that name in the
  Worker's answer is dropped.
- Outside an app folder nothing changes: GET and HEAD, files only.
- Request and response bodies are held in memory, with a size limit and a time limit per request.

Other pages of the same Space's artifacts share the origin and can call the app. That is
accepted: they are the owner's own artifacts.

## The Worker process

- One Bun process per app, under `sandbox-exec` with the plugin profile's rules: read the app
  folder and the host script, write only the data folder, no network, no other programs, a
  minimal environment. It runs a new host script, `Resources/plugin-host/app-host.ts`, which
  imports the Worker, builds `env`, and talks to the app in JSON lines over stdin/stdout, as
  plugin backgrounds do.
- **Starts at the first request** that needs it, and also when the folder watcher sees an app
  appear or its `wrangler.jsonc` or `migrations/` change while the Space's server runs. So the
  database exists, with its tables, before any request: an agent can write rows with `sqlite3`
  right after it wrote the files. **Stops** after a while without requests, when any file in the
  app folder changes (then started again as just said, or by the next request), when the Space's
  server stops, and at quit (killed at once, like plugin processes).
- Applies `migrations/*.sql` in name order at every start, each once, recorded in the table
  wrangler itself uses. The guide tells agents to make tables only through migrations.
- A Worker that can't start (syntax error, failed migration) or throws: the request gets a 500
  with the message and stack, as text.
- **The log is a file an agent can read**: `console.log`, errors and start-up failures go to
  `app-data/<app>/worker.log`, cut to its last lines. Before a line is written, every stored key
  value of that app is replaced with `[key NAME]` (exact matches; a key the code may read can
  still leave in another form, which the "code can read this key" switch already accepts).
- `ctx.waitUntil` is honoured before an idle stop.

## env.DB

A wrapper with D1's client API over `bun:sqlite`: `prepare`, `bind`, `first`, `all`, `run`,
`raw`, `batch` (one transaction), `exec`, with D1's result shapes (`results`, `success`, `meta`).
WAL mode, so an agent's `sqlite3` and the Worker can use the file together. It is ours to keep
true to D1; the Bun tests pin the shapes against Cloudflare's documentation.

## Outside requests

`fetch` inside the Worker is replaced by the host script: the request goes to the app over the
wire, the app makes it and sends the answer back. The sandbox denies the network, so there is no
way around it.

- **Hosts are allowed per app, by the owner.** A request to a host not yet allowed waits and puts
  an approval in the agent inbox: "firma (Work) wants to connect to api.example.com", Allow /
  Deny. Allow is remembered for that app. No answer within the approval timeout is a deny. A
  denied request fails in the Worker with an error that names the host.
- **A denied host stays quiet.** Requests to the same host of the same app that arrive while one
  approval waits share that one entry. After Deny or a timeout, that host is refused without
  asking again until the Worker next starts; the panel lists it with an Allow button meanwhile.
  Nothing about a deny is saved.
- **The Space's agent policy has no say here.** Read-only, ask and allow-all are about agents
  acting in the browser; an app's new host always asks, in every policy. The answer is re-checked
  only for "the Space and the app still exist". The inbox's other safeguards apply as they are
  (never a default button, the click lockout, at most 5 waiting per Space).
- https only, except http to a loopback host (a local dev server), which is allowed like any
  other host. A redirect to a host that isn't allowed fails. No cookies are kept between requests.
- Size and time limits as for requests.

## Keys

Stored by the owner in the app's panel: a name, the host it belongs to, the value, and one
switch, "The app's code can read this key" (off by default).

- **Off (default).** The Worker gets a placeholder in `env.NAME`, new at each start. When a
  request goes to that key's host, Singularity replaces the placeholder with the real value in
  the URL, the headers and a text body. To any other host it is not replaced. If the answer
  contains the real value, it is replaced back with the placeholder. So the code is written as
  on Cloudflare (`Authorization: Bearer ${env.MERIT_KEY}`) and the value never enters the sandbox.
- **On.** `env.NAME` is the real value. For APIs that sign requests with the key (HMAC), where a
  placeholder can't work. The panel says plainly that this app's code can read it. Allowed hosts
  still apply.
- **Values live in the macOS keychain**, never in a file. Names, hosts and the switch live in
  `space.json` next to the allowed hosts. In a copy with `SINGULARITY_HOME` set, values go to a
  file in that folder instead, so a test copy never touches the keychain; tests use a fake store.
- Key values and placeholders are never logged, and not shown again after saving.
- A name the Worker read from `env` that has no key is listed in the panel as "not set".
- **Nothing is removed by itself when a folder disappears.** An agent's `mv` and back, or a git
  checkout, must not cost the owner his keys. Keys, hosts and data stay under the app's path, and
  a folder that comes back under the same path has them again. Settings → Data & privacy lists,
  per Space, every app that has keys, hosts or data, also ones whose folder is gone, each with
  "Forget" (keys and hosts) and "Delete data". Deleting a Space removes its apps' keys from the
  keychain, as it removes its cookies.

**What this protects, honestly.** An agent in a terminal tab runs as the owner and could read or
change anything he can, including `space.json`. This does not defend against a hostile agent. It
keeps keys out of agents' context, chat transcripts and project files, and it keeps a Worker's
mistakes or a bad package inside the allowed hosts.

## The app's panel

For an artifact tab that belongs to an app, a button at the right of the address row (where a web
tab has site settings; artifact tabs have no button there today) opens the app's panel:

- Worker: running or stopped, the last error, the last log lines, Restart.
- Database: the file's path and size, Show in Finder.
- Connections: allowed hosts, each removable; add one by hand.
- Keys: name, host, the switch, set or replace the value, delete.

## How agents learn it

- `docs/apps/AUTHORING.md`, a guide written for agents, and `Apps/template/` (the five files
  above), both shipped in the bundle as the plugin guide is.
- The MCP server's instructions say in two sentences what an app is; `list_spaces` gives each
  Space's `app_data_folder` and the guide's path.
- The guide covers: the files, relative URLs, hash routes, migrations, writing data with `sqlite3`
  in the MCP step, asking the owner to allow a host or add a key (the agent never handles a key),
  the refresh button through `window.singularity.prompt()`, and moving out.

## Moving out to Cloudflare (a guide, not a feature)

`wrangler d1 create` and its id into `wrangler.jsonc`; `wrangler d1 migrations apply`; the data
with `sqlite3 .dump` and `wrangler d1 execute`; each key with `wrangler secret put`; the page
built once with `bun build` into `dist/` (Cloudflare does not compile TSX on request) and
`assets.directory` pointing there; `wrangler deploy`. `worker.ts` and the SQL do not change.

## Approaches

- **A. A Worker-shaped app in the artifacts folder (picked by the owner).** Starts by itself,
  sandboxed, keys held by Singularity, and the code already has Cloudflare's shape. Costs the
  most work in Singularity, and the D1 wrapper is ours to keep true.
- **B. Real `wrangler dev` in a terminal tab, opened as a web tab.** Nothing to build, and true
  Cloudflare emulation. But every app needs `npm install` and an open terminal, doesn't come back
  after a restart, and has no sandbox: agent-written code with the owner's rights, full network,
  keys in a file.
- **C. Storage only (`window.singularity.db`), no server code.** Small, covers the MCP step. But
  it can't call real APIs (CORS, keys in the page), and moving out means rewriting the data layer.
- Extending plugins was dropped early: approval of every change and one page per plugin fit
  browser tools, not prototypes.

## Builder's calls (the owner can overrule any)

- `wrangler.jsonc` itself is the manifest, rather than a file of our own.
- The app's files are served from the app folder as today; no separate `public/` folder locally.
- "A file exists, else the Worker" as the routing rule, with no `/api` prefix convention.
- The path prefix is stripped for the Worker; pages use relative URLs.
- Hosts are approved just in time through the inbox, not declared in a file.
- The placeholder scheme for keys, and the "code can read this key" switch for signing APIs.
- An agent writes data with `sqlite3` on the file; no MCP tool for SQL.
- The template's page uses Preact from esm.sh through its import map; nothing is vendored.
- `vars` from `wrangler.jsonc` are passed into `env`.
- The panel sits where site settings are for a web tab.
- No auto-restart of a crashed Worker; the next request starts it.
- From the builder check: the Space's agent policy has no say over an app's hosts; a denied host
  stays quiet until the Worker's next start; nothing is removed when a folder disappears, and
  Settings → Data & privacy lists apps with Forget and Delete data; the database is made when the
  app appears, not at the first request; the Worker's log is a file agents can read, with key
  values replaced; the Worker serves no pages.
- Key values in the macOS keychain. **This one needs the owner's yes**: it is a new exception to
  "all data lives under `~/Singularity/`".

## Scope change to record in CLAUDE.md when built

"Apps are in (spec `docs/superpowers/specs/2026-11-13-apps-design.md`): an artifact folder with a
`wrangler.jsonc` gets a sandboxed local Worker and a SQLite database with D1's API, and may call
outside hosts the owner allowed. Not a tab type. This lifts 'API routes on the artifact server'
and 'databases' for apps only; a plain artifact folder is still files only. Key values in the
macOS keychain are a fourth known exception to 'everything under `~/Singularity/`'."

## Left to the builder

- Names and file layout in Core and the app; whether the Worker process shares code with
  `PluginProcess` or stands beside it (the sandbox profile and the line protocol are reused).
- The wire messages, the size and time limits, the idle time before a stop, how many log lines.
- How the host approval rides on `AgentApprovals` and the inbox entry types.
- The panel's exact layout.
- Test split, following the repository's pattern: Core unit tests for every rule (routing, the
  origin checks, host rules, placeholder substitution and scrubbing); Bun tests for `app-host.ts`
  (the D1 wrapper, migrations, the fetch bridge against a fake app side); app tests with a real
  server, a real sandboxed Worker from a fixture app in a temp root, outside requests against a
  fixture server on loopback, approvals as inbox entries, and a fake key store.

## As built (2026-11-14)

Built as designed, with these differences and additions. Each is the builder's call.

- **A Worker also starts when the Space's server starts**, for an app that has no data folder
  yet (copied in while Singularity was not running), not only when the watcher sees it appear.
- **A page load of a missing `.html` inside an app shows "file is missing"** and does not go to
  the Worker. Every other path with no file goes to the Worker, as designed.
- **A request's 30 seconds do not run while the Worker's own outside request is out.** Otherwise a
  request that waits for the owner's Allow in the inbox (120 s by default) would get the Worker
  killed for hanging.
- **A Worker that could not start is not started again until its files change.** The error is
  answered from memory, so a page that polls doesn't start Bun and write the same log line once
  per request.
- **A file change stops the Worker at once**; requests still inside it are answered once more by
  the new process instead of waiting for the old one to finish.
- **Saving a key allows its host** for the app at the same time. A key for a host the app may
  not reach would do nothing.
- **A redirect never asks.** It is followed only to a host already allowed, at most 5 times, and
  the request is built again from the Worker's original for each hop, so a key is put in only
  when the hop's host is the key's.
- **A host is a name without a port** (`api.example.com`, `localhost`): allowing it allows every
  port of it.
- **`list_spaces` gives `app_data_folder` per Space and names the guide once**, in the note under
  the list (`app_guide: …`), only to outside agents and only when the bundle has the guide.
- **Settings → Data & privacy** calls the two actions "Forget Hosts and Keys" and "Delete Data";
  deleted data goes to the Trash.
- **The answer is re-checked** for "the Space exists and the app's folder is still an app".
- **Stopping** (`stop`) lets `ctx.waitUntil` work finish; it does not wait for requests.
- **Limits chosen:** bodies 8 MB each way, a request 30 s, an outside request 30 s, start 20 s,
  idle stop after 600 s, `worker.log` cut to its last 200 lines when it passes 256 KB.
- **The D1 wrapper's differences from D1** are listed in the header of
  `Resources/plugin-host/app-d1.ts` (meta values that can't be real, `exec` one statement per
  line as the real binding, no `withSession` or `dump`, no D1 size limits).

Where things are: `Sources/SingularityCore/Apps/` (every rule, and the Worker process),
`Sources/Singularity/Apps/` (the Workers of a Space, `AppCenter`, outside requests, the keychain,
the panel), `Resources/plugin-host/app-*.ts`, `Apps/template/`, `docs/apps/AUTHORING.md`. Tests:
`AppRulesTests`, `AppHostKeyTests`, `AppWorkerProcessTests` (Core, the last with the real
sandbox), `AppsTests` and `AppPanelTests` (app), `Tests/apps/` (Bun).
