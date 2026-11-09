// Page script of the template plugin. Singularity compiles this TypeScript to plain JavaScript and
// runs it in every page that matches "page.sites" in plugin.json, in its own isolated world: the
// page's own scripts can't see it.
//
// Rules for this file: no `import` and no `export` (it runs as a plain script, not a module),
// and no network (fetch and friends throw). Talk to the background program with singularity.send.
// `singularity` is a global that Singularity defines before this file runs.

// Where the plugin has an effect: only search fields. Change the selector to try other fields.
const SELECTOR = "input[type=search]";

async function onClick(input: HTMLInputElement): Promise<void> {
  // send() hands a JSON value to the background program and resolves with its answer.
  const reply = (await singularity.send({ type: "hello", text: input.value })) as {
    greeting?: string;
    error?: string;
  };

  // showMenu(anchor, items) shows a small menu next to `anchor` and resolves with the index of the
  // item the user picked, or null if they dismissed it. We only want to show text here.
  await singularity.showMenu(input, [{ title: reply.greeting ?? reply.error ?? "No answer" }]);
}

function decorate(): void {
  for (const input of document.querySelectorAll<HTMLInputElement>(SELECTOR)) {
    // One button per input. Calling this again for the same input just updates the button,
    // so it is safe to run decorate() many times. onClick runs only for real clicks by the user.
    singularity.addFieldButton(input, { title: "Say hello", onClick: () => onClick(input) });
  }
}

decorate();

// Pages add fields later (single-page apps, dialogs), so look again when the page changes.
// The timer batches bursts of changes into one scan. Timers must be given a function, not a string.
let scanPending = false;
new MutationObserver(() => {
  if (scanPending) return;
  scanPending = true;
  setTimeout(() => {
    scanPending = false;
    decorate();
  }, 200);
}).observe(document.documentElement, { childList: true, subtree: true });
