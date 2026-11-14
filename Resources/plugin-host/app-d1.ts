// env.DB for an app's Worker: Cloudflare D1's client API over a local SQLite file (bun:sqlite),
// and the migration runner. Used by app-host.ts inside the sandbox.
//
// The point is that Worker code written here runs unchanged on Cloudflare, so this file follows
// D1, not our taste. What it follows was checked on 2026-11-14 against:
//
//   [1] https://developers.cloudflare.com/d1/worker-api/                       (type conversion)
//   [2] https://developers.cloudflare.com/d1/worker-api/d1-database/           (prepare, batch, exec)
//   [3] https://developers.cloudflare.com/d1/worker-api/prepared-statements/   (bind, run, all, raw, first)
//   [4] https://developers.cloudflare.com/d1/worker-api/return-object/         (D1Result, D1ExecResult)
//   [5] https://developers.cloudflare.com/d1/reference/migrations/             (migrations folder and table)
//   [6] https://developers.cloudflare.com/d1/sql-api/foreign-keys/             (foreign keys are on)
//   [7] https://github.com/cloudflare/workerd/blob/main/src/cloudflare/internal/d1-api.ts
//       (the binding's own source: the code that runs in a Worker on Cloudflare)
//   [8] https://github.com/cloudflare/workers-sdk/blob/main/packages/wrangler/src/d1/migrations/helpers.ts
//       and ../constants.ts (wrangler's migrations table)
//
// What was verified:
//
// D1Database [2][7]
//   prepare(sql)       → a D1PreparedStatement. Nothing runs and nothing is checked yet.
//   batch(statements)  → Promise<D1Result[]>, in the statements' order. "Batched statements are SQL
//                        transactions": if one fails, the whole batch is rolled back and the call throws.
//   exec(sql)          → Promise<{ count, duration }> (D1ExecResult): count = queries executed,
//                        duration in ms. No parameters. The binding splits the text at line breaks and
//                        runs each line as one query ([7]: `query.trim().split('\n')`), so a statement
//                        must fit on one line. On an error it throws
//                        "D1_EXEC_ERROR: Error in line N: <line>: <message>"; earlier lines stay done.
//   Also on D1 and NOT here: withSession() (read replicas; there are none locally) and dump()
//   (deprecated, alpha databases only). Both throw with a message saying so.
//
// D1PreparedStatement [3][7]
//   bind(...values)    → a NEW statement with these values; the original is unchanged. Parameters are
//                        `?` and `?NNN`; named ones are not supported by D1. Values [1]: null, number,
//                        string; boolean → 1 / 0; ArrayBuffer and views → BLOB; an array of byte
//                        numbers → BLOB; anything else (undefined too) throws
//                        "D1_TYPE_ERROR: Type '<typeof>' not supported for value '<value>'".
//   first()            → the first row as an object, or null when there are no rows.
//   first(column)      → that column's value of the first row; null when there are no rows; throws
//                        when the column does not exist ([7]: "D1_COLUMN_NOTFOUND: Column not found
//                        (<column>)"; [3] calls it a D1_ERROR exception).
//   all() / run()      → Promise<D1Result>. [3]: run() is "functionally equivalent" to all();
//                        `results` is [] for a write (INSERT, UPDATE, DELETE without RETURNING).
//   raw(options?)      → Promise<unknown[][]>: one array per row, no metadata. With
//                        { columnNames: true } the first array is the column names.
//
// D1Result [4]
//   { success: true, meta: { … }, results: [ …rows as objects… ] }
//   meta: served_by (string), served_by_region (string), served_by_primary (boolean),
//         timings.sql_duration_ms (number), duration (ms), changes, last_row_id, changed_db (boolean),
//         size_after (bytes), rows_read, rows_written. ([4] also lists total_attempts; it is optional
//         in [7] and missing from [4]'s own example, and we leave it out: nothing is retried here.)
//   Reading [1]: INTEGER and REAL → number (64-bit integers above Number.MAX_SAFE_INTEGER lose
//   precision, as on D1: no BigInt), TEXT → string, NULL → null, BLOB → a plain Array of byte numbers.
//   Two columns with the same name: the later one wins in an object row ([7] uses Object.fromEntries).
//
// Migrations [5][8]
//   *.sql files in the binding's migrations folder (default "migrations"). Applied ones are recorded
//   in the table d1_migrations, created by wrangler as
//       CREATE TABLE IF NOT EXISTS "d1_migrations"(
//         id         INTEGER PRIMARY KEY AUTOINCREMENT,
//         name       TEXT UNIQUE,
//         applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL );
//   with `name` = the file's name including ".sql". Wrangler runs each file's SQL followed by
//   `INSERT INTO d1_migrations (name) values ('<name>')` and stops at the first one that fails.
//   So a database made here and one made by `wrangler d1 migrations apply` agree on what is applied.
//
// Foreign keys [6]: D1 enforces them by default ("PRAGMA foreign_keys = on"); so do we.
//
// Where this is NOT D1, on purpose or because it can't be:
//   - meta.served_by is "singularity-local", served_by_region "local", served_by_primary true.
//   - meta.rows_read is the number of rows the query returned, not rows scanned (bun:sqlite does not
//     expose SQLite's scan counters). meta.rows_written is the number of rows inserted, updated or
//     deleted, including by triggers; D1 also counts index writes. Don't size a bill from these.
//   - meta.size_after is the main file's page count × page size (in WAL mode recent writes may still
//     be in the -wal file next to it).
//   - meta.duration and timings.sql_duration_ms are the same local measurement.
//   - Error texts: the prefixes (D1_ERROR, D1_EXEC_ERROR, D1_TYPE_ERROR, D1_COLUMN_NOTFOUND) are the
//     binding's; what follows "D1_ERROR: " is bun:sqlite's message, and the D1 service's wording
//     for the same error was not compared. The "wrong number of parameter bindings" text is ours.
//   - Transactions: on D1 every query runs in an implicit transaction [6] and batch() is the only
//     way to group statements. SQLite here would accept BEGIN / COMMIT in a query; don't use them.
//   - exec(): blank lines are skipped and not counted.
//   - Migration files are ordered by plain name comparison ("0001_…" < "0002_…" < "0010_…"), each in
//     one transaction of its own; a file that fails leaves no trace of itself.
//   - No limits (statement length, bound parameters, row size, query time) are enforced.
//
// Another program may write the same file while the Worker runs (an agent's `sqlite3`), so the
// file is opened in WAL mode with a busy timeout: readers and one writer don't block each other,
// and two writers wait for each other instead of failing at once.

import { Database, type SQLQueryBindings } from "bun:sqlite";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// ---- Types ------------------------------------------------------------------------------------

export type D1Meta = {
  served_by: string;
  served_by_region: string;
  served_by_primary: boolean;
  timings: { sql_duration_ms: number };
  duration: number;
  changes: number;
  last_row_id: number;
  changed_db: boolean;
  size_after: number;
  rows_read: number;
  rows_written: number;
};

export type D1Result<T = Record<string, unknown>> = {
  success: true;
  meta: D1Meta;
  results: T[];
};

export type D1ExecResult = {
  count: number;
  duration: number;
};

export type D1RawOptions = {
  columnNames?: boolean;
};

export const MIGRATIONS_TABLE = "d1_migrations";

/** How long a write waits for another program's write to the same file, in milliseconds. */
const BUSY_TIMEOUT_MS = 5000;

// ---- Opening the file -------------------------------------------------------------------------

/** Opens (and creates) a database file the way every app database is opened. */
export function openSQLite(path: string): Database {
  const sqlite = new Database(path, { create: true });
  // The busy timeout first: switching to WAL needs a lock, and another program may hold one.
  sqlite.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
  // WAL is stored in the file, so this is a no-op from the second start on.
  sqlite.run("PRAGMA journal_mode = WAL");
  // Per connection, and off by default in SQLite; D1 has it on.
  sqlite.run("PRAGMA foreign_keys = ON");
  return sqlite;
}

// ---- Errors -----------------------------------------------------------------------------------

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** An error as the D1 binding throws them: "<PREFIX>: <message>", the original as `cause`. */
function d1Error(prefix: string, message: string, cause?: unknown): Error {
  return new Error(`${prefix}: ${message}`, { cause: cause ?? new Error(message) });
}

// ---- Running one statement --------------------------------------------------------------------

type Outcome = {
  columns: string[];
  rows: unknown[][];
  meta: D1Meta;
};

type Counters = { total: number; changes: number; last: number };

/** bind() keeps a BLOB as an array of byte numbers (as D1's binding does); SQLite wants bytes. */
function toSQLiteValue(value: unknown): SQLQueryBindings {
  return Array.isArray(value) ? new Uint8Array(value as number[]) : (value as SQLQueryBindings);
}

/** A BLOB is read as a plain array of numbers on D1, not as a Uint8Array. */
function fromSQLiteValue(value: unknown): unknown {
  return value instanceof Uint8Array ? Array.from(value) : value;
}

/**
 * The connection and the code that runs one statement on it. Kept apart from D1Database so that a
 * Worker holding env.DB can't reach anything that isn't D1's API.
 */
class Connection {
  readonly sqlite: Database;

  constructor(sqlite: Database) {
    this.sqlite = sqlite;
  }

  /** SQLite's own counters for this connection; reading them changes none of them. */
  counters(): Counters {
    return this.sqlite
      .query("SELECT total_changes() AS total, changes() AS changes, last_insert_rowid() AS last")
      .get() as Counters;
  }

  pragmaNumber(name: "schema_version" | "page_count" | "page_size"): number {
    const row = this.sqlite.query(`PRAGMA ${name}`).get() as Record<string, number> | null;
    return row ? Number(row[name]) : 0;
  }

  /** Runs one statement with its values. Throws D1_ERROR for anything SQLite refuses. */
  run(sql: string, params: unknown[]): Outcome {
    const started = performance.now();
    try {
      // prepare(), not query(): query() caches the compiled statement by its text, and the schema
      // can change under us (another program, a migration).
      const statement = this.sqlite.prepare(sql);
      try {
        // SQLite would silently use NULL for a missing value; D1 refuses the query.
        if (statement.paramsCount !== params.length) {
          throw new Error(
            `Wrong number of parameter bindings for SQL query: it has ${statement.paramsCount}, bind() gave ${params.length}.`,
          );
        }
        const readOnly = statement.readonly;
        const before = this.counters();
        const schemaBefore = readOnly ? 0 : this.pragmaNumber("schema_version");

        // values() gives each row as an array, in column order ([] for a statement with no rows).
        const rows = (statement.values(...params.map(toSQLiteValue)) ?? []) as unknown[][];
        const columns = statement.columnNames;

        const after = this.counters();
        const written = after.total - before.total;
        const schemaChanged = !readOnly && this.pragmaNumber("schema_version") !== schemaBefore;
        const duration = performance.now() - started;
        return {
          columns,
          rows: rows.map((row) => row.map(fromSQLiteValue)),
          meta: {
            served_by: "singularity-local",
            served_by_region: "local",
            served_by_primary: true,
            timings: { sql_duration_ms: duration },
            duration,
            // changes() still holds the previous write's number after a read, so only trust it when
            // this statement wrote something.
            changes: written > 0 ? after.changes : 0,
            last_row_id: after.last,
            changed_db: written > 0 || schemaChanged,
            size_after: this.pragmaNumber("page_count") * this.pragmaNumber("page_size"),
            rows_read: rows.length,
            rows_written: written,
          },
        };
      } finally {
        statement.finalize();
      }
    } catch (error) {
      throw d1Error("D1_ERROR", messageOf(error), error);
    }
  }
}

function toResult(outcome: Outcome): D1Result {
  const { columns, rows, meta } = outcome;
  return {
    success: true,
    meta,
    results: rows.map((row) => Object.fromEntries(row.map((cell, index) => [columns[index], cell]))),
  };
}

// ---- D1PreparedStatement ----------------------------------------------------------------------

// Statement → its connection. A WeakMap instead of a property, so the Worker sees only what a D1
// statement has: `statement`, `params` and the methods.
const connectionOf = new WeakMap<D1PreparedStatement, Connection>();

export class D1PreparedStatement {
  readonly statement: string;
  readonly params: unknown[];

  /** Made by D1Database.prepare() and bind(); Worker code never calls this. */
  constructor(connection: Connection, statement: string, params: unknown[] = []) {
    connectionOf.set(this, connection);
    this.statement = statement;
    this.params = params;
  }

  bind(...values: unknown[]): D1PreparedStatement {
    // The same checks and conversions, in the same order, as the binding on Cloudflare ([7]).
    const converted = values.map((value: unknown): unknown => {
      const type = typeof value;
      if (type === "number" || type === "string") return value;
      if (type === "boolean") return value ? 1 : 0;
      if (type === "object") {
        if (value === null) return value;
        if (Array.isArray(value) && value.every((b: unknown) => typeof b === "number" && b >= 0 && b < 256)) {
          return value;
        }
        if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
        if (ArrayBuffer.isView(value)) return Array.from(value as unknown as ArrayLike<unknown>);
      }
      throw d1Error("D1_TYPE_ERROR", `Type '${type}' not supported for value '${String(value)}'`);
    });
    return new D1PreparedStatement(connectionOf.get(this)!, this.statement, converted);
  }

  async first<T = unknown>(column?: string): Promise<T | null> {
    const result = toResult(connectionOf.get(this)!.run(this.statement, this.params));
    const row = result.results[0];
    if (row === undefined) return null;
    if (column === undefined) return row as T;
    if (row[column] === undefined) {
      throw d1Error("D1_COLUMN_NOTFOUND", `Column not found (${column})`, new Error("Column not found"));
    }
    return row[column] as T;
  }

  async all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return toResult(connectionOf.get(this)!.run(this.statement, this.params)) as D1Result<T>;
  }

  /** The same as all(): see the header ([3]). */
  async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return this.all<T>();
  }

  async raw<T = unknown[]>(options?: D1RawOptions): Promise<T[]> {
    const outcome = connectionOf.get(this)!.run(this.statement, this.params);
    return [...(options?.columnNames ? [outcome.columns] : []), ...outcome.rows] as T[];
  }
}

// ---- D1Database -------------------------------------------------------------------------------

export class D1Database {
  // A real private field: not reachable from Worker code.
  readonly #connection: Connection;

  /** `sqlite` comes from openSQLite(). */
  constructor(sqlite: Database) {
    this.#connection = new Connection(sqlite);
  }

  prepare(query: string): D1PreparedStatement {
    return new D1PreparedStatement(this.#connection, query);
  }

  async batch<T = Record<string, unknown>>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
    if (!Array.isArray(statements) || statements.some((s) => !(s instanceof D1PreparedStatement))) {
      throw d1Error("D1_ERROR", "batch() takes an array of prepared statements");
    }
    if (statements.length === 0) return [];
    const sqlite = this.#connection.sqlite;
    // IMMEDIATE takes the write lock now (waiting up to the busy timeout), so the batch can't fail
    // half-way because another program started writing in between.
    try {
      sqlite.run("BEGIN IMMEDIATE");
    } catch (error) {
      throw d1Error("D1_ERROR", messageOf(error), error);
    }
    try {
      const results = statements.map((s) => toResult(this.#connection.run(s.statement, s.params)) as D1Result<T>);
      sqlite.run("COMMIT");
      return results;
    } catch (error) {
      if (sqlite.inTransaction) sqlite.run("ROLLBACK");
      // run() already made it a D1_ERROR; a failing COMMIT has not been wrapped yet.
      throw messageOf(error).startsWith("D1_") ? error : d1Error("D1_ERROR", messageOf(error), error);
    }
  }

  async exec(query: string): Promise<D1ExecResult> {
    const started = performance.now();
    // One query per line, as the binding does it (see the header).
    const lines = query.trim().split("\n");
    let count = 0;
    for (const [index, line] of lines.entries()) {
      if (line.trim() === "") continue;
      try {
        this.#connection.sqlite.run(line);
      } catch (error) {
        throw d1Error("D1_EXEC_ERROR", `Error in line ${index + 1}: ${line}: ${messageOf(error)}`, error);
      }
      count += 1;
    }
    return { count, duration: performance.now() - started };
  }

  withSession(): never {
    throw d1Error("D1_ERROR", "withSession() is not available in Singularity's local database (there are no read replicas); use env.DB directly");
  }

  async dump(): Promise<never> {
    throw d1Error("D1_DUMP_ERROR", "dump() is not available in Singularity's local database (it is deprecated on D1 too)");
  }
}

// ---- Migrations -------------------------------------------------------------------------------

/** A migration file that could not be applied. `file` is its name, e.g. "0002_add_notes.sql". */
export class MigrationError extends Error {
  readonly file: string;

  constructor(file: string, message: string) {
    super(message);
    this.name = "MigrationError";
    this.file = file;
  }
}

/** The *.sql files of a folder, in name order. A missing folder has none. */
export function migrationFiles(folder: string): string[] {
  if (!existsSync(folder)) return [];
  return readdirSync(folder)
    .filter((name) => name.endsWith(".sql") && !name.startsWith(".") && statSync(join(folder, name)).isFile())
    // Plain comparison of the names, not the user's locale: the same order on every Mac.
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

/**
 * Applies the folder's migrations that d1_migrations doesn't list yet, in name order, and returns
 * the names it applied. Each file runs in one transaction together with its d1_migrations row, so
 * a file either happened completely and is recorded, or didn't happen. The first failure stops the
 * run with a MigrationError naming the file; earlier files stay applied.
 */
export function applyMigrations(sqlite: Database, folder: string): string[] {
  const files = migrationFiles(folder);
  // No migrations, no table: an app without a migrations folder gets an untouched database.
  if (files.length === 0) return [];

  // Wrangler's own statement ([8]), so the table is the same whoever made it.
  sqlite.run(`CREATE TABLE IF NOT EXISTS "${MIGRATIONS_TABLE}"(
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		name       TEXT UNIQUE,
		applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);`);
  const rows = sqlite.query(`SELECT name FROM "${MIGRATIONS_TABLE}" ORDER BY id`).all() as { name: string }[];
  const applied = new Set(rows.map((row) => row.name));

  const appliedNow: string[] = [];
  for (const file of files) {
    if (applied.has(file)) continue;
    try {
      const sql = readFileSync(join(folder, file), "utf8");
      sqlite.run("BEGIN IMMEDIATE");
      // A file of only comments or white space is a migration that does nothing, not an error
      // (bun:sqlite refuses to run blank SQL).
      if (hasStatement(sql)) sqlite.run(sql);
      sqlite.query(`INSERT INTO "${MIGRATIONS_TABLE}" (name) VALUES (?)`).run(file);
      sqlite.run("COMMIT");
    } catch (error) {
      if (sqlite.inTransaction) sqlite.run("ROLLBACK");
      throw new MigrationError(file, messageOf(error));
    }
    appliedNow.push(file);
  }
  return appliedNow;
}

/** False for text that is only white space and SQL comments. */
function hasStatement(sql: string): boolean {
  const withoutComments = sql.replace(/\/\*[\s\S]*?\*\//g, "").replace(/--[^\n]*/g, "");
  return withoutComments.trim() !== "";
}
