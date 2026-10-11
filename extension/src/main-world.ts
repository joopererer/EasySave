// Reads the XHS embedded state directly from the MAIN world page context.

export function readXhsStateJson(): unknown | undefined {
  const w = window as unknown as Record<string, unknown>;
  for (const key of ["__INITIAL_STATE__", "__NEXT_DATA__", "__NUXT__"]) {
    if (w[key] !== undefined) return w[key];
  }
  return undefined;
}
