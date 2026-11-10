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
  // { storage: [op, key?, value?] }: one call of singularity.storage; errors come back as text.
  if (payload && typeof payload === "object" && "storage" in payload) {
    const [op, key, value] = (payload as { storage: [string, string?, unknown?] }).storage;
    try {
      if (op === "get") return { value: (await singularity.storage.get(key!)) ?? "<undefined>" };
      if (op === "set") { await singularity.storage.set(key!, value); return { ok: true }; }
      if (op === "delete") return { deleted: await singularity.storage.delete(key!) };
      if (op === "keys") return { keys: await singularity.storage.keys() };
      if (op === "clear") { await singularity.storage.clear(); return { ok: true }; }
      // Many changes at once: all must land, in order, and the file must stay whole.
      if (op === "burst") {
        await Promise.all(Array.from({ length: 50 }, (_, i) => singularity.storage.set("n" + i, { i })));
        return { keys: (await singularity.storage.keys()).length };
      }
      // A value that isn't JSON, and one that is too big.
      if (op === "bad") { await singularity.storage.set("x", () => 1); return { ok: true }; }
      if (op === "huge") { await singularity.storage.set("big", "x".repeat(6 * 1024 * 1024)); return { ok: true }; }
      // What comes back is a copy.
      if (op === "copy") {
        await singularity.storage.set("o", { a: 1 });
        const first = (await singularity.storage.get("o")) as { a: number };
        first.a = 99;
        return { value: await singularity.storage.get("o") };
      }
    } catch (error) {
      return { storageError: String(error) };
    }
  }
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
