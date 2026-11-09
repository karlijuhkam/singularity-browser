// Test plugin for PluginProcessTests. Each payload string triggers one probe; anything else is echoed.
import { singularity } from "singularity";
import { readFileSync } from "node:fs";

singularity.onPageMessage(async ({ payload }) => {
  // Declared in plugin.json as command "echo" with sub-command "hello".
  if (payload === "run-op") return await singularity.run("echo", ["hello"]);
  // Not declared ("bye" is not a sub-command): the app refuses with status 126.
  if (payload === "forbidden") return await singularity.run("echo", ["bye"]);
  // The sandbox denies all network access.
  if (payload === "net") {
    try {
      await fetch("https://example.com", { signal: AbortSignal.timeout(5000) });
      return { fetched: true };
    } catch (error) {
      return { fetchError: String(error) };
    }
  }
  if (payload === "crash") process.exit(1);
  // Ten commands at once: at most 4 may run at the same time, the rest are refused right away.
  if (payload === "burst") {
    return await Promise.all(Array.from({ length: 10 }, () => singularity.run("echo", ["hello"])));
  }
  // Errors nobody catches are logged by host.ts; the plugin keeps running.
  if (payload === "reject") {
    Promise.reject(new Error("forgotten rejection"));
    return { echo: payload };
  }
  if (payload === "uncaught") {
    setTimeout(() => { throw new Error("thrown in a timer"); }, 0);
    return { echo: payload };
  }
  if (payload === "throw") throw new Error("boom");
  // console output must not break the wire (host.ts turns it into log messages).
  if (payload === "console") {
    console.log("noise on stdout");
    console.error("noise on stderr");
    return { echo: payload };
  }
  if (payload === "env") return { keys: Object.keys(process.env), home: process.env.HOME ?? null };
  // { read: "/some/path" }: try to read a file.
  if (payload && typeof payload === "object" && "read" in payload) {
    try {
      return { read: readFileSync(String((payload as { read: unknown }).read), "utf8") };
    } catch (error) {
      return { readError: String(error) };
    }
  }
  return { echo: payload };
});
