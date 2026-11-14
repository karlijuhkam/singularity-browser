// Deliberately broken: the parenthesis on line 4 is never closed.
export default {
  async fetch() {
    return new Response("never";
  },
};
