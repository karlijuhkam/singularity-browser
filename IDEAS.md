# Ideas parking lot

Things that came up while building but are not in the v1 brief. Nothing here gets built without an explicit decision.

- Drag and drop tabs between sections (pinned ↔ folder ↔ open). v1 uses context menus for moves and drag only to reorder within a section.
- Configurable search engine (v1 hard-codes DuckDuckGo in `URLInput.searchURL`).
- Download progress UI (v1 saves straight to ~/Downloads without UI).
- Artifact tabs whose file was deleted currently show the server's "Not Found"; could close or mark them instead.
- HTTP Range requests on the artifact server (seeking in large video/audio artifacts).
- Tiling / split view: show two or more tabs side by side (e.g. a terminal with an agent next to the page it drives). Out of scope for v1 per the brief; owner asked about it after Phase 4. Touches the content area, focus, Cmd+W, persistence, and agent tools (which pane is "current").
