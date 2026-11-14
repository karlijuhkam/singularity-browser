// Tests for Resources/plugin-host/app-host.ts. Run from the repo root: Vendor/bun/bun test Tests/apps
//
// Each test copies a fixture app (Tests/apps/fixtures/<name>) into a fresh temporary folder, starts
// the host there the way Singularity does (minus the sandbox) and plays the app's side over the
// pipes: it writes `start`, `request`, `fetchResult` and `stop` lines and reads what comes back.
// No network is used: the Worker's fetch() only ever reaches this file.
import { Database } from "bun:sqlite";
import { afterEach, expect, test } from "bun:test";
import { cpSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = join(import.meta.dir, "..", "..");
const hostFolder = join(repo, "Resources", "plugin-host");
const vendoredBun = join(repo, "Vendor", "bun", "bun");
// The repository's Bun; when these tests run, that is also the Bun running them.
const bun = existsSync(vendoredBun) ? vendoredBun : process.execPath;

type Pairs = [string, string][];
type Message = {
  t: string;
  id?: number | string;
  message?: string;
  status?: number;
  headers?: Pairs;
  body?: string | null;
  method?: string;
  url?: string;
  level?: string;
  text?: string;
  name?: string;
};

const base64 = (text: string | Uint8Array) => Buffer.from(text).toString("base64");
const bytesOf = (message: Message) => new Uint8Array(Buffer.from(message.body ?? "", "base64"));
const textOf = (message: Message) => Buffer.from(message.body ?? "", "base64").toString("utf8");
const jsonOf = (message: Message) => JSON.parse(textOf(message));

/** One running host and the test's end of its pipes. */
class Host {
  readonly appFolder: string;
  readonly dataFolder: string;
  /** Every message the host has written, in order. */
  readonly messages: Message[] = [];
  /** stdout lines that were not JSON objects with a "t". Must stay empty. */
  readonly strayLines: string[] = [];
  private readonly taken = new Set<Message>();
  private readonly process: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private wake: (() => void)[] = [];
  private outputEnded = false;
  private nextID = 1;

  constructor(appFolder: string, dataFolder: string, environment: Record<string, string> = {}) {
    this.appFolder = appFolder;
    this.dataFolder = dataFolder;
    this.process = Bun.spawn({
      // The flags Singularity uses for every sandboxed Bun (see PluginProcess.swift).
      cmd: [bun, `--config=${join(hostFolder, "bunfig.toml")}`, "--no-env-file", "--no-install", "run", join(hostFolder, "app-host.ts")],
      cwd: appFolder,
      env: { PATH: "/usr/bin:/bin", HOME: dataFolder, ...environment },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    void this.read();
  }

  private async read(): Promise<void> {
    const decoder = new TextDecoder();
    let buffered = "";
    for await (const chunk of this.process.stdout) {
      buffered += decoder.decode(chunk, { stream: true });
      let newline: number;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        try {
          const message = JSON.parse(line);
          if (typeof message?.t !== "string") throw new Error("no t");
          this.messages.push(message);
        } catch {
          this.strayLines.push(line);
        }
      }
      for (const wake of this.wake.splice(0)) wake();
    }
    if (buffered !== "") this.strayLines.push(buffered);
    this.outputEnded = true;
    for (const wake of this.wake.splice(0)) wake();
  }

  write(message: object): void {
    this.process.stdin.write(JSON.stringify(message) + "\n");
    this.process.stdin.flush();
  }

  writeRaw(text: string): void {
    this.process.stdin.write(text);
    this.process.stdin.flush();
  }

  closeInput(): void {
    this.process.stdin.end();
  }

  /** The first message not handed out before that `matches`. Fails after 10 s or when the host is gone. */
  async next(matches: (message: Message) => boolean, what = "a message"): Promise<Message> {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const found = this.messages.find((m) => !this.taken.has(m) && matches(m));
      if (found) {
        this.taken.add(found);
        return found;
      }
      if (this.outputEnded) throw new Error(`the host ended before ${what}; it wrote ${JSON.stringify(this.messages)}`);
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}; the host wrote ${JSON.stringify(this.messages).slice(0, 2000)}`);
      await new Promise<void>((resolve) => {
        this.wake.push(resolve);
        setTimeout(resolve, 250);
      });
    }
  }

  start(keys: Record<string, string> = {}): void {
    this.write({ t: "start", keys, dataFolder: this.dataFolder, appFolder: this.appFolder });
  }

  async ready(keys: Record<string, string> = {}): Promise<void> {
    this.start(keys);
    const answer = await this.next((m) => m.t === "ready" || m.t === "failed", "ready");
    if (answer.t !== "ready") throw new Error("the host failed to start: " + answer.message);
  }

  /** Sends a request and returns its id; the answer is read with response(id). */
  send(method: string, path: string, options: { headers?: Pairs; body?: string | null } = {}): number {
    const id = this.nextID++;
    this.write({
      t: "request",
      id,
      method,
      url: "http://127.0.0.1:4100" + path,
      headers: options.headers ?? [["host", "127.0.0.1:4100"]],
      body: options.body ?? null,
    });
    return id;
  }

  response(id: number | string): Promise<Message> {
    return this.next((m) => m.t === "response" && m.id === id, `the response to request ${id}`);
  }

  async request(method: string, path: string, options: { headers?: Pairs; body?: string | null } = {}): Promise<Message> {
    return this.response(this.send(method, path, options));
  }

  logs(level?: string): string[] {
    return this.messages.filter((m) => m.t === "log" && (level === undefined || m.level === level)).map((m) => m.text ?? "");
  }

  get exited(): Promise<number> {
    return this.process.exited;
  }

  async stderr(): Promise<string> {
    return new Response(this.process.stderr).text();
  }

  kill(): void {
    this.process.kill("SIGKILL");
  }
}

const hosts: Host[] = [];
const folders: string[] = [];

/** A fresh copy of a fixture app and an empty data folder next to it (not created: the host does). */
function copyOf(fixture: string): { appFolder: string; dataFolder: string } {
  const folder = mkdtempSync(join(tmpdir(), "sg-app-"));
  folders.push(folder);
  const appFolder = join(folder, "app");
  cpSync(join(import.meta.dir, "fixtures", fixture), appFolder, { recursive: true });
  return { appFolder, dataFolder: join(folder, "data") };
}

function launch(fixture: string, environment: Record<string, string> = {}): Host {
  const { appFolder, dataFolder } = copyOf(fixture);
  const host = new Host(appFolder, dataFolder, environment);
  hosts.push(host);
  return host;
}

afterEach(async () => {
  for (const host of hosts.splice(0)) {
    host.kill();
    await host.exited;
  }
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

// ---- Starting and answering -------------------------------------------------------------------

test("ready after start; nothing but messages on stdout", async () => {
  const host = launch("basic");
  await host.ready();
  // The Worker's top-level console.log arrived as a log message, before ready.
  expect(host.messages.map((m) => m.t)).toEqual(["log", "ready"]);
  expect(host.messages[0]).toEqual({ t: "log", level: "info", text: "worker module loaded" });
  expect(host.messages[1]).toEqual({ t: "ready" });
  expect(host.strayLines).toEqual([]);
});

test("a GET is answered with the Worker's status, headers and body", async () => {
  const host = launch("basic");
  await host.ready();
  const answer = await host.request("GET", "/hello");
  expect(answer.status).toBe(201);
  expect(textOf(answer)).toBe("hello");
  expect(answer.headers).toContainEqual(["x-app", "basic"]);
  expect(answer.headers).toContainEqual(["content-type", "text/plain"]);
  expect(Object.keys(answer).sort()).toEqual(["body", "headers", "id", "status", "t"]);

  const missing = await host.request("GET", "/nothing-here");
  expect(missing.status).toBe(404);
  expect(textOf(missing)).toBe("no such route: /nothing-here");
});

test("the Worker sees the method, URL, headers and body as given", async () => {
  const host = launch("basic");
  await host.ready();
  const answer = await host.request("POST", "/echo?a=1&b=two%20words", {
    headers: [["host", "127.0.0.1:4100"], ["content-type", "text/plain"], ["x-custom", "yes"], ["cookie", "a=1; b=2"]],
    body: base64("posted text ✓"),
  });
  const seen = jsonOf(answer);
  expect(seen.method).toBe("POST");
  expect(seen.url).toBe("http://127.0.0.1:4100/echo?a=1&b=two%20words");
  expect(seen.body).toBe("posted text ✓");
  expect(seen.headers).toContainEqual(["x-custom", "yes"]);
  expect(seen.headers).toContainEqual(["cookie", "a=1; b=2"]);
  expect(seen.headers).toContainEqual(["content-type", "text/plain"]);

  // A GET has no body, whatever the message says; a string id comes back as the same string.
  host.write({ t: "request", id: "abc", method: "get", url: "http://127.0.0.1:4100/echo", headers: [], body: base64("ignored") });
  const get = await host.response("abc");
  expect(jsonOf(get)).toMatchObject({ method: "GET", body: "" });
});

test("a bare path is completed with the Host header", async () => {
  const host = launch("basic");
  await host.ready();
  host.write({ t: "request", id: 1, method: "GET", url: "/echo?x=1", headers: [["host", "127.0.0.1:5123"]], body: null });
  expect(jsonOf(await host.response(1)).url).toBe("http://127.0.0.1:5123/echo?x=1");
  host.write({ t: "request", id: 2, method: "GET", url: "/echo", headers: [], body: null });
  expect(jsonOf(await host.response(2)).url).toBe("http://localhost/echo");
});

test("a thrown error becomes a 500 text answer with the message and stack, and a log error", async () => {
  const host = launch("basic");
  await host.ready();
  const answer = await host.request("GET", "/throw");
  expect(answer.status).toBe(500);
  expect(answer.headers).toEqual([["content-type", "text/plain; charset=utf-8"]]);
  const text = textOf(answer);
  expect(text).toContain("kaboom in the worker");
  // The stack names the Worker's file.
  expect(text).toMatch(/worker\.ts:\d+/);
  const log = await host.next((m) => m.t === "log" && m.level === "error", "the error's log line");
  expect(log.text).toContain("kaboom in the worker");

  // The Worker is still running afterwards.
  expect((await host.request("GET", "/hello")).status).toBe(201);
});

test("a return value that is not a Response becomes a 500", async () => {
  const host = launch("basic");
  await host.ready();
  const answer = await host.request("GET", "/not-a-response");
  expect(answer.status).toBe(500);
  expect(answer.headers).toEqual([["content-type", "text/plain; charset=utf-8"]]);
  expect(textOf(answer)).toContain("worker.ts: fetch() must return a Response");
  expect(textOf(answer)).toContain("just text");
  expect(host.logs("error").join("\n")).toContain("must return a Response");
});

test("console output becomes log messages, and nothing else reaches stdout", async () => {
  const host = launch("basic");
  await host.ready();
  const answer = await host.request("GET", "/log");
  expect(textOf(answer)).toBe("logged");
  const logs = host.messages.filter((m) => m.t === "log").slice(1); // the first is the module's own line
  expect(logs).toEqual([
    { t: "log", level: "info", text: "a log line {\n  count: 2,\n}" },
    { t: "log", level: "error", text: "a warning" },
    { t: "log", level: "error", text: "an error line" },
    { t: "log", level: "info", text: "a raw print\n" },
  ]);
  expect(host.strayLines).toEqual([]);
});

test("two set-cookie headers of an answer stay two", async () => {
  const host = launch("basic");
  await host.ready();
  const answer = await host.request("GET", "/cookies");
  const cookies = (answer.headers ?? []).filter(([name]) => name.toLowerCase() === "set-cookie").map(([, value]) => value);
  expect(cookies).toEqual(["a=1; Path=/", "b=2; Path=/; HttpOnly"]);
});

test("requests run side by side and are answered as they finish", async () => {
  const host = launch("basic");
  await host.ready();
  const slow = host.send("GET", "/slow?ms=400&tag=slow");
  const fast = host.send("GET", "/slow?ms=20&tag=fast");
  const [slowAnswer, fastAnswer] = await Promise.all([host.response(slow), host.response(fast)]);
  expect(textOf(slowAnswer)).toBe("slow");
  expect(textOf(fastAnswer)).toBe("fast");
  // The one sent second came back first: the first did not hold it up.
  const order = host.messages.filter((m) => m.t === "response").map((m) => m.id);
  expect(order).toEqual([fast, slow]);
});

test("a 2 MB body goes in and comes out intact", async () => {
  const host = launch("basic");
  await host.ready();
  const bytes = new Uint8Array(2 * 1024 * 1024);
  // Every byte value, in a pattern with no short period, so a lost or repeated piece shows.
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 31 + (i >> 8)) & 0xff;
  const answer = await host.request("POST", "/echo-bytes", { body: base64(bytes) });
  expect(answer.status).toBe(200);
  const back = bytesOf(answer);
  expect(back.length).toBe(bytes.length);
  expect(Buffer.compare(back, bytes)).toBe(0);
  expect(host.strayLines).toEqual([]);
});

// ---- Outside requests -------------------------------------------------------------------------

test("fetch() in the Worker becomes a fetch message, and the fetchResult its Response", async () => {
  const host = launch("basic");
  await host.ready({ API_KEY: "sgkey_placeholder" });
  const id = host.send("GET", "/fetch?to=" + encodeURIComponent("https://api.example.com/v1/items?page=2"));

  const outgoing = await host.next((m) => m.t === "fetch", "the fetch message");
  expect(Object.keys(outgoing).sort()).toEqual(["body", "headers", "id", "method", "t", "url"]);
  expect(typeof outgoing.id).toBe("number");
  expect(outgoing.method).toBe("POST");
  expect(outgoing.url).toBe("https://api.example.com/v1/items?page=2");
  expect(outgoing.headers).toContainEqual(["x-from", "worker"]);
  // The key's placeholder travels as the Worker wrote it; the app swaps it for the value.
  expect(outgoing.headers).toContainEqual(["authorization", "Bearer sgkey_placeholder"]);
  expect(textOf(outgoing)).toBe("outgoing body");

  host.write({
    t: "fetchResult",
    id: outgoing.id,
    status: 418,
    statusText: "I'm a teapot",
    headers: [["content-type", "application/json"], ["x-answer", "1"], ["set-cookie", "s=1"], ["set-cookie", "t=2; Secure"]],
    body: base64('{"items":[1,2]}'),
    url: "https://api.example.com/v1/items?page=2&redirected=1",
  });
  const seen = jsonOf(await host.response(id));
  expect(seen.status).toBe(418);
  expect(seen.statusText).toBe("I'm a teapot");
  expect(seen.ok).toBe(false);
  expect(seen.url).toBe("https://api.example.com/v1/items?page=2&redirected=1");
  expect(seen.body).toBe('{"items":[1,2]}');
  expect(seen.headers).toContainEqual(["x-answer", "1"]);
  expect(seen.headers).toContainEqual(["content-type", "application/json"]);
  // Both cookies of the outside answer reached the Worker as two headers.
  expect(seen.cookies).toEqual(["s=1", "t=2; Secure"]);
});

test("a fetchResult with an error rejects the Worker's fetch with that message", async () => {
  const host = launch("basic");
  await host.ready();
  const id = host.send("GET", "/fetch?to=" + encodeURIComponent("https://denied.example.com/"));
  const outgoing = await host.next((m) => m.t === "fetch", "the fetch message");
  host.write({ t: "fetchResult", id: outgoing.id, error: "denied.example.com is not allowed for this app" });
  const answer = await host.response(id);
  expect(answer.status).toBe(502);
  expect(jsonOf(answer)).toEqual({ failed: "denied.example.com is not allowed for this app", name: "TypeError" });
});

test("fetches side by side get their own answers; no body is null; a 204 works", async () => {
  const host = launch("basic");
  await host.ready();
  const first = host.send("GET", "/fetch-bytes?to=" + encodeURIComponent("https://one.example.com/"));
  const second = host.send("GET", "/fetch-bytes?to=" + encodeURIComponent("https://two.example.com/"));
  const a = await host.next((m) => m.t === "fetch" && m.url === "https://one.example.com/", "the first fetch");
  const b = await host.next((m) => m.t === "fetch" && m.url === "https://two.example.com/", "the second fetch");
  expect(a.id).not.toBe(b.id);
  expect(a.method).toBe("GET");
  expect(a.body).toBeNull();
  // Answered in the other order, with bytes that are not text.
  host.write({ t: "fetchResult", id: b.id, status: 200, statusText: "OK", headers: [], body: base64(new Uint8Array([0, 255, 10, 13])), url: b.url });
  host.write({ t: "fetchResult", id: a.id, status: 204, statusText: "No Content", headers: [], body: null, url: a.url });
  expect([...bytesOf(await host.response(second))]).toEqual([0, 255, 10, 13]);
  expect(bytesOf(await host.response(first)).length).toBe(0);
  // An answer nobody waits for is dropped quietly.
  host.write({ t: "fetchResult", id: 9999, status: 200, statusText: "OK", headers: [], body: null, url: "https://x.example.com/" });
  expect((await host.request("GET", "/hello")).status).toBe(201);
});

// ---- env --------------------------------------------------------------------------------------

test("env has vars, then keys; a name that is not defined is reported once", async () => {
  const host = launch("basic");
  await host.ready({ API_KEY: "secret value", SHADOWED: "the key" });
  const seen = jsonOf(await host.request("GET", "/env"));
  expect(seen.greeting).toBe("hello from vars");
  expect(seen.limits).toEqual({ max: 3 });
  expect(seen.key).toBe("secret value");
  // A key wins over a var of the same name.
  expect(seen.shadowed).toBe("the key");
  expect(seen.nope).toEqual([true, true]);
  expect(seen.alsoNope).toBe(true);
  expect(seen.hasDB).toBe("function");

  // The same route again: the names were already reported.
  await host.request("GET", "/env");
  const reads = host.messages.filter((m) => m.t === "envRead");
  expect(reads).toEqual([{ t: "envRead", name: "NOPE" }, { t: "envRead", name: "ALSO_NOPE" }]);
});

test("a key that is not set is reported when the Worker reads it", async () => {
  const host = launch("basic");
  await host.ready(); // no API_KEY
  await host.request("GET", "/env");
  expect(host.messages.filter((m) => m.t === "envRead").map((m) => m.name)).toEqual(["API_KEY", "NOPE", "ALSO_NOPE"]);
});

// ---- The database -----------------------------------------------------------------------------

test("env.DB works, and its file is <dataFolder>/DB.sqlite with the migrations applied", async () => {
  const host = launch("basic");
  await host.ready();
  expect(jsonOf(await host.request("GET", "/notes"))).toEqual([{ id: 1, title: "seeded" }]);
  const created = await host.request("POST", "/notes", { body: base64("from a request") });
  expect(created.status).toBe(201);
  expect(jsonOf(created)).toEqual({ id: 2 });

  const file = join(host.dataFolder, "DB.sqlite");
  expect(existsSync(file)).toBe(true);
  const outside = new Database(file);
  try {
    expect(outside.query("SELECT title FROM notes ORDER BY id").all()).toEqual([{ title: "seeded" }, { title: "from a request" }]);
    expect(outside.query("PRAGMA journal_mode").get()).toEqual({ journal_mode: "wal" });
    expect(outside.query("SELECT name FROM d1_migrations ORDER BY id").all()).toEqual([{ name: "0001_init.sql" }, { name: "0002_seed.sql" }]);
  } finally {
    outside.close();
  }
});

test("rows another connection writes while the host runs are in the Worker's next query", async () => {
  const host = launch("basic");
  await host.ready();
  expect(jsonOf(await host.request("GET", "/notes")).length).toBe(1);
  // What an agent's `sqlite3` does: its own connection to the same file.
  const outside = new Database(join(host.dataFolder, "DB.sqlite"));
  try {
    outside.run("INSERT INTO notes (title) VALUES ('written from outside')");
    expect(jsonOf(await host.request("GET", "/notes"))).toEqual([
      { id: 1, title: "seeded" },
      { id: 2, title: "written from outside" },
    ]);
    // And the other way round, while that connection stays open.
    await host.request("POST", "/notes", { body: base64("written by the worker") });
    expect(outside.query("SELECT COUNT(*) AS n FROM notes").get()).toEqual({ n: 3 });
  } finally {
    outside.close();
  }
});

test("a second start on the same data folder does not apply migrations again", async () => {
  const { appFolder, dataFolder } = copyOf("basic");
  const first = new Host(appFolder, dataFolder);
  hosts.push(first);
  await first.ready();
  await first.request("POST", "/notes", { body: base64("kept") });
  first.write({ t: "stop" });
  expect(await first.exited).toBe(0);

  // A migration added between the two starts runs; the old ones don't (0002 would add a row).
  writeFileSync(join(appFolder, "migrations", "0003_more.sql"), "INSERT INTO notes (title) VALUES ('from 0003');");
  const second = new Host(appFolder, dataFolder);
  hosts.push(second);
  await second.ready();
  expect(jsonOf(await second.request("GET", "/notes")).map((n: { title: string }) => n.title)).toEqual(["seeded", "kept", "from 0003"]);
});

test("a wrangler.json, a main in a subfolder, no database", async () => {
  const host = launch("plain-json");
  await host.ready();
  expect(jsonOf(await host.request("GET", "/"))).toEqual({ mode: "plain", db: "undefined" });
  // No binding, no file.
  expect(existsSync(join(host.dataFolder, "DB.sqlite"))).toBe(false);
  expect(host.messages.filter((m) => m.t === "envRead")).toEqual([{ t: "envRead", name: "DB" }]);
});

// ---- Failing to start -------------------------------------------------------------------------

async function failure(host: Host): Promise<string> {
  host.start();
  const answer = await host.next((m) => m.t === "ready" || m.t === "failed", "failed");
  expect(answer.t).toBe("failed");
  expect(await host.exited).toBe(1);
  // `failed` is the last thing written, and stdout held nothing but messages.
  expect(host.messages.at(-1)).toBe(answer);
  expect(host.strayLines).toEqual([]);
  return answer.message ?? "";
}

test("a Worker with a syntax error: failed, with the file, the line and what Bun says; exit 1", async () => {
  const message = await failure(launch("syntax-error"));
  expect(message.startsWith("worker.ts: ")).toBe(true);
  expect(message).toContain('Expected ")" but found ";"');
  // The place: the offending line and file:line:column.
  expect(message).toContain('return new Response("never";');
  expect(message).toMatch(/worker\.ts:4:\d+/);
});

test("a failing migration: failed, naming the file; earlier migrations stay", async () => {
  const host = launch("bad-migration");
  const message = await failure(host);
  expect(message.startsWith("db/migrations/0002_broken.sql: ")).toBe(true);
  expect(message).toContain("no such table: nowhere");
  const outside = new Database(join(host.dataFolder, "DB.sqlite"));
  try {
    expect(outside.query("SELECT name FROM d1_migrations").all()).toEqual([{ name: "0001_ok.sql" }]);
  } finally {
    outside.close();
  }
});

test("other ways not to start, each with a message that says what to fix", async () => {
  expect(await failure(launch("no-fetch"))).toBe(
    "worker.ts: the default export needs a fetch function: export default { async fetch(request, env, ctx) { … } }",
  );

  const thrown = await failure(launch("throws-at-load"));
  expect(thrown.startsWith("worker.ts: ")).toBe(true);
  expect(thrown).toContain("could not set up at load");
  expect(thrown).toMatch(/worker\.ts:2/);

  const noWorker = launch("plain-json");
  rmSync(join(noWorker.appFolder, "src"), { recursive: true });
  expect(await failure(noWorker)).toStartWith("src/index.ts: not found");

  const noManifest = launch("plain-json");
  rmSync(join(noManifest.appFolder, "wrangler.json"));
  expect(await failure(noManifest)).toStartWith("wrangler.jsonc: not found");

  const badManifest = launch("basic");
  writeFileSync(join(badManifest.appFolder, "wrangler.jsonc"), '{ "d1_databases": [{ "binding": "my-db" }] }');
  expect(await failure(badManifest)).toStartWith('wrangler.jsonc: a "d1_databases" entry\'s "binding" must be a JavaScript name');

  const outside = launch("basic");
  writeFileSync(join(outside.appFolder, "wrangler.jsonc"), '{ "main": "../elsewhere.ts" }');
  expect(await failure(outside)).toStartWith('wrangler.jsonc: "main" must stay inside the app\'s folder');
});

// ---- Stopping ---------------------------------------------------------------------------------

test("stop waits for ctx.waitUntil, then exits 0", async () => {
  const host = launch("basic");
  await host.ready();
  expect(textOf(await host.request("GET", "/wait"))).toBe("answered first");
  // The background write takes 300 ms; stop comes right away.
  host.write({ t: "stop" });
  expect(await host.exited).toBe(0);
  const outside = new Database(join(host.dataFolder, "DB.sqlite"));
  try {
    expect(outside.query("SELECT title FROM notes ORDER BY id").all()).toEqual([{ title: "seeded" }, { title: "written after the answer" }]);
  } finally {
    outside.close();
  }
  expect(host.strayLines).toEqual([]);
});

test("stop with nothing waiting exits 0 at once; a rejected waitUntil is only logged", async () => {
  const host = launch("basic");
  await host.ready();
  await host.request("GET", "/wait-rejected");
  const log = await host.next((m) => m.t === "log" && m.level === "error", "the rejection's log line");
  expect(log.text).toContain("background work failed");
  const before = Date.now();
  host.write({ t: "stop" });
  expect(await host.exited).toBe(0);
  expect(Date.now() - before).toBeLessThan(3000);
});

test("stop gives up on a waitUntil that never settles (the limit is 30 s; 300 ms here)", async () => {
  const host = launch("basic", { SINGULARITY_APP_STOP_WAIT_MS: "300" });
  await host.ready();
  await host.request("GET", "/wait-forever");
  const before = Date.now();
  host.write({ t: "stop" });
  expect(await host.exited).toBe(0);
  const took = Date.now() - before;
  expect(took).toBeGreaterThanOrEqual(250);
  expect(took).toBeLessThan(5000);
  expect(host.logs("error").join("\n")).toContain("1 waitUntil promise(s) still running");
});

test("end of stdin exits at once, also with work still waiting", async () => {
  const host = launch("basic");
  await host.ready();
  await host.request("GET", "/wait-forever");
  const before = Date.now();
  host.closeInput();
  expect(await host.exited).toBe(0);
  expect(Date.now() - before).toBeLessThan(3000);

  // Also before any start.
  const idle = launch("basic");
  idle.closeInput();
  expect(await idle.exited).toBe(0);
  expect(idle.messages).toEqual([]);
});

// ---- Lines the host can't use -----------------------------------------------------------------

test("a line that is not JSON, or of an unknown kind, is logged and ignored", async () => {
  const host = launch("basic");
  // Before start: only start is accepted.
  host.write({ t: "request", id: 1, method: "GET", url: "http://127.0.0.1:4100/hello", headers: [], body: null });
  await host.ready();
  host.writeRaw("this is not json\n");
  host.writeRaw("{ \"t\": \"request\", broken\n");
  host.writeRaw("\n   \n");
  host.writeRaw("42\n");
  host.write({ t: "dance" });
  host.write({ no: "kind" });
  host.start(); // a second start

  // Still working, and nothing crashed.
  expect((await host.request("GET", "/hello")).status).toBe(201);
  expect(host.logs("error")).toEqual([
    "host: ignored a message that came before start",
    "host: ignored a line that is not JSON",
    "host: ignored a line that is not JSON",
    "host: ignored a line that is not a message",
    'host: ignored a message of unknown kind "dance"',
    "host: ignored a message of unknown kind undefined",
    "host: ignored a second start",
  ]);
  // The request sent before start was dropped, not answered later.
  expect(host.messages.filter((m) => m.t === "response").length).toBe(1);
  expect(host.strayLines).toEqual([]);
});

test("a request the host can't turn into a Request is a 500, not a crash", async () => {
  const host = launch("basic");
  await host.ready();
  host.write({ t: "request", id: 7, method: "GET", url: "not a url", headers: [], body: null });
  const answer = await host.response(7);
  expect(answer.status).toBe(500);
  expect(textOf(answer)).toContain("Invalid URL");
  expect((await host.request("GET", "/hello")).status).toBe(201);
});
