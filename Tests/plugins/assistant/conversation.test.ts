// Tests for Plugins/assistant/conversation.ts. Run from the repo root: Vendor/bun/bun test Tests/plugins/assistant
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConversationFile, MAX_MESSAGES, markStale, type Message, parseConversation } from "../../../Plugins/assistant/conversation.ts";

const folders: string[] = [];
function folder(): string {
  const dir = mkdtempSync(join(tmpdir(), "assistant-conversation-"));
  folders.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of folders.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const two: Message[] = [
  { role: "user", text: "Hi" },
  { role: "assistant", text: "Hello **there**" },
];

test("round trip", async () => {
  const dir = folder();
  const file = new ConversationFile(dir, { delayMs: 10 });
  file.update(two);
  await file.flush();
  expect(await new ConversationFile(dir).load()).toEqual(two);
  // Written atomically: no temporary file is left behind.
  expect(readdirSync(dir)).toEqual(["conversation.json"]);
});

test("a missing file is an empty conversation", async () => {
  expect(await new ConversationFile(folder()).load()).toEqual([]);
});

test("an unreadable file counts as empty", async () => {
  for (const text of ["not json", "[]", "null", '{"messages": 5}', ""]) {
    const dir = folder();
    writeFileSync(join(dir, "conversation.json"), text);
    expect(await new ConversationFile(dir).load()).toEqual([]);
  }
  // Entries of the wrong shape are left out, the rest kept.
  const dir = folder();
  writeFileSync(
    join(dir, "conversation.json"),
    JSON.stringify({ version: 1, messages: [{ role: "user", text: "ok" }, { role: "system", text: "x" }, { role: "user" }, 7] }),
  );
  expect(await new ConversationFile(dir).load()).toEqual([{ role: "user", text: "ok" }]);
});

test("keeps only the last 400 messages", async () => {
  const dir = folder();
  const many: Message[] = Array.from({ length: MAX_MESSAGES + 25 }, (_, i) => ({ role: "user", text: String(i) }));
  const file = new ConversationFile(dir, { delayMs: 10 });
  file.update(many);
  await file.flush();
  const loaded = await file.load();
  expect(MAX_MESSAGES).toBe(400);
  expect(loaded.length).toBe(400);
  expect(loaded[0].text).toBe("25");
  expect(loaded[399].text).toBe(String(MAX_MESSAGES + 24));
});

test("writes at most once per interval while streaming", async () => {
  const dir = folder();
  const path = join(dir, "conversation.json");
  const file = new ConversationFile(dir, { delayMs: 80 });
  file.update([{ role: "user", text: "a" }]);
  file.update([{ role: "user", text: "ab" }]);
  await sleep(20);
  expect(existsSync(path)).toBe(false);
  await sleep(120);
  expect(JSON.parse(readFileSync(path, "utf8")).messages).toEqual([{ role: "user", text: "ab" }]);
  // flush writes at once.
  file.update([{ role: "user", text: "abc" }]);
  await file.flush();
  expect(JSON.parse(readFileSync(path, "utf8")).messages).toEqual([{ role: "user", text: "abc" }]);
});

test("delete removes the file and drops a pending write", async () => {
  const dir = folder();
  const file = new ConversationFile(dir, { delayMs: 30 });
  file.update(two);
  await file.flush();
  file.update([...two, { role: "user", text: "more" }]);
  await file.delete();
  await sleep(60);
  expect(existsSync(join(dir, "conversation.json"))).toBe(false);
  expect(await file.load()).toEqual([]);
  // Deleting again (nothing there) is fine.
  await file.delete();
});

test("stale marking", async () => {
  expect(markStale(two)).toEqual([
    { role: "user", text: "Hi", stale: true },
    { role: "assistant", text: "Hello **there**", stale: true },
  ]);
  // The flag survives a round trip.
  const dir = folder();
  const file = new ConversationFile(dir);
  file.update(markStale(two));
  await file.flush();
  expect((await file.load())[0].stale).toBe(true);
});

test("tool lines are kept in order with their message; a line that was running is not done", () => {
  const text = JSON.stringify({
    version: 1,
    messages: [
      { role: "user", text: "Hi" },
      { role: "assistant", text: "Ok", tools: [{ text: "Read a tab", status: "done" }, { text: "Clicked on a tab", status: "running" }, { text: 5 }, "x"] },
    ],
  });
  expect(parseConversation(text)[1]).toEqual({
    role: "assistant",
    text: "Ok",
    tools: [{ text: "Read a tab", status: "done" }, { text: "Clicked on a tab — not done", status: "failed" }],
  });
});
