// Page script of the fixture-filler test plugin. Singularity runs it in its own isolated world on
// http://127.0.0.1 pages (the artifact server), with `singularity` (the page API) already defined.
//
// - A password field's button fills u / p straight away.
// - A text field's button shows a menu of two logins first; picking one fills it.
// - A field marked data-fixture="wrong-host" asks for a fill meant for example.com, which
//   Singularity must block.
// It also checks, once per page, that it can't use the network or fill without a click, and
// prints the results to the console (Web Inspector, "fixture-filler" world).

type Login = { title: string; subtitle?: string };
type Reply = { logins?: Login[]; fill?: { username: string; password: string }; error?: string };

function loginFields(input: HTMLInputElement): { usernameInput?: HTMLInputElement; passwordInput?: HTMLInputElement } {
  const form = input.form ?? document;
  const passwordInput = form.querySelector<HTMLInputElement>("input[type=password]") ?? undefined;
  const usernameInput =
    form.querySelector<HTMLInputElement>("input[autocomplete=username], input[type=email], input[type=text]") ?? undefined;
  return { usernameInput, passwordInput };
}

async function fill(input: HTMLInputElement, action: string, index?: number): Promise<void> {
  const reply = (await singularity.send({ action, index })) as Reply;
  if (!reply.fill) {
    console.log("fixture-filler: no fill:", reply.error ?? reply);
    return;
  }
  singularity.fillLogin({ ...loginFields(input), username: reply.fill.username, password: reply.fill.password });
}

async function onButton(input: HTMLInputElement): Promise<void> {
  if (input.dataset.fixture === "wrong-host") return fill(input, "wrong-host");
  if (input.type === "password") return fill(input, "fill", 0);
  const reply = (await singularity.send({ action: "list" })) as Reply;
  const picked = await singularity.showMenu(input, reply.logins ?? []);
  if (picked !== null) await fill(input, "fill", picked);
}

function decorate(): void {
  for (const input of document.querySelectorAll<HTMLInputElement>("input[type=password], input[type=text], input[type=email]")) {
    // addFieldButton keeps one button per field, so calling it again after a re-render is fine.
    singularity.addFieldButton(input, { title: "Fill with Fixture filler", onClick: onButton });
  }
}

decorate();
// Pages re-render their forms (relogin.html replaces its form after 1 s): look again on changes.
let pending = false;
new MutationObserver(() => {
  if (pending) return;
  pending = true;
  setTimeout(() => {
    pending = false;
    decorate();
  }, 100);
}).observe(document.documentElement, { childList: true, subtree: true });

// Self-checks (results in the console).
try {
  fetch("http://127.0.0.1/");
  console.error("fixture-filler: fetch worked, but it should be blocked");
} catch (error) {
  console.log("fixture-filler: fetch is blocked:", String(error));
}
singularity.send({ action: "fill" }).then(
  (reply) => console.log("fixture-filler: fill without a click ->", JSON.stringify(reply), "(expected: fill blocked)"),
  (error) => console.log("fixture-filler: fill without a click failed:", String(error)),
);
