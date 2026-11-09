// Tests for Plugins/1password/logic.ts. Run from the repo root: Vendor/bun/bun test Tests/plugins/1password
// Made-up data only.
import { expect, test } from "bun:test";
import { isItemID, isSameOrSubdomain, matchLogins, parseCredentials } from "../../../Plugins/1password/logic.ts";

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

test("URLs without a scheme", () => {
  const one = (href: string, host: string) =>
    matchLogins(JSON.stringify([{ id: A, title: "T", urls: [{ href }] }]), host)?.length;
  expect(one("github.com", "github.com")).toBe(1);
  expect(one("www.github.com/login", "www.github.com")).toBe(1);
  expect(one("//github.com", "github.com")).toBe(1);
  expect(one("ftp://x", "x")).toBe(0);
  expect(one("ssh://github.com", "github.com")).toBe(0);
});

test("credential parsing", () => {
  const item = (fields: unknown[]) => JSON.stringify({ id: A, fields });
  expect(
    parseCredentials(item([
      { id: "username", purpose: "USERNAME", label: "username", value: "me" },
      { id: "password", purpose: "PASSWORD", label: "password", value: "pw" },
    ])),
  ).toEqual({ username: "me", password: "pw" });
  // No purpose: concealed "password" field; username by label, then email.
  expect(
    parseCredentials(item([
      { type: "CONCEALED", label: "Password", value: "pw" },
      { type: "STRING", label: "Email", value: "a@b.test" },
    ])),
  ).toEqual({ username: "a@b.test", password: "pw" });
  // Missing username label does not matter.
  expect(parseCredentials(item([{ purpose: "PASSWORD", value: "pw" }]))).toEqual({ username: "", password: "pw" });
  expect(parseCredentials(item([{ purpose: "USERNAME", value: "me" }]))).toBeNull();
  expect(parseCredentials(item([{ type: "CONCEALED", label: "pin", value: "1" }]))).toBeNull();
  expect(parseCredentials(JSON.stringify([{ purpose: "PASSWORD", value: "pw" }]))).toBeNull();
  expect(parseCredentials("oops")).toBeNull();
  expect(parseCredentials("null")).toBeNull();
});
