// Compiles, but its top-level code throws while the file is being loaded.
throw new Error("could not set up at load");

export default {
  async fetch(): Promise<Response> {
    return new Response("unreachable");
  },
};
