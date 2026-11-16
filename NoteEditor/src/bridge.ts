// The editor's only way out of its page: one message handler the app registers
// (`NoteHost` in Swift). The page has no network (its Content-Security-Policy forbids it), so
// loading, saving, renaming, pictures and opening links all go through here.

export type Loaded = {
  /** The note's title: its file name without ".md". */
  title: string;
  /** The file's text; "" for a note with no file yet. */
  markdown: string;
  /** False when the note's file is gone (deleted or moved outside Singularity). */
  exists: boolean;
};

export type Saved = { ok: true } | { conflict: true };

type Request =
  | { type: "load" }
  | { type: "save"; markdown: string; force: boolean }
  | { type: "rename"; title: string }
  | { type: "image"; name: string; base64: string }
  | { type: "open"; url: string };

declare global {
  interface Window {
    webkit?: { messageHandlers: { singularityNote: { postMessage(message: Request): Promise<unknown> } } };
    /** Called by the app when the note's file changed on disk. */
    __noteFileChanged?: () => void;
    /** Called by the app before the tab closes: saves what is unsaved, resolves when done. */
    __noteFlush?: () => Promise<void>;
    /** For the app's tests: the editor's text as Markdown, and typing through the editor. */
    __noteTest?: Record<string, unknown>;
  }
}

function send<T>(request: Request): Promise<T> {
  const handler = window.webkit?.messageHandlers.singularityNote;
  if (!handler) return Promise.reject(new Error("this page only works inside Singularity"));
  return handler.postMessage(request) as Promise<T>;
}

export const native = {
  load: () => send<Loaded>({ type: "load" }),
  save: (markdown: string, force = false) => send<Saved>({ type: "save", markdown, force }),
  /** Renames the note's file; resolves with the title it now has. */
  rename: (title: string) => send<{ title: string }>({ type: "rename", title }),
  /** Saves a picture next to the note; resolves with the path to write into the Markdown. */
  image: (name: string, base64: string) => send<{ src: string }>({ type: "image", name, base64 }),
  /** Opens a web address in a new tab of the note's Space. */
  open: (url: string) => send<null>({ type: "open", url }),
};
