// 공공데이터포털 「전국통합식품영양성분정보(가공식품)표준데이터」 API(15100066) 전체를 받아 필요한 열만 NDJSON 으로 저장한다.
//
//   DATA_GO_KR_KEY=<인코딩 키> node supabase/seed/fetch_processed_food.mjs <processed.ndjson>
//
// - 키는 환경변수 DATA_GO_KR_KEY 에서만 읽고 출력하지 않는다(저장소에 키 파일을 두지 말 것).
// - 1,000건씩 페이지별 파일(<출력>.pages/p0001.ndjson …)로 받아 끊겨도 이어 받고, 다 받으면 <출력> 하나로 합친다.
// - 적재: node supabase/seed/load_processed_food.mjs <processed.ndjson> <출력 폴더>
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const out = process.argv[2];
const key = (process.env.DATA_GO_KR_KEY ?? '').trim();
if (!out || !key) {
  console.error('사용법: DATA_GO_KR_KEY=<인코딩 키> node supabase/seed/fetch_processed_food.mjs <processed.ndjson>');
  process.exit(1);
}
const dir = `${out}.pages`;
mkdirSync(dir, { recursive: true });
const rows = 1000;
const base = 'https://api.data.go.kr/openapi/tn_pubr_public_nutri_process_info_api';
const pick = (i) => ({
  code: i.foodCd, name: i.foodNm, lv3: i.foodLv3Nm, lv4: i.foodLv4Nm, lv6: i.foodLv6Nm, per: i.nutConSrtrQua, kcal: i.enerc,
  carb: i.chocdf, prot: i.prot, fat: i.fatce, serv: i.servSize, size: i.foodSize, mfr: i.mfrNm, dist: i.distNm, imp: i.imptNm,
  date: i.crtYmd,
});

async function page(n) {
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const res = await fetch(`${base}?serviceKey=${key}&pageNo=${n}&numOfRows=${rows}&type=json`, { signal: AbortSignal.timeout(120000) });
      const j = await res.json();
      if (j.header?.resultCode !== '00') throw new Error(`code ${j.header?.resultCode} ${j.header?.resultMsg}`);
      return j.body;
    } catch (e) {
      // 오류 문구에 요청 URL(키 포함)을 싣지 않는다
      console.error(`page ${n} attempt ${attempt}: ${String(e?.message ?? e).replaceAll(key, '***')}`);
      await new Promise((r) => setTimeout(r, 3000 * attempt));
    }
  }
  throw new Error(`page ${n} failed`);
}

const pageFile = (n) => join(dir, `p${String(n).padStart(4, '0')}.ndjson`);
const first = await page(1);
const pages = Math.ceil(first.totalCount / rows);
console.log(`total ${first.totalCount}, pages ${pages}`);
for (let n = 1; n <= pages; n++) {
  const f = pageFile(n);
  if (existsSync(f)) continue;
  const body = n === 1 ? first : await page(n);
  const items = body.items?.item ?? [];
  writeFileSync(f, items.map((i) => JSON.stringify(pick(i))).join('\n') + '\n');
  if (n % 25 === 0) console.log(`page ${n}/${pages}`);
}
const all = [];
for (let n = 1; n <= pages; n++) all.push(readFileSync(pageFile(n), 'utf8').replace(/\n+$/, ''));
writeFileSync(out, all.filter((s) => s).join('\n') + '\n');
console.log(`done → ${out}`);
