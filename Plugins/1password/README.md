# 1Password plugin

Adds a small button to login fields on web pages. Click it, pick a login from the menu, and the
username and password are filled in. Touch ID (through 1Password) unlocks the vault.

## What it can't do

- It has no internet access at all.
- The only program it may run is `op` (1Password's command line tool), and only `op item list` and
  `op item get`.
- It fills only when you click the button and then pick a login from the menu. Always a menu, even
  if there is one login.
- It runs only on `https://` pages, plus `http://localhost` and `http://127.0.0.1` (any port) for
  local development logins. Never on other plain `http://` pages.
- It fills only into the site the login belongs to (the login's website, or a subdomain of it).
- It never writes passwords to its log or keeps them; the log has counts only.
- It doesn't save or create logins.

## Requirements

- The 1Password app, with Settings -> Developer -> "Integrate with 1Password CLI" switched on.
- The `op` command line tool installed (for example `brew install 1password-cli`).

## Install

Settings -> Plugins -> Add Plugin... -> choose this folder (`Plugins/1password`), then approve it.
The approval sheet should say it runs `op` (only: item list, item get — plus any further arguments), that its page script reads and changes pages and could pass what it reads to other websites, and that its background program never uses the internet (the programs it runs can).
Then enable it in the Spaces where you want it.

## Files

- `plugin.json` the manifest and permissions
- `background.ts` talks to `op`
- `logic.ts` the parsing and matching rules (tests: `Vendor/bun/bun test Tests/plugins/1password` from the repo root)
- `page.ts` finds login fields and shows the button and menu

There is no `icon.png` on purpose: no trademarked logo shipped.
