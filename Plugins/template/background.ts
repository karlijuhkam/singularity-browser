// Background program of the template plugin. Singularity starts it on its bundled Bun, inside a
// sandbox: no network, no other programs, files only in this folder (read) and the plugin's data
// folder (write). It starts when the plugin is approved and stays running.

// "singularity" is not an npm package. Singularity defines this module in memory, so the import
// works only here, in the background file (never in page.ts).
import { singularity } from "singularity";

// Called for every message the page script sends with singularity.send(...).
//   tabID      which tab sent it (an opaque string)
//   frameHost  the host of the page, e.g. "example.com". Singularity reads it from WebKit, so a
//              web page can't fake it. Never trust a host the page puts into `payload`.
//   payload    whatever page.ts passed to send(). It comes from a web page: treat it as untrusted.
singularity.onPageMessage(async ({ frameHost, payload }) => {
  // Check the shape of the payload before using it.
  const message = (payload ?? {}) as { type?: unknown; text?: unknown };
  if (message.type !== "hello") return { error: "unknown request" };

  const text = typeof message.text === "string" ? message.text : "";

  // singularity.log writes to the plugin's log (Settings -> Plugins). Don't log secrets.
  // Here we log only the length of the text, not the text itself.
  singularity.log(`hello from ${frameHost}, ${text.length} character(s) typed`);

  // Whatever you return (it must be JSON) becomes the answer of send() in page.ts.
  // If you throw, page.ts gets {error: "<message>"} instead.
  return { greeting: `Hello ${frameHost}! You typed ${text.length} character(s).` };
});
