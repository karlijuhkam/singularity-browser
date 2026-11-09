# Ideas parking lot

Things that came up while building but are not in the v1 brief. Nothing here gets built without an explicit decision.

- Drag and drop tabs between sections (pinned ↔ folder ↔ open). v1 uses context menus for moves and drag only to reorder within a section.
- Download progress UI (v1 saves straight to ~/Downloads without UI).
- Artifact tabs whose file was deleted currently show the server's "Not Found"; could close or mark them instead.
- HTTP Range requests on the artifact server (seeking in large video/audio artifacts).
- "Show Tab" button in the agent approval sheet, so you can look at the page an agent wants to act on before allowing it (considered in Phase 5, left out).
- **TypeScript/TSX artifacts via the bundled Bun** (owner wants this; after plugins round 1). Agents could write `app.tsx` (e.g. React components) and the artifact tab just opens it, with no build step and no CDN script. The Swift artifact server (FlyingFox, token cookie, Host check) stays as it is; Bun only compiles. When a `.ts`/`.tsx` page or import is requested, Singularity compiles it with Bun under the plugin sandbox profile (read the Space's `artifacts/`, write a cache folder, no network) and serves plain JavaScript. It reuses the sandboxed-Bun code from plugins (SandboxProfile, PluginProcess flags, Bun.Transpiler). Open question: npm imports. Either none or a small vendored set (React) first; arbitrary packages would need the plugins' "declared and pinned" rule. Still no API routes or server-side code on the artifact server.
- Ghostty as the terminal engine, if Ghostty ever ships a stable embeddable terminal *view*. As of Nov 2026 only libghostty-vt (emulation core, no rendering/PTY/input) is stable, which would mean writing our own renderer; SwiftTerm already covers all of that.
- **Web-extension compatibility** (parked; decision: native plugins instead). Spikes in Nov 2026. Safari: the 1Password Safari extension wasn't usable in a WKWebView app; PlugInKit found 0 plugins, so there is no native messaging. Chrome: the 1Password Chrome extension under WKWebExtension lacked APIs (e.g. `chrome.notifications`), and shims weren't enough. So Singularity plugins (`docs/plugins/AUTHORING.md`) replace extensions.
- **Import from Arc** (owner request; a separate project, to brainstorm later). Arc keeps its sidebar in a local file, and it maps closely onto Spaces, pinned tabs and folders. Logins and cookies are a separate, harder question.
- **Developer tools and site settings** (being designed with the owner; a design doc will follow). Agents reading console errors and failed network responses per Space and site; a site settings button next to the address with camera, microphone and screen permissions, device choice and per-site plugin switches; and a fix for right-click Inspect Element.
- **Plugin storage API** (round 2+). A `singularity.storage` for plugin backgrounds; round 1 has none (only the data folder).
