# EasySave 图标素材（方案 C）

所有素材都是最终文件，**请直接复制使用，不要重新绘制或修改路径数据**。效果见 `preview.png`。

## 目录

| 路径 | 用途 |
|---|---|
| `android/res/mipmap-anydpi-v26/ic_launcher.xml`、`ic_launcher_round.xml` | Android 8+ 自适应图标（含 Android 13 主题图标 monochrome 层） |
| `android/res/drawable/ic_launcher_background.xml` | 自适应图标背景：渐变 #FC494C → #FA662E |
| `android/res/drawable/ic_launcher_foreground.xml` | 自适应图标前景：白色圆 + 镂空下载箭头 |
| `android/res/drawable/ic_launcher_monochrome.xml` | 主题图标层（系统自动着色） |
| `android/res/mipmap-{mdpi…xxxhdpi}/ic_launcher*.png` | Android 7 及以下的位图图标 |
| `android/res/drawable/ic_stat_easysave.xml` | **所有通知**的小图标（白色剪影） |
| `android/res/drawable/ic_qs_easysave.xml` | 快捷开关（Tile）图标 |
| `android/res/drawable/bg_bubble.xml` + `ic_bubble_arrow.xml` | 悬浮球：渐变圆背景 + 白色箭头 |
| `png/play-store-512.png` | 应用商店图标（满版方形，商店自己加圆角） |
| `png/easysave-icon-1024.png` | 文档、README、宣传用 |
| `svg/` | 所有图形的矢量源文件 |

## 安装步骤

1. 把 `android/res/` 下的所有文件复制到 `app/android/app/src/main/res/` 的同名目录，**覆盖**已有的 `ic_launcher*` 文件。
2. 删除 Flutter 默认图标残留：res 下其他名字的 launcher 图标（如 `launcher_icon.png`），以及 `mipmap-anydpi-v26` 中旧的 xml（如果和上面重名，就是被覆盖）。
3. `AndroidManifest.xml`：`<application>` 中确认
   `android:icon="@mipmap/ic_launcher"`、`android:roundIcon="@mipmap/ic_launcher_round"`。
4. 通知小图标：所有 `NotificationCompat.Builder` 的 `setSmallIcon(R.drawable.ic_stat_easysave)`，包括 HostService 前台服务通知、下载进度、完成、错误通知。
   background_downloader 自己发的下载通知也要改用这个图标：查它的文档，确认如何指定小图标（覆盖它默认的 drawable 资源名，或通过配置项），不要猜。
5. Tile：`EasySaveTileService` 用 `Icon.createWithResource(this, R.drawable.ic_qs_easysave)`，manifest 中 `android:icon="@drawable/ic_qs_easysave"`。
6. 悬浮球：背景用 `@drawable/bg_bubble`，中间放 `@drawable/ic_bubble_arrow`（约占直径 62%）；闲置时整体 alpha 0.8。
7. **不要**使用 flutter_launcher_icons 重新生成，它会覆盖这里的 xml。若 pubspec 里有它的配置，删掉配置和依赖。

## 验证

- `flutter clean` 后重新安装（启动器会缓存旧图标；必要时卸载重装）。
- 截图：桌面图标、通知栏（下拉状态和状态栏小图标）、Android 13+ 设备开启"主题图标"后的效果。
