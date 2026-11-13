// Tests for Plugins/assistant/background.ts with a fake provider and a fake `singularity`.
// Run from the repo root: Vendor/bun/bun test Tests/plugins/assistant
import { plugin } from "bun";
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConversationFile } from "../../../Plugins/assistant/conversation.ts";
import type { Provider, ProviderEvent } from "../../../Plugins/assistant/provider.ts";
import { createClaudeProvider } from "../../../Plugins/assistant/provider-claude.ts";
import { fakeQuery, fakeSpawn, type Script } from "./fake-claude.ts";
import { helloTurn, initializeResponse } from "./recording.ts";

// background.ts imports the API as the module "singularity", which only Singularity's plugin host
// defines. Define it here the same way, before background.ts is loaded. Its own wiring at the
// bottom of the file then registers with this stand-in and is never used: every test below makes
// its own assistant with createAssistant.
plugin({
  name: "singularity",
  setup(build) {
    build.module("singularity", () => ({
      exports: {
        singularity: {
          onPageMessage() {},
          spawn() {
            throw new Error("not in tests");
          },
          panel: { post() {} },
          storage: { get: async () => undefined, set: async () => {}, delete: async () => false },
          log() {},
        },
      },
      loader: "object",
    }));
  },
});
const { createAssistant } = await import("../../../Plugins/assistant/background.ts");

class FakeProvider implements Provider {
  starts: { resume?: string; model?: string; configFolder?: string }[] = [];
  sent: string[] = [];
  models: string[] = [];
  interrupts = 0;
  stops = 0;
  emit: (event: ProviderEvent) => void = () => {};
  start(options: { resume?: string; model?: string; configFolder?: string }, emit: (event: ProviderEvent) => void) {
    this.starts.push(options);
    this.emit = emit;
  }
  send(text: string) {
    this.sent.push(text);
  }
  interrupt() {
    this.interrupts++;
  }
  setModel(id: string) {
    this.models.push(id);
  }
  stop() {
    this.stops++;
  }
}

const folders: string[] = [];
afterEach(async () => {
  // Let a pending conversation write (10 ms here) happen first, or it would make the folder again.
  await new Promise((resolve) => setTimeout(resolve, 50));
  for (const dir of folders.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const MODELS = [
  { id: "default", name: "Default (recommended)" },
  { id: "haiku", name: "Haiku" },
];
const ready = (billing: "plan" | "api" = "plan"): ProviderEvent => ({
  type: "ready",
  model: "default",
  billing,
  models: MODELS,
  providerVersion: "2.1.323",
});

type MakeOptions = {
  /** Another provider than the FakeProvider (the real Claude provider with a fake program). */
  provider?: Provider;
  /** storage.get rejects the first time. */
  failFirstGet?: boolean;
  /** conversation.delete and storage.delete reject. */
  failDeletes?: boolean;
};

async function make(
  stored: Record<string, unknown> = {},
  messages?: { role: "user" | "assistant"; text: string }[],
  options: MakeOptions = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "assistant-background-"));
  folders.push(dir);
  const conversation = new ConversationFile(dir, { delayMs: 10 });
  if (messages) {
    conversation.update(messages);
    await conversation.flush();
  }
  const storage = new Map<string, unknown>(Object.entries(stored));
  const posts: any[] = [];
  const provider = new FakeProvider();
  const logs: string[] = [];
  let getFailures = options.failFirstGet ? 1 : 0;
  const file = new ConversationFile(dir, { delayMs: 10 });
  if (options.failDeletes) file.delete = async () => Promise.reject(new Error("disk says no"));
  const assistant = createAssistant({
    singularity: {
      panel: { post: (payload: unknown) => posts.push(payload) },
      storage: {
        get: async (key: string) => {
          if (getFailures > 0) {
            getFailures--;
            throw new Error("storage is unreadable");
          }
          return storage.get(key);
        },
        set: async (key: string, value: unknown) => void storage.set(key, value),
        delete: async (key: string) => {
          if (options.failDeletes) throw new Error("disk says no");
          return storage.delete(key);
        },
      },
      log: (...values: unknown[]) => void logs.push(values.join(" ")),
    },
    provider: options.provider ?? provider,
    conversation: file,
    sdkVersion: "0.3.323",
  });
  const send = (payload: unknown) => assistant.handle(payload) as Promise<any>;
  const lastState = () => posts.filter((p) => p.type === "state").at(-1);
  return { dir, storage, posts, provider, send, lastState, logs };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 30));

test("the provider starts on the first hello, not before", async () => {
  const { provider, send } = await make();
  await settle();
  expect(provider.starts).toEqual([]);
  const state = await send({ type: "hello" });
  expect(provider.starts).toEqual([{ resume: undefined, model: undefined, configFolder: undefined }]);
  expect(state).toMatchObject({
    messages: [],
    status: "starting",
    model: null,
    models: [],
    billing: null,
    billingNoticeSeen: true,
    configFolder: "",
    providerVersion: "",
    sdkVersion: "0.3.323",
  });
  await send({ type: "hello" });
  expect(provider.starts.length).toBe(1);
});

test("stored session, model and config folder are used at start", async () => {
  const { provider, send } = await make({ session: "s1", model: "haiku", configFolder: "/Users/a/.claude-b" });
  const state = await send({ type: "hello" });
  expect(provider.starts).toEqual([{ resume: "s1", model: "haiku", configFolder: "/Users/a/.claude-b" }]);
  expect(state.model).toBe("haiku");
  expect(state.configFolder).toBe("/Users/a/.claude-b");
});

test("deltas are forwarded, and the state after done has the answer", async () => {
  const { dir, provider, send, posts, lastState, storage } = await make();
  await send({ type: "hello" });
  provider.emit(ready());
  expect(lastState()).toMatchObject({ status: "ready", model: "default", billing: "plan", providerVersion: "2.1.323" });
  expect(lastState().models).toEqual(MODELS);

  const answering = await send({ type: "send", text: "Hi" });
  expect(provider.sent).toEqual(["Hi"]);
  expect(answering.status).toBe("answering");
  expect(answering.messages).toEqual([{ role: "user", text: "Hi" }]);

  provider.emit({ type: "session", id: "s1" });
  provider.emit({ type: "text", delta: "Hel" });
  provider.emit({ type: "text", delta: "lo" });
  const deltas = posts.filter((p) => p.type === "delta");
  expect(deltas.map((d) => d.text)).toEqual(["Hel", "lo"]);
  // Each change counts up, so the page can tell when it missed one.
  expect(deltas[1].version).toBe(deltas[0].version + 1);

  provider.emit({ type: "done" });
  expect(lastState().status).toBe("ready");
  expect(lastState().messages).toEqual([
    { role: "user", text: "Hi" },
    { role: "assistant", text: "Hello" },
  ]);
  expect(lastState().version).toBeGreaterThan(deltas[1].version);
  expect(storage.get("session")).toBe("s1");
  await settle();
  expect(await new ConversationFile(dir).load()).toEqual(lastState().messages);
});

test("send is refused while not ready, and stop interrupts", async () => {
  const { provider, send } = await make();
  await send({ type: "hello" });
  expect((await send({ type: "send", text: "Hi" })).error).toBeString();
  expect(provider.sent).toEqual([]);
  provider.emit(ready());
  expect((await send({ type: "send", text: "   " })).error).toBeString();
  await send({ type: "send", text: "Hi" });
  await send({ type: "stop" });
  expect(provider.interrupts).toBe(1);
});

test("API billing the first time holds send until billingSeen", async () => {
  const { provider, send, lastState, storage } = await make();
  await send({ type: "hello" });
  provider.emit(ready("api"));
  expect(lastState()).toMatchObject({ billing: "api", billingNoticeSeen: false });
  const held = await send({ type: "send", text: "Hi" });
  expect(provider.sent).toEqual([]);
  expect(held.messages).toEqual([{ role: "user", text: "Hi" }]);
  const seen = await send({ type: "billingSeen" });
  expect(provider.sent).toEqual(["Hi"]);
  expect(seen).toMatchObject({ billingNoticeSeen: true, status: "answering" });
  expect(storage.get("billingNoticeSeen")).toBe(true);
  expect(storage.get("billing")).toBe("api");
});

test("a change of billing shows the notice again; plan the first time does not", async () => {
  const first = await make();
  await first.send({ type: "hello" });
  first.provider.emit(ready("plan"));
  expect(first.lastState()).toMatchObject({ billing: "plan", billingNoticeSeen: true });

  const changed = await make({ billing: "api", billingNoticeSeen: true });
  await changed.send({ type: "hello" });
  changed.provider.emit(ready("plan"));
  expect(changed.lastState()).toMatchObject({ billing: "plan", billingNoticeSeen: false });
  expect(changed.storage.get("billing")).toBe("plan");
  await changed.send({ type: "send", text: "Hi" });
  expect(changed.provider.sent).toEqual([]);

  // Seen before, same billing: nothing to show.
  const same = await make({ billing: "api", billingNoticeSeen: true });
  await same.send({ type: "hello" });
  same.provider.emit(ready("api"));
  expect(same.lastState().billingNoticeSeen).toBe(true);
});

test("newChat clears the file and the session and starts afresh", async () => {
  const { dir, provider, send, storage } = await make({ session: "s1" }, [{ role: "user", text: "old" }]);
  const hello = await send({ type: "hello" });
  expect(hello.messages).toEqual([{ role: "user", text: "old" }]);
  provider.emit(ready());
  const state = await send({ type: "newChat" });
  expect(state.messages).toEqual([]);
  expect(state.status).toBe("starting");
  expect(existsSync(join(dir, "conversation.json"))).toBe(false);
  expect(storage.has("session")).toBe(false);
  expect(provider.stops).toBe(1);
  expect(provider.starts.at(-1)).toEqual({ resume: undefined, model: undefined, configFolder: undefined });
});

test("model and config folder are stored", async () => {
  const { provider, send, storage } = await make({ session: "s1" });
  await send({ type: "hello" });
  provider.emit(ready());
  const state = await send({ type: "setModel", id: "haiku" });
  expect(state.model).toBe("haiku");
  expect(storage.get("model")).toBe("haiku");
  expect(provider.models).toEqual(["haiku"]);
  expect((await send({ type: "setModel", id: "made-up" })).error).toBeString();
  expect(provider.models).toEqual(["haiku"]);

  const moved = await send({ type: "setConfigFolder", path: " /Users/a/.claude-b " });
  expect(moved.configFolder).toBe("/Users/a/.claude-b");
  expect(storage.get("configFolder")).toBe("/Users/a/.claude-b");
  expect(provider.stops).toBe(1);
  expect(provider.starts.at(-1)).toEqual({ resume: "s1", model: "haiku", configFolder: "/Users/a/.claude-b" });
  expect((await send({ type: "setConfigFolder", path: "~/.claude" })).error).toBeString();
  await send({ type: "setConfigFolder", path: "" });
  expect(storage.get("configFolder")).toBe("");
  expect(provider.starts.at(-1)?.configFolder).toBeUndefined();
});

test("a failed resume marks the old messages stale and keeps the new session", async () => {
  const old = [
    { role: "user" as const, text: "old question" },
    { role: "assistant" as const, text: "old answer" },
  ];
  const { dir, provider, send, storage, lastState } = await make({ session: "gone" }, old);
  await send({ type: "hello" });
  expect(provider.starts[0].resume).toBe("gone");
  provider.emit({ type: "error", kind: "other", message: "That conversation couldn't be continued.", resumeFailed: true });
  expect(lastState().messages).toEqual(old.map((m) => ({ ...m, stale: true })));
  expect(lastState().status).toBe("starting");
  expect(storage.has("session")).toBe(false);
  provider.emit(ready());
  expect(lastState().status).toBe("ready");
  await send({ type: "send", text: "new question" });
  provider.emit({ type: "session", id: "fresh" });
  provider.emit({ type: "text", delta: "new answer" });
  provider.emit({ type: "done" });
  expect(storage.get("session")).toBe("fresh");
  expect(lastState().messages).toEqual([
    ...old.map((m) => ({ ...m, stale: true })),
    { role: "user", text: "new question" },
    { role: "assistant", text: "new answer" },
  ]);
  await settle();
  expect((await new ConversationFile(dir).load())[0].stale).toBe(true);
});

test("errors become states; retry starts again", async () => {
  const { provider, send, lastState } = await make({ session: "s1" });
  await send({ type: "hello" });
  provider.emit(ready());
  for (const kind of ["signedOut", "limit", "programEnded", "programsOff"] as const) {
    provider.emit({ type: "error", kind, message: "x" });
    expect(lastState().status).toBe(kind);
  }
  provider.emit({ type: "error", kind: "other", message: "Something odd" });
  expect(lastState()).toMatchObject({ status: "error", error: "Something odd" });
  const retried = await send({ type: "retry" });
  expect(retried.status).toBe("starting");
  expect(retried.error).toBeNull();
  expect(provider.stops).toBe(1);
  expect(provider.starts.at(-1)).toEqual({ resume: "s1", model: undefined, configFolder: undefined });
});

test("unknown or malformed messages are refused", async () => {
  const { send } = await make();
  expect((await send({ type: "nonsense" })).error).toBeString();
  expect((await send(null)).error).toBeString();
  expect((await send({ type: "send", text: 5 })).error).toBeString();
});

test("any other error before ready keeps the session and the messages, and Try Again works", async () => {
  const old = [{ role: "user" as const, text: "old question" }];
  const { provider, send, storage, lastState } = await make({ session: "s1" }, old);
  await send({ type: "hello" });
  // For example the SDK failing to load, or the app refusing the start.
  provider.emit({ type: "error", kind: "other", message: "a program is already running" });
  expect(lastState()).toMatchObject({ status: "error", error: "a program is already running", messages: old });
  expect(storage.get("session")).toBe("s1");
  const retried = await send({ type: "retry" });
  expect(retried.status).toBe("starting");
  expect(provider.starts.at(-1)?.resume).toBe("s1");
});

test("Try Again is taken whenever no answer is on its way, also while starting", async () => {
  const { provider, send } = await make();
  await send({ type: "hello" });
  await send({ type: "retry" });
  expect(provider.starts.length).toBe(2);
  provider.emit(ready());
  await send({ type: "retry" });
  expect(provider.starts.length).toBe(2);
});

test("a message held for the billing notice is taken out again when an error comes first", async () => {
  const { dir, provider, send, lastState } = await make({}, [{ role: "user", text: "earlier" }]);
  await send({ type: "hello" });
  provider.emit(ready("api"));
  const held = await send({ type: "send", text: "Hi" });
  expect(held.messages.at(-1)).toEqual({ role: "user", text: "Hi" });
  provider.emit({ type: "error", kind: "programEnded", message: "x" });
  expect(lastState().messages).toEqual([{ role: "user", text: "earlier" }]);
  await new Promise((resolve) => setTimeout(resolve, 40));
  expect(await new ConversationFile(dir).load()).toEqual([{ role: "user", text: "earlier" }]);
  // And OK later sends nothing.
  await send({ type: "billingSeen" });
  expect(provider.sent).toEqual([]);
});

test("a failed first read of storage is tried again on the next request", async () => {
  const { send, provider } = await make({ session: "s1" }, undefined, { failFirstGet: true });
  await expect(send({ type: "hello" })).rejects.toThrow("storage is unreadable");
  const state = await send({ type: "hello" });
  expect(state.status).toBe("starting");
  expect(provider.starts).toEqual([{ resume: "s1", model: undefined, configFolder: undefined }]);
});

test("New Chat starts the provider again even when removing the old conversation fails", async () => {
  const { send, provider, logs } = await make({ session: "s1" }, undefined, { failDeletes: true });
  await send({ type: "hello" });
  provider.emit(ready());
  const state = await send({ type: "newChat" });
  expect(state.status).toBe("starting");
  expect(provider.stops).toBe(1);
  expect(provider.starts.length).toBe(2);
  expect(provider.starts.at(-1)?.resume).toBeUndefined();
  expect(logs.some((line) => line.includes("disk says no"))).toBe(true);
});

// ---- With the real Claude provider and a fake program (one program at a time, as in the app) --

/** A program that answers initialize and plays the hello turn for every message. */
const chatting: Script = (program, line) => {
  if (line.type === "control_request") {
    if (line.request?.subtype === "initialize") program.answer(line, initializeResponse);
    else program.answer(line);
  } else if (line.type === "user") {
    program.say(...helloTurn("sess-1"));
  }
};

async function withClaude(stored: Record<string, unknown> = {}) {
  const fake = fakeSpawn([chatting]);
  const made = await make(stored, [{ role: "user", text: "kept" }], {
    provider: createClaudeProvider({ spawn: fake.spawn, loadQuery: async () => fakeQuery }),
  });
  /** Waits for a state with `status` pushed after the first `since` posts. */
  const waitForStatus = async (status: string, since = 0) => {
    for (let i = 0; i < 400; i++) {
      if (made.posts.slice(since).some((p) => p.type === "state" && p.status === status)) return;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error(`timed out waiting for ${status}; last state: ${JSON.stringify(made.lastState())}`);
  };
  /** Sends a message, then waits for a pushed state with `status`. */
  const act = async (payload: object, status: string) => {
    const since = made.posts.length;
    await made.send(payload);
    await waitForStatus(status, since);
  };
  return { ...made, fake, waitForStatus, act };
}

test("restarts wait for the old program: New Chat, Try Again and Save config folder", async () => {
  const { act, fake, lastState, storage } = await withClaude({ session: "s1" });
  await act({ type: "hello" }, "ready");

  // Save config folder: stop, then start again resuming the session.
  await act({ type: "setConfigFolder", path: "/Users/someone/.claude-b" }, "ready");
  expect(fake.programs.length).toBe(2);
  expect(fake.programs[0].ended).toBe(true);
  expect(fake.programs[1].env.CLAUDE_CONFIG_DIR).toBe("/Users/someone/.claude-b");
  expect(fake.programs[1].args).toContain("--resume=s1");

  // Try Again after the program ended.
  fake.programs[1].exit(1);
  for (let i = 0; i < 400 && lastState().status !== "programEnded"; i++) await new Promise((r) => setTimeout(r, 5));
  expect(lastState().status).toBe("programEnded");
  await act({ type: "retry" }, "ready");
  expect(fake.programs.length).toBe(3);

  // New Chat while the program runs.
  await act({ type: "newChat" }, "ready");
  expect(fake.programs.length).toBe(4);
  expect(fake.programs[3].args.some((arg) => arg.startsWith("--resume"))).toBe(false);

  // Never refused, never mistaken for a failed resume.
  expect(fake.refused).toEqual([]);
  expect(lastState().messages).toEqual([]);
  expect(storage.has("session")).toBe(false);

  await act({ type: "send", text: "Hi" }, "ready");
  expect(lastState().messages).toEqual([
    { role: "user", text: "Hi" },
    { role: "assistant", text: "Hello there." },
  ]);
  expect(storage.get("session")).toBe("sess-1");
});

test("Save config folder with a stored session keeps the conversation", async () => {
  const { act, fake, lastState, storage } = await withClaude({ session: "s1" });
  await act({ type: "hello" }, "ready");
  await act({ type: "setConfigFolder", path: "" }, "ready");
  expect(fake.refused).toEqual([]);
  expect(fake.programs.length).toBe(2);
  expect(lastState().messages).toEqual([{ role: "user", text: "kept" }]);
  expect(storage.get("session")).toBe("s1");
});
