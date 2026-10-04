// 식약처 「전국통합식품영양성분정보(가공식품)표준데이터」(공공데이터포털 15100066) NDJSON → food_db_cache 상품 행 적재 SQL.
//
//   DATA_GO_KR_KEY=<인코딩 키> node supabase/seed/fetch_processed_food.mjs <processed.ndjson>
//   node supabase/seed/load_processed_food.mjs <processed.ndjson> <출력 폴더> [파일당 행 수, 기본 5000] [--only-lv3=대분류,…]
//   for f in <출력 폴더>/processed_food_*.sql; do npx --yes supabase@2 db query --linked -f "$f" || break; done
//
// 규칙(docs/02 §10 D63)
//  - 끼니로 먹는 대분류(KEEP_LV3)만 넣는다. 식용유지류·장류·주류 등은 뺀다. kcal 이 없는 행도 뺀다.
//    절임류·조미식품은 소분류만 골라 넣는다(D66, KEEP_LV4): 김치·단무지/피클·장아찌·기타 조림·절임식품(김칫속·과·채당절임 빼고),
//    카레 전부, 기타 소스류 중 이름이 짜장·카레·하이라이스·덮밥 소스인 것(READY_SAUCE). 나머지 소스·식초·드레싱·향신료 등은 뺀다.
//  - 같은 상품(공백을 뺀 이름 + 제조사)은 데이터생성일자가 가장 최근인 행 하나만.
//  - 포장이 5,000(g·ml, kg·L 은 1,000배)을 넘는 업소용·대용량은 뺀다. kcal 0 은 음료·차·커피·생수·탄산과 제로·무설탕 이름만 남긴다.
//  - 이름의 중량·용량 표기('(70g)' · ' 2kg' · '-450g')는 떼고 저장·중복 판단한다.
//  - 1개 = 포장 전체(식품중량이 1회 섭취참고량의 2배 이하) → 1회 섭취참고량
//    → 포장 전체(500 이하이고 포장 전체 700 kcal 이하) → 기준량(100g·ml).
//    kcal·탄단지는 기준량당 값 × 1개 양 ÷ 기준량. 라벨은 '1개(40g)' · '1회분(30g)' · '100g'.
//  - food_code 는 식약처 상품 코드(P…), is_product = true 로 음식(D…) 자동 매칭과 나눈다.
//  - package_g = 포장 전체 양(식품중량의 g·ml 숫자, 읽을 수 없으면 null). 앱의 '몇 개입' 낱개 계산(D64)에 쓴다.
//  - 제조사가 '해당없음'·빈 값이면 수입업체, 그다음 유통업체를 maker 로 쓴다(중복 판단도 이 이름으로).
//  - --only-lv3=절임류 또는 조림류,조미식품 이면 그 대분류에서 나온 상품만 쓴다(전체와 같은 규칙·중복 제거 뒤 거름, 추가 적재용).
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

/** 대분류 전체가 아니라 소분류만 넣는 대분류(D66): 반찬으로 먹는 김치·절임·조림, 데워 먹는 카레 */
export const KEEP_LV4 = new Map([
  ['절임류 또는 조림류', new Set(['배추김치', '기타김치', '물김치', '단무지/피클', '장아찌', '기타 조림', '절임식품'])],
  ['조미식품', new Set(['카레'])],
]);

/** 조미식품/기타 소스류 중 바로 먹는 덮밥 소스(3분짜장 등)만: 이름으로 고른다 */
export const READY_SAUCE_LV3 = '조미식품';
export const READY_SAUCE_LV4 = '기타 소스류';
export const READY_SAUCE_NAME = /짜장|카레|하이라이스|덮밥\s*소스|짜장\s*소스/;

/** 넣을 분류인가: KEEP_LV3 전체, 또는 KEEP_LV4 의 소분류, 또는 이름이 맞는 기타 소스류 */
export function keepCategory(r) {
  if (KEEP_LV3.has(r.lv3)) return true;
  const lv4 = String(r.lv4 ?? '').trim();
  if (KEEP_LV4.get(r.lv3)?.has(lv4)) return true;
  return r.lv3 === READY_SAUCE_LV3 && lv4 === READY_SAUCE_LV4 && READY_SAUCE_NAME.test(String(r.name ?? ''));
}

/** 1회 섭취참고량이 없을 때 포장 전체를 1개로 보는 최대 양(g·ml)과 포장 전체 최대 kcal */
export const WHOLE_PACKAGE_MAX = 500;
export const WHOLE_PACKAGE_MAX_KCAL = 700;

/** 업소용·대용량: 포장이 이 양(g·ml)을 넘으면 넣지 않는다 */
export const BULK_MAX = 5000;

/** 포장이 1회 섭취참고량의 이 배수 이하면 포장 전체를 1개로 */
export const WHOLE_PACKAGE_RATIO = 2;

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

/** '30g' · '130ml' · '100ml(g)' · '100g(ml)' · '2kg' · '1.5L' → {value, unit(g·ml)}. kg·L 은 1,000배. 다른 꼴('1식', 분류 공통 문구)·0 은 null */
export function parseAmount(s) {
  const m = /^([0-9]+(?:\.[0-9]+)?)\s*(kg|g|ml|l|ℓ)(?:\s*\((?:g|ml)\))?$/i.exec(String(s ?? '').trim());
  if (!m || Number(m[1]) <= 0) return null;
  const u = m[2].toLowerCase();
  if (u === 'kg') return { value: Number(m[1]) * 1000, unit: 'g' };
  if (u === 'l' || u === 'ℓ') return { value: Number(m[1]) * 1000, unit: 'ml' };
  return { value: Number(m[1]), unit: u };
}

/** 이름 속 중량·용량 표기('(70g)' · ' 2kg' · '-450g' · ' 1.5L'). '100g당'처럼 글자가 붙으면 그대로 */
const AMOUNT_TOKEN = /[(\[]?\s*\d+(?:[.,]\d+)?\s*(?:kg|mg|g|그램|ml|㎖|l|ℓ|리터)(?![a-z가-힣])\s*[)\]]?/gi;
const TRAILING_AMOUNT = /\s*[-–]\s*\d+(?:[.,]\d+)?\s*(?:kg|mg|g|그램|ml|㎖|l|ℓ|리터)\s*$/i;

/** 저장·중복 판단용 이름: 중량·용량 표기를 떼고 공백을 하나로. 다 지워지면 원래 이름 */
export function cleanName(name) {
  const raw = String(name ?? '').trim();
  const s = raw.replace(TRAILING_AMOUNT, ' ').replace(AMOUNT_TOKEN, ' ').replace(/\s+/g, ' ').trim();
  return s || raw;
}

/** 0 kcal 이 맞을 수 있는 행: 음료류, 음료·차·커피·생수·탄산 소분류, 제로·무설탕 이름 */
const zeroOk = (r) => r.lv3 === '음료류' || /음료|다류|커피|생수|탄산/.test(r.lv4 ?? '') || /제로|zero|0\s*kcal|무설탕|슈가프리/i.test(String(r.name ?? ''));

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
  } else if (size && size.value <= WHOLE_PACKAGE_MAX && ((num(r.kcal) ?? 0) * size.value) / per.value <= WHOLE_PACKAGE_MAX_KCAL) {
    amount = size.value;
    label = `1개(${fmt(size.value)}${size.unit})`;
  } else {
    amount = per.value;
    label = `${fmt(per.value)}${per.unit}`;
  }
  const scale = (v) => (v === null ? null : r1((v * amount) / per.value));
  return { amount, label, kcal: scale(num(r.kcal)), carb: scale(num(r.carb)), prot: scale(num(r.prot)), fat: scale(num(r.fat)) };
}

/** NDJSON 행 → 상품 목록(분류·kcal 거르기, 이름+제조사 중복 제거, food_code 순).
 *  onlyLv3(대분류 집합)를 주면 전체와 똑같이 고른 뒤 그 대분류에서 나온 상품만 돌려준다(추가 적재용) */
export function pickProducts(rows, { onlyLv3 = null } = {}) {
  const skipped = { category: 0, noKcal: 0, bulk: 0, zero: 0, duplicate: 0 };
  const best = new Map();
  for (const r of rows) {
    if (!keepCategory(r)) { skipped.category++; continue; }
    if (num(r.kcal) === null) { skipped.noKcal++; continue; }
    if ((parseAmount(r.size)?.value ?? 0) > BULK_MAX) { skipped.bulk++; continue; }
    if (num(r.kcal) === 0 && !zeroOk(r)) { skipped.zero++; continue; }
    const key = `${cleanName(r.name).replace(/\s+/g, '')}\u0000${makerOf(r) ?? ''}`;
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
    .filter((r) => !onlyLv3 || onlyLv3.has(r.lv3))
    .sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0))
    .map((r) => {
      const u = unitOf(r);
      return {
        food_code: r.code, name_kr: cleanName(r.name), category: (r.lv4 || '').trim() || r.lv3, serving_g: u.amount, kcal: u.kcal,
        carb_g: u.carb, protein_g: u.prot, fat_g: u.fat, maker: makerOf(r), unit_label: u.label,
        package_g: parseAmount(r.size)?.value ?? null,
      };
    });
  return { products, skipped };
}

/** 남길 행: 원래 대분류(KEEP_LV3) 행이 다시 넣은 소분류(D66) 행보다 먼저, 그다음 데이터생성일자가 더 최근(같으면 코드가 큰 행).
 *  다시 넣은 행이 이미 적재된 같은 상품(이름+제조사)을 밀어내지 않아야 추가 적재(--only-lv3)가 전체 적재와 같다 */
function newer(a, b) {
  const ka = KEEP_LV3.has(a.lv3), kb = KEEP_LV3.has(b.lv3);
  if (ka !== kb) return ka;
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

/** CLI 의 --only-lv3=a,b 값 → 대분류 집합(없으면 null). 모르는 대분류면 오류 */
export function onlyLv3Arg(args) {
  const a = args.find((x) => x.startsWith('--only-lv3='));
  if (!a) return null;
  const names = a.slice('--only-lv3='.length).split(',').map((x) => x.trim()).filter(Boolean);
  const known = new Set([...KEEP_LV3, ...KEEP_LV4.keys(), READY_SAUCE_LV3]);
  const bad = names.filter((x) => !known.has(x));
  if (!names.length || bad.length) throw new Error(`--only-lv3 에 넣는 대분류가 아니에요: ${bad.join(', ') || '(빈 값)'}`);
  return new Set(names);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const [path, outDir, rowsArg] = args.filter((x) => !x.startsWith('--'));
  if (!path || !outDir) {
    console.error('사용법: node supabase/seed/load_processed_food.mjs <processed.ndjson> <출력 폴더> [파일당 행 수, 기본 5000] [--only-lv3=대분류,…]');
    process.exit(1);
  }
  const onlyLv3 = onlyLv3Arg(args);
  const rows = await readNdjson(path);
  const { products, skipped } = pickProducts(rows, { onlyLv3 });
  mkdirSync(outDir, { recursive: true });
  const chunks = chunkSql(products, chunkSizeArg(rowsArg));
  chunks.forEach((sql, i) => writeFileSync(join(outDir, `processed_food_${String(i + 1).padStart(3, '0')}.sql`), sql));
  console.error(`읽은 행 ${rows.length} · 상품 ${products.length}건 · 파일 ${chunks.length}개 · 건너뜀 ${JSON.stringify(skipped)}`);
}
