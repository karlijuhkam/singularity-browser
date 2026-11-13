// Stand-ins for the provider test: a fake `singularity.spawn` whose program replays a recorded
// stream-json exchange (it behaves like host.ts's SpawnedProgram: Node streams, "error" then
// "exit" 126 for a refused start), and a small fake of the Agent SDK's `query` that talks to that
// program the way the SDK does (newline-delimited JSON, an `initialize` control request first).
// No real claude program is ever run.
import { EventEmitter } from "node:events";
import { Readable, Writable } from "node:stream";

type Line = Record<string, any>;

/** What the fake program does with each line the SDK writes to it. */
export type Script = (program: FakeProgram, line: Line) => void;

export class FakeProgram {
  readonly stdin: Writable;
  readonly stdout: Readable;
  killed = false;
  exitCode: number | null = null;
  /** Every JSON line written to the program's stdin. */
  readonly received: Line[] = [];
  readonly killSignals: string[] = [];
  #events = new EventEmitter();
  #ended = false;
  #buffer = "";

  constructor(
    readonly program: string,
    readonly args: string[],
    readonly env: Record<string, string>,
    script: Script,
  ) {
    const self = this;
    this.stdin = new Writable({
      write(chunk: Buffer | string, _encoding, done) {
        self.#buffer += chunk.toString();
        let newline: number;
        while ((newline = self.#buffer.indexOf("\n")) >= 0) {
          const text = self.#buffer.slice(0, newline);
          self.#buffer = self.#buffer.slice(newline + 1);
          if (text.trim() === "") continue;
          const line = JSON.parse(text);
          self.received.push(line);
          // Answer later, as a real program would.
          setTimeout(() => {
            if (!self.#ended) script(self, line);
          }, 1);
        }
        done();
      },
    });
    this.stdout = new Readable({ read() {} });
  }

  on(event: string, listener: (...args: any[]) => void) {
    this.#events.on(event, listener);
    return this;
  }
  once(event: string, listener: (...args: any[]) => void) {
    this.#events.once(event, listener);
    return this;
  }
  off(event: string, listener: (...args: any[]) => void) {
    this.#events.off(event, listener);
    return this;
  }

  kill(signal = "SIGTERM"): boolean {
    if (this.#ended) return false;
    this.killed = true;
    this.killSignals.push(signal);
    setTimeout(() => this.exit(null, signal), 1);
    return true;
  }

  /** Writes lines to the program's stdout. */
  say(...lines: object[]): void {
    for (const line of lines) this.stdout.push(JSON.stringify(line) + "\n");
  }

  /** Answers a control request with success. */
  answer(request: Line, response: object = {}): void {
    this.say({ type: "control_response", response: { subtype: "success", request_id: request.request_id, response } });
  }

  exit(code: number | null, signal: string | null = null): void {
    if (this.#ended) return;
    this.#ended = true;
    this.exitCode = code;
    this.stdout.push(null);
    this.#events.emit("exit", code, signal);
  }

  /** What host.ts does when the app refuses the start. */
  refuse(reason: string): void {
    if (this.#events.listenerCount("error") > 0) this.#events.emit("error", new Error(reason));
    this.exit(126);
  }

  get ended(): boolean {
    return this.#ended;
  }
}

/** A fake singularity.spawn: each call makes a program run by the next script. */
export function fakeSpawn(scripts: Script[], options: { refuse?: string } = {}) {
  const programs: FakeProgram[] = [];
  const spawn = (program: string, args: string[], spawnOptions: { env: Record<string, string> }) => {
    const script = scripts[programs.length] ?? scripts[scripts.length - 1];
    const fake = new FakeProgram(program, args, spawnOptions.env, script);
    programs.push(fake);
    if (options.refuse) setTimeout(() => fake.refuse(options.refuse!), 1);
    return fake;
  };
  return { spawn, programs };
}

// ---- A small fake of the SDK's query() ----------------------------------------------------------

/** The options the provider passed to the last query(). */
export const seenOptions: Record<string, any>[] = [];

export function fakeQuery(params: { prompt: AsyncIterable<unknown>; options: Record<string, any> }) {
  const { prompt, options } = params;
  seenOptions.push(options);
  const abort = new AbortController();
  const args = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"];
  // Written the way the SDK writes them.
  if (options.model) args.push("--model=" + options.model);
  if (options.resume) args.push("--resume=" + options.resume);
  args.push("--permission-prompt-tool=stdio", "--tools=", "--setting-sources=", "--include-partial-messages");
  const program = options.spawnClaudeCodeProcess({
    command: options.pathToClaudeCodeExecutable,
    args,
    cwd: "/sandbox/data",
    // What the SDK passes: its own three names, plus the sandbox's environment.
    env: {
      CLAUDE_AGENT_SDK_VERSION: "0.3.323",
      CLAUDE_CODE_ENTRYPOINT: "sdk-ts",
      CLAUDE_CODE_SDK_READS_SESSION_STATE: "1",
      HOME: "/sandbox/data",
      TMPDIR: "/sandbox/data/tmp",
      CLAUDE_CONFIG_DIR: "/from/the/sandbox",
      ANTHROPIC_API_KEY: "not-to-be-passed",
    },
    signal: abort.signal,
  });

  let nextID = 1;
  const pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  const queue: Line[] = [];
  let wake: (() => void) | null = null;
  let finished = false;
  let failure: Error | null = null;

  function request(body: object): Promise<any> {
    const id = String(nextID++);
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      program.stdin.write(JSON.stringify({ type: "control_request", request_id: id, request: body }) + "\n");
    });
  }

  program.on("error", (error: Error) => {
    failure = new Error("Failed to spawn Claude Code process: " + error.message);
  });
  program.on("exit", (code: number | null) => {
    if (code !== 0 && code !== null) failure ??= new Error(`Claude Code process exited with code ${code}`);
    for (const waiter of pending.values()) waiter.reject(failure ?? new Error("ended"));
    pending.clear();
  });
  let buffer = "";
  program.stdout.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      if (line.type === "control_response") {
        const waiter = pending.get(line.response.request_id);
        pending.delete(line.response.request_id);
        waiter?.resolve(line.response.response);
      } else {
        queue.push(line);
        wake?.();
      }
    }
  });
  program.stdout.on("end", () => {
    finished = true;
    wake?.();
  });

  const initialization = request({ subtype: "initialize", hooks: null });
  initialization.catch(() => {});
  void (async () => {
    try {
      await initialization;
    } catch {
      return;
    }
    for await (const message of prompt) program.stdin.write(JSON.stringify(message) + "\n");
  })();

  async function* messages() {
    while (true) {
      if (queue.length > 0) {
        yield queue.shift()!;
        continue;
      }
      if (finished) {
        // Like the SDK: give the exit event a moment, then fail if the program failed.
        await new Promise((resolve) => setTimeout(resolve, 5));
        if (failure) throw failure;
        return;
      }
      await new Promise<void>((resolve) => (wake = resolve));
      wake = null;
    }
  }
  const iterator = messages();
  return Object.assign(iterator, {
    initializationResult: () => initialization,
    supportedModels: async () => (await initialization).models,
    interrupt: () => request({ subtype: "interrupt" }),
    setModel: (model?: string) => request({ subtype: "set_model", model }).then(() => {}),
    close: () => {
      abort.abort();
      program.stdin.end();
    },
  });
}
