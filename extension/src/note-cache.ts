// Pure helpers for harvesting note records from XHR/fetch JSON payloads.
// The MAIN-world bridge uses these to cache notes loaded by SPA navigation,
// so posts opened without a full page load are still parseable.

export interface CachedNote {
  id: string;
  note: Record<string, unknown>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function unwrapEntry(entry: unknown): Record<string, unknown> | undefined {
  if (!isRecord(entry)) return undefined;
  if (isRecord(entry["note"])) return entry["note"] as Record<string, unknown>;
  return entry;
}

function noteIdOf(note: Record<string, unknown>): string | undefined {
  const id = note["noteId"];
  return typeof id === "string" && id.length > 0 ? id : undefined;
}

function isNoteLike(obj: Record<string, unknown>): boolean {
  if (!noteIdOf(obj)) return false;
  return (
    typeof obj["title"] === "string" ||
    typeof obj["desc"] === "string" ||
    typeof obj["description"] === "string" ||
    Array.isArray(obj["imageList"]) ||
    Array.isArray(obj["images"]) ||
    isRecord(obj["video"])
  );
}

/**
 * Walk a decoded JSON payload and collect every note record it contains.
 * Recognizes `noteDetailMap` entries (keyed by note id) and mobile-style
 * `noteData` wrappers. Never throws on unexpected shapes.
 */
export function extractCachedNotes(payload: unknown): CachedNote[] {
  const out: CachedNote[] = [];
  const seenIds = new Set<string>();
  const push = (id: string | undefined, note: Record<string, unknown> | undefined): void => {
    if (!note) return;
    const key = id ?? noteIdOf(note);
    if (!key || seenIds.has(key)) return;
    seenIds.add(key);
    out.push({ id: key, note });
  };

  const seen = new Set<object>();
  const visit = (node: unknown): void => {
    if (!isRecord(node) && !Array.isArray(node)) return;
    if (seen.has(node as object)) return;
    seen.add(node as object);
    if (isRecord(node)) {
      const map = node["noteDetailMap"];
      if (isRecord(map)) {
        for (const [key, entry] of Object.entries(map)) {
          push(key, unwrapEntry(entry));
        }
      }
      const data = node["data"];
      const nested = isRecord(data) ? (data["noteData"] as unknown) : undefined;
      if (isRecord(node["noteData"]) || isRecord(nested)) {
        const wrapper = (isRecord(nested) ? nested : node["noteData"]) as Record<string, unknown>;
        push(undefined, unwrapEntry(isRecord(wrapper["note"]) ? wrapper["note"] : wrapper));
      }
      // Unknown API shapes (e.g. feed modal payloads): accept any object
      // that looks like a note and carries its own noteId.
      if (isNoteLike(node)) push(undefined, node);
      for (const value of Object.values(node)) visit(value);
    } else {
      for (const value of node as unknown[]) visit(value);
    }
  };

  try {
    visit(payload);
  } catch {
    // Ignore; return whatever was collected.
  }
  return out;
}

/** Parse response text into cached notes; returns [] for non-JSON bodies. */
export function cachedNotesFromText(text: string): CachedNote[] {
  if (text.length === 0 || text.length > 8 * 1024 * 1024) return [];
  const hasMap = text.includes("noteDetailMap") || text.includes("noteData");
  const hasNoteLike =
    text.includes('"noteId"') &&
    (text.includes('"imageList"') || text.includes('"images"') || text.includes('"video"'));
  if (!hasMap && !hasNoteLike) return [];
  try {
    return extractCachedNotes(JSON.parse(text) as unknown);
  } catch {
    return [];
  }
}

/** Bounded id -> note cache used by the bridge. */
export class NoteCache {
  private readonly map = new Map<string, Record<string, unknown>>();
  constructor(private readonly limit = 20) {}

  add(notes: CachedNote[]): void {
    for (const { id, note } of notes) {
      this.map.delete(id);
      this.map.set(id, note);
    }
    while (this.map.size > this.limit) {
      const oldest = this.map.keys().next();
      if (oldest.done) break;
      this.map.delete(oldest.value);
    }
  }

  get(id: string): Record<string, unknown> | undefined {
    return this.map.get(id);
  }

  /** Most recently added note (used when the URL carries no post id, e.g. feed modals). */
  recent(): Record<string, unknown> | undefined {
    let last: Record<string, unknown> | undefined;
    for (const note of this.map.values()) last = note;
    return last;
  }
}
