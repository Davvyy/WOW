import type { CsvFile, CsvType } from '../data/types';

/**
 * CSV 열 허용 목록. health_alerts·operator_note·record_mode_reason 등 운영자 전용 열은 여기에 없다.
 * 서버 export가 없을 때 쓰는 클라이언트 생성도 이 열만 쓴다.
 */
export const CSV_COLUMNS: Record<CsvType, string[]> = {
  ranking: ['rank', 'nickname', 'score_total', 'confirmed_meals'],
  scores: ['nickname', 'local_date', 'steps', 'a_d', 'i_d', 'd_d', 's_d', 'is_counted'],
  meals: ['nickname', 'local_date', 'slot', 'status', 'confirmed_kcal'],
  activity: ['nickname', 'local_date', 'steps_total', 'steps_net', 'sessions_net', 'floors_bonus', 'a_capped'],
};

export const CSV_FILE_BASE: Record<CsvType, string> = {
  ranking: 'final_ranking',
  scores: 'daily_scores',
  meals: 'meals_confirmed',
  activity: 'activity_breakdown',
};

export const CSV_LABEL: Record<CsvType, string> = {
  ranking: '최종 순위',
  scores: '일별 장부',
  meals: '끼니 확정값',
  activity: '활동 분해',
};

/** 허용 목록에 없는 열은 버리고 허용 열 순서로 정렬한다. */
export function buildCsv(type: CsvType, code: string, records: Record<string, unknown>[]): CsvFile {
  const cols = CSV_COLUMNS[type];
  const q = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const lines = [cols.map(q).join(','), ...records.map((r) => cols.map((c) => q(r[c])).join(','))];
  return { filename: `${CSV_FILE_BASE[type]}_${code}.csv`, text: '﻿' + lines.join('\n'), rowCount: records.length };
}
