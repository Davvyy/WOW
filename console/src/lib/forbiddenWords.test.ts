import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

/** UI 문구 금지 어휘(06 §6). 목록 자체를 담은 이 파일은 검사에서 뺀다. */
const FORBIDDEN = ['실패', '부정', '조작', '거짓', '적발', '꼴찌'];
const SELF = 'forbiddenWords.test.ts';

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(ts|tsx)$/.test(name) && name !== SELF) out.push(p);
  }
  return out;
}

/** 문자열 리터럴·템플릿 문자열·JSX 텍스트만 모은다(주석·식별자 제외). */
function textsOf(file: string): { text: string; line: number }[] {
  const src = readFileSync(file, 'utf8');
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
  const found: { text: string; line: number }[] = [];
  const visit = (n: ts.Node) => {
    if (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n) || ts.isTemplateHead(n) || ts.isTemplateMiddle(n) || ts.isTemplateTail(n) || ts.isJsxText(n)) {
      found.push({ text: n.text ?? '', line: sf.getLineAndCharacterOfPosition(n.getStart()).line + 1 });
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
  return found;
}

describe('UI 문구 금지 어휘', () => {
  const files = walk(resolve(__dirname, '..'));
  it('검사 대상 파일이 있다', () => {
    expect(files.length).toBeGreaterThan(5);
  });
  it('src 문자열 리터럴에 금지 어휘가 없다', () => {
    const hits: string[] = [];
    for (const f of files) {
      for (const { text, line } of textsOf(f)) {
        for (const w of FORBIDDEN) if (text.includes(w)) hits.push(`${f}:${line} "${w}"`);
      }
    }
    expect(hits).toEqual([]);
  });
  it('스캐너가 금지 어휘를 실제로 잡는다', () => {
    const sf = ts.createSourceFile('x.tsx', 'const a = "실패"; const b = <p>조작</p>;', ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
    const texts: string[] = [];
    const visit = (n: ts.Node) => { if (ts.isStringLiteral(n) || ts.isJsxText(n)) texts.push(n.text); ts.forEachChild(n, visit); };
    visit(sf);
    expect(FORBIDDEN.some((w) => texts.join('').includes(w))).toBe(true);
  });
});
