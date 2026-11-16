// What a note can contain: exactly what Markdown can say. This file touches no page (no
// `document`), so the Markdown rules can be tested on their own (Tests/notes).

import type { AnyExtension } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import { Markdown, MarkdownManager } from "@tiptap/markdown";
import { NoteImage } from "./image";

// HTML written inside a note is shown as the text it is, never turned into elements: a note can
// be written by another program (or an agent), and what it says must not become markup here.
// The library's own handling would parse it; this replaces that one step.
const manager = MarkdownManager.prototype as unknown as {
  parseHTMLToken(token: { text?: string; raw?: string; block?: boolean }): unknown;
  htmlAsLiteralText(html: string, isBlock: boolean): unknown;
};
manager.parseHTMLToken = function (token) {
  const html = token.text || token.raw || "";
  return html.trim() ? this.htmlAsLiteralText(html, !!token.block) : null;
};

/** Links a note may hold: web addresses and mail. Never `javascript:`, `file:` or the like. */
export function isAllowedLink(url: string): boolean {
  return /^(https?:\/\/|mailto:)/i.test(url.trim());
}

export const contentExtensions: AnyExtension[] = [
  StarterKit.configure({
    heading: { levels: [1, 2, 3] },
    // Markdown has no underline.
    underline: false,
    link: {
      openOnClick: false,
      autolink: true,
      linkOnPaste: true,
      protocols: ["http", "https", "mailto"],
      isAllowedUri: (url) => isAllowedLink(url),
      HTMLAttributes: { rel: "noopener noreferrer nofollow" },
    },
    dropcursor: { width: 2, class: "drop-cursor" },
  }),
  TaskList,
  TaskItem.configure({ nested: true }),
  TableKit.configure({ table: { resizable: false } }),
  NoteImage,
  Markdown,
];
