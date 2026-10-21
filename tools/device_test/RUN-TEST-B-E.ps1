# Quick launcher for Test B-E in interactive terminal
# Run this in a real PowerShell terminal (not background shell)

cd d:\workspace\IdeaProjects\EasySave\tools\device_test

.\run.ps1 `
  -TestCase all `
  -ExifTool "C:\Users\univasity\AppData\Local\Programs\ExifTool\ExifTool.exe" `
  -AlbumDir "/sdcard/Pictures/EasySave" `
  -XhsUrl 'https://www.xiaohongshu.com/explore/6aca33420000000012035198' `
  -IgUrl 'https://www.instagram.com/p/DeTOj5WRMIh/' `
  -XUrl 'https://x.com/Lucy_love_AI/status/2110916144072913327' `
  -SkipExtensionTest

# New test URLs (different content to bypass deduplication):
# - XHS: xhs_video (video note)
# - Instagram: ig_reel (short-form video)
# - X: photo (single photo tweet)
