// Tests for Plugins/assistant/provider-claude.ts. Run from the repo root: Vendor/bun/bun test Tests/plugins/assistant
//
// The provider is given a fake `singularity.spawn` whose program replays a recorded stream-json
// exchange (recording.ts), and, by default, a small fake of the SDK's query() (fake-claude.ts), so
// these tests need no installed packages and never run the real claude program.
//
// To run the same tests against the real SDK (still with the fake program), install the plugin's
// packages in a scratch copy and point ASSISTANT_SDK at the SDK's sdk.mjs:
//   ASSISTANT_SDK=/path/to/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs Vendor/bun/bun test Tests/plugins/assistant
import { expect, test } from "bun:test";
import type { ProviderEvent } from "../../../Plugins/assistant/provider.ts";
import {
  billingFrom,
  billingFromAccount,
  createClaudeProvider,
  programEnvironment,
} from "../../../Plugins/assistant/provider-claude.ts";
import { type FakeProgram, fakeQuery, fakeSpawn, type Script, seenOptions } from "./fake-claude.ts";
import {
  helloTurn,
  initializeResponse,
  initializeResponseAPI,
  initMessage,
  limitTurn,
  limitTurnPlainText,
  limitWithExtraUsageTurn,
  noConversationTurn,
  result,
  resultOnlyTurn,
  signedOutTurn,
} from "./recording.ts";

const realSDK = process.env.ASSISTANT_SDK;
const loadQuery = async () => (realSDK ? (await import(realSDK)).query : fakeQuery);

/** A program that answers `initialize`, then plays one recorded turn per user message. */
function chat(turns: object[][], init: object = initializeResponse): Script {
  let next = 0;
  return (program, line) => {
    if (line.type === "control_request") {
      const subtype = line.request?.subtype;
      if (subtype === "initialize") program.answer(line, init);
      else if (subtype === "interrupt") {
        program.answer(line);
        program.say(result("sess-1", { subtype: "error_during_execution", is_error: false }));
      } else program.answer(line);
    } else if (line.type === "user") {
      program.say(...(turns[next++] ?? []));
    }
  };
}

function start(scripts: Script[], options: { resume?: string; model?: string; configFolder?: string } = {}, refuse?: string) {
  const { spawn, programs } = fakeSpawn(scripts, { refuse });
  const provider = createClaudeProvider({ spawn, loadQuery });
  const events: ProviderEvent[] = [];
  provider.start(options, (event) => events.push(event));
  return { provider, events, programs };
}

async function waitFor(check: () => boolean, what: string) {
  for (let i = 0; i < 800; i++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("timed out waiting for " + what);
}

const of = <T extends ProviderEvent["type"]>(events: ProviderEvent[], type: T) =>
  events.filter((e): e is Extract<ProviderEvent, { type: T }> => e.type === type);

test("a turn on a Claude plan: ready, text, done", async () => {
  const { provider, events, programs } = start([chat([helloTurn("sess-1")])], { configFolder: "/Users/someone/.claude-work" });
  await waitFor(() => of(events, "ready").length > 0, "ready");
  expect(of(events, "ready")[0]).toEqual({
    type: "ready",
    model: "default",
    billing: "plan",
    models: [
      { id: "default", name: "Default (recommended)" },
      { id: "opus", name: "Opus" },
      { id: "haiku", name: "Haiku" },
    ],
    providerVersion: "2.1.323",
  });

  provider.send("Hi");
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "text").map((e) => e.delta)).toEqual(["Hello", " there."]);
  expect(of(events, "session")).toEqual([{ type: "session", id: "sess-1" }]);
  expect(of(events, "error")).toEqual([]);
  // The init message says which model answered: shown from then on.
  expect(of(events, "ready").at(-1)?.model).toBe("opus");

  const program = programs[0];
  expect(program.program).toBe("claude");
  expect(program.args).toContain("stream-json");
  // Only the SDK's own names and the config folder from the setting; nothing else of the sandbox.
  expect(program.env.CLAUDE_CONFIG_DIR).toBe("/Users/someone/.claude-work");
  for (const name of Object.keys(program.env)) {
    expect(["CLAUDE_CONFIG_DIR", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SDK_READS_SESSION_STATE"]).toContain(name);
  }
  // No MCP servers at all: not the user's own either (with the real SDK too, this is its argument).
  expect(program.args).toContain("--strict-mcp-config");
  expect(program.args.some((arg) => arg.startsWith("--mcp-config"))).toBe(false);
  // No skills listed in the program's prompt (sent with `initialize`).
  expect(program.received[0].request?.subtype).toBe("initialize");
  expect(program.received[0].request?.skills).toEqual([]);
  const user = program.received.find((line) => line.type === "user");
  expect(user?.message).toEqual({ role: "user", content: "Hi" });
  if (!realSDK) {
    const options = seenOptions.at(-1)!;
    expect(options.pathToClaudeCodeExecutable).toBe("claude");
    expect(options.tools).toEqual([]);
    expect(options.settingSources).toEqual([]);
    expect(options.mcpServers).toEqual({});
    expect(options.strictMcpConfig).toBe(true);
    expect(options.skills).toEqual([]);
    expect(options.canUseTool).toBeUndefined();
    expect(options.includePartialMessages).toBe(true);
    expect(options.systemPrompt).toContain("Singularity");
    expect(options.resume).toBeUndefined();
  }
  provider.stop();
  await waitFor(() => program.ended, "the program to end");
});

test("the program's environment", () => {
  const sdk = {
    CLAUDE_AGENT_SDK_VERSION: "0.3.323",
    CLAUDE_CODE_ENTRYPOINT: "sdk-ts",
    CLAUDE_CODE_SDK_READS_SESSION_STATE: "1",
    CLAUDE_CONFIG_DIR: "/from/the/sandbox",
    HOME: "/sandbox",
    ANTHROPIC_API_KEY: "x",
  };
  expect(programEnvironment(sdk, "")).toEqual({
    CLAUDE_AGENT_SDK_VERSION: "0.3.323",
    CLAUDE_CODE_ENTRYPOINT: "sdk-ts",
    CLAUDE_CODE_SDK_READS_SESSION_STATE: "1",
  });
  expect(programEnvironment({ CLAUDE_CODE_ENTRYPOINT: "sdk-ts", CLAUDE_AGENT_SDK_VERSION: undefined }, "  /Users/a/.claude-b ")).toEqual({
    CLAUDE_CODE_ENTRYPOINT: "sdk-ts",
    CLAUDE_CONFIG_DIR: "/Users/a/.claude-b",
  });
});

test("billing fails closed: only \"none\" is a plan", () => {
  expect(billingFrom("none")).toBe("plan");
  for (const source of [undefined, null, "", "ANTHROPIC_API_KEY", "/login managed key", "apiKeyHelper", "oauth"]) {
    expect(billingFrom(source)).toBe("api");
  }
  // The account in the answer to initialize (before any turn says more).
  expect(billingFromAccount({ apiKeySource: "none" })).toBe("plan");
  expect(billingFromAccount({ subscriptionType: "max", tokenSource: "claude.ai", apiProvider: "firstParty" })).toBe("plan");
  expect(billingFromAccount({ subscriptionType: "pro" })).toBe("plan");
  expect(billingFromAccount({ apiKeySource: "ANTHROPIC_API_KEY", subscriptionType: "max" })).toBe("api");
  expect(billingFromAccount({ subscriptionType: "max", apiProvider: "bedrock" })).toBe("api");
  expect(billingFromAccount({ apiKeySource: null })).toBe("api");
  expect(billingFromAccount({})).toBe("api");
  expect(billingFromAccount(undefined)).toBe("api");
  expect(billingFromAccount(null)).toBe("api");
});

test("a turn whose init message has no apiKeySource (absent or null) is API billing", async () => {
  for (const source of [undefined, null]) {
    const turn = helloTurn("sess-1");
    turn[0] = { ...initMessage("sess-1"), apiKeySource: source } as ReturnType<typeof initMessage>;
    const { provider, events } = start([chat([turn])]);
    await waitFor(() => of(events, "ready").length > 0, "ready");
    expect(of(events, "ready")[0].billing).toBe("plan");
    provider.send("Hi");
    await waitFor(() => of(events, "done").length > 0, "done");
    expect(of(events, "ready").at(-1)?.billing).toBe("api");
    provider.stop();
  }
});

test("an account without apiKeySource or a plan is API billing from the start", async () => {
  const { provider, events } = start([chat([], { ...initializeResponse, account: { apiProvider: "vertex" } })]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  expect(of(events, "ready")[0].billing).toBe("api");
  provider.stop();
});

test("stop, then start: the new program starts only after the old one has ended", async () => {
  const { spawn, programs, refused } = fakeSpawn([chat([]), chat([helloTurn("sess-1")])]);
  const provider = createClaudeProvider({ spawn, loadQuery });
  const first: ProviderEvent[] = [];
  provider.start({}, (event) => first.push(event));
  await waitFor(() => of(first, "ready").length > 0, "ready");

  provider.stop();
  const second: ProviderEvent[] = [];
  provider.start({ resume: "s1" }, (event) => second.push(event));
  await waitFor(() => of(second, "ready").length > 0, "the second ready");
  expect(refused).toEqual([]);
  expect(of(second, "error")).toEqual([]);
  expect(programs.length).toBe(2);
  expect(programs[0].ended).toBe(true);
  expect(programs[1].args).toContain("--resume=s1");
  // Nothing more from the first start.
  expect(first.filter((e) => e.type !== "ready")).toEqual([]);

  // start() again without stop() waits the same way.
  const third: ProviderEvent[] = [];
  provider.start({ resume: "s1" }, (event) => third.push(event));
  await waitFor(() => of(third, "ready").length > 0, "the third ready");
  expect(refused).toEqual([]);
  expect(programs.length).toBe(3);
  provider.stop();
});

for (const restarts of [2, 3]) {
  test(`stop and start ${restarts} times in quick succession: each start waits its turn`, async () => {
    const { spawn, programs, refused } = fakeSpawn([chat([helloTurn("sess-1")])]);
    const provider = createClaudeProvider({ spawn, loadQuery });
    const first: ProviderEvent[] = [];
    provider.start({}, (event) => first.push(event));
    await waitFor(() => of(first, "ready").length > 0, "ready");

    // Right away, before any of the new programs started (New Chat clicked twice, a double-click
    // on Try Again, New Chat right after Save config folder).
    let last: ProviderEvent[] = [];
    for (let i = 0; i < restarts; i++) {
      provider.stop();
      last = [];
      const events = last;
      provider.start({ resume: "s1" }, (event) => events.push(event));
    }
    await waitFor(() => of(last, "ready").length > 0, "the last ready");
    expect(refused).toEqual([]);
    expect(of(last, "error")).toEqual([]);
    expect(programs.length).toBe(2);
    expect(programs[0].ended).toBe(true);
    provider.send("Hi");
    await waitFor(() => of(last, "done").length > 0, "done");
    provider.stop();
  });
}

test("a refused start while resuming is an ordinary error, not a failed resume", async () => {
  const { provider, events, programs } = start([chat([])], { resume: "s1" }, "the program was not found");
  await waitFor(() => of(events, "error").length > 0, "an error");
  await new Promise((resolve) => setTimeout(resolve, 1200));
  expect(of(events, "error")).toEqual([{ type: "error", kind: "other", message: "the program was not found" }]);
  expect(programs.length).toBe(1);
  provider.stop();
});

test("API billing", async () => {
  const turn = helloTurn("sess-1");
  turn[0] = initMessage("sess-1", "/login managed key");
  const { provider, events } = start([chat([turn], initializeResponseAPI)]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  expect(of(events, "ready")[0].billing).toBe("api");
  provider.send("Hi");
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "ready").every((e) => e.billing === "api")).toBe(true);
  provider.stop();
});

test("programs off in a test copy", async () => {
  const { events, programs } = start([chat([])], {}, "programs are off in a test copy");
  await waitFor(() => of(events, "error").length > 0, "an error");
  await new Promise((resolve) => setTimeout(resolve, 1200));
  expect(of(events, "error")).toEqual([{ type: "error", kind: "programsOff", message: "programs are off in a test copy" }]);
  expect(of(events, "ready")).toEqual([]);
  expect(programs.length).toBe(1);
});

test("signed out", async () => {
  const { provider, events } = start([chat([signedOutTurn("sess-1")])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "error").length > 0, "an error");
  expect(of(events, "error")[0].kind).toBe("signedOut");
  expect(of(events, "done")).toEqual([]);
  expect(of(events, "text")).toEqual([]);
  provider.stop();
});

test("usage limit", async () => {
  const { provider, events } = start([chat([limitTurn("sess-1")])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "error").length > 0, "an error");
  expect(of(events, "error")[0].kind).toBe("limit");
  expect(of(events, "done")).toEqual([]);
  provider.stop();
});

test("a rejected rate limit event, then a successful result: the answer, not the limit notice", async () => {
  const { provider, events } = start([chat([limitWithExtraUsageTurn("sess-1"), helloTurn("sess-1")])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "text").map((e) => e.delta)).toEqual(["Hello", " there."]);
  expect(of(events, "error")).toEqual([]);
  // And the next turn is not held against it either.
  provider.send("Again");
  await waitFor(() => of(events, "done").length > 1, "the second done");
  expect(of(events, "error")).toEqual([]);
  provider.stop();
});

test("a refused turn after a rejected rate limit event is the limit, whatever its text", async () => {
  const { provider, events } = start([chat([limitTurnPlainText("sess-1")])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "error").length > 0, "an error");
  expect(of(events, "error")[0].kind).toBe("limit");
  expect(of(events, "done")).toEqual([]);
  provider.stop();
});

test("a turn with no streamed text shows its result text as the answer", async () => {
  const { provider, events } = start([chat([resultOnlyTurn("sess-1", "Unknown command: /nothing"), resultOnlyTurn("sess-1", "  ")])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("/nothing");
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "text").map((e) => e.delta)).toEqual(["Unknown command: /nothing"]);
  // Blank result text: nothing to show, just the end of the turn.
  provider.send("/blank");
  await waitFor(() => of(events, "done").length > 1, "the second done");
  expect(of(events, "text").length).toBe(1);
  expect(of(events, "error")).toEqual([]);
  provider.stop();
});

test("a failed resume reported at the first message: one error, then a new conversation", async () => {
  const { provider, events, programs } = start([chat([noConversationTurn("old-session")]), chat([helloTurn("sess-2")])],
    { resume: "old-session" });
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "error").length > 0, "an error");
  expect(of(events, "error")).toEqual([{
    type: "error",
    kind: "other",
    message: "The earlier conversation couldn't be continued, so a new one was started.",
    resumeFailed: true,
  }]);
  await waitFor(() => programs.length === 2 && of(events, "ready").length > 1, "the new program's ready");
  expect(programs[0].ended).toBe(true);
  expect(programs[1].args.some((arg) => arg.startsWith("--resume"))).toBe(false);
  provider.send("Hi");
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "session").at(-1)).toEqual({ type: "session", id: "sess-2" });
  expect(of(events, "error").length).toBe(1);
  provider.stop();
});

test("\"No conversation found\" without resume, or after a turn worked, is an ordinary error", async () => {
  const fresh = start([chat([noConversationTurn("x")])]);
  await waitFor(() => of(fresh.events, "ready").length > 0, "ready");
  fresh.provider.send("Hi");
  await waitFor(() => of(fresh.events, "error").length > 0, "an error");
  expect(of(fresh.events, "error")[0]).toMatchObject({ kind: "other" });
  expect(of(fresh.events, "error")[0].resumeFailed).toBeUndefined();
  fresh.provider.stop();

  const resumed = start([chat([helloTurn("s1"), noConversationTurn("s1")])], { resume: "s1" });
  await waitFor(() => of(resumed.events, "ready").length > 0, "ready");
  resumed.provider.send("Hi");
  await waitFor(() => of(resumed.events, "done").length > 0, "done");
  resumed.provider.send("Again");
  await waitFor(() => of(resumed.events, "error").length > 0, "an error");
  expect(of(resumed.events, "error")[0].resumeFailed).toBeUndefined();
  expect(resumed.programs.length).toBe(1);
  resumed.provider.stop();
});

test("the program ending mid-conversation", async () => {
  const dies: Script = (program, line) => {
    if (line.type === "control_request" && line.request?.subtype === "initialize") program.answer(line, initializeResponse);
    else if (line.type === "user") {
      program.say(initMessage("sess-1"));
      setTimeout(() => program.exit(1), 5);
    }
  };
  const { provider, events } = start([dies]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "error").length > 0, "an error");
  await new Promise((resolve) => setTimeout(resolve, 1200));
  expect(of(events, "error")).toEqual([{ type: "error", kind: "programEnded", message: "The connection to Claude ended." }]);
  provider.stop();
});

test("a failed resume: one error, then a new conversation without resume", async () => {
  const noSuchSession: Script = (program) => program.exit(1);
  const { provider, events, programs } = start([noSuchSession, chat([helloTurn("sess-2")])], { resume: "old-session" });
  await waitFor(() => of(events, "ready").length > 0, "ready");
  expect(events[0].type).toBe("error");
  expect(of(events, "error").length).toBe(1);
  expect(of(events, "error")[0]).toMatchObject({ kind: "other", resumeFailed: true });
  expect(programs.length).toBe(2);
  expect(programs[0].args).toContain("--resume=old-session");
  expect(programs[1].args.some((arg) => arg.startsWith("--resume"))).toBe(false);
  provider.send("Hi");
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "session")).toEqual([{ type: "session", id: "sess-2" }]);
  provider.stop();
});

test("resume and model are passed on", async () => {
  const { provider, events, programs } = start([chat([])], { resume: "sess-1", model: "haiku" });
  await waitFor(() => of(events, "ready").length > 0, "ready");
  expect(programs[0].args).toContain("--resume=sess-1");
  expect(programs[0].args).toContain("--model=haiku");
  expect(of(events, "ready")[0].model).toBe("haiku");
  provider.stop();
});

test("interrupt ends the turn with done, not an error", async () => {
  const slow: Script = (program, line) => {
    if (line.type === "control_request") {
      if (line.request?.subtype === "initialize") program.answer(line, initializeResponse);
      else {
        program.answer(line);
        if (line.request?.subtype === "interrupt") program.say(result("sess-1", { subtype: "error_during_execution", is_error: true }));
      }
    } else if (line.type === "user") {
      program.say(initMessage("sess-1"), helloTurn("sess-1")[3]);
    }
  };
  const { provider, events, programs } = start([slow]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.send("Hi");
  await waitFor(() => of(events, "text").length > 0, "text");
  provider.interrupt();
  await waitFor(() => of(events, "done").length > 0, "done");
  expect(of(events, "error")).toEqual([]);
  expect(programs[0].received.some((line) => line.request?.subtype === "interrupt")).toBe(true);
  provider.stop();
});

test("setModel asks the running program", async () => {
  const { provider, events, programs } = start([chat([])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  provider.setModel("haiku");
  await waitFor(() => programs[0].received.some((line) => line.request?.subtype === "set_model"), "set_model");
  expect(programs[0].received.find((line) => line.request?.subtype === "set_model")?.request.model).toBe("haiku");
  provider.stop();
});

test("stop ends the program and nothing more is reported", async () => {
  const { provider, events, programs } = start([chat([helloTurn("sess-1")])]);
  await waitFor(() => of(events, "ready").length > 0, "ready");
  const before = events.length;
  provider.stop();
  const program: FakeProgram = programs[0];
  await waitFor(() => program.ended, "the program to end");
  await new Promise((resolve) => setTimeout(resolve, 1200));
  expect(events.length).toBe(before);
});
