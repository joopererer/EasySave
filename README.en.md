<div align="center">
  <img src="docs/design/icon/easysave-icon-C/png/easysave-icon-circle-512.png" width="112" height="112" alt="EasySave icon">
  <h1>EasySave</h1>
  <p>Save the images and videos you love. Keep their origins, too.</p>
  <p><a href="README.md">简体中文</a> · <strong>English</strong></p>
</div>

<p align="center">
  <a href="app/android/app/build.gradle.kts"><img src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&amp;logoColor=white" alt="Android 7.0 and later"></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Built_with-Flutter-02569B?logo=flutter&amp;logoColor=white" alt="Built with Flutter"></a>
  <a href="https://github.com/joopererer/EasySave/releases"><img src="https://img.shields.io/github/v/release/joopererer/EasySave?filter=parser-v*&amp;label=parser" alt="Latest parser release, not the app version"></a>
  <a href="https://github.com/joopererer/EasySave/actions/workflows/release_parser.yml"><img src="https://github.com/joopererer/EasySave/actions/workflows/release_parser.yml/badge.svg" alt="Parser release workflow status, not full app CI"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#features">Features</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="docs/roadmap.md">Roadmap</a> ·
  <a href="https://github.com/joopererer/EasySave/issues">Report an issue</a>
</p>

EasySave is a media-saving tool primarily targeting **Android**. It parses and saves images, videos, and Live Photos from Xiaohongshu, Instagram, X, and TikTok posts. Beyond downloading, it offers local history browsing, provenance metadata, backup and restore, and quick download entry points without leaving your current app.

> **Development status**: v1.10 is under development and device verification; implementation does not imply full device acceptance. Candidate ideas in the v1.11 document are not existing features. See the [changelog](CHANGELOG.md) and [task records](docs/tasks/v1.10.md) for details.

## Features

- **Multi-platform media saving**: Preview posts, select images and videos, process multiple links, and save media to the system gallery.
- **Quick download entry points**: Use system sharing, background share-to-download, a Quick Settings tile, or an optional floating selection panel.
- **Media browsing and management**: Zoom images, play videos, and long-press Live Photos; browse history by post, media, or author, with search, filters, and sharing.
- **Preserved origins**: Write XMP provenance into supported images and videos, including the original post, author, and platform-provided AI labels; preserve C2PA image bytes and record provenance in XMP sidecars.
- **Backup and restore**: Export history and non-sensitive settings, automatically back up to a selected folder, or rebuild history from provenance stored with gallery files.
- **Verified parser updates**: The app checks signatures, hashes, and compatibility before accepting online parser updates, retaining a working version on failure without requiring an APK reinstall for every parser fix.

## Supported platforms

| Platform | Content | Notes |
| --- | --- | --- |
| Xiaohongshu | Images, videos, Live Photos | Some content requires login or a complete share link; original-image availability depends on platform resources |
| Instagram | Images, carousels, videos / Reels | Some content requires login; sensitive-content and platform restrictions may affect parsing |
| X (Twitter) | Images, videos, GIF-like media | Some restricted posts can use an existing login session, subject to the account's access rights |
| TikTok | Videos, photo posts | Interrupted session-authenticated videos may require re-parsing; resumable downloads are not guaranteed |
| YouTube | External handoff | No built-in downloader; links can be handed to [Seal](https://github.com/JunkFood02/Seal) |

The current Android minimum is **Android 7.0 (API 24)**. Other Flutter platform directories do not imply complete support or available releases for those platforms; the browser extension does not promise the same platform coverage as the Android app.

## Quick start

### Installation

Check the release notes and assets on [GitHub Releases](https://github.com/joopererer/EasySave/releases). Only releases explicitly identified as app releases with an `.apk` asset can be installed on a phone. If no APK is available, build from source using the instructions below.

**The `parser.js` and `manifest.json` files in `parser-v*` releases are parser rules for the app, not installation packages.** The parser badge above does not indicate the app version either.

### Usage

1. Open EasySave and paste a supported post link, or send a link through the system share sheet.
2. If login is required, sign in to the corresponding platform within the app; save only content your account is allowed to access.
3. Preview the media, select the items you want, and download them.
4. Browse local files, open original posts, or share content from history.
5. Configure a backup folder in settings; enable the floating overlay or add the Quick Settings tile only if you need those shortcuts.

Grant gallery, notification, folder, and overlay permissions as needed. Android and device-vendor background policies can affect background tasks; actual behavior needs device verification.

## Provenance, privacy, and limitations

- **Provenance travels with files**: Metadata follows [provenance-spec](https://github.com/joopererer/provenance-spec) and is handled by [provenance_dart](https://github.com/joopererer/provenance_dart); see the [metadata documentation](spec/metadata.md).
- **AI labels are not authenticity verdicts**: Labels reflect platform detection or author declarations, not an independent assessment by EasySave.
- **Content credentials remain intact**: C2PA images and their matching `.xmp` sidecars are saved in `Download/EasySave/`; keep them together when moving or backing them up.
- **Backups do not contain media bytes**: History and settings backups are not substitutes for image and video backups; restoration still needs local files or access to the original post for downloading again.
- **Business-data backups exclude login credentials**: Account cookies, Authorization headers, and WebView sessions are not exported; original post links, authors, and captions may remain in backups and metadata, so share backups cautiously.
- **Platform restrictions still apply**: Not all original images, private posts, or restricted resources are available; website changes, login requirements, and link expiration may affect functionality.
- **Use only with appropriate authorization**: Respect copyright, privacy, and platform terms; do not use the tool to bypass access controls or redistribute content without permission.

## Build from source

### Prerequisites

- Git with submodule support.
- Flutter stable satisfying the Dart SDK constraint in [`app/pubspec.yaml`](app/pubspec.yaml), currently `^3.11.5`.
- Android SDK, JDK 17, and an Android device or emulator; run `flutter doctor` to check your environment first.
- Node.js 20 and npm when modifying or testing the shared parser.

### Android app

```bash
git clone --recurse-submodules https://github.com/joopererer/EasySave.git
cd EasySave/app
flutter pub get
flutter run
```

Build an APK from the `app/` directory:

```bash
flutter build apk --release
```

The output is `app/build/app/outputs/flutter-apk/app-release.apk`. Release builds currently use debug signing and are suitable for development verification; configure and safeguard a production signing key before distribution, and do not treat a local build as an officially signed release.

### Shared parser and browser extension

From the repository root, enter `extension/`:

```bash
cd extension
npm ci
npm test
npm run build
```

`npm run build` builds the browser extension; the Android app uses a bundled version of the shared TypeScript parser. After changing parser sources, run `npm run build:parser` as needed and review generated-file changes. Official parser releases require a maintainer-configured signing key; ordinary development and testing do not require running the release workflow.

## Testing and contributing

Run Flutter checks from `app/`:

```bash
flutter analyze
flutter test
```

Run native unit tests from `app/android/`:

```bash
./gradlew testDebugUnitTest
```

On Windows, use `.\gradlew.bat testDebugUnitTest`. Run shared parser tests with `npm test` in `extension/` as shown above; passing automated tests is not the same as passing device verification.

Report bugs and suggestions through [Issues](https://github.com/joopererer/EasySave/issues), or improve the project with a pull request. Include app/parser versions, Android version, reproduction steps, and sanitized logs. Never submit account cookies, login credentials, or unsanitized private content. Discuss new platforms or major features before implementing them.

## Project structure and documentation

| Path | Contents |
| --- | --- |
| [`app/`](app/) | Flutter app, Android-native entry points, and media management |
| [`extension/`](extension/) | Shared TypeScript parser, browser extension, and build scripts |
| [`config/`](config/) | Site and parser release configuration |
| [`spec/`](spec/) | Data models, backup formats, and metadata integration contracts |
| [`docs/provenance-spec/`](docs/provenance-spec/) | Provenance specification submodule |
| [`docs/tasks/`](docs/tasks/) | Version tasks, handovers, and verification records |

- [Changelog (Chinese and English)](CHANGELOG.md)
- [Roadmap](docs/roadmap.md)
- [Backup format](spec/backup.md)
- [v1.10 design and implementation records](docs/tasks/v1.10.md)
- [v1.11 candidate directions](docs/tasks/v1.11.md)

Most detailed project documents are currently in Chinese.

## Licensing and acknowledgments

The repository does not currently provide a project-level `LICENSE`. Publicly visible source code does not imply permission under an open-source license; confirm usage, modification, and distribution terms with the maintainer. Third-party dependencies, brand assets, and submodules retain their respective licenses.

Thanks to [Flutter](https://flutter.dev), [provenance_dart](https://github.com/joopererer/provenance_dart), [provenance-spec](https://github.com/joopererer/provenance-spec), and the projects behind the dependencies. YouTube handoff uses the independent [Seal](https://github.com/JunkFood02/Seal) project. Language navigation and information grouping in these READMEs were informed by [LocalSend](https://github.com/localsend/localsend) and [Obtainium](https://github.com/ImranR98/Obtainium).
