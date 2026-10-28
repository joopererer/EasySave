# AI 标注匿名采集（2026-10-27）

- xhs-platform.json： https://xhslink.cn/o/1vYtL5IX5ke
- xhs-author.json： https://xhslink.cn/o/7jkO0bCLNht
- xhs-normal.json： https://xhslink.cn/o/4FcXXaDxasW
- tiktok-platform.json：用户提供 D:/temp/tiktok_research/post_ai_platform.html
- tiktok-author.json： https://www.tiktok.com/@/video/7674898126922140959

使用 curl -L --fail --max-time 45 匿名请求，不使用 Cookie/Cookie jar。
小红书使用 iPhone Safari UA（默认 UA 返回无详情页），TikTok 使用默认 UA。
提取脚本 extension/scripts/create_ai_label_fixtures.py 拒绝覆盖已有数据。
帖子 ID、媒体地址已替换，作者与正文等非必要字段全部移除；只保留标注原文/值。
原始页面不进入仓库。
