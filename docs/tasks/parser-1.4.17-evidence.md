# parser 1.4.17 验证报告

分支 `fix/parser-1.4.17`（基于 `master` `dfb5915`，即 `v1.11.0`）。只走 parser 发布通道：
`spec/PARSER_VERSION` 1.4.17、`config/parser-release.json` manifestVersion 13、
`app/assets/parser/builtin-manifest.json` 13 / `parserVersion` 1.4.17。
**未发 App 版本**：`pubspec.yaml` 仍是 `1.11.0+59`，App 代码只改了会随内置清单变化的测试。

| 项目 | 值 |
| --- | --- |
| parser 版本 | `1.4.17` |
| manifestVersion | `13` |
| bundle（`app/assets/parser/parser.js`，即 APK 内置副本） | sha256 `482fcc7530606073466208fa42c1c9df874c524bec3eb86d9fa30bdad78e3d79`（97,214 B） |
| 清单内 `sha256` 字段 | 同上，一致 |
| 真机日志 `configHash` | `b0f351383bbec10524b7916424673a823ac8dc26b8ef34a25c3cc406ee61acbe` |
| 真机 `activeVersion` | `1.4.17`（`activeManifest=13`） |

---

## 1. 已登录但会话失效时引导重新登录

### 1.1 两类页面信号与对应 fixture

判定只发生在解析**已经失败**之后（`classify` 钩子收到 `LOGIN_REQUIRED` / `INVALID_PAGE`
且 App 认为已登录），因此它只回答「这次失败到底是哪一种」，不参与成功解析。

**小红书**（`xhsPageSignal`，`extension/src/xhs.ts`）

| 信号 | 取值 | 依据 fixture |
| --- | --- | --- |
| `当前笔记暂时无法浏览` / `笔记暂时无法浏览` / `该笔记暂时无法浏览` | `unavailable` | `spec/fixtures/xhs/xhs_note_deleted.html` |
| `笔记不存在`、`该笔记不存在`、`笔记已被删除`、`笔记已删除`、`笔记无法查看` | `unavailable` | 同上（同一族的平台提示语） |
| `该笔记为私密笔记`、`笔记已设为私密`、`作者已将笔记设为私密` | `unavailable` | 同上 |
| `内容暂时无法查看` / `当前内容无法查看` | `unavailable` | 同上 |
| `id="login-container"` / `class="…login-container…"` | `login_wall` | `spec/fixtures/xhs/xhs_session_expired.html` |
| `扫码登录`、`登录后查看`、`登录后可查看`、`登录以继续`、`请先登录`、`立即登录` | `login_wall` | 同上 |
| `"loggedIn":false` | `login_wall` | 同上 |
| URL 已是 `/login` | `login_wall` | 单元用例（`parser_1417.test.ts`，「a login redirect alone is a login wall on both platforms」） |
| 以上都不出现 | `undefined`（保持 1.4.16 行为） | `xhs_multi.html` / `xhs_live.html` / `xhs_video.html` / `xhs_profile_route.html` 均无信号 |

**Instagram**（`instagramPageSignal`，`extension/src/instagram.ts`）

| 信号 | 取值 | 依据 fixture |
| --- | --- | --- |
| `Sorry, this page isn't available` / `this page isn't available` / `page not found` | `unavailable` | `spec/fixtures/instagram/ig_post_deleted.html` |
| `页面不存在`、`该页面无法使用`、`此页面无法使用`、`页面暂时无法使用`、`链接可能已失效` | `unavailable` | 同上（中文界面同一提示） |
| `内容不存在`、`该帖子不存在`、`帖子不存在`、`该帖子已被删除`、`帖子已被删除` | `unavailable` | 同上 |
| `Log in to Instagram`、`log in to see` | `login_wall` | `spec/fixtures/instagram/ig_session_expired.html` |
| HTML 中出现 `accounts/login` | `login_wall` | 同上 |
| `登录 instagram`、`登录后查看/后可查看`、`登录以继续`、`登入以繼續`、`请先登录` | `login_wall` | 同上 |
| URL 已是 `/accounts/login` | `login_wall` | 单元用例（同上一条） |
| 以上都不出现 | `undefined`（保持 1.4.16 行为） | `ig_carousel.html`、`ig_reel.html`、`ig_og_only_post.html`、`ig_og_only_reel.html`、`blocked.html` 均无信号 |

两条刻意**不算**登录墙的信号：

* Instagram 的年龄 / 敏感内容闸门（`ig_login_wall.html`）：它要的是一次确认，不是新会话，
  继续按 1.4.16 回答 `PRIVATE_OR_UNAVAILABLE` 并保留它自己的文案（有用例固定）。
* 已登出外壳自带的 `PolarisLoggedOut*` / `CurrentUserInitialData` `USER_ID` 0：匿名抓取的
  **可读**帖子（`ig_carousel`、`ig_reel`、`blocked`）同样带着它们，无法说明会话状态。
  小红书侧对应的 `"loggedIn":false` 之所以**算**信号，见 1.2。

两类信号同时出现时「不存在 / 私密」优先（有用例：往 `xhs_note_deleted.html` 里塞
`login-container` 仍判 `unavailable`）。

### 1.2 证据分级（哪些是抓取事实，哪些是重建）

必须讲清楚，因为「已登录但会话失效」页与「已登录且帖子已删除」页都要求一个真实会话，
而本轮不允许读取、输出或记录任何 cookie，也不允许拿用户会话做抓取。

**抓取事实（可复核）**

* 小红书 `__INITIAL_STATE__.user.loggedIn` 是服务端按 cookie 渲染的：仓库里已抓取的
  登录态页面 `xhs_multi.html`、`xhs_live.html`、`xhs_video.html` 都是 `"loggedIn":true`；
  本轮匿名 `GET https://www.xiaohongshu.com/explore/000000000000000000000000`
  （2026-11-16，无 cookie）返回的 286,474 B 页面是
  `"user":{"loggedIn":false,"activated":false,…}`。也就是说**会话一旦失效，服务端就把这一位
  翻成 false**，这是小红书侧唯一不依赖文案措辞的硬信号，`"loggedIn":false` 因此进标记表。
* Instagram 登录墙的登录重定向地址是 `/accounts/login/`（`config/sites.json` 的
  `auth.loginUrl` 也是它），`accounts/login` 出现在 DOM 里同样是硬信号。
* Instagram 的登录墙措辞沿用 1.4.16 之前**已在真机验证过**的 `hasLoginWall`
  正则里的同一批词（`log in to`、`登入以继续`、`请先登录`），本轮只是把「登录墙」与
  「年龄闸门」拆开，没有扩大词表。
* 两家平台在匿名 GET 下都**不**在 HTML 里给出「不存在 / 已删除」字样（小红书 286,474 B
  与 Instagram 533,737 B 的响应里都没有），这两段提示是页面脚本渲染出来的。App 的
  `classify` 读的正是 WebView 渲染后的 `document.documentElement.outerHTML`，所以放在
  这里判定是正确的位置；但**本轮无法用真实会话复核这些渲染后的字样**。

**重建（不是会话抓包）**

* `xhs_session_expired.html`、`xhs_note_deleted.html`、`ig_session_expired.html`、
  `ig_post_deleted.html` 四份 fixture 是按上面这些事实重写的渲染后 DOM 骨架，文件头注释
  已声明；这与 1.4.16 里 `ig_login_wall.html` 的处理方式一致。

**这条风险为什么可以接受**：规则是「只有读到登录墙信号才改成 `LOGIN_REQUIRED`，
读不到就保持 1.4.16 行为」。所以最坏情况是「字样变了、没认出来」→ 回到旧的
`PRIVATE_OR_UNAVAILABLE`（也就是今天的样子），不会出现新的错误导向。反过来，
「已删除却提示去登录」用户登录后仍会看到帖子已不存在，代价可逆。

### 1.3 新规则（`extension/src/parser-modules.ts`）

| 页面信号 | App 认为已登录 | App 认为未登录 |
| --- | --- | --- |
| 不存在 / 私密 / 已删除 | `PRIVATE_OR_UNAVAILABLE` + 原 1.4.16 文案（不变） | 原逻辑（`LOGIN_REQUIRED` + 登录引导） |
| 登录墙 | **`LOGIN_REQUIRED` + `登录可能已失效，请重新登录`（新）** | 原逻辑（登录引导） |
| 两类都读不到 | 原 1.4.16 答案（不变） | 原逻辑 |

`moduleCall` 里「未登录时把 `PRIVATE_OR_UNAVAILABLE` 降级成 `LOGIN_REQUIRED`」的兼容分支
未改动，有用例固定。

### 1.4 不新增错误码；三版 App 都显示「去登录」，文案用引擎给的句子

* 1.4.17 只产出 `LOGIN_REQUIRED` 与 `PRIVATE_OR_UNAVAILABLE` 两个码，有用例断言（
  `1.4.17 introduces no new error code`）。
* 三个版本的 `error_copy.dart` **逐字相同**：`displayErrorMessage` 优先返回引擎的
  message，`errorCopyFor(LOGIN_REQUIRED)` 的 action 是 `goLogin`，`ErrorCard` 用
  `displayErrorMessage(code, message)` 渲染并把 `goLogin` 画成「去登录」。因此
  v1.10.2 / v1.10.3 / v1.11.0 的用户读到的都是「登录可能已失效，请重新登录」，
  按钮都是「去登录」，没有「重试」「返回首页」。
* 「登录后重新解析」是 App 侧既有流程（`goLogin` → 登录页 → 返回后重新解析），
  parser 1.4.17 恰好把这类页面指回这条既有流程，没有新增分支。
* 上述三条在三份 App 代码上分别实跑过（见第 3 节），不是只看代码。

### 1.5 新增 fixture（只增不改）

`spec/fixtures/xhs/xhs_session_expired.{html,expected.json}`、
`spec/fixtures/xhs/xhs_note_deleted.{html,expected.json}`、
`spec/fixtures/instagram/ig_session_expired.{html,expected.json}`、
`spec/fixtures/instagram/ig_post_deleted.{html,expected.json}`；`sources.json` 里登记
`xhs_session_expired`、`xhs_note_deleted`、`ig_session_expired`、`ig_post_deleted`。
既有 fixture 的输入文件一个字节都没改。

---

## 2. 解析器直接生成全质量 jpg 候选

### 2.1 变更

* `extension/src/xhs.ts`：新增 `fullQualityJpegImageUrl(token)` =
  `https://sns-img-bd.xhscdn.com/{token}?imageView2/format/jpg/q/100`，插在
  `imageUrlOf` 的 fallbacks **最前**（其后依次是 `ci` 的 `format/jpg`、场景图、`ci` 裸 token）。
* `xhsImageVariant`：`sns-img-*` host 上带 `imageView2` 且不带 `/w/`、`/h/`、`thumbnail`
  的地址判为 `jpeg`（此前记为 `other`，label 不准，行为不变）；钉死尺寸的转码仍是 preview。
* 视频候选、TikTok / Instagram / X 的候选完全未动（有用例比对 `xhs_video.expected.json`
  与 `ig_carousel.expected.json`）。

依据 `docs/tasks/parser-1.4.17-proposal.md` 的实测：同一 token 上
`format/jpg` = 245,672 B、`format/jpg/q/100` = 1,030,648 B、原始字节 1,007,645 B，
三者像素相同；`/quality/100` 不被识别，必须 `/q/100`。

### 2.2 候选顺序（`xhs_multi.html` 第 1 张，三版 App 实测一致）

```
1  https://sns-img-bd.xhscdn.com/{t}?imageView2/format/jpg/q/100   ← 新增，parser 直接给
2  https://ci.xiaohongshu.com/{t}?imageView2/format/jpg
3  https://sns-img-bd.xhscdn.com/{t}                               ← 原图（item.url，仍为主体）
4  https://ci.xiaohongshu.com/{t}
5  https://sns-webpic-qc.xhscdn.com/…/{t}!nd_dft_wlteh_webp_3       ← 最后兜底
```

`item.url` 仍是原图（下载策略未变），preview 永不入列，`downloadOrder[0]` 是新增候选。
实况的静态图同样以新增候选打头，动效 clip 单独成项、互不串用。

### 2.3 三版本兼容证据（worktree 实测）

| | v1.10.2（无派生） | v1.10.3（有派生、无最终去重） | v1.11.0（派生后按最终 URL 去重） |
| --- | --- | --- | --- |
| 计划请求的 URL（图片） | 5 条，与上表逐条相同 | 同 | 同 |
| 唯一 URL 数 / 总数 | 5 / 5 | 5 / 5 | 5 / 5 |
| 是否重复请求同一 URL | 否 | 否：`withDerivedJpegOriginals` 的 `_hasDeclaredJpegTranscode` 看到候选集里已有同 host+path 的 `imageview2/format/jp…` 就不再派生 | 否：`dedupeFinalCandidates` 收掉重复 |
| 新增候选是否被请求策略放行 | 是（`fallback` 角色，`xhscdn.com` 在 `mediaHosts` 内） | 是 | 是 |
| 排序 | `q/100` 第一，原图第三 | 同 | 同 |
| publish 的 `fallbacks` / `downloadOrder` | 引擎原样 | 引擎原样 | 引擎原样 |

实况：静态图 `Live 1_1.jpg` 的 URL 列表同样 5 条唯一、「q/100」第一；
`Live 1_1.mp4` 只有 1 条视频 URL（`sns-video-v27.xhscdn.com`），两者不交叉。

结论：旧版本**没有**出现问题，无需中断上报。

### 2.4 fixture 预期输出（只增不改）

新增 `spec/fixtures/xhs/xhs_multi.expected.1.4.17.json`、
`xhs_live.expected.1.4.17.json`、`xhs_profile_route.expected.1.4.17.json`，
`xhs_multi.expected.json` / `xhs_live.expected.json` / `xhs_profile_route.expected.json`
原样保留（1.4.16 的记录）。测试装载器按 `spec/PARSER_VERSION` 选版本化预期：
`parser.test.ts` 与 `xhs.test.ts` 优先用 `<name>.expected.<version>.json`，没有才回落到
`<name>.expected.json`；`xhs_image_order_build32.test.ts` 显式指向 1.4.17 预期。

---

## 3. 兼容性证明（worktree）

仿照 1.4.16：把同一份兼容测试、同一份 node harness、同一份 1.4.17 bundle
（`sha256 482fcc75…`，与内置副本逐字节相同）和三份新 fixture（无 `.expected.json`，
只作为输入）拷进各 tag 的 worktree，跑 `flutter test test/parser_1417_compat_test.dart`。

| worktree | commit | 用例 | 结果 |
| --- | --- | --- | --- |
| `v1.10.2` | `516d184` | 13 | 全部通过 |
| `v1.10.3` | `ad345e0` | 13 | 全部通过 |
| `v1.11.0` | `dfb5915` | 13 | 全部通过 |

`git status` 在三个 worktree 里都只有新增的未跟踪文件（测试、harness、bundle 副本、
4 份 fixture 输入），**没有任何被修改的已跟踪文件**，tag 内容未被改写。三个 worktree
用完后已 `git worktree remove --force` 并 `git worktree prune` 删除。

测试本身提交在本分支：`app/test/parser_1417_compat_test.dart` +
`app/test/parser_1417_compat/harness.mjs`。harness 用 `EasySaveParser.moduleCall` 跑真实
bundle（页面 DOM 只是桩），`parser_1.4.17.js` 若存在则优先于 APK 自带副本，所以同一份
测试能在旧 worktree 里指向本版本；在本分支上它跑的就是内置副本。

---

## 4. 发布准备与真机验证包

* `spec/PARSER_VERSION` = `1.4.17`；`config/parser-release.json` `manifestVersion` = 13；
  `npm run build:parser` 重建 `app/assets/parser/parser.js`、
  `app/lib/generated/parser_version.dart`、`app/assets/parser/builtin-manifest.json`
  （`parserVersion` 1.4.17、`parserUrl` `…/parser-v1.4.17/parser.js`、`sha256` 与 bundle 一致）。
* `CHANGELOG.md` 新增 `[Unreleased] → 解析器 / Parser` 两条（中英对应），说明登录失效
  与全质量 jpg 候选，并写明不随 App 版本发布。
* 验证用 APK（**仅供验证，未上传任何 Release**）：
  `app/build/app/outputs/flutter-apk/app-release.apk`，24,108,960 B，
  `versionCode=60`、`versionName=1.11.0`、arm64-v8a，release 签名，
  证书 SHA-256 `08d7da286f2a84251ddfa85d1a49dc1b1d6b3ffc59ab7d117d8db783b0633907`；
  `assets/flutter_assets/assets/parser/builtin-manifest.json` 为 `manifestVersion 13` /
  `parserVersion 1.4.17`，包内 `parser.js` sha256 与 `482fcc75…` 完全一致。
* 真机（`ead4148c`，`adb install -r` 覆盖安装，未卸载、未清数据）启动日志：

```
[ParserUpdate] event=select builtin=1.4.17/13 stored=- chosen=builtin reason=stored_none
[ParserUpdate] event=activated version=1.4.17 source=builtin manifestVersion=13 configHash=b0f3513…
[ParserUpdate] event=session stream=foreground app=1.11.0 builtinVersion=1.4.17 builtinManifest=13 activeVersion=1.4.17 activeManifest=13
[ParserUpdate] event=check trigger=startup result=older remoteVersion=1.4.16 remoteManifest=12 localManifest=13 localVersion=1.4.17
```

  即 v1.11 的「取 manifestVersion 较高的一份」规则生效：内置 13 高于在线 12，
  `activeVersion=1.4.17`，在线更新判为 `result=older` 不会把设备降回去。
  `manifestVersion` 保持 13；从现在起到打 tag 之间不再改 parser 代码。

---

## 5. 测试矩阵

| 命令 | 结果 |
| --- | --- |
| `extension: npm test`（`wxt prepare` + `tsc --noEmit` + vitest + 3 个 node 检查） | 30 个文件 / 322 项通过；node 检查 33 项通过（含「仓库 bundle 与 `config/parser-release.json`、`spec/PARSER_VERSION` 一致」「sha256 与清单一致」「`parser_version.dart` 未过期」） |
| spec 向量（`spec/test-vectors/site-links.json` 由 `site_registry_links_test.dart` 与 Kotlin `SiteLinksCorpusTest` 两端读同一份） | 随下面两条一起通过 |
| `app: flutter test` | 1,440 项通过（含 `media_request_policy_test`、`parser_1417_compat_test`、`v1103_parser_selection_test`） |
| `app/android: gradlew testDebugUnitTest` | 135 项、0 失败、1 跳过（`BUILD SUCCESSFUL`） |
| `app: flutter analyze` | 0 error（26 warning / 72 info，全部为既有问题；本次新增/修改的文件未产生任何诊断） |

命令环境：每条先 `fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression`；
`JAVA_HOME` 仅在 gradle 那条进程内指向 `jdk-21`（`D:\Program Files\Java\jdk-21`）。
（`fnm env` 反复叠加会超过 Windows 命令行长度上限，故后续命令改为从同一 fnm 环境取出的
node 目录继续使用，node 版本 `v26.13.0`、npm `11.20.0` 未变。）

---

## 6. 未验证与残余风险（如实列出）

1. **渲染后字样未用真实会话复核**（1.2）。规则的安全边界是「读不到就保持原状」，
   因此这是「可能不生效」，不是「误判成别的东西」。
2. 小红书「已登录 + 帖子已删除」页面的提示措辞随 A/B 与版本会变；若换成未收录的措辞，
   会回落到 1.4.16 的 `PRIVATE_OR_UNAVAILABLE`（用户可见结果与今天相同）。
3. `/q/100` 若在某些 token 上不被 CDN 接受，会退回下一个候选（`ci` 的 `format/jpg` 或原图），
   最多多花一次尝试；候选列表已用 fixture 固定。
4. 旧版 App 的候选完全由引擎给的顺序决定（v1.10.2 不派生、v1.10.3 有同址转码就不派生），
   已实测 5 条唯一 URL；未覆盖「引擎与 App 派生结果 host 不同」这种组合，因为双方都只会
   产出 `sns-img-bd` 同一地址。

## 7. 本轮不变量

未推送分支、未打 `parser-v*` tag、未发 App 版本、未上传 Release、未读取或打印任何
签名密钥与 cookie、未请求断点或调试会话、未卸载 App / 清数据 / 删相册文件、
未改写既有提交与 fixture 输入、`spec/manifest.json` 与 `spec/parser.js`（冻结 1.2.4）
未变、所有文本保持 LF。

---

# 附录（manifestVersion 14）：build60 真机 FormatException 的定位与修复

本节记录验证包 versionCode 60（内置 parser 1.4.17 / manifestVersion 13）在真机上退出小红书
登录后解析帖子失败的报告，以及随后的定位、修复与重新构建。上文表格里的
「manifestVersion 13 / bundle `482fcc75…`」是 1.4.17 的**首次**构建；本附录完成后
manifestVersion 改为 **14**、bundle 变为 `f49a8928…`（见 §10）。1.4.17 仍未发布。

## 8. 故障与定位

### 8.1 真机现象（build60）

退出小红书登录后解析帖子，界面只有「重试」，标题行是
`FormatException: Invalid parser hook result 页面内容无法识别，可能已改版`。
日志（`v16dl_build60.log`）：

```
[XhsDomain] event=choose from=rednote.com to=xiaohongshu.com reason=alias_valid   （反复）
[ParseWebView] navigations=15~17  耗时 8.4–8.8s   最终 path=explore
[ParseMismatch] check=HOOK_RESULT site=xhs hook=parsePage expected={value:<json>} actual=type=Null
[ParseWebView] event=failure … condition=parse code=UNEXPECTED
[ParseMismatch] check=UNCAUGHT expected=ParseFailure actual=type=FormatException
```

### 8.2 `actual=type=Null` 只有一种来源

`parsePage` 在 1.4.16 / 1.4.17 里都不会返回 `null`：所有分支都经过
`JSON.stringify({value: …})`，失败也是 `{ok:false,error:{code,message}}`。而
`app/lib/services/parser_hooks.dart` 的 `unwrapHookResult` 里
`actual=type=Null` 只出现在**整条 JS 答案为空**时（`raw == null` 或 `"null"`），
即 `evaluateJavascript` 拿到了空结果——也就是 `EasySaveParser.moduleCall(...)`
**抛了异常**（WebView 把异常折成空返回值）。

复现（把 document 摆成「正在被替换」的样子，两种形态都试）：

| 场景 | parser 1.4.16 | parser 1.4.17（build60） |
| --- | --- | --- |
| `document.documentElement === null` | 抛 `TypeError: Cannot read properties of null (reading 'outerHTML')` | 抛同样的 `TypeError` |
| 读取 `documentElement` 即抛错 | 抛出该错误 | 抛出该错误 |
| 正常文档（首页/`/explore`） | `LOGIN_REQUIRED` 错误对象 | `LOGIN_REQUIRED` 错误对象 |

`_parse_page.parsePageForModule` 的 `document.documentElement.outerHTML` 与
`parser-modules.moduleCall` 的 `case 'parsePage'` 分支当时都没有保护；真机上
15–17 次导航（8.4–8.8s）正好让钩子落在这类过渡态。同类空答案还有两处：
Instagram 的 `probe: () => null`、TikTok 无 `probe` 钩子时 `moduleCall` 抛
`UNSUPPORTED_HOOK`（build60 日志里 tiktok 的那行 `hook=probe … type=Null` 就是它）。

### 8.3 1.4.16 与 1.4.17 的对比实验（三份 App 代码）

页面用新 fixture `xhs_redirected_home.html`（帖子链接被重定向到 `/explore`、未登录），
在 v1.10.2（`516d184`）/ v1.10.3（`ad345e0`）/ v1.11.0（`dfb5915`）的 worktree 上，
用同一份 harness 分别跑 1.4.16（`91434d22…`）与 1.4.17/14 的 bundle：

| 钩子 / 页面 | 1.4.16（三版结果一致） | 1.4.17 manifestVersion 14（三版结果一致） |
| --- | --- | --- |
| `parsePage`（落在 `/explore`） | `LOGIN_REQUIRED`「Xiaohongshu returned an authenticated-only shell without note data.」 | `LOGIN_REQUIRED`「需要先登录小红书才能解析该笔记」 |
| `classify`（App 未登录） | `LOGIN_REQUIRED`「需要先登录小红书才能解析该笔记」→「去登录」 | 同左 |
| `classify`（App 认为已登录） | `PRIVATE_OR_UNAVAILABLE`「分享链接可能已过期…」→「返回首页」 | `LOGIN_REQUIRED`「登录可能已失效，请重新登录」→「去登录」 |
| `parsePage`（帖子 URL + 文档不可读） | **抛异常 → App 得到空答案 → `FormatException`** | `INVALID_PAGE`「页面内容无法识别，可能已改版」 |

结论：

1. **不是 1.4.17 引入的**。同一个「文档不可读」触发条件在 1.4.16 上抛一样的异常，
   三个 App 版本都一样；1.4.17 只是把「已登录却被弹回首页」从
   `PRIVATE_OR_UNAVAILABLE` 改成会话失效提示，异常与它无关。
2. 「重定向到 `/explore`」这个页面本身在 1.4.16 上也不会崩：它给出
   `LOGIN_REQUIRED` +「去登录」。真机上的空答案来自**钩子与导航竞争**，不是页面解析。
3. 1.4.16 在三版上的 `PRIVATE_OR_UNAVAILABLE`（「分享链接可能已过期」）正是 1.4.17
   要纠正的误导；这部分 1.4.17 是对的，保留。

## 9. 修复（parser 侧，manifestVersion 14）

### 9.1 (a) 帖子链接被弹回首页 / 登录页

* `extension/src/xhs.ts`：新增 `xhsLandingPage(url)`（`pathname` 为 `/login…` 或
  `/explore`、`/explore/`，即没有笔记 id）与常量 `XHS_LOGIN_REQUIRED`
  =「需要先登录小红书才能解析该笔记」（沿用既有文案，不新增文案）。
* `_parse_page.parsePageForModule`：xhs 且落在落地页 → 直接
  `{ok:false,error:{code:'LOGIN_REQUIRED',message:XHS_LOGIN_REQUIRED}}`；
  `parse`（guest HTML 路径）同样处理。
* `parser-modules.xhs.classify`：`LOGIN_REQUIRED` / `INVALID_PAGE` 的失败在
  App **未登录**时给「需要先登录小红书才能解析该笔记」；App **认为已登录**时，
  若 URL 是落地页或页面带登录墙信号 → `LOGIN_REQUIRED` +「登录可能已失效，请重新登录」；
  两类信号都没有才维持 `PRIVATE_OR_UNAVAILABLE`。

### 9.2 (b) 任何 hook 都不再返回 null / 无法识别的结构

`moduleCall` 改为 `runHook(...)` + 兜底 `fallbackHook(...)`：整条钩子包在 try/catch 里，
任何异常都折成该钩子自己文档化的形状。

| hook | 兜底答案 | 说明 |
| --- | --- | --- |
| `parse` / `parsePage` | `{ok:false,error:{code:'INVALID_PAGE',message:'页面内容无法识别，可能已改版'}}` | 不再抛异常、不再空 |
| `classify` | `context.error`，没有则 `INVALID_PAGE` | 不再返回空 |
| `ready` / `prepare` | `false` | App 的 `_emptyAnswer` 只接受 `false` |
| `install` / `navigate` / `account` | `null` | App 明确接受 `null` |
| `probe` | `{tag:'NoProbe'}` | 之前 IG 是 `null`、TikTok 是抛 `UNSUPPORTED_HOOK`，两处都会在日志里留下 `HOOK_RESULT type=Null` |
| 其他/未知钩子、未知 module | `{value:null}` / 结构化失败 | 不再 `throw UNSUPPORTED_MODULE/HOOK` |

页面侧同样收紧：

* `readableDocumentHtml()` / `currentPageUrl()` 都 try/catch，`documentElement` 为 null
  或读取抛错时返回 `undefined`/`''`；
* `parsePageForModule` / `parse` 外层 try/catch，出错回 `INVALID_PAGE`；
* `moduleCall` 的 `parsePage` 分支：页面缓存不 ok 且**文档读不出来**时，用页面级答案
  （`INVALID_PAGE` 或落地页的 `LOGIN_REQUIRED`），不再拿空 HTML 去猜成登录问题；
  HTML 兜底解析失败时统一 `INVALID_PAGE`。

四个平台逐项检查：

| 平台 | 检查结果 |
| --- | --- |
| 小红书 | `parsePage`/`parse`/`classify`/`ready`/`probe`/`probeSession`/`account`/`decorate` 全部有形状；`classify` 新增落地页判断 |
| Instagram | `probe` 由 `null` 改为 `{tag:'IgParse',reason:'no_probe'}`；`ready`/`prepare` 读 DOM 抛错时回 `false`；`parsePage` 走统一兜底 |
| X | `request` 抛 `UNSUPPORTED_URL` 时回 `{value:null}`（App 的 `REQUEST_SHAPE` 检查给出可读文案）；`parsePage` 回 `UNSUPPORTED_URL` 对象；`probe` 恒为 `XProbe` 结构 |
| TikTok | 无 `probe` 钩子时回 `{tag:'NoProbe'}`；`navigate`/`ready`/`parse` 均有形状（`navigate` 无 id 时 `{wait:true}`） |

### 9.3 (c) 新 fixture（只增不改）

`spec/fixtures/xhs/xhs_redirected_home.{html,expected.json}`，`sources.json` 登记
`xhs_redirected_home` → `https://www.xiaohongshu.com/explore`。

* 文件头注释写明：按**公开匿名**的 `xiaohongshu.com/explore` 结构重写的首页骨架，
  未使用任何会话、未抓取登录态，id / 昵称 / 图片地址全部虚构。
* `__INITIAL_STATE__` 只用公开结构（`user.loggedIn:false`、`note.noteDetailMap`
  带一条空壳、`feed.feeds` 两张示例卡），DOM 只有 `登录` 按钮与两列卡片；
  刻意**不含**登录弹窗文案，避免把它当成登录墙 fixture。
* 既有 fixture 输入文件一个字节未改（`git diff --stat spec/fixtures` 只有本文件与
  `sources.json`）。

### 9.4 (d) 兼容测试补充（该场景 × 三个 App 版本）

`app/test/parser_1417_compat_test.dart` 新增分组
「a note link Xiaohongshu redirects to the home feed」，5 个用例：
落地页 `parsePage` 必为 `LOGIN_REQUIRED`；未登录 / 已登录两种 `classify` 文案；
`validateParserResult` 抛 `ParseFailure(LOGIN_REQUIRED)` 而非 `FormatException`；
错误卡只有「去登录」、没有「重试」；文档不可读时 `INVALID_PAGE`（`doc=missing` 与
`doc=throwing` 两种）。harness 新增第 9 个参数 `doc:page|missing|throwing`。

三个 worktree 实跑（同一份测试 + 同一份 harness + 1.4.17/14 bundle 副本 +
5 份 fixture 输入，全部为未跟踪新增文件）：

| worktree | commit | 用例 | 结果 |
| --- | --- | --- | --- |
| `v1.10.2` | `516d184` | 18 | 全部通过 |
| `v1.10.3` | `ad345e0` | 18 | 全部通过 |
| `v1.11.0` | `dfb5915` | 18 | 全部通过 |

`git status` 在三个 worktree 里都只有新增的未跟踪文件，没有任何被修改的已跟踪文件。
用完后已 `git worktree remove --force` + `git worktree prune`。

## 10. 重新构建的验证包（未推送、未打 tag）

| 项目 | 值 |
| --- | --- |
| parser 版本 | `1.4.17` |
| manifestVersion | **14** |
| bundle sha256（`app/assets/parser/parser.js`） | `f49a8928542842b2f6c1d1730c61815500d8c4ce790e50f4dc8be1bbd207eca1`（100,526 B） |
| 清单 `sha256` 字段 | 同上，一致 |
| `app/lib/generated/parser_version.dart` | `1.4.17` |
| APK | `versionName=1.11.0`、`versionCode=61`、release 签名、arm64-v8a 等（见下） |

`docs/roadmap.md` 已记录：验证包占用了 versionCode 60 / 61，
**正式 App 的下一个 versionCode 须 ≥ 62**。

### 10.1 构建产物

* 构建命令：`flutter build apk --release --build-number 61 --target-platform android-arm64`
  （`app/pubspec.yaml` 仍是 `1.11.0+59`，versionCode 只由命令行参数给出，与上一轮一致）。
* `app/build/app/outputs/flutter-apk/app-release.apk`：24,109,540 B，
  `versionCode=61`、`versionName=1.11.0`，release 签名，
  证书 SHA-256 `08d7da286f2a84251ddfa85d1a49dc1b1d6b3ffc59ab7d117d8db783b0633907`
  （与 build60 同一张证书，只读了 APK 里的公钥证书，未读取、打印或复制任何签名密钥）。
* APK 内 `assets/flutter_assets/assets/parser/parser.js` sha256
  = `f49a8928542842b2f6c1d1730c61815500d8c4ce790e50f4dc8be1bbd207eca1`（100,526 B），
  与仓库 bundle、`builtin-manifest.json` 的 `sha256` 字段完全一致；
  `builtin-manifest.json` 为 `manifestVersion 14` / `parserVersion 1.4.17`。

## 11. 测试矩阵（本轮实跑）

每条命令先执行 `fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression`
（node `v26.13.0`）；`JAVA_HOME` 只在 gradle 那条进程内指向 `D:\Program Files\Java\jdk-21`。

| 命令 | 结果 |
| --- | --- |
| `extension: npm test` | 30 个文件 / **333** 项通过；node 检查 33 项、`fail 0`（含「仓库 bundle 与 `config/parser-release.json`、`spec/PARSER_VERSION` 一致」「sha256 与清单一致」「`parser_version.dart` 未过期」） |
| spec 向量（`spec/test-vectors/site-links.json`，由 `site_registry_links_test.dart` 与 Kotlin `SiteLinksCorpusTest` 两端读同一份） | 随下面两条一起通过 |
| `app: flutter test` | **1,446** 项全部通过（含 `media_request_policy_test`、`parser_1417_compat_test`、`xhs_redirected_home` fixture 用例） |
| `app/android: gradlew testDebugUnitTest` | `BUILD SUCCESSFUL` |
| `app: flutter analyze` | **0 error**；26 warning / 72 info = 98，与基线相同；本次新增与修改的文件 0 条诊断 |

`flutter test` 期间唯一需要跟着改的用例是 `v1103_parser_selection_test.dart` 里
「上一版 APK 留下的设备」那条：它把**内置**清单号写死为 13，manifestVersion 升到 14
后必然失败，已同步改为 14（只改这一个常量与对应注释，行为断言未变）。App 的
`lib/` 代码一行未改。

## 12. 残余风险与不变量

### 12.1 残余风险

1. **触发条件是按日志推断的，未在真机复现**。日志能证明的是「`parsePage` 给出了空答案」，
   而空答案只有一种来源（`moduleCall` 抛异常）。JS 层能复现的两种形态（`documentElement`
   为 null、读取即抛）在 1.4.16 与 1.4.17 上都抛同样的异常；若真机实际是 WebView 在导航
   中**销毁了 JS 上下文**（脚本根本没跑），parser 侧无论怎么改都拿不到执行机会——这一类只能
   靠 §9.4 之后的 App 待办（不显示原始异常、已知站点给「去登录」）兜住。两种情况用户可见
   结果都已不再是 `FormatException`：前者现在返回 `INVALID_PAGE`，后者由 App 侧统一文案。
2. **fixture 是重写的骨架**。真机首页的 `__INITIAL_STATE__` 字段更多（实测 35 张卡、更多
   子状态），fixture 只保留与判定相关的结构；判定只依赖 URL 路径与 `loggedIn` 位，因此这些
   差异不影响结论，但「真机页面结构变化」仍需 A/B 观察。
3. **落地页判定假设「被弹回首页 = 登录问题」**。若某个帖子被删后也重定向到 `/explore`，
   已登录用户会看到「登录可能已失效，请重新登录」；登录后仍会被弹回，代价可逆，但不如
   「链接已过期」精确。带平台自身「笔记不存在」提示的页面仍优先判 `PRIVATE_OR_UNAVAILABLE`。
4. **导航风暴本身未修**：`XhsDomain` 在 `xiaohongshu.com` / `rednote.com` 之间反复选择
   15–17 次是 App 侧行为，parser 无法阻止，只记入待办（§9 对应 `docs/roadmap.md`）。

### 12.2 本轮不变量

未推送分支、未打 `parser-v*` tag、未发 App 版本、未上传 Release；未读取、打印或复制任何
签名密钥（只读 APK 内公钥证书）；未读取、输出或记录任何 cookie 值；未使用现有会话抓取
页面（新 fixture 只依据公开匿名结构与已抓取的公开页面重写）；未请求断点或调试会话；
未卸载 App、未清数据、未删相册文件；未改写既有提交与既有 fixture 输入文件；所有文本保持 LF。
