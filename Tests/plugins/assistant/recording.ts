// A recorded stream-json exchange with the claude program, written by hand from the Agent SDK's
// types (sdk.d.ts of @anthropic-ai/claude-agent-sdk 0.3.323) and the shapes seen when the SDK was
// tried by hand: what the program answers to the SDK's `initialize` request, and the lines of one
// turn. Made-up data only; no real program was run.

export const initializeResponse = {
  commands: [],
  agents: [],
  output_style: "default",
  available_output_styles: ["default"],
  models: [
    { value: "default", displayName: "Default (recommended)", description: "The model Claude picks" },
    { value: "opus", resolvedModel: "claude-opus-5-1", displayName: "Opus", description: "Most capable" },
    { value: "haiku", resolvedModel: "claude-haiku-5-0", displayName: "Haiku", description: "Fastest" },
  ],
  account: { email: "someone@example.com", subscriptionType: "max", tokenSource: "claude.ai", apiProvider: "firstParty" },
  claude_code_version: "2.1.323",
};

/** The same, signed in with an API key from the Console. */
export const initializeResponseAPI = {
  ...initializeResponse,
  account: { apiKeySource: "/login managed key", apiProvider: "firstParty" },
};

export function initMessage(session: string, apiKeySource = "none") {
  return {
    type: "system",
    subtype: "init",
    apiKeySource,
    claude_code_version: "2.1.323",
    cwd: "/Users/someone/Singularity/plugins/.data/assistant",
    tools: [],
    mcp_servers: [],
    model: "claude-opus-5-1",
    permissionMode: "default",
    slash_commands: [],
    output_style: "default",
    skills: [],
    plugins: [],
    uuid: "00000000-0000-4000-8000-000000000001",
    session_id: session,
  };
}

function streamEvent(session: string, event: object, n: number) {
  return { type: "stream_event", event, parent_tool_use_id: null, uuid: `00000000-0000-4000-8000-0000000001${n}`, session_id: session };
}

const usage = { input_tokens: 12, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };

/** One turn that answers "Hello there." in two pieces. */
export function helloTurn(session: string) {
  const message = {
    id: "msg_01",
    type: "message",
    role: "assistant",
    model: "claude-opus-5-1",
    content: [] as object[],
    stop_reason: null,
    stop_sequence: null,
    usage,
  };
  return [
    initMessage(session),
    streamEvent(session, { type: "message_start", message }, 10),
    streamEvent(session, { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }, 11),
    streamEvent(session, { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello" } }, 12),
    streamEvent(session, { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: " there." } }, 13),
    streamEvent(session, { type: "content_block_stop", index: 0 }, 14),
    {
      type: "assistant",
      message: { ...message, content: [{ type: "text", text: "Hello there." }] },
      parent_tool_use_id: null,
      uuid: "00000000-0000-4000-8000-000000000020",
      session_id: session,
    },
    streamEvent(session, { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage }, 15),
    streamEvent(session, { type: "message_stop" }, 16),
    result(session, { subtype: "success", is_error: false, result: "Hello there." }),
  ];
}

/** A turn that fails because the program isn't signed in. */
export function signedOutTurn(session: string) {
  const text = "Not logged in · Please run /login";
  return [
    initMessage(session),
    {
      type: "assistant",
      message: {
        id: "msg_02", type: "message", role: "assistant", model: "<synthetic>",
        content: [{ type: "text", text }], stop_reason: "stop_sequence", stop_sequence: "", usage,
      },
      parent_tool_use_id: null,
      error: "authentication_failed",
      uuid: "00000000-0000-4000-8000-000000000030",
      session_id: session,
    },
    result(session, { subtype: "success", is_error: true, result: text }),
  ];
}

/** A turn refused because the plan's usage limit is reached. */
export function limitTurn(session: string) {
  return [
    initMessage(session),
    {
      type: "rate_limit_event",
      rate_limit_info: { status: "rejected", rateLimitType: "five_hour", resetsAt: 1_900_000_000 },
      uuid: "00000000-0000-4000-8000-000000000040",
      session_id: session,
    },
    result(session, { subtype: "success", is_error: true, result: "You've hit your limit · resets 5pm" }),
  ];
}

/** A rate limit event; "rejected" with extra usage paying is not a failed turn. */
function rateLimitEvent(session: string, info: object) {
  return {
    type: "rate_limit_event",
    rate_limit_info: info,
    uuid: "00000000-0000-4000-8000-000000000041",
    session_id: session,
  };
}

/**
 * Past the plan's limit with extra usage switched on: the event says "rejected" (with overage
 * allowed and in use), and the answer still comes in full and ends well.
 */
export function limitWithExtraUsageTurn(session: string) {
  const turn = helloTurn(session);
  const info = { status: "rejected", rateLimitType: "five_hour", resetsAt: 1_900_000_000, overageStatus: "allowed",
    isUsingOverage: true, overageInUse: true };
  return [turn[0], rateLimitEvent(session, info), ...turn.slice(1)];
}

/**
 * A turn refused at the limit whose result text says nothing about it (only the event does): the
 * event names the reason.
 */
export function limitTurnPlainText(session: string) {
  return [
    initMessage(session),
    rateLimitEvent(session, { status: "rejected", rateLimitType: "seven_day", resetsAt: 1_900_000_000 }),
    result(session, { subtype: "success", is_error: true, result: "API Error: 429" }),
  ];
}

/** A turn the program answers itself, with no streamed text: only the result carries the answer. */
export function resultOnlyTurn(session: string, text: string) {
  return [initMessage(session), result(session, { subtype: "success", is_error: false, result: text })];
}

/**
 * A resumed program that answered `initialize` but can't find the conversation: the first turn
 * fails with "No conversation found".
 */
export function noConversationTurn(session: string) {
  return [
    result(session, {
      subtype: "error_during_execution",
      is_error: true,
      errors: [`No conversation found with session ID: ${session}`],
    }),
  ];
}

export function result(session: string, fields: { subtype: string; is_error: boolean; result?: string; errors?: string[] }) {
  return {
    // SDKResultError (every subtype but "success") carries `errors`; the SDK reads it.
    ...(fields.subtype === "success" ? {} : { errors: [] as string[] }),
    type: "result",
    duration_ms: 1200,
    duration_api_ms: 1100,
    num_turns: 1,
    stop_reason: "end_turn",
    total_cost_usd: 0.01,
    usage,
    modelUsage: {},
    permission_denials: [],
    uuid: "00000000-0000-4000-8000-000000000099",
    session_id: session,
    ...fields,
  };
}
