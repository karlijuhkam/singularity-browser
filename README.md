# Singularity

A native macOS browser organised in **Spaces**, whose sidebar holds web pages, terminals and locally generated HTML artifacts side by side. External agents (e.g. Claude Code running in a terminal tab) can drive it through an MCP server. There is no built-in AI.

> This README grows into the full 5-minute setup in phase 6. For architecture and scope, see `CLAUDE.md`.

## Build and run

Requires macOS 14+ and full Xcode. `scripts/env.sh` looks for it at `/Volumes/Zealot/Xcode.app`; set `XCODE_APP=/path/to/Xcode.app` to use another copy.

```sh
scripts/run.sh      # build build/Singularity.app and launch it
scripts/test.sh     # unit tests
```

## Connect Claude Code (MCP)

1. In Singularity, right-click a Space → **Edit Space…** → switch on **Allow agents**. Only Spaces with this switch are visible to agents.
2. Register the server once, for all your projects (`-s user`; without it, Claude Code only loads the server in the folder where you ran the command):

   ```sh
   claude mcp add -s user singularity -- /path/to/Singularity.app/Contents/MacOS/singularity-mcp
   ```

   For a development build that is `…/Singularity-Browser/build/Singularity.app/Contents/MacOS/singularity-mcp`. If Singularity isn't running, the command starts it.

3. In Claude Code, the tools show up as `mcp__singularity__list_spaces`, `mcp__singularity__work_read_page`, and so on (Singularity names them `work.read_page`; Claude Code turns the dot into an underscore).

Terminal tabs set `SINGULARITY_SPACE` to their Space's slug (and `TERM_PROGRAM=Singularity`), so an agent running inside Singularity knows which Space's tools are "its" browser.

Tools per Space: `list_tabs`, `open`, `navigate`, `close`, `read_page`, `find`, `click`, `type`, `screenshot`. `read_page` returns an outline of the page where interactive elements carry refs like `[12] button "Add to cart"`; pass those refs to `click` and `type`. Everything taken from a page is wrapped in an `<untrusted_page_content>` block.
