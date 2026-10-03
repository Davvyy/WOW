// 식약처 「전국통합식품영양성분정보(음식)표준데이터」(공공데이터포털 15100070) CSV → food_db_cache 적재 SQL.
//
//   node supabase/seed/load_food_db.mjs <CSV 경로> > food_db.sql
//   npx --yes supabase@2 db query --linked -f food_db.sql
//
// 규칙(docs/02 §10 D42)
//  - 일반 음식만 넣는다. 외식(프랜차이즈 등 업체 제공 영양정보)과 간편조리세트(밀키트, 한 상자 분량)는 뺀다.
//  - kcal·탄단지는 1인분 값: 영양성분(기준량당) × 식품중량 ÷ 기준량. 이 데이터는 1인(회)분량 참고량이 비어 있어 식품중량을 1인분으로 쓴다.
//    기준량과 식품중량의 단위(g·ml)는 행마다 같고, ml 은 serving_g 에 그대로 숫자로 넣는다.
//  - 같은 이름이 여러 기원에 있으면 하나만 고른다: 식품중량이 100(g·ml)이 아닌 행(실제 분량) 먼저,
//    그 안에서 ORIGIN_PRIORITY(실측·성인 분량 우선) 순. 모든 행이 100 이면 100 을 1인분으로 둔다.
//  - 식품중량이 없는 행은 뺀다. 같은 food_code 가 있으면 값을 갱신한다(다시 돌려도 된다).
//  - 두 단계 이름 A_B(예: 김밥_참치)에는 동의어를 붙인다: B 가 A 로 끝나면 B, 아니면 B+A(참치김밥).
//  - 시드 예시 음식(가짜 코드 D000001 형식)과 그 동의어는 지운다. 끼니 항목이 참조하면 외래 키 때문에 전체가 되돌려진다.
//  - 테스트: node --test supabase/seed/load_food_db_test.mjs
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const ORIGIN_PRIORITY = [
  '외식(분석함량)',
  '가정식(분석 함량)',
  '외식(재료량 기반 산출함량)',
  '산업체급식(재료량 기반 산출 함량)',
  '중고등학교급식(재료량 기반 산출함량)',
  '초등학교급식(재료량 기반 산출 함량)',
];

/**
 * 규칙으로 고른 값이 성인 1인분과 크게 다른 자주 먹는 음식의 예외: 이 기원 행의 기준량당 값 × 이 분량.
 * 쌀밥은 실제 분량이 학교급식(250·450ml)뿐이라 외식(분석) 100g당 값에 한 공기 210g 을 쓴다.
 */
export const SERVING_OVERRIDES = new Map([['쌀밥', { origin: '외식(분석함량)', serving: 210 }]]);

/** 사진·검색에서 흔히 쓰는 이름 → 음식 이름 */
export const MANUAL_SYNONYMS = new Map([['쌀밥', ['공기밥', '흰쌀밥', '흰밥', '밥']]]);

/** RFC 4180 CSV(따옴표 안 쉼표·줄바꿈·"" 이스케이프) */
export function parseCsv(text) {
  const rows = [];
  let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') {
        if (text[i + 1] === '"') { f += '"'; i++; } else q = false;
      } else f += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n') { row.push(f.replace(/\r$/, '')); rows.push(row); row = []; f = ''; }
    else f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  return rows;
}

const r1 = (x) => Math.floor(x * 10 + 0.5) / 10;
const amount = (s) => {
  const m = /^([0-9.]+)\s*(g|ml)$/i.exec((s ?? '').trim());
  return m ? { value: Number(m[1]), unit: m[2].toLowerCase() } : null;
};
const num = (s) => (s === undefined || s.trim() === '' ? null : Number(s));

/** CSV 행 → 음식 목록(이름당 1건, 1인분 값) */
export function pickFoods(rows) {
  const [header, ...data] = rows;
  const col = (name) => {
    const i = header.indexOf(name);
    if (i < 0) throw new Error(`CSV 에 '${name}' 컬럼이 없어요`);
    return i;
  };
  const C = {
    code: col('식품코드'), name: col('식품명'), origin: col('식품기원명'), big: col('식품대분류명'),
    base: col('영양성분함량기준량'), kcal: col('에너지(kcal)'), protein: col('단백질(g)'), fat: col('지방(g)'),
    carb: col('탄수화물(g)'), weight: col('식품중량'),
  };
  const best = new Map();
  const skipped = { franchise: 0, mealKit: 0, noWeight: 0, unitMismatch: 0, unknownOrigin: 0 };
  for (const r of data) {
    if (r[C.origin].startsWith('외식(프랜차이즈')) { skipped.franchise++; continue; }
    const name = r[C.name].trim();
    if (name.includes('간편조리세트')) { skipped.mealKit++; continue; }
    const rank = ORIGIN_PRIORITY.indexOf(r[C.origin]);
    if (rank < 0) { skipped.unknownOrigin++; continue; }
    const override = SERVING_OVERRIDES.get(name);
    if (override && r[C.origin] !== override.origin) continue;
    const base = amount(r[C.base]);
    const weight = override ? { value: override.serving, unit: base?.unit } : amount(r[C.weight]);
    if (!base || !weight) { skipped.noWeight++; continue; }
    if (base.unit !== weight.unit) { skipped.unitMismatch++; continue; }
    const k = weight.value / base.value;
    const scaled = (v) => (v === null ? null : r1(v * k));
    const food = {
      food_code: r[C.code], name_kr: name, category: r[C.big] || null, serving_g: weight.value,
      kcal: r1(num(r[C.kcal]) * k), carb_g: scaled(num(r[C.carb])), protein_g: scaled(num(r[C.protein])), fat_g: scaled(num(r[C.fat])),
      sortKey: [weight.value === 100 ? 1 : 0, rank, r[C.code]],
    };
    const prev = best.get(name);
    if (!prev || compareKeys(food.sortKey, prev.sortKey) < 0) best.set(name, food);
  }
  const foods = [...best.values()].sort((a, b) => a.food_code.localeCompare(b.food_code));
  const names = new Set(foods.map((f) => f.name_kr));
  const synonyms = foods.flatMap((f) =>
    [...aliasesFor(f.name_kr, names), ...(MANUAL_SYNONYMS.get(f.name_kr) ?? []).filter((a) => !names.has(a))]
      .map((alias) => ({ alias, food_code: f.food_code })));
  return { foods, synonyms, skipped };
}

function compareKeys(a, b) {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

/** 두 단계 이름 A_B 의 동의어: B 가 A 로 끝나면 B(국밥_순대국밥 → 순대국밥), 아니면 B+A(김밥_참치 → 참치김밥). 이미 음식 이름이면 만들지 않음 */
export function aliasesFor(name, names) {
  const parts = name.split('_');
  if (parts.length !== 2 || !parts[0] || !parts[1]) return [];
  const [a, b] = parts;
  const alias = b.endsWith(a) ? b : b + a;
  return names.has(alias) ? [] : [alias];
}

const lit = (v) => (v === null ? 'null' : typeof v === 'number' ? String(v) : `'${String(v).replace(/'/g, "''")}'`);

/** 예시 음식 삭제(동의어는 연쇄 삭제) + 음식 upsert + 동의어 추가. 한 번의 질의로 보내면 한 트랜잭션으로 처리된다. */
export function toSql(foods, synonyms = []) {
  const values = foods
    .map((f) => `(${[f.food_code, f.name_kr, f.category, f.serving_g, f.kcal, f.carb_g, f.protein_g, f.fat_g].map(lit).join(', ')})`)
    .join(',\n');
  const sql = [
    `delete from food_db_cache where food_code ~ '^D[0-9]{6}$';`,
    `insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, carb_g, protein_g, fat_g) values\n${values}\n` +
      `on conflict (food_code) do update set name_kr = excluded.name_kr, category = excluded.category, serving_g = excluded.serving_g,\n` +
      `  kcal = excluded.kcal, carb_g = excluded.carb_g, protein_g = excluded.protein_g, fat_g = excluded.fat_g, updated_at = now();`,
  ];
  if (synonyms.length) {
    sql.push(
      `insert into food_synonyms (alias, food_code) values\n${synonyms.map((s) => `(${lit(s.alias)}, ${lit(s.food_code)})`).join(',\n')}\n` +
        `on conflict (alias, food_code) do nothing;`,
    );
  }
  return sql.join('\n');
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const path = process.argv[2];
  if (!path) {
    console.error('사용법: node supabase/seed/load_food_db.mjs <CSV 경로> > food_db.sql');
    process.exit(1);
  }
  const { foods, synonyms, skipped } = pickFoods(parseCsv(readFileSync(path, 'utf8').replace(/^﻿/, '')));
  console.error(`음식 ${foods.length}건 · 동의어 ${synonyms.length}개 · 건너뜀 ${JSON.stringify(skipped)}`);
  process.stdout.write(toSql(foods, synonyms) + '\n');
}
