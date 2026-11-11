# Android release signing / 发布签名

This document records the rule only. The keystore, the `key.properties` file and every
value inside them live **outside the repository** and must never be read, printed,
copied into the repo, a log, or a handover record. Only Gradle reads them at build time.

## Rule: every delivered APK is a release build with the release key

Every APK handed to a user for installation — including every intermediate test build
in later rounds — must be built as a **signed `release` build**
(`flutter build apk --release`) with the EasySave release keystore.

This guarantees that each new APK installs as an in-place upgrade over the previous one
(same `applicationId`, same signing certificate). Debug-signed or `--debug` APKs must
never be delivered, because they cannot be installed over a release build and would
force an uninstall that wipes app data.

The release build refuses to run without a valid signing configuration; it never falls
back to the debug keystore. See `app/android/app/build.gradle.kts`
(`requireReleaseSigning`, wired into `preReleaseBuild`).

## Where the configuration lives

| Item | Location |
| --- | --- |
| Signing properties | `%USERPROFILE%\.easysave\key.properties` |
| Override path | environment variable `EASYSAVE_KEY_PROPERTIES` |
| Keystore | path given by `storeFile` inside that file |

Gradle resolves the properties file as
`System.getProperty("user.home")/.easysave/key.properties` unless
`EASYSAVE_KEY_PROPERTIES` is set. Required fields: `storeFile`, `storePassword`,
`keyAlias`, `keyPassword` (optional `storeType`). A relative `storeFile` is resolved
against the directory that contains `key.properties`.

If the file is missing, or any field or the keystore file itself is missing, the release
build fails with an explicit error message. There is no silent debug fallback.

## Verifying a delivered APK

```powershell
& $env:LOCALAPPDATA\Android\Sdk\build-tools\<version>\apksigner.bat verify --print-certs <apk>
```

Print only the certificate fingerprint (`SHA-256 digest`) — that is public information.
The EasySave release certificate must **not** be the Android debug certificate
(`7ec6c14f...3484`).

## Repository hygiene

`*.jks`, `*.keystore` and `key.properties` are ignored by `.gitignore` so signing
material can never be committed by accident.
