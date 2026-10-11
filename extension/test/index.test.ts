import { describe, expect, it } from "vitest";
import { parse } from "../src/index";

describe("parse dispatcher", () => {
  it("routes xiaohongshu hosts to the XHS parser", () => {
    const result = parse("<html></html>", "https://www.xiaohongshu.com/explore/6aca089a000000000a01efb4");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error.code).toBe("LOGIN_REQUIRED");
  });

  it("routes instagram hosts to the Instagram parser", () => {
    const result = parse("<html></html>", "https://www.instagram.com/p/Ddl1WWnGyCN/");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error.code).toBe("LOGIN_REQUIRED");
  });

  it("returns UNSUPPORTED_URL for unknown hosts and bad URLs", () => {
    for (const url of ["https://example.com/p/123", "https://www.youtube.com/watch?v=1", "not a url"]) {
      const result = parse("<html></html>", url);
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.error.code).toBe("UNSUPPORTED_URL");
    }
  });
});
