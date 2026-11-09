// Background program of the fixture-filler test plugin (see page.ts).
// It answers the page script's messages with fixed logins. A real password manager would look
// the logins up; this one only exists to test Singularity's page bridge and fill guard.
import { singularity } from "singularity";

const logins = [
  { title: "Fixture user", subtitle: "u", username: "u", password: "p" },
  { title: "Other user", subtitle: "other", username: "other", password: "p2" },
];

singularity.onPageMessage(async ({ frameHost, payload }) => {
  const message = (payload ?? {}) as { action?: string; index?: number };
  switch (message.action) {
    // The menu's entries (titles and usernames only, never passwords).
    case "list":
      return { logins: logins.map(({ title, subtitle }) => ({ title, subtitle })) };
    // A fill for this site: Singularity delivers it only to a 127.0.0.1 frame, on a site in
    // fillForms, after a real click.
    case "fill": {
      const login = logins[message.index ?? 0] ?? logins[0];
      return { fill: { forHost: "127.0.0.1", username: login.username, password: login.password } };
    }
    // A fill meant for another site: Singularity must block it (and log "blocked fill for 127.0.0.1").
    case "wrong-host":
      return { fill: { forHost: "example.com", username: "u", password: "p" } };
    default:
      console.log(`unknown message from ${frameHost}`);
      return { error: "unknown action" };
  }
});
