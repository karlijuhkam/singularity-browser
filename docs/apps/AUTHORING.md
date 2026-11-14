# Building a Singularity app

This guide is for agents first and for the owner reading along. It describes apps as Singularity runs them today. If the guide and the code disagree, the code wins; the sources are named at the end.

A starter app is in the `template/` folder next to this guide (in the repository: `Apps/template/`). Start from it.

## What an app is

An **artifact** is a page in a Space's `artifacts/` folder: HTML, or `app.tsx`. Singularity serves the files and shows the page in a tab.

An **app** is an artifact folder that also has a `wrangler.jsonc`. It gets two more things:

- a **Worker**: server code in the shape of a Cloudflare Worker (`export default { fetch(request, env, ctx) }`). Requests the folder has no file for go to it. Singularity runs it on this Mac, in a sandbox with no network of its own.
- a **database**: `env.DB`, a SQLite file with the API of Cloudflare D1.

The Worker can call outside APIs with `fetch()`, but only hosts the owner allowed for that app. API keys are typed in by the owner; the code normally sees a placeholder, never the value.

The code is written as for Cloudflare, so an app that proves itself can be deployed there with few changes (see Moving out to Cloudflare).

**Make an app when** the page must keep data, must call an API that needs a key, or needs code that runs outside the page. **Make a plain artifact when** a page that shows something is enough: a report, a chart, a one-off tool. A plain artifact can still call public APIs with `fetch()` from the page. Do not add a `wrangler.jsonc` "just in case".

## The files, and where they go

Call the MCP tool `list_spaces`. For each Space it gives:

- `artifacts_folder`: where you write the app's folder;
- `app_data_folder`: where Singularity keeps each app's database and log;
- `app_guide` (in the note under the list): the path of this guide. The template is in `template/` next to it.

An app named `firma` in the Space `work`:

```
<artifacts_folder>/firma/        you write this folder
  wrangler.jsonc                 makes the folder an app; names the Worker and the database
  worker.ts                      the Worker
  migrations/0001_init.sql       the tables
  app.tsx                        the page
  importmap.json                 where the page's packages come from

<app_data_folder>/firma/         Singularity writes this folder
  DB.sqlite                      env.DB (one file per database binding, named after the binding)
  worker.log                     what the Worker printed, its errors, why it could not start
```

To start:

```sh
cp -R "<folder of this guide>/template" "<artifacts_folder>/firma"
```

Then change `"name"` in `wrangler.jsonc`, and replace the notes example with your own tables, routes and page.

Rules:

- **The folder's path is the app's identity.** `firma` here. The owner's allowed hosts, the keys and the data folder all hang on that path. If you rename the folder, it is a new app: no hosts, no keys, an empty database. The old data stays on disk under the old name. Pick the name once.
- **An app in a subfolder** (`tools/firma`) has its data folder named `tools%2Ffirma`: one folder per app, directly in `app_data_folder`, never one inside another.
- **The data folder is outside `artifacts/`**, so the server can never serve it. Never put a database, a key or a `.env` file into the app's folder: every file there is served to the page.
- Only `wrangler.jsonc` (or `wrangler.json`) makes an app. A `wrangler.toml` does not.
- No files or folders whose name starts with a dot in a route or page path; they are never served and never reach the Worker.

### What Singularity reads from `wrangler.jsonc`

| Key | Meaning here |
|---|---|
| `main` | The Worker's file, inside the folder. Default `worker.ts`. |
| `d1_databases[].binding` | The name in `env` (`"DB"` → `env.DB`) and of the file (`DB.sqlite`). |
| `d1_databases[].migrations_dir` | Folder of `.sql` files. Default `migrations`. |
| `vars` | Plain values put into `env`. Never keys. |

Everything else is ignored here (`name`, `compatibility_date`, `database_name`, `database_id`, `assets`, …), so the file can already hold what Cloudflare needs. Comments and trailing commas are fine. A file that can't be read stops the Worker from starting; the message says what is wrong.

## How it runs

Nothing is installed, built or started by hand.

1. When `wrangler.jsonc` or a file in `migrations/` appears or changes, Singularity starts the Worker. It creates the database and applies the migrations. So the database exists, with its tables, a moment after you wrote the files, before any request.
2. `app.tsx` opens as a tab by itself (when the folder has no HTML page). The tab reloads when its files change.
3. Any change to any file in the app's folder stops the Worker. The next request starts it again with the new code.
4. A Worker with no requests for 10 minutes is stopped. The next request starts it.

Because the Worker stops and starts often, **keep nothing in module-level variables** that must survive. Put it in the database. This is also true on Cloudflare.

**Check your work after writing the files:**

- `<app_data_folder>/firma/DB.sqlite` exists. (If not after a few seconds, look at the next point; if there is no log either, the Space's artifact server is not running yet: open the app's tab.)
- `<app_data_folder>/firma/worker.log` has no line with `The Worker could not start`.
- Open the tab and read it with the Space's browser tools (`<slug>.list_tabs`, `<slug>.read_page`), when the Space is open to agents.

You cannot call the app's API with `curl`: every request to the artifact server needs the Space's token, which only the app's tabs have.

## The Worker

```ts
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/api/invoices" && request.method === "GET") {
      const { results } = await env.DB.prepare("SELECT * FROM invoices ORDER BY due").all();
      return Response.json(results);
    }
    return Response.json({ error: `No route for ${request.method} ${pathname}` }, { status: 404 });
  },
};
```

It may import other files of the folder (`import { total } from "./money"`). There are no packages: write plain TypeScript, and declare the few types you need by hand, as the template does. (A `node_modules` folder that you put into the app's folder yourself is used as it is; Singularity installs nothing.)

Use only what a Cloudflare Worker has: `fetch`, `Request`, `Response`, `URL`, `Headers`, `crypto`, `TextEncoder`, `JSON`. The Worker runs on Bun here, so `Bun.*`, `process` and `node:` modules happen to exist. Do not use them: they will not be there on Cloudflare, and the sandbox refuses files outside the folder, other programs and sockets anyway.

### Which requests reach the Worker

For a request under the app's folder, in this order:

1. A `GET` or `HEAD` for a path that is a file in the folder gets the file (compiled first, for `.ts` and `.tsx`).
2. Everything else goes to the Worker: any other path, and every `POST`, `PUT`, `PATCH`, `DELETE`.

Details that matter:

- **The Worker sees the app at the root.** The page's request for `/firma/api/invoices` arrives as `/api/invoices`. Route on `/api/…`, never on `/firma/api/…`.
- **Pages are files; the Worker is the API.** A page load of a missing `.html` path shows Singularity's "file is missing" page; it does not reach the Worker. Do not render pages in the Worker.
- **A path without an extension also finds a script.** `GET api/notes` finds a file `api/notes.ts` (or `api/notes/index.ts`) if there is one, and serves it instead of calling the Worker. Keep all routes under `api/` and do not make a folder named `api`.
- **Only the app's own pages may call it.** A request from another origin gets `403`. Every non-`GET` request must carry the page's own `Origin`; a `fetch()` from the page sends it by itself. Other artifact pages of the same Space share the origin and can call the app.
- `OPTIONS` is answered by Singularity with `204` and never reaches the Worker.
- Singularity's own credentials are removed first: the Worker sees no `Authorization` header from the tab and no `singularity_token` cookie, and cannot set that cookie.
- An answer without `Cache-Control` gets `no-store`.

### In the page: relative URLs and hash routes

```ts
await fetch("api/invoices");                       // right: relative to the page
await fetch("/api/invoices");                      // wrong: leaves the app's folder
```

The page lives at `…/firma/app.tsx` here and at `/` on Cloudflare. Relative URLs work in both places; absolute paths work in neither here. For the same reason:

- routes inside the page are **hash routes**: `#/settings`, `#/invoice/14`. Not `history.pushState` paths.
- the Worker must not send redirects or links that start with `/`. Return data; let the page decide where to go.

The page is a TS/TSX artifact. Each file is compiled when the tab asks for it; nothing is bundled. Bare imports (`"preact"`) are resolved by the browser through `importmap.json` next to the page. `/** @jsxImportSource preact */` on the first line makes JSX import `preact/jsx-runtime`; without it JSX imports `react/jsx-runtime`, and the import map must say where that comes from. A script cannot import a `.css` file; insert a `<style>` element, as the template does.

The page also has, as any artifact:

- `window.singularity.open(url)`: opens the address in a new tab of the Space.
- `window.singularity.prompt(text)`: types the text into the Space's terminal and presses Return, after the owner agreed. It returns a promise: `true` when typed, `false` when the owner said no, and it rejects when the Space has no terminal or does not allow it.

### What `env` holds

In this order, a later one winning a name:

1. `vars` from `wrangler.jsonc`;
2. the owner's **keys** (see Keys): `env.MERIT_KEY`;
3. the databases: `env.DB`.

A name that is not there reads as `undefined`, as everywhere. Singularity notes it and lists the name in the app's panel under Keys as "not set", so the owner sees what is missing. Check before use:

```ts
if (!env.MERIT_KEY) return Response.json({ error: "The key MERIT_KEY is not set (the app's panel, Keys)." }, { status: 500 });
```

`.dev.vars` and `.env` files are not read.

### `ctx.waitUntil`

`ctx.waitUntil(promise)` lets work finish after the response was sent, for example writing a log row. Before a Worker is stopped, Singularity waits up to 30 seconds for these promises. A rejection is written to `worker.log`. `ctx.passThroughOnException()` exists and does nothing.

### Errors, and where to read them

- `console.log`, `console.error` and the rest go to `<app_data_folder>/<app>/worker.log`, one entry per call: `2026-11-14T20:41:05Z error …`, further lines indented. The file is cut to its last 200 lines when it grows past 256 KB. Key values are replaced with `[key NAME]` before a line is written.
- The owner sees the same lines in the app's panel.

What the page gets when something goes wrong:

| Status | Body (plain text) | Cause |
|---|---|---|
| 500 | The error's message and stack | The Worker threw, or returned something that is not a `Response`. Also in `worker.log`. |
| 500 | `The Worker of “firma” could not start.` and the reason | A syntax error, a bad `wrangler.jsonc`, a failed migration (the file is named), no `fetch` in the default export. Not tried again until a file in the folder changes or the owner presses Restart. |
| 504 | `…did not answer in time and was stopped.` | A request took more than 30 seconds. The whole Worker is killed. |
| 502 | `…stopped before it answered.` | The Worker process ended under the request. |
| 413 | `…over the 8 MB limit.` | A request or response body is too large. |
| 403 | `Forbidden: an app's Worker only answers its own pages.` | The request came from another origin. |
| 503 | `Apps need the app bundle…` | This copy of Singularity was built without Bun. |

Catch your own errors and answer with JSON, as the template does, so the page can show a message. The page should show the body of any failed answer as text; then both kinds are readable.

### Limits

| | |
|---|---|
| Request body, response body | 8 MB each |
| One request | 30 seconds. Time spent in the Worker's outside requests, including waiting for the owner to allow a host, does not count. |
| One outside request | 30 seconds, 8 MB answer, at most 5 redirects |
| Start (config, migrations, loading the Worker) | 20 seconds |
| Streaming, server-sent events, WebSockets | none: a response is complete before it is sent |
| Cron (`scheduled`) | none |

## The database

`env.DB` is a SQLite file with D1's client API. Foreign keys are enforced, as on D1.

### Migrations

Tables are made **only** in `migrations/*.sql`.

- Files are applied in name order: `0001_init.sql`, `0002_add_due.sql`. Use four digits.
- Each file is applied once, at the Worker's start, and recorded in the table `d1_migrations` (the table wrangler itself uses).
- Each file runs in one transaction. Do not write `BEGIN` or `COMMIT` in it.
- Never edit a file that has been applied: it will not run again. Add a new file.
- A file that fails stops the Worker from starting. The 500 and `worker.log` name the file and SQLite's message. Fix the file; the change starts the Worker again.

Do not create or alter tables with `sqlite3` or from the Worker. On Cloudflare only the migrations will exist.

### The calls

```ts
// first(): one row or null. With a column name: that value.
const invoice = await env.DB.prepare("SELECT * FROM invoices WHERE id = ?").bind(id).first<Invoice>();
const open = await env.DB.prepare("SELECT count(*) AS n FROM invoices WHERE paid = 0").first<number>("n");

// all(): every row, in `results`.
const { results } = await env.DB.prepare("SELECT * FROM invoices WHERE customer = ? ORDER BY due").bind(customer).all<Invoice>();

// run(): a write. `meta.changes` rows were changed; `meta.last_row_id` is the new row's id.
const result = await env.DB.prepare("UPDATE invoices SET paid = 1 WHERE id = ?").bind(id).run();
if (result.meta.changes === 0) return Response.json({ error: "No such invoice." }, { status: 404 });

// batch(): several statements as one transaction. All happen, or none and the call throws.
const insert = env.DB.prepare(
  "INSERT INTO invoices (id, customer, total_cents, due) VALUES (?, ?, ?, ?) " +
  "ON CONFLICT(id) DO UPDATE SET customer = excluded.customer, total_cents = excluded.total_cents, due = excluded.due");
await env.DB.batch(rows.map((row) => insert.bind(row.id, row.customer, row.total_cents, row.due)));
```

Also there: `raw()` (rows as arrays) and `exec(sql)` (SQL text without values). `INSERT … RETURNING` works with `first()` and `all()`.

Always pass values with `bind()`. Never build SQL from request text.

### Where it behaves like D1, and it may surprise you

- **No `BEGIN` / `COMMIT`.** D1 refuses them; SQLite here would accept them. Use `batch()` for anything that must happen together.
- **`bind()` takes `?` and `?1` parameters only**, and exactly as many values as the SQL has parameters. `undefined` throws (`D1_TYPE_ERROR`); pass `null`. `true` and `false` are stored as 1 and 0.
- **`exec()` runs one statement per line.** A statement spread over several lines fails. Prefer `prepare()`.
- A BLOB is read as a plain array of numbers. Integers above 2^53 lose precision.
- Dates have no type. Store ISO text (`2026-11-14T20:41:05Z`) and compare as text.

### Where it differs from D1

- `meta.rows_read`, `meta.rows_written` and `meta.size_after` are rough local numbers, and `meta.served_by` is `singularity-local`. Do not build logic on them. `meta.changes` and `meta.last_row_id` are right.
- No limits are enforced here. D1 has limits on statement length, bound parameters per statement, row size and query time (<https://developers.cloudflare.com/d1/platform/limits/>). Keep statements small and batches modest.
- Error texts: the prefix is D1's (`D1_ERROR: …`), the rest is SQLite's wording. Do not match on the text.
- `withSession()` and `dump()` throw.

## Bringing data in: two stages

The usual life of one source of data, for example invoices from an accounting system.

### Stage 1: you bring the data

You have MCP connections the Worker does not have. Fetch the data through them and write it into the app's database with the `sqlite3` command line. The Worker and `sqlite3` can use the file at the same time.

Small writes:

```sh
sqlite3 -cmd ".timeout 5000" "<app_data_folder>/firma/DB.sqlite" \
  "INSERT INTO invoices (id, customer, total_cents, due) VALUES ('2026-014', 'Example OÜ', 120000, '2026-12-01')
   ON CONFLICT(id) DO UPDATE SET customer = excluded.customer, total_cents = excluded.total_cents, due = excluded.due;"
```

Many rows, or text you did not write yourself: put the rows into a JSON file outside the app's folder and let SQLite read it. Nothing has to be quoted by hand.

```sh
sqlite3 -cmd ".timeout 5000" "<app_data_folder>/firma/DB.sqlite" "
  PRAGMA foreign_keys = ON;
  BEGIN;
  INSERT INTO invoices (id, customer, total_cents, due)
    SELECT value ->> 'id', value ->> 'customer', value ->> 'total_cents', value ->> 'due'
    FROM json_each(readfile('/path/to/rows.json'))
    WHERE true
    ON CONFLICT(id) DO UPDATE SET customer = excluded.customer, total_cents = excluded.total_cents, due = excluded.due;
  UPDATE sources SET refreshed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE name = 'invoices';
  COMMIT;"
```

- `.timeout 5000` makes `sqlite3` wait when the Worker is writing, instead of failing with "database is locked".
- `PRAGMA foreign_keys = ON`: the `sqlite3` program has foreign keys off unless told. The Worker has them on.
- `BEGIN` and `COMMIT` are fine here: this is `sqlite3`, not `env.DB`.
- Write rows only. Tables come from migrations.
- Write so that running it twice is harmless (`ON CONFLICT … DO UPDATE`).
- Do not delete or replace the database file. To start over, the owner uses Settings → Data & privacy → Apps.

**A refresh button.** The page cannot reach your MCP connections, but it can ask you:

```tsx
async function refresh() {
  const asked = await window.singularity.prompt(
    'Refresh the invoices of the app "firma" in this Space: read REFRESH.md in the app\'s folder and follow it.');
  // true: typed into the terminal. false: the owner said no. Then poll api/sources until refreshed_at changes.
}
```

- Put the steps into a file in the app's folder (`REFRESH.md`: which MCP tool, which table, the `sqlite3` command) and keep the prompt short. The owner sees the text and must agree each time.
- The text is typed into the Space's most recently used terminal. An agent must be running there.
- Record when the data was last written (a `sources` table with `refreshed_at`, as above) and show it in the page: "Invoices as of 14 Nov 20:41". The page reads it again every few seconds after asking, and stops after a few minutes.
- Guard the call: `window.singularity` exists only inside Singularity.

### Stage 2: the Worker calls the API

When the source proves useful, promote it: the Worker fetches from the real API with a key. **The table stays. The `GET` route stays. The page stays**, except for what the button does.

```ts
// worker.ts
if (pathname === "/api/refresh/invoices" && request.method === "POST") {
  const response = await fetch("https://api.example.com/v1/invoices", {
    headers: { Authorization: `Bearer ${env.EXAMPLE_KEY}` },
  });
  if (!response.ok) return Response.json({ error: `api.example.com answered ${response.status}` }, { status: 502 });
  const rows = (await response.json()) as Invoice[];
  const insert = env.DB.prepare(
    "INSERT INTO invoices (id, customer, total_cents, due) VALUES (?, ?, ?, ?) " +
    "ON CONFLICT(id) DO UPDATE SET customer = excluded.customer, total_cents = excluded.total_cents, due = excluded.due");
  await env.DB.batch([
    ...rows.map((row) => insert.bind(row.id, row.customer, row.total_cents, row.due)),
    env.DB.prepare("UPDATE sources SET refreshed_at = ? WHERE name = 'invoices'").bind(new Date().toISOString()),
  ]);
  return Response.json({ refreshed: rows.length });
}
```

```tsx
// app.tsx: the button now calls the Worker instead of asking an agent
await fetch("api/refresh/invoices", { method: "POST" });
```

Before it works, the owner must allow the host and add the key. The next two sections say how, and what to tell the owner.

## Outside requests

The sandbox has no network. `fetch()` in the Worker is handed to Singularity, which makes the request if the host is allowed for this app.

- **https only.** Plain http only to `localhost`, `127.0.0.1` and `::1` (a dev server on this Mac), which must be allowed like any other host.
- **Hosts are exact names.** `api.example.com` does not cover `example.com` or `eu.api.example.com`. No wildcards. The port does not matter.
- An address with a user name or password in it is refused.

**A new host asks the owner.** The first `fetch()` to a host that is not allowed waits. An approval appears in the owner's inbox: *The app “firma” wants to connect to api.example.com*, with Allow and Deny. Other requests to the same host wait for the same answer.

- **Allow**: the request goes out. The host is remembered for the app (the app's panel, Connections).
- **Deny, or no answer in time**: `fetch()` throws. The host is then refused **without asking again** until the Worker next starts. Any file change in the app's folder restarts the Worker; so does Restart in the panel. The owner can also allow the host in the panel at any time: denied hosts are listed there with an Allow button, and that works at once.

So: before the first request, tell the owner which host will ask and why. The owner can also add it beforehand in the panel under Connections.

What a refused host looks like in code:

```ts
try {
  response = await fetch("https://api.example.com/v1/invoices");
} catch (error) {
  // TypeError: "api.example.com is not allowed for this app. The owner can allow it in the app's panel (…)."
  // Also thrown when the request itself failed: "The request to api.example.com failed: …"
  return Response.json({ error: (error as Error).message }, { status: 502 });
}
```

Pass the message on to the page. It tells the owner what to do.

**Redirects** are followed by Singularity, at most 5, and only to hosts that are already allowed; a redirect never asks. A redirect to another host fails with *The request was redirected to x, which is not allowed for this app.* A redirect to another host leaves the `Authorization`, `Proxy-Authorization` and `Cookie` headers behind, as a browser does. `response.url` is the final address. `redirect: "manual"` has no effect.

Also: no cookies are kept between requests. Singularity sets `Host`, `Content-Length`, `Connection` and `Accept-Encoding` itself, and hands you the body already decompressed. An `AbortSignal` ends the wait in the Worker.

## Keys

**You never handle a key's value.** Not in a file, not in the terminal, not in the chat. You tell the owner the key's **name** and **host**; the owner types the value into the app's panel.

What to tell the owner, in these words or close to them:

> This app needs an API key for Merit. Open the app's tab and click the button at the right of the address row. Under Keys, add: name `MERIT_KEY`, host `api.merit.ee`, and paste the value. Leave "The app's code can read this key" off.

- The name is letters, digits and `_`, not starting with a digit. It becomes `env.MERIT_KEY`.
- The host is the one host the key may be sent to: a bare name, no `https://`, no path. Saving a key also allows that host, so it will not ask.
- A value has at least 8 characters.
- Saving or deleting a key restarts the Worker.
- If you ever see a key's value (the owner pasted it into the chat), do not write it anywhere. Ask the owner to put it into the panel.

### How the placeholder works

With the switch off (the default), `env.MERIT_KEY` in the Worker is a **placeholder**: text like `sgkey_3f9c…`, new at every start of the Worker. When a request goes to the key's host, Singularity replaces the placeholder with the real value. If the answer contains the real value, it is replaced back before the Worker sees it. The value never enters the sandbox.

Write the code as you would for Cloudflare:

```ts
await fetch("https://api.merit.ee/v2/invoices", { headers: { Authorization: `Bearer ${env.MERIT_KEY}` } });
await fetch(`https://api.merit.ee/v2/invoices?apikey=${env.MERIT_KEY}`);
await fetch("https://api.merit.ee/v2/login", { method: "POST", body: JSON.stringify({ key: env.MERIT_KEY }) });
```

The placeholder is replaced in:

- the URL (the value is percent-encoded for you);
- header values;
- the body. With `Content-Type: application/json` the value gets JSON's escapes, with `application/x-www-form-urlencoded` it is percent-encoded, so a value with quotes or `&` keeps the body well-formed. Set the right `Content-Type`. In any other body it goes in as it is.

It is **not** replaced:

- in a request to any other host. That API receives the text `sgkey_…`, so a key can't be sent elsewhere. A redirect to another host does not carry the key either.
- when you changed it in any way. You cannot hash it, sign with it, base64 it (so no hand-made `Basic` header), cut it, or compare it with anything. To the code it is an opaque piece of text to pass along whole.

Do not store `env.MERIT_KEY` in the database or send it to the page: it is a different text after every restart. A `401` from an API that should accept the key usually means one of the points above; log the status, not the header.

### When to ask for "The app's code can read this key"

Only when the API needs the code to compute something from the key:

- request signing (HMAC, AWS-style signatures);
- `Basic` authentication, where the key is base64-encoded together with a user name;
- a key that must be combined or encoded before sending.

Then tell the owner to switch on "The app's code can read this key" for that key, and say why. `env.NAME` is then the real value. Allowed hosts still apply. Keep such a key out of `console.log`, out of the database and out of every response. The log replaces exact copies of a key's value, not encoded or partial ones.

## What does not work (round 1)

| Not there | Do this instead |
|---|---|
| KV, R2, Durable Objects, Queues, service bindings, `env.ASSETS` | Keep data in `env.DB`. Keep files in the app's folder and let the page load them by relative URL. |
| Cron triggers (`scheduled`) | A refresh button in the page, or refresh when the page loads and the data is older than you like. |
| Streaming responses, server-sent events, WebSockets | Answer whole. For progress, write it to a table and let the page poll. |
| Pages rendered by the Worker; `run_worker_first` | Pages are files. The Worker returns JSON; the page renders it. |
| History-API routes (`/settings`) | Hash routes (`#/settings`). |
| Packages installed by Singularity; a bundler | The page: `importmap.json` (esm.sh) or files you put next to it. The Worker: plain TypeScript. |
| `.dev.vars`, `.env`, secrets in files | The owner types keys into the app's panel. |
| `wrangler.toml`; `env.*` sections of the config | `wrangler.jsonc`, top-level keys. |
| `caches.default`, `request.cf` | Not present here. Store what you want to keep in the database. |
| Sign-in | Locally the owner is the only user. On Cloudflare it is the owner's to add (see below). |
| A deploy or export button; a "New App" command | You write the folder. Moving out is the section below. |
| A fixed address | The server's port changes at every launch. Use relative URLs and never store the origin. |
| Calling the app's API from a terminal | Use the page, or read and write the database with `sqlite3`. |

## Moving out to Cloudflare

`worker.ts` and `migrations/` move unchanged. The page must be built once, because Cloudflare does not compile TSX on request. The steps need `wrangler` (through `npx`) and the owner's Cloudflare account. Commands and config keys below were checked against Cloudflare's documentation on 2026-11-14.

Before you start, tell the owner: **the deployed app has no sign-in.** Its `workers.dev` address is public: anyone who has it can read and change the data. Singularity's "only the app's own pages" check does not exist there either. The owner decides whether to put Cloudflare Access in front of it (Cloudflare can require visitors of a Worker's `workers.dev` address to authenticate) before real data is copied.

Also check first: every source still in stage 1 will stop refreshing. `window.singularity.prompt()` does not exist outside Singularity. Promote the sources that must stay fresh to stage 2.

**1. Copy the folder out of the Space.** Work on a copy in a normal project folder, not in `artifacts/`: the steps below add `node_modules` and `dist`.

```sh
cp -R "<artifacts_folder>/firma" ~/Developer/firma && cd ~/Developer/firma
npx wrangler login
```

**2. Create the database.**

```sh
npx wrangler d1 create firma
```

It prints a `d1_databases` entry with a `database_id`. If it offers to add it to the config for you, say no. Put the name and the id into the existing entry in `wrangler.jsonc`, keeping `"binding": "DB"`:

```jsonc
"d1_databases": [{ "binding": "DB", "database_name": "firma", "database_id": "<the id it printed>" }]
```

Set `"name"` and `"compatibility_date"` (today's date) while you are there.

**3. Apply the migrations to the remote database.**

```sh
npx wrangler d1 migrations apply firma --remote
```

Without `--remote` wrangler works on a local database of its own.

**4. Copy the data.** Dump only the rows of your own tables:

```sh
sqlite3 "<app_data_folder>/firma/DB.sqlite" ".dump --data-only invoices customers sources" > data.sql
npx wrangler d1 execute firma --remote --file=data.sql
```

Name your tables; `--data-only` writes `INSERT` lines and nothing else. This matters, because a full `.dump` holds things D1 refuses or that collide:

- `BEGIN TRANSACTION` and `COMMIT`: D1 refuses them ("cannot start a transaction within a transaction").
- `CREATE TABLE` for your tables: they exist already, from step 3.
- the rows of `d1_migrations`: step 3 wrote them already.
- `sqlite_sequence` and the `PRAGMA writable_schema` lines around it: an internal table. Inserting rows with their ids keeps the counters right without it.

If your `sqlite3` has no `--data-only`, make a full `.dump` and delete those lines by hand. Further:

- List parent tables before the tables that refer to them, or put `PRAGMA defer_foreign_keys = true;` on the first line of `data.sql`.
- A recent `sqlite3` writes text that contains line breaks as `unistr('…')`. If D1 answers "no such function: unistr", make the dump with `sqlite3 -escape off …` instead.
- Check: `npx wrangler d1 execute firma --remote --command "SELECT count(*) FROM invoices"`.

**5. Set the keys.** For each key in the app's panel, the owner runs this and types the value when asked. Not you.

```sh
npx wrangler secret put MERIT_KEY
```

On Cloudflare `env.MERIT_KEY` is the real value and `fetch()` may reach any host. Code that passed the placeholder along works unchanged.

**6. Build the page.** Install the packages that `importmap.json` names, at the same versions, then bundle:

```sh
bun add preact@11.2.0
bun build app.tsx --outdir dist --production
```

`dist/app.js` now contains the page and its packages; the import map is not needed any more. Add `dist/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Firma</title>
</head>
<body>
<div id="root"></div>
<script type="module" src="./app.js"></script>
</body>
</html>
```

Copy any other files the page loads (images, a stylesheet) into `dist/` at the same relative paths.

**7. Point Cloudflare at the built page.** In `wrangler.jsonc`, remove the comment marks from:

```jsonc
"assets": { "directory": "./dist" }
```

Cloudflare then does what Singularity did: a request that matches a file in `dist/` gets the file, every other request runs the Worker. `/` serves `index.html`. Keep `directory` at `./dist`, never `.`: everything in that folder becomes public.

**8. Deploy.**

```sh
npx wrangler deploy
```

It prints the address.

**9. Check.**

- The page loads at the address and lists the data.
- Add, change and delete something. The page's relative URLs (`api/invoices`) now resolve to `/api/invoices`, which is the path the Worker always saw; nothing in `worker.ts` changes. If a request fails with 404, look for a URL in the page that starts with `/` or contains the old folder name.
- Hash routes still work after a reload.
- Each outside API answers: the secrets are set (`npx wrangler secret list`).
- Buttons that used `window.singularity` are gone or guarded.
- Tell the owner again that the address is public unless Cloudflare Access was added.

Optional afterwards: `npx wrangler types` writes full types for `env`; the hand-written ones in `worker.ts` can then go.

## Before you tell the owner it is done

- [ ] The folder has `wrangler.jsonc`, the Worker, `migrations/`, the page and `importmap.json`, and nothing secret.
- [ ] `<app_data_folder>/<app>/DB.sqlite` exists and `worker.log` has no "could not start" and no errors from your last try.
- [ ] Every table is made by a migration. No applied migration was edited.
- [ ] Every URL in the page is relative (`api/…`). Routes in the page are hash routes. The Worker routes on `/api/…` and sends no absolute redirects.
- [ ] The page shows the body of a failed request as text. You have seen it do so.
- [ ] All SQL values go through `bind()`. Things that belong together are in one `batch()`. No `BEGIN`.
- [ ] Nothing that must last is kept in the Worker's memory.
- [ ] Only Worker APIs are used: no `Bun.*`, no `process`, no `node:` imports.
- [ ] No key value is in any file, command or message. Keys are used whole, only towards their own host.
- [ ] You told the owner, by name: each host that will ask for approval, and each key to add (name, host, where to type it, and whether the "code can read this key" switch is needed and why).
- [ ] If there is a stage-1 refresh: `REFRESH.md` is in the folder, the write can be run twice, and the page shows when the data was last written.
- [ ] You opened the tab and saw the page work with real rows.

## Sources

- Design: `docs/superpowers/specs/2026-11-13-apps-design.md`. The page side: `docs/superpowers/specs/2026-11-10-ts-artifacts-design.md`.
- What runs the Worker: `Resources/plugin-host/app-host.ts`, `app-d1.ts` (its header lists every difference from D1), `app-config.ts`.
- Routing, origin checks, hosts, keys: `Sources/SingularityCore/Apps/` (`ArtifactApps.swift`, `AppHosts.swift`, `AppKeys.swift`).
- Starting and stopping, outside requests, the panel: `Sources/Singularity/Apps/`; the server: `Sources/Singularity/Artifacts/ArtifactServer.swift`.
- A working app: `Apps/template/`.
