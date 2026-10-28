import { afterEach, describe, expect, it, vi } from 'vitest';
import { findNoteInStates, buildNoteFromRecord } from '../src/xhs';

afterEach(() => { delete (globalThis as any).__EasySaveXhsDiagnostic; vi.restoreAllMocks(); });
describe('temporary XHS diagnostic privacy boundary', () => {
  for (const mobile of [false, true]) it(`reports selected ${mobile ? 'mobile' : 'PC'} path and limited fields`, () => {
    (globalThis as any).__EasySaveXhsDiagnostic = true;
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    const note = { noteId: '123', imageList: [], illegalInfo: null,
      declarationLabel: '作者声明：AI' + '字'.repeat(100), aiCount: 9,
      authorStatement: '作者声明：AI',
      tagList: [{ label: '普通标签' }], title: 'AI PRIVATE_BODY',
      author: { aiLabel: 'AI PRIVATE_AUTHOR' }, cookie: 'AI PRIVATE_COOKIE',
      aiAccount: 'AI PRIVATE_ACCOUNT', plainText: 'AI PRIVATE_BODY',
      nested: { notice: '普通提示', statement: false } };
    const state = mobile ? { noteData: { data: { noteData: note } } }
      : { note: { noteDetailMap: { '123': { note } } } };
    const selected = findNoteInStates([state], '123')!;
    buildNoteFromRecord(selected, '123');
    const raw = log.mock.calls.find(([line]) => String(line).startsWith('EasySaveXhsDiagnostic:'))![0] as string;
    const data = JSON.parse(raw.slice('EasySaveXhsDiagnostic:'.length));
    expect(data.dataPath).toBe(mobile ? 'noteData.data.noteData' : 'note.noteDetailMap[id].note');
    expect(data.fields).toContainEqual({ path: 'note.illegalInfo', type: 'null' });
    expect(data.fields).toContainEqual({ path: 'note.aiCount', type: 'number' });
    expect(data.fields).toContainEqual({ path: 'note.authorStatement', type: 'string', text: '作者声明：AI' });
    expect(data.fields).toContainEqual({ path: 'note.nested.notice', type: 'string' });
    expect(data.fields.find((f: any) => f.path === 'note.declarationLabel').text.length).toBe(50);
    expect(raw).not.toContain('PRIVATE_');
    expect(raw).not.toContain('普通标签');
  });
  it('emits an empty field list for a note without candidate fields', () => {
    (globalThis as any).__EasySaveXhsDiagnostic = true;
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    buildNoteFromRecord({ noteId: '123', imageList: [] }, '123');
    expect(log.mock.calls.some(([line]) => String(line).includes('"fields":[]'))).toBe(true);
  });
  it('does not log when the App diagnostic flag is absent', () => {
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    buildNoteFromRecord({ noteId: '123', aiLabel: 'AI' }, '123');
    expect(log).not.toHaveBeenCalled();
  });
});
