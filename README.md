<div align="center">
  <img src="docs/design/icon/easysave-icon-C/png/easysave-icon-circle-512.png" width="112" height="112" alt="EasySave 图标">
  <h1>EasySave</h1>
  <p>保存喜欢的图片与视频，也留下它们的来源。</p>
  <p><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
</div>

<p align="center">
  <a href="app/android/app/build.gradle.kts"><img src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&amp;logoColor=white" alt="Android 7.0 及以上"></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Built_with-Flutter-02569B?logo=flutter&amp;logoColor=white" alt="使用 Flutter 构建"></a>
  <a href="https://github.com/joopererer/EasySave/releases"><img src="https://img.shields.io/github/v/release/joopererer/EasySave?filter=parser-v*&amp;label=parser" alt="解析器最新发布版本，非 App 版本"></a>
  <a href="https://github.com/joopererer/EasySave/actions/workflows/release_parser.yml"><img src="https://github.com/joopererer/EasySave/actions/workflows/release_parser.yml/badge.svg" alt="解析器发布工作流状态，非全量 App CI"></a>
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#功能亮点">功能亮点</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="docs/roadmap.md">路线图</a> ·
  <a href="https://github.com/joopererer/EasySave/issues">反馈问题</a>
</p>

EasySave 是一个以 **Android** 为主要目标平台的媒体保存工具，支持从小红书、Instagram、X 和 TikTok 帖子中解析并保存图片、视频与 Live Photo。除了下载，它还提供本地历史浏览、来源元数据、备份恢复，以及不离开当前 App 的快捷下载入口。

> **开发状态**：v1.10 正在开发与真机验证中，已实现内容不等于全部完成设备验收；v1.11 文档中的候选方案尚非现有功能。请结合[更新日志](CHANGELOG.md)与[任务记录](docs/tasks/v1.10.md)查看状态。

## 功能亮点

- **多平台媒体保存**：预览帖子、按需选择图片和视频、批量处理链接，保存到系统相册。
- **便捷下载入口**：支持系统分享、后台分享下载、快捷设置磁贴，以及可选的悬浮球选择面板。
- **媒体浏览与管理**：图片缩放、视频播放、Live Photo 长按预览；按帖子、全部媒体或作者浏览历史，支持搜索、筛选和分享。
- **保留内容来源**：为支持的图片和视频写入 XMP 来源信息，记录原帖、作者及平台提供的 AI 标注；带 C2PA 内容凭证的图片保留原字节，并用 XMP 边车文件记录来源。
- **备份与恢复**：导出历史和非敏感设置，支持自动备份到自选文件夹，也可从相册中的来源信息重建历史。
- **可信解析器更新**：App 对在线解析器执行签名、哈希与兼容性验证；更新失败时保留可用版本，无需为每次解析规则修复重新安装 APK。

## 支持范围

| 平台 | 内容 | 说明 |
| --- | --- | --- |
| 小红书 | 图片、视频、Live Photo | 部分内容需要登录或完整分享链接；原图可用性受平台返回资源影响 |
| Instagram | 图片、轮播、视频 / Reels | 部分内容需要登录，敏感内容与平台限制可能影响解析 |
| X（Twitter） | 图片、视频、GIF 类媒体 | 部分受限帖子可使用已有登录状态，仍受账号访问权限限制 |
| TikTok | 视频、图集 | 会话视频中断后可能需要重新解析，不保证断点续传 |
| YouTube | 外部工具转交 | 不内置下载解析，可将链接交给 [Seal](https://github.com/JunkFood02/Seal) |

Android 当前最低配置为 **Android 7.0（API 24）**。仓库中的其他 Flutter 平台目录不代表已经提供对应平台的完整功能或发行版；浏览器扩展也不承诺与 Android App 具有相同的平台支持范围。

## 快速开始

### 安装

前往 [GitHub Releases](https://github.com/joopererer/EasySave/releases) 查看发布说明和附件：只有明确标注为 App、并附带 `.apk` 的发布才能安装到手机；没有 APK 时请参考下方源码构建。

**`parser-v*` 发布中的 `parser.js` 和 `manifest.json` 是 App 使用的解析规则，不是安装包。** 顶部解析器版本徽章也不代表 App 版本。

### 使用

1. 打开 EasySave，粘贴受支持的帖子链接，或通过系统分享面板将链接发送到 EasySave。
2. 如内容需要登录，在 App 内完成对应平台的登录；仅保存当前账号有权访问的内容。
3. 预览媒体，选择需要保存的项目，再执行下载。
4. 在历史页查看本地文件、打开原帖或分享内容。
5. 建议在设置中配置备份文件夹；需要快捷操作时，再按需开启悬浮球或添加快捷设置磁贴。

相册、通知、文件夹与悬浮窗权限按功能需要授权。Android 系统与厂商后台管理策略可能影响后台任务，实际行为应以设备验证为准。

## 来源信息、隐私与限制

- **来源随文件保存**：来源信息遵循 [provenance-spec](https://github.com/joopererer/provenance-spec)，使用 [provenance_dart](https://github.com/joopererer/provenance_dart) 读写；详见[元数据说明](spec/metadata.md)。
- **AI 标签不是鉴定结果**：仅展示平台识别或作者声明，不代表 EasySave 对内容真实性作出独立判断。
- **内容凭证保持完整**：C2PA 图片与同名 `.xmp` 边车保存到 `Download/EasySave/`，移动或备份时应一同保留。
- **备份不包含媒体本体**：历史与设置备份不能替代图片和视频备份，恢复后仍需本地文件，或重新访问原帖下载。
- **登录信息不进入业务备份**：不导出账号 Cookie、Authorization 或 WebView 会话；原帖链接、作者及文案可能保留在备份和元数据中，请谨慎分享备份文件。
- **平台限制仍然有效**：不保证获取所有原图、私密内容或受限资源；网站结构、登录要求和链接有效期变化可能影响使用。
- **仅用于合法授权的内容**：请尊重版权、隐私及各平台条款，不用于绕过访问控制或未经授权的再分发。

## 从源码构建

### 环境准备

- Git（包含子模块）。
- Flutter stable，需满足 [`app/pubspec.yaml`](app/pubspec.yaml) 中的 Dart SDK 约束（当前为 `^3.11.5`）。
- Android SDK、JDK 17，以及可用的 Android 设备或模拟器；先运行 `flutter doctor` 检查环境。
- 修改或测试共享解析器时，需要 Node.js 20 与 npm。

### Android App

```bash
git clone --recurse-submodules https://github.com/joopererer/EasySave.git
cd EasySave/app
flutter pub get
flutter run
```

在 `app/` 目录构建 APK：

```bash
flutter build apk --release
```

输出位于 `app/build/app/outputs/flutter-apk/app-release.apk`。当前 release 构建仍使用 debug 签名，适合开发验证；对外分发前应配置并妥善保管正式签名，不应将本地构建视作官方签名发行包。

### 共享解析器与浏览器扩展

在仓库根目录进入 `extension/`：

```bash
cd extension
npm ci
npm test
npm run build
```

`npm run build` 构建浏览器扩展；Android App 使用共享 TypeScript 解析器生成的内置包。修改解析器后可执行 `npm run build:parser`，生成文件可能发生变化，应检查差异。正式解析器发布需要维护者配置签名密钥，普通开发与测试无需执行发布流程。

## 测试与贡献

在 `app/` 目录运行 Flutter 检查：

```bash
flutter analyze
flutter test
```

在 `app/android/` 目录运行原生单元测试：

```bash
./gradlew testDebugUnitTest
```

Windows 使用 `.\gradlew.bat testDebugUnitTest`。共享解析器测试使用上文 `extension/` 下的 `npm test`；自动化测试通过不等于真机验证通过。

欢迎通过 [Issues](https://github.com/joopererer/EasySave/issues) 提交问题或建议，通过 Pull Request 改进项目。反馈时请提供 App / 解析器版本、Android 版本、复现步骤和脱敏日志；不要提交账号 Cookie、登录凭据或未脱敏的私人内容。涉及新平台或较大功能时，建议先讨论范围。

## 项目结构与文档

| 路径 | 内容 |
| --- | --- |
| [`app/`](app/) | Flutter App、Android 原生入口与媒体管理 |
| [`extension/`](extension/) | 共享 TypeScript 解析器、浏览器扩展与构建脚本 |
| [`config/`](config/) | 站点及解析器发布配置 |
| [`spec/`](spec/) | 数据模型、备份格式及元数据集成约定 |
| [`docs/provenance-spec/`](docs/provenance-spec/) | 来源元数据规范子模块 |
| [`docs/tasks/`](docs/tasks/) | 版本任务、交接与验证记录 |

- [更新日志（中英文）](CHANGELOG.md)
- [路线图](docs/roadmap.md)
- [备份格式](spec/backup.md)
- [v1.10 设计与执行记录](docs/tasks/v1.10.md)
- [v1.11 候选方向](docs/tasks/v1.11.md)

## 许可证与致谢

仓库当前尚未提供项目级 `LICENSE`，请勿将源码可见理解为已获某种开源许可证授权；使用、修改或分发前请向维护者确认授权条件。第三方依赖、品牌素材与子模块遵循各自的许可证。

感谢 [Flutter](https://flutter.dev)、[provenance_dart](https://github.com/joopererer/provenance_dart)、[provenance-spec](https://github.com/joopererer/provenance-spec) 及相关依赖项目。YouTube 转交功能使用独立项目 [Seal](https://github.com/JunkFood02/Seal)。README 的语言导航与信息分区参考了 [LocalSend](https://github.com/localsend/localsend) 和 [Obtainium](https://github.com/ImranR98/Obtainium) 的组织方式。
