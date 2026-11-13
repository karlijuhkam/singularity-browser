// Background program of the Assistant plugin. It runs on Singularity's bundled Bun, in a sandbox
// with no network. It owns one Provider (today Claude, provider-claude.ts) and the conversation's
// state, and talks to the plugin's own page (panel.tsx).
//
// Messages from the page (singularity.send; every answer is the full state, or { error }):
//   { type: "hello" }                    starts the provider the first time (not at plugin start,
//                                        so nothing runs or counts against a plan until the panel opens)
//   { type: "send", text }               { type: "stop" }       { type: "newChat" }
//                                        (a stop with no end of the answer within 5 s starts the
//                                        provider again, keeping the session and the messages)
//   { type: "setModel", id }             { type: "setConfigFolder", path }   (restarts the provider)
//   { type: "retry" }                    { type: "billingSeen" }
// Pushed to the page (singularity.panel.post):
//   { type: "delta", text, version }     a piece of the answer
//   { type: "front", chip }              the tab in front changed (the chip above the input)
//   { type: "state", ...state }          after every other change the provider causes
// The state: { messages, status, model, models, billing, billingNoticeSeen, configFolder,
// providerVersion, sdkVersion, error, chip, version } (see view.ts, ViewState).
//
// Where the user is: at every send the tab in front (singularity.front()) is put, as a note
// (front.ts, frontBlock), before the user's text in what goes to the provider. The chat and
// conversation.json keep only what the user typed. The browser's tools come from
// singularity.browser.server(), asked at every start of the provider. Tool calls arrive as `tool`
// events and become lines on the answer's message (front.ts, toolLine); a tool's answer never
// reaches this file.
//
// Kept in singularity.storage: session (the conversation's id, to continue it after a restart),
// model, configFolder, billing (the last one seen) and billingNoticeSeen. The visible messages are
// in conversation.json (conversation.ts). Nothing here is secret: no tokens or keys pass through
// this plugin; the claude program keeps its own sign-in.
import { singularity } from "singularity";
import { ConversationFile, markStale, type Message, type ToolLine } from "./conversation.ts";
import { chipText, frontBlock, type FrontTab, toolLine, FAILED_SUFFIX } from "./front.ts";
import type { BrowserServer, Provider, ProviderEvent } from "./provider.ts";
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
  singularity: {
    panel: { post(payload: unknown): void };
    storage: Storage;
    log(...values: unknown[]): void;
    /** Absent in a build without these abilities: the Assistant then is the plain chat of part 1. */
    front?(): Promise<FrontTab | null>;
    onFrontChange?(handler: (front: FrontTab | null) => void): void;
    browser?: { server(): Promise<BrowserServer | null> };
  };
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
  /** The tab in front as last heard of (hello, a send, a change), for the chip. */
  let latestFront: FrontTab | null = null;
  /** The tab that was in front when the message being answered was sent (for its tool lines). */
  let frontAtSend: FrontTab | null = null;
  /** The tool lines still running, by the id `claude` gave the call. */
  const runningTools = new Map<string, ToolLine>();
  /** Counts the provider's starts, so a start waiting for the browser server can tell it was replaced. */
  let startCount = 0;

  /** A message sent while the billing notice waits for OK, and the tab in front when it was sent. */
  let held: string | null = null;
  let heldFront: FrontTab | null = null;
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
      chip: chipText(latestFront),
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
    const mine = ++startCount;
    const begin = (browser: BrowserServer | null | undefined) => {
      if (mine !== startCount) return; // stopped or started again while waiting for the server
      const options: Parameters<Provider["start"]>[0] = { resume: session, model: chosenModel, configFolder: configFolder || undefined };
      if (browser !== undefined) options.browser = browser;
      provider.start(options, onEvent);
    };
    const server = deps.singularity.browser?.server;
    if (!server) return begin(undefined);
    // No server (or one that can't be asked) means a chat without the browser's tools.
    server().then(begin, (e: unknown) => {
      log("couldn't get the browser's tools: " + String(e));
      begin(null);
    });
  }

  function restartProvider(): void {
    dropHeld();
    clearStopTimer();
    startCount += 1;
    runningTools.clear();
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

  /** A turn is over: a tool line still running never got its end, so it says "not done". */
  function settleTools(): void {
    if (runningTools.size === 0) return;
    for (const line of runningTools.values()) {
      line.text += FAILED_SUFFIX;
      line.status = "failed";
    }
    runningTools.clear();
    conversation.update(messages);
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
        // Text after tool lines is a new answer, so lines and text stay in the order they came.
        if (last && last.role === "assistant" && !last.stale && !last.tools?.length) {
          messages[messages.length - 1] = { ...last, text: last.text + event.delta };
        } else messages.push({ role: "assistant", text: event.delta });
        conversation.update(messages);
        changed();
        try {
          panel.post({ type: "delta", text: event.delta, version });
        } catch (e) {
          log("couldn't send a piece of the answer to the page: " + String(e));
        }
        return;
      }
      case "tool": {
        let line = runningTools.get(event.id);
        const text = toolLine(event.name, event.input, event.status, frontAtSend).text;
        if (line) {
          line.text = text;
          line.status = event.status;
          if (event.status !== "running") runningTools.delete(event.id);
        } else {
          line = { text, status: event.status };
          if (event.status === "running") runningTools.set(event.id, line);
          const last = messages.at(-1);
          if (last && last.role === "assistant" && !last.stale) messages[messages.length - 1] = { ...last, tools: [...(last.tools ?? []), line] };
          else messages.push({ role: "assistant", text: "", tools: [line] });
        }
        conversation.update(messages);
        break;
      }
      case "done":
        settleTools();
        clearStopTimer();
        if (status === "answering") status = "ready";
        flush();
        break;
      case "error":
        settleTools();
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

  /** Asks for the tab in front; a failure or a build without the API means nothing is shared. */
  async function currentFront(): Promise<FrontTab | null> {
    if (!deps.singularity.front) return null;
    try {
      latestFront = (await deps.singularity.front()) ?? null;
    } catch (e) {
      log("couldn't ask for the tab in front: " + String(e));
      latestFront = null;
    }
    return latestFront;
  }

  /** Sends to the provider: the note about the tab in front, when this build has one, then the text. */
  function sendNow(text: string): void {
    status = "answering";
    error = null;
    turn += 1;
    frontAtSend = heldFront;
    provider.send(deps.singularity.front ? frontBlock(frontAtSend) + "\n\n" + text : text);
  }

  async function handle(payload: unknown): Promise<unknown> {
    if (payload === null || typeof payload !== "object") return { error: "unknown request" };
    const message = payload as Record<string, unknown>;
    await load();
    switch (message.type) {
      case "hello":
        await currentFront();
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
        const front = await currentFront();
        // Checked again: another request may have come in while the tab in front was asked for.
        if (held !== null || status !== "ready") return { error: "The Assistant isn't ready for a message." };
        heldFront = front;
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
        runningTools.clear();
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

  // The chip follows the tab in front.
  deps.singularity.onFrontChange?.((front) => {
    latestFront = front;
    try {
      panel.post({ type: "front", chip: chipText(front) });
    } catch (e) {
      log("couldn't send the chip to the page: " + String(e));
    }
  });

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
