// Tests for Plugins/assistant/background.ts with a fake provider and a fake `singularity`.
// Run from the repo root: Vendor/bun/bun test Tests/plugins/assistant
import { plugin } from "bun";
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConversationFile } from "../../../Plugins/assistant/conversation.ts";
import type { FrontTab } from "../../../Plugins/assistant/front.ts";
import type { Provider, ProviderEvent } from "../../../Plugins/assistant/provider.ts";
import { frontBlock } from "../../../Plugins/assistant/front.ts";
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
  starts: { resume?: string; model?: string; configFolder?: string; browser?: unknown }[] = [];
  sent: string[] = [];
  models: string[] = [];
  interrupts = 0;
  stops = 0;
  emit: (event: ProviderEvent) => void = () => {};
  start(options: { resume?: string; model?: string; configFolder?: string; browser?: unknown }, emit: (event: ProviderEvent) => void) {
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
  /** The conversation file's write delay (10 ms unless given). */
  conversationDelayMs?: number;
  /** How long after Stop the background waits for the end of the turn (default: its own 5 s). */
  stopWaitMs?: number;
  /** The tab in front (what singularity.front() answers); leave out for a copy without that API. */
  front?: { current: FrontTab | null | "fail" };
  /** What singularity.browser.server() answers ("fail": it rejects). */
  browser?: { command: string; args: string[]; env: Record<string, string> } | null | "fail" | (() => Promise<{ command: string; args: string[]; env: Record<string, string> }>);
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
  const file = new ConversationFile(dir, { delayMs: options.conversationDelayMs ?? 10 });
  if (options.failDeletes) file.delete = async () => Promise.reject(new Error("disk says no"));
  const frontHandlers: ((front: FrontTab | null) => void)[] = [];
  const frontAPI = options.front
    ? {
        front: async () => {
          if (options.front!.current === "fail") throw new Error("no front");
          return options.front!.current as FrontTab | null;
        },
        onFrontChange: (handler: (front: FrontTab | null) => void) => void frontHandlers.push(handler),
      }
    : {};
  const browserAPI = options.browser !== undefined
    ? {
        browser: {
          server: async () => {
            if (options.browser === "fail") throw new Error("no server");
            if (typeof options.browser === "function") return options.browser();
            return options.browser as { command: string; args: string[]; env: Record<string, string> } | null;
          },
        },
      }
    : {};
  const assistant = createAssistant({
    singularity: {
      ...frontAPI,
      ...browserAPI,
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
    stopWaitMs: options.stopWaitMs,
  });
  const send = (payload: unknown) => assistant.handle(payload) as Promise<any>;
  const lastState = () => posts.filter((p) => p.type === "state").at(-1);
  const changeFront = (front: FrontTab | null) => frontHandlers.forEach((h) => h(front));
  return { dir, storage, posts, provider, send, lastState, logs, changeFront, file };
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

test("New Chat refuses a message sent while it is still starting the new conversation", async () => {
  const { provider, send } = await make({ session: "s1" });
  await send({ type: "hello" });
  provider.emit(ready());
  // Return pressed right after New Chat: both arrive before New Chat has finished.
  const newChat = send({ type: "newChat" });
  const early = await send({ type: "send", text: "Hi" });
  expect(early.error).toBe("The Assistant isn't ready for a message.");
  expect(provider.sent).toEqual([]);
  const state = await newChat;
  expect(state.status).toBe("starting");
  expect(state.messages).toEqual([]);
});

test("a message the user sends is saved at once, not only after the write delay", async () => {
  const { dir, provider, send } = await make({}, undefined, { conversationDelayMs: 60_000 });
  await send({ type: "hello" });
  provider.emit(ready());
  await send({ type: "send", text: "Keep me" });
  await settle();
  expect(await new ConversationFile(dir).load()).toEqual([{ role: "user", text: "Keep me" }]);
});

test("a second message while the billing note waits is refused with its own words", async () => {
  const { provider, send } = await make();
  await send({ type: "hello" });
  provider.emit(ready("api"));
  await send({ type: "send", text: "Hi" });
  expect((await send({ type: "send", text: "And this" })).error).toBe("Press OK on the note above first.");
  expect(provider.sent).toEqual([]);
});

test("Stop with no end of the answer: the provider starts again, keeping the conversation", async () => {
  const { provider, send, lastState, storage } = await make({ session: "s1" }, [{ role: "user", text: "earlier" }],
    { stopWaitMs: 40 });
  await send({ type: "hello" });
  provider.emit(ready());
  await send({ type: "send", text: "Hi" });
  provider.emit({ type: "text", delta: "Half an ans" });
  await send({ type: "stop" });
  expect(provider.interrupts).toBe(1);
  expect(provider.starts.length).toBe(1);
  await new Promise((resolve) => setTimeout(resolve, 100));
  expect(provider.stops).toBe(1);
  expect(provider.starts.length).toBe(2);
  expect(provider.starts.at(-1)?.resume).toBe("s1");
  expect(lastState().status).toBe("starting");
  expect(lastState().messages).toEqual([
    { role: "user", text: "earlier" },
    { role: "user", text: "Hi" },
    { role: "assistant", text: "Half an ans" },
  ]);
  expect(storage.get("session")).toBe("s1");
  provider.emit(ready());
  expect(lastState().status).toBe("ready");
});

test("Stop followed by the end of the answer restarts nothing", async () => {
  const { provider, send, lastState } = await make({}, undefined, { stopWaitMs: 40 });
  await send({ type: "hello" });
  provider.emit(ready());
  await send({ type: "send", text: "Hi" });
  await send({ type: "stop" });
  provider.emit({ type: "done" });
  // The next message is already on its way when the old timer would have fired.
  const next = await send({ type: "send", text: "Next" });
  expect(next.status).toBe("answering");
  await new Promise((resolve) => setTimeout(resolve, 100));
  expect(provider.starts.length).toBe(1);
  expect(provider.stops).toBe(0);
  expect(provider.sent).toEqual(["Hi", "Next"]);
  expect(lastState().status).toBe("ready");
});

test("a failed resume at the first message: the answer that was asked for is not awaited", async () => {
  const { provider, send, lastState } = await make({ session: "gone" }, [{ role: "user", text: "old" }]);
  await send({ type: "hello" });
  provider.emit(ready());
  await send({ type: "send", text: "Hi" });
  provider.emit({ type: "error", kind: "other", message: "x", resumeFailed: true });
  expect(lastState().status).toBe("starting");
  expect(lastState().messages.every((m: { stale?: boolean }) => m.stale)).toBe(true);
  provider.emit(ready());
  expect(lastState().status).toBe("ready");
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

test("a restart drops a message held for the billing notice", async () => {
  const { dir, provider, send, lastState } = await make({ session: "s1" }, [{ role: "user", text: "earlier" }]);
  await send({ type: "hello" });
  provider.emit(ready("api"));
  await send({ type: "send", text: "Hi" });
  const restarted = await send({ type: "setConfigFolder", path: "/Users/a/.claude-b" });
  expect(restarted.messages).toEqual([{ role: "user", text: "earlier" }]);
  // A failed resume after the restart greys out only what was really sent before.
  provider.emit({ type: "error", kind: "other", message: "gone", resumeFailed: true });
  provider.emit(ready("api"));
  expect(lastState().messages).toEqual([{ role: "user", text: "earlier", stale: true }]);
  // OK sends nothing: the held message is gone.
  await send({ type: "billingSeen" });
  expect(provider.sent).toEqual([]);
  await new Promise((resolve) => setTimeout(resolve, 40));
  expect(await new ConversationFile(dir).load()).toEqual([{ role: "user", text: "earlier", stale: true }]);
  // Try Again is a restart too.
  const second = await make();
  await second.send({ type: "hello" });
  second.provider.emit(ready("api"));
  await second.send({ type: "send", text: "Hi" });
  second.provider.emit({ type: "error", kind: "programEnded", message: "x" });
  await second.send({ type: "retry" });
  await second.send({ type: "billingSeen" });
  expect(second.provider.sent).toEqual([]);
});

// ---- The tab in front and the browser's tools -------------------------------------------------

const FRONT: FrontTab = {
  space: { slug: "work", name: "Work" },
  tab: { id: "T1", kind: "web", title: "Invoice 42", url: "https://example.com/invoices/42" },
};
const SERVER = { command: "/App/singularity-mcp", args: [], env: { SINGULARITY_MCP_SOCKET: "/x" } };

async function readyAssistant(options: MakeOptions = {}) {
  const made = await make({}, undefined, options);
  await made.send({ type: "hello" });
  made.provider.emit(ready());
  return made;
}

test("the text sent to the provider starts with the block; the chat and the saved file keep only the user's text", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { provider, send, file, dir } = await readyAssistant({ front });
  const state = await send({ type: "send", text: "What is this?" });
  expect(provider.sent.length).toBe(1);
  expect(provider.sent[0].startsWith(frontBlock(FRONT))).toBe(true);
  expect(provider.sent[0].endsWith("What is this?")).toBe(true);
  expect(state.messages).toEqual([{ role: "user", text: "What is this?" }]);
  await file.flush();
  const saved = await Bun.file(dir + "/conversation.json").text();
  expect(saved).toContain("What is this?");
  expect(saved).not.toContain("untrusted-content");
  expect(saved).not.toContain("Invoice 42");
});

test("each send asks for the tab in front again; nothing in front says so", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { provider, send } = await readyAssistant({ front });
  await send({ type: "send", text: "one" });
  provider.emit({ type: "done" });
  front.current = null;
  await send({ type: "send", text: "two" });
  expect(provider.sent[1]).toBe("Nothing in front is visible to you.\n\ntwo");
  provider.emit({ type: "done" });
  front.current = "fail";
  await send({ type: "send", text: "three" });
  expect(provider.sent[2]).toBe("Nothing in front is visible to you.\n\nthree");
});

test("a copy without the front API sends the text as it is", async () => {
  const { provider, send } = await readyAssistant();
  await send({ type: "send", text: "plain" });
  expect(provider.sent).toEqual(["plain"]);
});

test("the chip: in the hello answer, and pushed when the tab in front changes", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { send, posts, changeFront } = await make({}, undefined, { front });
  const state = await send({ type: "hello" });
  expect(state.chip).toBe("Invoice 42");
  changeFront(null);
  expect(posts.at(-1)).toEqual({ type: "front", chip: "Nothing shared from here" });
  front.current = { ...FRONT, tab: { ...FRONT.tab, title: "Other" } };
  changeFront(front.current);
  expect(posts.at(-1)).toEqual({ type: "front", chip: "Other" });
  expect((await send({ type: "hello" })).chip).toBe("Other");
});

test("the browser server is handed to the provider at every start; failing or none starts without tools", async () => {
  const a = await make({}, undefined, { browser: SERVER });
  await a.send({ type: "hello" });
  await settle();
  expect(a.provider.starts).toEqual([{ resume: undefined, model: undefined, configFolder: undefined, browser: SERVER }]);
  await a.send({ type: "newChat" });
  await settle();
  expect(a.provider.starts.length).toBe(2);
  expect(a.provider.starts[1].browser).toEqual(SERVER);

  const b = await make({}, undefined, { browser: null });
  await b.send({ type: "hello" });
  await settle();
  expect(b.provider.starts[0].browser).toBeNull();

  const c = await make({}, undefined, { browser: "fail" });
  const state = await c.send({ type: "hello" });
  expect(state.status).toBe("starting");
  await settle();
  expect(c.provider.starts[0].browser).toBeNull();
  expect(c.logs.some((line) => line.includes("browser"))).toBe(true);
});

test("tool events become lines in order with the text; results never appear; the file keeps the lines", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { provider, send, lastState, file, dir } = await readyAssistant({ front });
  await send({ type: "send", text: "Summarise" });
  provider.emit({ type: "text", delta: "Let me read it." });
  provider.emit({ type: "tool", id: "a", name: "work.read_page", input: { tab_id: "T1" }, status: "running" });
  expect(lastState().messages.at(-1)).toEqual({
    role: "assistant",
    text: "Let me read it.",
    tools: [{ text: "Read Invoice 42", status: "running" }],
  });
  provider.emit({ type: "tool", id: "a", name: "work.read_page", input: { tab_id: "T1" }, status: "done" });
  provider.emit({ type: "tool", id: "b", name: "work.click", input: { tab_id: "T1", ref: 2 }, status: "running" });
  provider.emit({ type: "tool", id: "b", name: "work.click", input: { tab_id: "T1", ref: 2 }, status: "failed" });
  provider.emit({ type: "text", delta: "Done." });
  provider.emit({ type: "done" });
  const messages = lastState().messages;
  expect(messages).toEqual([
    { role: "user", text: "Summarise" },
    {
      role: "assistant",
      text: "Let me read it.",
      tools: [
        { text: "Read Invoice 42", status: "done" },
        { text: "Clicked on Invoice 42 — not done", status: "failed" },
      ],
    },
    { role: "assistant", text: "Done." },
  ]);
  await file.flush();
  const saved = JSON.parse(await Bun.file(dir + "/conversation.json").text());
  expect(saved.messages[1].tools).toEqual(messages[1].tools);
});

test("a turn that ends with a tool still running leaves it as not done", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { provider, send, lastState } = await readyAssistant({ front });
  await send({ type: "send", text: "Go" });
  provider.emit({ type: "tool", id: "a", name: "work.read_page", input: { tab_id: "T1" }, status: "running" });
  provider.emit({ type: "done" });
  expect(lastState().messages.at(-1).tools).toEqual([{ text: "Read Invoice 42 — not done", status: "failed" }]);
});

test("the tool lines use the tab that was in front at send, not the one in front now", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { provider, send, lastState } = await readyAssistant({ front });
  await send({ type: "send", text: "Go" });
  front.current = { ...FRONT, tab: { ...FRONT.tab, id: "T2", title: "Else" } };
  provider.emit({ type: "tool", id: "a", name: "work.read_page", input: { tab_id: "T1" }, status: "running" });
  expect(lastState().messages.at(-1).tools[0].text).toBe("Read Invoice 42");
});

test("the real provider with a fake program: the sent text carries the block, a result's text goes nowhere", async () => {
  const sent: any[] = [];
  const script: Script = (program, line) => {
    if (line.type === "control_request") program.answer(line, initializeResponse);
    else if (line.type === "user") {
      sent.push(line.message);
      program.say(
        { type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id: "t1", name: "mcp__singularity__work_read_page", input: { tab_id: "T1" } }] }, parent_tool_use_id: null, session_id: "s" },
        { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "SECRET PAGE TEXT" }] }, parent_tool_use_id: null, session_id: "s" },
        ...helloTurn("s").slice(1),
      );
    }
  };
  const { spawn } = fakeSpawn([script]);
  const provider = createClaudeProvider({ spawn, loadQuery: async () => fakeQuery });
  const front = { current: FRONT as FrontTab | null };
  const { send, lastState, file, dir } = await make({}, undefined, { provider, front, browser: SERVER });
  await send({ type: "hello" });
  for (let i = 0; i < 400 && lastState()?.status !== "ready"; i++) await new Promise((r) => setTimeout(r, 5));
  await send({ type: "send", text: "Read it" });
  for (let i = 0; i < 400 && !(sent.length > 0 && lastState()?.status === "ready" && lastState().messages.at(-1)?.text === "Hello there."); i++) await new Promise((r) => setTimeout(r, 5));
  expect(sent[0].content.startsWith("Where the user is")).toBe(true);
  expect(sent[0].content).toContain("Invoice 42");
  const messages = lastState().messages;
  expect(JSON.stringify(messages)).not.toContain("SECRET");
  expect(messages[1].tools).toEqual([{ text: "Read Invoice 42", status: "done" }]);
  expect(messages.at(-1)).toEqual({ role: "assistant", text: "Hello there." });
  await file.flush();
  expect(await Bun.file(dir + "/conversation.json").text()).not.toContain("SECRET");
  provider.stop();
});

test("a Stop that brings no end restarts the provider: a running tool line says not done", async () => {
  const front = { current: FRONT as FrontTab | null };
  const { provider, send, lastState, file, dir } = await readyAssistant({ front, stopWaitMs: 20 });
  await send({ type: "send", text: "Go" });
  provider.emit({ type: "tool", id: "a", name: "work.click", input: { tab_id: "T1" }, status: "running" });
  await send({ type: "stop" });
  await new Promise((r) => setTimeout(r, 80));
  expect(provider.stops).toBe(1);
  expect(lastState().messages.at(-1).tools).toEqual([{ text: "Clicked on Invoice 42 — not done", status: "failed" }]);
  await file.flush();
  expect(await Bun.file(dir + "/conversation.json").text()).toContain("Clicked on Invoice 42 — not done");
});

test("the browser's server can't be asked: a line, the chat starts without tools, Try Again asks again", async () => {
  const made = await make({}, undefined, { browser: "fail" });
  const state = await made.send({ type: "hello" });
  expect(state.browserProblem).toBe(false);
  await settle();
  expect(made.provider.starts.length).toBe(1);
  expect(made.provider.starts[0].browser).toBeNull();
  made.provider.emit(ready());
  expect(made.lastState().browserProblem).toBe(true);
  expect(made.lastState().status).toBe("ready");
  // The chat works.
  await made.send({ type: "send", text: "hi" });
  expect(made.provider.sent).toEqual(["hi"]);
  made.provider.emit({ type: "done" });
  // Try Again restarts the provider, which asks for the server again.
  await made.send({ type: "retry" });
  await settle();
  expect(made.provider.stops).toBe(1);
  expect(made.provider.starts.length).toBe(2);
});

test("no browser server (null, or no door at all): no line", async () => {
  for (const options of [{ browser: null }, {}] as MakeOptions[]) {
    const made = await make({}, undefined, options);
    await made.send({ type: "hello" });
    await settle();
    made.provider.emit(ready());
    expect(made.lastState().browserProblem).toBe(false);
    // Try Again does nothing when everything is fine.
    await made.send({ type: "retry" });
    expect(made.provider.stops).toBe(0);
  }
});

test("a server that doesn't connect: a line; one that does clears it", async () => {
  const made = await make({}, undefined, { browser: SERVER });
  await made.send({ type: "hello" });
  await settle();
  made.provider.emit(ready());
  made.provider.emit({ type: "browser", connected: false });
  expect(made.lastState().browserProblem).toBe(true);
  made.provider.emit({ type: "browser", connected: true });
  expect(made.lastState().browserProblem).toBe(false);
  made.provider.emit({ type: "browser", connected: false });
  const after = await made.send({ type: "retry" });
  await settle();
  expect(made.provider.starts.length).toBe(2);
  expect(after.browserProblem).toBe(false);
});

test("New Chat while the browser's server is still being asked for starts the provider once, with the new start", async () => {
  const waiting: ((server: typeof SERVER) => void)[] = [];
  const made = await make({}, undefined, { browser: () => new Promise((resolve) => waiting.push(resolve)) });
  await made.send({ type: "hello" });
  expect(waiting.length).toBe(1);
  const newChat = made.send({ type: "newChat" });
  await settle();
  expect(waiting.length).toBe(2);
  // The old answer arrives first: it must not start anything.
  waiting[0]({ ...SERVER, command: "/old" });
  await settle();
  expect(made.provider.starts.length).toBe(0);
  waiting[1]({ ...SERVER, command: "/new" });
  await newChat;
  await settle();
  expect(made.provider.starts.map((o) => (o.browser as any).command)).toEqual(["/new"]);
});
