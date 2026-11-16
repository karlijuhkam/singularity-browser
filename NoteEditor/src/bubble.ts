// The small toolbar above selected text: bold, italic, strikethrough, code, link.
// With the caret inside a link it shows the link's address, with Open and Remove.
//
// Plain DOM, positioned with floating-ui. It never takes the caret out of the text, except for
// the link's address field, which needs typing.

import type { Editor } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import { computePosition, flip, offset, shift } from "@floating-ui/dom";
import { native } from "./bridge";

/** Addresses a link may have. Everything else typed into the field gets "https://" in front. */
export function normalizeLink(text: string): string | null {
  const value = text.trim();
  if (!value) return null;
  if (/^(https?:\/\/|mailto:)/i.test(value)) return value;
  // Another scheme ("javascript:", "file:") is never made into a link.
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) && !/^[^/]+\.[a-z]{2,}(:\d+)?(\/|$)/i.test(value)) return null;
  return "https://" + value;
}

export function attachBubble(editor: Editor): () => void {
  const element = document.createElement("div");
  element.className = "bubble";
  element.hidden = true;
  document.body.append(element);

  const buttons = document.createElement("div");
  buttons.className = "bubble-buttons";
  const linkRow = document.createElement("div");
  linkRow.className = "bubble-link";
  linkRow.hidden = true;
  element.append(buttons, linkRow);

  // Pressing a button must not move the selection (the address field is the exception).
  element.addEventListener("mousedown", (event) => {
    if (!(event.target instanceof HTMLInputElement)) event.preventDefault();
  });

  function button(label: string, title: string, className: string, isActive: () => boolean, run: () => void) {
    const node = document.createElement("button");
    node.type = "button";
    node.className = "bubble-button " + className;
    node.textContent = label;
    node.title = title;
    node.addEventListener("click", run);
    buttons.append(node);
    return () => node.classList.toggle("active", isActive());
  }

  const refreshers = [
    button("B", "Bold (⌘B)", "bold", () => editor.isActive("bold"), () => editor.chain().focus().toggleBold().run()),
    button("I", "Italic (⌘I)", "italic", () => editor.isActive("italic"), () => editor.chain().focus().toggleItalic().run()),
    button("S", "Strikethrough (⇧⌘S)", "strike", () => editor.isActive("strike"), () => editor.chain().focus().toggleStrike().run()),
    button("</>", "Code (⌘E)", "code", () => editor.isActive("code"), () => editor.chain().focus().toggleCode().run()),
    button("Link", "Link", "link", () => editor.isActive("link"), () => showLinkRow(true)),
  ];

  const input = document.createElement("input");
  input.type = "text";
  input.placeholder = "Paste or type an address";
  input.spellcheck = false;
  const open = document.createElement("button");
  open.type = "button";
  open.className = "bubble-button";
  open.textContent = "Open";
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "bubble-button";
  remove.textContent = "Remove";
  linkRow.append(input, open, remove);

  let linkRowWanted = false;

  function currentLink(): string {
    return (editor.getAttributes("link").href as string | undefined) ?? "";
  }

  function showLinkRow(focus: boolean) {
    linkRowWanted = true;
    input.value = currentLink();
    linkRow.hidden = false;
    open.hidden = remove.hidden = !currentLink();
    place();
    if (focus) { input.focus(); input.select(); }
  }

  function applyLink() {
    const href = normalizeLink(input.value);
    linkRowWanted = false;
    if (!href) {
      if (!input.value.trim()) editor.chain().focus().extendMarkRange("link").unsetLink().run();
      else editor.commands.focus();
      return;
    }
    editor.chain().focus().extendMarkRange("link").setLink({ href }).run();
  }

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); applyLink(); }
    if (event.key === "Escape") { event.preventDefault(); linkRowWanted = false; editor.commands.focus(); }
  });
  input.addEventListener("blur", () => { linkRowWanted = false; requestAnimationFrame(update); });
  open.addEventListener("click", () => {
    const href = currentLink();
    if (href) native.open(href).catch(() => {});
  });
  remove.addEventListener("click", () => {
    linkRowWanted = false;
    editor.chain().focus().extendMarkRange("link").unsetLink().run();
  });

  function shouldShow(): boolean {
    if (document.activeElement === input) return true;
    if (!editor.isFocused || !editor.isEditable) return false;
    const { selection } = editor.state;
    if (selection instanceof NodeSelection) return false;
    if (editor.isActive("codeBlock")) return false;
    if (!selection.empty) return editor.state.doc.textBetween(selection.from, selection.to, " ").trim().length > 0;
    return editor.isActive("link");
  }

  function place() {
    const { from, to } = editor.state.selection;
    const start = editor.view.coordsAtPos(from);
    const end = editor.view.coordsAtPos(to);
    const top = Math.min(start.top, end.top);
    const bottom = Math.max(start.bottom, end.bottom);
    const left = Math.min(start.left, end.left);
    const right = Math.max(start.right, end.right);
    const rect = new DOMRect(left, top, Math.max(1, right - left), bottom - top);
    computePosition({ getBoundingClientRect: () => rect }, element, {
      placement: "top", strategy: "fixed", middleware: [offset(8), flip(), shift({ padding: 8 })],
    }).then(({ x, y }) => {
      element.style.left = `${x}px`;
      element.style.top = `${y}px`;
    });
  }

  function update() {
    if (!shouldShow()) {
      element.hidden = true;
      linkRow.hidden = true;
      linkRowWanted = false;
      return;
    }
    element.hidden = false;
    refreshers.forEach((refresh) => refresh());
    const inLink = editor.isActive("link");
    // With only a caret in a link there is nothing to format: show the address alone.
    buttons.hidden = editor.state.selection.empty;
    if (document.activeElement !== input) {
      if (inLink || linkRowWanted) {
        linkRow.hidden = false;
        input.value = currentLink();
        open.hidden = remove.hidden = !inLink;
      } else {
        linkRow.hidden = true;
      }
    }
    place();
  }

  editor.on("selectionUpdate", update);
  editor.on("transaction", update);
  editor.on("focus", update);
  editor.on("blur", () => requestAnimationFrame(update));
  window.addEventListener("scroll", update, { passive: true });
  window.addEventListener("resize", update);

  return () => {
    window.removeEventListener("scroll", update);
    window.removeEventListener("resize", update);
    element.remove();
  };
}
