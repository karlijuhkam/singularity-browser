// The seam between the Assistant and whatever answers it. Everything that knows about one
// particular program (today only Claude, in provider-claude.ts) sits behind this interface; the
// rest of the plugin (background.ts, the page) uses only what is here. A second provider later is
// one more file like provider-claude.ts plus one more name in plugin.json's `programs`.

export type ProviderEvent =
  /**
   * The program is running and can take a message. Sent once it has started, and again whenever
   * one of these values changes (for example the program reports the model it really used, or how
   * it is signed in, at the start of a turn).
   * - `billing`: "plan" when it uses a subscription sign-in, "api" when an API account pays.
   * - `models`: what the user may choose from; `model` is the one in use (an `id` of `models`,
   *   or the program's own name for it).
   */
  | { type: "ready"; model: string; billing: "plan" | "api"; models: { id: string; name: string }[]; providerVersion: string }
  /** A piece of the answer being written. */
  | { type: "text"; delta: string }
  /** The answer is complete (also after `interrupt`). */
  | { type: "done" }
  /**
   * Something went wrong. After `signedOut`, `limit`, `programEnded` and `programsOff` nothing more
   * comes until `start` is called again. A turn ends with either `done` or `error`, never both.
   *
   * If the conversation given as `resume` can't be continued, the provider sends exactly one
   * `error` of kind `other` *before its first `ready`*, then goes on by itself with a new
   * conversation (a new `session` follows with the first answer).
   */
  | { type: "error"; kind: "signedOut" | "limit" | "programEnded" | "programsOff" | "other"; message: string }
  /** The id under which the program keeps this conversation; give it as `resume` to continue it. */
  | { type: "session"; id: string };

export interface Provider {
  /** Starts the program (ending one that runs). Events arrive through `emit` until `stop`. */
  start(options: { resume?: string; model?: string; configFolder?: string }, emit: (e: ProviderEvent) => void): void;
  /** Sends the user's message; the answer arrives as `text` events, then `done`. */
  send(text: string): void;
  /** Asks the program to stop the answer it is writing. */
  interrupt(): void;
  /** Uses another model from the next answer on. */
  setModel(id: string): void;
  /** Ends the program. No events arrive after this. */
  stop(): void;
}
