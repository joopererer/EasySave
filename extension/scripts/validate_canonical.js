import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '../../app');
const validated = new Set();

export function validateCanonicalTemplates(sites) {
  const input = JSON.stringify(sites.map((s) => ({ id: s.id, normalize: s.normalize })));
  if (validated.has(input)) return;
  let dart = process.env.DART_EXECUTABLE || 'dart';
  if (process.platform === 'win32' && !process.env.DART_EXECUTABLE) {
    const config = JSON.parse(readFileSync(resolve(app, '.dart_tool/package_config.json'), 'utf8'));
    const flutter = fileURLToPath(config.packages.find((p) => p.name === 'flutter').rootUri);
    dart = resolve(flutter, '../../bin/cache/dart-sdk/bin/dart.exe');
  }
  const result = spawnSync(dart, ['--packages=.dart_tool/package_config.json', 'tool/validate_canonical_templates.dart'], {
    cwd: app, input: input + '\n', encoding: 'utf8', timeout: 60000,
  });
  if (result.status !== 0) {
    throw new Error('canonicalTemplate/provenance_dart validation failed: ' + (result.stderr || result.error?.message || 'Dart unavailable'));
  }
  validated.add(input);
}
