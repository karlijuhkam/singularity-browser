# App template

A starter for a Singularity app: a small notes list. Copy the folder, rename it, delete what you
don't need. The guide is `AUTHORING.md`, next to this folder inside Singularity (in the repository:
`docs/apps/AUTHORING.md`). Read it before you build.

| File | What it is |
|---|---|
| `wrangler.jsonc` | Makes the folder an app. Names the Worker and the database binding `DB`. |
| `worker.ts` | The Worker: `GET api/notes`, `POST api/notes`, `DELETE api/notes/:id`, and one commented-out route that calls an outside API with a key. |
| `migrations/0001_init.sql` | The `notes` table. Tables are made only in migrations. |
| `app.tsx` | The page (Preact). Lists, adds and deletes notes; shows the API's errors as text. |
| `importmap.json` | Where the page's `preact` imports come from (esm.sh). |

**Run it.** Copy the folder into a Space's artifacts folder (`artifacts_folder` from `list_spaces`)
under the app's name, for example `…/artifacts/notes`. `app.tsx` opens as a tab by itself. The
database appears at `<app_data_folder>/notes/DB.sqlite`; the Worker's log is `worker.log` beside it.
There is nothing to install and nothing to start.

**Move it out.** `worker.ts` and `migrations/` run on Cloudflare unchanged. Create the D1 database,
apply the migrations, copy the data, set the keys as secrets, build `app.tsx` into `dist/` and
deploy with wrangler. The guide has the exact commands under "Moving out to Cloudflare".
