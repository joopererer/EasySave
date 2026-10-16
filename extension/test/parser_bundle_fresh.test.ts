import { describe, it, expect } from 'vitest';
import { readFileSync, mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join, resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import esbuild from 'esbuild';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

describe('Parser bundle freshness check', () => {
  it('committed app/assets/parser/parser.js matches fresh build', async () => {
    const versionPath = resolve(__dirname, '../../spec/PARSER_VERSION');
    const version = readFileSync(versionPath, 'utf8').trim();
    const parserBundlePath = resolve(__dirname, '../../app/assets/parser/parser.js');
    const committedBundle = readFileSync(parserBundlePath, 'utf8');

    const tempDir = mkdtempSync(join(tmpdir(), 'easysave-parser-'));
    const tempBundlePath = join(tempDir, 'parser.js');

    try {
      await esbuild.build({
        entryPoints: [resolve(__dirname, '../src/_parse_page.ts')],
        bundle: true,
        platform: 'browser',
        format: 'iife',
        globalName: 'EasySaveParser',
        define: { __VERSION__: JSON.stringify(version) },
        outfile: tempBundlePath,
      });

      const freshBundle = readFileSync(tempBundlePath, 'utf8');
      expect(freshBundle).toBe(committedBundle);
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it('generated parser_version.dart matches spec/PARSER_VERSION', () => {
    const versionPath = resolve(__dirname, '../../spec/PARSER_VERSION');
    const version = readFileSync(versionPath, 'utf8').trim();
    const dartPath = resolve(__dirname, '../../app/lib/generated/parser_version.dart');
    const committedDart = readFileSync(dartPath, 'utf8').replace(/\r\n/g, '\n');
    const expectedDart = `// GENERATED FILE - DO NOT EDIT\nclass ParserVersion {\n  static const String version = '${version}';\n}\n`;
    expect(committedDart).toBe(expectedDart);
  });
});
