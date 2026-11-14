// The app's Worker: the API behind the page. Ordinary Cloudflare Worker code.
//
// The Worker sees the app at the root: the page's fetch("api/notes") arrives here as /api/notes,
// in Singularity and on Cloudflare alike. Pages are files in this folder; the Worker only
// answers requests the folder has no file for.

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(request.url);
    const method = request.method;

    try {
      if (pathname === "/api/notes" && method === "GET") return await listNotes(env);
      if (pathname === "/api/notes" && method === "POST") return await addNote(request, env);

      const note = pathname.match(/^\/api\/notes\/(\d+)$/);
      if (note && method === "DELETE") return await deleteNote(Number(note[1]), env);

      // An outside call with a key. To use it: remove the comment marks here and around
      // exampleRates() below, then tell the owner the key's name (EXAMPLE_KEY) and host
      // (api.example.com). The owner types the value into the app's panel and allows the host.
      // if (pathname === "/api/rates" && method === "GET") return await exampleRates(env);

      return json({ error: `No route for ${method} ${pathname}` }, 404);
    } catch (error) {
      // Goes to worker.log in the app's data folder.
      console.error(error);
      return json({ error: error instanceof Error ? error.message : String(error) }, 500);
    }
  },
};

// ---- Routes -----------------------------------------------------------------------------------

async function listNotes(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare("SELECT id, text, created_at FROM notes ORDER BY id DESC").all<Note>();
  return json(results);
}

async function addNote(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { text?: unknown } | null;
  const text = typeof body?.text === "string" ? body.text.trim() : "";
  if (text === "") return json({ error: "A note needs some text." }, 400);
  if (text.length > 2000) return json({ error: "A note is at most 2000 characters." }, 400);

  const note = await env.DB.prepare("INSERT INTO notes (text) VALUES (?) RETURNING id, text, created_at")
    .bind(text)
    .first<Note>();
  return json(note, 201);
}

async function deleteNote(id: number, env: Env): Promise<Response> {
  const result = await env.DB.prepare("DELETE FROM notes WHERE id = ?").bind(id).run();
  if (result.meta.changes === 0) return json({ error: `There is no note ${id}.` }, 404);
  return new Response(null, { status: 204 });
}

// async function exampleRates(env: Env): Promise<Response> {
//   let response: Response;
//   try {
//     // env.EXAMPLE_KEY is a placeholder here. Singularity puts the real value in, and only
//     // into requests for the key's own host. Use it as it is: don't cut, hash or encode it.
//     response = await fetch("https://api.example.com/v1/rates", {
//       headers: { Authorization: `Bearer ${env.EXAMPLE_KEY}` },
//     });
//   } catch (error) {
//     // fetch() throws when the host is not allowed (the owner said no, or did not answer),
//     // and when the request itself failed. The message says which.
//     return json({ error: error instanceof Error ? error.message : String(error) }, 502);
//   }
//   if (!response.ok) return json({ error: `api.example.com answered ${response.status}` }, 502);
//   return json(await response.json());
// }

// ---- Helpers ----------------------------------------------------------------------------------

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

// ---- Types ------------------------------------------------------------------------------------
//
// Written out by hand, because the app has no packages. They cover what this file uses. After
// moving to Cloudflare, `wrangler types` generates the full ones and these can go.

type Note = { id: number; text: string; created_at: string };

interface Env {
  /** The database: "binding": "DB" in wrangler.jsonc. */
  DB: D1Database;
  /** A key the owner stored in the app's panel (used by the example route). */
  EXAMPLE_KEY?: string;
}

interface ExecutionContext {
  /** Work that may finish after the response was sent. */
  waitUntil(promise: Promise<unknown>): void;
}

interface D1Database {
  prepare(sql: string): D1PreparedStatement;
  /** Several statements as one transaction: all happen or none. */
  batch<T = Record<string, unknown>>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]>;
}

interface D1PreparedStatement {
  /** Values for the `?` in the SQL, in order. Returns a new statement. */
  bind(...values: unknown[]): D1PreparedStatement;
  /** The first row, or null. With a column name: that column's value. */
  first<T = Record<string, unknown>>(column?: string): Promise<T | null>;
  /** Every row, in `results`. */
  all<T = Record<string, unknown>>(): Promise<D1Result<T>>;
  /** For writes: look at `meta.changes` and `meta.last_row_id`. */
  run<T = Record<string, unknown>>(): Promise<D1Result<T>>;
}

interface D1Result<T> {
  success: true;
  results: T[];
  meta: { changes: number; last_row_id: number; [name: string]: unknown };
}
