// The Claude provider: talks to the user's own installed `claude` program through the Claude
// Agent SDK (@anthropic-ai/claude-agent-sdk, pinned in package.json).
//
// How it is wired:
// - One SDK `query` in streaming-input mode: the user's messages are fed to it one at a time
//   through `Input`, and the program's messages come back from it as they arrive.
// - The SDK doesn't start the program itself. `spawnClaudeCodeProcess` hands the start to
//   Singularity (`singularity.spawn`), which runs `claude` outside this plugin's sandbox, at the
//   path pinned when the plugin was approved, with an environment the app builds.
// - The program gets no built-in tools (`tools: []`); none of the user's settings files, so none
//   of their hooks, plugins, permission rules or CLAUDE.md (`settingSources: []`); no MCP servers
//   at all (`strictMcpConfig: true` → `--strict-mcp-config`: only servers passed in `mcpServers`,
//   and we pass none; without it the user's own servers, including Singularity's, would start);
//   no skills in its prompt (`skills: []`); and a short system prompt of our own. So it can only
//   write text. Reviewers: this is what keeps the Assistant harmless; the app doesn't enforce it.
//   Not closable by an option (SDK 0.3.323): a message typed as a "/command" may still be read
//   by the program as one of its own commands, and organisation-managed settings still apply.
// - Of the environment the SDK wants to pass, only its own three names go through, plus
//   CLAUDE_CONFIG_DIR from the Assistant's setting (plugin.json's `programEnv` lists exactly these).
//
// Names used from the SDK (sdk.d.ts of version 0.3.323): query({ prompt, options }) returning a
// Query with initializationResult(), supportedModels(), interrupt(), setModel(), close(); the
// messages `system`/`init` (apiKeySource, model, claude_code_version, session_id), `stream_event`
// (content_block_delta / text_delta), `assistant` (its `error` field), `rate_limit_event` and
// `result` (subtype, is_error, result).

import packageInfo from "./package.json";
import type { Provider, ProviderEvent } from "./provider.ts";

/** The pinned SDK version, shown in the page's settings and error states. */
export const claudeSDKVersion: string = packageInfo.dependencies["@anthropic-ai/claude-agent-sdk"];

const SYSTEM_PROMPT = [
  "You are the Assistant inside Singularity, a web browser for macOS.",
  "In this version you can only chat: you cannot see the user's pages, tabs or terminals, and you cannot open, click, type or run anything for them.",
  "When asked to look at or do something in the browser, say plainly that you can't do that yet, and help with what you can.",
  "Answer in plain Markdown.",
].join(" ");

/** The names the SDK sets for its program (plugin.json's programEnv lists these and CLAUDE_CONFIG_DIR). */
const SDK_ENV_NAMES = ["CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SDK_READS_SESSION_STATE"];

/** What `singularity.spawn` returns (see host.ts, "Programs"). */
export type SpawnedProgram = {
  stdin: unknown;
  stdout: unknown;
  readonly killed: boolean;
  readonly exitCode: number | null;
  kill(signal?: string): boolean;
  on(event: "exit" | "error", listener: (...args: any[]) => void): unknown;
  once(event: "exit" | "error", listener: (...args: any[]) => void): unknown;
  off(event: "exit" | "error", listener: (...args: any[]) => void): unknown;
};
export type Spawn = (program: string, args: string[], options: { env: Record<string, string> }) => SpawnedProgram;

/** The part of the SDK's Query this file uses. */
type Query = AsyncIterable<any> & {
  initializationResult(): Promise<any>;
  supportedModels(): Promise<any[]>;
  interrupt(): Promise<unknown>;
  setModel(model?: string): Promise<void>;
  close(): void;
};
export type QueryFunction = (params: { prompt: AsyncIterable<unknown>; options: Record<string, unknown> }) => Query;

/**
 * The environment for the program: the SDK's own three names as the SDK set them, and
 * CLAUDE_CONFIG_DIR only from the user's setting (never from the sandbox's environment).
 */
export function programEnvironment(sdkEnv: Record<string, string | undefined>, configFolder: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const name of SDK_ENV_NAMES) {
    const value = sdkEnv[name];
    if (typeof value === "string") env[name] = value;
  }
  const folder = configFolder.trim();
  if (folder !== "") env.CLAUDE_CONFIG_DIR = folder;
  return env;
}

/**
 * A turn's init message: "none" means no API key is used, a Claude plan sign-in. Anything else,
 * absent included (a third-party provider's account), counts as API billing: when in doubt, say
 * that the chat may cost money.
 */
export function billingFrom(apiKeySource: unknown): "plan" | "api" {
  return apiKeySource === "none" ? "plan" : "api";
}

/**
 * The account in the program's answer to `initialize`, before any turn's init message: a plan
 * only with "none", or with no API key named but a Claude subscription on Anthropic's own service.
 * Everything else is API billing.
 */
export function billingFromAccount(account: unknown): "plan" | "api" {
  const a = (account ?? {}) as { apiKeySource?: unknown; subscriptionType?: unknown; apiProvider?: unknown };
  if (a.apiKeySource === "none") return "plan";
  if (a.apiKeySource !== undefined && a.apiKeySource !== null) return "api";
  const firstParty = a.apiProvider === undefined || a.apiProvider === "firstParty";
  return firstParty && typeof a.subscriptionType === "string" && a.subscriptionType !== "" ? "plan" : "api";
}

type Failure = { kind: "signedOut" | "limit" | "other"; message: string };

/** The `error` of an assistant message (SDKAssistantMessageError) as one of our kinds. */
function failureFor(error: string, message: string): Failure {
  if (error === "authentication_failed") return { kind: "signedOut", message };
  if (error === "rate_limit") return { kind: "limit", message };
  return { kind: "other", message };
}

/** For a failed turn that came without one of the SDK's error names: the program's text. */
function failureFromText(text: string): Failure {
  if (/not logged in|please run \/login|invalid api key|oauth token/i.test(text)) return { kind: "signedOut", message: text };
  if (/usage limit|hit your limit|rate limit/i.test(text)) return { kind: "limit", message: text };
  return { kind: "other", message: text || "Claude couldn't answer." };
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** The text of an SDK assistant message (for an error message). */
function assistantText(message: any): string {
  const content = message?.message?.content;
  if (!Array.isArray(content)) return "";
  return content.filter((block: any) => block?.type === "text" && typeof block.text === "string").map((b: any) => b.text).join("");
}

/** The user's messages, handed to the SDK one at a time as it asks for them. */
class Input implements AsyncIterable<unknown> {
  #items: unknown[] = [];
  #waiting: ((result: IteratorResult<unknown>) => void) | null = null;
  #closed = false;

  push(item: unknown): void {
    if (this.#closed) return;
    if (this.#waiting) {
      const resolve = this.#waiting;
      this.#waiting = null;
      resolve({ value: item, done: false });
    } else {
      this.#items.push(item);
    }
  }

  close(): void {
    this.#closed = true;
    this.#waiting?.({ value: undefined, done: true });
    this.#waiting = null;
  }

  [Symbol.asyncIterator](): AsyncIterator<unknown> {
    return {
      next: () => {
        if (this.#items.length > 0) return Promise.resolve({ value: this.#items.shift(), done: false });
        if (this.#closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => (this.#waiting = resolve));
      },
      return: () => {
        this.close();
        return Promise.resolve({ value: undefined, done: true });
      },
    };
  }
}

type Dependencies = {
  spawn: Spawn;
  /** The SDK's `query`; loaded on first use, so the plugin starts without loading the SDK. */
  loadQuery: () => Promise<QueryFunction>;
  log?: (...values: unknown[]) => void;
};

type StartOptions = { resume?: string; model?: string; configFolder?: string };

/** How long a stopped program may take to exit before the next one is started anyway. */
const EXIT_WAIT_MS = 5000;

/**
 * One start of the program, until it ends or is stopped. A restart makes a new Run; an old one
 * reports nothing more once it has ended.
 */
class Run {
  #ended = false;
  /** A terminal error or a restart has been reported: nothing more from this run. */
  #finished = false;
  #query: Query | null = null;
  #program: SpawnedProgram | null = null;
  #input = new Input();
  /** initializationResult() answered: the program started and read its options. */
  #initialized = false;
  #spawnError: string | null = null;
  // The answer being written.
  #answering = false;
  #interrupted = false;
  #turnFailure: Failure | null = null;
  /** A rate_limit_event of this turn said "rejected"; it counts only if the turn fails too. */
  #limitRejected = false;
  /** Some of this turn's answer was streamed as text. */
  #textThisTurn = false;
  /** A turn of this run ended well: from then on `resume` worked. */
  #turnSucceeded = false;
  // What `ready` last said.
  #models: { id: string; name: string; resolved?: string }[] = [];
  #billing: "plan" | "api" = "plan";
  #providerVersion = "";
  #modelInUse: string | null = null;
  #lastReady = "";
  #session: string | null = null;
  #programExited: Promise<void>;
  #markExited: () => void = () => {};

  constructor(
    private readonly deps: Dependencies,
    private readonly options: StartOptions,
    private readonly chosenModel: () => string | undefined,
    private readonly emitOut: (event: ProviderEvent) => void,
    /** Called once when `resume` failed; starts a new run without it. */
    private readonly restartWithoutResume: () => void,
    previousExit: Promise<void>,
  ) {
    this.#programExited = new Promise((resolve) => (this.#markExited = resolve));
    void this.#run(previousExit);
  }

  /** Resolves when this run's program has exited (at once if none was started). */
  get exited(): Promise<void> {
    return this.#programExited;
  }

  #emit(event: ProviderEvent): void {
    if (!this.#ended && !this.#finished) this.emitOut(event);
  }

  async #run(previousExit: Promise<void>): Promise<void> {
    // Singularity runs one program per plugin: wait for the one being stopped to go.
    await Promise.race([previousExit, new Promise((resolve) => setTimeout(resolve, EXIT_WAIT_MS))]);
    let query: QueryFunction;
    try {
      query = await this.deps.loadQuery();
    } catch (error) {
      this.#markExited();
      this.#fail({ kind: "other", message: "The Assistant couldn't load: " + errorText(error) });
      return;
    }
    if (this.#ended) {
      this.#markExited();
      return;
    }
    try {
      this.#query = query({ prompt: this.#input, options: this.#sdkOptions() });
    } catch (error) {
      this.#markExited();
      this.#fail({ kind: "other", message: "The Assistant couldn't start: " + errorText(error) });
      return;
    }
    void this.#initialize();
    try {
      for await (const message of this.#query) {
        if (this.#ended) break;
        this.#handle(message);
      }
    } catch {
      // The program ended or failed to start; #programEnded says which.
    }
    this.#programEnded();
  }

  #sdkOptions(): Record<string, unknown> {
    const options: Record<string, unknown> = {
      pathToClaudeCodeExecutable: "claude",
      tools: [],
      settingSources: [],
      mcpServers: {},
      strictMcpConfig: true,
      skills: [],
      includePartialMessages: true,
      systemPrompt: SYSTEM_PROMPT,
      spawnClaudeCodeProcess: (o: { args: string[]; env: Record<string, string | undefined>; signal?: AbortSignal }) =>
        this.#spawn(o),
    };
    if (this.options.resume) options.resume = this.options.resume;
    const model = this.chosenModel();
    if (model) options.model = model;
    return options;
  }

  #spawn(o: { args: string[]; env: Record<string, string | undefined>; signal?: AbortSignal }): SpawnedProgram {
    const program = this.deps.spawn("claude", o.args, { env: programEnvironment(o.env ?? {}, this.options.configFolder ?? "") });
    this.#program = program;
    // Stopped while the SDK was still starting it.
    if (this.#ended) program.kill("SIGTERM");
    program.on("error", (error: unknown) => {
      this.#spawnError ??= errorText(error);
    });
    program.on("exit", () => {
      this.#markExited();
      // Normally the SDK's message stream ends right after; this is in case it doesn't.
      setTimeout(() => this.#programEnded(), 1000);
    });
    // The SDK aborts this signal when it closes the query (after giving the program time to end
    // by itself): the program must end then.
    o.signal?.addEventListener("abort", () => program.kill("SIGTERM"), { once: true });
    return program;
  }

  async #initialize(): Promise<void> {
    try {
      const info = await this.#query!.initializationResult();
      const models = await this.#query!.supportedModels();
      if (this.#ended) return;
      this.#initialized = true;
      this.#models = (Array.isArray(models) ? models : [])
        .filter((m) => typeof m?.value === "string" && m.value !== "")
        .map((m) => ({
          id: m.value,
          name: typeof m.displayName === "string" && m.displayName !== "" ? m.displayName : m.value,
          resolved: typeof m.resolvedModel === "string" ? m.resolvedModel : undefined,
        }));
      this.#billing = billingFromAccount(info?.account);
      if (typeof info?.claude_code_version === "string") this.#providerVersion = info.claude_code_version;
      this.#emitReady();
    } catch {
      // The program ended before it answered; #programEnded reports it.
    }
  }

  #emitReady(): void {
    if (!this.#initialized) return;
    const model = this.chosenModel() ?? this.#modelInUse ?? this.#models[0]?.id ?? "";
    const event: ProviderEvent = {
      type: "ready",
      model,
      billing: this.#billing,
      models: this.#models.map(({ id, name }) => ({ id, name })),
      providerVersion: this.#providerVersion,
    };
    const key = JSON.stringify(event);
    if (key === this.#lastReady) return;
    this.#lastReady = key;
    this.#emit(event);
  }

  #handle(message: any): void {
    if (message === null || typeof message !== "object") return;
    switch (message.type) {
      case "system":
        if (message.subtype === "init") {
          this.#noteSession(message.session_id);
          this.#billing = billingFrom(message.apiKeySource);
          if (typeof message.claude_code_version === "string") this.#providerVersion = message.claude_code_version;
          if (typeof message.model === "string") {
            // Shown as the menu's row for it when there is one ("opus" for claude-opus-…).
            const row = this.#models.find((m) => m.id === message.model || m.resolved === message.model);
            this.#modelInUse = row ? row.id : message.model;
          }
          this.#emitReady();
        }
        break;
      case "stream_event": {
        // Only the main answer's text (a subagent's would have parent_tool_use_id; there are no tools anyway).
        const event = message.event;
        if (!message.parent_tool_use_id && event?.type === "content_block_delta" && event.delta?.type === "text_delta"
            && typeof event.delta.text === "string" && event.delta.text !== "") {
          this.#textThisTurn = true;
          this.#emit({ type: "text", delta: event.delta.text });
        }
        break;
      }
      case "assistant":
        if (typeof message.error === "string" && !message.parent_tool_use_id) {
          this.#turnFailure ??= failureFor(message.error, assistantText(message));
        }
        break;
      case "rate_limit_event":
        // "rejected" alone doesn't mean this turn failed: a plan with extra usage switched on
        // goes on and answers. It decides the kind only when the turn fails (#endTurn).
        if (message.rate_limit_info?.status === "rejected") this.#limitRejected = true;
        break;
      case "result":
        this.#noteSession(message.session_id);
        this.#endTurn(message);
        break;
    }
  }

  #noteSession(id: unknown): void {
    if (typeof id === "string" && id !== "" && id !== this.#session) {
      this.#session = id;
      this.#emit({ type: "session", id });
    }
  }

  #endTurn(result: any): void {
    const interrupted = this.#interrupted;
    const failure = this.#turnFailure;
    const limited = this.#limitRejected;
    const streamed = this.#textThisTurn;
    this.#answering = false;
    this.#interrupted = false;
    this.#turnFailure = null;
    this.#limitRejected = false;
    this.#textThisTurn = false;
    const resultText = (typeof result?.result === "string" ? result.result
      : Array.isArray(result?.errors) ? result.errors.filter((e: unknown) => typeof e === "string").join("\n") : "").slice(0, 1000);
    if (interrupted) {
      this.#emit({ type: "done" });
    } else if (failure) {
      this.#turnFailed(failure.kind, failure.message || resultText, resultText);
    } else if (result?.is_error || result?.subtype !== "success") {
      const found = failureFromText(resultText);
      // A refused turn after a "rejected" rate limit event: that is the reason.
      this.#turnFailed(limited ? "limit" : found.kind, found.message, resultText);
    } else {
      this.#turnSucceeded = true;
      // A turn the program answered without streaming (a "/command" it handles itself): its
      // result text is the answer.
      if (!streamed && typeof result?.result === "string" && result.result.trim() !== "") {
        this.#emit({ type: "text", delta: result.result });
      }
      this.#emit({ type: "done" });
    }
  }

  /**
   * A turn ended in failure. While resuming, before any turn worked, "No conversation found" means
   * the program couldn't find the conversation to continue (it may say so at the first message
   * rather than end before `initialize`): that is a failed resume.
   */
  #turnFailed(kind: Failure["kind"], message: string, resultText: string): void {
    if (this.options.resume && !this.#turnSucceeded && /no conversation found/i.test(message + "\n" + resultText)) {
      this.#resumeFailed();
      return;
    }
    this.#emit({ type: "error", kind, message });
  }

  /** Exactly one error with `resumeFailed`, then a new run without `resume`. */
  #resumeFailed(): void {
    this.#emit({
      type: "error",
      kind: "other",
      message: "The earlier conversation couldn't be continued, so a new one was started.",
      resumeFailed: true,
    });
    this.#finished = true;
    this.restartWithoutResume();
  }

  /** The program is gone (or never started): say why, once. */
  #programEnded(): void {
    if (this.#ended || this.#finished) return;
    if (this.#spawnError !== null) {
      const kind = this.#spawnError.includes("programs are off in a test copy") ? "programsOff" : "other";
      this.#fail({ kind, message: this.#spawnError });
    } else if (this.options.resume && !this.#initialized) {
      // The program started (no refusal) but ended before it answered: `claude --resume <id>`
      // does that when it can't find or read that conversation.
      this.#resumeFailed();
    } else {
      this.#fail({ kind: "programEnded", message: "The connection to Claude ended." });
    }
  }

  #fail(failure: { kind: ProviderEventKind; message: string }): void {
    this.#emit({ type: "error", kind: failure.kind, message: failure.message });
    this.#finished = true;
    this.end();
  }

  send(text: string): void {
    if (this.#ended || this.#finished) return;
    this.#answering = true;
    this.#interrupted = false;
    this.#turnFailure = null;
    this.#limitRejected = false;
    this.#textThisTurn = false;
    this.#input.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
  }

  interrupt(): void {
    if (!this.#answering || !this.#query) return;
    this.#interrupted = true;
    this.#query.interrupt().catch((error) => this.deps.log?.("interrupt failed: " + errorText(error)));
  }

  setModel(id: string): void {
    this.#query?.setModel(id).catch((error) => this.deps.log?.("setModel failed: " + errorText(error)));
    this.#modelInUse = id;
    this.#emitReady();
  }

  /** Ends the program at once (Singularity runs one per plugin, and the next start waits for it). */
  end(): void {
    if (this.#ended) return;
    this.#ended = true;
    this.#input.close();
    try {
      this.#query?.close();
    } catch {
      // already closed
    }
    if (this.#program && this.#program.exitCode === null && !this.#program.killed) this.#program.kill("SIGTERM");
    if (!this.#program) this.#markExited();
  }
}

type ProviderEventKind = Extract<ProviderEvent, { type: "error" }>["kind"];

export function createClaudeProvider(deps: Dependencies): Provider {
  let run: Run | null = null;
  let chosenModel: string | undefined;
  /**
   * When the last program ended. Kept across stop(): Singularity runs one program per plugin and
   * refuses a second start while the first is still ending, so every start waits for this.
   */
  let lastExit: Promise<void> = Promise.resolve();

  function endRun(): void {
    if (run === null) return;
    run.end();
    // Chained, not replaced: a run stopped while it was still waiting for an earlier program has
    // no program of its own and counts as exited at once, but that earlier program may still be
    // ending.
    lastExit = Promise.all([lastExit, run.exited]).then(() => {});
    run = null;
  }

  function begin(options: StartOptions, emit: (event: ProviderEvent) => void): void {
    endRun();
    run = new Run(deps, options, () => chosenModel, emit, () => begin({ ...options, resume: undefined }, emit), lastExit);
  }

  return {
    start(options, emit) {
      chosenModel = options.model || undefined;
      begin(options, emit);
    },
    send(text) {
      run?.send(text);
    },
    interrupt() {
      run?.interrupt();
    },
    setModel(id) {
      chosenModel = id;
      run?.setModel(id);
    },
    stop() {
      endRun();
    },
  };
}
