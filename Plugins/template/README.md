# Template plugin

The smallest useful plugin. It puts a small button inside every `input[type=search]` field. Click
it and the page script sends a message to the background program, which logs it and answers; the
page shows the answer in a menu.

It asks for almost nothing: a page script on `https://` sites, no commands, no form filling, no
network.

## Try it

1. Copy this folder to somewhere else and rename it. The folder name must equal `id` in `plugin.json`.
2. Settings -> Plugins -> Add Plugin... -> choose the folder, then approve it.
3. Switch it on for a Space, open a page with a search field and click the button in the field.
4. Edit `page.ts` or `background.ts`. With development mode on (approval sheet or Settings), saving a
   file restarts the plugin. Without it, any change pauses the plugin until you approve again.

Read `docs/plugins/AUTHORING.md` for the full rules.
