# v1.10 最终硬编码逐文件盘点

生成命令：rtk proxy python scripts/audit_site_hardcoding.py。完整逐行源码与理由见 hardcoded-hits.json。
本表是词法候选盘点；生成配置、注释/符号、算法与延期项不冒充四类获准保留项。详细范围和结论见 README.md。

| 文件 | 行号 | 分类 | 每处保留理由 |
|---|---|---|---|
| app/android/app/src/main/AndroidManifest.xml | 138 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/android/app/src/main/AndroidManifest.xml | 55, 137 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/android/app/src/main/assets/link-recognition.json | 1 | 生成配置 | 由 config/sites.json 与构建器生成；不是独立维护的平台表。 |
| app/android/app/src/main/kotlin/com/james/easysave/ExternalHandlers.kt | 9, 22, 23, 31 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/android/app/src/main/kotlin/com/james/easysave/LogSanitizer.kt | 7 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/android/app/src/main/kotlin/com/james/easysave/MainActivity.kt | 29, 30, 166, 170, 177, 610, 611, 618, 619, 624 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/assets/parser/builtin-manifest.json | 1 | 生成配置 | 由 config/sites.json 与构建器生成；不是独立维护的平台表。 |
| app/lib/background/background_entry.dart | 81 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/core/dev_log.dart | 6, 143 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/core/models.dart | 3, 75, 81 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/generated/builtin_sites.dart | 2 | 生成配置 | 由 config/sites.json 与构建器生成；不是独立维护的平台表。 |
| app/lib/pages/batch_page.dart | 63, 112, 114, 115, 119, 187, 221, 222 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/lib/pages/batch_page.dart | 15, 69, 71 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/pages/login_page.dart | 5, 8, 113, 338, 366 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/pages/parse_page.dart | 217, 272, 273, 285, 298, 303, 313, 314, 315, 337, 404, 411, 420, 509 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/lib/pages/parse_page.dart | 26, 212, 360, 402, 1085, 1086 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/auth.dart | 4, 7, 51, 121, 144, 183 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/clipboard_guard.dart | 68 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/lib/services/clipboard_guard.dart | 22, 23, 32 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/download_manager.dart | 381 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/links.dart | 57, 67, 68, 69, 70, 71, 73, 84, 92, 102 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/lib/services/links.dart | 55, 56, 82, 83, 108 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/login_navigation.dart | 8, 9 | 通用安全规则 | 内嵌 WebView 的 Google OAuth 精确 host 判定，与站点无关；站点专用文案已入清单。 |
| app/lib/services/preview_open_guard.dart | 84 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/seal.dart | 8, 9, 13, 16, 18, 21, 31, 32, 37, 38, 41 | 外部转交许可表 | YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。 |
| app/lib/services/seal.dart | 1, 2, 6, 12, 15, 20, 29, 30 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| app/lib/services/update_service.dart | 467, 479, 480 | 旧通道兼容代码 | 旧 platforms/headers ABI 的 X 默认 endpoint/UA；v2 解析入口从 site.load 获取数据，本轮保留旧调用契约。 |
| app/lib/widgets/shared.dart | 280, 281, 282, 283 | 内置图标资源 | 本地 Material assetKey 注册表；清单只能选择已打包字形，不能加载远程图标。 |
| app/lib/widgets/shared.dart | 67 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| config/parser-release.json | 7, 9, 11, 13, 15, 17, 19, 22, 26, 27, 29, 32, 35 | 清单源配置 | 允许维护站点数据的源配置；parser-release 的 platforms/headers 是旧 ABI 兼容投影。 |
| config/sites.json | 3, 4, 5, 6, 16, 20, 31, 35, 39, 52, 60, 68, 80, 82, 83, 90, 96, 101, 105, 106, 107, 112, 116, 120, 124, 129, 139, 144, 145, 146, 147, 157, 161, 177, 184, 190, 192, 195, 199, 203, 208, 218, 223, 224, 225, 226, 236, 240, 251, 264, 276, 283, 292, 294, 296, 300, 313, 318, 319, 320, 321, 331, 343, 347, 360, 369, 378, 394, 401, 407, 408, 410, 412, 413, 415, 419, 423, 427, 431, 436, 439, 461, 464, 467, 468, 469, 470, 480, 484, 495, 508, 520, 527, 533, 537 | 清单源配置 | 允许维护站点数据的源配置；parser-release 的 platforms/headers 是旧 ABI 兼容投影。 |
| extension/entrypoints/background.ts | 51, 52, 53, 125 | 扩展旧通道与静态权限（超类说明） | 扩展仍消费冻结 v1 通道；内容脚本注入/host_permissions/DNR 属浏览器打包权限，App 清单不能提升；迁移需单独扩展协议与重新发行，且本轮不改请求策略。 |
| extension/entrypoints/content.ts | 3, 4, 5, 6, 10, 11, 12, 124, 128, 153, 158, 164, 168, 181, 182, 183, 186, 193, 203, 240, 244, 279, 329, 330, 375, 376, 385, 387, 389, 449, 611 | 扩展旧通道与静态权限（超类说明） | 扩展仍消费冻结 v1 通道；内容脚本注入/host_permissions/DNR 属浏览器打包权限，App 清单不能提升；迁移需单独扩展协议与重新发行，且本轮不改请求策略。 |
| extension/public/rules.json | 8, 12, 22, 26, 36, 40 | 扩展旧通道与静态权限（超类说明） | 扩展仍消费冻结 v1 通道；内容脚本注入/host_permissions/DNR 属浏览器打包权限，App 清单不能提升；迁移需单独扩展协议与重新发行，且本轮不改请求策略。 |
| extension/src/_parse_page.ts | 17, 89, 91, 101, 102, 110, 111, 115, 119, 138, 140, 147, 149, 153, 163, 168, 169, 171, 172, 174 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/_parse_page.ts | 1, 2, 4, 5, 180 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/_utils.ts | 10, 11, 14, 15, 19 | 旧通道兼容代码 | parse(input,pageUrl) 与扩展旧 manifest 协议入口/host 辅助/错误投影；不是 App v2 Registry 分派。 |
| extension/src/ai-label.ts | 11, 18 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/errors.ts | 14, 15, 16, 17, 18, 23 | 旧通道兼容代码 | parse(input,pageUrl) 与扩展旧 manifest 协议入口/host 辅助/错误投影；不是 App v2 Registry 分派。 |
| extension/src/ig-cache.ts | 1 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/index.ts | 23, 24, 26, 37, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 52, 54, 55, 56, 57, 63, 64, 65, 66, 82, 83, 85 | 旧通道兼容代码 | parse(input,pageUrl) 与扩展旧 manifest 协议入口/host 辅助/错误投影；不是 App v2 Registry 分派。 |
| extension/src/index.ts | 3, 4, 6, 92 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/instagram.ts | 13, 14, 18, 25, 26, 35, 36, 39, 42, 46, 47, 169, 173, 195, 230, 231, 232, 234, 243, 249, 263, 269, 294, 322, 327, 328, 330 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/instagram.ts | 1, 5, 7, 23, 45, 66, 191, 258 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/page-hooks.d.ts | 2, 3 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/page-hooks.js | 75, 97 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/parser-modules.ts | 26, 36, 46, 49, 68, 69, 70, 72, 75, 82 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/parser-modules.ts | 3, 5 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/tiktok.ts | 9, 13, 20, 21, 25, 37, 48, 71, 73, 75, 81, 83, 85, 86, 89, 90, 91, 110, 120, 127, 128, 131, 139 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/tiktok.ts | 1, 2, 69, 70, 78, 137 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/x.ts | 40, 53, 198, 199, 268 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/x.ts | 1 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/src/xhs.ts | 15, 16, 20, 27, 28, 40, 42, 45, 49, 53, 54, 71, 72, 114, 122, 362, 409, 418, 477, 491, 496, 508, 530, 531, 532, 534, 539, 545, 564, 565, 573, 641, 647, 679, 684, 695, 715, 727, 740, 750, 764, 769, 770, 772, 776 | 签名解析模块算法（超类说明） | 站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。 |
| extension/src/xhs.ts | 1, 5, 7, 9, 25, 32, 52, 99, 100, 101, 504, 560, 635 | 词法候选 | 注释、导入或符号声明；不独立执行站点数据规则。 |
| extension/wxt.config.ts | 10, 11, 12, 13, 14, 15, 16, 17, 18, 34, 35, 36, 37 | 扩展旧通道与静态权限（超类说明） | 扩展仍消费冻结 v1 通道；内容脚本注入/host_permissions/DNR 属浏览器打包权限，App 清单不能提升；迁移需单独扩展协议与重新发行，且本轮不改请求策略。 |

扫描文件数：195；命中行数：494。
