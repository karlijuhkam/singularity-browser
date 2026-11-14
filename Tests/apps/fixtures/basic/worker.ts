// The fixture Worker of Tests/apps/host.test.ts: one small route per thing the host must do.
// Written as a Worker for Cloudflare would be; nothing here knows about Singularity.

type Statement = {
  bind(...values: unknown[]): Statement;
  all(): Promise<{ results: Record<string, unknown>[] }>;
  run(): Promise<{ meta: { last_row_id: number } }>;
};
type Env = {
  DB: { prepare(sql: string): Statement };
  GREETING?: string;
  SHADOWED?: string;
  LIMITS?: { max: number };
  API_KEY?: string;
  NOPE?: string;
  ALSO_NOPE?: string;
};
type Context = { waitUntil(promise: Promise<unknown>): void; passThroughOnException(): void };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

console.log("worker module loaded");

export default {
  async fetch(request: Request, env: Env, ctx: Context): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/hello":
        return new Response("hello", { status: 201, headers: { "x-app": "basic", "content-type": "text/plain" } });

      // What the Worker was given, so the test can compare it with what it sent.
      case "/echo":
        return Response.json({
          method: request.method,
          url: request.url,
          headers: [...request.headers],
          body: await request.text(),
        });

      // The request's bytes, back as they came.
      case "/echo-bytes":
        return new Response(await request.arrayBuffer(), { headers: { "content-type": "application/octet-stream" } });

      case "/throw":
        throw new Error("kaboom in the worker");

      case "/not-a-response":
        return "just text" as unknown as Response;

      case "/log":
        console.log("a log line", { count: 2 });
        console.warn("a warning");
        console.error("an error line");
        process.stdout.write("a raw print\n");
        return new Response("logged");

      case "/cookies": {
        const headers = new Headers({ "content-type": "text/plain" });
        headers.append("set-cookie", "a=1; Path=/");
        headers.append("set-cookie", "b=2; Path=/; HttpOnly");
        return new Response("cookies", { headers });
      }

      // Answers after ?ms= milliseconds with ?tag=, for the test of requests running side by side.
      case "/slow":
        await sleep(Number(url.searchParams.get("ms")));
        return new Response(url.searchParams.get("tag"));

      // Makes an outside request and reports what came back (or how it failed).
      case "/fetch": {
        try {
          const answer = await fetch(url.searchParams.get("to")!, {
            method: "POST",
            headers: { "x-from": "worker", authorization: `Bearer ${env.API_KEY}` },
            body: "outgoing body",
          });
          return Response.json({
            status: answer.status,
            statusText: answer.statusText,
            ok: answer.ok,
            url: answer.url,
            headers: [...answer.headers],
            cookies: answer.headers.getSetCookie(),
            body: await answer.text(),
          });
        } catch (error) {
          return Response.json({ failed: (error as Error).message, name: (error as Error).name }, { status: 502 });
        }
      }

      // An outside request with no body, and its answer's bytes passed on untouched.
      case "/fetch-bytes": {
        const answer = await fetch(url.searchParams.get("to")!);
        return new Response(await answer.arrayBuffer());
      }

      case "/env":
        return Response.json({
          greeting: env.GREETING,
          shadowed: env.SHADOWED,
          limits: env.LIMITS,
          key: env.API_KEY,
          // Read twice: the host must report it once.
          nope: [env.NOPE === undefined, env.NOPE === undefined],
          alsoNope: env.ALSO_NOPE === undefined,
          hasDB: typeof env.DB.prepare,
          // None of these may be reported as a missing key.
          text: JSON.stringify(env).length > 0 && String(Object.keys(env).length),
        });

      case "/notes": {
        if (request.method === "POST") {
          const done = await env.DB.prepare("INSERT INTO notes (title) VALUES (?)").bind(await request.text()).run();
          return Response.json({ id: done.meta.last_row_id }, { status: 201 });
        }
        const { results } = await env.DB.prepare("SELECT id, title FROM notes ORDER BY id").all();
        return Response.json(results);
      }

      // Answers at once; the row is written 300 ms later. `stop` must wait for it.
      case "/wait":
        ctx.waitUntil(sleep(300).then(() => env.DB.prepare("INSERT INTO notes (title) VALUES ('written after the answer')").run()));
        ctx.passThroughOnException();
        return new Response("answered first");

      case "/wait-forever":
        ctx.waitUntil(new Promise(() => {}));
        return new Response("waiting forever");

      case "/wait-rejected":
        ctx.waitUntil(Promise.reject(new Error("background work failed")));
        return new Response("ok");

      default:
        return new Response("no such route: " + url.pathname, { status: 404 });
    }
  },
};
