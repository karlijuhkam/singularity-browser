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

/** 1Password often stores "github.com" or "www.github.com/login" without a scheme: add https://. */
export function withScheme(href: string): string {
  const text = href.trim();
  if (text.startsWith("//")) return "https:" + text;
  return /^[a-z][a-z0-9+.-]*:/i.test(text) ? text : "https://" + text;
}

/** The hosts of an item's http(s) URLs. */
function itemHosts(item: Record<string, unknown>): string[] {
  if (!Array.isArray(item.urls)) return [];
  const hosts: string[] = [];
  for (const entry of item.urls) {
    const href = entry && typeof entry === "object" ? (entry as Record<string, unknown>).href : undefined;
    if (typeof href !== "string") continue;
    try {
      const url = new URL(withScheme(href));
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
 * Parses the output of `op item get <id> --format json --reveal` (the whole item; its `fields` is an
 * array of {id, type, purpose, label, value}). The password is the field with purpose PASSWORD,
 * else a CONCEALED field labelled "password". The username is purpose USERNAME, else a field
 * labelled "username", else "email". Returns null when the shape is wrong or there is no password;
 * the username may be "" (the page then leaves what the user typed alone).
 */
export function parseCredentials(getJSON: string): { username: string; password: string } | null {
  let item: unknown;
  try {
    item = JSON.parse(getJSON);
  } catch {
    return null;
  }
  const rawFields = item && typeof item === "object" ? (item as Record<string, unknown>).fields : undefined;
  if (!Array.isArray(rawFields)) return null;
  const fields = rawFields.filter((f): f is Record<string, unknown> => !!f && typeof f === "object");
  const label = (f: Record<string, unknown>) => (typeof f.label === "string" ? f.label.toLowerCase() : "");
  const valueOf = (f: Record<string, unknown> | undefined) =>
    f && typeof f.value === "string" && f.value !== "" ? f.value : undefined;

  const password = valueOf(
    fields.find((f) => f.purpose === "PASSWORD" && valueOf(f)) ??
      fields.find((f) => f.type === "CONCEALED" && label(f) === "password" && valueOf(f)),
  );
  if (password === undefined) return null;
  const username = valueOf(
    fields.find((f) => f.purpose === "USERNAME" && valueOf(f)) ??
      fields.find((f) => label(f) === "username" && valueOf(f)) ??
      fields.find((f) => label(f) === "email" && valueOf(f)),
  );
  return { username: username ?? "", password };
}
