// What the Assistant's page shows, as plain functions (panel.tsx only draws it). The state comes
// from background.ts: its `hello` answer and its `state` messages, changed in between by `delta`s.
import type { Message } from "./conversation.ts";

export type Status = "starting" | "ready" | "answering" | "signedOut" | "limit" | "programEnded" | "programsOff" | "error";

export type ViewState = {
  messages: Message[];
  status: Status;
  model: string | null;
  models: { id: string; name: string }[];
  billing: "plan" | "api" | null;
  billingNoticeSeen: boolean;
  configFolder: string;
  providerVersion: string;
  sdkVersion: string;
  /** The program's own words for a failure of kind "other" (status "error"). */
  error: string | null;
  /** Counts every change; a `delta` carries the number it makes. */
  version: number;
};

export const EMPTY_CHAT = "Ask anything. In this version the Assistant can't see your pages or act for you yet.";
export const STALE_LINE = "Earlier conversation. The Assistant no longer remembers it.";
export const STARTING = "Connecting to Claude…";

/** The line shown instead of the input's normal state, and whether it has a Try Again button. */
export function statusNotice(state: ViewState): { text: string; retry: boolean } | null {
  switch (state.status) {
    case "signedOut":
      return { text: "Claude isn't signed in on this Mac. Open a terminal tab, run claude and sign in, then press Try Again.", retry: true };
    case "limit":
      return { text: "Your Claude usage limit is reached. Try again later.", retry: true };
    case "programEnded":
      return { text: "The connection to Claude ended.", retry: true };
    case "programsOff":
      return { text: "Programs are off in this test copy of Singularity.", retry: false };
    case "error":
      return { text: state.error || "Something went wrong.", retry: true };
    default:
      return null;
  }
}

export function billingLabel(billing: ViewState["billing"]): string {
  if (billing === "plan") return "Claude plan";
  if (billing === "api") return "API billing";
  return "";
}

/** Shown once before the next message when the billing is new (API) or changed. */
export function billingNotice(state: ViewState): string | null {
  if (state.billingNoticeSeen || state.billing === null) return null;
  return state.billing === "api"
    ? "This chat is billed to an API account, not a Claude plan."
    : "This chat now uses your Claude plan.";
}

export function canType(status: Status): boolean {
  return status === "ready";
}

/** Return sends, Shift-Return makes a new line; while an input method composes, Return is its own. */
export function keyAction(event: { key: string; shiftKey: boolean; isComposing: boolean }): "send" | "newline" | "other" {
  if (event.key !== "Enter") return "other";
  return event.shiftKey || event.isComposing ? "newline" : "send";
}

/**
 * The state with a piece of the answer added: to the answer being written (the last message, when
 * it is the Assistant's), or as a new answer. The same state when the piece is already in it (a
 * newer state came first). null when a change was missed (the delta's number is past the next
 * one): then the page asks for the whole state again.
 */
export function applyDelta(state: ViewState, delta: { text: string; version: number }): ViewState | null {
  if (delta.version <= state.version) return state;
  if (delta.version !== state.version + 1) return null;
  const messages = state.messages.slice();
  const last = messages.at(-1);
  if (last && last.role === "assistant" && !last.stale) messages[messages.length - 1] = { ...last, text: last.text + delta.text };
  else messages.push({ role: "assistant", text: delta.text });
  return { ...state, messages, version: delta.version };
}

/** Where the "no longer remembers" line goes: before the first stale message; -1 for none. */
export function firstStaleIndex(messages: Message[]): number {
  return messages.findIndex((m) => m.stale);
}

/** "Claude 2.1.323 · SDK 0.3.323", for the settings view and the error states. */
export function versionsLine(state: ViewState): string {
  return `Claude ${state.providerVersion || "unknown"} · SDK ${state.sdkVersion || "unknown"}`;
}
