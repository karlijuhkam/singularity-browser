// Tests for Plugins/assistant/markdown.ts. Run from the repo root: Vendor/bun/bun test Tests/plugins/assistant
import { expect, test } from "bun:test";
import { render } from "../../../Plugins/assistant/markdown.ts";
import { allNodes, fakeDocument, type FakeNode, outline } from "./fake-dom.ts";

const md = (text: string) => render(text, fakeDocument) as unknown as FakeNode[];
const show = (text: string) => outline(md(text));

test("paragraphs, with line breaks kept inside one", () => {
  expect(show("Hello\nthere\n\nSecond")).toBe("<P>Hello<BR></BR>there</P><P>Second</P>");
  expect(show("")).toBe("");
  expect(show("\n\n  \n")).toBe("");
});

test("headings", () => {
  expect(show("# One\n## Two\n###### Six")).toBe("<H1>One</H1><H2>Two</H2><H6>Six</H6>");
  // Seven hashes, or none of the space after them, is just text.
  expect(show("####### x")).toBe("<P>####### x</P>");
  expect(show("#hashtag")).toBe("<P>#hashtag</P>");
});

test("fenced code blocks keep their text as it is", () => {
  expect(show("Before\n```ts\nconst a = **b**;\n  <b>x</b>\n```\nAfter")).toBe(
    "<P>Before</P><PRE><CODE>const a = **b**;\n  <b>x</b></CODE></PRE><P>After</P>",
  );
  // An unclosed fence runs to the end (the answer may still be streaming).
  expect(show("```\nline 1\nline 2")).toBe("<PRE><CODE>line 1\nline 2</CODE></PRE>");
});

test("inline code, bold, italic", () => {
  expect(show("a `x*y*` b")).toBe("<P>a <CODE>x*y*</CODE> b</P>");
  expect(show("**bold** and __bold__")).toBe("<P><STRONG>bold</STRONG> and <STRONG>bold</STRONG></P>");
  expect(show("*it* and _it_")).toBe("<P><EM>it</EM> and <EM>it</EM></P>");
  expect(show("**bold *with it* inside**")).toBe("<P><STRONG>bold <EM>with it</EM> inside</STRONG></P>");
  // Underscores inside words are not emphasis.
  expect(show("snake_case_name")).toBe("<P>snake_case_name</P>");
  // A lone star is text.
  expect(show("2 * 3 = 6")).toBe("<P>2 * 3 = 6</P>");
});

test("lists", () => {
  expect(show("- one\n- **two**\n* three")).toBe("<UL><LI>one</LI><LI><STRONG>two</STRONG></LI><LI>three</LI></UL>");
  expect(show("1. first\n2. second")).toBe("<OL><LI>first</LI><LI>second</LI></OL>");
  expect(show("Intro\n- a\n\nOutro")).toBe("<P>Intro</P><UL><LI>a</LI></UL><P>Outro</P>");
});

test("a link is its text followed by the address, never an anchor", () => {
  expect(show("See [the docs](https://example.com/a) now")).toBe("<P>See the docs (https://example.com/a) now</P>");
});

test("HTML and script stay text (Review Focus 6)", () => {
  const cases = [
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    "[x](javascript:alert(1))",
    "**<script>alert(1)</script>**",
    "- <iframe src=//evil>",
    "# <img src=x onerror=alert(1)>",
  ];
  const allowed = new Set(["P", "BR", "PRE", "CODE", "STRONG", "EM", "UL", "OL", "LI", "H1", "H2", "H3", "H4", "H5", "H6", "#text"]);
  for (const text of cases) {
    const nodes = allNodes(md(text));
    for (const node of nodes) {
      expect(allowed.has(node.nodeName)).toBe(true);
      expect(node.attributes.size).toBe(0);
    }
    // The text survives as text.
    expect(md(text).map((n) => n.textContent).join("")).toContain(text.includes("javascript") ? "javascript:alert(1" : "<");
  }
  expect(show("<script>alert(1)</script>")).toBe("<P><script>alert(1)</script></P>");
  expect(show("[x](javascript:alert(1))")).toBe("<P>x (javascript:alert(1))</P>");
});
