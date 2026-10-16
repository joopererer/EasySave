import { readdirSync, readFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseX, calculateToken, extractTweetId } from "../src/x";

const fixtureDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "spec",
  "fixtures",
  "x",
);

const sourcesPath = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "spec",
  "fixtures",
  "sources.json",
);

const sources = JSON.parse(readFileSync(sourcesPath, "utf-8")) as {
  x?: Record<string, string>;
};

const cases = readdirSync(fixtureDir)
  .filter((name) => name.endsWith(".json") && !name.endsWith(".expected.json"))
  .map((name) => basename(name, ".json"))
  .filter((name) => {
    try {
      readFileSync(join(fixtureDir, `${name}.expected.json`), "utf-8");
      return true;
    } catch {
      return false;
    }
  })
  .sort();

describe("x (twitter) fixtures", () => {
  it("has fixtures to test", () => {
    expect(cases.length).toBeGreaterThanOrEqual(6);
  });

  for (const name of cases) {
    it(`${name}.json matches ${name}.expected.json`, () => {
      const inputJson = readFileSync(join(fixtureDir, `${name}.json`), "utf-8");
      const expected = JSON.parse(
        readFileSync(join(fixtureDir, `${name}.expected.json`), "utf-8"),
      ) as
        | { error: { code: string; message: string } }
        | Record<string, unknown>;

      const pageUrl =
        sources.x?.[name] || `https://x.com/test/status/${name}`;

      const result = parseX(inputJson, pageUrl);

      if ("error" in expected) {
        expect(result.ok).toBe(false);
        if (!result.ok) {
          expect(result.error.code).toBe(
            (expected as { error: { code: string } }).error.code,
          );
        }
      } else {
        expect(result).toEqual({ ok: true, data: expected });
      }
    });
  }
});

describe("calculateToken", () => {
  it("calculates correct deterministic token for tweet IDs", () => {
    expect(calculateToken("2110916144072913327")).toBe("547mzovpdmp");
    expect(calculateToken("2111037737172336975")).toBe("548qraagn");
    expect(calculateToken("2111025862892269612")).toBe("547zeetmng5");
    expect(calculateToken("2110932947121668283")).toBe("547ow3ru3rw");
    expect(calculateToken("2111043031700844656")).toBe("5481cbbr5b3");
  });
});

describe("extractTweetId", () => {
  it("extracts numeric status id from x.com and twitter.com URLs", () => {
    expect(
      extractTweetId("https://x.com/Lucy_love_AI/status/2110916144072913327"),
    ).toBe("2110916144072913327");
    expect(
      extractTweetId(
        "https://twitter.com/user/status/2111025862892269612?s=20",
      ),
    ).toBe("2111025862892269612");
  });
});
