# EasySave 备份与恢复规范 (Backup & Restore Specification)

本文档定义 EasySave v1.8 备份与恢复的架构、文件格式（`easysave-backup.json`）、导入导出规则与恢复流程。

---

## 1. 目标与设计原则

### 1.1 核心目标
当用户遇到以下场景时，能够完整恢复下载历史与非敏感个性化配置，且无需重新下载图片/视频：
1. **卸载重装**：清除应用后重新安装。
2. **更换手机**：在新设备上导入备份文件，或通过 Android 系统云备份/数据迁移自动恢复。
3. **清除应用数据**：在系统设置中误操作或排查问题清除了应用数据。

### 1.2 三层备份架构
| 层次 | 机制 | 触发时机 | 存储位置 | 用户交互 |
|---|---|---|---|---|
| **第 1 层**<br>单文件导入导出 | 纯 Dart JSON 导出与恢复 | 用户手动点击"立即备份"或"从备份恢复" | 用户选取的任意文件路径（通过系统 SAF 选择器） | 选择文件 → 预览摘要（帖子数/文件数/时间/设置开关）→ 确认合并 |
| **第 2 层**<br>Android 自动备份 | 系统 Auto Backup (GMS / OS 云同步与换机迁移) | 每批下载完成（限制最多每小时 1 次）及每天首次启动 | App 私有目录 `files/backup/easysave-backup.json`（由 `getApplicationSupportDirectory()` 获取） | 零交互，系统根据网络与充电状态在后台静默同步 |
| **第 3 层**<br>文件夹自动备份 | 外部文件夹周期性自动归档（SAF 持久化目录授权） | 与第 2 层相同：每批下载完成（最多每小时 1 次）及每天首次启动，或用户手动点击 | 用户授权的文件夹（建议 `Documents/EasySave Backup/`） | 按文件名时间戳轮转保留最近 7 份 `easysave-backup-YYYYMMDD-HHmm.json`，支持权限失效重新引导 |

---

## 2. 备份数据格式 (`easysave-backup.json`)

备份文件采用单个 UTF-8 编码的 JSON 文件，便于跨平台解析、离线校验和版本兼容。

### 2.1 顶层结构

```json
{
  "format": "easysave-backup",
  "formatVersion": 1,
  "exportedAt": "2026-10-22T20:30:00+08:00",
  "appVersion": "1.8.0",
  "provenanceSpecVersion": "0.1.3",
  "settings": { ... },
  "posts": [ ... ]
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `format` | String | 是 | 固定常量 `"easysave-backup"`，用于文件类型识别 |
| `formatVersion` | Integer | 是 | 整数版本号，当前版本为 `1`。遇到 `formatVersion > 1` 时拒绝导入并提示升级 App |
| `exportedAt` | String | 是 | 导出时间戳，必须遵循 ISO 8601 并附带时区偏移（例如 `+08:00`） |
| `appVersion` | String | 是 | 导出时 EasySave App 版本（当前为 `"1.8.0"`） |
| `provenanceSpecVersion` | String | 是 | 来源元数据规范版本（当前为 `"0.1.3"`），与 `metadata` 模块共用常量，禁止硬编码多份 |
| `settings` | Object | 是 | 非敏感设置项键值对（见 §2.4） |
| `posts` | Array | 是 | 历史帖子与媒体文件列表（见 §2.2 & §2.3） |

---

### 2.2 帖子结构 (`posts[]`)

每个元素代表一条下载历史记录（**仅包含未删除记录，软删除记录不导出**）：

```json
{
  "platform": "xiaohongshu",
  "sourceId": "670f1a2b000000001e028b12",
  "originalUrl": "https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12?xsec_token=AB1234...",
  "title": "巴黎周末漫步",
  "authorName": "旅行家小张",
  "caption": "塞纳河畔的秋天...",
  "createdAt": "2026-10-20T14:22:10+08:00",
  "items": [
    {
      "type": "image",
      "url": "https://sns-img-qc.xhscdn.com/..."
    }
  ],
  "files": [ ... ]
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `platform` | String | 是 | 规范平台标识符：`"xiaohongshu"`、`"instagram"`、`"x"`（导出时由内部标识 `xhs` 等转为规范名称，导入时转回内部标识，复用 metadata 模块的映射表） |
| `sourceId` | String | 是 | 平台原生内容 ID（笔记 ID / 推文 ID / Reel 简码等） |
| `originalUrl` | String | 是 | 原始帖子链接（保留用于重新解析与离线还原） |
| `title` | String? | 否 | 标题（可为空） |
| `authorName` | String? | 否 | 作者昵称（可为空） |
| `caption` | String? | 否 | 正文/文案（可为空） |
| `createdAt` | String | 是 | 本条历史在 App 中首次保存的时间戳（ISO 8601） |
| `items` | Array? | 否 | 结构化解析项数组（**不采用 JSON 字符串嵌套**），用于离线恢复预览页完整卡片数据 |
| `files` | Array | 是 | 该帖子关联的文件列表（见 §2.3） |

---

### 2.3 文件结构 (`files[]`)

每个元素代表该帖子下载保存的具体相册媒体文件：

```json
{
  "filename": "xhs_670f1a2b000000001e028b12_1.jpg",
  "relativePath": "Pictures/EasySave/",
  "savedAt": "2026-10-20T14:22:15+08:00",
  "mediaType": "image",
  "mediaId": "100234",
  "itemIndex": 1,
  "assetId": "550e8400-e29b-41d4-a716-446655440000",
  "provenance": {
    "schema": "0.1",
    "assetId": "550e8400-e29b-41d4-a716-446655440000",
    "capturedAt": "2026-10-20T14:22:12+08:00",
    "capturedBy": "EasySave/1.8.0",
    "metadataDate": "2026-10-20T14:22:12+08:00",
    "source": {
      "url": "https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12",
      "platform": "xiaohongshu",
      "id": "670f1a2b000000001e028b12",
      "itemIndex": 1,
      "itemCount": 3
    },
    "title": "巴黎周末漫步",
    "creator": ["旅行家小张"]
  }
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `filename` | String | 是 | 相册中的实际文件名（包含扩展名，如 `xhs_..._1.jpg`） |
| `relativePath` | String? | 否 | Android MediaStore `RELATIVE_PATH`（如 `"Pictures/EasySave/"` 或 `"Movies/EasySave/"`，旧记录在定位前可为空） |
| `savedAt` | String | 是 | 保存落盘时间戳（ISO 8601 带时区） |
| `mediaType` | String | 是 | 媒体类型：`"image"`、`"video"`、`"gif"` |
| `mediaId` | String? | 否 | 原设备 MediaStore ID（跨设备恢复时可能失效，用于本设备快速定位） |
| `itemIndex` | Integer | 是 | 在原帖媒体列表中的 1-based 位置序号 |
| `assetId` | String? | 否 | 来源元数据资产唯一标识符（UUID v4） |
| `provenance` | Object? | 否 | 符合 [Provenance Spec v0.1 §7](../docs/provenance-spec/SPEC.md#7-json-representation) 标准的完整元数据对象 |

#### Live 图（实况照片）的表示方式：
与 `HistoryFile` 现有结构保持一致，Live 图包含图片与视频两个文件，它们通过**相同的 `itemIndex`** 关联配对：
- **静态封面**：`mediaType: "image"`，`itemIndex: i`（对应 `HistoryFile.isImage = true`）；
- **动态视频**：`mediaType: "video"`，`itemIndex: i`（对应 `HistoryFile.isImage = false`）；
- 两者共享相同的 `itemIndex`，并对应 `items[]` 中 `type: "live"` 的同一个媒体项。导入时依据 `(itemIndex, isImage)` 正确配对恢复至数据库。

---

### 2.4 设置项结构 (`settings`)

仅允许备份**用户个性化配置与非敏感首选项**：

```json
{
  "albumName": "EasySave",
  "usedAlbumNames": ["EasySave", "EasySaveBackup", "MyPhotos"],
  "namePattern": "{id}_{seq}",
  "saveProvenanceInImages": true,
  "bubbleEnabled": true,
  "bubbleAutoHide": true,
  "backgroundToast": true,
  "autoClipboard": true,
  "saveCaptionTxt": false,
  "historyView": "posts",
  "historyLayout": "waterfall",
  "historySort": "latest"
}
```

#### 包含字段（白名单）：
- `albumName`: 当前相册名称（String）
- `usedAlbumNames`: 历史用过的相册名称列表（List<String>，必须反序列化为可变 List，不得为 const）
- `namePattern`: 自定义文件名格式模板（String）
- `saveProvenanceInImages`: 在图片中嵌入来源元数据开关（Boolean）
- `bubbleEnabled`: 悬浮球开关（Boolean，恢复时需遵循权限约束，见 §5.2）
- `bubbleAutoHide`: 悬浮球闲置时贴边隐藏（Boolean）
- `backgroundToast`: 后台下载完成轻提示（Boolean）
- `autoClipboard`: 自动检测剪贴板（Boolean）
- `saveCaptionTxt`: 保存文案为 txt 开关（Boolean）
- `historyView` / `historyLayout` / `historySort`: 历史页视图与排序偏好

#### 严格排除字段（黑名单与隐私边界）：
- **绝对不备份的设置项**：`backupTreeUri`（设备特定的文件夹 URI）、`lastBackupTime`（上次备份时间）、`skipRestoreHint`（首次启动或历史为空恢复引导的跳过标记）。
- **严禁包含**：Cookie、Authorization Header、Token、WebView 登录状态、Session 数据、解析器本地缓存、崩溃日志、调试日志。
- **唯一特例**：原帖分享链接 `originalUrl` 中由平台分享面板生成的查询参数（如小红书 `xsec_token`）允许保留在链接字符串内部，用于后续重新解析；**绝不允许作为独立键值出现**。
- **敏感信息检查规范**：
  - **仅检查 JSON 对象的键名（Keys）**，不检查值（Values），因为标题、文案等内容中可能自然出现 "token"、"session" 等词汇；
  - **此检查仅在单元测试中断言**，用于防泄露安全审计；**运行时不拦截导出**，保证性能与导出可靠性。

---

## 3. 导入与合并算法 (Import & Reconciliation)

数据恢复采用增量合并（Reconciliation）机制，保证幂等性与一致性。

### 3.1 事务一致性与范围
- **导出**：在 `HistoryDb` 的单个只读事务内完成，**只导出未删除记录（`where: is_deleted = 0`），绝不导出软删除记录**。
  - *原因*：若导出软删除记录，恢复时配合 `restoreDeleted: true` 规则，会导致用户此前在历史中主动删除的记录在每次恢复时全部复活。
- **导入**：在一个读写事务内执行全部合并与写入操作。若中途发生异常，整个事务回滚，维持本地历史库的原子性。

### 3.2 实体合并规则
1. **平台标识转换**：
   - 导出时：App 内部标识（如 `xhs`）通过 `toSpecPlatform()` 转换为规范平台名称（`xiaohongshu`、`instagram`、`x`）；
   - 导入时：规范平台名称转换回 App 内部标识（`xiaohongshu` -> `xhs`），确保历史库内部平台命名完全一致。
2. **帖子级去重与合并**：
   - 匹配键：优先按 `(platform, sourceId)`，次选 `postUrl`；
   - 若本地已存在该帖子：
     - 合并两者的媒体文件列表；
     - 更新 `fileCount` 为合并后的实际文件数；
     - 标题、正文、作者优先保留非空值；
     - 如果已有记录与备份记录产生冲突，捕获字段以相册文件现存的 XMP 元数据为准；
   - 若本地不存在：直接插入新记录。
3. **文件级合并**：
   - 匹配键：优先使用 `assetId`（UUID v4）；若无 `assetId`，按 `itemIndex + mediaType` 匹配；
   - 重复导入相同文件不会生成多余记录。
4. **主动恢复语义 (`restoreDeleted: true`)**：
   - 用户主动从备份恢复属于明确的用户意图；
   - 写入记录时调用 `HistoryDb.upsert(record, restoreDeleted: true)`；
   - 场景：该记录在**备份导出时为有效状态**，但在导出后被用户在本地误删（`isDeleted = 1`），再从该备份恢复时，该记录将被重新还原为可见状态（`isDeleted = 0`）。
5. **设置项恢复策略**：
   - **历史为空时**：默认勾选"同时恢复设置"；
   - **历史不为空时**：默认不恢复设置，恢复预览面板提供"同时恢复设置"复选框供用户按需决定；
   - **`usedAlbumNames` 处理**：采用**并集合并（Union）**，将备份中的相册名追加至当前列表，不覆盖已有相册名；
   - **排除字段**：`backupTreeUri`、`lastBackupTime`、`skipRestoreHint` 坚决不被恢复覆盖。

### 3.3 版本兼容性与错误处理
- **高版本文件保护**：
  若备份文件中的 `formatVersion > 1`，解析器立即中断，抛出 `IncompatibleBackupVersionException`，UI 弹出友好的提示对话框："此备份由更新版本的 EasySave 创建，请先前往更新应用后再恢复"，严禁强行解析导致崩溃或数据错乱。
- **低版本与缺损容错**：
  若备份文件来自低版本或缺少非关键字段（如缺少 `relativePath`、缺少 `provenance` 对象、缺少某项设置、或 `items` 仍为旧版 `itemsJson` 字符串），赋予合理默认值，确保平滑导入。

---

## 4. 存储与多层自动化策略

### 4.1 第 2 层：Android 自动备份 (Auto Backup)
利用 Android 系统原生 Backup Agent 实现换机与云端同步：
1. **私有快照写入**：
   - 路径：由 `(await getApplicationSupportDirectory()).path/backup/easysave-backup.json` 定位（Android 上即为 `context.filesDir/backup/easysave-backup.json`，禁止使用 `../` 脆弱拼接）。
   - 触发时机：
     - 每批下载完成时（设置防抖限频：距上次备份至少间隔 1 小时）；
     - 每天首次冷启动 App 时。
2. **系统备份规则配置**：
   - Android 12+ (API 31+): `res/xml/data_extraction_rules.xml`
     - `<cloud-backup>`: 包含 `backup/easysave-backup.json`，排除 `databases/`、`shared_prefs/`、`cache/`、`code_cache/`、`app_webview/` 等。
     - `<device-transfer>`: 同样仅包含此备份文件。
   - Android 11 及以下: `res/xml/backup_rules.xml`
     - `<full-backup-content>`: 仅包含 `backup/easysave-backup.json`。
3. **ADB 命令行真机验证指南**：
   ```bash
   # 1. 启用备份管理器
   adb shell bmgr enable true
   # 2. 查看当前 Transport
   adb shell bmgr list transports
   # 3. 强制立即执行 EasySave 备份
   adb shell bmgr backupnow com.james.easysave
   # 4. 查看备份日志
   adb logcat -s BackupManagerService PFTBT
   ```

### 4.2 第 3 层：用户自选目录自动备份 (SAF 归档)
1. **入口路径**：「我的 → 设置 → 备份与恢复」。
2. **自动备份触发时机**：与第 2 层完全一致（每批下载完成且间隔满 1 小时，以及每天首次冷启动）。
3. **目录授权与持久化**：
   - 调用系统 `ACTION_OPEN_DOCUMENT_TREE` 让用户选取保存目录；
   - 建议默认位置：`Documents/EasySave Backup`；
   - 成功选取后调用 `takePersistableUriPermission` 保持重启后 URI 权限有效。
4. **文件命名与轮转清理策略**：
   - 文件命名规则：`easysave-backup-YYYYMMDD-HHmm.json`；
   - 轮转清理：遍历目标目录下的 `easysave-backup-*.json`，**根据文件名中的时间戳 `YYYYMMDD-HHmm` 降序排列**（不依赖文件修改时间），严格**保留最近 7 份**，更旧的文件通过 DocumentFile API 自动删除。
5. **权限失效恢复与交互**：
   - 参考 Mihon (Tachiyomi) 交互体验：清晰卡片展示"备份目录"、"备份时机"、"上次备份时间"与"立即备份"操作；
   - 若系统权限被用户撤销或重装后失效，检测到 `SecurityException` 或 `canWrite() == false` 时，明确展示警告状态与重新选择按钮，严禁静默忽略。

### 4.3 空历史保护机制 (Empty History Protection)
为防止历史数据丢失或覆盖已有备份，实施以下严格防护：
1. **自动备份静默跳过**：当本地历史记录为空时，**第 2 层（Android 自动备份）与第 3 层（自选文件夹自动备份）的所有自动备份任务均不执行**。
   - *防护场景*：设备刚换机、刚重装、或误清空数据后，避免系统触发冷启动自动备份生成空 JSON，从而覆盖掉 Android 系统刚从云端恢复回来的有内容私有备份，或轮转清理掉外部文件夹中有内容的历史备份。
2. **手动备份二次确认**：当用户在设置页手动点击"立即备份"时，若检测到历史记录为空，必须弹窗确认："当前没有任何记录，确定要导出空备份吗？"，用户确认后方可导出。
3. **冷启动流程顺序保障**：App 启动生命周期中，**首次启动的"发现私有备份"检查与提示必须在冷启动自动备份之前完成**，确保不会因自动备份机制介入影响恢复判断。

---

## 5. 恢复体验与联动

### 5.1 恢复触发流程
1. **首次启动或历史为空智能引导**：
   - 当历史记录为空时，首先检查私有目录中是否存在 `files/backup/easysave-backup.json`（可能是系统自动恢复回来的）：
     - **存在**：直接弹出对话框："发现 <备份时间> 的备份（N 条记录），是否恢复？" [确认恢复] [跳过]；
     - **不存在**：展示三选一引导卡片：
       - `[从备份文件恢复]`（调起系统文件选择器）
       - `[从相册重建]`（扫描相册）
       - `[跳过]`
     - **跳过逻辑**：点击"跳过"后，本地记录 `settings.skipRestoreHint = true`，后续冷启动不再自动弹出引导（该字段明确不参与备份）。
2. **设置页手动恢复**：
   - 点击「从备份恢复」→ 唤起 `ACTION_OPEN_DOCUMENT`（类型 `application/json`）；
   - 选中文件后先读取元数据进行**恢复预览**：展示"备份时间"、"应用版本"、"包含帖子 N 条"、"文件 M 个"以及"同时恢复设置"选项（历史为空时默认勾选，历史不为空时默认不勾选）；
   - 用户点击"确认恢复"后执行导入，完成后弹出恢复摘要 SnackBar。
3. **后置自动联动相册重建**：
   - 备份恢复写入数据库后，**立即自动触发一次 `HistoryRebuildService.rebuild()`**；
   - 作用：
     1. 补上备份文件生成之后、用户在相册中新下载的文件；
     2. 扫描本地相册重新定位 `mediaId`，确保历史卡片本地缩略图与全屏浏览立即正常可用。

### 5.2 恢复安全性防护
1. **悬浮球权限安全保护**：
   - 若恢复设置中 `bubbleEnabled: true`，恢复时不自动弹窗强行申请 `SYSTEM_ALERT_WINDOW`（避免流氓权限打扰）；
   - 检查 `Settings.canDrawOverlays(context)`：
     - 若当前已有权限，则恢复开启；
     - 若无权限，则开关保持关闭（`false`），并在恢复结果中明确提示："悬浮球需重新授权后开启"。
2. **不可修改集合陷阱防护**：
   - 设置中的列表字段（如 `usedAlbumNames`）在从 JSON 反序列化时，必须使用可修改 List（如 `List<String>.from(...)`），严禁使用 `const []` 或不可修改集合，避免后续 `rememberAlbum` 抛出运行时异常。

---

## 6. 相册文件定位与 `relativePath`

### 6.1 `HistoryFile` 结构扩展
在 SQLite `history_records.files_json` 中，每个文件对象新增 `relative_path` 字段：
- 格式：MediaStore 标准路径格式，如 `"Pictures/EasySave/"` 或 `"Movies/EasySave/"`；
- **新下载文件**：通过 MediaStore 插入并定位后，即时记录其真实的 `relativePath`；
- **历史旧数据**：在 `GalleryLocatorService` 扫描定位命中已有文件时，通过原生平台通道读取 `relativePath` 并自动补写保存至数据库；未定位前该字段为 `null`。

### 6.2 跨机恢复定位算法 (Device Migration Fallback)
更换设备后，由于新系统中的 MediaStore `mediaId` 必然全部失效，采用以下分层定位策略：
1. **第 1 优先级（精确匹配）**：若 `relativePath` 存在，按 `relativePath + filename` 在相册中定位对应媒体文件；
2. **第 2 优先级（相册匹配）**：若未命中或无 `relativePath`，在设置中记录的 `usedAlbumNames`（所有用过的相册目录）中按 `filename` 遍历查找；
3. **第 3 优先级（模糊匹配）**：通过 `postId + seq` 匹配相册中可能被系统重命名命中的文件；
4. 定位成功后，立即缓存新设备的 `mediaId` 并将文件状态更新为 `FileStatus.found`，同时补写 `relativePath`。
