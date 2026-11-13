// A very small stand-in for the DOM, enough for Plugins/assistant/markdown.ts: createElement,
// createTextNode, appendChild. It records every attribute or property a renderer might set, so a
// test can prove none was.

export class FakeNode {
  readonly childNodes: FakeNode[] = [];
  /** Attributes set with setAttribute (the renderer must never set any). */
  readonly attributes = new Map<string, string>();

  constructor(
    readonly nodeType: 1 | 3,
    readonly nodeName: string,
    readonly data = "",
  ) {}

  appendChild(child: FakeNode): FakeNode {
    this.childNodes.push(child);
    return child;
  }

  append(...children: FakeNode[]): void {
    for (const child of children) this.appendChild(child);
  }

  setAttribute(name: string, value: string): void {
    this.attributes.set(name, value);
  }

  get textContent(): string {
    return this.nodeType === 3 ? this.data : this.childNodes.map((c) => c.textContent).join("");
  }
}

export const fakeDocument = {
  createElement(tag: string): FakeNode {
    return new FakeNode(1, tag.toUpperCase());
  },
  createTextNode(text: string): FakeNode {
    return new FakeNode(3, "#text", text);
  },
};

/** A short picture of a tree: elements as <TAG>…</TAG>, text as its text. */
export function outline(nodes: FakeNode[]): string {
  return nodes
    .map((n) => (n.nodeType === 3 ? n.data : `<${n.nodeName}>${outline(n.childNodes)}</${n.nodeName}>`))
    .join("");
}

/** Every node of the trees, depth first. */
export function allNodes(nodes: FakeNode[]): FakeNode[] {
  return nodes.flatMap((n) => [n, ...allNodes(n.childNodes)]);
}
