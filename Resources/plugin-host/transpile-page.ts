// Singularity: turns a plugin's page.ts into plain JavaScript for web pages.
//
// The app runs this with the bundled Bun, inside the same kind of sandbox as plugin background
// programs (no network, no other programs, only a throwaway folder writable):
//
//     bun --config=bunfig.toml --no-env-file --no-install run transpile-page.ts <copy of page.ts>
//
// On success it prints the JavaScript on stdout and exits with 0. On a problem it prints one line
// explaining it on stderr and exits with 1; Settings → Plugins shows that line.
//
// Round 1 rules: page.ts is a single file. It can't import anything (static or dynamic imports,
// including import() of a computed path), and it can't export anything, because it runs as a
// plain script inside the page.

type Outcome = { ok: true; javascript: string } | { ok: false; problem: string };

function transpile(source: string): Outcome {
  const transpiler = new Bun.Transpiler({ loader: "ts" });
  let scanned: { imports: { path: string }[]; exports: string[] };
  try {
    scanned = transpiler.scan(source);
  } catch (error) {
    return { ok: false, problem: `page.ts has a syntax error: ${describe(error)}` };
  }
  if (scanned.imports.length > 0) {
    const paths = scanned.imports.map((i) => JSON.stringify(i.path)).join(", ");
    return { ok: false, problem: `page.ts can't import other files in round 1 (it imports ${paths})` };
  }
  if (scanned.exports.length > 0) {
    return { ok: false, problem: "page.ts can't export anything: it runs as a plain script in the page" };
  }
  let javascript: string;
  try {
    javascript = transpiler.transformSync(source);
  } catch (error) {
    return { ok: false, problem: `page.ts has a syntax error: ${describe(error)}` };
  }
  // scan() only reports imports of fixed paths; import(someVariable) would load a module from
  // anywhere. Any "import(" left in the output is refused (even in a string or comment: rename it).
  if (/\bimport\s*\(/.test(javascript)) {
    return { ok: false, problem: "page.ts can't import other files in round 1 (it uses import())" };
  }
  return { ok: true, javascript };
}

function describe(error: unknown): string {
  // Bun reports parse errors as an AggregateError ("Parse error") whose `errors` say where.
  const inner = (error as { errors?: unknown[] })?.errors;
  if (Array.isArray(inner) && inner.length > 0) return inner.map(String).join("; ");
  return error instanceof Error ? error.message : String(error);
}

const file = process.argv[2];
const outcome: Outcome = file ? transpile(await Bun.file(file).text()) : { ok: false, problem: "no file given" };
// Awaited writes, and no process.exit(): exiting straight away can drop output not yet written.
if (outcome.ok) {
  await Bun.write(Bun.stdout, outcome.javascript);
} else {
  await Bun.write(Bun.stderr, outcome.problem.replace(/\s+/g, " ").slice(0, 500) + "\n");
  process.exitCode = 1;
}
