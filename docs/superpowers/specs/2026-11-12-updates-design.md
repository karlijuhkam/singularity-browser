# Going public and updating itself: design

Date: 2026-11-12. Status: approved by the owner (2026-11-12).

## Why

The owner wants to use Singularity as their daily browser from now on, and a few friends will
follow later. Today a new version reaches the owner only by running `scripts/run.sh`, which
replaces the very bundle the daily copy runs from (`build/Singularity.app`). There is no GitHub
repository, no version bumping and no way for an installed copy to learn that a newer one exists.

The owner's words: "one command on this Mac", "a convenient update method", "treat it as beta
only, with one track", "open source and public", "MIT licence", "yes to Sparkle".

## What success looks like

1. The owner runs **one command** on this Mac. Some minutes later a release is on GitHub.
2. The owner's daily copy, running from `/Applications`, notices within about an hour (or at once
   via "Check for Updates…"), shows what is new, and restarts into the new version when the owner
   says so.
3. Tabs, Spaces, logins and the agents' connection are exactly as before the update.
4. Anyone can clone the repository and build it.

## Goals

- A public repository `karlijuhkam/singularity-browser`, MIT-licensed.
- `scripts/release.sh <version>` does everything from version bump to published release.
- The app updates itself with Sparkle from GitHub Releases.
- One update track. The feed format leaves room for a second one later.
- Works today with the owner's Apple Development certificate (the owner's own Mac). Notarized
  releases switch on by themselves once the owner has a Developer ID certificate and the notary
  profile; that is required before friends install.

## Non-goals

- Stable / beta / nightly tracks and a track picker. Not now.
- Building on GitHub (Actions, certificates in secrets). GitHub only stores files.
- Delta updates, a DMG, a Homebrew cask, a download web page.
- Silent background installs. The owner always confirms the restart.
- Keeping terminal tabs alive across the update restart (herdr-core terminals already survive).

## Anti-goals (a failure even if it "works")

- A test copy, a debug build or a test run ever checks for updates, downloads one, or replaces
  itself. Only bundles made by `release.sh` have a live updater.
- An update that changes the bundle ID, moves data, or logs the owner out of sites.
- A release that can be half-published: a tag without files, or files the app can see before
  they are complete.
- The update private key, a certificate or a notary password in the repository or on GitHub.
- Personal details in the public history (done, see "Already done").
- The updater sending anything about the user. No system profile, no analytics.

## Already done (2026-11-12, by the owner's decision)

All 73 commits on all 11 branches were rewritten: the other company's signing team name and ID
are gone from `CLAUDE.md`, the owner's work Space and repository names in the projects spec
became neutral ones, and every commit carries the owner's GitHub no-reply address
(`33862438+karlijuhkam@users.noreply.github.com`, also set as this repository's `user.email`).
A scan of every commit finds none of those strings. The untouched original is kept at
`~/Developer/Singularity-Browser-backup-2026-11-12.git` (a mirror clone; never push it).

## The parts

### 1. The public repository

- `gh repo create karlijuhkam/singularity-browser --public`, description "A native macOS browser
  organised in Spaces: web pages, terminals and local HTML artifacts side by side."
  (Claude's wording.)
- Only `main` is pushed. The ten other local branches are finished phases already merged, or
  work in progress (`inbox`); they stay local. (Claude's call.)
- `LICENSE`: MIT, "Copyright (c) 2026 Karli Juhkam". README gets a licence line, an "Install"
  section (download the zip from Releases, move to Applications) and a "Releasing" section.
- `scripts/env.sh` keeps the owner's drive path as its first guess and its existing fallback to
  the system's selected Xcode, and additionally tries `/Applications/Xcode.app`, so a stranger
  can build without setting anything. The error message stops assuming the owner's drive.
- Before the first push: run the history scan once more and build and test from a fresh clone.
- Making the repository public is the one step that cannot be taken back. The builder does it
  only as its own, announced step.

### 2. Versions

- `CFBundleShortVersionString` is what people see (`0.2.0`); `CFBundleVersion` is a whole number
  that goes up by one with every release and is what Sparkle compares. Both live in
  `Resources/Info.plist`, as today.
- Tags are `v<version>`. The first published release is `0.2.0`, build `2`. (Claude's call.)

### 3. Sparkle in the app

- **Dependency:** Sparkle 2 (owner-approved 2026-11-12), added to `Package.swift` and to the
  allowed list in `CLAUDE.md`. It ships as a binary framework; SwiftPM links it, and the bundle
  scripts must copy `Sparkle.framework` into `Contents/Frameworks/`, make the executable find it
  there (rpath), and sign its inner helpers inside-out before the app, with the same identity
  and the hardened runtime. Follow Sparkle's own documentation for "apps not built with Xcode"
  and for signing; verify, do not rely on memory. Its licence goes into
  `THIRD-PARTY-NOTICES.txt` (`scripts/make-notices.sh`).
- **Update key:** an EdDSA key pair made once with Sparkle's `generate_keys`. The private key
  stays in the owner's login keychain; the public key goes into `Info.plist` (`SUPublicEDKey`).
  The app accepts only updates signed with it, so a taken-over GitHub account alone cannot push
  code. The owner must keep a copy of the private key somewhere safe (their password manager):
  without it no installed copy can ever be updated again.
- **Feed:** `SUFeedURL` =
  `https://github.com/karlijuhkam/singularity-browser/releases/latest/download/appcast.xml`.
  Each release carries its own `appcast.xml` as a file next to the zip; GitHub's "latest" link
  always resolves to the newest one. Nothing has to be committed after a release, and no other
  hosting is involved. Releases are published as normal releases, not GitHub "pre-releases"
  (those are skipped by "latest"), even though every version is a beta in spirit, and are
  always created with `--latest`. Two consequences to know: the repository's owner and name are
  baked into every installed copy for good, and the feed file itself is not covered by the
  update key, so someone who took over the GitHub account could change the notes shown or hold
  updates back, but not ship code. (Claude's call.)
- **Only release bundles update.** `release.sh` stamps the feed URL and public key into the
  bundle's `Info.plist`; the checked-in `Info.plist` has neither. The app creates the updater
  only when both keys are present, `SINGULARITY_HOME` is not set, and the app is not
  translocated. So `build-app.sh` bundles, bare debug binaries, test copies and `swift test`
  have no updater at all, and the menu item and the Settings switch are disabled with a one-line
  reason. `release.sh --skip-notarize` (a local build that publishes nothing) is not stamped
  either; the scratch update test gets its own flag. After zipping, `release.sh` removes
  `dist/Singularity.app`, so no second stamped bundle with the same bundle ID lies around.
  (Claude's call.)
- **Every bundle must still load the framework.** Once the executable links Sparkle, ad-hoc
  debug bundles (`build-app.sh`, hardened runtime) load it too, and macOS may refuse a framework
  whose team does not match. Check this before anything else; the fix is an entitlement for
  debug bundles or no hardened runtime for ad-hoc ones.
- **What the owner sees.** Sparkle's standard windows, with its "automatically download and
  install in the future" choice switched off (`SUAllowsAutomaticUpdates` = false): "A new version of Singularity
  is available", the release notes, Install / Later / Skip. Install downloads, verifies, quits,
  replaces the app and starts it again. Because quitting ends built-in terminal tabs, the app's
  existing quit path (the prompt when a terminal is busy) must still run; if it does not by
  itself, hook it through Sparkle's delegate.
- **When it checks:** at launch (an explicit background check: Sparkle by itself only checks
  when its interval has passed) and then every hour (Sparkle's shortest interval), plus
  Singularity → "Check for Updates…" and the same entry in the command palette.
  (Claude's call.)
- **Settings → General:** "Check for updates automatically" (on by default), the current
  version and build, and a "Check Now" button. The switch is stored in `settings.json`
  (`AppSettings.checksForUpdates`) and pushed into Sparkle at launch and on change, through
  `AppState.updateSettings` like every other setting. Sparkle's own "check automatically?"
  question must never appear: set its answer before the updater starts.
- **Known exception to "everything under ~/Singularity/":** Sparkle keeps its own small state
  (time of last check, a skipped version) in the app's macOS preferences
  (`~/Library/Preferences/dev.roosa.Singularity.plist`). Document it next to the WebKit one.
- **Privacy:** system profiling stays off. A check is one HTTPS request to github.com that
  shows GitHub the IP address and a user agent with the app's name and version. The README's
  privacy paragraph says so.
- **Structure:** the decisions that can be tested without Sparkle go to Core
  (`SingularityCore/Updates/`: may this copy update? given keys, home override, translocation;
  version/build parsing and bumping rules if the script needs a helper). The Sparkle glue is one
  small file in `Sources/Singularity/Updates/`. Tests cover the Core rules and that a test
  `AppState` never creates an updater.

### 4. The release command

`scripts/release.sh <version>` (today's script, extended; `--skip-notarize` remains for a local
signed build that publishes nothing). In order:

1. **Checks, before anything changes:** on `main`, clean tree, in sync with `origin/main`;
   the version is higher than the current one and the tag is free; `gh` is logged in; the update
   key is in the keychain; a signing certificate of team `T748B76PPL` exists.
2. `scripts/test.sh` passes.
3. Bump both version fields in `Resources/Info.plist`.
4. Build, assemble (now with Sparkle and the stamped feed keys), sign.
   - Developer ID certificate **and** notary profile present → notarize and staple as today.
   - Otherwise → sign with the team's Apple Development certificate and say clearly, in the
     terminal and at the top of the release notes, "not notarized: works on the owner's Mac,
     Gatekeeper will stop it elsewhere". (Claude's call: the owner has neither yet, and the
     update loop must work now. Sparkle's key is what keeps updates working across the later
     change of certificate; the builder verifies this with a real update before relying on it.)
5. Zip (`Singularity-<version>.zip`), sign the zip with the update key, write `appcast.xml`
   with one entry: version, build, minimum macOS, the zip's release-download URL, length,
   signature, and the release notes.
6. **Release notes:** the subjects of the commits since the previous tag, opened in `$EDITOR`
   to trim before publishing (`--notes-file <path>` skips the editor). The same text is the
   GitHub release body and what Sparkle shows. (Claude's call.)
7. Commit "Release <version>" and push the commit only, no tag yet.
8. Create the GitHub release as a **draft** against that commit, upload the zip and
   `appcast.xml`, then publish it with `--latest`. Publishing is what creates the tag, so a tag
   without files cannot exist and installed copies can only ever see a complete release.
9. Fetch the tag, print the release URL.

If anything fails before step 7, the script restores `Info.plist` and leaves nothing behind
but files in `dist/`. If it fails after the push, it says exactly which step to repeat (the
draft is invisible to installed copies until then).

### 4a. The agents' launcher starts its own bundle

`singularity-mcp` starts the app with `open -g -b dev.roosa.Singularity`, by bundle ID. With a
daily copy in `/Applications` and a development copy in `build/` sharing that ID, macOS may pick
either, so an agent call while the daily copy is closed could open the debug build on the real
data. Change: the launcher starts the bundle it lives in (by path). While an update is being
installed (the app has quit, the new one is not up yet) a launcher call must wait and retry the
socket rather than start a copy that then collides with the updated one on the instance lock.
(Claude's call, found by the design review.)

### 4b. Where the builder stops for the owner

Each of these is announced and waits for the owner's go: making the repository public;
creating the update key in the owner's keychain; publishing the first release; installing into
`/Applications`. Everything else proceeds.

### 5. Moving the owner's daily copy (once, by hand, with the owner)

- Install the first release into `/Applications/Singularity.app` and use that from now on.
  Same bundle ID and same `~/Singularity/`, so Spaces and logins carry over.
- Settings → Agents → Update, so Claude Code and Codex point at the launcher inside
  `/Applications` (a path that stays the same across updates). The owner clicks; nobody else.
- Then prove the loop for real: publish a second release and watch the daily copy update.

### 6. Development next to the daily copy

`scripts/run.sh` today quits any running Singularity and starts `build/Singularity.app` on the
real data folder. Once the daily copy lives in `/Applications`, that would quit the owner's
browser. New behaviour (owner-approved 2026-11-12): `run.sh` never quits
anything outside `build/`, and starts the development copy with its own data folder
(`SINGULARITY_HOME=~/Singularity-dev`, own agent socket), so both run side by side.
`SINGULARITY_HOME=… scripts/run.sh` still picks another folder; `SINGULARITY_HOME=~/Singularity`
gives the old behaviour while the daily copy is closed.

Details that follow from it:
- Same bundle ID, so the copy must be started as a new instance with the variable set (plain
  `open` would just bring the daily copy forward).
- The development copy shares macOS preferences, privacy permissions and WebKit's site-data
  folder with the daily copy. That is safe because Space ids differ; `~/Singularity-dev` starts
  empty and must never be made by copying `~/Singularity`. The README says so.
- A fresh folder opens the welcome flow. Whenever `SINGULARITY_HOME` is set, the Connect and
  Update buttons (welcome flow and Settings → Agents) are disabled with a one-line reason, so a
  development copy can never point the owner's real agents at `build/`.

## Adding a second track later (not built now)

Sparkle's feed can mark an entry with a channel name; a copy only sees channels it allows.
Later: releases marked "beta" get that channel in the feed, the app gets a Settings choice
that answers Sparkle's "allowed channels" question, and stable users are untouched. The feed
then has to list both the newest stable and the newest beta entry (today's one-entry file per
release would hide stable behind a beta), which is a change to the release script only.
Installed copies keep working unchanged.

## The signing name is public (owner's decision, 2026-11-12)

The team's Apple Development certificate is named after the owner's Apple ID email, and that
name is readable in every signed copy (`codesign -dvv`). The owner accepts this: it is a
personal release. Releases are therefore published now, without waiting for a Developer ID
certificate, whose name would be the owner's name and team ID only.

## A known cost of changing certificates

Each change of signing identity (today's development certificate → Developer ID) makes macOS
forget the app's privacy permissions once (camera, microphone, folders, controlling other
apps); the prompts come back the next time they are needed. Updates signed with the same
identity keep them. Spaces, tabs and logins are not affected.

## What the owner has to do themselves

- Keep a copy of the update private key in their password manager (the builder shows how).
- Before the first friend installs: join/renew the Apple Developer Program if needed, create a
  "Developer ID Application" certificate in team `T748B76PPL`, and store the `singularity-notary`
  profile. The next release is then notarized without any change to the command.
- Click Update in Settings → Agents after moving to `/Applications`.

## Left to the builder

- Exact Sparkle version (pin it), API names, the rpath mechanism, the signing order of Sparkle's
  inner helpers, where its command-line tools live in the SwiftPM checkout.
- Whether `appcast.xml` is written by Sparkle's `generate_appcast` or by a small template in the
  script (one entry is enough either way).
- Wording of menu items, Settings rows and script messages (plain, short, like the rest).
- How to test the update flow without touching the owner's copy: a scratch bundle in
  `/private/tmp` with a local feed and a throwaway key, never activated, never sent input.

## Docs to update when built

`CLAUDE.md` (dependency list, architecture, the Sparkle exception, release and run scripts,
"never run the daily copy from build/"), `README.md`, `IDEAS.md` (entry under the approved
items, plus "more tracks" under "New, not yet decided").
