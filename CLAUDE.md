# EasySave

EasySave is a monorepo skeleton for a Flutter app and a vanilla WXT browser extension supporting future watermark-free Xiaohongshu and Instagram media parsing.

## Directories

- `app/`: Flutter application (`com.james.easysave`) for Android and iOS.
- `extension/`: WXT + TypeScript vanilla extension, with Vitest tests.
- `spec/`: parser contract and fixture directories (`fixtures/xhs/`, `fixtures/instagram/`).
- `refs/`: read-only AGPL/GPL reference checkouts for research only.

Never copy code from `refs/` into this project. The references are read-only and remain outside the product implementation.

## Parser contract

App and extension parsers must pass every fixture pair under `spec/fixtures/`: each `*.html` input has a corresponding `*.expected.json` output. Add fixtures before implementing parser behavior.

## Workflow and language

After each completed step, run the relevant tests and commit. Code, comments, and commit messages must be in English.

## Common commands

- `flutter test` (from `app/)
- `flutter run` (from `app/`)
- `npm run dev` (from `extension/`)
- `npx vitest run` (from `extension/`)
- `npm run build` (from `extension/`)
