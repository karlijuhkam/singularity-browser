// The Assistant's own copy of the conversation the user sees, so it is still there after a
// restart. (What Claude itself remembers is the program's own session file, in its config folder;
// the plugin only keeps that session's id.)
//
// One file, <data folder>/conversation.json:  { "version": 1, "messages": [ { role, text, stale? } ] }
// - written whole to a temporary file that is then renamed over the old one, so a crash leaves
//   the old copy or the new one, never half a file;
// - while an answer streams, at most once a second; at the end of an answer at once (`flush`);
// - only the last 400 messages are kept;
// - a file that can't be read counts as an empty conversation (and is replaced by the next write).
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";

export type Message = { role: "user" | "assistant"; text: string; stale?: boolean };

export const MAX_MESSAGES = 400;

/** The newest MAX_MESSAGES messages. */
export function capMessages(messages: Message[]): Message[] {
  return messages.length > MAX_MESSAGES ? messages.slice(messages.length - MAX_MESSAGES) : messages;
}

/** Every message marked as one Claude no longer remembers. */
export function markStale(messages: Message[]): Message[] {
  return messages.map((message) => ({ ...message, stale: true }));
}

function isMessage(value: unknown): value is Message {
  if (value === null || typeof value !== "object") return false;
  const m = value as Record<string, unknown>;
  return (m.role === "user" || m.role === "assistant") && typeof m.text === "string"
    && (m.stale === undefined || typeof m.stale === "boolean");
}

/** The messages in a conversation.json's text; [] for anything that isn't one. */
export function parseConversation(text: string): Message[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  const messages = (parsed as { messages?: unknown } | null)?.messages;
  if (!Array.isArray(messages)) return [];
  return capMessages(
    messages.filter(isMessage).map((m) => (m.stale ? { role: m.role, text: m.text, stale: true } : { role: m.role, text: m.text })),
  );
}

export class ConversationFile {
  readonly #path: string;
  readonly #folder: string;
  readonly #delayMs: number;
  #pending: Message[] | null = null;
  #timer: ReturnType<typeof setTimeout> | null = null;
  /** Writes and deletes happen one after another, in order. */
  #queue: Promise<void> = Promise.resolve();

  /** `folder`: the plugin's data folder (HOME of the background program). */
  constructor(folder: string, options: { delayMs?: number } = {}) {
    this.#folder = folder;
    this.#path = folder + "/conversation.json";
    this.#delayMs = options.delayMs ?? 1000;
  }

  async load(): Promise<Message[]> {
    await this.#queue;
    try {
      return parseConversation(await readFile(this.#path, "utf8"));
    } catch {
      return [];
    }
  }

  /** Saves `messages` soon: at most once per second, the latest version wins. */
  update(messages: Message[]): void {
    this.#pending = capMessages(messages).map((m) => ({ ...m }));
    if (this.#timer === null) {
      this.#timer = setTimeout(() => {
        this.#timer = null;
        // A failed write is tried again with the next change; there is nobody to tell here.
        this.#writePending().catch(() => {});
      }, this.#delayMs);
    }
  }

  /** Writes what `update` is holding now. */
  async flush(): Promise<void> {
    if (this.#timer !== null) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
    await this.#writePending();
  }

  /** Removes the file (New Chat), and forgets a write that hasn't happened yet. */
  async delete(): Promise<void> {
    if (this.#timer !== null) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
    this.#pending = null;
    await this.#enqueue(() => rm(this.#path, { force: true }));
  }

  #writePending(): Promise<void> {
    const messages = this.#pending;
    this.#pending = null;
    if (messages === null) return this.#queue;
    const text = JSON.stringify({ version: 1, messages });
    return this.#enqueue(async () => {
      await mkdir(this.#folder, { recursive: true });
      const temporary = this.#path + ".tmp";
      await writeFile(temporary, text);
      await rename(temporary, this.#path);
    });
  }

  #enqueue(work: () => Promise<unknown>): Promise<void> {
    const next = this.#queue.then(work).then(() => {});
    // A failed write must not block the ones after it; the caller still sees the failure.
    this.#queue = next.catch(() => {});
    return next;
  }
}
