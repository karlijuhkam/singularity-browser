// Run with: bun test   (in this folder). Uses made-up data only.
import { expect, test } from "bun:test";
import { isItemID, isSameOrSubdomain, matchLogins, parseCredentials } from "./logic.ts";

const A = "a".repeat(26);
const B = "b2".repeat(13);

test("host matching", () => {
  expect(isSameOrSubdomain("github.com", "github.com")).toBe(true);
  expect(isSameOrSubdomain("Gist.GitHub.com.", "github.com")).toBe(true);
  expect(isSameOrSubdomain("evilgithub.com", "github.com")).toBe(false);
  expect(isSameOrSubdomain("github.com", "gist.github.com")).toBe(false);
  expect(isSameOrSubdomain("github.com", "")).toBe(false);
});

test("item ids", () => {
  expect(isItemID(A)).toBe(true);
  expect(isItemID("--vault")).toBe(false);
  expect(isItemID(A.toUpperCase())).toBe(false);
  expect(isItemID(5)).toBe(false);
});

test("list parsing", () => {
  const list = JSON.stringify([
    { id: A, title: "GH", additional_information: "me", urls: [{ href: "https://github.com/login", primary: true }] },
    { id: B, title: "Other", urls: [{ href: "https://example.com" }] },
    { id: "bad", title: "BadID", urls: [{ href: "https://github.com" }] },
    { id: A, title: "FTP", urls: [{ href: "ftp://github.com" }] },
    { title: "NoID" },
    "junk",
  ]);
  expect(matchLogins(list, "gist.github.com")).toEqual([{ id: A, title: "GH", username: "me", host: "github.com" }]);
  expect(matchLogins(list, "nothing.test")).toEqual([]);
  expect(matchLogins("not json", "x.test")).toBeNull();
  expect(matchLogins("{}", "x.test")).toBeNull();
});

test("credential parsing", () => {
  const both = JSON.stringify([
    { id: "username", label: "username", purpose: "USERNAME", value: "me" },
    { id: "password", label: "password", purpose: "PASSWORD", value: "pw" },
  ]);
  expect(parseCredentials(both)).toEqual({ username: "me", password: "pw" });
  expect(parseCredentials(JSON.stringify({ label: "password", value: "pw" }))).toEqual({ username: "", password: "pw" });
  expect(parseCredentials(JSON.stringify([{ label: "username", value: "me" }]))).toBeNull();
  expect(parseCredentials("oops")).toBeNull();
  expect(parseCredentials("null")).toBeNull();
});
