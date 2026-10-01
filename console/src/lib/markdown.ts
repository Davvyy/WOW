/** P11 "운영자 추가 규칙" 카드용 최소 Markdown(## 제목, - 목록, **굵게**). 결과는 React 노드용 구조로 돌려준다. */
export type MdBlock =
  | { kind: 'h'; text: string }
  | { kind: 'ul'; items: string[] }
  | { kind: 'p'; text: string };

export function parseMd(md: string): MdBlock[] {
  const out: MdBlock[] = [];
  let list: string[] | null = null;
  const flush = () => { if (list) { out.push({ kind: 'ul', items: list }); list = null; } };
  for (const line of md.split('\n')) {
    if (/^##\s+/.test(line)) { flush(); out.push({ kind: 'h', text: line.replace(/^##\s+/, '') }); }
    else if (/^[-*]\s+/.test(line)) { (list ??= []).push(line.replace(/^[-*]\s+/, '')); }
    else if (line.trim()) { flush(); out.push({ kind: 'p', text: line }); }
  }
  flush();
  return out;
}

/** **굵게** 구간을 나눈다. */
export function splitBold(text: string): { bold: boolean; text: string }[] {
  const parts: { bold: boolean; text: string }[] = [];
  const re = /\*\*(.+?)\*\*/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (m.index > last) parts.push({ bold: false, text: text.slice(last, m.index) });
    parts.push({ bold: true, text: m[1] });
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push({ bold: false, text: text.slice(last) });
  return parts;
}
