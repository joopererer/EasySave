// TEMPORARY: remove in a separate commit after the device logs resolve A.
const paths = new WeakMap<object, string>();
export function rememberXhsPath<T extends object>(note: T, path: string): T {
  paths.set(note, path);
  return note;
}

export function xhsDiagnostic(note: Record<string, unknown>): void {
  if (!(globalThis as Record<string, unknown>).__EasySaveXhsDiagnostic) return;
  const fields: { path: string; type: string; text?: string }[] = [];
  const seen = new Set<object>();
  const sensitive = /cookie|token|session|account|password|email|phone|^(?:author|user|profile|nickname)(?:$|[_-]?(?:id|name|info|avatar|detail|data)$)/i;
  const wanted = /illegal|ai|aigc|declare|statement|label|tag|notice|tip/i;
  const body = /^(title|desc|description|caption|content|body|text|plaintext)$/i;
  function visit(value: unknown, path: string, depth: number): void {
    if (!value || typeof value !== 'object' || seen.has(value) || depth > 24) return;
    seen.add(value);
    for (const [key, child] of Object.entries(value)) {
      // Dynamic map keys could themselves contain private data.
      if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key) && !/^\d+$/.test(key)) continue;
      if (sensitive.test(key)) continue;
      const childPath = /^\d+$/.test(key) ? `${path}[index]` : `${path}.${key}`;
      if (wanted.test(key)) {
        const field: { path: string; type: string; text?: string } = {
          path: childPath,
          type: child === null ? 'null' : Array.isArray(child) ? 'array' : typeof child,
        };
        if (typeof child === 'string' && /AI|声明/i.test(child) && !body.test(key)) {
          field.text = Array.from(child).slice(0, 50).join('');
        }
        fields.push(field);
      }
      visit(child, childPath, depth + 1);
    }
  }
  visit(note, 'note', 0);
  console.info('EasySaveXhsDiagnostic:' + JSON.stringify({
    dataPath: paths.get(note) ?? 'HTML.noteDetailMap[id]', fields,
  }));
}
