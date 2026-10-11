import { describe, expect, it } from "vitest";
import {
  buildFilename,
  downloadTargets,
  extensionFromUrl,
  sanitizeFilePart,
} from "../src/download";

describe("sanitizeFilePart", () => {
  it("replaces illegal characters and falls back on empty input", () => {
    expect(sanitizeFilePart("a/b:c*d?e<f>g|h", "x")).toBe("a_b_c_d_e_f_g_h");
    expect(sanitizeFilePart("...bad...", "x")).toBe("bad");
    expect(sanitizeFilePart("   ", "x")).toBe("x");
    expect(sanitizeFilePart("正常名字", "x")).toBe("正常名字");
  });
});

describe("extensionFromUrl", () => {
  it("reads the extension from the path and ignores query strings", () => {
    expect(extensionFromUrl("https://ci.xiaohongshu.com/a/b?x=1", "image")).toBe("jpg");
    expect(extensionFromUrl("https://cdn.example.com/v/a.mp4?sign=1", "video")).toBe("mp4");
    expect(extensionFromUrl("https://cdn.example.com/v/a.heic?x=1", "image")).toBe("heic");
  });

  it("falls back to a type default when the path has no extension", () => {
    expect(extensionFromUrl("https://ci.xiaohongshu.com/notes_pre_post/abc", "image")).toBe("jpg");
    expect(extensionFromUrl("https://cdn.example.com/stream/1", "video")).toBe("mp4");
  });
});

describe("buildFilename", () => {
  it("follows {平台}_{作者}_{id}_{序号}.{扩展名} under EasySave/", () => {
    expect(
      buildFilename({ platform: "xhs", author: "momo", id: "abc123" }, 1, "https://cdn/x.png", "image"),
    ).toBe("EasySave/xhs_momo_abc123_1.png");
    expect(
      buildFilename({ platform: "instagram", author: "a/b", id: "Ddl1WWnGyCN" }, 2, "https://cdn/x", "video"),
    ).toBe("EasySave/instagram_a_b_Ddl1WWnGyCN_2.mp4");
  });
});

describe("downloadTargets", () => {
  it("expands a live item into image plus motion video", () => {
    const targets = downloadTargets(
      { type: "live", url: "https://cdn/still", videoUrl: "https://cdn/motion.mp4" },
      { platform: "xhs", author: "m", id: "n" },
      1,
    );
    expect(targets).toHaveLength(2);
    expect(targets[0]).toEqual({ url: "https://cdn/still", filename: "EasySave/xhs_m_n_1.jpg" });
    expect(targets[1]).toEqual({
      url: "https://cdn/motion.mp4",
      filename: "EasySave/xhs_m_n_1_live.mp4",
    });
  });

  it("emits a single target for image and video items", () => {
    expect(
      downloadTargets({ type: "image", url: "https://cdn/a.png" }, { platform: "xhs", id: "n" }, 1),
    ).toEqual([{ url: "https://cdn/a.png", filename: "EasySave/xhs_unknown_n_1.png" }]);
  });
});
