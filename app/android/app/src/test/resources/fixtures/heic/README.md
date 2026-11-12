# HEIC samples for the decode table

Drop the reported samples here (any of `.heic`, `.heif`, `.avif`) and run:

```
cd app/android && ./gradlew testDebugUnitTest --tests '*HeicSampleDecodeTableTest*' --info
```

`HeicSampleDecodeTableTest` prints one line per sample.

Robolectric's `BitmapFactory` is a shadow that fabricates a bitmap for every
input, so the printed table does **not** represent a real Android 12 device.
The authoritative table comes from the read-only on-device self-check described
in `docs/tasks/v1.10.3-heic-video-hotfix.md`.

Files are only ever read; nothing in this directory is modified or deleted.
