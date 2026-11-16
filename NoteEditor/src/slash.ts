// The "/" menu: type "/" at the start of a line or after a space, then pick a block.
//
// Tiptap's Suggestion plugin does the watching (what was typed after "/", when it ends); this
// file supplies the list and draws it. The menu is plain DOM, positioned under the caret.

import { Extension, type Editor, type Range } from "@tiptap/core";
import { Suggestion, type SuggestionKeyDownProps, type SuggestionProps } from "@tiptap/suggestion";
import { computePosition, flip, offset, shift } from "@floating-ui/dom";

export type SlashItem = {
  title: string;
  /** Shown in the small square at the left of the row. */
  glyph: string;
  /** What the row says under its title. */
  hint: string;
  /** Extra words the row is found by. */
  keywords: string;
  run(editor: Editor, range: Range): void;
};

/** `range` is the "/" and what was typed after it: every item removes it first. */
const block = (editor: Editor, range: Range) => editor.chain().focus().deleteRange(range);

export const slashItems: SlashItem[] = [
  { title: "Text", glyph: "¶", hint: "Plain paragraph", keywords: "paragraph plain",
    run: (e, r) => block(e, r).setParagraph().run() },
  { title: "Heading 1", glyph: "H1", hint: "Large heading", keywords: "title h1 big",
    run: (e, r) => block(e, r).setHeading({ level: 1 }).run() },
  { title: "Heading 2", glyph: "H2", hint: "Medium heading", keywords: "h2 subtitle",
    run: (e, r) => block(e, r).setHeading({ level: 2 }).run() },
  { title: "Heading 3", glyph: "H3", hint: "Small heading", keywords: "h3",
    run: (e, r) => block(e, r).setHeading({ level: 3 }).run() },
  { title: "To-do list", glyph: "☑", hint: "Items you can tick off", keywords: "todo task check checkbox",
    run: (e, r) => block(e, r).toggleTaskList().run() },
  { title: "Bulleted list", glyph: "•", hint: "A simple list", keywords: "bullet unordered ul",
    run: (e, r) => block(e, r).toggleBulletList().run() },
  { title: "Numbered list", glyph: "1.", hint: "A list with numbers", keywords: "ordered ol number",
    run: (e, r) => block(e, r).toggleOrderedList().run() },
  { title: "Quote", glyph: "❝", hint: "Set a passage apart", keywords: "blockquote citation",
    run: (e, r) => block(e, r).toggleBlockquote().run() },
  { title: "Code", glyph: "{}", hint: "A block of code", keywords: "codeblock snippet pre",
    run: (e, r) => block(e, r).toggleCodeBlock().run() },
  { title: "Divider", glyph: "—", hint: "A line across the page", keywords: "hr rule separator line",
    run: (e, r) => block(e, r).setHorizontalRule().run() },
  { title: "Table", glyph: "▦", hint: "Three columns, three rows", keywords: "grid columns rows",
    run: (e, r) => block(e, r).insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
  { title: "Today's date", glyph: "◷", hint: "Insert the date as text", keywords: "date today now day",
    run: (e, r) => block(e, r).insertContent(new Date().toLocaleDateString(undefined, { dateStyle: "long" }) + " ").run() },
];

/** The rows for what was typed after "/": title first, then keywords. Empty query: all. */
export function matchingItems(query: string, items = slashItems): SlashItem[] {
  const q = query.trim().toLowerCase();
  if (!q) return items;
  const starts = items.filter((item) => item.title.toLowerCase().startsWith(q));
  const contains = items.filter((item) => !starts.includes(item)
    && (item.title.toLowerCase().includes(q) || item.keywords.split(" ").some((word) => word.startsWith(q))));
  return [...starts, ...contains];
}

/** Draws the list and keeps the highlighted row. One per open menu. */
class MenuView {
  private element = document.createElement("div");
  private selected = 0;
  private props: SuggestionProps<SlashItem, SlashItem>;

  constructor(props: SuggestionProps<SlashItem, SlashItem>) {
    this.props = props;
    this.element.className = "slash-menu";
    this.element.setAttribute("role", "listbox");
    // A mouse press on the menu must not take the caret out of the text.
    this.element.addEventListener("mousedown", (event) => event.preventDefault());
    document.body.append(this.element);
    this.update(props);
  }

  update(props: SuggestionProps<SlashItem, SlashItem>) {
    this.props = props;
    this.selected = Math.min(this.selected, Math.max(0, props.items.length - 1));
    this.draw();
    this.place();
  }

  private draw() {
    this.element.replaceChildren();
    if (this.props.items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "slash-empty";
      empty.textContent = "No block by that name";
      this.element.append(empty);
      return;
    }
    this.props.items.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = "slash-row" + (index === this.selected ? " selected" : "");
      row.setAttribute("role", "option");
      const glyph = document.createElement("span");
      glyph.className = "slash-glyph";
      glyph.textContent = item.glyph;
      const text = document.createElement("span");
      text.className = "slash-text";
      const title = document.createElement("span");
      title.className = "slash-title";
      title.textContent = item.title;
      const hint = document.createElement("span");
      hint.className = "slash-hint";
      hint.textContent = item.hint;
      text.append(title, hint);
      row.append(glyph, text);
      row.addEventListener("mousemove", () => {
        if (this.selected !== index) { this.selected = index; this.draw(); }
      });
      row.addEventListener("click", () => this.props.command(item));
      this.element.append(row);
    });
    this.element.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
  }

  private place() {
    const rect = this.props.clientRect?.();
    if (!rect) return;
    // A "virtual element": floating-ui only needs to know where the caret is.
    computePosition({ getBoundingClientRect: () => rect }, this.element, {
      placement: "bottom-start", strategy: "fixed", middleware: [offset(6), flip(), shift({ padding: 8 })],
    }).then(({ x, y }) => {
      this.element.style.left = `${x}px`;
      this.element.style.top = `${y}px`;
    });
  }

  keyDown({ event }: SuggestionKeyDownProps): boolean {
    const count = this.props.items.length;
    if (event.key === "ArrowDown" && count) {
      this.selected = (this.selected + 1) % count;
      this.draw();
      return true;
    }
    if (event.key === "ArrowUp" && count) {
      this.selected = (this.selected + count - 1) % count;
      this.draw();
      return true;
    }
    if (event.key === "Enter" || event.key === "Tab") {
      const item = this.props.items[this.selected];
      if (item) this.props.command(item);
      return true;
    }
    return false;
  }

  remove() {
    this.element.remove();
  }
}

export const SlashMenu = Extension.create({
  name: "slashMenu",

  addProseMirrorPlugins() {
    return [
      Suggestion<SlashItem, SlashItem>({
        editor: this.editor,
        char: "/",
        // Not inside code: there "/" is just a character.
        allow: ({ state, range }) => {
          const $from = state.doc.resolve(range.from);
          return !$from.parent.type.spec.code && !state.doc.rangeHasMark(range.from, range.to, state.schema.marks.code);
        },
        items: ({ query }) => matchingItems(query),
        command: ({ editor, range, props }) => props.run(editor, range),
        render: () => {
          let view: MenuView | null = null;
          return {
            onStart: (props) => { view = new MenuView(props); },
            onUpdate: (props) => view?.update(props),
            onKeyDown: (props) => view?.keyDown(props) ?? false,
            onExit: () => { view?.remove(); view = null; },
          };
        },
      }),
    ];
  },
});
