// Test plugin for PluginProgramTests. Each page message is one probe of singularity.spawn or
// singularity.panel; the answer says what happened.
import { singularity } from "singularity";

type Options = { env?: Record<string, string>; input?: Uint8Array; slowMs?: number; kill?: string };

/** Starts `name`, feeds it `input`, reads all of its output and waits for its exit. */
async function runProgram(name: string, args: string[], options: Options = {}) {
  const program = singularity.spawn(name, args, { env: options.env });
  const chunks: Buffer[] = [];
  let received = 0;
  let atExit = -1;
  let maxBuffered = 0;
  let error: string | null = null;
  program.on("error", (e: Error) => { error = e.message; });
  const exited = new Promise<{ code: number | null; signal: string | null }>((resolve) => {
    program.on("exit", (code: number | null, signal: string | null) => {
      // Everything the program wrote has arrived by now: read, or waiting in the stream's buffer.
      atExit = received + program.stdout.readableLength;
      resolve({ code, signal });
    });
  });
  if (options.input) program.stdin.write(options.input);
  if (options.kill) program.kill(options.kill);
  else program.stdin.end();
  const reading = (async () => {
    for await (const chunk of program.stdout) {
      chunks.push(chunk);
      received += chunk.length;
      maxBuffered = Math.max(maxBuffered, program.stdout.readableLength);
      if (options.slowMs) await Bun.sleep(options.slowMs);
    }
  })();
  const exit = await exited;
  await reading;
  return { ...exit, error, data: Buffer.concat(chunks), atExit, maxBuffered, killed: program.killed, exitCode: program.exitCode };
}

singularity.onPageMessage(async ({ tabID, frameHost, payload }) => {
  const p = payload as any;

  // A message from the plugin's own page (the panel): say who asked.
  if (tabID === "panel") return { tabID, frameHost, payload };

  // Bytes 0…255 over and over, more than one input message and many output messages long.
  if (p === "echo") {
    const input = new Uint8Array(700 * 1024).map((_, i) => i % 256);
    const result = await runProgram("fixture", ["echo"], { input });
    return { same: Buffer.compare(result.data, Buffer.from(input)) === 0, length: result.data.length, code: result.code };
  }

  // About 5 MB of numbered lines, read slowly: all there, in order, never much waiting.
  if (p === "slow") {
    const result = await runProgram("fixture", ["count", "750000"], { slowMs: 5 });
    const lines = result.data.toString().split("\n");
    let inOrder = lines.pop() === "";
    for (let i = 0; i < lines.length && inOrder; i++) inOrder = lines[i] === String(i + 1);
    return { lines: lines.length, inOrder, bytes: result.data.length, maxBuffered: result.maxBuffered, code: result.code };
  }

  if (p === "exit") {
    const result = await runProgram("fixture", ["exit", "20000"]);
    return { code: result.code, signal: result.signal, atExit: result.atExit, bytes: result.data.length };
  }

  if (p === "kill") {
    const result = await runProgram("fixture", ["echo"], { kill: "SIGTERM" });
    return { code: result.code, signal: result.signal, killed: result.killed, exitCode: result.exitCode };
  }

  if (p === "env") {
    const result = await runProgram("fixture", ["env"], { env: { FIXTURE_SETTING: "yes", NOT_LISTED: "no", EMPTY: "" } });
    return { text: result.data.toString() };
  }

  if (p === "stderr") {
    const result = await runProgram("fixture", ["stderr"]);
    return { code: result.code };
  }

  // Starts a program that ignores SIGTERM and leaves it running; answers with its pids.
  if (p === "ignore-term" || p === "ignore-term-then-crash") {
    const program = singularity.spawn("fixture", ["ignore-term"]);
    const first = await new Promise<string>((resolve) => program.stdout.once("data", (c: Buffer) => resolve(c.toString())));
    if (p === "ignore-term-then-crash") setTimeout(() => process.exit(1), 100);
    return { pids: first.trim() };
  }

  // A start the app refuses: { spawnFail: name }.
  if (p && typeof p === "object" && "spawnFail" in p) {
    const result = await runProgram(p.spawnFail, []);
    return { error: result.error, code: result.code };
  }

  // A second start while one runs.
  if (p === "twice") {
    const first = singularity.spawn("fixture", ["echo"]);
    const firstExit = new Promise((resolve) => first.on("exit", (code: number | null, signal: string | null) => resolve({ code, signal })));
    const second = await runProgram("fixture", ["echo"]);
    first.stdin.end();
    return { second: { error: second.error, code: second.code }, first: await firstExit };
  }

  if (p === "post") {
    singularity.panel.post({ hello: "panel", n: [1, 2] });
    let thrown: string | null = null;
    try {
      singularity.panel.post("x".repeat(300 * 1024));
    } catch (e) {
      thrown = (e as Error).message;
    }
    return { thrown };
  }

  return { unknown: payload };
});
