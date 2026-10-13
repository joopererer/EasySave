# EasySave UI 设计规范（视觉参考：`docs/design/` 原型截图）

> 截图只作为视觉参考，不要求像素级还原。**一切以本文件的修改意见为准。**
> App 名称统一为 **EasySave**（Grabit 为备选，定名前全文暂用 EasySave）。
> 删除所有"原型版本"提示文字。支持深色模式（由以下浅色 token 推导，保持暖色调）。

## 1. 设计 Token（可直接映射到 Flutter `ThemeData`）

色值来自截图像素取样，以此为准。

### 1.1 颜色

| Token | 浅色值 | 深色值（暖色调推导） | 用途 / 映射 |
|---|---|---|---|
| `background` | `#FAF6F1`（暖米色） | `#1A1412` | `scaffoldBackgroundColor` |
| `surface`（卡片） | `#FFFFFF` | `#26201C` | 卡片底；**用柔和阴影，不用边框** |
| `cardShadow` | `Black` 8% + blur 16 + offset (0, 4) | `Black` 40% + blur 16 | 卡片 `BoxShadow` |
| `gradientStart` | `#FC494C` | `#FC494C` | 主按钮渐变起始 |
| `gradientEnd` | `#FA662E` | `#FA662E` | 主按钮渐变结束（`LinearGradient([#FC494C, #FA662E])`，横向） |
| `primary` | `#EA3B48` | `#F26A75` | `colorScheme.primary`；选中边框、勾选、底部导航选中项 |
| `secondaryBgPink` | `#FFDCD7` | `#4A2622` | 次级按钮底、粉色浅底 |
| `secondaryBgBeige` | `#F3E9E1` | `#33291F` | 识别提示条、"原帖"等次要按钮底 |
| `textPrimary` | `#1E130F`（暖黑） | `#F5ECE6` | `colorScheme.onSurface` |
| `textSecondary` | `#A89B92`（暖灰） | `#8D7F76` | `colorScheme.onSurfaceVariant`；作者、时间、副文案 |
| `success` | `#43A047` | `#66BB6A` | 下载完成、已登录 |
| `warning` | `#FB8C00` | `#FFA726` | 部分失败提示 |
| `error` | `#EA3B48` | `#F26A75` | `colorScheme.error`；失败项标红、删除 |
| `platformXhs` | `#EA1C42` 纯色 | 同左 | 小红书标签底色（白字） |
| `platformIg` | `#CE35A8` 纯色 | 同左 | Instagram 标签底色（白字） |
| `overlayScrim` | `Black54` | `Black54` | 全屏查看、下载面板遮罩 |

### 1.2 形状与阴影

| Token | 值 | 映射 |
|---|---|---|
| `radiusCard` | 24 | 大卡片（确认卡片、历史卡片）`BorderRadius.circular(24)` |
| `radiusButton` | 胶囊（`StadiumBorder`） | 主按钮：红→橙渐变底 + 白字 |
| `radiusThumb` | 16 | 预览缩略图 `ClipRRect(borderRadius: 16)` |
| `elevationCard` | 柔和阴影（见 `cardShadow`），无边框 | 所有白色卡片 |
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

8pt 基准：页面边距 16，卡片内边距 16~20（大圆角需要更宽松的内边距），列表项间距 12，网格间距 8。预览网格 `crossAxisCount: 2`。

### 1.5 平台标签样式

白字小胶囊（圆角 8~10，11sp 加粗）：小红书 `#EA1C42` 纯色，Instagram `#CE35A8` 纯色。出现在历史卡片、预览页 AppBar 副标题、下载面板标题旁。

## 2. 逐页布局与组件

### 2.1 首页（Tab 1：解析）

- 顶部：**渐变色头图区**（`gradientStart → gradientEnd`，高度约 180），上面叠一张白色大圆角卡片（`radiusCard` 24 + 柔和阴影，负边距 overlapping 头图底部）。
- 卡片内：输入框（surface 底，圆角 16），**右侧放粘贴图标按钮**（`Icons.paste`）；**去掉独立的"读取剪贴板"按钮**。
- **剪贴板自动检测**：打开 App（`initState` + `AppLifecycleState.resumed`）时读剪贴板，若含支持链接则弹出**确认卡片**（对话框样式：链接 + 平台标签 + [解析] [取消]）。
- **解析中状态**：输入框下方或全屏小卡片显示 `CircularProgressIndicator` + "解析中…" + **[取消]按钮**（取消 headless WebView 解析任务）。
- **解析失败状态**：红色错误卡片，按 §4 错误码显示文案和操作按钮（如 LOGIN_REQUIRED → [去登录]）；卡片上带**诊断按钮**（复制诊断信息，预览页 AppBar 不再放）。
- 下半部分：**最近 3 条历史**（缩略图 + 标题 + 平台标签 + 时间），点击进预览页，尾部"查看全部 →"跳历史页。

### 2.2 预览页

- AppBar：作者名 + 平台标签；**无诊断按钮**（诊断入口只在错误卡片上）。
- 标题下方：**可折叠文案区**（`ExpansionTile`：标题 + 正文，默认折叠）+ **"复制文案"按钮**（复制"标题 + 正文"拼接文本）。
- 网格：**2 列**缩略图，圆角 16；**视频显示右下角标（▶ + 时长 `mm:ss`，时长取自 item.duration，取不到只显示 ▶）**；**Live 图显示 "Live" 标识**（左上角小胶囊）。
- 交互：**选中项主色描边 + 右上角圆形勾选 + 左下角"1/3"序号**（序号 = 选中顺序）；**点勾选框切换选择，点图片本身全屏查看**（`PhotoView`/`InteractiveViewer`，左右滑动切换，视频点播）。
- 底部：全选/反选 + [保存到相册] 主按钮（红→橙渐变胶囊，白字）。

### 2.3 下载面板（Modal Bottom Sheet）

- 条目命名：**图片 1、图片 2… / 视频 / Live 1、Live 2…**（按类型独立计数）。
- 每行：缩略图 + 名称 + 状态（等待/下载中百分比/完成✓/失败标红）。
- 底部按钮：**[后台下载]**（原"稍后继续"改名，切后台不中断，v1.1b）+ **[取消]按钮**（原垃圾桶图标改为文字按钮，取消未完成任务）。
- **完成状态**：顶部"全部完成 ✓" + [打开相册] [分享] [完成]（[打开相册] 用 `Gal.open()` 实现，已核实 gal 2.3.3 提供该 API；分享为 v1.2 功能，先置灰或隐藏）。
- **部分失败状态**：顶部 warning 色"X 项失败"，**失败行标红 + 单独 [重试] 按钮**；单个文件失败不导致整批报错。

### 2.4 历史页（Tab 2：历史）

- 顶部：**按平台筛选**（全部 / 小红书 / Instagram，`SegmentedButton` 或 Chip 组）。
- 列表：**按日期分组**（"今天 / 昨天 / 2026-10-12" sticky header），卡片 = 缩略图 + 标题 + 作者 + 平台标签 + 文件数 + 时间（白色 24 圆角卡片 + 柔和阴影）。
- 点击卡片 → 打开预览页（用缓存的解析结果，无需重新解析）。
- 左滑/长按删除 → Snackbar **"已删除，可撤销 [撤销]"**，并注明"仅删除记录，不删除相册文件"。
- **空状态**：插图占位 + "还没有下载记录，去首页解析第一条帖子吧" + [去解析] 按钮。

### 2.5 我的页（Tab 3：我的）

分三组（`ListView` + 分组头）：

1. **账号**：平台行（小红书 / Instagram）显示登录状态（已登录 + 昵称 / 未登录）；[退出登录]（二次确认）；**登录过期提示**（解析报 LOGIN_REQUIRED 时对应行显示 warning 色"登录已过期，请重新登录"）。
2. **下载设置**：相册名称、文件名格式、同时保存文案为 txt、自动检测剪贴板开关（roadmap v1.1a）。
3. **其他**：清除缓存、版本号、（可选）意见反馈、开源许可。

## 3. 全局状态清单

| 页面 | 加载中 | 空 | 错误 |
|---|---|---|---|
| 首页 | 解析中（进度 + 取消） | 暂无历史（"粘贴链接开始第一次保存"） | 见 §4，按错误码给文案 + 按钮 |
| 预览页 | 骨架缩略图（`Shimmer` 或灰色占位） | 帖子无媒体（"该帖子没有可保存的图片/视频"） | 同上 |
| 下载面板 | 每行进度条 | —（有任务才打开） | 部分失败（失败行标红 + 重试） |
| 历史页 | DB 读取中（转圈） | 空状态（插图 + 引导 + 去解析） | DB 读取失败（[重试]） |
| 我的页 | 登录状态检查中（行内小转圈） | — | 登录过期（warning 行内提示） |

## 4. 错误码 → 文案与操作

与 `spec/parsing.md` 错误模型对应（已补 `TIMEOUT`）。

| 错误码 | 用户文案 | 操作按钮 |
|---|---|---|
| `LOGIN_REQUIRED` | "需要先登录小红书/Instagram" | [去登录]（跳对应平台登录页） |
| `PRIVATE_OR_UNAVAILABLE` | "该帖子不存在、私密或已删除" | [返回首页] |
| `BLOCKED` | "请求被对方限制，请稍后再试" | [重试] |
| `INVALID_PAGE` | "页面内容无法识别，可能已改版" | [重试] [复制诊断信息] |
| `UNSUPPORTED_URL` | "不支持的链接，请粘贴小红书/Instagram 帖子链接" | [重新粘贴] |
| `TIMEOUT`（解析/下载超时） | "网络超时，请检查网络后重试" | [重试] |
| 单文件下载失败 | "第 X 项下载失败"（行内标红） | [单独重试]；不弹整批报错 |

诊断信息内容（roadmap v1.1a）：平台、错误码、链接、App 版本；**严禁包含 cookie 或任何账号信息**。
