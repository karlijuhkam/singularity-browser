# TypeScript and TSX artifacts: design

Status: **built on 2026-11-10.** The owner handed the design choices to the builder ("I'll allow
you to choose where design choices are needed and will review in the end"). Everything under
"Builder's calls" is open to that review.

## Intent: why

Agents write artifacts for the owner to look at. Until now an artifact had to be plain HTML and
JavaScript, or come with a build step the agent runs itself. Agents write TypeScript and TSX more
naturally (and with fewer mistakes) than hand-rolled DOM code. The owner wants: the agent writes
`app.tsx`, the artifact tab opens it. No build step, no `node_modules`.

## Goals

1. A `.ts`, `.tsx`, `.jsx` or `.mts` file in a Space's `artifacts/` folder runs in an artifact tab.
2. Files can import each other the way TypeScript is normally written (`import "./util"`).
3. A mistake in a file is shown in the page and in the console, with the line.
4. Editing a file reloads the tabs that show it, as for HTML artifacts.

## Non-goals

- Bundling, minifying, type checking (types are removed, not checked).
- Installing or resolving npm packages. See "Open question for the owner".
- CSS or JSON imports from scripts (`import "./style.css"` does not work; use a `<link>`).
- API routes or any server-side code on the artifact server. It still only answers GET and HEAD
  with files; a compiled file is the same file, as JavaScript.

## Anti-goals

- The compiler reading or writing anything outside a throwaway folder.
- A compile step that needs the network.
- Anything that weakens the artifact server's token, Host check or path rules.

## How it works

- **Compile on request.** When the browser asks the artifact server for a script file, the server
  compiles that one file and answers with JavaScript (`text/javascript`). Nothing is written to
  the artifacts folder.
- **Bun, in the plugin sandbox, on a copy.** `Resources/plugin-host/transpile-artifact.ts` runs
  under `sandbox-exec` with the same generated profile and flags as plugin code (no network, no
  other programs, one throwaway writable folder). It gets a *copy* of the file, named
  `module.<ext>`; Bun never sees the artifacts folder. This is narrower than the idea's "read the
  Space's `artifacts/`".
- **One file in, one module out.** `Bun.build` with every import external. `Bun.Transpiler` was
  tried first and dropped: it compiles TSX to calls of a JSX runtime it does not import.
- **Imports.** Relative imports stay as written. The server resolves a path without an extension
  by trying `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs` and `/index.*`, each through the same containment
  check as any other request. Bare imports (`"react"`) stay as written too; the browser resolves
  them through the page's import map.
- **JSX** compiles to the automatic runtime: `import { jsx } from "react/jsx-runtime"`. The page's
  import map decides what that is.
- **Opening a script as a page.** A page load of a script (the request's `Accept` asks for HTML)
  gets a small HTML page: `<div id="root">` and the script as a module. If the script's folder has
  an `importmap.json`, its content goes into the page as the import map (only if it is a JSON
  object, and written so it can't close its script tag). Imports of the same file get JavaScript.
- **Which scripts open a tab by themselves.** `app.tsx`, `index.tsx`, `main.tsx` (and `.jsx`), and
  only when their folder has no HTML page. With an HTML page the page is the artifact and loads
  the script itself. Other scripts never open a tab on their own; any of them can be opened by
  address.
- **Errors.** A file that doesn't compile is answered with a module that writes the compiler's
  message to the console and to the top of the page.
- **Cache.** In memory, per file path, tied to modification time and size. Gone on quit. (The idea
  spoke of a cache folder; memory is enough and leaves nothing to clean up.)
- **Without Bun** (a build that wasn't given it) the error module says so.

## Open question for the owner: packages

Round 1 ships **no packages**. A TSX artifact that uses React needs an import map that says where
`react`, `react-dom/client` and `react/jsx-runtime` come from: files the agent put next to the
page, or a CDN such as esm.sh. That works today, but it is not yet "no CDN script".

Shipping React inside Singularity would close that gap. It is a new bundled dependency, which
CLAUDE.md says to ask about first, so it is not built. It is listed in `IDEAS.md` under "New, not
yet decided". Arbitrary packages would need the plugins' "declared and pinned" rule and are a
separate project.

## Builder's calls (the owner can overrule any)

- No packages in round 1; the import map is the author's.
- The copy-in sandbox instead of read access to the artifacts folder.
- Automatic JSX runtime, production mode (`react/jsx-runtime`, not the development runtime).
- The entry names that open a tab, and "not when the folder has an HTML page".
- `importmap.json` next to a script as the way to give a directly opened script its import map.
- Memory-only cache.
- `.jsx` and `.mts` are compiled as well.

## Where things are

- `Sources/SingularityCore/Artifacts/ArtifactScripts.swift`: what is compiled, module resolution,
  the shell page, the error module, `ArtifactCompiler`.
- `Sources/SingularityCore/Plugins/PluginPageCompiler.swift`: `runHostScript`, the sandboxed Bun
  run shared with plugin page scripts.
- `Sources/Singularity/Artifacts/ArtifactScriptService.swift` (cache) and `ArtifactServer.swift`.
- `Resources/plugin-host/transpile-artifact.ts`.
- Tests: `Tests/SingularityCoreTests/ArtifactScriptTests.swift` (the compiler tests need
  `Vendor/bun/bun`).

Checked by hand in a second copy of the app: a `.tsx` opened directly, an HTML page importing
`.ts` files without extensions, TSX through an import map, a syntax error, reload after an edit.
