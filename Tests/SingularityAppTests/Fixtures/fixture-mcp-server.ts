// A tiny MCP server over stdio, for the opt-in RealAssistantTests only: newline-delimited JSON-RPC.
// One tool, `alpha.ping`, with no arguments; it answers "pong-alpha-7391". Run with the
// repository's Bun: bun fixture-mcp-server.ts

type Message = { jsonrpc?: string; id?: number | string; method?: string; params?: { protocolVersion?: string; name?: string } };

function send(message: object): void {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}

function handle(message: Message): void {
  // A message without an id is a notification: nothing to answer.
  if (message.id === undefined || message.method === undefined) return;
  const { id } = message;
  switch (message.method) {
    case "initialize":
      send({
        id,
        result: {
          protocolVersion: message.params?.protocolVersion ?? "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "singularity", version: "0" },
        },
      });
      break;
    case "tools/list":
      send({
        id,
        result: {
          tools: [{
            name: "alpha.ping",
            description: "Answers with a fixed text. Takes no arguments.",
            inputSchema: { type: "object", properties: {}, additionalProperties: false },
          }],
        },
      });
      break;
    case "tools/call":
      if (message.params?.name === "alpha.ping") {
        send({ id, result: { content: [{ type: "text", text: "pong-alpha-7391" }] } });
      } else {
        send({ id, error: { code: -32602, message: `Unknown tool ${message.params?.name ?? ""}` } });
      }
      break;
    case "ping":
      send({ id, result: {} });
      break;
    default:
      // A method this server doesn't have (a client may probe resources or prompts).
      send({ id, error: { code: -32601, message: "Method not found" } });
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  buffer += chunk;
  let newline = buffer.indexOf("\n");
  while (newline >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line) {
      try { handle(JSON.parse(line) as Message); } catch { /* not JSON: ignore */ }
    }
    newline = buffer.indexOf("\n");
  }
});
process.stdin.on("end", () => process.exit(0));
