// The note editor's rules that need no page: Markdown in and out, the "/" menu's matching, link
// addresses, picture paths. Run by scripts/test.sh when NoteEditor's packages are installed.
// (The editor in a real web view is tested in Tests/SingularityAppTests/NoteTests.swift.)

import { describe, expect, test } from "bun:test";
import { resolveExtensions } from "../../NoteEditor/node_modules/@tiptap/core";
import { MarkdownManager } from "../../NoteEditor/node_modules/@tiptap/markdown";
import { normalizeLink } from "../../NoteEditor/src/bubble";
import { shownSource } from "../../NoteEditor/src/image";
import { contentExtensions, isAllowedLink } from "../../NoteEditor/src/schema";
import { matchingItems, slashItems } from "../../NoteEditor/src/slash";

const markdown = new MarkdownManager({ extensions: resolveExtensions(contentExtensions) });
const roundTrip = (text: string) => markdown.serialize(markdown.parse(text));

describe("Markdown", () => {
  const sample = [
    "# Title",
    "",
    "Some *italic*, **bold**, ~~struck~~ and `code` with a [link](https://example.com).",
    "",
    "- one",
    "- two",
    "  - nested",
    "",
    "- [ ] to do",
    "- [x] done",
    "  - [ ] under it",
    "",
    "1. first",
    "2. second",
    "",
    "> a quote",
    "",
    "```swift",
    "let a = 1 < 2",
    "```",
    "",
    "---",
    "",
    "![a picture](assets/2026-11-16-ab12cd34.png)",
  ].join("\n");

  test("what the editor writes, it reads back the same", () => {
    const once = roundTrip(sample);
    expect(once).toBe(sample);
    expect(roundTrip(once)).toBe(once);
  });

  test("a table survives", () => {
    const table = roundTrip("| Day | Plan |\n| --- | --- |\n| Friday | Arrive |");
    expect(table).toContain("| Day");
    expect(table).toContain("| Friday");
    expect(roundTrip(table)).toBe(table);
  });

  test("HTML in a note stays text", () => {
    const json = JSON.stringify(markdown.parse('<img src=x onerror="alert(1)">\n\nA <b>bold</b> word and <script>x()</script>.'));
    expect(json).toContain("<img src=x onerror=");
    expect(json).toContain("<b>");
    expect(json).not.toContain('"type":"image"');
    expect(json).not.toContain('"type":"bold"');
  });

  test("characters that mean something in Markdown are kept as typed", () => {
    const tricky = roundTrip("2 \\* 3 \\* 4, snake\\_case\\_name and \\[brackets\\]");
    expect(markdown.parse(tricky)).toEqual(markdown.parse("2 \\* 3 \\* 4, snake\\_case\\_name and \\[brackets\\]"));
  });
});

describe("the / menu", () => {
  test("lists everything for an empty query", () => {
    expect(matchingItems("")).toEqual(slashItems);
  });

  test("titles first, then keywords", () => {
    expect(matchingItems("to").map((item) => item.title)).toEqual(["To-do list", "Today's date"]);
    expect(matchingItems("check").map((item) => item.title)).toEqual(["To-do list"]);
    expect(matchingItems("h2").map((item) => item.title)).toEqual(["Heading 2"]);
    expect(matchingItems("list").map((item) => item.title)).toEqual(["To-do list", "Bulleted list", "Numbered list"]);
    expect(matchingItems("zzz")).toEqual([]);
  });
});

describe("links", () => {
  test("a typed address becomes a web address", () => {
    expect(normalizeLink("example.com/a")).toBe("https://example.com/a");
    expect(normalizeLink(" https://example.com ")).toBe("https://example.com");
    expect(normalizeLink("http://localhost:3000")).toBe("http://localhost:3000");
    expect(normalizeLink("mailto:me@example.com")).toBe("mailto:me@example.com");
    expect(normalizeLink("example.com:8080/x")).toBe("https://example.com:8080/x");
    expect(normalizeLink("")).toBeNull();
  });

  test("other schemes never become links", () => {
    for (const bad of ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "singularity-note://editor/"]) {
      expect(normalizeLink(bad)).toBeNull();
      expect(isAllowedLink(bad)).toBe(false);
    }
    expect(isAllowedLink("https://example.com")).toBe(true);
    expect(isAllowedLink("mailto:me@example.com")).toBe(true);
  });
});

describe("pictures", () => {
  test("a picture of the note is asked from the note's folder", () => {
    expect(shownSource("assets/a.png")).toBe("/file/assets/a.png");
  });

  test("a picture anywhere else is not asked for at all", () => {
    for (const elsewhere of ["https://example.com/a.png", "//example.com/a.png", "/etc/a.png", "file:///a.png", "data:image/png;base64,AA", null]) {
      expect(shownSource(elsewhere)).toBe("");
    }
  });
});
