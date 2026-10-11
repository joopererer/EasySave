import { describe, expect, it } from "vitest";
import { cachedNotesFromText, extractCachedNotes, NoteCache } from "../src/note-cache";

describe("extractCachedNotes", () => {
  it("collects noteDetailMap entries keyed by note id", () => {
    const notes = extractCachedNotes({
      data: {
        noteDetailMap: {
          abc123: { note: { noteId: "abc123", desc: "hi" } },
          def456: { noteId: "def456", desc: "yo" },
        },
      },
    });
    expect(notes.map((n) => n.id).sort()).toEqual(["abc123", "def456"]);
    expect(notes[0].note).toMatchObject({ noteId: "abc123" });
  });

  it("collects mobile-style noteData wrappers", () => {
    const notes = extractCachedNotes({
      noteData: { data: { noteData: { note: { noteId: "m1", title: "t" } } } },
    });
    expect(notes).toHaveLength(1);
    expect(notes[0].id).toBe("m1");
  });

  it("collects unknown API shapes carrying their own noteId", () => {
    const notes = extractCachedNotes({
      data: { feed: [{ noteId: "w1", desc: "hello", imageList: [] }] },
    });
    expect(notes.map((n) => n.id)).toEqual(["w1"]);
  });

  it("ignores unexpected shapes without throwing", () => {
    expect(extractCachedNotes(null)).toEqual([]);
    expect(extractCachedNotes({ a: [1, "x", null] })).toEqual([]);
    expect(extractCachedNotes("noteDetailMap")).toEqual([]);
  });
});

describe("cachedNotesFromText", () => {
  it("parses JSON bodies containing note markers", () => {
    const notes = cachedNotesFromText(
      JSON.stringify({ noteDetailMap: { z9: { note: { noteId: "z9" } } } }),
    );
    expect(notes.map((n) => n.id)).toEqual(["z9"]);
  });

  it("rejects non-JSON and oversized bodies", () => {
    expect(cachedNotesFromText("<html>noteDetailMap</html>")).toEqual([]);
    expect(cachedNotesFromText("")).toEqual([]);
  });
});

describe("NoteCache", () => {
  it("evicts oldest entries beyond the limit", () => {
    const cache = new NoteCache(2);
    cache.add([
      { id: "a", note: { noteId: "a" } },
      { id: "b", note: { noteId: "b" } },
      { id: "c", note: { noteId: "c" } },
    ]);
    expect(cache.get("a")).toBeUndefined();
    expect(cache.get("c")).toMatchObject({ noteId: "c" });
  });
});
