// Singularity app host: runs one app's Worker.
//
// An "app" is an artifact folder with a wrangler.jsonc (or wrangler.json) and a Worker file:
//
//     export default {
//       async fetch(request, env, ctx) { return new Response("hello"); }
//     };
//
// Singularity starts one of these per app, inside the macOS sandbox (no network, no other
// programs, files readable only in the app folder, writable only in the app's data folder):
//
//     bun --config=bunfig.toml --no-env-file --no-install run <this folder>/app-host.ts
//
// with the current directory = the app folder. This file runs first: it takes over fetch, console
// and stdout, waits for `start`, reads the manifest (app-config.ts), opens the databases and
// applies their migrations (app-d1.ts), loads the Worker and then answers requests.
//
// How it talks to the app: one JSON object per line, the app writing to our stdin and we to
// stdout. Every message has a "t". Headers are [[name, value], …] (a list, not an object, so that
// several set-cookie headers survive). Bodies are base64 text, or null for "no body".
//
//   app -> host   {"t":"start","keys":{"NAME":"value or placeholder"},"dataFolder":"/…","appFolder":"/…"}
//                 {"t":"request","id":1,"method":"GET","url":"http://127.0.0.1:1234/api/x","headers":[…],"body":null}
//                 {"t":"fetchResult","id":1,"status":200,"statusText":"OK","headers":[…],"body":"…","url":"https://…"}
//                 {"t":"fetchResult","id":1,"error":"api.example.com is not allowed"}
//                 {"t":"stop"}
//   host -> app   {"t":"ready"}
//                 {"t":"failed","message":"worker.ts: …"}                       (then exit 1)
//                 {"t":"response","id":1,"status":200,"headers":[…],"body":"…"}
//                 {"t":"fetch","id":1,"method":"POST","url":"https://…","headers":[…],"body":"…"}
//                 {"t":"log","level":"info","text":"…"}                          (level: "info" or "error")
//                 {"t":"envRead","name":"MERIT_KEY"}                             (once per name)
//
// Details the other side relies on (the Swift side is Sources/SingularityCore/Apps/AppWire.swift
// and AppWorkerProcess.swift):
//
//   - `start` must be the first line. `ready` or `failed` is the answer to it.
//   - A request's `id` is echoed in its `response` as it came (number or string). The `id` of a
//     `fetch` is a number we choose (1, 2, …); it has nothing to do with request ids.
//   - A request's `url` is used as given when it is a full URL. A bare path ("/api/x?y=1") is
//     also accepted and completed with the request's Host header: "http://<host>/api/x?y=1".
//   - `response.body` is always text ("" for no body). `fetch.body` is null when the Worker's
//     request has no body. In `request` and `fetchResult`, null, a missing body and "" all mean
//     no bytes.
//   - `stop`: the host waits for the promises given to ctx.waitUntil (at most 30 s), then exits 0.
//     End of stdin: exit 0 at once.
//   - A line that is not JSON, or has a "t" we don't know, is ignored with a `log` error.
//
// stdout carries only these messages: everything is written by send(), and console.* and
// process.stdout.write are redirected into `log` messages, so a stray print can't break a line.

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { type AppConfig, parseAppConfig } from "./app-config.ts";
import { applyMigrations, D1Database, MigrationError, openSQLite } from "./app-d1.ts";

// ---- Messages ---------------------------------------------------------------------------------

type HeaderPairs = [string, string][];
type MessageID = number | string;

type StartMessage = { t: "start"; keys: Record<string, string>; dataFolder: string; appFolder: string };
type RequestMessage = { t: "request"; id: MessageID; method: string; url: string; headers: HeaderPairs; body: string | null };
type FetchResultMessage = {
  t: "fetchResult";
  id: number;
  error?: string;
  status?: number;
  statusText?: string;
  headers?: HeaderPairs;
  body?: string | null;
  url?: string;
};

type OutgoingMessage =
  | { t: "ready" }
  | { t: "failed"; message: string }
  | { t: "response"; id: MessageID; status: number; headers: HeaderPairs; body: string }
  | { t: "fetch"; id: number; method: string; url: string; headers: HeaderPairs; body: string | null }
  | { t: "log"; level: "info" | "error"; text: string }
  | { t: "envRead"; name: string };

// ---- Writing messages -------------------------------------------------------------------------

// Our own reference to the real stdout writer, taken before any Worker code runs, so a Worker
// replacing process.stdout.write can't affect our messages.
const writeToStdout = process.stdout.write.bind(process.stdout) as (text: string, done?: () => void) => boolean;

// Lines handed to stdout that the system hasn't taken yet. A pipe takes about 64 KB at once, so a
// large response is written in pieces; before exiting on purpose we wait for this to reach 0.
let unwrittenLines = 0;
let onAllWritten: (() => void) | null = null;

/** The one function that writes to stdout. */
function send(message: OutgoingMessage): void {
  unwrittenLines += 1;
  // JSON.stringify escapes line breaks inside strings, so one message is always one line.
  writeToStdout(JSON.stringify(message) + "\n", () => {
    unwrittenLines -= 1;
    if (unwrittenLines === 0) onAllWritten?.();
  });
}

/** Exits once everything sent so far has left the process (or after 5 s, if nobody reads). */
function exitAfterWriting(status: number): void {
  if (unwrittenLines === 0) process.exit(status);
  onAllWritten = () => process.exit(status);
  setTimeout(() => process.exit(status), 5000);
}

// ---- Logging ----------------------------------------------------------------------------------

/** One log message is cut to this many characters (a Worker printing a whole table in a loop). */
const LOG_MAX_CHARACTERS = 64 * 1024;

/** Console-style arguments as one text: strings as they are, other values inspected. */
function format(values: unknown[]): string {
  return values.map((v) => (typeof v === "string" ? v : Bun.inspect(v))).join(" ");
}

function log(level: "info" | "error", text: string): void {
  const cut = text.length > LOG_MAX_CHARACTERS ? text.slice(0, LOG_MAX_CHARACTERS) + " … (cut)" : text;
  send({ t: "log", level, text: cut });
}

/** An error as text for the log and for a 500 answer: its message and where it was thrown. */
function describeError(error: unknown): string {
  if (!(error instanceof Error)) return typeof error === "string" ? error : Bun.inspect(error);
  const headline = `${error.name}: ${error.message}`;
  const stack = error.stack ?? "";
  // Bun's stack usually starts with the headline; don't print it twice.
  if (stack.includes(error.message)) return stack;
  return stack === "" ? headline : headline + "\n" + stack;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

console.log = (...values: unknown[]) => log("info", format(values));
console.info = (...values: unknown[]) => log("info", format(values));
console.debug = (...values: unknown[]) => log("info", format(values));
console.dir = (value: unknown) => log("info", format([value]));
console.table = (value: unknown) => log("info", format([value]));
console.trace = (...values: unknown[]) => log("info", format(values));
console.warn = (...values: unknown[]) => log("error", format(values));
console.error = (...values: unknown[]) => log("error", format(values));
// Bun-specific: console.write prints raw text to stdout.
(console as unknown as { write: (...data: unknown[]) => number }).write = (...data: unknown[]) => {
  log("info", format(data));
  return 0;
};
process.stdout.write = ((chunk: unknown) => {
  log("info", typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk as Uint8Array));
  return true;
}) as typeof process.stdout.write;

// A forgotten promise rejection or an error thrown in a timer is logged and the Worker keeps
// running: one bad request must not take the app's other requests down with it.
process.on("unhandledRejection", (reason: unknown) => {
  log("error", "unhandled promise rejection: " + describeError(reason));
});
process.on("uncaughtException", (error: unknown) => {
  log("error", "uncaught exception: " + describeError(error));
});

// ---- Bodies and headers on the wire -----------------------------------------------------------

function toBase64(bytes: ArrayBuffer): string {
  return Buffer.from(bytes).toString("base64");
}

/** null, a missing body and "" all give null: no bytes. */
function fromBase64(text: string | null | undefined): Uint8Array | null {
  if (typeof text !== "string" || text === "") return null;
  return new Uint8Array(Buffer.from(text, "base64"));
}

/** Headers as pairs. Iterating a Headers object gives each set-cookie header on its own. */
function headerPairs(headers: Headers): HeaderPairs {
  return [...headers] as HeaderPairs;
}

/** Pairs as Headers; append() keeps repeated names (set-cookie stays several headers). */
function headersFrom(pairs: unknown): Headers {
  const headers = new Headers();
  if (!Array.isArray(pairs)) return headers;
  for (const pair of pairs) {
    if (Array.isArray(pair) && typeof pair[0] === "string" && typeof pair[1] === "string") {
      headers.append(pair[0], pair[1]);
    }
  }
  return headers;
}

// ---- fetch: sent to the app, which makes the request ------------------------------------------
//
// The sandbox has no network. The Worker's fetch() becomes a `fetch` message; Singularity checks
// the host against the ones the owner allowed, puts keys in, makes the request and sends the
// answer back as `fetchResult`. Whole bodies travel in one message, so nothing streams.

type PendingFetch = { resolve: (response: Response) => void; reject: (error: unknown) => void };
const pendingFetches = new Map<number, PendingFetch>();
let nextFetchID = 1;

/** Statuses whose Response must not have a body. */
const NO_BODY_STATUSES = new Set([101, 204, 205, 304]);

async function bridgedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  // Request does the work of understanding every form fetch() accepts (a URL, a Request, a body
  // as text, FormData, a stream, …) and throws the usual TypeError for a bad one.
  const request = new Request(input, init);
  if (request.signal.aborted) throw request.signal.reason;
  const body = request.body === null ? null : toBase64(await request.arrayBuffer());
  const id = nextFetchID++;

  return new Promise<Response>((resolve, reject) => {
    pendingFetches.set(id, { resolve, reject });
    // An abort ends the wait in the Worker. The app is not told (the wire has no "cancel"): it
    // finishes or times out the request by itself, and its late answer is dropped.
    request.signal.addEventListener("abort", () => {
      if (pendingFetches.delete(id)) reject(request.signal.reason);
    });
    send({ t: "fetch", id, method: request.method, url: request.url, headers: headerPairs(request.headers), body });
  });
}

function handleFetchResult(message: FetchResultMessage): void {
  const pending = pendingFetches.get(message.id);
  if (!pending) return; // aborted meanwhile, or an id we never sent
  pendingFetches.delete(message.id);
  if (typeof message.error === "string") {
    // fetch() fails with a TypeError in every runtime; the text is the app's (it names the host).
    pending.reject(new TypeError(message.error));
    return;
  }
  try {
    const status = message.status ?? 200;
    const bytes = NO_BODY_STATUSES.has(status) ? null : (fromBase64(message.body) ?? new Uint8Array(0));
    const response = new Response(bytes, {
      status,
      statusText: message.statusText ?? "",
      headers: headersFrom(message.headers),
    });
    // A Response made by hand has url "". Code that looks at response.url (after a redirect, say)
    // should see the address the answer came from.
    if (typeof message.url === "string") {
      Object.defineProperty(response, "url", { value: message.url, configurable: true });
    }
    pending.resolve(response);
  } catch (error) {
    // e.g. a status outside 200…599
    pending.reject(new TypeError("fetch failed: the answer could not be read: " + errorMessage(error)));
  }
}

globalThis.fetch = bridgedFetch as typeof fetch;

// ---- env --------------------------------------------------------------------------------------

/** Names the Worker read from env that are not defined, each reported once. */
const reportedEnvReads = new Set<string>();

/**
 * The Worker's env: vars from the manifest, then the owner's keys, then the databases (a later
 * one wins a name). Reading a name that isn't there gives undefined, as everywhere, and tells the
 * app, which lists it in the app's panel as a key that is "not set".
 */
function makeEnv(config: AppConfig, keys: Record<string, string>, databases: Record<string, D1Database>): object {
  const values: Record<string, unknown> = { ...config.vars, ...keys, ...databases };
  return new Proxy(values, {
    get(target, name, receiver) {
      // Not reported: symbols (inspection, iteration), names that exist (also inherited ones such
      // as toString), and the two names JavaScript itself asks any object for: `then` (await env)
      // and `toJSON` (JSON.stringify(env)).
      if (typeof name === "symbol" || name in target || name === "then" || name === "toJSON") {
        return Reflect.get(target, name, receiver);
      }
      if (!reportedEnvReads.has(name)) {
        reportedEnvReads.add(name);
        send({ t: "envRead", name });
      }
      return undefined;
    },
  });
}

// ---- Starting ---------------------------------------------------------------------------------

type Worker = { fetch: (request: Request, env: object, ctx: ExecutionContext) => unknown };
type Running = { worker: Worker; env: object; main: string };

const MANIFEST_NAMES = ["wrangler.jsonc", "wrangler.json"];

/** A reason the Worker can't start, already worded for the developer. */
class StartError extends Error {}

function isRecordOfStrings(value: unknown): value is Record<string, string> {
  return (
    typeof value === "object" && value !== null && !Array.isArray(value) &&
    Object.values(value).every((v) => typeof v === "string")
  );
}

function readConfig(appFolder: string): AppConfig {
  const name = MANIFEST_NAMES.find((candidate) => existsSync(join(appFolder, candidate)));
  if (!name) throw new StartError(`wrangler.jsonc: not found in ${appFolder}`);
  try {
    return parseAppConfig(readFileSync(join(appFolder, name), "utf8"));
  } catch (error) {
    throw new StartError(`${name}: ${errorMessage(error)}`);
  }
}

function openDatabases(config: AppConfig, appFolder: string, dataFolder: string): Record<string, D1Database> {
  const databases: Record<string, D1Database> = {};
  for (const { binding, migrationsDir } of config.d1) {
    const fileName = `${binding}.sqlite`;
    let sqlite;
    try {
      mkdirSync(dataFolder, { recursive: true });
      sqlite = openSQLite(join(dataFolder, fileName));
    } catch (error) {
      throw new StartError(`${fileName}: the database could not be opened: ${errorMessage(error)}`);
    }
    try {
      applyMigrations(sqlite, join(appFolder, migrationsDir));
    } catch (error) {
      if (error instanceof MigrationError) {
        throw new StartError(`${migrationsDir}/${error.file}: the migration failed: ${error.message}`);
      }
      throw new StartError(`${migrationsDir}: the migrations could not be read: ${errorMessage(error)}`);
    }
    databases[binding] = new D1Database(sqlite);
  }
  return databases;
}

async function loadWorker(appFolder: string, main: string): Promise<Worker> {
  const path = join(appFolder, main);
  if (!existsSync(path)) {
    throw new StartError(`${main}: not found. The app's Worker is the file "main" names in wrangler.jsonc (default worker.ts).`);
  }
  let module: { default?: unknown };
  try {
    module = await import(pathToFileURL(path).href);
  } catch (error) {
    // A file Bun can't compile (or an import it can't find) gives a BuildMessage or
    // ResolveMessage, or an AggregateError of several. Bun.inspect prints each with its line, a
    // marker under the place and "file:line:column"; their `message` alone has no place in it.
    // For an error thrown while the file's top-level code ran, the message and stack say more.
    const name = (error as { name?: unknown } | null)?.name;
    const isBuildError = error instanceof AggregateError || name === "BuildMessage" || name === "ResolveMessage";
    throw new StartError(`${main}: ${isBuildError ? Bun.inspect(error).trim() : describeError(error)}`);
  }
  const worker = module.default as Partial<Worker> | null | undefined;
  if (typeof worker !== "object" || worker === null || typeof worker.fetch !== "function") {
    throw new StartError(
      `${main}: the default export needs a fetch function: export default { async fetch(request, env, ctx) { … } }`,
    );
  }
  return worker as Worker;
}

async function start(message: StartMessage): Promise<Running> {
  if (typeof message.appFolder !== "string" || typeof message.dataFolder !== "string") {
    throw new StartError("start: appFolder and dataFolder are missing");
  }
  const keys = isRecordOfStrings(message.keys) ? message.keys : {};
  const config = readConfig(message.appFolder);
  const databases = openDatabases(config, message.appFolder, message.dataFolder);
  const env = makeEnv(config, keys, databases);
  const worker = await loadWorker(message.appFolder, config.main);
  return { worker, env, main: config.main };
}

// Requests wait for this. It is settled by the `start` line: resolved with the running Worker, or
// the process exits.
let started = false;
let resolveRunning: (running: Running) => void = () => {};
const running = new Promise<Running>((resolve) => {
  resolveRunning = resolve;
});

function handleStart(message: StartMessage): void {
  if (started) {
    log("error", "host: ignored a second start");
    return;
  }
  started = true;
  // Not awaited by the reading loop: the Worker's top-level code may itself call fetch(), whose
  // answer arrives as a later line.
  start(message).then(
    (result) => {
      resolveRunning(result);
      send({ t: "ready" });
    },
    (error: unknown) => {
      send({ t: "failed", message: error instanceof StartError ? error.message : describeError(error) });
      exitAfterWriting(1);
    },
  );
}

// ---- Requests ---------------------------------------------------------------------------------

/** Promises given to ctx.waitUntil that haven't settled yet. `stop` waits for them. */
const waiting = new Set<Promise<unknown>>();

type ExecutionContext = {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
};

function makeContext(): ExecutionContext {
  return {
    waitUntil(promise: Promise<unknown>): void {
      // Promise.resolve: Workers accept any value here. A rejection is logged, never unhandled.
      const tracked: Promise<unknown> = Promise.resolve(promise)
        .catch((error: unknown) => log("error", "waitUntil: " + describeError(error)))
        .finally(() => waiting.delete(tracked));
      waiting.add(tracked);
    },
    // On Cloudflare: "if the Worker throws, send the request on to the origin". There is no
    // origin behind an app, so there is nothing to do.
    passThroughOnException(): void {},
  };
}

/** The Request the Worker gets. Throws for a URL or method that can't be one. */
function makeRequest(message: RequestMessage): Request {
  const headers = headersFrom(message.headers);
  // A bare path is completed with the Host header (see the header comment).
  const url = message.url.startsWith("/") ? `http://${headers.get("host") ?? "localhost"}${message.url}` : message.url;
  const method = typeof message.method === "string" ? message.method.toUpperCase() : "GET";
  // GET and HEAD can't have a body (Request refuses it).
  const body = method === "GET" || method === "HEAD" ? null : fromBase64(message.body);
  return new Request(url, { method, headers, body });
}

function sendError(id: MessageID, text: string): void {
  log("error", text);
  send({
    t: "response",
    id,
    status: 500,
    headers: [["content-type", "text/plain; charset=utf-8"]],
    body: Buffer.from(text, "utf8").toString("base64"),
  });
}

async function handleRequest(message: RequestMessage): Promise<void> {
  const { worker, env, main } = await running;
  try {
    const answer = await worker.fetch(makeRequest(message), env, makeContext());
    if (!(answer instanceof Response)) {
      sendError(message.id, `${main}: fetch() must return a Response, but returned ${Bun.inspect(answer)}`);
      return;
    }
    // The whole body, read here: a body that fails half-way is an error of this request too.
    const body = toBase64(await answer.arrayBuffer());
    send({ t: "response", id: message.id, status: answer.status, headers: headerPairs(answer.headers), body });
  } catch (error) {
    sendError(message.id, describeError(error));
  }
}

// ---- Stopping ---------------------------------------------------------------------------------

/** How long `stop` waits for ctx.waitUntil promises. Tests shorten it; nothing else sets this. */
const STOP_WAIT_MS = Number(process.env.SINGULARITY_APP_STOP_WAIT_MS) || 30_000;

let stopping = false;

async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  const deadline = new Promise<"late">((resolve) => setTimeout(() => resolve("late"), STOP_WAIT_MS));
  // A loop, because a waitUntil promise may itself call waitUntil while we wait.
  while (waiting.size > 0) {
    const outcome = await Promise.race([Promise.allSettled([...waiting]), deadline]);
    if (outcome === "late") {
      log("error", `host: stopped with ${waiting.size} waitUntil promise(s) still running after ${STOP_WAIT_MS / 1000} s`);
      break;
    }
  }
  exitAfterWriting(0);
}

// ---- Reading messages -------------------------------------------------------------------------

function handleLine(line: string): void {
  let message: { t?: unknown };
  try {
    message = JSON.parse(line);
  } catch {
    log("error", "host: ignored a line that is not JSON");
    return;
  }
  if (typeof message !== "object" || message === null) {
    log("error", "host: ignored a line that is not a message");
    return;
  }
  if (message.t === "start") {
    handleStart(message as StartMessage);
  } else if (!started) {
    log("error", "host: ignored a message that came before start");
  } else if (message.t === "request") {
    // Not awaited: requests run side by side and are answered in whatever order they finish.
    void handleRequest(message as RequestMessage);
  } else if (message.t === "fetchResult") {
    handleFetchResult(message as FetchResultMessage);
  } else if (message.t === "stop") {
    void stop();
  } else {
    log("error", `host: ignored a message of unknown kind ${JSON.stringify(message.t)}`);
  }
}

// Read stdin as lines until the app closes it, then exit at once.
const decoder = new TextDecoder();
let buffered = "";
for await (const chunk of Bun.stdin.stream()) {
  // A line with a large body arrives in many chunks; look for its end only in the new part.
  let searchFrom = buffered.length;
  buffered += decoder.decode(chunk, { stream: true });
  let newline: number;
  while ((newline = buffered.indexOf("\n", searchFrom)) >= 0) {
    const line = buffered.slice(0, newline);
    buffered = buffered.slice(newline + 1);
    searchFrom = 0;
    if (line.trim() !== "") handleLine(line);
  }
}
process.exit(0);
