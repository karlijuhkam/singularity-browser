// A Worker with a wrangler.json (no comments), a "main" in a subfolder and no database.
export default {
  async fetch(_request: Request, env: { MODE: string; DB?: unknown }): Promise<Response> {
    return Response.json({ mode: env.MODE, db: typeof env.DB });
  },
};
