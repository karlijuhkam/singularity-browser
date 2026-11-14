// Reads an app's manifest: wrangler.jsonc (or wrangler.json), the same file Cloudflare's wrangler
// reads. Used by app-host.ts inside the sandbox; Swift only needs to know that the file exists.
//
// We read four things and ignore every other key, so a manifest written for Cloudflare works here
// unchanged (checked against https://developers.cloudflare.com/workers/wrangler/configuration/
// on 2026-11-14):
//
//   main                           string   the Worker's entry file. Wrangler has no default; ours is
//                                           "worker.ts".
//   d1_databases[].binding         string   the name in env ("DB" → env.DB). Wrangler: "must be a
//                                           valid JavaScript variable name".
//   d1_databases[].migrations_dir  string   folder of *.sql files, default "migrations" (wrangler's
//                                           DEFAULT_MIGRATION_PATH is "./migrations").
//   vars                           object   plain values put into env.
//
// database_name, database_id, migrations_table and migrations_pattern are not read: there is one
// local file per binding, and the migrations table is always wrangler's default, d1_migrations.
//
// JSONC is parsed here, by hand, rather than by importing the file with Bun: the text is turned
// into plain JSON (comments and trailing commas removed, strings left alone) and given to JSON.parse.

export type D1BindingConfig = {
  binding: string;
  /** Relative to the app folder. */
  migrationsDir: string;
};

export type AppConfig = {
  /** Relative to the app folder. */
  main: string;
  d1: D1BindingConfig[];
  vars: Record<string, unknown>;
};

export const DEFAULT_MAIN = "worker.ts";
export const DEFAULT_MIGRATIONS_DIR = "migrations";

/** A manifest we refuse. The message is written for the developer (or agent) who wrote the file. */
export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

// ---- JSONC ------------------------------------------------------------------------------------

/**
 * Copies a JSON string literal starting at `start` (the opening quote) to `out` and returns the
 * index after its closing quote. A backslash always takes the next character with it, so `\"`
 * does not end the string. An unterminated string is copied to the end; JSON.parse reports it.
 */
function copyString(text: string, start: number, out: string[]): number {
  let i = start + 1;
  while (i < text.length) {
    const c = text[i];
    if (c === "\\") {
      i += 2;
    } else if (c === '"') {
      i += 1;
      break;
    } else {
      i += 1;
    }
  }
  out.push(text.slice(start, i));
  return i;
}

// Step 1: line comments and block comments outside strings become spaces (line breaks are kept,
// so JSON.parse's line numbers still point at the right line).
function removeComments(text: string): string {
  const out: string[] = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      i = copyString(text, i, out);
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i += 1;
      out.push(" ");
    } else if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      if (end < 0) throw new ConfigError("a /* comment is never closed");
      // Keep the comment's line breaks.
      out.push(text.slice(i, end + 2).replace(/[^\n]/g, " "));
      i = end + 2;
    } else {
      out.push(c);
      i += 1;
    }
  }
  return out.join("");
}

/** Step 2: a comma whose next character (after white space) is `}` or `]` is dropped. */
function removeTrailingCommas(text: string): string {
  const out: string[] = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      i = copyString(text, i, out);
      continue;
    }
    if (c === ",") {
      let next = i + 1;
      while (next < text.length && /\s/.test(text[next])) next += 1;
      if (text[next] === "}" || text[next] === "]") {
        i += 1; // skip the comma
        continue;
      }
    }
    out.push(c);
    i += 1;
  }
  return out.join("");
}

/** Parses JSON with comments and trailing commas. Throws ConfigError with JSON.parse's message. */
export function parseJSONC(text: string): unknown {
  // A UTF-8 byte order mark (some editors write one) is not JSON.
  const withoutMark = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const json = removeTrailingCommas(removeComments(withoutMark));
  try {
    return JSON.parse(json);
  } catch (error) {
    throw new ConfigError("not valid JSON: " + (error instanceof Error ? error.message : String(error)));
  }
}

// ---- The keys we read -------------------------------------------------------------------------

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** What `binding` must look like: env.<binding> has to be writable as plain JavaScript. */
const IDENTIFIER = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

/**
 * A path inside the app folder, as the manifest gives it: not empty, not absolute, no ".." part.
 * Returned without a leading "./". (The sandbox is what really keeps the Worker inside its folder;
 * this check gives a clear message instead of a "file not found" from somewhere else.)
 */
function relativePath(value: unknown, key: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new ConfigError(`"${key}" must be a path, for example "${key === "main" ? DEFAULT_MAIN : DEFAULT_MIGRATIONS_DIR}"`);
  }
  if (value.includes("\0")) throw new ConfigError(`"${key}" is not a usable path`);
  if (value.startsWith("/") || value.startsWith("\\") || value.startsWith("~") || /^[A-Za-z]:[\\/]/.test(value)) {
    throw new ConfigError(`"${key}" must be a path inside the app's folder, not an absolute one: ${value}`);
  }
  const parts = value.split(/[\\/]/);
  if (parts.includes("..")) {
    throw new ConfigError(`"${key}" must stay inside the app's folder (no ".."): ${value}`);
  }
  // "./worker.ts" and "worker.ts" are the same file; "." alone stays "." (the app folder itself).
  const cleaned = parts.filter((part) => part !== "" && part !== ".").join("/");
  return cleaned === "" ? "." : cleaned;
}

/** Reads a manifest's text. Throws ConfigError for anything we refuse. */
export function parseAppConfig(text: string): AppConfig {
  const root = parseJSONC(text);
  if (!isObject(root)) throw new ConfigError("the file must hold one JSON object");

  const main = root.main === undefined ? DEFAULT_MAIN : relativePath(root.main, "main");
  if (main === ".") throw new ConfigError('"main" must name a file');

  const d1: D1BindingConfig[] = [];
  const databases = root.d1_databases;
  if (databases !== undefined) {
    if (!Array.isArray(databases)) throw new ConfigError('"d1_databases" must be a list');
    for (const entry of databases) {
      if (!isObject(entry)) throw new ConfigError('every entry of "d1_databases" must be an object');
      const binding = entry.binding;
      if (typeof binding !== "string" || !IDENTIFIER.test(binding)) {
        throw new ConfigError(
          `a "d1_databases" entry's "binding" must be a JavaScript name such as "DB", not ${JSON.stringify(binding)}`,
        );
      }
      if (d1.some((other) => other.binding === binding)) {
        throw new ConfigError(`two "d1_databases" entries have the binding "${binding}"`);
      }
      const migrationsDir =
        entry.migrations_dir === undefined ? DEFAULT_MIGRATIONS_DIR : relativePath(entry.migrations_dir, "migrations_dir");
      d1.push({ binding, migrationsDir });
    }
  }

  let vars: Record<string, unknown> = {};
  if (root.vars !== undefined) {
    if (!isObject(root.vars)) throw new ConfigError('"vars" must be an object of names and values');
    vars = { ...root.vars };
  }

  return { main, d1, vars };
}
