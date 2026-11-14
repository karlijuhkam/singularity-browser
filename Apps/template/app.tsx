/** @jsxImportSource preact */
// The app's page. Singularity compiles this file when the tab asks for it: no build step.
// The line above makes JSX use Preact; "preact" and its two sub-paths come from importmap.json.
//
// Two rules for every page of an app:
//   - URLs to the Worker are relative: fetch("api/notes"), never fetch("/api/notes").
//   - Routes inside the page are hash routes (#/settings), never paths.
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";

type Note = { id: number; text: string; created_at: string };

/** Calls the Worker. Throws an Error with the API's own message when the answer is not 2xx. */
async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init);
  const text = await response.text();
  if (!response.ok) {
    // The Worker answers errors as { "error": "…" }; Singularity's own errors are plain text.
    let message = text;
    try {
      message = JSON.parse(text).error ?? text;
    } catch {}
    throw new Error(message || `The request failed (${response.status}).`);
  }
  return (text === "" ? undefined : JSON.parse(text)) as T;
}

function App() {
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState("");

  /** Runs one call to the API and shows what went wrong, if anything. */
  async function attempt(work: () => Promise<void>) {
    try {
      await work();
      setError("");
    } catch (problem) {
      setError(problem instanceof Error ? problem.message : String(problem));
    }
  }

  const load = () => attempt(async () => setNotes(await api<Note[]>("api/notes")));

  useEffect(() => {
    void load();
  }, []);

  function add(event: Event) {
    event.preventDefault();
    void attempt(async () => {
      await api<Note>("api/notes", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: draft }),
      });
      setDraft("");
      await load();
    });
  }

  function remove(note: Note) {
    void attempt(async () => {
      await api<void>(`api/notes/${note.id}`, { method: "DELETE" });
      await load();
    });
  }

  return (
    <main>
      <h1>Notes</h1>

      <form onSubmit={add}>
        <input
          value={draft}
          onInput={(event) => setDraft((event.target as HTMLInputElement).value)}
          placeholder="Write a note"
          aria-label="New note"
          autofocus
        />
        <button type="submit">Add</button>
      </form>

      {error !== "" && <pre class="error" role="alert">{error}</pre>}

      {notes === null ? (
        error === "" && <p class="quiet">Loading…</p>
      ) : notes.length === 0 ? (
        <p class="quiet">No notes yet.</p>
      ) : (
        <ul>
          {notes.map((note) => (
            <li key={note.id}>
              <span class="text">{note.text}</span>
              <time dateTime={note.created_at}>{new Date(note.created_at).toLocaleString()}</time>
              <button type="button" onClick={() => remove(note)} aria-label={`Delete “${note.text}”`}>
                Delete
              </button>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}

// The page's styles. (A script can't import a .css file here; a <style> element can hold it.)
const style = document.createElement("style");
style.textContent = `
  :root {
    color-scheme: light dark;
    --text: #1d1d1f; --quiet: #6e6e73; --line: #d2d2d7; --page: #ffffff; --field: #ffffff; --bad: #b3261e;
  }
  @media (prefers-color-scheme: dark) {
    :root { --text: #f5f5f7; --quiet: #98989d; --line: #3a3a3c; --page: #1c1c1e; --field: #2c2c2e; --bad: #ff8a80; }
  }
  body { margin: 0; background: var(--page); color: var(--text); font: 15px/1.45 -apple-system, system-ui, sans-serif; }
  main { max-width: 34rem; margin: 0 auto; padding: 2.5rem 1.25rem; }
  h1 { margin: 0 0 1rem; font-size: 1.5rem; }
  form { display: flex; gap: 0.5rem; }
  input, button { font: inherit; color: inherit; border: 1px solid var(--line); border-radius: 6px; background: var(--field); }
  input { flex: 1; min-width: 0; padding: 0.45rem 0.6rem; }
  button { padding: 0.45rem 0.8rem; cursor: pointer; }
  ul { list-style: none; margin: 1rem 0 0; padding: 0; }
  li { display: flex; align-items: baseline; gap: 0.75rem; padding: 0.6rem 0; border-top: 1px solid var(--line); }
  li .text { flex: 1; min-width: 0; overflow-wrap: anywhere; white-space: pre-wrap; }
  li button { padding: 0.15rem 0.5rem; font-size: 0.85rem; }
  time, .quiet { color: var(--quiet); font-size: 0.85rem; white-space: nowrap; }
  .quiet { margin: 1rem 0 0; }
  .error { margin: 1rem 0 0; color: var(--bad); font: inherit; white-space: pre-wrap; overflow-wrap: anywhere; }
`;
document.head.append(style);

render(<App />, document.getElementById("root")!);
