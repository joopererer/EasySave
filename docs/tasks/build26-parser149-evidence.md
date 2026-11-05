# Build 26 / Parser 1.4.9

## 范围与更新顺序

App **1.10.0+26**；解析模块 **1.4.9 / manifestVersion 5**。
用户反馈 build 25 / 1.4.8 的小红书选域与云端激活通过，X/TikTok 正常；本轮新增修复仍待设备复测。

**先覆盖安装 build 26 APK，再检查云端模块。** 预览修复和日志桥接在 Dart 中，仅更新解析模块不能修复旧 APK。
build 26 已内置完整 1.4.9，安装后可以直接测试，再从“我的 → 解析器版本”检查云端 1.4.9 激活和重启保持。
使用同一调试签名覆盖安装，不卸载、不清数据。历史记录不会自动重新解析；要取得新 AI 字段，需重新解析原帖。

## 问题 1：App 内预览策略拒绝

对照 build 23 的 `d38d4c1` 与 build 24 的 `2069945`：后者为缩略图增加最小尺寸候选，并区分
`thumb` / `image` 缓存身份，但全屏中间模型 `GalleryBrowserItem` 没同步增加 `thumbnailUrl`。
`PreviewPage._viewFullscreen` 仍逐字段复制，`toMediaItem()` 重建时也丢掉它；请求声明 `requestResources`
却完整保留。因此普通和 AI 帖子都会失败，与 AI 内容识别无关。

离线真实 widget 回归复现的主要错误是 **`REQUEST_RESOURCE_MISMATCH`**，不是根据通用提示猜测的
`REQUEST_URL_REJECTED`。缺少 thumbnail slot 使声明数量不一致。补充诊断后的字段是
`field=resources.count shape=scheme=https hostClass=media`，Instagram host 为受支持的 CDN 域名。

另外，实际点击“已保存”记录复现 X/TikTok url-only 视频被填入 `videoUrl=相册文件名`：
**`REQUEST_URL_REJECTED field=videoUrl shape=relative hostClass=none`**（host 为空）。
这是另一条历史网络回退问题，不能把它当作 Instagram 主回退的现场日志。

| 消费路径 | 大图 / 海报 | 视频 | 缩略图 |
| --- | --- | --- | --- |
| App 全屏 | `GalleryBrowserItem.fromMediaItem` → `toMediaItem` → `CoverImage(fullResolution: true)` | `videoUrl ?? url` → `networkPreviewController`，连同完整 item 校验 | `thumbnailUrl` 仅用于带尺寸的缩略图请求 |
| 悬浮球 | 原始 `post.items[i].url`，通过共享缓存与策略授权 | 原始 `videoUrl ?? url`，通过策略生成 native 请求 | 优先 `thumbnailUrl` |
| 下载 / 手动重试 | 原始 `url` 与对应 image fallbacks | 有独立 `videoUrl` 时仅使用它；否则使用主视频与其 fallbacks | 不作为下载资源 |

修复内容：

- 统一完整 MediaItem 转换，保留原媒体、海报、thumbnail、fallbacks、请求声明和缓存身份。
  当前预览、近期历史及“已保存”回退均已检查；`HistoryRecord.toPost()` 同时恢复存储的 thumbnail。
- 本地文件名仅留作相册定位/显示，缺少本地资源时使用原网络媒体，不把文件名送入网络播放器。
  播放器的本地文件读取失败分支也携带完整 item 校验，不丢请求声明。
- 四路径测试额外发现 IG 视频下载把海报作为视频 fallback；初始下载和手动重试一起修复。
- 真实大图 widget 测试暴露动画控制器在 dispose 时才惰性初始化的错误，改为 initState 初始化。
- 请求策略日志统一携带安全 `field/shape/hostClass`；不记录路径、完整 URL、query 值或 cookie。
  没有放宽域名、协议、重定向或声明一致性校验。

测试：IG 视频/图片/多图各覆盖普通与 AI，共 6 个真实 PreviewPage → GalleryBrowserPage 案例；
小红书、X、TikTok 各覆盖图片/视频路由。4 个真实 HistoryPage 点击案例覆盖 IG 视频、X/TikTok
url-only 视频及小红书 Live。实际消费者测试运行下载入口、图片策略入口、HTTP 隔离的视频 helper、
悬浮球图片 handler，并验证 native 视频选择地址的授权。测试隔离外部 I/O，未执行设备播放。

## 问题 2：Instagram 帖子级 AI 标签

Instagram 解析模块只读取根 `ai_label_info`：必须为对象，且 `attribution_label_text` 是非空字符串，
才输出 `{ text: 原值, source: platform }`。null、空白、错误类型、仅有
`user.aigm_account_label_info` 的帖子均不识别。HTML 和网络缓存 product 入口共用此规则。

现有共享元数据链路写入 `prov:aiLabel` / `prov:aiLabelSource=platform`，依照 spec v0.1.6 的已有映射写入
`Iptc4xmpExt:DigitalSourceType=http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia`。
未修改 provenance-spec、provenance_dart 或既有 spec fixtures / 测试向量；新增三个离线 fixture。
旧 Reel 向量已含帖子级标签，测试显式补充新字段期待，原向量文件保留不动。

App 预览、全屏和“已保存”沿用现有共享 `AiLabelBadge`，与小红书/TikTok 相同；真实 widget 测试覆盖显示、
原文披露、平台归因及普通帖子无标签。**标签暂用平台原文，待用户确认最终文案规则。**

诊断仅对根 `$.ai_label_info.attribution_label_text` 放行平台文案，去除 C0/C1 控制字符，最多 60 个 Unicode
字符；清洗后完整文本若含 URL/query，则只记类型，先检查后截断，防止控制字符绕过。
根 ai_label_info 下遍历全部合法字段名与安全短枚举/布尔/数字，其他长字符串只记类型。
账号树、敏感值、URL、query 和用户正文仍不记录。

已有离线 Reel fixture 可见 `gen_ai_detection_method=AI_CREATED`、`subtitle_text`、`attribution_label_text`；
Carousel 的 attribution 为 null，subtitle 有文案，仍不识别。**现有证据不足以确定检测与作者声明的区别**，
不据此改变 aiLabelSource。新增 fixture 的 method 值为合成测试数据，不能当作现场发现。
后续需用户提供两条目标帖的新增 `[IgAiProbe]` 日志确认实际字段和文案。

## 测试、APK 与发布校验

提交前最终门槛：

- Flutter 全量 **766/766**；Android **96/96，23 suites**，0 failure。
- TypeScript 检查及 Vitest **198/198**；Node 发布检查 **28/28**；QR 辅助测试 **4/4**。
- parser / extension 构建、unsigned candidate 配置一致性检查通过。
- Dart analyze 无 error，退出 0；现存 86 项 warning/info 保留，新测试依赖已显式声明。
- 初次全量 Flutter 的新增 AI 断言错误地合计转场中的两页面标签，限定到各自实际页面后重新全量通过。
  失败日志保留，未跳过测试、删除断言或放宽性能阈值。Android 首次命令定位失败后用包装器绝对路径执行成功。
- 发布 CI 在签名前新增 5 个本轮 App 回归测试文件的门槛，Node 测试验证其存在与顺序。

APK：`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build26-debug.apk`
（202,029,307 bytes），`com.james.easysave`，versionName **1.10.0** / versionCode **26**。

SHA-256：`401460c9ff4b0e2adc9304fa8595bb286e327e0138b83cc77d01b34791f41a4d`。

`apksigner verify` 通过，公开证书 SHA-256
`7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484`，与 build 25 相同。
内置 parser SHA-256：`2f3b48bf36c07a5449a28abbbd104a8a870df797694bc2de3d3bb9e0b11a3e4e`。

APK 层证据：`tools/verify_build26_apk.py` 检查真实 debug kernel 中的 PreviewPage、GalleryBrowserPage、
fromMediaItem/toMediaItem、播放器、缓存与共享 AI badge 符号；APK 内嵌的六份修改后 widget/策略/日志源文件
与本次源码逐字节相同，内置 parser/manifest 与经过测试的产物一致。配合实际 widget 路由测试验证接线，
不以单独新增但未挂载的 widget 代替实际页面。检查结果保留 `app/build/v149/apk-evidence.log`。
全量门槛、构建、证书与 badging 日志同目录保留；没有清理临时目录或结束其他进程。

CI 与发布后的独立验签/公开回读结果将在发布完成后补充。

## 用户设备复测

1. 覆盖安装 build 26，确认 App 1.10.0+26；检查解析模块 1.4.9，再检查云端激活及重启保持。
2. 分别用普通 IG 视频、普通图片、多图帖，以及用户提供的两条 AI 帖子重新解析。App 中点击大图、
   放大/退出、播放视频和切换多图，应不再出现资源策略拒绝；确认缩略图和原图独立加载。
3. 同帖分别走悬浮球预览与下载；从“已保存”打开新、旧记录，检查图片/视频网络回退。
   相册文件不可用时，不应把文件名作为网络资源尝试；不要删除相册文件来制造该条件。
4. AI 帖在 App 预览、全屏与“已保存”显示同样 AI 标记，点开显示平台原文与“平台识别”；
   普通帖和仅账号级标签帖不显示帖子 AI 标记。
5. 检查新增 `[IgAiProbe]` 的根标签文案与各字段枚举；如有拒绝，带回 `[RequestPolicy]` 的 code、field、
   shape、hostClass 和时间段。日志不得含正文、账号、cookie、完整 URL 或 query 值。
6. 回归小红书短链/两域选域、X 和 TikTok 的 App 大图/视频、悬浮球与下载。

以上为待用户执行的设备步骤，离线测试与 APK 检查不代表设备播放结果。
