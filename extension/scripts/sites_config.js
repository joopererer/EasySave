// Limited schema vocabulary used by sites-manifest.schema.json; unknown keywords fail closed.
// contentSchema is explicitly applied to decoded payloads.
const annotations = new Set(['$schema', '$id', 'title', 'description', '$defs', 'contentMediaType', 'contentSchema']);
const supported = new Set(['$ref', 'type', 'properties', 'additionalProperties', 'required', 'items', 'minItems', 'maxItems', 'uniqueItems', 'minLength', 'maxLength', 'pattern', 'enum', 'const', 'minimum', 'maximum', 'format']);

export function validateSchema(value, rule, schema, path = '$') {
  for (const key of Object.keys(rule)) {
    if (!annotations.has(key) && !supported.has(key)) throw new Error('Unsupported schema keyword: ' + key);
  }
  if (rule.$ref) {
    const target = rule.$ref.split('/').slice(1).reduce((node, key) => node[key], schema);
    return validateSchema(value, target, schema, path);
  }
  const fail = () => { throw new Error('Invalid manifest field: ' + path); };
  if ('const' in rule && value !== rule.const) fail();
  if (rule.enum && !rule.enum.includes(value)) fail();
  if (rule.type === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail();
    for (const key of rule.required ?? []) if (!Object.hasOwn(value, key)) fail();
    for (const [key, child] of Object.entries(value)) {
      const childRule = Object.hasOwn(rule.properties ?? {}, key)
        ? rule.properties[key] : rule.additionalProperties;
      if (childRule === false) fail();
      if (childRule && typeof childRule === 'object') validateSchema(child, childRule, schema, path + '.' + key);
    }
  } else if (rule.type === 'array') {
    if (!Array.isArray(value)) fail();
    if (value.length < (rule.minItems ?? 0) || value.length > (rule.maxItems ?? Infinity)) fail();
    if (rule.uniqueItems && new Set(value.map((v) => JSON.stringify(v))).size !== value.length) fail();
    value.forEach((item, i) => validateSchema(item, rule.items, schema, path + '[' + i + ']'));
  } else if (rule.type === 'string') {
    if (typeof value !== 'string') fail();
    if (value.length < (rule.minLength ?? 0) || value.length > (rule.maxLength ?? Infinity)) fail();
    if (rule.pattern && !new RegExp(rule.pattern).test(value)) fail();
    if (rule.format === 'uri') { try { new URL(value); } catch { fail(); } }
  } else if (rule.type === 'integer') {
    if (!Number.isSafeInteger(value) || value < (rule.minimum ?? -Infinity) || value > (rule.maximum ?? Infinity)) fail();
  } else if (rule.type === 'boolean' && typeof value !== 'boolean') fail();
}

export function validatePayload(payload, schema) {
  validateSchema(payload, schema.$defs.payload, schema);
  const url = new URL(payload.parserUrl);
  if (url.origin !== 'https://github.com' || url.username || url.password || url.search || url.hash ||
      !/^\/[^/]+\/[^/]+\/releases\/download\/parser-v[0-9]+\.[0-9]+\.[0-9]+\/parser\.js$/.test(url.pathname) ||
      !url.pathname.endsWith('/parser-v' + payload.parserVersion + '/parser.js')) {
    throw new Error('parserUrl must address the versioned GitHub Release attachment');
  }
  const ids = new Set();
  const domain = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$/;
  for (const site of payload.sites) {
    if (ids.has(site.id)) throw new Error('Duplicate site id');
    ids.add(site.id);
    const hosts = [...site.match.routes.flatMap((r) => r.hosts), ...site.shortLinks.map((r) => r.host), ...site.download.mediaHosts];
    if (hosts.some((h) => !domain.test(h.domain)) || site.download.cookieDomains.some((d) => !domain.test(d))) throw new Error('Invalid site domain');
    for (const route of site.match.routes) {
      if (!route.hosts.length || !route.pathPatterns.length) throw new Error('Empty site route');
      for (const pattern of route.pathPatterns) {
        if (!pattern.startsWith('^/')) throw new Error('Path rules must be anchored');
        new RegExp(pattern);
      }
    }
    if (Object.values(site.download.headers).some((v) => /[\r\n\x00]/.test(v))) throw new Error('Invalid request header value');
    if (site.auth.mode !== 'none' && !site.auth.loginUrl) throw new Error('Missing login URL');
    for (const raw of [site.auth.loginUrl, ...(site.auth.cookieUrls || [])].filter(Boolean)) {
      const u = new URL(raw);
      if (u.protocol !== 'https:' || u.username || u.password || !site.match.routes.some(r => r.hosts.some(h =>
        u.hostname === h.domain || h.includeSubdomains && u.hostname.endsWith('.' + h.domain)))) throw new Error('Invalid login URL');
    }
    if (/[\r\n\x00]/.test(site.auth.userAgent || '')) throw new Error('Invalid login user agent');
  }
  for (const headers of Object.values(payload.headers ?? {})) {
    if (Object.values(headers).some((v) => /[\r\n\x00]/.test(v))) throw new Error('Invalid request header value');
  }
}
