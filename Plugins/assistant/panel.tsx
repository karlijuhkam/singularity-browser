/** @jsxImportSource preact */
// The Assistant's own page, shown in Singularity's side panel or in a tab. It only draws: the
// state comes from background.ts (see the message list there), and what it shows is decided in
// view.ts. Everything Claude writes is shown as text: answers go through markdown.ts, which builds
// DOM nodes and never inserts HTML; everything else is a Preact text child, which is escaped.
//
// The page runs under a strict policy (no network, no inline scripts, only its own files), and
// talks to the background only through window.singularity.send / onMessage.
import { Fragment, render } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { Message, ToolLine } from "./conversation.ts";
import { chipText, mayWaitForOK, WAITING_AFTER_MS, WAITING_SUFFIX } from "./front.ts";
import { render as renderMarkdown } from "./markdown.ts";
import {
  applyDelta,
  BROWSER_PROBLEM,
  billingLabel,
  billingNotice,
  canEdit,
  canType,
  EMPTY_CHAT,
  firstStaleIndex,
  keyAction,
  STALE_LINE,
  START_RETRY_AFTER_MS,
  STARTING,
  statusNotice,
  versionsLine,
  type ViewState,
} from "./view.ts";

declare global {
  interface Window {
    singularity: {
      send(payload: unknown): Promise<unknown>;
      onMessage(handler: (payload: unknown) => void): void;
    };
  }
}

// A script page gets a plain shell page from Singularity, with no stylesheet in it. The page's
// policy allows styles from the plugin's own folder, so the stylesheet is added from here.
const stylesheet = document.createElement("link");
stylesheet.rel = "stylesheet";
stylesheet.href = "./panel.css";
document.head.appendChild(stylesheet);

/** A message to the background: its `type` and its fields (see background.ts). */
type Payload = { type: string; [field: string]: unknown };

function isState(value: unknown): value is ViewState {
  const v = value as Partial<ViewState> | null;
  return v !== null && typeof v === "object" && Array.isArray(v.messages) && typeof v.status === "string"
    && typeof v.version === "number" && Array.isArray(v.models);
}

function errorOf(value: unknown): string | null {
  const error = (value as { error?: unknown } | null)?.error;
  return typeof error === "string" ? error : null;
}

function App() {
  const [state, setState] = useState<ViewState | null>(null);
  /** Why there is no state yet (the plugin didn't answer the first hello). */
  const [problem, setProblem] = useState<string | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const resyncing = useRef(false);

  /** Takes a state unless a newer one is already shown. */
  const accept = (next: ViewState) => setState((current) => (current === null || next.version >= current.version ? next : current));

  /**
   * Sends a message to the background; a state in the answer is shown. Returns the answer. The
   * answer to `hello` is always taken, whatever its version: it is the whole state as it is now
   * (a background that started again counts from 0).
   */
  async function request(payload: Payload): Promise<unknown> {
    let reply: unknown;
    try {
      reply = await window.singularity.send(payload);
    } catch (error) {
      reply = { error: error instanceof Error ? error.message : String(error) };
    }
    if (isState(reply)) {
      if (payload.type === "hello") setState(reply);
      else accept(reply);
    }
    return reply;
  }

  /** The first `hello`, and Try Again after it failed. */
  async function greet() {
    setProblem(null);
    const reply = await request({ type: "hello" });
    if (!isState(reply)) setProblem(errorOf(reply) ?? "The Assistant didn't answer.");
  }

  /** Asks for the whole state again (a change was missed). */
  function resync() {
    if (resyncing.current) return;
    resyncing.current = true;
    void request({ type: "hello" }).finally(() => (resyncing.current = false));
  }

  useEffect(() => {
    window.singularity.onMessage((message: unknown) => {
      const m = message as { type?: unknown; text?: unknown; version?: unknown } | null;
      if (m?.type === "state") {
        const { type: _type, ...rest } = m as Record<string, unknown>;
        if (isState(rest)) accept(rest);
      } else if (m?.type === "front" && typeof (m as { chip?: unknown }).chip === "string") {
        const chip = (m as { chip: string }).chip;
        setState((current) => (current === null ? current : { ...current, chip }));
      } else if (m?.type === "delta" && typeof m.text === "string" && typeof m.version === "number") {
        const delta = { text: m.text, version: m.version };
        setState((current) => {
          if (current === null) return current;
          const next = applyDelta(current, delta);
          if (next === null) queueMicrotask(resync);
          return next ?? current;
        });
      }
    });
    void greet();
  }, []);

  if (state === null) {
    return (
      <div class="app">
        {problem === null
          ? <p class="notice quiet">{STARTING}</p>
          : (
            <div class="notice warn">
              <p>{problem}</p>
              <button type="button" onClick={() => void greet()}>Try Again</button>
            </div>
          )}
      </div>
    );
  }

  return (
    <div class="app">
      <Header state={state} request={request} settingsOpen={settingsOpen} toggleSettings={() => setSettingsOpen(!settingsOpen)} />
      {settingsOpen
        ? <Settings state={state} request={request} close={() => setSettingsOpen(false)} />
        : <Conversation messages={state.messages} />}
      {/* Hidden, not removed, so a half-written message survives a look at the settings. */}
      <Footer state={state} request={request} hidden={settingsOpen} />
    </div>
  );
}

type Request = (payload: Payload) => Promise<unknown>;

function Header(props: { state: ViewState; request: Request; settingsOpen: boolean; toggleSettings: () => void }) {
  const { state, request } = props;
  const options = state.models.slice();
  // The model in use may be one the menu doesn't list (Claude's own name for it).
  if (state.model && !options.some((m) => m.id === state.model)) options.push({ id: state.model, name: state.model });
  return (
    <header class="bar">
      <button type="button" class="plain" onClick={() => request({ type: "newChat" })}>New Chat</button>
      <select
        class="model"
        aria-label="Model"
        value={state.model ?? ""}
        disabled={state.models.length === 0}
        onChange={(event) => request({ type: "setModel", id: (event.currentTarget as HTMLSelectElement).value })}
      >
        {options.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
      </select>
      <span class="billing">{billingLabel(state.billing)}</span>
      <button
        type="button"
        class={props.settingsOpen ? "plain icon active" : "plain icon"}
        aria-label="Settings"
        aria-pressed={props.settingsOpen}
        onClick={props.toggleSettings}
      >
        {"⚙︎"}
      </button>
    </header>
  );
}

function Conversation({ messages }: { messages: Message[] }) {
  const list = useRef<HTMLElement>(null);
  // Follow the answer as it grows, unless the user scrolled up to read.
  const stick = useRef(true);
  useLayoutEffect(() => {
    const element = list.current;
    if (element && stick.current) element.scrollTop = element.scrollHeight;
  }, [messages]);
  const onScroll = () => {
    const element = list.current;
    if (element) stick.current = element.scrollHeight - element.scrollTop - element.clientHeight < 40;
  };

  const stale = firstStaleIndex(messages);
  return (
    <main class="messages" ref={list} onScroll={onScroll}>
      {messages.length === 0 && <p class="empty">{EMPTY_CHAT}</p>}
      {messages.map((message, i) => (
        <Fragment key={i}>
          {i === stale && <p class="stale-line">{STALE_LINE}</p>}
          <MessageView message={message} />
        </Fragment>
      ))}
    </main>
  );
}

function MessageView({ message }: { message: Message }) {
  const classes = "message " + message.role + (message.stale ? " stale" : "");
  if (message.role === "user") return <div class={classes}>{message.text}</div>;
  return (
    <>
      {message.text !== "" && <Answer classes={classes} text={message.text} />}
      {message.tools && message.tools.length > 0 && (
        <ul class={"tools" + (message.stale ? " stale" : "")}>
          {message.tools.map((tool, i) => <ToolItem key={i} tool={tool} />)}
        </ul>
      )}
    </>
  );
}

/** One tool line, as a text node. A call that runs for a while is probably waiting for the user's OK. */
function ToolItem({ tool }: { tool: ToolLine }) {
  const [waiting, setWaiting] = useState(false);
  useEffect(() => {
    setWaiting(false);
    if (tool.status !== "running" || !mayWaitForOK(tool.text)) return;
    const timer = setTimeout(() => setWaiting(true), WAITING_AFTER_MS);
    return () => clearTimeout(timer);
  }, [tool.status]);
  const shown = tool.status === "running" && waiting ? tool.text + WAITING_SUFFIX : tool.text;
  return <li class={"tool " + tool.status}>{shown}</li>;
}

/** An answer, drawn by markdown.ts (DOM nodes only, never HTML). Preact leaves its children alone. */
function Answer({ classes, text }: { classes: string; text: string }) {
  const box = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    box.current?.replaceChildren(...renderMarkdown(text));
  }, [text]);
  return <div class={classes} ref={box} />;
}

function Footer({ state, request, hidden }: { state: ViewState; request: Request; hidden: boolean }) {
  const [draft, setDraft] = useState("");
  /** What the background said when it refused the last request. */
  const [problem, setProblem] = useState<string | null>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const notice = statusNotice(state);
  const billing = billingNotice(state);
  const typing = canType(state.status);
  const editable = canEdit(state.status);
  const slowStart = useSlowStart(state.status, state.version);

  // When the page loads and whenever typing becomes possible again, the input takes the focus,
  // unless something else on the page has it (the settings' field, a button).
  useEffect(() => {
    const element = input.current;
    const active = document.activeElement;
    if (editable && !hidden && element && (active === null || active === document.body)) element.focus();
  }, [editable, hidden]);

  // Grow with the text, up to the limit in panel.css.
  useLayoutEffect(() => {
    const element = input.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = element.scrollHeight + "px";
  }, [draft]);

  async function send() {
    const text = draft.trim();
    if (text === "" || !typing) return;
    const reply = await ask({ type: "send", text });
    if (isState(reply)) setDraft("");
    // Stays enabled while the answer is written: ready for the next message.
    input.current?.focus();
  }

  async function ask(payload: Payload): Promise<unknown> {
    const reply = await request(payload);
    setProblem(isState(reply) ? null : errorOf(reply) ?? "The Assistant didn't answer.");
    return reply;
  }

  return (
    <footer class="footer" hidden={hidden}>
      {state.status === "starting" && (
        <div class="notice quiet">
          <p>{STARTING}</p>
          {/* A start that never finishes (no ready after 15 s) can be tried again. */}
          {slowStart && <button type="button" onClick={() => ask({ type: "retry" })}>Try Again</button>}
        </div>
      )}
      {notice && (
        <div class="notice warn">
          <p>{notice.text}</p>
          {notice.retry && <button type="button" onClick={() => ask({ type: "retry" })}>Try Again</button>}
          <p class="versions">{versionsLine(state)}</p>
        </div>
      )}
      {billing && (
        <div class="notice">
          <p>{billing}</p>
          <button type="button" onClick={() => ask({ type: "billingSeen" })}>OK</button>
        </div>
      )}
      {state.browserProblem && state.status === "ready" && (
        <div class="notice warn">
          <p>{BROWSER_PROBLEM}</p>
          <button type="button" onClick={() => ask({ type: "retry" })}>Try Again</button>
        </div>
      )}
      {problem && <p class="problem">{problem}</p>}
      {/* What the next message will carry: the tab in front, or nothing. */}
      <p class="chip">{state.chip ?? chipText(null)}</p>
      <div class="compose">
        <textarea
          ref={input}
          rows={1}
          value={draft}
          disabled={!editable}
          aria-label="Message"
          placeholder="Message"
          onInput={(event) => setDraft((event.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown={(event) => {
            if (keyAction(event) === "send") {
              event.preventDefault();
              void send();
            }
          }}
        />
        {state.status === "answering"
          ? <button type="button" onClick={() => ask({ type: "stop" })}>Stop</button>
          : <button type="button" disabled={!typing || draft.trim() === ""} onClick={() => void send()}>Send</button>}
      </div>
    </footer>
  );
}

/**
 * True once the status has been "starting" for START_RETRY_AFTER_MS with no new state (Try Again
 * makes a new one, so the wait starts over).
 */
function useSlowStart(status: ViewState["status"], version: number): boolean {
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    setSlow(false);
    if (status !== "starting") return;
    const timer = setTimeout(() => setSlow(true), START_RETRY_AFTER_MS);
    return () => clearTimeout(timer);
  }, [status, version]);
  return slow;
}

function Settings({ state, request, close }: { state: ViewState; request: Request; close: () => void }) {
  const [folder, setFolder] = useState(state.configFolder);
  /** "Saved." or why it wasn't. */
  const [result, setResult] = useState<string | null>(null);

  async function save() {
    const reply = await request({ type: "setConfigFolder", path: folder });
    setResult(isState(reply) ? "Saved." : errorOf(reply) ?? "The Assistant didn't answer.");
  }

  return (
    <section class="settings">
      <label class="field">
        <span>Claude config folder</span>
        <input
          type="text"
          value={folder}
          placeholder="Default"
          spellcheck={false}
          onInput={(event) => {
            setFolder((event.currentTarget as HTMLInputElement).value);
            setResult(null);
          }}
          onKeyDown={(event) => {
            if (event.key === "Enter") void save();
          }}
        />
      </label>
      <p class="hint">Only for keeping several Claude accounts apart. Leave it empty for Claude's usual folder.</p>
      <div class="row">
        <button type="button" disabled={folder.trim() === state.configFolder} onClick={() => void save()}>Save</button>
        {result && <span class="hint">{result}</span>}
      </div>
      <p class="versions">{versionsLine(state)}</p>
      <div class="row">
        <button type="button" onClick={close}>Done</button>
      </div>
    </section>
  );
}

render(<App />, document.getElementById("root")!);
