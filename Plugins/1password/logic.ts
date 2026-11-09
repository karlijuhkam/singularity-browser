// Pure helpers of the 1Password plugin: no I/O, so they can be tested with `bun test`.
// background.ts does the talking (to the page and to `op`); this file only decides and parses.

export type Login = { id: string; title: string; username: string };
export type Match = Login & { host: string };

/** 1Password item ids are 26 lowercase letters and digits. Anything else is never passed to `op`. */
export function isItemID(id: unknown): id is string {
  return typeof id === "string" && /^[a-z0-9]{26}$/.test(id);
}

/** Lowercase, trailing dot removed ("GitHub.com." -> "github.com"). */
export function normalizeHost(host: string): string {
  return host.toLowerCase().replace(/\.$/, "");
}

/**
 * True when `frameHost` is `itemHost` or a subdomain of it ("gist.github.com" matches "github.com",
 * "evilgithub.com" does not). Same rule as HostMatch in Sources/SingularityCore (the Swift side
 * applies it again before any fill is delivered).
 */
export function isSameOrSubdomain(frameHost: string, itemHost: string): boolean {
  const f = normalizeHost(frameHost);
  const i = normalizeHost(itemHost);
  return i !== "" && (f === i || f.endsWith("." + i));
}

/** The hosts of an item's http(s) URLs. */
function itemHosts(item: Record<string, unknown>): string[] {
  if (!Array.isArray(item.urls)) return [];
  const hosts: string[] = [];
  for (const entry of item.urls) {
    const href = entry && typeof entry === "object" ? (entry as Record<string, unknown>).href : undefined;
    if (typeof href !== "string") continue;
    try {
      const url = new URL(href);
      if (url.protocol === "http:" || url.protocol === "https:") hosts.push(normalizeHost(url.hostname));
    } catch {
      // Not a URL: skip it.
    }
  }
  return hosts;
}

/**
 * Parses the output of `op item list --categories Login --format json` and keeps the logins that
 * belong to `frameHost`. Returns null when the output isn't the expected shape (a JSON array).
 * Items without a valid id, or without a URL for this host, are skipped.
 */
export function matchLogins(listJSON: string, frameHost: string): Match[] | null {
  let items: unknown;
  try {
    items = JSON.parse(listJSON);
  } catch {
    return null;
  }
  if (!Array.isArray(items)) return null;
  const matches: Match[] = [];
  for (const raw of items) {
    if (!raw || typeof raw !== "object") continue;
    const item = raw as Record<string, unknown>;
    if (!isItemID(item.id)) continue;
    const host = itemHosts(item).find((h) => isSameOrSubdomain(frameHost, h));
    if (host === undefined) continue;
    const title = typeof item.title === "string" && item.title !== "" ? item.title : "Untitled login";
    // For logins, 1Password puts the username in additional_information (a hint, may be empty).
    const username = typeof item.additional_information === "string" ? item.additional_information : "";
    matches.push({ id: item.id, title, username, host });
  }
  return matches;
}

/**
 * Parses the output of `op item get <id> --fields label=username,label=password --reveal --format json`.
 * With several fields `op` prints an array of field objects, with one field a single object; both
 * are accepted. A field counts as the username/password by its `purpose` (USERNAME/PASSWORD) or,
 * failing that, its label. Returns null when there is no password.
 */
export function parseCredentials(getJSON: string): { username: string; password: string } | null {
  let data: unknown;
  try {
    data = JSON.parse(getJSON);
  } catch {
    return null;
  }
  const fields = (Array.isArray(data) ? data : [data]).filter(
    (f): f is Record<string, unknown> => !!f && typeof f === "object",
  );
  function find(purpose: string, label: string): string | undefined {
    const field =
      fields.find((f) => f.purpose === purpose) ??
      fields.find((f) => typeof f.label === "string" && f.label.toLowerCase() === label);
    return field && typeof field.value === "string" ? field.value : undefined;
  }
  const password = find("PASSWORD", "password");
  if (password === undefined || password === "") return null;
  return { username: find("USERNAME", "username") ?? "", password };
}
