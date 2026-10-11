import { readdirSync, readFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseXhs } from "../src/xhs";

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "spec", "fixtures", "xhs");

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

describe("xhs fixtures", () => {
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
      const id = typeof (expected as Record<string, unknown>)["id"] === "string"
        ? ((expected as Record<string, unknown>)["id"] as string)
        : name;
      const result = parseXhs(html, `https://www.xiaohongshu.com/explore/${id}`);

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
