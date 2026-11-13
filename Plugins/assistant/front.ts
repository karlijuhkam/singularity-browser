// What the Assistant knows about where the user is, and how a tool call is told to the user.
// Pure functions (background.ts, provider-claude.ts and the page use them; tests cover them).
//
// Two rules hold everywhere here:
// - A tab's title and address come from a web page, so they are untrusted. They go to Claude only
//   inside an <untrusted-content> wrapper, with < and > replaced so a page can't close it.
// - A tool line is built only from the call's own input and from the tab that was in front when
//   the message was sent. Nothing a tool answered is ever used.

export type FrontTab = {
  space: { slug: string; name: string };
  tab: { id: string; kind: "web" | "artifact" | "terminal"; title?: string; url?: string };
};

/** A running tool shows "waiting for your OK" after this long (Singularity may be asking the user). */
export const WAITING_AFTER_MS = 1500;
export const WAITING_SUFFIX = " — waiting for your OK";
export const FAILED_SUFFIX = " — not done";
export const NOTHING_SHARED = "Nothing shared from here";
const NOTHING_VISIBLE = "Nothing in front is visible to you.";
/** An address or a search text in a line is cut here (the model chooses them). */
const MAX_SHOWN = 200;

/** Title and address are cut here before they go to Claude (the app cuts them too). */
const MAX_TITLE = 300;
const MAX_ADDRESS = 2000;

/**
 * Turns every run of whitespace, newlines included, into one space (a title can't start a line
 * of its own), removes the other Unicode control and format characters (they could hide or
 * reorder text), and replaces < and > (page text must not be able to close the wrapper).
 */
function defang(text: string): string {
  return text.replace(/\s+/g, " ").replace(/[\p{Cc}\p{Cf}]/gu, "").trim().replace(/</g, "‹").replace(/>/g, "›");
}

/** The note put before the user's text in what is sent to Claude (never shown, never saved). */
export function frontBlock(front: FrontTab | null): string {
  if (front === null) return NOTHING_VISIBLE;
  const { space, tab } = front;
  const lines = [
    "Where the user is (from Singularity, not typed by the user):",
    `Space: ${defang(space.slug)} (${defang(space.name)})`,
    `Tab id: ${defang(tab.id)}`,
    `Kind: ${tab.kind}`,
    '<untrusted-content source="tab in front">',
  ];
  if (tab.title !== undefined) lines.push(`Title: ${defang(tab.title.slice(0, MAX_TITLE))}`);
  if (tab.url !== undefined) lines.push(`Address: ${defang(tab.url.slice(0, MAX_ADDRESS))}`);
  lines.push("</untrusted-content>");
  return lines.join("\n");
}

/** The chip above the input: what the next message will share. */
export function chipText(front: FrontTab | null): string {
  if (front === null) return NOTHING_SHARED;
  return front.tab.title || front.tab.url || "Untitled tab";
}

/** The door's tool names, longest first (a name ends with one of them). */
const TOOLS = [
  "read_console", "read_network", "list_spaces", "screenshot", "read_page", "list_tabs", "navigate",
  "click", "close", "find", "open", "type",
];
const PREFIX = "mcp__singularity__";

/**
 * The name the door gives a tool, from the name `claude` reports: "mcp__singularity__my_work_read_page"
 * is "my_work.read_page". The app's slugs hold only a-z, 0-9 and "-" (never "_"), but tool
 * names hold underscores, so the name is split at its last known tool name, never at the first
 * "_". null for a tool that isn't the door's.
 */
export function doorName(claudeName: string): string | null {
  if (!claudeName.startsWith(PREFIX)) return null;
  const name = claudeName.slice(PREFIX.length);
  if (name === "list_spaces") return name;
  for (const tool of TOOLS) {
    if (name.endsWith("_" + tool) && name.length > tool.length + 1) return name.slice(0, -(tool.length + 1)) + "." + tool;
  }
  return name;
}

function shown(value: unknown): string {
  const text = typeof value === "string" ? value : "";
  return text.length > MAX_SHOWN ? text.slice(0, MAX_SHOWN) + "…" : text;
}

/**
 * The line for a tool call. `name` is the door's ("work.read_page", "list_spaces"); `status`
 * "running", "waiting" (running for longer than WAITING_AFTER_MS), "done" or "failed".
 */
export function toolLine(
  name: string,
  input: Record<string, unknown>,
  status: string,
  frontAtSend: FrontTab | null,
): { text: string; space?: string } {
  const dot = name.indexOf(".");
  const slug = dot < 0 ? undefined : name.slice(0, dot);
  const tool = dot < 0 ? name : name.slice(dot + 1);
  const isFront = frontAtSend !== null && typeof input.tab_id === "string" && input.tab_id === frontAtSend.tab.id;
  const title = isFront ? frontAtSend.tab.title || frontAtSend.tab.url || "a tab" : "a tab";
  let text: string;
  switch (tool) {
    case "read_page": text = `Read ${title}`; break;
    case "find": text = `Looked for “${shown(input.query)}” on ${title}`; break;
    case "open": text = `Opened ${shown(input.url)}`; break;
    case "navigate": text = `Went to ${shown(input.url)}`; break;
    case "click": text = `Clicked on ${title}`; break;
    case "type": text = `Typed on ${title}`; break;
    case "close": text = `Closed ${title}`; break;
    case "screenshot": text = `Took a picture of ${title}`; break;
    case "list_tabs": text = "Listed the tabs"; break;
    case "list_spaces": text = "Looked at your Spaces"; break;
    case "read_console": text = `Read the console of ${title}`; break;
    case "read_network": text = `Read the network log of ${title}`; break;
    default: text = `Used ${shown(tool)}`;
  }
  const space = slug !== undefined && slug !== frontAtSend?.space.slug ? slug : undefined;
  if (space !== undefined) text += ` in ${space}`;
  if (status === "waiting") text += WAITING_SUFFIX;
  else if (status === "failed") text += FAILED_SUFFIX;
  return space === undefined ? { text } : { text, space };
}

/**
 * Whether a line may be waiting for the user's OK when it runs long: only the acting tools ask
 * (open, navigate, close, click, type). A slow read is just slow. Judged by the line's own
 * text, which toolLine writes.
 */
export function mayWaitForOK(lineText: string): boolean {
  return /^(Opened |Went to |Closed |Clicked on |Typed on )/.test(lineText);
}
