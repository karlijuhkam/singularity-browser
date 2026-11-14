// Never loaded: the app's second migration fails first.
export default {
  async fetch(): Promise<Response> {
    return new Response("unreachable");
  },
};
