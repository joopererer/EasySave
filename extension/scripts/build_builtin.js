import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPayload } from './build_release.js';
import { validatePayload } from './sites_config.js';
import { validateCanonicalTemplates } from './validate_canonical.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const payload = createPayload(root);
validatePayload(payload, JSON.parse(readFileSync(resolve(root, 'spec/sites-manifest.schema.json'))));
validateCanonicalTemplates(payload.sites);
const write = (name, contents) => { const p = resolve(root, name); mkdirSync(dirname(p), {recursive:true}); writeFileSync(p, contents); };
write('app/assets/parser/builtin-manifest.json', JSON.stringify(payload));
write('app/lib/generated/builtin_sites.dart', '// GENERATED FILE - DO NOT EDIT\nconst builtinSitesJson = ' +
  JSON.stringify(JSON.stringify(payload.sites)).replaceAll('$', '\\$') + ';\n');
const view = {sites: payload.sites.filter((s) => s.enabled).map((s) => ({id:s.id, routes:s.match.routes}))};
write('app/android/app/src/main/assets/link-recognition.json', JSON.stringify(view));
