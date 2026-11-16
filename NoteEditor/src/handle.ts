// The grip at the left of the block under the pointer: drag it to move the block, click it to
// select the block (then Delete removes it, ⌘C copies it).
//
// A "block" here is a list item when the pointer is over one (so a to-do list can be reordered
// item by item), otherwise the top-level block: paragraph, heading, whole table, picture…
//
// How the drag works: ProseMirror already knows how to move a selected node that is dragged
// (`view.dragging`, its own drop handling and the drop cursor). So the grip only has to select
// the block, hand ProseMirror the slice, and let the browser start a drag.

import { Extension } from "@tiptap/core";
import { NodeSelection, Plugin, PluginKey } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";

const listItemTypes = new Set(["listItem", "taskItem"]);

/** The block at a document position: its start position, or null in an empty spot. */
export function blockAt(view: EditorView, pos: number, inside: number): number | null {
  const doc = view.state.doc;
  const $pos = doc.resolve(Math.min(pos, doc.content.size));
  for (let depth = $pos.depth; depth >= 1; depth -= 1) {
    if (listItemTypes.has($pos.node(depth).type.name)) return $pos.before(depth);
  }
  if ($pos.depth >= 1) return $pos.before(1);
  // Depth 0: the pointer is on a block with no text in it (a divider, a picture).
  if (inside >= 0 && doc.resolve(inside).depth === 0 && doc.nodeAt(inside)) return inside;
  return null;
}

class HandleView {
  private grip = document.createElement("div");
  private blockPos: number | null = null;
  private hideTimer: number | undefined;

  constructor(private view: EditorView) {
    this.grip.className = "block-grip";
    this.grip.draggable = true;
    this.grip.hidden = true;
    this.grip.title = "Drag to move · click to select";
    for (let dot = 0; dot < 6; dot += 1) this.grip.append(document.createElement("i"));
    document.body.append(this.grip);

    this.grip.addEventListener("mousedown", this.select);
    this.grip.addEventListener("dragstart", this.dragStart);
    this.grip.addEventListener("dragend", this.dragEnd);
    this.grip.addEventListener("mouseenter", () => window.clearTimeout(this.hideTimer));
    document.addEventListener("mousemove", this.pointerMoved);
    document.addEventListener("keydown", this.hide);
    window.addEventListener("scroll", this.hide, { passive: true });
  }

  private pointerMoved = (event: MouseEvent) => {
    if (event.buttons !== 0 || !this.view.editable) return;
    if (event.target === this.grip || this.grip.contains(event.target as Node)) return;
    const box = this.view.dom.getBoundingClientRect();
    // The grip lives in the margin left of the text, so the pointer counts a little outside it too.
    if (event.clientY < box.top || event.clientY > box.bottom || event.clientX < box.left - 60 || event.clientX > box.right) {
      this.hideSoon();
      return;
    }
    // Ask "which block is on this line?" at a point inside the text column.
    const x = Math.max(event.clientX, box.left + 4);
    const found = this.view.posAtCoords({ left: x, top: event.clientY });
    const pos = found ? blockAt(this.view, found.pos, found.inside) : null;
    if (pos === null) { this.hideSoon(); return; }
    const dom = this.view.nodeDOM(pos);
    if (!(dom instanceof HTMLElement)) { this.hideSoon(); return; }
    window.clearTimeout(this.hideTimer);
    this.blockPos = pos;
    const rect = dom.getBoundingClientRect();
    // List items: their bullet, number or checkbox sits left of the box; go left of that too.
    const isItem = listItemTypes.has(this.view.state.doc.nodeAt(pos)?.type.name ?? "");
    const firstLine = Math.min(rect.height, parseFloat(getComputedStyle(dom).lineHeight) || 24);
    this.grip.style.left = `${rect.left - (isItem ? 44 : 24)}px`;
    this.grip.style.top = `${rect.top + (firstLine - 20) / 2}px`;
    this.grip.hidden = false;
  };

  private hideSoon() {
    window.clearTimeout(this.hideTimer);
    this.hideTimer = window.setTimeout(this.hide, 120);
  }

  private hide = () => {
    this.grip.hidden = true;
    this.blockPos = null;
  };

  private select = () => {
    if (this.blockPos === null) return;
    const { state } = this.view;
    if (this.blockPos > state.doc.content.size || !state.doc.nodeAt(this.blockPos)) return;
    this.view.dispatch(state.tr.setSelection(NodeSelection.create(state.doc, this.blockPos)));
    this.view.focus();
  };

  private dragStart = (event: DragEvent) => {
    const selection = this.view.state.selection;
    if (!(selection instanceof NodeSelection) || !event.dataTransfer) { event.preventDefault(); return; }
    const dom = this.view.nodeDOM(selection.from);
    // WebKit only starts a drag that carries some data.
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", selection.node.textContent);
    if (dom instanceof HTMLElement) event.dataTransfer.setDragImage(dom, 0, 0);
    // From here ProseMirror's own drop handling moves the slice.
    this.view.dragging = { slice: selection.content(), move: true };
    this.grip.classList.add("dragging");
  };

  private dragEnd = () => {
    this.grip.classList.remove("dragging");
    this.hide();
  };

  destroy() {
    document.removeEventListener("mousemove", this.pointerMoved);
    document.removeEventListener("keydown", this.hide);
    window.removeEventListener("scroll", this.hide);
    this.grip.remove();
  }
}

export const BlockGrip = Extension.create({
  name: "blockGrip",
  addProseMirrorPlugins() {
    return [new Plugin({ key: new PluginKey("blockGrip"), view: (view) => new HandleView(view) })];
  },
});
