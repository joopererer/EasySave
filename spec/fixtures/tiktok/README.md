# TikTok fixtures

`video.html` is a minimal projection of the real `video1.html` captured during
phase-one research in `D:/temp/tiktok_research/`. Only the required hydration
scope, status, post identity, caption, timestamp, numeric author identity and
video playback fields remain. `downloadAddr` is retained solely as a negative
test: it must never appear in the parsed result.

All media addresses use `media.example` and opaque paths are replaced with
`FAKE_<n>.mp4`. Every query value (including signatures and chain tokens) is
`FAKE`. No cookies or application/session context is included.

The reference `post_photo.html` has no `webapp.video-detail` scope. A real photo
success fixture is still pending; synthetic photo unit tests are explicitly
separate and are not represented as captured page data.
