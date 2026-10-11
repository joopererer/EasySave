import { readdirSync, readFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseInstagram, shortcodeToMediaId } from "../src/instagram";

const fixtureDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "spec",
  "fixtures",
  "instagram",
);

const cases = readdirSync(fixtureDir)
  .filter((name) => name.endsWith(".html"))
  .map((name) => basename(name, ".html"))
  .filter((name) => {
    try {
      readFileSync(join(fixtureDir, `${name}.expected.json`), "utf-8");
      return true;
    } catch {
      return false;
    }
  })
  .sort();

describe("instagram fixtures", () => {
  if (cases.length === 0) {
    it("has fixtures to test", () => {
      expect(cases.length).toBeGreaterThan(0);
    });
  }
  for (const name of cases) {
    it(`${name}.html matches ${name}.expected.json`, () => {
      const html = readFileSync(join(fixtureDir, `${name}.html`), "utf-8");
      const expected = JSON.parse(readFileSync(join(fixtureDir, `${name}.expected.json`), "utf-8")) as
        | { error: { code: string; message: string } }
        | Record<string, unknown>;
      const id =
        typeof (expected as Record<string, unknown>)["id"] === "string"
          ? ((expected as Record<string, unknown>)["id"] as string)
          : name;
      const result = parseInstagram(html, `https://www.instagram.com/p/${id}/`);

      if ("error" in expected) {
        expect(result.ok).toBe(false);
        if (!result.ok) {
          expect(result.error.code).toBe(expected.error.code);
        }
      } else {
        expect(result).toEqual({ ok: true, data: expected });
      }
    });
  }
});

describe("shortcodeToMediaId", () => {
  it("converts known shortcodes with BigInt precision", () => {
    expect(shortcodeToMediaId("Ddl1WWnGyCN")).toBe("3991831277305798797");
    expect(shortcodeToMediaId("DeTOj5WRMIh")).toBe("4004608533072232993");
  });

  it("rejects empty input and characters outside the alphabet", () => {
    expect(shortcodeToMediaId("")).toBeUndefined();
    expect(shortcodeToMediaId("abc$defghij")).toBeUndefined();
    expect(shortcodeToMediaId("ab cd")).toBeUndefined();
  });

  it("round-trips single characters against the base64url alphabet", () => {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    for (let i = 0; i < alphabet.length; i++) {
      expect(shortcodeToMediaId(alphabet[i])).toBe(String(i));
    }
  });
});
