import esbuild from 'esbuild';
import { readFileSync, writeFileSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const version = readFileSync(resolve(__dirname, '..', '..', 'spec', 'PARSER_VERSION'), 'utf8').trim();

esbuild.build({
  entryPoints: [resolve(__dirname, '..', 'src', '_parse_page.ts')],
  bundle: true,
  platform: 'browser',
  format: 'iife',
  globalName: 'EasySaveParser',
  define: { __VERSION__: JSON.stringify(version) },
  outfile: resolve(__dirname, '..', '..', 'app', 'assets', 'parser', 'parser.js')
}).then(() => {
  // Generate parser_version.dart
  const versionDartPath = resolve(__dirname, '..', '..', 'app', 'lib', 'generated', 'parser_version.dart');
  const dartContent = `// GENERATED FILE - DO NOT EDIT\nclass ParserVersion {\n  static const String version = '$version';\n}\n`;
  writeFileSync(versionDartPath, dartContent);
}).catch(err => {
  console.error(err);
  process.exit(1);
});