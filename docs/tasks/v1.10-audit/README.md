# v1.10 / 2b-1 最终复查结论

2026-10-29，分支 feature/v1.10。第 4 步提交 3ae2b0f 后执行。
这是 2b-1 的完成盘点，不表示 2b-2 媒体授权或整个 2b 已完成。

复跑：rtk proxy python scripts/audit_site_hardcoding.py。
hardcoded-inventory.md 按文件、行号列出所有词法候选与保留理由；
hardcoded-hits.json 保留每一行原始源码，含注释/符号/生成配置，便于复查。
扫描 app/lib Dart、Android 主源码 Kotlin/XML/识别视图、extension/src TS/JS、
entrypoints、wxt.config.ts、public/rules.json、build_release.js、全部 workflows，
另列 config 与内置生成清单。当前共 154 文件、499 行命中。
测试/fixtures、说明文档、生成 parser bundle 不作为独立运行配置再次计数。
这不是形式化的零硬编码证明：关键词扫描后还检查了平台比较、网络消费者和配置生成链路。

## 本次移除的遗漏

- services/login_navigation.dart 的 TikTok Google 登录指引迁至
  config/sites.json 的 auth.externalGoogleMessage，LoginPage 按当前 siteId 读取。
  Google OAuth 的精确 host 判定和通用兜底仍属于可信客户端安全规则。
- services/preview_video.dart 的 TikTok 播放错误文案迁至 previewErrorMessage。
  预览 headers / Cookie / controller 的请求实现与第 4 步提交逐字相同。
- 两个可选文本字段均有 Schema 类型、长度约束，重新生成内置 Schema、
  builtin manifest 与 builtin_sites。原 TikTok 文案逐字保留，未知站点使用通用提示。
  测试覆盖配置替换、原文保持、未知站点及非法字段拒绝。

## 四类允许保留的信息

| 类别 | 位置与用途 | 保留理由 |
|---|---|---|
| 内置图标资源 | app/lib/widgets/shared.dart:238–241 | assetKey 到已打包 Material 字形的注册表；清单只选择资源，未知 key 使用通用图标。 |
| 通用安全规则 | services/login_navigation.dart:8–9；auth.dart 的 loopback 判断；core/dev_log.dart、background/background_entry.dart、Android LogSanitizer.kt | Google 内嵌 OAuth 限制、loopback 和全局日志脱敏与社交站点无关；不能由远程清单放宽。日志中的平台词只是注释示例，执行规则会去掉所有 URL query 和凭据。 |
| 外部转交许可表 | services/links.dart:57–102、seal.dart:13–38；pages/parse_page.dart、batch_page.dart、clipboard_guard.dart 的消费者；Android ExternalHandlers.kt:9–31、MainActivity.kt:29–30/166–177/610–624、AndroidManifest.xml:138 | YouTube 的域/路径只允许显式交给本机 Seal 包；包名、包可见性、转交通道及安装说明是同一产品边界，远程配置不能指定任意包。 |
| 旧通道兼容代码 | update_service.dart:467–480；extension/src/index.ts:37–85、_utils.ts:10–19、manifest.ts:22、errors.ts:14–23；config/parser-release.json 的 platforms/headers | 保留 v1 platforms/headers 和 parse(input,pageUrl) 契约。App v2 解析已走 Registry→parserModule；旧 getter 的 X 默认 UA/endpoint 不当作 v2 清单表。扩展还消费冻结 v1 通道。 |

表中的分组不是遗漏逐行说明；所有命中行和对应理由均在两个生成附件。
清单源 config/sites.json、本地 generated/builtin_sites.dart、builtin-manifest.json、
Android link-recognition.json 属同一源配置的投影，不是允许新增的独立平台表。
build_release.js 与 CI 没有社交站点域表；仓库 URL、标签、发布文件路径属于分发基础设施。

## 超出四类但本轮不能迁移的逐处说明

这些项明确列作范围限制，未伪装成四类获准保留项，也未声称已迁移。

| 位置 | 仍写死的信息 | 为什么本轮不能迁移 |
|---|---|---|
| services/download_manager.dart:44 | TikTok 按 URL 数量决定重试次数 | 改用清单会改变实际重试策略；用户本轮明确禁止，留 2b-2。 |
| services/download_manager.dart:47 | TikTok 非图片资源使用会话传输 | 牵涉当前下载任务状态、续传和会话安全，需与逐请求授权一同迁移，留 2b-2。 |
| services/download_manager.dart:59 | TikTok 优先主媒体 URL，其他站点优先 fallback | 这是实际下载候选顺序，不能在本轮改变请求策略；留 2b-2。 |
| services/download_manager.dart:1267 | 从 TikTok 页面查询 Cookie | 已知旧策略；不能只替换域名而继续不加请求授权。按用户约束保持，2b-2 验证实际媒体 URL Cookie 后整体修改。 |
| services/saver.dart:18–21 | 四站默认 Referer | 图片/视频/分享/预览共用请求输入，改成清单会改变网络头；明确留 2b-2。 |
| services/preview_video.dart:11–12 | TikTok Cookie 分支与页面 Cookie URL | 属预览请求策略，保持逐字实现，留 2b-2；只迁走该文件的显示文案。 |
| services/session_media_download.dart:70 | TikTok Referer | 会话下载和重定向安全要与授权同时改，不能本轮仅替换字符串。 |
| extension/wxt.config.ts:10–18、34–37；entrypoints/content.ts:3–12 | 浏览器 host_permissions、内容脚本注入范围 | 浏览器打包权限，App 私有清单不能提升；改变需扩展自身清单/授权与重新发行，超出 App 2b-1。 |
| extension/public/rules.json:8–40；entrypoints/background.ts:51–53、125 | 扩展 DNR 的 host→header 及旧 X endpoint 兜底 | 依赖旧扩展通道和浏览器权限；本轮不改下载请求策略，不把 App 热更新解释成可突破扩展权限。 |
| entrypoints/content.ts:124–449、611 | IG/XHS 当前页缓存、抓取、注入和平台入口 | 这是旧扩展的浏览器环境适配，不能由 App Registry 直接替代。需单独扩展协议/注入迁移，保留既有功能。 |
| extension/src/parser-modules.ts:25–80、page-hooks.js:75/97、page-hooks.d.ts:2–3 | xhs/instagram/x/tiktok 模块与 ready/account/probe/错误归类 | 属签名可执行模块注册及页面语义，清单只能选模块，不能用普通 JSON 取代 JS 实现。此前已从 Dart 迁出，不在 App 再保留站点分支。 |
| extension/src/_parse_page.ts:17–174 | DOM/页面缓存提取与旧 parse 适配 | 保留经 fixture 验证的取数算法和 ABI；泛化需更改签名模块实现，而不是站点显示配置。 |
| extension/src/xhs.ts:114–122、362–496、564–573、715 等 | CDN 原图/视频、canonical 和分享 query 保留 | 基于源页面字段的媒体/来源算法。包括保留 xsec_token 的行为，不能粗略套模板丢失 parser 输出语义；完整命中逐行见附件。 |
| extension/src/instagram.ts:230–249、328–330；x.ts:40/53/198–199/268；tiktok.ts:9–25、81–131；ai-label.ts:11/18 | 页面识别、短码/ID、canonical、媒体选择和 AI 语义 | 签名 parser 的站点算法，不是 App 的链接许可或 metadata 表。JSON 清单无这些执行语义；本轮保持迁移前解析结果及其 fixture 契约。 |

Android SelectPanelView.kt:945–951、1002、1119 仍按传入 URL 查询 Cookie；
shared.dart 图片组件、share_service.dart 等仍消费旧请求头。它们没有另藏站点域表，
但也属于 2b-2 必须统一授权的网络路径，不能因本次词法无命中而视为已安全迁移。

## 边界和验收

- creditName / authorIdRule、开放平台映射、账号入口、UI 名称/颜色/提示均已由当前清单驱动。
- Instagram numeric 是用户明确批准的缺陷修正；54 项迁移前比较仅有这一显式例外。
- 旧 spec/manifest.json 和 spec/parser.js 字节不变；未改备份代码或抖音条目。
- 本次最终全量：npm 147 + 20、Flutter 559、analyze 72 项且无 error、
  Gradle testDebugUnitTest BUILD SUCCESSFUL；定向文本/登录/预览验证 15 项通过。
- 未进行真机验证、合并、推送或发布；真机与 2b-2/2c/2d 继续按主任务阶段执行。
