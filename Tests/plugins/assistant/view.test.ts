// Tests for Plugins/assistant/view.ts (what the panel shows). Run from the repo root:
// Vendor/bun/bun test Tests/plugins/assistant
import { expect, test } from "bun:test";
import {
  applyDelta,
  billingLabel,
  billingNotice,
  canEdit,
  canType,
  EMPTY_CHAT,
  firstStaleIndex,
  keyAction,
  STALE_LINE,
  START_RETRY_AFTER_MS,
  statusNotice,
  type ViewState,
} from "../../../Plugins/assistant/view.ts";

const state = (fields: Partial<ViewState> = {}): ViewState => ({
  messages: [],
  status: "ready",
  model: "default",
  models: [],
  billing: "plan",
  billingNoticeSeen: true,
  configFolder: "",
  providerVersion: "2.1.323",
  sdkVersion: "0.3.323",
  error: null,
  version: 5,
  ...fields,
});

test("state texts, exactly", () => {
  expect(statusNotice(state({ status: "signedOut" }))).toEqual({
    text: "Claude isn't signed in on this Mac. Open a terminal tab, run claude and sign in, then press Try Again.",
    retry: true,
  });
  expect(statusNotice(state({ status: "limit" }))).toEqual({ text: "Your Claude usage limit is reached. Try again later.", retry: true });
  expect(statusNotice(state({ status: "programEnded" }))).toEqual({ text: "The connection to Claude ended.", retry: true });
  expect(statusNotice(state({ status: "programsOff" }))).toEqual({ text: "Programs are off in this test copy of Singularity.", retry: false });
  expect(statusNotice(state({ status: "error", error: "Something odd" }))).toEqual({ text: "Something odd", retry: true });
  expect(statusNotice(state({ status: "ready" }))).toBeNull();
  expect(statusNotice(state({ status: "answering" }))).toBeNull();
  expect(EMPTY_CHAT).toBe("Ask anything. In this version the Assistant can't see your pages or act for you yet.");
  expect(STALE_LINE).toBe("Earlier conversation. The Assistant no longer remembers it.");
});

test("billing label and notice", () => {
  expect(billingLabel("plan")).toBe("Claude plan");
  expect(billingLabel("api")).toBe("API billing");
  expect(billingLabel(null)).toBe("");
  expect(billingNotice(state({ billing: "api", billingNoticeSeen: false }))).toBe(
    "This chat is billed to an API account, not a Claude plan.",
  );
  expect(billingNotice(state({ billing: "plan", billingNoticeSeen: false }))).toBe("This chat now uses your Claude plan.");
  expect(billingNotice(state({ billing: "api", billingNoticeSeen: true }))).toBeNull();
});

test("sending only while ready; the input takes typing while an answer is written too", () => {
  expect(canType("ready")).toBe(true);
  for (const status of ["starting", "answering", "signedOut", "limit", "programEnded", "programsOff", "error"] as const) {
    expect(canType(status)).toBe(false);
  }
  expect(canEdit("ready")).toBe(true);
  expect(canEdit("answering")).toBe(true);
  for (const status of ["starting", "signedOut", "limit", "programEnded", "programsOff", "error"] as const) {
    expect(canEdit(status)).toBe(false);
  }
  expect(START_RETRY_AFTER_MS).toBe(15_000);
});

test("Return sends, Shift-Return makes a new line", () => {
  expect(keyAction({ key: "Enter", shiftKey: false, isComposing: false })).toBe("send");
  expect(keyAction({ key: "Enter", shiftKey: true, isComposing: false })).toBe("newline");
  // While an input method is composing, Return belongs to it.
  expect(keyAction({ key: "Enter", shiftKey: false, isComposing: true })).toBe("newline");
  // WebKit's Return that confirms an input method's text: isComposing false, keyCode 229.
  expect(keyAction({ key: "Enter", shiftKey: false, isComposing: false, keyCode: 229 })).toBe("newline");
  expect(keyAction({ key: "Enter", shiftKey: false, isComposing: false, keyCode: 13 })).toBe("send");
  expect(keyAction({ key: "a", shiftKey: false, isComposing: false })).toBe("other");
});

test("a delta is added to the answer being written", () => {
  const before = state({ status: "answering", messages: [{ role: "user", text: "Hi" }] });
  const one = applyDelta(before, { text: "Hel", version: 6 })!;
  expect(one.messages).toEqual([{ role: "user", text: "Hi" }, { role: "assistant", text: "Hel" }]);
  const two = applyDelta(one, { text: "lo", version: 7 })!;
  expect(two.messages.at(-1)).toEqual({ role: "assistant", text: "Hello" });
  expect(two.version).toBe(7);
  expect(before.messages.length).toBe(1);
  // A missed change: the page must ask for the whole state again.
  expect(applyDelta(two, { text: "!", version: 9 })).toBeNull();
  // Already in the state (a newer state came first): nothing changes.
  expect(applyDelta(two, { text: "lo", version: 7 })).toBe(two);
});

test("where the stale line goes", () => {
  expect(firstStaleIndex([{ role: "user", text: "a" }])).toBe(-1);
  expect(
    firstStaleIndex([
      { role: "user", text: "a", stale: true },
      { role: "assistant", text: "b", stale: true },
      { role: "user", text: "c" },
    ]),
  ).toBe(0);
});
