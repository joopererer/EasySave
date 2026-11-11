import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { isDeepStrictEqual } from 'node:util';

export function assertBuiltinParity(root, payload) {
  const json = name => JSON.parse(readFileSync(resolve(root, name), 'utf8'));
  const effective = value => Object.fromEntries(Object.entries(value)
    .filter(([key]) => !['parserVersion', 'manifestVersion'].includes(key)));
  const equal = (a, b, name) => {
    if (!isDeepStrictEqual(a, b)) throw new Error('Builtin configuration mismatch: ' + name);
  };
  equal(effective(payload), effective(json('app/assets/parser/builtin-manifest.json')), 'manifest');
  equal(json('spec/sites-manifest.schema.json'), json('app/assets/parser/sites-manifest.schema.json'), 'schema');
  const dart = readFileSync(resolve(root, 'app/lib/generated/builtin_sites.dart'), 'utf8');
  const encoded = /const builtinSitesJson = (.*);/.exec(dart)?.[1];
  equal(JSON.parse(JSON.parse(encoded.replaceAll('\\$', '$'))), payload.sites, 'builtin_sites');
  equal(json('app/android/app/src/main/assets/link-recognition.json'), {
    sites: payload.sites.filter(s => s.enabled).map(s => ({id:s.id, routes:s.match.routes})),
  }, 'link-recognition');
}
