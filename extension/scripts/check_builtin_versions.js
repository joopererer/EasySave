// Hard gate: the parser bundled in the App must be exactly the release this
// repository declares.
//
// A build once shipped an asset set that no longer matched
// config/parser-release.json, so the App reported an older builtin version than
// the release it was built from. Every value below is derived from the
// repository, so a mismatch is a packaging mistake, never a runtime condition.
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';

export function checkBuiltinVersions(root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')) {
  const json = (name) => JSON.parse(readFileSync(resolve(root, name), 'utf8'));
  const release = json('config/parser-release.json');
  const parserVersion = readFileSync(resolve(root, 'spec/PARSER_VERSION'), 'utf8').trim();
  const builtin = json('app/assets/parser/builtin-manifest.json');
  const parserBytes = readFileSync(resolve(root, 'app/assets/parser/parser.js'));
  const sha256 = crypto.createHash('sha256').update(parserBytes).digest('hex');
  const dart = readFileSync(resolve(root, 'app/lib/generated/parser_version.dart'), 'utf8');
  const dartVersion = /static const String version = '([^']+)'/.exec(dart)?.[1];
  const problems = [];
  const expect = (actual, expected, name) => {
    if (actual !== expected) problems.push(`${name}: builtin=${actual} expected=${expected}`);
  };
  expect(builtin.manifestVersion, release.manifestVersion, 'manifestVersion');
  expect(builtin.parserVersion, parserVersion, 'parserVersion');
  expect(builtin.sha256, sha256, 'parser.js sha256');
  expect(dartVersion, parserVersion, 'lib/generated/parser_version.dart');
  const expectedUrl = release.parserUrlTemplate.replaceAll('{parserVersion}', parserVersion);
  expect(builtin.parserUrl, expectedUrl, 'parserUrl');
  if (problems.length) {
    throw new Error(
      'Bundled parser release does not match config/parser-release.json and spec/PARSER_VERSION:\n  ' +
        problems.join('\n  ') +
        '\nUpdate the version files, then run `npm run build:parser` before building the App.',
    );
  }
  return {
    manifestVersion: builtin.manifestVersion,
    parserVersion: builtin.parserVersion,
    sha256,
    bytes: parserBytes.length,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = checkBuiltinVersions();
    console.log(
      `Builtin parser ok: version=${result.parserVersion} ` +
        `manifestVersion=${result.manifestVersion} sha256=${result.sha256} bytes=${result.bytes}`,
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
