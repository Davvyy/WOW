/** 검토 SLA(72h) 계산. 색 없이 텍스트로도 상태를 알려 준다(접근성). */
export const SLA_HOURS = 72;
export const SLA_WARN_HOURS = 24;

export type SlaLevel = 'ok' | 'warn' | 'critical';

export function hoursLeft(slaDueAt: string, nowIso: string): number {
  return Math.ceil((Date.parse(slaDueAt) - Date.parse(nowIso)) / 3600e3);
}

export function slaLevel(h: number): SlaLevel {
  if (h < 0) return 'critical';
  if (h < SLA_WARN_HOURS) return 'warn';
  return 'ok';
}

export function slaText(h: number): string {
  if (h < 0) return `+${Math.abs(h)}h 초과`;
  if (h < SLA_WARN_HOURS) return `남은 ${h}h · 임박`;
  return `남은 ${h}h`;
}
