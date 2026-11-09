// Background program of the 1Password plugin. It runs on Singularity's bundled Bun, in a sandbox
// with no network. The only thing it can start is `op` (1Password's command line tool), and only
// `op item list` and `op item get` (see plugin.json). `op` asks for Touch ID itself.
//
// Messages from page.ts:
//   {type: "logins"}        -> {logins: [{id, title, username}]}  or  {error}
//   {type: "fill", id}      -> {fill: {forHost, username, password}}  or  {error}
//
// Safety rules this file follows:
// - The site comes from `frameHost`, which Singularity reads from WebKit. A host sent in the
//   page's message is ignored (a web page can't be trusted to say where it is).
// - A fill is only allowed for an item this file itself listed as matching that frameHost
//   in the last two minutes.
// - Never log or keep secrets: the log gets counts and error kinds only, and passwords are
//   never stored anywhere (only ids, titles, usernames and hosts, to answer the next fill).
import { singularity } from "singularity";
import { isItemID, matchLogins, parseCredentials, type Match } from "./logic.ts";

const UNAVAILABLE = "1Password is locked or unavailable";
const NOT_AVAILABLE_HERE = "That login isn't available here";
const REMEMBER_MS = 2 * 60 * 1000;

// What we last listed for a site: frameHost -> {when, id -> the item's matching host}.
const listed = new Map<string, { at: number; hosts: Map<string, string> }>();

/** Runs `op item list` and returns this site's logins, or null if op failed or answered oddly. */
async function listLogins(frameHost: string): Promise<Match[] | null> {
  const result = await singularity.run("op", ["item", "list", "--categories", "Login", "--format", "json"]);
  if (result.status !== 0 || result.timedOut) {
    singularity.log(`op item list failed (${result.timedOut ? "timed out" : "status " + result.status})`);
    return null;
  }
  const matches = matchLogins(result.stdout, frameHost);
  if (matches === null) {
    singularity.log("op item list: unexpected output");
    return null;
  }
  // Forget entries past their time, so the map can't grow without bound.
  for (const [host, entry] of listed) if (Date.now() - entry.at > REMEMBER_MS) listed.delete(host);
  listed.set(frameHost, { at: Date.now(), hosts: new Map(matches.map((m) => [m.id, m.host])) });
  return matches;
}

async function handleLogins(frameHost: string) {
  const matches = await listLogins(frameHost);
  if (matches === null) return { error: UNAVAILABLE };
  singularity.log(`listed ${matches.length} login(s)`);
  return { logins: matches.map(({ id, title, username }) => ({ id, title, username })) };
}

async function handleFill(frameHost: string, id: unknown) {
  if (!isItemID(id)) return { error: NOT_AVAILABLE_HERE };

  // Only an item we listed for this very frameHost, recently. Otherwise list again and check.
  let entry = listed.get(frameHost);
  if (!entry || Date.now() - entry.at > REMEMBER_MS || !entry.hosts.has(id)) {
    if ((await listLogins(frameHost)) === null) return { error: UNAVAILABLE };
    entry = listed.get(frameHost);
  }
  const forHost = entry?.hosts.get(id);
  if (forHost === undefined) return { error: NOT_AVAILABLE_HERE };

  // The id is its own argument. We fetch the whole item (no --fields) so a missing username label can't fail the call.
  const result = await singularity.run("op", [
    "item", "get", id, "--format", "json", "--reveal",
  ]);
  if (result.status !== 0 || result.timedOut) {
    singularity.log(`op item get failed (${result.timedOut ? "timed out" : "status " + result.status})`);
    return { error: UNAVAILABLE };
  }
  try {
    JSON.parse(result.stdout);
  } catch {
    singularity.log("op item get: unparsable output");
    return { error: UNAVAILABLE };
  }
  const credentials = parseCredentials(result.stdout);
  if (credentials === null) {
    singularity.log("op item get: no password in the answer");
    return { error: "That login has no password" };
  }
  singularity.log("filled one login");
  // Singularity checks forHost against the page's real host again before filling anything.
  return { fill: { forHost, username: credentials.username, password: credentials.password } };
}

singularity.onPageMessage(async ({ frameHost, payload }) => {
  const message = (payload ?? {}) as { type?: unknown; id?: unknown };
  if (message.type === "logins") return handleLogins(frameHost);
  if (message.type === "fill") return handleFill(frameHost, message.id);
  return { error: "unknown request" };
});
