// A small Markdown renderer for the Assistant's answers. Everything Claude writes is untrusted
// text, so this builds DOM nodes one by one and never uses innerHTML: HTML in an answer stays
// text, and no element gets an attribute (so no links, images, handlers or styles).
//
// What it knows: paragraphs (a single line break stays a line break), fenced code blocks
// (``` or ~~~), `inline code`, **bold** / __bold__, *italic* / _italic_, # headings (1 to 6), and
// lists with -, * or + and with 1. or 1). A link [text](address) is shown as "text (address)",
// never as a link. Anything else is shown as it was written.

/** The two document functions used (the page passes `document`; tests pass a stand-in). */
export type DocumentLike = {
  createElement(tag: string): { appendChild(child: any): unknown };
  createTextNode(text: string): unknown;
};

type Element = ReturnType<DocumentLike["createElement"]>;

const FENCE = /^\s{0,3}(`{3,}|~{3,})/;
const HEADING = /^\s{0,3}(#{1,6})\s+(.*)$/;
const BULLET = /^\s*[-*+]\s+(.*)$/;
const NUMBERED = /^\s*\d{1,9}[.)]\s+(.*)$/;

/** The blocks of `text` as DOM nodes. */
export function render(text: string, doc: DocumentLike = document as unknown as DocumentLike): Node[] {
  const out: unknown[] = [];
  const element = (tag: string) => doc.createElement(tag);
  const textNode = (value: string) => doc.createTextNode(value);

  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  let paragraph: string[] = [];
  let list: { tag: "ul" | "ol"; node: Element } | null = null;

  const endParagraph = () => {
    if (paragraph.length === 0) return;
    const p = element("p");
    paragraph.forEach((line, i) => {
      if (i > 0) p.appendChild(element("br"));
      inline(line.trim(), p, doc);
    });
    out.push(p);
    paragraph = [];
  };
  const endList = () => {
    list = null;
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    const fence = FENCE.exec(line);
    if (fence) {
      endParagraph();
      endList();
      // Until the same kind of fence closes it, or to the end (the answer may still be streaming).
      const close = new RegExp("^\\s{0,3}" + (fence[1][0] === "`" ? "`" : "~") + "{" + fence[1].length + ",}\\s*$");
      const body: string[] = [];
      for (i += 1; i < lines.length && !close.test(lines[i]); i++) body.push(lines[i]);
      const pre = element("pre");
      const code = element("code");
      code.appendChild(textNode(body.join("\n")));
      pre.appendChild(code);
      out.push(pre);
      continue;
    }

    if (line.trim() === "") {
      endParagraph();
      endList();
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      endParagraph();
      endList();
      const h = element("h" + heading[1].length);
      inline(heading[2].trim(), h, doc);
      out.push(h);
      continue;
    }

    const bullet = BULLET.exec(line);
    const numbered = bullet ? null : NUMBERED.exec(line);
    if (bullet || numbered) {
      endParagraph();
      const tag = bullet ? "ul" : "ol";
      if (list === null || list.tag !== tag) {
        list = { tag, node: element(tag) };
        out.push(list.node);
      }
      const li = element("li");
      inline((bullet ?? numbered)![1].trim(), li, doc);
      list.node.appendChild(li);
      continue;
    }

    endList();
    paragraph.push(line);
  }
  endParagraph();
  return out as Node[];
}

const CODE_SPAN = /^(`+)([\s\S]*?[^`])\1(?!`)/;
const STRONG_STARS = /^\*\*(?=\S)([\s\S]*?\S)\*\*/;
const STRONG_UNDERSCORES = /^__(?=\S)([\s\S]*?\S)__(?![A-Za-z0-9_])/;
const EM_STAR = /^\*(?=[^\s*])([\s\S]*?[^\s*])\*(?!\*)/;
const EM_UNDERSCORE = /^_(?=[^\s_])([\s\S]*?[^\s_])_(?![A-Za-z0-9_])/;
const LINK = /^\[([^\]\n]+)\]\(([^)\s]+)\)/;

/** Inline Markdown of one line (or a part of one) into `parent`. */
function inline(text: string, parent: Element, doc: DocumentLike): void {
  let plain = "";
  const flush = () => {
    if (plain !== "") parent.appendChild(doc.createTextNode(plain));
    plain = "";
  };
  const wrap = (tag: string, inner: string, length: number) => {
    flush();
    const node = doc.createElement(tag);
    inline(inner, node, doc);
    parent.appendChild(node);
    return length;
  };

  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);
    // "_" counts only at the start of a word, so snake_case_names stay as they are.
    const wordStart = i === 0 || !/[A-Za-z0-9_]/.test(text[i - 1]);
    let m: RegExpExecArray | null;
    if (text[i] === "`" && (m = CODE_SPAN.exec(rest))) {
      flush();
      const code = doc.createElement("code");
      code.appendChild(doc.createTextNode(m[2]));
      parent.appendChild(code);
      i += m[0].length;
    } else if ((m = STRONG_STARS.exec(rest)) || (wordStart && (m = STRONG_UNDERSCORES.exec(rest)))) {
      i += wrap("strong", m[1], m[0].length);
    } else if ((m = EM_STAR.exec(rest)) || (wordStart && (m = EM_UNDERSCORE.exec(rest)))) {
      i += wrap("em", m[1], m[0].length);
    } else if ((m = LINK.exec(rest))) {
      // The text, then the address as plain text: nothing to click.
      flush();
      inline(m[1], parent, doc);
      plain = " (" + m[2] + ")";
      i += m[0].length;
    } else {
      plain += text[i];
      i += 1;
    }
  }
  flush();
}
