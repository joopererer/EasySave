import { it, expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { parseXhs } from '../src/xhs';

it.each(['author', 'normal', 'both'])('logged-in PC structure: %s', kind => {
  const input = readFileSync(new URL(`../../spec/fixtures/ai-label/xhs-pc-${kind}.json`, import.meta.url), 'utf8');
  const log = vi.spyOn(console, 'info').mockImplementation(() => {});
  try {
    const result = parseXhs(`<script>window.__INITIAL_STATE__=${input}</script>`, 'https://www.xiaohongshu.com/explore/000000000000000000000001');
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const note = JSON.parse(input).note.noteDetailMap['000000000000000000000001'].note;
    expect(result.data.aiLabel).toEqual(kind === 'normal' ? undefined : { text: note.noteStatement, source: 'author' });
    if (kind !== 'author') expect(log).toHaveBeenCalledWith('EasySaveAiLabel:' + JSON.stringify({ id: result.data.id, value: kind === 'both' ? note.illegalInfo.desc : note.noteStatement }));
  } finally { log.mockRestore(); }
});
