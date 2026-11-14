// The fixture Worker behind AppWorkerProcessTests and the app tests: one route per thing a
// test needs to see.
import { helper } from "./helper";

export default {
  async fetch(request: Request, env: any, ctx: any): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/api/hello":
        return Response.json({ hello: env.GREETING, helper: helper(), path: url.pathname });

      // What the Worker was given, so tests can check what reached it (and what did not).
      case "/api/echo":
        return Response.json({
          method: request.method,
          url: request.url,
          headers: [...request.headers.entries()],
          body: await request.text(),
        });

      case "/api/notes": {
        if (request.method === "POST") {
          const text = await request.text();
          const result = await env.DB.prepare("INSERT INTO notes (text) VALUES (?)").bind(text).run();
          return Response.json({ id: result.meta.last_row_id });
        }
        const { results } = await env.DB.prepare("SELECT id, text FROM notes ORDER BY id").all();
        return Response.json(results);
      }

      // An outside request: the answer's status, final address and text come back. With
      // `auth`, the app's key goes along as the Worker's code would send it on Cloudflare.
      case "/api/fetch": {
        try {
          const target = url.searchParams.get("url")!;
          const headers: Record<string, string> = {};
          if (url.searchParams.has("auth")) headers["Authorization"] = `Bearer ${env.API_KEY}`;
          const response = await fetch(target, { headers });
          return Response.json({ status: response.status, url: response.url, text: await response.text() });
        } catch (error) {
          return Response.json({ error: String((error as Error).message) }, { status: 502 });
        }
      }

      // The sandbox must hold: a socket opened without fetch() goes nowhere.
      case "/api/connect": {
        try {
          const bun = (globalThis as any).Bun;
          const socket = await bun.connect({
            hostname: url.searchParams.get("host") ?? "127.0.0.1",
            port: Number(url.searchParams.get("port") ?? "80"),
            socket: { data() {}, open() {}, close() {}, error() {} },
          });
          socket.end();
          return new Response("open");
        } catch {
          return new Response("denied");
        }
      }

      case "/api/env":
        return Response.json({ key: env.API_KEY ?? null, missing: env.NOPE ?? null });

      case "/api/log":
        console.log("hello from the worker", { n: 1 });
        console.error("an error line");
        return new Response("logged");

      case "/api/throw":
        throw new Error("the worker threw");

      case "/api/big":
        return new Response("x".repeat(Number(url.searchParams.get("n") ?? "0")));

      case "/api/cookies": {
        const headers = new Headers();
        headers.append("Set-Cookie", "singularity_token=stolen; Path=/");
        headers.append("Set-Cookie", "session=abc; Path=/");
        return new Response("cookies", { headers });
      }

      // Never answers: the request must time out and the process be killed.
      case "/api/loop":
        for (;;) {}

      default:
        return new Response("no route for " + url.pathname, { status: 404 });
    }
  },
};
