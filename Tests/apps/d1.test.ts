// Tests for Resources/plugin-host/app-d1.ts. Run from the repo root: Vendor/bun/bun test Tests/apps
//
// These pin the wrapper to Cloudflare D1's documented client API (the header of app-d1.ts lists the
// pages). Every database is a file in a fresh temporary folder.
import { Database } from "bun:sqlite";
import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  applyMigrations,
  D1Database,
  MigrationError,
  migrationFiles,
  openSQLite,
} from "../../Resources/plugin-host/app-d1.ts";

const folders: string[] = [];
const handles: Database[] = [];

function scratch(): string {
  const folder = mkdtempSync(join(tmpdir(), "sg-d1-"));
  folders.push(folder);
  return folder;
}

/** A new database file with one table, `notes`, and the raw handle for looking behind the wrapper. */
function open(): { db: D1Database; sqlite: Database; path: string } {
  const path = join(scratch(), "DB.sqlite");
  const sqlite = openSQLite(path);
  handles.push(sqlite);
  sqlite.run("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE, stars INTEGER, data BLOB)");
  return { db: new D1Database(sqlite), sqlite, path };
}

afterEach(() => {
  for (const handle of handles.splice(0)) handle.close();
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

const META_KEYS = [
  "changed_db", "changes", "duration", "last_row_id", "rows_read", "rows_written",
  "served_by", "served_by_primary", "served_by_region", "size_after", "timings",
];

test("run() on a write: success, meta, empty results", async () => {
  const { db } = open();
  const result = await db.prepare("INSERT INTO notes (title, stars) VALUES (?, ?)").bind("first", 3).run();
  expect(Object.keys(result).sort()).toEqual(["meta", "results", "success"]);
  expect(result.success).toBe(true);
  expect(result.results).toEqual([]);
  expect(Object.keys(result.meta).sort()).toEqual(META_KEYS);
  expect(result.meta.changes).toBe(1);
  expect(result.meta.last_row_id).toBe(1);
  expect(result.meta.changed_db).toBe(true);
  expect(result.meta.rows_written).toBe(1);
  expect(typeof result.meta.duration).toBe("number");
  expect(result.meta.timings.sql_duration_ms).toBe(result.meta.duration);
  expect(result.meta.size_after).toBeGreaterThan(0);
  expect(typeof result.meta.served_by).toBe("string");
  expect(typeof result.meta.served_by_region).toBe("string");
  expect(result.meta.served_by_primary).toBe(true);

  const second = await db.prepare("INSERT INTO notes (title) VALUES ('second'), ('third')").run();
  expect(second.meta.changes).toBe(2);
  expect(second.meta.last_row_id).toBe(3);
});

test("all() on a read: rows as objects, nothing changed", async () => {
  const { db } = open();
  await db.prepare("INSERT INTO notes (title, stars) VALUES ('a', 1), ('b', 2)").run();
  const result = await db.prepare("SELECT id, title, stars FROM notes WHERE stars >= ?1 ORDER BY id").bind(1).all();
  expect(result.success).toBe(true);
  expect(result.results).toEqual([
    { id: 1, title: "a", stars: 1 },
    { id: 2, title: "b", stars: 2 },
  ]);
  expect(result.meta.changes).toBe(0);
  expect(result.meta.changed_db).toBe(false);
  expect(result.meta.rows_written).toBe(0);
  expect(result.meta.rows_read).toBe(2);

  const none = await db.prepare("SELECT * FROM notes WHERE id = 99").all();
  expect(none.results).toEqual([]);
  // run() is the same as all(): a SELECT run with run() has its rows.
  const viaRun = await db.prepare("SELECT title FROM notes ORDER BY id").run();
  expect(viaRun.results).toEqual([{ title: "a" }, { title: "b" }]);
});

test("RETURNING gives rows from a write", async () => {
  const { db } = open();
  const result = await db.prepare("INSERT INTO notes (title) VALUES (?) RETURNING id, title").bind("r").run();
  expect(result.results).toEqual([{ id: 1, title: "r" }]);
  expect(result.meta.changes).toBe(1);
});

test("creating a table changes the database without changing rows", async () => {
  const { db } = open();
  const result = await db.prepare("CREATE TABLE more (a)").run();
  expect(result.meta.changed_db).toBe(true);
  expect(result.meta.changes).toBe(0);
  const nothing = await db.prepare("UPDATE notes SET stars = 1 WHERE id = 99").run();
  expect(nothing.meta.changed_db).toBe(false);
});

test("first(): a row, a column, null, a missing column", async () => {
  const { db } = open();
  await db.prepare("INSERT INTO notes (title, stars) VALUES ('a', 1), ('b', NULL)").run();
  expect(await db.prepare("SELECT id, title FROM notes ORDER BY id").first()).toEqual({ id: 1, title: "a" });
  expect(await db.prepare("SELECT id, title FROM notes ORDER BY id").first("title")).toBe("a");
  expect(await db.prepare("SELECT COUNT(*) AS total FROM notes").first<number>("total")).toBe(2);
  // No rows: null, with or without a column name.
  expect(await db.prepare("SELECT * FROM notes WHERE id = 99").first()).toBeNull();
  expect(await db.prepare("SELECT * FROM notes WHERE id = 99").first("title")).toBeNull();
  // A NULL value is null, not "column not found".
  expect(await db.prepare("SELECT stars FROM notes WHERE title = 'b'").first("stars")).toBeNull();
  await expect(db.prepare("SELECT id FROM notes").first("nope")).rejects.toThrow("D1_COLUMN_NOTFOUND: Column not found (nope)");
});

test("raw(): arrays, with column names on request", async () => {
  const { db } = open();
  await db.prepare("INSERT INTO notes (title, stars) VALUES ('a', 1), ('b', 2)").run();
  const statement = db.prepare("SELECT id, title FROM notes ORDER BY id");
  expect(await statement.raw()).toEqual([[1, "a"], [2, "b"]]);
  expect(await statement.raw({ columnNames: true })).toEqual([["id", "title"], [1, "a"], [2, "b"]]);
  expect(await statement.raw({ columnNames: false })).toEqual([[1, "a"], [2, "b"]]);
  // No rows: still the names when asked for.
  expect(await db.prepare("SELECT id, title FROM notes WHERE id = 99").raw({ columnNames: true })).toEqual([["id", "title"]]);
  // raw() keeps two columns of the same name apart; an object row can't (the later one wins).
  expect(await db.prepare("SELECT 1 AS x, 2 AS x").raw()).toEqual([[1, 2]]);
  expect((await db.prepare("SELECT 1 AS x, 2 AS x").all()).results).toEqual([{ x: 2 }]);
});

test("bind(): a new statement each time, ?NNN, and the type table", async () => {
  const { db } = open();
  const statement = db.prepare("SELECT ?2 AS second, ?1 AS first");
  const bound = statement.bind("one", "two");
  expect(bound).not.toBe(statement);
  expect(statement.params).toEqual([]);
  expect(bound.params).toEqual(["one", "two"]);
  expect(bound.statement).toBe("SELECT ?2 AS second, ?1 AS first");
  expect(await bound.first()).toEqual({ second: "two", first: "one" });
  // The same statement bound again is independent of the first binding.
  expect(await statement.bind("x", "y").first("first")).toBe("x");

  const types = await db
    .prepare("SELECT ? AS n, ? AS s, ? AS yes, ? AS no, ? AS none, ? AS real")
    .bind(7, "text", true, false, null, 1.5)
    .first();
  expect(types).toEqual({ n: 7, s: "text", yes: 1, no: 0, none: null, real: 1.5 });

  // Blobs: an ArrayBuffer, a view or an array of bytes goes in; a plain array of numbers comes out.
  const bytes = new Uint8Array([0, 1, 254, 255]);
  await db.prepare("INSERT INTO notes (title, data) VALUES ('buffer', ?), ('view', ?), ('array', ?)")
    .bind(bytes.buffer, bytes, [0, 1, 254, 255])
    .run();
  const blobs = await db.prepare("SELECT data, typeof(data) AS kind FROM notes ORDER BY id").all();
  expect(blobs.results).toEqual([
    { data: [0, 1, 254, 255], kind: "blob" },
    { data: [0, 1, 254, 255], kind: "blob" },
    { data: [0, 1, 254, 255], kind: "blob" },
  ]);
  expect(Array.isArray(blobs.results[0].data)).toBe(true);
});

test("bind() refuses types D1 has no place for", () => {
  const { db } = open();
  const statement = db.prepare("SELECT ?");
  expect(() => statement.bind(undefined)).toThrow("D1_TYPE_ERROR: Type 'undefined' not supported for value 'undefined'");
  expect(() => statement.bind({ a: 1 })).toThrow(/^D1_TYPE_ERROR: Type 'object' not supported/);
  expect(() => statement.bind(10n)).toThrow(/^D1_TYPE_ERROR: Type 'bigint'/);
  expect(() => statement.bind(() => 1)).toThrow(/^D1_TYPE_ERROR: Type 'function'/);
  expect(() => statement.bind([1, 300])).toThrow(/^D1_TYPE_ERROR/);
});

test("too few or too many bound parameters throw when the query runs", async () => {
  const { db } = open();
  const statement = db.prepare("INSERT INTO notes (title, stars) VALUES (?, ?)");
  // bind() itself checks nothing (on D1 the query has not been looked at yet).
  const tooFew = statement.bind("only one");
  await expect(tooFew.run()).rejects.toThrow(/^D1_ERROR: Wrong number of parameter bindings/);
  await expect(statement.run()).rejects.toThrow(/^D1_ERROR: Wrong number of parameter bindings/);
  await expect(statement.bind("a", 1, 2).all()).rejects.toThrow(/^D1_ERROR/);
  await expect(tooFew.first()).rejects.toThrow(/^D1_ERROR/);
  await expect(tooFew.raw()).rejects.toThrow(/^D1_ERROR/);
  // Nothing was written with a NULL in place of the missing value.
  expect(await db.prepare("SELECT COUNT(*) AS n FROM notes").first("n")).toBe(0);
});

test("SQL errors are D1_ERROR, thrown when the query runs, with the cause kept", async () => {
  const { db } = open();
  // prepare() never throws, not even for nonsense.
  const nonsense = db.prepare("SELEKT nothing");
  await expect(nonsense.all()).rejects.toThrow(/^D1_ERROR: /);
  await expect(db.prepare("SELECT * FROM missing").all()).rejects.toThrow(/^D1_ERROR: .*no such table: missing/);
  await db.prepare("INSERT INTO notes (title) VALUES ('same')").run();
  const error = await db.prepare("INSERT INTO notes (title) VALUES ('same')").run().catch((e: unknown) => e);
  expect(error).toBeInstanceOf(Error);
  expect((error as Error).message).toMatch(/^D1_ERROR: .*UNIQUE constraint failed: notes\.title/);
  expect((error as Error).cause).toBeInstanceOf(Error);
});

test("batch(): one result per statement, in order", async () => {
  const { db } = open();
  const insert = db.prepare("INSERT INTO notes (title, stars) VALUES (?, ?)");
  const results = await db.batch([
    insert.bind("a", 1),
    insert.bind("b", 2),
    db.prepare("SELECT title FROM notes ORDER BY id"),
  ]);
  expect(results.length).toBe(3);
  for (const result of results) {
    expect(Object.keys(result).sort()).toEqual(["meta", "results", "success"]);
    expect(result.success).toBe(true);
    expect(Object.keys(result.meta).sort()).toEqual(META_KEYS);
  }
  expect(results[0].results).toEqual([]);
  expect(results[0].meta.last_row_id).toBe(1);
  expect(results[1].meta.last_row_id).toBe(2);
  expect(results[2].results).toEqual([{ title: "a" }, { title: "b" }]);
  expect(await db.batch([])).toEqual([]);
});

test("batch() rolls back everything when one statement fails", async () => {
  const { db, sqlite } = open();
  await db.prepare("INSERT INTO notes (title) VALUES ('kept')").run();
  const insert = db.prepare("INSERT INTO notes (title) VALUES (?)");
  const failing = db.batch([insert.bind("new 1"), insert.bind("new 2"), insert.bind("kept"), insert.bind("new 3")]);
  await expect(failing).rejects.toThrow(/^D1_ERROR: .*UNIQUE constraint failed/);
  await failing.catch(() => {});
  expect((await db.prepare("SELECT title FROM notes").all()).results).toEqual([{ title: "kept" }]);
  expect(sqlite.inTransaction).toBe(false);
  // The database is usable afterwards.
  await db.batch([insert.bind("after")]);
  expect(await db.prepare("SELECT COUNT(*) AS n FROM notes").first("n")).toBe(2);
  await expect(db.batch(["SELECT 1" as never])).rejects.toThrow(/^D1_ERROR/);
});

test("exec(): count and duration, one query per line", async () => {
  const { db } = open();
  const result = await db.exec(
    "INSERT INTO notes (title) VALUES ('a')\nINSERT INTO notes (title) VALUES ('b');\n\nINSERT INTO notes (title) VALUES ('c')\n",
  );
  expect(Object.keys(result).sort()).toEqual(["count", "duration"]);
  expect(result.count).toBe(3);
  expect(typeof result.duration).toBe("number");
  expect(await db.prepare("SELECT COUNT(*) AS n FROM notes").first("n")).toBe(3);
});

test("exec() stops at the failing line and names it; earlier lines stay", async () => {
  const { db } = open();
  const failing = db.exec("INSERT INTO notes (title) VALUES ('a')\nINSERT INTO nowhere VALUES (1)\nINSERT INTO notes (title) VALUES ('c')");
  await expect(failing).rejects.toThrow(/^D1_EXEC_ERROR: Error in line 2: INSERT INTO nowhere VALUES \(1\): .*no such table/);
  await failing.catch(() => {});
  expect((await db.prepare("SELECT title FROM notes").all()).results).toEqual([{ title: "a" }]);
  // As on D1, a statement spread over several lines is several broken queries.
  await expect(db.exec("CREATE TABLE wide (\n  a TEXT\n)")).rejects.toThrow(/^D1_EXEC_ERROR: Error in line 1/);
});

test("what D1 has and the local database doesn't says so", async () => {
  const { db } = open();
  expect(() => db.withSession()).toThrow(/withSession\(\) is not available/);
  await expect(db.dump()).rejects.toThrow(/dump\(\) is not available/);
});

test("the file is in WAL mode, with a busy timeout and foreign keys on", async () => {
  const { db, sqlite, path } = open();
  expect(sqlite.query("PRAGMA journal_mode").get()).toEqual({ journal_mode: "wal" });
  expect(sqlite.query("PRAGMA busy_timeout").get()).toEqual({ timeout: 5000 });
  expect(sqlite.query("PRAGMA foreign_keys").get()).toEqual({ foreign_keys: 1 });
  // WAL is a property of the file: another connection finds it that way.
  const other = new Database(path);
  handles.push(other);
  expect(other.query("PRAGMA journal_mode").get()).toEqual({ journal_mode: "wal" });

  await db.exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)\nCREATE TABLE child (parent INTEGER REFERENCES parent(id))");
  await expect(db.prepare("INSERT INTO child (parent) VALUES (5)").run()).rejects.toThrow(/^D1_ERROR: .*FOREIGN KEY constraint failed/);
});

test("rows written by another connection are seen at once, and the other way round", async () => {
  const { db, path } = open();
  const other = new Database(path);
  handles.push(other);
  other.run("INSERT INTO notes (title) VALUES ('from outside')");
  expect((await db.prepare("SELECT title FROM notes").all()).results).toEqual([{ title: "from outside" }]);
  await db.prepare("INSERT INTO notes (title) VALUES ('from the worker')").run();
  expect(other.query("SELECT COUNT(*) AS n FROM notes").get()).toEqual({ n: 2 });
  // A table the other connection made after ours was opened.
  other.run("CREATE TABLE later (a)");
  other.run("INSERT INTO later VALUES (1)");
  expect(await db.prepare("SELECT a FROM later").first("a")).toBe(1);
});

// ---- Migrations -------------------------------------------------------------------------------

function migrationsFolder(files: Record<string, string>): string {
  const folder = join(scratch(), "migrations");
  mkdirSync(folder);
  for (const [name, sql] of Object.entries(files)) writeFileSync(join(folder, name), sql);
  return folder;
}

function emptyDatabase(): Database {
  const sqlite = openSQLite(join(scratch(), "DB.sqlite"));
  handles.push(sqlite);
  return sqlite;
}

test("migrations run in name order, once, and are recorded in d1_migrations", () => {
  const folder = migrationsFolder({
    // Written out of order on purpose; 0002 needs 0001's table, 0010 needs 0002's column.
    "0010_fill.sql": "INSERT INTO notes (title, stars) VALUES ('hello', 5);",
    "0001_init.sql": "-- the first table\nCREATE TABLE notes (\n  id INTEGER PRIMARY KEY,\n  title TEXT\n);\nCREATE INDEX notes_title ON notes (title);\n",
    "0002_stars.sql": "ALTER TABLE notes ADD COLUMN stars INTEGER;",
    "README.md": "not a migration",
    ".hidden.sql": "this would fail",
  });
  expect(migrationFiles(folder)).toEqual(["0001_init.sql", "0002_stars.sql", "0010_fill.sql"]);

  const sqlite = emptyDatabase();
  expect(applyMigrations(sqlite, folder)).toEqual(["0001_init.sql", "0002_stars.sql", "0010_fill.sql"]);
  expect(sqlite.query("SELECT title, stars FROM notes").all()).toEqual([{ title: "hello", stars: 5 }]);

  // The table wrangler makes: id, name, applied_at.
  const columns = sqlite.query("PRAGMA table_info(d1_migrations)").all() as { name: string; type: string; pk: number; notnull: number }[];
  expect(columns.map((c) => [c.name, c.type])).toEqual([["id", "INTEGER"], ["name", "TEXT"], ["applied_at", "TIMESTAMP"]]);
  const rows = sqlite.query("SELECT id, name, applied_at FROM d1_migrations ORDER BY id").all() as { id: number; name: string; applied_at: string }[];
  expect(rows.map((r) => [r.id, r.name])).toEqual([[1, "0001_init.sql"], [2, "0002_stars.sql"], [3, "0010_fill.sql"]]);
  expect(rows[0].applied_at).toMatch(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/);

  // Again: nothing to do, and the insert of 0010 did not run twice.
  expect(applyMigrations(sqlite, folder)).toEqual([]);
  expect(sqlite.query("SELECT COUNT(*) AS n FROM notes").get()).toEqual({ n: 1 });

  // A new file later: only that one runs.
  writeFileSync(join(folder, "0011_more.sql"), "INSERT INTO notes (title) VALUES ('later');");
  expect(applyMigrations(sqlite, folder)).toEqual(["0011_more.sql"]);
  expect(sqlite.query("SELECT COUNT(*) AS n FROM notes").get()).toEqual({ n: 2 });
});

test("a failing migration stops the run, names the file and leaves earlier ones applied", () => {
  const folder = migrationsFolder({
    "0001_init.sql": "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT);",
    // The first statement is fine, the second is not: neither may stay.
    "0002_broken.sql": "CREATE TABLE half (a);\nINSERT INTO nowhere VALUES (1);",
    "0003_never.sql": "CREATE TABLE never (a);",
  });
  const sqlite = emptyDatabase();
  let caught: unknown;
  try {
    applyMigrations(sqlite, folder);
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeInstanceOf(MigrationError);
  expect((caught as MigrationError).file).toBe("0002_broken.sql");
  expect((caught as MigrationError).message).toMatch(/no such table: nowhere/);
  expect(sqlite.inTransaction).toBe(false);

  const tables = (sqlite.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as { name: string }[])
    .map((t) => t.name)
    .filter((name) => !name.startsWith("sqlite_"));
  expect(tables).toEqual(["d1_migrations", "notes"]);
  expect(sqlite.query("SELECT name FROM d1_migrations").all()).toEqual([{ name: "0001_init.sql" }]);

  // Once the file is fixed, the run goes on from it.
  writeFileSync(join(folder, "0002_broken.sql"), "CREATE TABLE half (a);");
  expect(applyMigrations(sqlite, folder)).toEqual(["0002_broken.sql", "0003_never.sql"]);
});

test("no folder, an empty folder and a comment-only file", () => {
  const sqlite = emptyDatabase();
  expect(applyMigrations(sqlite, join(scratch(), "missing"))).toEqual([]);
  expect(applyMigrations(sqlite, migrationsFolder({}))).toEqual([]);
  // Nothing to apply: the database was not touched, not even with the migrations table.
  expect(sqlite.query("SELECT COUNT(*) AS n FROM sqlite_master").get()).toEqual({ n: 0 });
  expect(applyMigrations(sqlite, migrationsFolder({ "0001_empty.sql": "-- nothing yet\n/* really */\n" }))).toEqual(["0001_empty.sql"]);
  expect(sqlite.query("SELECT name FROM d1_migrations").all()).toEqual([{ name: "0001_empty.sql" }]);
});
