// Singularity: turns one TypeScript/TSX/JSX file of an artifact into plain JavaScript for the browser.
//
// The app runs this with the bundled Bun, inside the same kind of sandbox as plugin programs (no
// network, no other programs, only a throwaway folder writable), on a *copy* of the file:
//
//     bun --config=bunfig.toml --no-env-file --no-install run transpile-artifact.ts <copy of the file>
//
// On success it prints the JavaScript on stdout and exits with 0. On a problem it prints the
// compiler's messages on stderr and exits with 1; the artifact server shows them in the page.
//
// One file in, one module out: every import stays an import (`external: ["*"]`), so the browser
// asks the artifact server for "./other" (which compiles that file in turn) and resolves bare
// names like "react" through the page's import map. Nothing is bundled and nothing is installed.
// The bundler, not Bun.Transpiler, because only the bundler adds the import of the JSX runtime
// that compiled TSX needs.

const file = process.argv[2];
let problem = "";
let javascript = "";
if (!file) {
  problem = "no file given";
} else {
  try {
    const result = await Bun.build({
      entrypoints: [file],
      external: ["*"],
      target: "browser",
      format: "esm",
      // "production": compiled TSX imports "react/jsx-runtime" (one import-map entry), not the
      // development runtime, and `process.env.NODE_ENV` (which browsers don't have) is filled in.
      define: { "process.env.NODE_ENV": '"production"' },
      throw: false,
    });
    if (result.success && result.outputs.length > 0) {
      javascript = await result.outputs[0].text();
    } else {
      problem = result.logs.map((log) => describe(log)).join("\n") || "the file could not be compiled";
    }
  } catch (error) {
    const inner = (error as { errors?: unknown[] })?.errors;
    problem = Array.isArray(inner) && inner.length > 0 ? inner.map(describe).join("\n") : describe(error);
  }
}

function describe(entry: unknown): string {
  const item = entry as { message?: string; position?: { line?: number; column?: number; lineText?: string } | null };
  if (item && typeof item.message === "string") {
    const at = item.position?.line ? ` (line ${item.position.line}${item.position.column ? `, column ${item.position.column}` : ""})` : "";
    const text = item.position?.lineText ? `\n    ${item.position.lineText.trim()}` : "";
    return item.message + at + text;
  }
  return String(entry);
}

// Awaited writes, and no process.exit(): exiting straight away can drop output not yet written.
if (problem) {
  await Bun.write(Bun.stderr, problem.slice(0, 4000) + "\n");
  process.exitCode = 1;
} else {
  await Bun.write(Bun.stdout, javascript);
}
