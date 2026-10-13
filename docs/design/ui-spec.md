# EasySave UI 设计规范（视觉参考：`docs/design/` 原型截图）

> 截图只作为视觉参考，不要求像素级还原。**一切以本文件的修改意见为准。**
> App 名称统一为 **EasySave**。删除所有"原型版本"提示文字。支持深色模式。

## 1. 设计 Token（可直接映射到 Flutter `ThemeData`）

### 1.1 颜色

| Token | 浅色值 | 深色值 | 用途 / 映射 |
|---|---|---|---|
| `primary` | `#E53935`（Red 600） | `#EF5350`（Red 400） | `colorScheme.primary`；主按钮、选中态、进度条 |
| `primaryContainer` | `#FFEBEE` | `#4A1412` | 选中卡片底色、badge 底 |
| `background` | `#FFFFFF` | `#121212` | `scaffoldBackgroundColor` |
| `surface` | `#F5F5F5` | `#1E1E1E` | 卡片、输入框底（`colorScheme.surfaceContainerHighest` 近似） |
| `outline` | `#E0E0E0` | `#3A3A3A` | 卡片边框、分割线（`colorScheme.outlineVariant`） |
| `textPrimary` | `#212121` | `#F5F5F5` | `colorScheme.onSurface` |
| `textSecondary` | `#757575` | `#B0B0B0` | `colorScheme.onSurfaceVariant`；作者、时间、副文案 |
| `success` | `#43A047` | `#66BB6A` | 下载完成、已登录 |
| `warning` | `#FB8C00` | `#FFA726` | 部分失败提示 |
| `error` | `#E53935` | `#EF5350` | `colorScheme.error`；失败项标红、删除 |
| `platformXhs` | `#FF2D55` | `#FF2D55` | 小红书标签底色（白字） |
| `platformIg` | `#7B61FF` 紫 → `#E1306C` 粉 | 同左 | Instagram 标签底色（白字，渐变 `LinearGradient([#7B61FF, #E1306C])`） |
| `overlayScrim` | `Black54` | `Black54` | 全屏查看、下载面板遮罩 |

渐变只用在两处：Instagram 平台标签，以及首页主按钮（可选 `LinearGradient([#FF2D55, #E1306C])`，深色模式降饱和 10%）。

### 1.2 形状与阴影

| Token | 值 | 映射 |
|---|---|---|
| `radiusCard` | 12 | `Card.shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))` |
| `radiusButton` | 24（胶囊） | 主按钮 `StadiumBorder` 或 `BorderRadius.circular(24)` |
| `radiusThumb` | 8 | 预览缩略图、历史缩略图 `ClipRRect(borderRadius: 8)` |
| `elevationCard` | 0（扁平，用 1px `outline` 边框代替阴影） | 历史卡片、确认卡片 |
| `elevationSheet` | 16 + `Black26` scrim | 下载面板（`showModalBottomSheet`） |

### 1.3 字号层级（Material 3 TypeScale 映射）

| Token | 字号/字重 | 映射 | 用途 |
|---|---|---|---|
| `titleLarge` | 20 / w600 | `textTheme.titleLarge` | AppBar 标题（作者名/帖子标题） |
| `titleMedium` | 16 / w600 | `textTheme.titleMedium` | 卡片标题、面板标题 |
| `bodyMedium` | 14 / w400 | `textTheme.bodyMedium` | 正文、文案区 |
| `bodySmall` | 12 / w400 | `textTheme.bodySmall` | 作者、时间、副文案 |
| `labelSmall` | 11 / w600 | `textTheme.labelSmall` | 平台标签、角标（视频时长、Live） |

### 1.4 间距

8pt 基准：页面边距 16，卡片内边距 12，列表项间距 8，网格间距 8。预览网格 `crossAxisCount: 3`。

### 1.5 平台标签样式

圆角 4 的小胶囊，11sp 白字加粗：小红书纯色 `#FF2D55`，Instagram 紫粉渐变。出现在历史卡片、预览页 AppBar 副标题、下载面板标题旁。

## 2. 逐页布局与组件

### 2.1 首页（Tab 1：首页）

- 顶部：App 名称 EasySave + 副标题（slogan）。
- 输入框：圆角 12 的 surface 底输入框，**右侧放粘贴图标按钮**（`Icons.paste`），占满剩余宽度即为主操作；**去掉独立的"读取剪贴板"按钮**。
- **剪贴板自动检测**：打开 App（`initState` + `AppLifecycleState.resumed`）时读剪贴板，若含支持链接则弹出**确认卡片**（对话框样式：链接 + 平台标签 + [解析] [取消]）。
- **解析中状态**：输入框下方或全屏小卡片显示 `CircularProgressIndicator` + "解析中…" + **[取消]按钮**（取消 headless WebView 解析任务）。
- **解析失败状态**：红色错误卡片，按 §4 错误码显示文案和操作按钮（如 LOGIN_REQUIRED → [去登录]）。
- 下半部分：**最近 3 条历史**（缩略图 + 标题 + 平台标签 + 时间），点击进预览页，尾部"查看全部 →"跳历史页。

### 2.2 预览页

- AppBar：作者名 + 平台标签；右侧 🐞 诊断按钮保留（仅解析失败/调试时需要，见 roadmap v1.1 诊断信息）。
- 标题下方：**可折叠文案区**（`ExpansionTile`：标题 + 正文，默认折叠）+ **"复制文案"按钮**（复制"标题 + 正文"拼接文本）。
- 网格：3 列缩略图；**视频显示右下角标（▶ + 时长 `mm:ss`）**；**Live 图显示 "Live" 标识**（左上角小胶囊）。
- 交互：**点勾选框切换选择**（右上角圆形复选框，选中态 primary 底）；**点图片本身全屏查看**（`PhotoView`/`InteractiveViewer`，左右滑动切换，视频点播）。
- 底部：全选/反选 + [保存到相册] 主按钮（胶囊，primary 底白字）。

### 2.3 下载面板（Modal Bottom Sheet）

- 条目命名：**图片 1、图片 2… / 视频 / Live 1、Live 2…**（按类型独立计数）。
- 每行：缩略图 + 名称 + 状态（等待/下载中百分比/完成✓/失败标红）。
- 底部按钮：**[后台下载]**（原"稍后继续"改名，切后台不中断，见 roadmap v1.1）+ **[取消]按钮**（原垃圾桶图标改为文字按钮，取消未完成任务）。
- **完成状态**：顶部"全部完成 ✓" + [打开相册] [分享] [完成] 三个按钮（分享为 v1.2 功能，先置灰或隐藏，见 roadmap）。
- **部分失败状态**：顶部 warning 色"X 项失败"，**失败行标红 + 单独 [重试] 按钮**；单个文件失败不导致整批报错。

### 2.4 历史页（Tab 2：历史）

- 顶部：**按平台筛选**（全部 / 小红书 / Instagram，`SegmentedButton` 或 Chip 组）。
- 列表：**按日期分组**（"今天 / 昨天 / 2026-10-12" sticky header），卡片 = 缩略图 + 标题 + 作者 + 平台标签 + 文件数 + 时间。
- 点击卡片 → 打开预览页（用缓存的解析结果，无需重新解析）。
- 左滑/长按删除 → Snackbar **"已删除，可撤销 [撤销]"**，并注明"仅删除记录，不删除相册文件"。
- **空状态**：插图占位 + "还没有下载记录，去首页解析第一条帖子吧" + [去首页] 按钮。

### 2.5 我的页（Tab 3：我的，原第三个 Tab 更名）

分三组（`ListView` + 分组头）：

1. **账号**：平台行（小红书 / Instagram）显示登录状态（已登录 + 昵称 / 未登录）；[退出登录]（二次确认）；**登录过期提示**（解析报 LOGIN_REQUIRED 时对应行显示 warning 色"登录已过期，请重新登录"）。
2. **下载设置**：相册名称、文件名格式、同时保存文案为 txt、自动检测剪贴板开关（roadmap v1.1）。
3. **其他**：清除缓存、版本号、（可选）意见反馈、开源许可。

## 3. 全局状态清单

| 页面 | 加载中 | 空 | 错误 |
|---|---|---|---|
| 首页 | 解析中（进度 + 取消） | 暂无历史（"粘贴链接开始第一次保存"） | 见 §4，按错误码给文案 + 按钮 |
| 预览页 | 骨架缩略图（`Shimmer` 或灰色占位） | 帖子无媒体（"该帖子没有可保存的图片/视频"） | 同上 |
| 下载面板 | 每行进度条 | —（有任务才打开） | 部分失败（失败行标红 + 重试） |
| 历史页 | DB 读取中（转圈） | 空状态（插图 + 引导 + 去首页） | DB 读取失败（[重试]） |
| 我的页 | 登录状态检查中（行内小转圈） | — | 登录过期（warning 行内提示） |

## 4. 错误码 → 文案与操作

| 错误码（现状 `ParseErrorCode`） | 用户文案 | 操作按钮 |
|---|---|---|
| `LOGIN_REQUIRED` | "对方要求登录后查看" | [去登录]（跳对应平台登录页） |
| `PRIVATE_OR_UNAVAILABLE` | "该帖子不存在、私密或已删除" | [返回首页] |
| `BLOCKED` | "请求被对方限制，请稍后再试" | [重试] |
| `INVALID_PAGE` | "页面内容无法识别，可能已改版" | [重试] [复制诊断信息] |
| `UNSUPPORTED_URL` | "不支持的链接，请粘贴小红书/Instagram 帖子链接" | [重新粘贴] |
| `TIMEOUT`（解析/下载超时） | "网络超时，请检查网络后重试" | [重试] |
| 单文件下载失败 | "第 X 项下载失败"（行内标红） | [单独重试]；不弹整批报错 |

诊断信息内容（roadmap v1.1）：平台、错误码、链接、App 版本；**严禁包含 cookie 或任何账号信息**。
