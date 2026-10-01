import { describe, expect, it } from 'vitest';
import { CSV_COLUMNS, buildCsv } from './csv';

describe('csv', () => {
  it('운영자 전용 열이 어느 CSV에도 없다', () => {
    const all = Object.values(CSV_COLUMNS).flat();
    for (const banned of ['health_alerts', 'operator_note', 'record_mode_reason', 'type', 'photo_path']) {
      expect(all).not.toContain(banned);
    }
  });
  it('허용 열만 내보낸다', () => {
    const f = buildCsv('ranking', 'K7Q2MD', [{ rank: 1, nickname: '달려라하니', score_total: 1310.4, confirmed_meals: 84, operator_note: '비공개' }]);
    expect(f.filename).toBe('final_ranking_K7Q2MD.csv');
    expect(f.text).not.toContain('비공개');
    expect(f.text).toContain('"1","달려라하니","1310.4","84"');
    expect(f.rowCount).toBe(1);
  });
});
