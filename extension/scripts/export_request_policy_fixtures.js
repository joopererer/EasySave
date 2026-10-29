// Local integration corpus from the CURRENT bundled parser, never network I/O.
// stdout is consumed in memory by the Dart policy tests; it is not a log/artifact.
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const read = path => readFileSync(resolve(root, path), 'utf8');
const sites = JSON.parse(read('config/sites.json'));
const sources = JSON.parse(read('spec/fixtures/sources.json'));
const context = vm.createContext({ URL, window: {}, console: { log() {}, warn() {}, error() {} } });
vm.runInContext(read('app/assets/parser/parser.js'), context);
const parser = context.EasySaveParser;
const corpus = [];
for (const id of ['xhs', 'instagram', 'x', 'tiktok']) {
  for (const name of readdirSync(resolve(root, 'spec/fixtures', id)).sort()) {
    if (!(name.endsWith('.html') || id === 'x' && name.endsWith('.json') && !name.endsWith('.expected.json'))) continue;
    const input = read('spec/fixtures/' + id + '/' + name);
    let url = sources[id]?.[name.replace(/\.(?:html|json)$/, '')];
    if (id === 'tiktok') {
      const match = /<script\b[^>]*>([\s\S]*?)<\/script>/.exec(input);
      const scope = JSON.parse(match[1]).__DEFAULT_SCOPE__;
      const detail = scope['webapp.video-detail'] ?? scope['webapp.reflow.video.detail'];
      url = 'https://www.tiktok.com/@/video/' + detail.itemInfo.itemStruct.id;
    }
    if (!url) continue;
    const result = JSON.parse(parser.moduleCall(id, 'parse', {
      url, input, statusCode: 200, site: sites.find(s => s.id === id),
    })).value;
    if (result.ok) corpus.push({ id, fixture: name, data: result.data });
  }
}
process.stdout.write(JSON.stringify(corpus));
