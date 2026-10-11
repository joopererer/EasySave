# EasySave

EasySave is a monorepo skeleton for a Flutter app and a vanilla WXT browser extension supporting future watermark-free Xiaohongshu and Instagram media parsing.

## Directories

- `app/`: Flutter application (`com.james.easysave`) for Android and iOS.
- `extension/`: WXT + TypeScript vanilla extension, with Vitest tests.
- `spec/`: parser contract and fixtures under `spec/fixtures/` (`spec/fixtures/xhs/`, `spec/fixtures/instagram/`).
- `refs/`: read-only AGPL/GPL reference checkouts for research only.

Never copy code from `refs/` into this project. The references are read-only and remain outside the product implementation.

## Parser contract

App and extension parsers must pass every fixture pair under `spec/fixtures/`: each `*.html` input has a corresponding `*.expected.json` output. Add fixtures before implementing parser behavior.

## Environment

Node.js 22.12 or newer is required.

## Workflow and language

Run the relevant tests after each completed step. Tests or builds that do not pass must stop the workflow and be reported; never commit a change when validation has failed. Never use `GIT_SSL_NO_VERIFY` or any other method that disables TLS certificate verification. Code, comments, and commit messages must be in English.

## Common commands

- `flutter test` (from `app/)
- `flutter run` (from `app/`)
- `npm run dev` (from `extension/`)
- `npx vitest run` (from `extension/`)
- `npm run build` (from `extension/`)
