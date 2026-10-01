import type { HealthAlertType } from '../data/types';
import { addDays, mdDate } from './format';

/** 건강 알림 한 줄 설명 (운영자 전용 섹션). localDate는 마지막 해당 날짜. */
export function healthAlertText(type: HealthAlertType, localDate: string): string {
  const end = mdDate(localDate);
  const start = mdDate(addDays(localDate, -2));
  switch (type) {
    case 'low_intake_3d': return `섭취 기록 3일 연속 적음(${start}~${end})`;
    case 'high_activity_3d': return `활동 기록 3일 연속 높음(${start}~${end}, 약 1,000 kcal 초과)`;
    case 'weight_drop': return `체중이 주 2% 넘게 줄었어요(${end} 기준) · 푸시 없음`;
  }
}
