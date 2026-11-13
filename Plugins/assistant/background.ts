// Background program of the Assistant plugin. It runs on Singularity's bundled Bun, in a sandbox
// with no network. It owns one Provider (today Claude, provider-claude.ts) and the conversation's
// state, and talks to the plugin's own page (panel.tsx).
//
// Messages from the page (singularity.send; every answer is the full state, or { error }):
//   { type: "hello" }                    starts the provider the first time (not at plugin start,
//                                        so nothing runs or counts against a plan until the panel opens)
//   { type: "send", text }               { type: "stop" }       { type: "newChat" }
//   { type: "setModel", id }             { type: "setConfigFolder", path }   (restarts the provider)
//   { type: "retry" }                    { type: "billingSeen" }
// Pushed to the page (singularity.panel.post):
//   { type: "delta", text, version }     a piece of the answer
//   { type: "state", ...state }          after every other change the provider causes
// The state: { messages, status, model, models, billing, billingNoticeSeen, configFolder,
// providerVersion, sdkVersion, error, version } (see view.ts, ViewState).
//
// Kept in singularity.storage: session (the conversation's id, to continue it after a restart),
// model, configFolder, billing (the last one seen) and billingNoticeSeen. The visible messages are
// in conversation.json (conversation.ts). Nothing here is secret: no tokens or keys pass through
// this plugin; the claude program keeps its own sign-in.
import { singularity } from "singularity";
import { ConversationFile, markStale, type Message } from "./conversation.ts";
import type { Provider, ProviderEvent } from "./provider.ts";
import { claudeSDKVersion, createClaudeProvider, type QueryFunction } from "./provider-claude.ts";
import type { Status, ViewState } from "./view.ts";

/** The largest state the page is sent; older messages are left out beyond it (a post may be 256 KB). */
const STATE_BUDGET_BYTES = 200 * 1024;
const MAX_TEXT_LENGTH = 100_000;
const MAX_PATH_LENGTH = 1024;
/** After Stop, how long the end of the turn may take before the provider is started again. */
const STOP_WAIT_MS = 5000;

type Storage = {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<boolean>;
};

type Dependencies = {
  singularity: { panel: { post(payload: unknown): void }; storage: Storage; log(...values: unknown[]): void };
  provider: Provider;
  conversation: ConversationFile;
  sdkVersion: string;
  /** Tests make it shorter (default STOP_WAIT_MS). */
  stopWaitMs?: number;
};

/** The newest messages that fit in `budget` bytes of JSON (at least the last one, cut if it must be). */
export function fitMessages(messages: Message[], budget = STATE_BUDGET_BYTES): Message[] {
  const kept: Message[] = [];
  let size = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const bytes = Buffer.byteLength(JSON.stringify(messages[i]));
    if (size + bytes > budget) {
      if (kept.length === 0) kept.push({ ...messages[i], text: messages[i].text.slice(0, Math.floor(budget / 4)) });
      break;
    }
    kept.unshift(messages[i]);
    size += bytes;
  }
  return kept;
}

const statusFor: Record<Extract<ProviderEvent, { type: "error" }>["kind"], Status> = {
  signedOut: "signedOut",
  limit: "limit",
  programEnded: "programEnded",
  programsOff: "programsOff",
  other: "error",
};

export function createAssistant(deps: Dependencies) {
  const { provider, conversation } = deps;
  const { storage, panel, log } = deps.singularity;

  let messages: Message[] = [];
  let status: Status = "starting";
  let models: { id: string; name: string }[] = [];
  let providerModel: string | null = null;
  let chosenModel: string | undefined;
  let billing: "plan" | "api" | null = null;
  let storedBilling: "plan" | "api" | undefined;
  let billingNoticeSeen = true;
  let configFolder = "";
  let providerVersion = "";
  let error: string | null = null;
  let version = 0;
  let session: string | undefined;

  /** A message sent while the billing notice waits for OK. */
  let held: string | null = null;
  let started = false;
  let loading: Promise<void> | null = null;
  /** Counts the messages sent to the provider, so a late Stop timer knows its turn is over. */
  let turn = 0;
  let stopTimer: ReturnType<typeof setTimeout> | null = null;

  /** Saves the conversation now rather than after the file's short delay. */
  const flush = () => void conversation.flush().catch((e: unknown) => log("couldn't save the conversation: " + String(e)));

  function clearStopTimer(): void {
    if (stopTimer !== null) clearTimeout(stopTimer);
    stopTimer = null;
  }

  /**
   * After Stop the answer normally ends at once (`done`). If it doesn't within a few seconds, the
   * provider is started again; the conversation and its session are kept, so nothing is lost.
   */
  function armStopTimer(): void {
    clearStopTimer();
    const stopped = turn;
    stopTimer = setTimeout(() => {
      stopTimer = null;
      if (status !== "answering" || turn !== stopped) return;
      log("no end of the answer after Stop; starting again");
      restartProvider();
      changed();
      postState();
    }, deps.stopWaitMs ?? STOP_WAIT_MS);
  }

  /** Writes to storage in the background; a failure is logged (the value is still used now). */
  const store = (key: string, value: unknown) => {
    storage.set(key, value).catch((e: unknown) => log("storage: couldn't save " + key + ": " + String(e)));
  };
  const unstore = (key: string) => {
    storage.delete(key).catch((e: unknown) => log("storage: couldn't remove " + key + ": " + String(e)));
  };

  /** Reads the saved state once. A failed read is not kept: the next request tries again. */
  function load(): Promise<void> {
    if (loading !== null) return loading;
    const attempt = (async () => {
      messages = await conversation.load();
      const text = async (key: string) => {
        const value = await storage.get(key);
        return typeof value === "string" && value !== "" ? value : undefined;
      };
      session = await text("session");
      chosenModel = await text("model");
      configFolder = (await text("configFolder")) ?? "";
      const lastBilling = await storage.get("billing");
      storedBilling = lastBilling === "plan" || lastBilling === "api" ? lastBilling : undefined;
      billingNoticeSeen = (await storage.get("billingNoticeSeen")) !== false;
    })();
    loading = attempt;
    attempt.catch(() => {
      if (loading === attempt) loading = null;
    });
    return attempt;
  }

  function state(): ViewState {
    return {
      messages: fitMessages(messages),
      status,
      model: chosenModel ?? providerModel,
      models,
      billing,
      billingNoticeSeen,
      configFolder,
      providerVersion,
      sdkVersion: deps.sdkVersion,
      error,
      version,
    };
  }

  function changed(): void {
    version += 1;
  }

  function postState(): void {
    try {
      panel.post({ type: "state", ...state() });
    } catch (e) {
      log("couldn't send the state to the page: " + String(e));
    }
  }

  function startProvider(): void {
    status = "starting";
    error = null;
    provider.start({ resume: session, model: chosenModel, configFolder: configFolder || undefined }, onEvent);
  }

  function restartProvider(): void {
    dropHeld();
    clearStopTimer();
    provider.stop();
    startProvider();
  }

  /**
   * A message held for the billing notice was never sent: an error or a restart takes it out of
   * the list again (the user types it again once the Assistant is ready).
   */
  function dropHeld(): void {
    if (held === null) return;
    const last = messages.at(-1);
    if (last && last.role === "user" && last.text === held) messages.pop();
    conversation.update(messages);
    held = null;
  }

  function onEvent(event: ProviderEvent): void {
    switch (event.type) {
      case "ready":
        models = event.models;
        providerModel = event.model;
        providerVersion = event.providerVersion;
        noteBilling(event.billing);
        if (status === "starting") status = "ready";
        break;
      case "text": {
        const last = messages.at(-1);
        if (last && last.role === "assistant" && !last.stale) messages[messages.length - 1] = { ...last, text: last.text + event.delta };
        else messages.push({ role: "assistant", text: event.delta });
        conversation.update(messages);
        changed();
        try {
          panel.post({ type: "delta", text: event.delta, version });
        } catch (e) {
          log("couldn't send a piece of the answer to the page: " + String(e));
        }
        return;
      }
      case "done":
        clearStopTimer();
        if (status === "answering") status = "ready";
        flush();
        break;
      case "error":
        clearStopTimer();
        if (event.resumeFailed) {
          // The earlier conversation can't be continued: the provider goes on with a new one.
          // Keep what the user saw, greyed out, and forget the old session. (Only this flag means
          // that; any other error keeps the session and the messages as they are.) It may come
          // at the first message (the program found no such conversation then): the new one
          // reports `ready` again.
          messages = markStale(messages);
          session = undefined;
          unstore("session");
          status = "starting";
          conversation.update(messages);
          flush();
          break;
        }
        status = statusFor[event.kind];
        error = event.kind === "other" ? event.message.slice(0, 2000) : null;
        dropHeld();
        flush();
        log("provider error: " + event.kind);
        break;
      case "session":
        if (event.id !== session) {
          session = event.id;
          store("session", event.id);
        }
        return; // nothing the page shows
    }
    changed();
    postState();
  }

  /** A new billing (API the first time, or a change) shows the notice once and holds sending. */
  function noteBilling(next: "plan" | "api"): void {
    billing = next;
    if (next === storedBilling) return;
    if (storedBilling !== undefined || next === "api") {
      billingNoticeSeen = false;
      store("billingNoticeSeen", false);
    }
    storedBilling = next;
    store("billing", next);
  }

  function sendNow(text: string): void {
    status = "answering";
    error = null;
    turn += 1;
    provider.send(text);
  }

  async function handle(payload: unknown): Promise<unknown> {
    if (payload === null || typeof payload !== "object") return { error: "unknown request" };
    const message = payload as Record<string, unknown>;
    await load();
    switch (message.type) {
      case "hello":
        if (!started) {
          started = true;
          startProvider();
          changed();
        }
        return state();

      case "send": {
        if (typeof message.text !== "string") return { error: "unknown request" };
        const text = message.text.trim();
        if (text === "") return { error: "There's nothing to send." };
        if (text.length > MAX_TEXT_LENGTH) return { error: "That message is too long." };
        if (held !== null) return { error: "Press OK on the note above first." };
        if (status !== "ready") return { error: "The Assistant isn't ready for a message." };
        messages.push({ role: "user", text });
        conversation.update(messages);
        // Saved now: a quit right after sending must not lose it (Claude's session has it).
        flush();
        if (billingNoticeSeen) sendNow(text);
        else held = text;
        changed();
        return state();
      }

      case "stop":
        if (status === "answering") {
          provider.interrupt();
          armStopTimer();
        }
        return state();

      case "newChat":
        clearStopTimer();
        provider.stop();
        // Until the new start: a message sent meanwhile is refused (visibly), not dropped.
        status = "starting";
        held = null;
        messages = [];
        session = undefined;
        try {
          await conversation.delete();
          await storage.delete("session");
        } catch (e) {
          log("New Chat couldn't remove the old conversation: " + String(e));
        } finally {
          // Whatever happened above, the provider must run again.
          started = true;
          startProvider();
          changed();
        }
        return state();

      case "setModel": {
        if (typeof message.id !== "string" || !models.some((m) => m.id === message.id)) return { error: "That model isn't available." };
        chosenModel = message.id;
        store("model", message.id);
        provider.setModel(message.id);
        changed();
        return state();
      }

      case "setConfigFolder": {
        if (typeof message.path !== "string") return { error: "unknown request" };
        const path = message.path.trim();
        // The program gets it as it is (no shell), so "~" would not mean the home folder.
        if (path !== "" && (!path.startsWith("/") || path.length > MAX_PATH_LENGTH || /[\0\n\r]/.test(path))) {
          return { error: "Use a full path that starts with /, or leave it empty." };
        }
        configFolder = path;
        store("configFolder", path);
        if (started) restartProvider();
        changed();
        return state();
      }

      case "retry":
        // Any time no answer is on its way (also while "starting", in case a start never finishes).
        if (status !== "ready" && status !== "answering") {
          restartProvider();
          changed();
        }
        return state();

      case "billingSeen":
        billingNoticeSeen = true;
        store("billingNoticeSeen", true);
        if (held !== null && status === "ready") {
          const text = held;
          held = null;
          sendNow(text);
        }
        changed();
        return state();

      default:
        return { error: "unknown request" };
    }
  }

  return { handle };
}

// ---- Wiring (the real thing) ------------------------------------------------------------------

const assistant = createAssistant({
  singularity,
  provider: createClaudeProvider({
    spawn: singularity.spawn,
    // Loaded when the panel first asks, so the plugin itself starts quickly.
    loadQuery: async () => (await import("@anthropic-ai/claude-agent-sdk")).query as unknown as QueryFunction,
    log: singularity.log,
  }),
  // HOME is the plugin's data folder.
  conversation: new ConversationFile(process.env.HOME ?? "."),
  sdkVersion: claudeSDKVersion,
});

singularity.onPageMessage(({ tabID, payload }) => {
  // Only the plugin's own page talks to it (it has no page script on websites).
  if (tabID !== "panel") return { error: "unknown request" };
  return assistant.handle(payload);
});
