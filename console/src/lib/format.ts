/** 숫자·날짜 표기. prototype/data.js의 fmt와 같은 규칙. */
export const fmt = {
  int: (n: number) => Math.round(n).toLocaleString('ko-KR'),
  k1: (n: number) => (Math.round(n * 10) / 10).toLocaleString('ko-KR', { minimumFractionDigits: 1, maximumFractionDigits: 1 }),
  /** 부호 붙은 소수 1자리. 음수는 유니코드 마이너스(−). */
  signed1: (n: number) => (n > 0 ? '+' : n < 0 ? '−' : '±') + (Math.round(Math.abs(n) * 10) / 10).toLocaleString('ko-KR', { minimumFractionDigits: 1, maximumFractionDigits: 1 }),
};

export const round1 = (x: number) => Math.round(x * 10) / 10;

/** "2026-10-13" -> "10.13" */
export const mdDate = (iso: string) => `${+iso.slice(5, 7)}.${+iso.slice(8, 10)}`;

/** ISO 시각 -> "10.13 21:14" (KST 고정) */
export function mdTime(iso: string): string {
  const d = new Date(new Date(iso).getTime() + 9 * 3600e3);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getUTCMonth() + 1}.${d.getUTCDate()} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
}

export function addDays(iso: string, n: number): string {
  const d = new Date(iso + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86400e3);
}

export function median(arr: number[]): number {
  const a = [...arr].sort((x, y) => x - y);
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}
