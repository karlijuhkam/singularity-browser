// Singularity plugin host.
//
// Singularity starts every plugin's background program like this (inside a macOS sandbox:
// no network, no starting other programs, files only in the plugin's own folder and its data folder):
//
//     bun --config=bunfig.toml --no-env-file --no-install run host.ts <plugin folder>/<background file>
//
// (bunfig.toml is the empty one next to this file, so a plugin's own bunfig.toml and .env files are
// not used, and Bun never tries to download missing packages.)
//
// This file runs first. It gives the plugin its API, then loads the plugin's background file.
// Plugins use the API like this:
//
//     import { singularity } from "singularity";
//
//     singularity.onPageMessage(async ({ tabID, frameHost, payload }) => {
//       const result = await singularity.run("op", ["item", "list", "--format", "json"]);
//       await singularity.storage.set("lastListed", Date.now());   // kept across restarts
//       return { items: JSON.parse(result.stdout) };      // becomes the page script's answer
//     });
//
// How it talks to the app: one JSON object per line. The app writes messages to our stdin;
// we write messages to stdout. Every message has a "kind":
//
//   app -> plugin   {"kind":"pageMessage","requestID":1,"tabID":"…","frameHost":"…","payload":…}
//                   {"kind":"commandResult","callID":1,"result":{"status":0,"stdout":"…","stderr":"…","timedOut":false}}
//   plugin -> app   {"kind":"reply","requestID":1,"payload":…}
//                   {"kind":"runCommand","callID":1,"command":"op","arguments":["item","list"]}
//                   {"kind":"log","level":"info","message":"…"}
//
// Limits: Singularity buffers at most 16 MB of messages that the plugin hasn't read yet. If more
// would be waiting (the plugin is stuck, or a single message is larger than 16 MB), the plugin is
// stopped. Lines the plugin writes are capped at 1 MB, log messages at 8 KB, and at most 4
// singularity.run() calls run at once (more are answered with status 126 right away).
//
// Because stdout carries these messages, console.log and friends are redirected to the plugin's
// log (see below) so a stray print can't break a message. The Swift side of this protocol is
// Sources/SingularityCore/Plugins/PluginWire.swift and PluginProcess.swift.

import { mkdir, rename } from "node:fs/promises";
import { pathToFileURL } from "node:url";

// ---- Writing messages -------------------------------------------------------------------------

// Keep our own reference to the real stdout writer, taken before any plugin code runs,
// so the plugin replacing process.stdout.write can't affect our messages.
const writeToStdout: (text: string) => unknown = process.stdout.write.bind(process.stdout);

function send(message: object): void {
  // JSON.stringify escapes newlines inside strings, so one message is always one line.
  writeToStdout(JSON.stringify(message) + "\n");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// ---- Logging ----------------------------------------------------------------------------------

/** Turns console-style arguments into one line of text: strings as they are, other values inspected. */
function format(values: unknown[]): string {
  return values.map((v) => (typeof v === "string" ? v : Bun.inspect(v))).join(" ");
}

function log(level: string, values: unknown[]): void {
  send({ kind: "log", level, message: format(values) });
}

// Everything that would print to stdout goes to the log instead.
console.log = (...values: unknown[]) => log("info", values);
console.info = (...values: unknown[]) => log("info", values);
console.debug = (...values: unknown[]) => log("debug", values);
console.dir = (value: unknown) => log("info", [value]);
console.table = (value: unknown) => log("info", [value]);
console.warn = (...values: unknown[]) => log("warn", values);
console.error = (...values: unknown[]) => log("error", values);
// Bun-specific: console.write prints raw text to stdout.
(console as unknown as { write: (...data: unknown[]) => number }).write = (...data: unknown[]) => {
  log("info", data);
  return 0;
};
process.stdout.write = ((chunk: unknown) => {
  log("info", [typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk as Uint8Array)]);
  return true;
}) as typeof process.stdout.write;

// A forgotten promise rejection or an error thrown in a timer callback is logged (with its stack)
// and the plugin keeps running.
function describeError(error: unknown): string {
  return error instanceof Error ? (error.stack ?? error.message) : Bun.inspect(error);
}
process.on("unhandledRejection", (reason: unknown) => {
  log("error", ["unhandled promise rejection: " + describeError(reason)]);
});
process.on("uncaughtException", (error: unknown) => {
  log("error", ["uncaught exception: " + describeError(error)]);
});

// ---- Storage ----------------------------------------------------------------------------------
//
// singularity.storage: a small key → value store that survives restarts of the plugin and of
// Singularity. It lives in one file, <data folder>/storage.json, the folder the plugin may write
// anyway (HOME points to it). So it gives a plugin nothing it couldn't do with file APIs; it
// spares every plugin writing the careful version of "save some JSON":
//
// - the file is read once, on first use, and kept in memory;
// - every change writes the whole store to a temporary file and renames it over the old one, so
//   a crash or power cut leaves either the old store or the new one, never half a file;
// - changes are written one after another, in the order they were made, and a call's promise
//   resolves when its change is on disk;
// - a file that can't be read as a JSON object is moved aside (storage.unreadable-<time>.json)
//   and the store starts empty, so one bad write can't lock a plugin out for good.

const STORAGE_MAX_BYTES = 5 * 1024 * 1024;
const STORAGE_MAX_KEY_LENGTH = 256;

function storageFolder(): string {
  const home = process.env.HOME;
  if (!home) throw new Error("storage isn't available: the plugin has no data folder");
  return home;
}

let storageValues: Map<string, unknown> | null = null;
let storageLoading: Promise<Map<string, unknown>> | null = null;
// The tail of the queue of writes; each write starts when the one before it has finished.
let storageWrites: Promise<void> = Promise.resolve();

function loadStorage(): Promise<Map<string, unknown>> {
  if (storageValues) return Promise.resolve(storageValues);
  storageLoading ??= (async () => {
    const path = storageFolder() + "/storage.json";
    const values = new Map<string, unknown>();
    const file = Bun.file(path);
    if (await file.exists()) {
      try {
        const parsed = JSON.parse(await file.text());
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
        for (const [key, value] of Object.entries(parsed)) values.set(key, value);
      } catch (error) {
        const aside = storageFolder() + "/storage.unreadable-" + Date.now() + ".json";
        try { await rename(path, aside); } catch { /* the next write replaces it anyway */ }
        log("error", ["storage: storage.json couldn't be read (" + errorMessage(error) + "); it was set aside and the store starts empty"]);
      }
    }
    storageValues = values;
    return values;
  })();
  return storageLoading;
}

/** Queues writing the store as it is now; resolves when that is on disk. */
function saveStorage(values: Map<string, unknown>): Promise<void> {
  const text = JSON.stringify(Object.fromEntries(values));
  const write = storageWrites.then(async () => {
    const folder = storageFolder();
    await mkdir(folder, { recursive: true });
    const temporary = folder + "/storage.json.tmp";
    await Bun.write(temporary, text);
    await rename(temporary, folder + "/storage.json");
  });
  // A failed write must not block the ones after it.
  storageWrites = write.catch(() => {});
  return write;
}

function checkStorageKey(key: unknown): asserts key is string {
  if (typeof key !== "string" || key.length === 0 || key.length > STORAGE_MAX_KEY_LENGTH) {
    throw new TypeError("a storage key is a string of 1 to " + STORAGE_MAX_KEY_LENGTH + " characters");
  }
}

const storage = Object.freeze({
  /** The value saved under `key`, or `undefined`. A copy: changing it doesn't change the store. */
  async get(key: string): Promise<unknown> {
    checkStorageKey(key);
    const values = await loadStorage();
    return values.has(key) ? structuredClone(values.get(key)) : undefined;
  },

  /**
   * Saves a JSON value (object, array, string, number, boolean or null) under `key`, replacing
   * what was there. Resolves when it is on disk. Rejects when the value isn't JSON or the store
   * would grow beyond 5 MB; the store is then unchanged.
   */
  async set(key: string, value: unknown): Promise<void> {
    checkStorageKey(key);
    let json: string | undefined;
    try {
      json = JSON.stringify(value);
    } catch (error) {
      throw new TypeError("a storage value must be JSON: " + errorMessage(error));
    }
    if (json === undefined) throw new TypeError("a storage value must be JSON (to remove a key, use storage.delete)");
    const values = await loadStorage();
    const next = new Map(values);
    next.set(key, JSON.parse(json)); // a copy, as JSON sees it (no Dates, no undefined fields)
    if (Buffer.byteLength(JSON.stringify(Object.fromEntries(next))) > STORAGE_MAX_BYTES) {
      throw new RangeError("storage is full: a plugin's store holds at most 5 MB");
    }
    values.set(key, next.get(key));
    await saveStorage(values);
  },

  /** Removes `key`. Resolves to whether there was something to remove. */
  async delete(key: string): Promise<boolean> {
    checkStorageKey(key);
    const values = await loadStorage();
    if (!values.delete(key)) return false;
    await saveStorage(values);
    return true;
  },

  /** All keys, in the order they were first saved. */
  async keys(): Promise<string[]> {
    return [...(await loadStorage()).keys()];
  },

  /** Removes everything. */
  async clear(): Promise<void> {
    const values = await loadStorage();
    if (values.size === 0) return;
    values.clear();
    await saveStorage(values);
  },
});

// ---- The `singularity` API --------------------------------------------------------------------

type PageMessage = { tabID: string; frameHost: string; payload: unknown };
type PageMessageHandler = (message: PageMessage) => unknown | Promise<unknown>;
type CommandResult = { status: number; stdout: string; stderr: string; timedOut: boolean };

let pageMessageHandler: PageMessageHandler | null = null;
let nextCallID = 1;
const pendingCommands = new Map<number, (result: CommandResult) => void>();

const singularity = Object.freeze({
  /**
   * Handles messages from this plugin's page script. Whatever the handler returns (or resolves
   * to) is sent back as the answer; it must be JSON-serialisable. A thrown error is answered as
   * `{ error: "<message>" }`. Registering again replaces the previous handler.
   */
  onPageMessage(handler: PageMessageHandler): void {
    if (typeof handler !== "function") throw new TypeError("onPageMessage needs a function");
    pageMessageHandler = handler;
  },

  /**
   * Asks Singularity to run a program declared in plugin.json under permissions.commands,
   * e.g. run("op", ["item", "list"]). The arguments must start with one of the declared
   * sub-commands; anything else comes back with status 126 and "not allowed by the manifest".
   * There is no shell: arguments are passed to the program as they are.
   */
  run(command: string, args: string[]): Promise<CommandResult> {
    if (typeof command !== "string" || !Array.isArray(args) || !args.every((a) => typeof a === "string")) {
      return Promise.reject(new TypeError("run(command: string, args: string[])"));
    }
    const callID = nextCallID++;
    return new Promise((resolve) => {
      pendingCommands.set(callID, resolve);
      send({ kind: "runCommand", callID, command, arguments: args });
    });
  },

  /**
   * A small key → value store that survives restarts: `await singularity.storage.set("seen", [1, 2])`,
   * `await singularity.storage.get("seen")`. Kept in the plugin's data folder; see "Storage" above.
   */
  storage,

  /** Writes a line to the plugin's log (shown in Singularity's settings). Same as console.log. */
  log(...values: unknown[]): void {
    log("info", values);
  },
});

// Plugins import the API as a module named "singularity". Bun.plugin lets us define that module
// in memory; "object" means its exports are exactly the object we return.
Bun.plugin({
  name: "singularity",
  setup(build) {
    build.module("singularity", () => ({ exports: { singularity }, loader: "object" }));
  },
});

// ---- Loading the plugin -----------------------------------------------------------------------

const backgroundFile = process.argv[2];
// Messages wait for this, so a handler registered by the plugin's top-level code sees all of them.
// If the plugin fails to load, log why and exit with status 1 (Singularity may restart it).
const pluginLoaded: Promise<void> = import(pathToFileURL(backgroundFile).href).then(
  () => {},
  (error) => {
    log("error", ["could not load " + backgroundFile + ": " + describeError(error)]);
    process.exit(1);
  },
);

// ---- Handling messages from the app -----------------------------------------------------------

async function answerPageMessage(requestID: number, message: PageMessage): Promise<void> {
  await pluginLoaded;
  let payload: unknown;
  if (pageMessageHandler === null) {
    payload = { error: "no handler" };
  } else {
    try {
      payload = await pageMessageHandler(message);
    } catch (error) {
      payload = { error: errorMessage(error) };
    }
  }
  try {
    // `undefined` isn't JSON; answer null instead.
    send({ kind: "reply", requestID, payload: payload === undefined ? null : payload });
  } catch (error) {
    // e.g. a BigInt or a circular object in the answer
    send({ kind: "reply", requestID, payload: { error: "answer is not JSON: " + errorMessage(error) } });
  }
}

function handleLine(line: string): void {
  let message: any;
  try {
    message = JSON.parse(line);
  } catch {
    log("error", ["host: ignored a line that is not JSON"]);
    return;
  }
  if (message.kind === "pageMessage") {
    // Not awaited: several page messages can be in progress at once.
    void answerPageMessage(message.requestID, {
      tabID: message.tabID,
      frameHost: message.frameHost,
      payload: message.payload,
    });
  } else if (message.kind === "commandResult") {
    const resolve = pendingCommands.get(message.callID);
    pendingCommands.delete(message.callID);
    resolve?.(message.result);
  }
}

// Read stdin as lines until the app closes it, then exit (that is how Singularity stops a plugin).
const decoder = new TextDecoder();
let buffered = "";
for await (const chunk of Bun.stdin.stream()) {
  buffered += decoder.decode(chunk, { stream: true });
  let newline: number;
  while ((newline = buffered.indexOf("\n")) >= 0) {
    const line = buffered.slice(0, newline);
    buffered = buffered.slice(newline + 1);
    if (line.trim() !== "") handleLine(line);
  }
}
process.exit(0);
