// Page script of the 1Password plugin. Singularity runs it (as plain JavaScript) on every web
// page, with `singularity` (the page API) already defined. It adds a small button to login
// fields. A click opens a menu of this site's logins; picking one fills the form.
// The passwords never pass through this script's own storage: they come back from the background
// program and go straight into the fields via singularity.fillLogin.

type LoginChoice = { id: string; title: string; username: string };
type Reply = {
  logins?: LoginChoice[];
  fill?: { username: string; password: string };
  error?: string;
};

function isUsable(input: HTMLInputElement): boolean {
  if (input.disabled || input.readOnly || input.type === "hidden") return false;
  const box = input.getBoundingClientRect();
  if (box.width === 0 || box.height === 0) return false;
  const style = getComputedStyle(input);
  return style.visibility !== "hidden" && style.display !== "none";
}

function isUsernameCandidate(input: HTMLInputElement): boolean {
  const type = input.type;
  return (type === "text" || type === "email" || input.autocomplete === "username") && isUsable(input);
}

/** The nearest usable text/email/username input before the password field: in its form, or else
 *  earlier in the document. */
function usernameFor(password: HTMLInputElement): HTMLInputElement | undefined {
  const scope: ParentNode = password.form ?? document;
  const candidates = Array.from(scope.querySelectorAll<HTMLInputElement>("input"));
  const at = candidates.indexOf(password);
  for (let i = at - 1; i >= 0; i--) {
    if (isUsernameCandidate(candidates[i])) return candidates[i];
  }
  return undefined;
}

async function onClick(anchor: HTMLInputElement, usernameInput: HTMLInputElement | undefined, passwordInput: HTMLInputElement): Promise<void> {
  const reply = (await singularity.send({ type: "logins" })) as Reply;
  const logins = reply.logins ?? [];

  // Always a menu, even for one login: a fill needs a deliberate pick, not just a click on the button.
  if (reply.error || logins.length === 0) {
    // One entry that tells what is going on. Picking it does nothing.
    await singularity.showMenu(anchor, [{ title: reply.error ?? "No logins for this site" }]);
    return;
  }
  const picked = await singularity.showMenu(
    anchor,
    logins.map((l) => ({ title: l.title, subtitle: l.username })),
  );
  if (picked === null || !logins[picked]) return;

  const answer = (await singularity.send({ type: "fill", id: logins[picked].id })) as Reply;
  if (!answer.fill) {
    await singularity.showMenu(anchor, [{ title: answer.error ?? "Couldn't fill this login" }]);
    return;
  }
  singularity.fillLogin({
    usernameInput,
    passwordInput,
    username: answer.fill.username,
    password: answer.fill.password,
  });
}

function decorate(): void {
  for (const password of document.querySelectorAll<HTMLInputElement>("input[type=password]")) {
    if (!isUsable(password)) continue;
    const username = usernameFor(password);
    const click = () => onClick(password, username, password);
    // addFieldButton keeps one button per input, so calling it again after a page change is fine.
    singularity.addFieldButton(password, { title: "Fill with 1Password", onClick: click });
    if (username) singularity.addFieldButton(username, { title: "Fill with 1Password", onClick: click });
  }
}

decorate();
// Login forms often appear later (single-page apps, dialogs): look again when the page changes.
let scanPending = false;
new MutationObserver(() => {
  if (scanPending) return;
  scanPending = true;
  setTimeout(() => {
    scanPending = false;
    decorate();
  }, 200);
}).observe(document.documentElement, { childList: true, subtree: true });
