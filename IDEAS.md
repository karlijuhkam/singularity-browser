# Ideas parking lot

Things that came up while building but are not in the v1 brief. Nothing here gets built without an explicit decision.

- Drag and drop tabs between sections (pinned ↔ folder ↔ open). v1 uses context menus for moves and drag only to reorder within a section.
- Download progress UI (v1 saves straight to ~/Downloads without UI).
- Artifact tabs whose file was deleted currently show the server's "Not Found"; could close or mark them instead.
- HTTP Range requests on the artifact server (seeking in large video/audio artifacts).
- "Show Tab" button in the agent approval sheet, so you can look at the page an agent wants to act on before allowing it (considered in Phase 5, left out).
- Ghostty as the terminal engine, if Ghostty ever ships a stable embeddable terminal *view*. As of Nov 2026 only libghostty-vt (emulation core, no rendering/PTY/input) is stable, which would mean writing our own renderer; SwiftTerm already covers all of that.
