# 1Password plugin, round 2: design

Date: 2026-11-13. Status: draft, waiting for the owner's approval. Nothing is built.

## Why

The owner uses the bundled 1Password plugin (`Plugins/1password/`) every day and finds it weak.
In the owner's words: "no passkey functionality, choosing the correct login is flimsy", and
"there is noticable delay when filling the credentials". Asked what "flimsy" means, the owner
picked two of three problems put to them:

1. The button only appears next to a password field, so sign-ins that ask for the email first and
   the password on the next page get no button on the first page.
2. The right login is not offered (as opposed to too many being offered). The owner could not give
   an example site.

The owner also asked for one-time codes ("it would be neat if it offered OTP codes too") and for
passkeys.

Real extension support was looked at first and is not the answer: `IDEAS.md` already records it
under "Decided against", and a spike on 2026-11-13 repeated the result (the Safari build of the
1Password extension loads but its sign-in does nothing; the Chrome build fails on APIs WebKit
lacks). So the owner decided: "lets fix our current implementation then".

## Goals

- A 1Password button on sign-in steps that have only a username or email field.
- Logins saved under a related address of the same site are offered.
- The menu appears faster, and the login used last on a site is on top.
- One-time codes can be filled from the same button.

## Not in this round

- **Passkeys.** Not possible in the plugin. Tested 2026-11-13 in a WKWebView app without special
  entitlements: `navigator.credentials.create` on webauthn.io fails with `NotAllowedError` and the
  macOS passkey sheet never appears. It needs Apple's restricted entitlement
  `com.apple.developer.web-browser.public-key-credential`, which only the owner can request (it
  belongs to their developer account). Once granted, the macOS sheet should offer 1Password, whose
  system autofill extension is already enabled on the owner's Mac. That is its own later piece of
  work; this design only records it in `IDEAS.md`.
- **Searching all logins** and filling one saved for an unrelated site (or with no website). It
  would mean filling a login into a site it is not saved for, which is what the fill guard exists
  to stop. Recorded in `IDEAS.md` under "New, not yet decided".
- Saving or creating logins, generating passwords, filling cards or addresses.
- Any way to fill without a click on the button and a pick from the menu.

## What must not happen (anti-goals)

- The fill guard gets looser. Every fill still needs: the frame's host is `forHost` or a subdomain
  of it, the URL matches `fillForms`, and a genuine click (`FillGuard` in
  `Sources/SingularityCore/Plugins/PluginPage.swift`). `CLAUDE.md`: "Don't loosen these without the
  owner."
- A login is offered on a different site that merely shares a public suffix (`a.github.io` and
  `b.github.io`, `x.co.uk` and `y.co.uk`).
- `op` runs, or Touch ID is asked for, without the user having clicked the plugin's button.
- A password or one-time code is logged, stored, or kept in memory after it was sent to the page.
- The plugin gets a new command, network access, or wider site lists.

## The four changes

Decisions marked **(my call)** were made by the designer, not the owner. The owner should check
them when reading.

### 1. A button on username-only steps

`page.ts` today decorates each first password field and the username field before it. Add: a
usable `text`/`email` input with no usable password field in the same form (or, without a form, on
the page) gets the button when it looks like a sign-in step **(my call, the rule)**:

- `autocomplete` contains `username` (always enough by itself), or
- one of: `type=email`, `autocomplete=email`, or a `name`/`id` matching a small word list (`user`,
  `login`, `email`, `identifier`, `account`); **and**, for every case in this second line, the form
  (or page) has no more than two usable text inputs, so sign-up, newsletter and contact forms with
  several fields are left alone. A lone newsletter email field can still get a button; it only
  opens a menu, and nothing is filled without a pick.

Search boxes (`type=search`, `role=search` on the form, name `q`) never get it. The exact word
lists are the builder's to settle, with tests on the pure part.

Picking a login there fills only the username. The background answers from the list it already
has (`{ fill: { forHost, username } }`), so `op item get` does not run and no password leaves
1Password for this step. This relies on `additional_information` in `op item list` being the
login's full username; `logic.ts` calls it "a hint". The builder checks that first on the owner's
Mac (one `op item list`, with the owner's agreement). If it is not always the full username, the
username step runs `op item get` like a password fill and returns only the username. A login with an empty username shows in the menu but picking it shows
"This login has no username". The password page is handled as today.

### 2. Matching on the site's main domain

Today an item matches when the frame's host is the item's host or a subdomain of it. A login saved
for `app.example.com` is not offered on `login.example.com`. New rule, the same one 1Password
uses by default: an item matches when its host and the frame's host have the same *registrable
domain* (`example.com` for both).

Finding the registrable domain needs the Public Suffix List, or `github.io` and `co.uk` would
count as one site. macOS has no public API for it. **(My call, needs the owner's yes because it
ships a third-party data file):** put a snapshot of `public_suffix_list.dat` (Mozilla, MPL-2.0,
about 300 KB, both its ICANN and private sections) in the plugin folder, with a short note on
where it came from and its date. `logic.ts` parses it (plain rules, wildcards `*.` and exceptions
`!`). Reading a file in its own folder is already allowed in the sandbox. It is data, not code or
a package.

Safety of the rule:

- The background returns `forHost` = the registrable domain. The app's existing check (frame host
  equals `forHost` or is a subdomain of it) then passes unchanged, so no Swift change is needed.
- **What this costs, for the owner to accept or not:** the app's check is weaker in effect. Today
  it compares the frame with the host the login is saved under. After this it compares the frame
  with whatever the plugin's own suffix-list code computed, so a bug there (returning `co.uk`)
  would pass the app's check too. The protection against that is the tests on the parsing, and
  that the plugin is reviewed code. The plugin README's line "fills only into the site the login
  belongs to (the login's website, or a subdomain of it)" changes to "... or another address of
  the same site (same main domain)".
- If the owner says no to the suffix list, change 2 is dropped: matching stays as today, and the
  menu order below still applies (without the same-domain group).
- If the registrable domain cannot be determined (an IP address, `localhost`, a host that is
  itself a public suffix, the list file missing or unreadable), fall back to today's rule: exact
  host or subdomain only.

Menu order **(my call)**: the login last used on this host first, then exact-host matches, then
subdomain matches, then other same-domain matches; alphabetical by title inside each group. The
subtitle stays the username; for a login saved under a different host of the same domain, the
subtitle also shows that host, so two "Example" logins can be told apart. `showMenu` allows 50
entries; more than that are cut and the last entry says how many were left out.

"Last used" is the item id per host, kept with `singularity.storage` (ids are not secrets; the
storage file is plain, which the authoring guide allows for non-secrets).

### 3. Speed

Today every click starts `op item list` for the whole vault, and every fill starts `op item get`.
Each start talks to the 1Password app.

- Keep the parsed list in memory for 5 minutes **(my call)**: ids, titles, usernames and hosts
  only, as today's `listed` map already keeps for 2 minutes. A click within that time opens the
  menu without starting `op`. The list is fetched only after a click, never ahead of one.
- So a new login is not invisible for 5 minutes: when the remembered list has no match for the
  site, fetch it again once before showing "No logins for this site".
- `op item get` on a password fill stays; it is the step that asks 1Password for the secret.
- The builder measures both `op` calls on the owner's Mac before and after (with the owner's
  agreement, since it can raise a Touch ID prompt) and writes the numbers into this document's
  "As built" section. If the single `op item get` is still the noticeable delay, that is reported
  to the owner rather than worked around by fetching secrets early.

### 4. One-time codes

A code field gets the button when it is a usable input with `autocomplete=one-time-code`, or a
numeric-looking input (`inputmode=numeric`, `type=tel`/`number`/`text` with `maxlength` 6 to 8)
whose `name`/`id`/label matches a small word list (`otp`, `totp`, `2fa`, `mfa`, `code`,
`verification`) **(my call, the rule; word lists are the builder's)**. Split fields (six
one-character boxes) count as one code field: the button goes on the first box.

A click shows the same menu of this site's logins, last used on top. Picking one runs
`op item get <id> --otp`, which prints only the current code. That fits the already approved
command (`"op": ["item get"]` plus further arguments), so the manifest's permissions do not
change. A login without a one-time code shows "This login has no one-time code". The list does not
say which logins have a code, and finding out would mean one `op` start per login, so the menu
lists them all **(my call)**.

The app side needs one small addition, because a fill reply and `fillLogin` know only `username`
and `password` today:

- `FillGuard`: a fill reply may also carry `code`, which must be a string when present (as
  `username` and `password` are checked today). Same three conditions. The guard does not reject
  unknown keys today and that is left alone: making it strict would change it for every plugin.
- `PluginPrelude`: `singularity.fillLogin` also accepts `codeInput` and `code`. For split boxes
  `page.ts` calls it once per box with one character each.
- `docs/plugins/AUTHORING.md` and `Plugins/template/` (the `declare const singularity` block) are
  updated; the review checklist's line on secrets already names one-time codes.

The code is never logged or stored, like the password. The log line is "filled a one-time code".

## What the owner sees

- Email-first sign-in: a 1Password button in the email field. Click, pick, the email is filled.
  On the password page: click, pick, Touch ID if 1Password asks, the password is filled.
- Code page: a 1Password button in the code field. Click, pick, the code is filled.
- The menu opens at once when it was used in the last few minutes, with the login used last on
  this site on top.
- The plugin's files change, so Singularity pauses it and asks for approval again (unless
  development mode is on). The approval sheet's permission lines are the same as before. How the
  owner's installed copy in `~/Singularity/plugins/1password` gets the new files (Add Plugin…
  again, or copy) is the builder's to check against `PluginInstaller` and describe.

## Constraints

- `CLAUDE.md`: boring readable code, comments for the non-obvious, no new dependencies without the
  owner (the suffix list above is the one thing asked for).
- `page.ts` rules in `docs/plugins/AUTHORING.md`: no imports, no network, a fill only after a menu
  pick, one `send` per click carries the click token.
- Plugin version becomes 0.2.0; `README.md` of the plugin is updated: every line of "What it
  can't do" stays true except the one on where it fills, which changes as described in change 2.

## Testing

- `Tests/plugins/1password/logic.test.ts` (Bun): suffix-list parsing and registrable domains
  (`co.uk`, `github.io`, wildcard and exception rules, IP addresses, `localhost`), the fallback,
  menu order, parsing of `op item get --otp` output, the pure parts of field classification.
- `Tests/SingularityCoreTests/PluginPageTests.swift`: a fill reply with `code` passes and fails
  under the same conditions as one with `password`; a `code` that is not a string is malformed.
- `scripts/probe-plugin-frames.sh` after the `PluginPrelude` change, as `CLAUDE.md` requires.
- Field detection on real pages cannot be scripted here (no clicks into a test copy, and the
  owner's real 1Password must not be driven by tests). The builder lists the hands-on checks for
  the owner: an email-first sign-in, a code page with one field, a code page with split boxes, a
  site with logins under two subdomains.
- `scripts/test.sh` passes.

## Left to the builder

File layout inside the plugin, the exact word lists and limits, message names between `page.ts`
and `background.ts`, how the suffix list is loaded and cached in the background program, wording
of menu entries and log lines.

## Also part of this work

`IDEAS.md`, under "New, not yet decided": passkeys (waiting on Apple's entitlement, with the test
result above) and the "search all logins" entry (with the reason it was left out). The existing
"Decided against" entry on web extensions gets one line saying the 2026-11-13 spike confirmed it.
