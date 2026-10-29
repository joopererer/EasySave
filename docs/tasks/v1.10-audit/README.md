# v1.10 / 2b-2 最终硬编码复查

2026-10-29，分支 `feature/v1.10`，第 5 项提交 `bbcef4c` 后复跑。
运行 `rtk proxy python scripts/audit_site_hardcoding.py`，扫描 App Dart、Android 主源码、受控后台下载插件的 Android 主源码、扩展源码/入口/静态规则、构建和 CI 配置、站点清单与生成投影。共 195 个文件、494 行词法候选、0 行未归类。逐行源码、行号及理由见 [hardcoded-inventory.md](hardcoded-inventory.md) 和 [hardcoded-hits.json](hardcoded-hits.json)。测试、fixture、生成的 parser bundle 不重复计数。

## 媒体请求策略结论

App 的 `refererFor` 四站表、TikTok 主页 Cookie 取法、按平台判断媒体下载传输/重试/候选顺序、Dart 按 URL 查询参数猜媒体过期时间均已移除。下载、图片/视频预览、分享、Kotlin 选择面板使用逐资源声明的媒体主机、请求头、Cookie 域和过期时间。Dart 和 Kotlin 的重定向消费者每跳重新校验；Cookie 只按该跳实际媒体 URL 查询且不沿用上一跳。原生面板不读 Cookie，需要 Cookie 的资源显示占位并引导 App 内预览。请求拒绝只记录固定错误码和主机名，并显示统一提示。

人工搜索覆盖 `refererFor`、平台名与 `Cookie`/`Referer` 同行、`CookieManager`、`followRedirects`、`instanceFollowRedirects`、`openConnection`、`Image.network` 和 `VideoPlayerController.networkUrl`；核对每个媒体消费者及插件的实际调用链。**按平台写死的媒体请求策略已清空。** `auth.dart` 的 `cookieHeaderFor` 是登录状态/解析探测，`parse_service.dart` 的 Cookie 查询是页面解析输入，均不向媒体请求转发。`session_media_download.dart` 保留显式传入 URL 的本地传输测试接口；生产调用始终传策略及资源声明。

## 仍保留的平台信息

| 类别 | 位置 | 保留理由 |
|---|---|---|
| 内置图标资源 | `app/lib/widgets/shared.dart` 的 `assetKey` 到 Material 字形映射 | 字形随 APK 打包，清单只选择已存在的本地资源。 |
| 通用安全规则 | `login_navigation.dart` 的 Google OAuth 精确主机校验；`auth.dart` 的 loopback 校验；DevLog/Android 日志脱敏与媒体策略的 HTTPS、域名边界、头白名单 | 这些是跨站安全边界，不能由站点清单放宽。 |
| 外部转交许可表 | `services/links.dart`、`seal.dart`、`clipboard_guard.dart`、`pages/parse_page.dart`、`batch_page.dart`、Android `ExternalHandlers.kt`、`MainActivity.kt`、`AndroidManifest.xml` | YouTube 只可显式交给已许可的本地 Seal 包；包名、可见性和 Intent 是 App 产品边界。 |
| 旧通道兼容代码 | `update_service.dart` 的旧 X endpoint/UA；`extension/src/index.ts`、`_utils.ts`、`manifest.ts`、`errors.ts`；`config/parser-release.json` | 保持旧 `platforms/headers` 和 `parse(input,pageUrl)` 通道 ABI；App v2 请求从当前清单与逐资源声明读取。 |

清单源 `config/sites.json`、内置生成清单、Android 链接识别 JSON 是同一配置的源与投影，不是独立平台请求表。签名 TS parser 的站点 DOM/JSON 提取、媒体选择、canonical/ID 算法是可执行解析实现；普通 JSON 无法替代这些算法，详见逐行盘点。

扩展的 `wxt.config.ts`、`entrypoints`、`public/rules.json` 仍含浏览器打包权限、内容脚本注入范围和旧 DNR 规则。这些属于浏览器旧通道和静态权限，不能由 App 私有热更新清单扩大；改动需要独立的扩展协议与重新发布。本轮 2b-2 针对 App 媒体请求，不改浏览器扩展的请求权限。词法盘点不能证明任意动态 URL 的安全性；该边界由策略单测、原生重定向单测及四套全量测试验证，真机 URL/重定向仍列首验项目。
