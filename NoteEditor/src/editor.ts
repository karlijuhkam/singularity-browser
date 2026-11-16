// Singularity's note editor: one Markdown file, edited as rich text.
//
// The page is shown by the app in a locked web view (`NoteHost` in Swift): it has no network and
// talks to the app through `bridge.ts` only. The file on disk is plain Markdown, so the editor's
// blocks are limited to what Markdown can say: headings, lists, to-do lists, quotes, code,
// dividers, tables, pictures, links, bold/italic/strikethrough/code.
//
// Built with scripts/build-note-editor.sh into Resources/note-editor/ (the built files are
// committed, so building the app needs no npm).

import { Editor } from "@tiptap/core";
import { Placeholder } from "@tiptap/extensions";
import { native } from "./bridge";
import { attachBubble } from "./bubble";
import { BlockGrip } from "./handle";
import { fileToBase64, imageFiles } from "./image";
import { contentExtensions } from "./schema";
import { SlashMenu } from "./slash";

const titleElement = document.getElementById("title") as HTMLElement;
const editorElement = document.getElementById("editor") as HTMLElement;
const strip = document.getElementById("strip") as HTMLElement;
const stripText = document.getElementById("strip-text") as HTMLElement;
const stripButtons = document.getElementById("strip-buttons") as HTMLElement;

let editor: Editor | null = null;
let detachBubble: (() => void) | null = null;
/** The title the file has now (what a failed rename goes back to). */
let currentTitle = "";
/** The editor has changes that are not on disk yet. */
let dirty = false;
/** A save is on its way to the app. */
let saving: Promise<void> | null = null;
let saveTimer: number | undefined;
/** The file changed on disk while the editor had its own changes: saving waits for a choice. */
let conflicted = false;

const saveDelay = 400;

// MARK: The editor

function makeEditor(markdown: string): Editor {
  return new Editor({
    element: editorElement,
    extensions: [
      ...contentExtensions,
      Placeholder.configure({
        placeholder: ({ node }) => (node.type.name === "paragraph" ? "Write, or press / for blocks" : ""),
        showOnlyCurrent: true,
      }),
      SlashMenu,
      BlockGrip,
    ],
    content: markdown,
    contentType: "markdown",
    editorProps: {
      attributes: { class: "note", spellcheck: "true" },
      handlePaste: (_view, event) => insertImages(imageFiles(event.clipboardData), null),
      handleDrop: (view, event, _slice, moved) => {
        if (moved) return false;
        const at = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos ?? null;
        return insertImages(imageFiles(event.dataTransfer), at);
      },
      handleClick: (_view, _pos, event) => {
        // ⌘-click opens a link; a plain click only puts the caret there.
        if (!event.metaKey) return false;
        const link = (event.target as HTMLElement | null)?.closest("a[href]");
        const href = link?.getAttribute("href");
        if (!href) return false;
        native.open(href).catch(() => {});
        return true;
      },
    },
    onUpdate: () => {
      dirty = true;
      scheduleSave();
    },
  });
}

/** Saves pictures next to the note and puts them into the text. True when there were any. */
function insertImages(files: File[], at: number | null): boolean {
  if (files.length === 0 || !editor) return false;
  const target = editor;
  (async () => {
    for (const file of files) {
      try {
        const { src } = await native.image(file.name, await fileToBase64(file));
        const node = { type: "image", attrs: { src, alt: "" } };
        if (at === null) target.chain().focus().insertContent(node).run();
        else target.chain().focus().insertContentAt(at, node).run();
      } catch (error) {
        showStrip(`That picture couldn't be added: ${message(error)}`, [["OK", hideStrip]]);
      }
    }
  })();
  return true;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// MARK: Loading and saving

async function load(focus: boolean) {
  const loaded = await native.load();
  currentTitle = loaded.title;
  titleElement.textContent = loaded.title;
  document.title = loaded.title;
  detachBubble?.();
  editor?.destroy();
  editor = makeEditor(loaded.markdown);
  detachBubble = attachBubble(editor);
  dirty = false;
  conflicted = false;
  window.clearTimeout(saveTimer);
  if (loaded.exists) {
    hideStrip();
  } else {
    showStrip("This note's file is gone. Typing here creates it again.", [["OK", hideStrip]]);
  }
  if (!focus) return;
  // A brand-new note starts at its title, selected, ready to be named.
  if (!loaded.markdown.trim() && /^Untitled( \d+)?$/.test(loaded.title)) {
    titleElement.focus();
    document.getSelection()?.selectAllChildren(titleElement);
  } else {
    editor.commands.focus("start", { scrollIntoView: false });
  }
}

function scheduleSave() {
  window.clearTimeout(saveTimer);
  if (conflicted) return;
  saveTimer = window.setTimeout(() => { save(false); }, saveDelay);
}

/** Writes the text to the file, one save at a time. Changes made meanwhile get their own save. */
async function save(force: boolean): Promise<void> {
  window.clearTimeout(saveTimer);
  if (saving) await saving;
  if (!editor || !dirty || (conflicted && !force)) return;
  const markdown = editor.getMarkdown();
  dirty = false;
  saving = (async () => {
    try {
      const reply = await native.save(markdown, force);
      if ("conflict" in reply) {
        dirty = true;
        showConflict();
      } else if (force) {
        conflicted = false;
        hideStrip();
      }
    } catch (error) {
      dirty = true;
      showStrip(`This note couldn't be saved: ${message(error)}`, [["Try Again", () => { hideStrip(); save(false); }]]);
    }
  })();
  await saving;
  saving = null;
}

function showConflict() {
  conflicted = true;
  showStrip("This note changed on disk while you were writing.", [
    ["Keep Mine", () => { save(true); }],
    ["Load That Version", () => { load(true); }],
  ]);
}

// The app calls this when the file changed on disk (another program wrote it).
window.__noteFileChanged = () => {
  if (dirty || saving) showConflict();
  else load(false);
};

// The app calls this before the tab closes or the app quits.
window.__noteFlush = async () => {
  await commitTitle();
  await save(false);
};

// Leaving the page for another tab or app: don't wait out the timer.
document.addEventListener("visibilitychange", () => { if (document.hidden) save(false); });
window.addEventListener("blur", () => { save(false); });

// MARK: The strip above the note

function showStrip(text: string, actions: [string, () => void][]) {
  stripText.textContent = text;
  stripButtons.replaceChildren(...actions.map(([label, run]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.addEventListener("click", run);
    return button;
  }));
  strip.hidden = false;
}

function hideStrip() {
  strip.hidden = true;
}

// MARK: The title (the file's name)

async function commitTitle() {
  const typed = (titleElement.textContent ?? "").replace(/\s+/g, " ").trim();
  if (typed === currentTitle) return;
  if (!typed) { titleElement.textContent = currentTitle; return; }
  try {
    const { title } = await native.rename(typed);
    currentTitle = title;
    titleElement.textContent = title;
    document.title = title;
  } catch (error) {
    titleElement.textContent = currentTitle;
    showStrip(`The note couldn't be renamed: ${message(error)}`, [["OK", hideStrip]]);
  }
}

titleElement.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === "ArrowDown") {
    event.preventDefault();
    editor?.commands.focus("start");
  }
  if (event.key === "Escape") {
    event.preventDefault();
    titleElement.textContent = currentTitle;
    editor?.commands.focus();
  }
});
titleElement.addEventListener("blur", () => { commitTitle(); });
// Pasting into the title: text only, on one line.
titleElement.addEventListener("paste", (event) => {
  event.preventDefault();
  const text = (event.clipboardData?.getData("text/plain") ?? "").replace(/\s+/g, " ");
  document.execCommand("insertText", false, text);
});

// Clicking the empty space under the text puts the caret at the end, as on paper.
document.getElementById("page")!.addEventListener("mousedown", (event) => {
  if (event.target === event.currentTarget && editor) {
    event.preventDefault();
    editor.commands.focus("end");
  }
});

// For the app's tests (they drive this page in an off-screen window).
window.__noteTest = {
  markdown: () => editor?.getMarkdown() ?? null,
  json: () => editor?.getJSON() ?? null,
  insert: (text: string) => editor?.chain().focus("end").insertContent(text).run() ?? false,
  isDirty: () => dirty,
  isConflicted: () => conflicted,
  stripText: () => (strip.hidden ? null : stripText.textContent),
  pressStripButton: (label: string) => {
    const button = [...stripButtons.querySelectorAll("button")].find((node) => node.textContent === label);
    button?.click();
    return !!button;
  },
  setTitle: async (text: string) => { titleElement.textContent = text; await commitTitle(); return currentTitle; },
  ready: false,
};

load(true).then(
  () => { window.__noteTest!.ready = true; },
  (error) => showStrip(`This note couldn't be opened: ${message(error)}`, [["Try Again", () => { hideStrip(); load(true); }]]),
);
