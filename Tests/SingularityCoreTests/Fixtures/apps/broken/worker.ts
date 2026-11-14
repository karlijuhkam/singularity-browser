export default {
  async fetch(request: Request) {
    return new Response("never" // a missing parenthesis: this file does not parse
  },
};
