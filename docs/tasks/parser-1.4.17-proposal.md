# parser 1.4.17 改动建议（本轮未改 parser）

状态：**建议，未实现**。v1.10.3 是 hotfix，parser 版本仍为 `1.4.16`
（`app/assets/parser/builtin-manifest.json` manifestVersion 12）。
本文件列出需要 parser 侧生成候选、因此没在 hotfix 里做的事项。

参考项目 NEORUAA/XHS_Downloader_Android 为 AGPL-3.0：本轮只借鉴思路（用 CDN 的
`imageView2` 转码），**没有复制或改写其任何代码**。

---

## 1. 已实测的 CDN 行为（2026-11-12，真实 token，只读 GET）

| 请求 | 字节 | 像素 | SHA-256 前 16 |
| --- | --- | --- | --- |
| `sns-img-bd.xhscdn.com/{token}` | 1,007,645 | 1290×1608 | `ea80472824226ac8` |
| `sns-img-bd…?imageView2/format/jpg` | 245,672 | 1290×1608 | `3c9c08f36ae0f5e4` |
| `sns-img-bd…?imageView2/format/jpeg` | 245,672 | 1290×1608 | `3c9c08f36ae0f5e4` |
| `sns-img-bd…?imageView2/format/jpg/q/100` | 1,030,648 | 1290×1608 | `2ed25b20f19ff3ab` |
| `ci.xiaohongshu.com/{token}` | 1,007,645 | 1290×1608 | `ea80472824226ac8` |
| `ci…?imageView2/format/jpg` | 245,672 | 1290×1608 | `3c9c08f36ae0f5e4` |
| `ci…?imageView2/format/jpg/quality/100` | 245,672 | 1290×1608 | `3c9c08f36ae0f5e4` |

结论：

1. `format/jpeg` 与 `format/jpg` **字节完全一致**，parser 现有写法（`jpg`）无需更改。
2. `imageView2` 在 `sns-img-bd`（原始格式 host）与 `ci` 上都被执行。
3. 只写 `format/jpg` 会重编码（-76% 体积），`/q/100` 才回到接近原始体积。
   `/quality/100` 不被识别，**必须用 `/q/100`**。
4. NEORUAA 的“原始格式走 `sns-img-bd`、JPEG 走 `ci?imageView2/format/jpeg`”与我们
   现状的差别只在 host + 是否要质量参数，不在拼写。

## 2. 建议的 parser 侧改动

### 2.1 `jpegImageUrl(token)` 增加质量参数（P0）

当前 `extension/src/xhs.ts`：

```ts
export function jpegImageUrl(token: string): string {
  return `https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`;
}
```

建议：

```ts
export function jpegImageUrl(token: string): string {
  return `https://ci.xiaohongshu.com/${token}?imageView2/format/jpg/q/100`;
}
```

理由：不改变候选数量与顺序，只把“服务器转码的 JPEG”从约 245KB 提到约 1.03MB，
与 1.01MB 的原始字节接近，避免用户拿到明显降质的“原图”。

风险：`/q/100` 若在某些 token 上不被接受，需要一条 `expected.json` fixture 固定
“候选字符串”，再由 App 侧实测体积回归。

### 2.2 在 `img`（原始格式 host）上也给出 JPEG 原图候选（P1）

现状 `imageUrlOf` 的 `fallbacks` 是
`[jpegImageUrl(token), ...sceneRaws, direct, ci/{token}]`，其中
`jpegImageUrl` 用的是 `ci` host。建议额外补一条同 token 的
`sns-img-bd` JPEG 原图：

```ts
`https://sns-img-bd.xhscdn.com/${token}?imageView2/format/jpg/q/100`
```

理由：与 `ci` 是两条独立边缘，一条被 reset 时另一条仍可能成功；实测两者对同一
token 的原始字节完全一致，说明同一存储，只是入口不同。

**但**：v1.10.3 已在 App 侧实现了等价的派生候选
（`withDerivedJpegOriginals`），所以这条迁移到 parser 时只是“把派生搬回上游”，
App 侧派生逻辑应同时下线，避免重复候选。

### 2.3 `mediaKindOf` 对 `imageView2` 的判定（P2）

`xhsMediaKindOf` 现已把“含 `imageView2` 且不含 `/w/`、`/h/`、`thumbnail`”的
`ci` URL 判为 `jpeg`。建议同步把 `sns-img-bd…?imageView2/format/jpg/q/100`
也判为 `jpeg`（当前按 host 会判为 `image`，结果正确但 label 是 `img:jpg`，
两条入口在日志里无法区分）。这是可观测性问题，不是功能问题。

### 2.4 fixture（P0，与 2.1 一起）

* `spec/fixtures/xhs/`：把 `xhs_multi.expected.json` 里所有
  `?imageView2/format/jpg` 更新为 `?imageView2/format/jpg/q/100`
  （属于 parser 版本升级时的 fixture 变更，需与 App 的
  `build32_xhs_image_quality_test` 期望同步修改）。
* 新增一条 fixture 记录“同一 token 的 `ci` 与 `sns-img-bd` 原始字节一致”的
  证据（体积/像素，不落 URL 之外的数据）。

## 3. 不在 parser 范围内的事

* “图片格式”设置（兼容优先 / 原始格式 / JPEG）、实况合成系统动态照片、
  瀑布流左右对调、本地缩略图原生按比例解码，均已记录在
  [v1.11.md](v1.11.md)，属于 App 侧。
* `format/jpeg` 与 `format/jpg` 的差异：**不存在**，不建议为此改任何代码。
