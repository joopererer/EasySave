export interface AiLabel {
  text: string;
  source: 'platform' | 'author';
}

// Dedicated bridge to App DevLog; never log the surrounding post payload.
export function unknownAiLabel(id: string, value: string | number | boolean): void {
  console.info('EasySaveAiLabel:' + JSON.stringify({ id, value }));
}

export function xhsAiLabel(desc: unknown, id: string): AiLabel | undefined {
  if (typeof desc !== 'string' || !desc.trim()) return;
  if (desc === '可能含AI生成内容') return { text: desc, source: 'platform' };
  if (desc.startsWith('作者声明') && /ai/i.test(desc)) return { text: desc, source: 'author' };
  unknownAiLabel(id, desc);
}

export function tiktokAiLabel(value: unknown, id: string): AiLabel | undefined {
  // Real web payloads encode these enum values as strings.
  if (value === 1 || value === '1') return { text: 'Contains AI-generated media', source: 'platform' };
  if (value === 2 || value === '2') return { text: 'Creator labeled as AI-generated', source: 'author' };
  if ((typeof value === 'string' && value.trim()) || typeof value === 'number' || typeof value === 'boolean') {
    unknownAiLabel(id, value as string | number | boolean);
  }
}
