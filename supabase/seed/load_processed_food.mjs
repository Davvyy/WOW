// 식약처 「전국통합식품영양성분정보(가공식품)표준데이터」(공공데이터포털 15100066) NDJSON → food_db_cache 상품 행 적재 SQL.
//
//   DATA_GO_KR_KEY=<인코딩 키> node supabase/seed/fetch_processed_food.mjs <processed.ndjson>
//   node supabase/seed/load_processed_food.mjs <processed.ndjson> <출력 폴더> [파일당 행 수, 기본 5000]
//   for f in <출력 폴더>/processed_food_*.sql; do npx --yes supabase@2 db query --linked -f "$f" || break; done
//
// 규칙(docs/02 §10 D63)
//  - 끼니로 먹는 대분류(KEEP_LV3)만 넣는다. 조미식품·식용유지류·장류·절임류·주류 등은 뺀다. kcal 이 없는 행도 뺀다.
//  - 같은 상품(공백을 뺀 이름 + 제조사)은 데이터생성일자가 가장 최근인 행 하나만.
//  - 1개 = 포장 전체(식품중량이 1회 섭취참고량의 1.5배 이하) → 1회 섭취참고량 → 포장 전체(500 이하) → 기준량(100g·ml).
//    kcal·탄단지는 기준량당 값 × 1개 양 ÷ 기준량. 라벨은 '1개(40g)' · '1회분(30g)' · '100g'.
//  - food_code 는 식약처 상품 코드(P…), is_product = true 로 음식(D…) 자동 매칭과 나눈다.
//  - package_g = 포장 전체 양(식품중량의 g·ml 숫자, 읽을 수 없으면 null). 앱의 '몇 개입' 낱개 계산(D64)에 쓴다.
//  - 제조사가 '해당없음'·빈 값이면 수입업체, 그다음 유통업체를 maker 로 쓴다(중복 판단도 이 이름으로).
//  - 파일당 5,000건(세 번째 인자로 바꿈)씩 나눠 쓰고, 같은 food_code 의 상품 행은 값만 갱신한다
//    (다시 돌려도 된다. 음식 행은 덮어쓰지 않는다).
//  - 테스트: node --test supabase/seed/load_processed_food_test.mjs
import { createReadStream, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

/** 끼니·간식으로 먹는 대분류 */
export const KEEP_LV3 = new Set([
  '과자류·빵류 또는 떡류', '즉석식품류', '음료류', '식육가공품 및 포장육', '수산가공식품류', '코코아가공품류 또는 초콜릿류', '면류',
  '유가공품류', '빙과류', '두부류 또는 묵류', '알가공품류', '당류', '농산가공식품류', '특수영양식품',
]);

/** 1회 섭취참고량이 없을 때 포장 전체를 1개로 보는 최대 양(g·ml) */
export const WHOLE_PACKAGE_MAX = 500;

/** 포장이 1회 섭취참고량의 이 배수 이하면 포장 전체를 1개로 */
export const WHOLE_PACKAGE_RATIO = 1.5;

export const CHUNK_ROWS = 5000;

/** CLI 세 번째 인자(파일당 행 수). 없으면 CHUNK_ROWS, 양의 정수가 아니면 오류 */
export function chunkSizeArg(s) {
  if (s === undefined || s === '') return CHUNK_ROWS;
  if (!/^[0-9]+$/.test(String(s)) || Number(s) <= 0) throw new Error(`파일당 행 수는 양의 정수여야 해요: ${s}`);
  return Number(s);
}

const real = (s) => {
  const v = String(s ?? '').trim();
  return v && v !== '해당없음' ? v : null;
};

/** 표시할 제조사: 제조사 → (해당없음·빈 값이면) 수입업체 → 유통업체, 모두 없으면 null */
export const makerOf = (r) => real(r.mfr) ?? real(r.imp) ?? real(r.dist);

const r1 = (x) => Math.floor(x * 10 + 0.5) / 10;
const num = (s) => {
  if (s === undefined || s === null || String(s).trim() === '') return null;
  const v = Number(s);
  return Number.isFinite(v) ? v : null;
};
const fmt = (v) => String(r1(v));

/** '30g' · '130ml' · '100ml(g)' · '100g(ml)' → {value, unit}. 다른 꼴('1식', 분류 공통 문구)·0 은 null */
export function parseAmount(s) {
  const m = /^([0-9]+(?:\.[0-9]+)?)\s*(g|ml)(?:\s*\((?:g|ml)\))?$/i.exec(String(s ?? '').trim());
  if (!m || Number(m[1]) <= 0) return null;
  return { value: Number(m[1]), unit: m[2].toLowerCase() };
}

/** 1개(포장 전체·1회분·기준량)의 양·라벨·kcal·탄단지 */
export function unitOf(r) {
  const per = parseAmount(r.per) ?? { value: 100, unit: 'g' };
  const serv = parseAmount(r.serv);
  const size = parseAmount(r.size);
  let amount, label;
  if (size && serv && size.value <= WHOLE_PACKAGE_RATIO * serv.value) {
    amount = size.value;
    label = `1개(${fmt(size.value)}${size.unit})`;
  } else if (serv) {
    amount = serv.value;
    label = `1회분(${fmt(serv.value)}${serv.unit})`;
  } else if (size && size.value <= WHOLE_PACKAGE_MAX) {
    amount = size.value;
    label = `1개(${fmt(size.value)}${size.unit})`;
  } else {
    amount = per.value;
    label = `${fmt(per.value)}${per.unit}`;
  }
  const scale = (v) => (v === null ? null : r1((v * amount) / per.value));
  return { amount, label, kcal: scale(num(r.kcal)), carb: scale(num(r.carb)), prot: scale(num(r.prot)), fat: scale(num(r.fat)) };
}

/** NDJSON 행 → 상품 목록(분류·kcal 거르기, 이름+제조사 중복 제거, food_code 순) */
export function pickProducts(rows) {
  const skipped = { category: 0, noKcal: 0, duplicate: 0 };
  const best = new Map();
  for (const r of rows) {
    if (!KEEP_LV3.has(r.lv3)) { skipped.category++; continue; }
    if (num(r.kcal) === null) { skipped.noKcal++; continue; }
    const key = `${String(r.name).replace(/\s+/g, '')}\u0000${makerOf(r) ?? ''}`;
    const prev = best.get(key);
    if (prev) skipped.duplicate++;
    if (!prev || newer(r, prev)) best.set(key, r);
  }
  // 같은 코드가 다른 이름·제조사로 남으면(드묾) 최근 행 하나만 — 한 upsert 안에서 같은 키가 두 번 나오지 않게
  const byCode = new Map();
  for (const r of best.values()) {
    const prev = byCode.get(r.code);
    if (prev) skipped.duplicate++;
    if (!prev || newer(r, prev)) byCode.set(r.code, r);
  }
  const products = [...byCode.values()]
    .sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0))
    .map((r) => {
      const u = unitOf(r);
      return {
        food_code: r.code, name_kr: String(r.name).trim(), category: (r.lv4 || '').trim() || r.lv3, serving_g: u.amount, kcal: u.kcal,
        carb_g: u.carb, protein_g: u.prot, fat_g: u.fat, maker: makerOf(r), unit_label: u.label,
        package_g: parseAmount(r.size)?.value ?? null,
      };
    });
  return { products, skipped };
}

/** 데이터생성일자가 더 최근(같으면 코드가 큰 행) */
function newer(a, b) {
  const da = a.date ?? '', db = b.date ?? '';
  if (da !== db) return da > db;
  return String(a.code) > String(b.code);
}

const lit = (v) => (v === null || v === undefined ? 'null' : typeof v === 'number' || typeof v === 'boolean' ? String(v) : `'${String(v).replace(/'/g, "''")}'`);

/** 상품 upsert SQL 을 [size]건씩 나눈 문자열 목록 */
export function chunkSql(products, size = CHUNK_ROWS) {
  const out = [];
  for (let i = 0; i < products.length; i += size) {
    const values = products.slice(i, i + size)
      .map((p) => `(${[p.food_code, p.name_kr, p.category, p.serving_g, p.kcal, p.carb_g, p.protein_g, p.fat_g, true, p.maker, p.unit_label, p.package_g].map(lit).join(', ')})`)
      .join(',\n');
    out.push(
      `insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, carb_g, protein_g, fat_g, is_product, maker, unit_label, package_g) values\n${values}\n` +
        `on conflict (food_code) do update set name_kr = excluded.name_kr, category = excluded.category, serving_g = excluded.serving_g,\n` +
        `  kcal = excluded.kcal, carb_g = excluded.carb_g, protein_g = excluded.protein_g, fat_g = excluded.fat_g,\n` +
        `  is_product = excluded.is_product, maker = excluded.maker, unit_label = excluded.unit_label,\n` +
        `  package_g = excluded.package_g, updated_at = now()\n` +
        `  where food_db_cache.is_product;\n`,
    );
  }
  return out;
}

async function readNdjson(path) {
  const rows = [];
  const rl = createInterface({ input: createReadStream(path, 'utf8'), crlfDelay: Infinity });
  for await (const line of rl) if (line.trim()) rows.push(JSON.parse(line));
  return rows;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [path, outDir, rowsArg] = process.argv.slice(2);
  if (!path || !outDir) {
    console.error('사용법: node supabase/seed/load_processed_food.mjs <processed.ndjson> <출력 폴더> [파일당 행 수, 기본 5000]');
    process.exit(1);
  }
  const rows = await readNdjson(path);
  const { products, skipped } = pickProducts(rows);
  mkdirSync(outDir, { recursive: true });
  const chunks = chunkSql(products, chunkSizeArg(rowsArg));
  chunks.forEach((sql, i) => writeFileSync(join(outDir, `processed_food_${String(i + 1).padStart(3, '0')}.sql`), sql));
  console.error(`읽은 행 ${rows.length} · 상품 ${products.length}건 · 파일 ${chunks.length}개 · 건너뜀 ${JSON.stringify(skipped)}`);
}
