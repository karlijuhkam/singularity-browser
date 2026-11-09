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
// Because stdout carries these messages, console.log and friends are redirected to the plugin's
// log (see below) so a stray print can't break a message. The Swift side of this protocol is
// Sources/SingularityCore/Plugins/PluginWire.swift and PluginProcess.swift.

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
