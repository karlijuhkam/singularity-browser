// Tests for Resources/plugin-host/app-config.ts. Run from the repo root: Vendor/bun/bun test Tests/apps
import { expect, test } from "bun:test";
import { ConfigError, parseAppConfig, parseJSONC } from "../../Resources/plugin-host/app-config.ts";

test("comments and trailing commas", () => {
  const text = `{
    // the Worker
    "main": "src/index.ts", /* a block
    comment over two lines */
    "d1_databases": [
      { "binding": "DB", "database_name": "firma", "database_id": "local", },
    ],
    "vars": { "A": "1", },
  }`;
  expect(parseAppConfig(text)).toEqual({
    main: "src/index.ts",
    d1: [{ binding: "DB", migrationsDir: "migrations" }],
    vars: { A: "1" },
  });
});

test("comment marks and commas inside strings are kept", () => {
  const value = parseJSONC(`{
    "url": "https://example.com/a//b", // a real comment
    "block": "not /* a */ comment",
    "quote": "she said \\"hi\\" // still text",
    "backslash": "ends with a backslash \\\\", // so the quote before this closes the string
    "commas": "a,}", "list": "b,]",
  }`);
  expect(value).toEqual({
    url: "https://example.com/a//b",
    block: "not /* a */ comment",
    quote: 'she said "hi" // still text',
    backslash: "ends with a backslash \\",
    commas: "a,}",
    list: "b,]",
  });
});

test("JSONC odds and ends", () => {
  expect(parseJSONC("[1, 2, /* three */ 3,]")).toEqual([1, 2, 3]);
  expect(parseJSONC('\uFEFF{"a": 1}')).toEqual({ a: 1 });
  expect(parseJSONC('{"a": [1,\n  // nothing more\n  ],\n}')).toEqual({ a: [1] });
  expect(() => parseJSONC('{"a": 1 /* never closed')).toThrow(ConfigError);
  expect(() => parseJSONC('{"a": }')).toThrow(/not valid JSON/);
  // Two commas are still a mistake.
  expect(() => parseJSONC("[1,,]")).toThrow(ConfigError);
});

test("defaults: main is worker.ts, no databases, no vars", () => {
  expect(parseAppConfig("{}")).toEqual({ main: "worker.ts", d1: [], vars: {} });
  expect(parseAppConfig('{ "name": "firma", "compatibility_date": "2026-01-01" }').main).toBe("worker.ts");
});

test("vars are copied as they are", () => {
  const config = parseAppConfig('{ "vars": { "NAME": "x", "LIMIT": 3, "FLAGS": { "beta": true } } }');
  expect(config.vars).toEqual({ NAME: "x", LIMIT: 3, FLAGS: { beta: true } });
  expect(() => parseAppConfig('{ "vars": ["a"] }')).toThrow(/"vars" must be an object/);
});

test("d1_databases: binding and migrations_dir", () => {
  const config = parseAppConfig(`{
    "d1_databases": [
      { "binding": "DB" },
      { "binding": "ARCHIVE_2", "migrations_dir": "./db/archive/" }
    ]
  }`);
  expect(config.d1).toEqual([
    { binding: "DB", migrationsDir: "migrations" },
    { binding: "ARCHIVE_2", migrationsDir: "db/archive" },
  ]);
});

test("a binding that is not a JavaScript name is refused", () => {
  for (const binding of ['"my-db"', '"1DB"', '"a b"', '""', '"../DB"', "5", "null"]) {
    expect(() => parseAppConfig(`{ "d1_databases": [{ "binding": ${binding} }] }`)).toThrow(/"binding" must be a JavaScript name/);
  }
  expect(() => parseAppConfig('{ "d1_databases": [{}] }')).toThrow(ConfigError);
  expect(() => parseAppConfig('{ "d1_databases": [{ "binding": "DB" }, { "binding": "DB" }] }')).toThrow(/two "d1_databases" entries/);
  expect(() => parseAppConfig('{ "d1_databases": { "binding": "DB" } }')).toThrow(/must be a list/);
});

test("main and migrations_dir must stay inside the app folder", () => {
  for (const main of ["/etc/worker.ts", "../worker.ts", "src/../../worker.ts", "~/worker.ts", "C:\\\\worker.ts", "..", ""]) {
    expect(() => parseAppConfig(`{ "main": "${main}" }`)).toThrow(ConfigError);
  }
  for (const dir of ["/tmp/migrations", "../migrations", "a/../../b"]) {
    expect(() => parseAppConfig(`{ "d1_databases": [{ "binding": "DB", "migrations_dir": "${dir}" }] }`)).toThrow(ConfigError);
  }
  expect(() => parseAppConfig('{ "main": 5 }')).toThrow(/"main" must be a path/);
  expect(() => parseAppConfig('{ "main": "./" }')).toThrow(/"main" must name a file/);
  // "./" in front is fine, and a name that merely contains dots is too.
  expect(parseAppConfig('{ "main": "./src/index.ts" }').main).toBe("src/index.ts");
  expect(parseAppConfig('{ "main": "worker..v2.ts" }').main).toBe("worker..v2.ts");
});

test("the file must hold an object", () => {
  expect(() => parseAppConfig("[]")).toThrow(/one JSON object/);
  expect(() => parseAppConfig("")).toThrow(/not valid JSON/);
});
