// node --test supabase/seed/
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  KEEP_LV3, READY_SAUCE_NAME, chunkSizeArg, chunkSql, cleanName, keepCategory, makerOf, onlyLv3Arg, parseAmount, pickProducts, unitOf,
} from './load_processed_food.mjs';

const row = (o) => ({
  code: 'P1', name: '칙촉', lv3: '과자류·빵류 또는 떡류', lv4: '비스킷/쿠키/크래커', lv6: '과자', per: '100g', kcal: '501',
  carb: '61.11', prot: '6.67', fat: '25.56', serv: '30g', size: '180g', mfr: '롯데웰푸드 주식회사', dist: '해당없음', imp: '해당없음',
  date: '2024-12-31', ...o,
});

test('1개 규칙: 큰 포장은 1회분, 1회분의 2배 이하 포장은 통째', () => {
  // 칙촉 180g, 1회분 30g, 501/100g → 1회분 30g = 150.3 kcal
  assert.deepEqual(unitOf(row({})), { amount: 30, label: '1회분(30g)', kcal: 150.3, carb: 18.3, prot: 2, fat: 7.7 });
  // 칙촉 브라우니 40g(1회분 30g) → 1개 40g = 190 kcal
  assert.deepEqual(unitOf(row({ name: '칙촉 브라우니', kcal: '475', size: '40g', carb: '55', prot: '7.5', fat: '25' })),
    { amount: 40, label: '1개(40g)', kcal: 190, carb: 22, prot: 3, fat: 10 });
  // 칙촉샌드아이스 130ml(1회분 100ml, 165/100ml) → 1개 130ml = 214.5 kcal
  const ice = unitOf(row({ name: '칙촉샌드아이스', per: '100ml', kcal: '165', serv: '100ml', size: '130ml' }));
  assert.deepEqual([ice.amount, ice.label, ice.kcal], [130, '1개(130ml)', 214.5]);
});

test('1개 규칙: 1회분이 없으면 500 이하 포장 통째, 아니면 기준량', () => {
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '75g', kcal: '400' }))), [75, '1개(75g)', 300]);
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '500ml', per: '100ml', kcal: '40' }))), [500, '1개(500ml)', 200]);
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '915g', kcal: '202' }))), [100, '100g', 202]);
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '', per: '100ml', kcal: '45' }))), [100, '100ml', 45]);
  // 분류 공통 문구(면류 '생·숙면 200g, …')·'1식' 은 1회분으로 읽지 않는다
  assert.deepEqual(pick(unitOf(row({ serv: '생·숙면 200g, 건면 100g, 당면 30g', size: '337g', kcal: '126' }))), [337, '1개(337g)', 424.6]);
  assert.deepEqual(pick(unitOf(row({ serv: '1식', size: '380g', kcal: '131' }))), [380, '1개(380g)', 497.8]);
  // 1회분 표기 'Nml(g)'·'Ng(ml)' 은 숫자와 앞 단위로 읽는다
  assert.deepEqual(pick(unitOf(row({ serv: '200ml(g)', size: '1000ml', per: '100ml', kcal: '60' }))), [200, '1회분(200ml)', 120]);
});

const pick = (u) => [u.amount, u.label, u.kcal];

test('수량 파싱: g·ml 숫자만', () => {
  assert.deepEqual(parseAmount('30g'), { value: 30, unit: 'g' });
  assert.deepEqual(parseAmount(' 12.5 ML '), { value: 12.5, unit: 'ml' });
  assert.deepEqual(parseAmount('100g(ml)'), { value: 100, unit: 'g' });
  assert.equal(parseAmount(''), null);
  assert.equal(parseAmount('1식'), null);
  assert.equal(parseAmount('0g'), null);
});

test('분류: 남길 대분류만, kcal 없는 행은 뺀다', () => {
  assert.equal(KEEP_LV3.size, 14);
  const { products, skipped } = pickProducts([
    row({ code: 'P1' }),
    row({ code: 'P2', name: '고추장', lv3: '장류' }),
    row({ code: 'P3', name: '참기름', lv3: '식용유지류' }),
    row({ code: 'P4', name: '맥주', lv3: '주류' }),
    row({ code: 'P5', name: '이온음료', lv3: '음료류', kcal: '' }),
    row({ code: 'P6', name: '두부', lv3: '두부류 또는 묵류' }),
  ]);
  assert.deepEqual(products.map((p) => p.food_code), ['P1', 'P6']);
  assert.deepEqual(skipped, { category: 3, noKcal: 1, bulk: 0, zero: 0, duplicate: 0 });
});

test('중복: 공백 뺀 이름 + 제조사가 같으면 데이터생성일자가 최근인 행 하나', () => {
  const { products, skipped } = pickProducts([
    row({ code: 'P10', name: '칙촉 말차', date: '2023-01-01', kcal: '450' }),
    row({ code: 'P11', name: '칙촉말차', date: '2026-03-18', kcal: '459' }),
    row({ code: 'P12', name: '칙촉 말차', date: '2024-05-05', kcal: '455' }),
    row({ code: 'P13', name: '칙촉 말차', mfr: '다른회사', date: '2020-01-01' }),
    row({ code: 'P13', name: '칙촉 말차', mfr: '다른회사', date: '2020-01-01' }), // 같은 행이 두 번(API 페이지 겹침)
  ]);
  assert.deepEqual(products.map((p) => [p.food_code, p.name_kr]), [['P11', '칙촉말차'], ['P13', '칙촉 말차']]);
  assert.equal(skipped.duplicate, 3);
});

test('상품 행: 분류는 lv4(없으면 lv3), 1개 값·제조사·라벨', () => {
  const { products } = pickProducts([row({ lv4: '' })]);
  assert.deepEqual(products[0], {
    food_code: 'P1', name_kr: '칙촉', category: '과자류·빵류 또는 떡류', serving_g: 30, kcal: 150.3, carb_g: 18.3, protein_g: 2, fat_g: 7.7,
    maker: '롯데웰푸드 주식회사', unit_label: '1회분(30g)', package_g: 180,
  });
  assert.equal(pickProducts([row({})]).products[0].category, '비스킷/쿠키/크래커');
});

test('SQL: 5,000건씩 나눈 upsert(is_product = true, 다시 돌려도 값만 갱신)', () => {
  const products = pickProducts(Array.from({ length: 12 }, (_, i) => row({ code: `P${String(i).padStart(3, '0')}`, name: `과자${i}`, mfr: "O'Neil" }))).products;
  const chunks = chunkSql(products, 5);
  assert.equal(chunks.length, 3);
  assert.equal((chunks[2].match(/\('P/g) ?? []).length, 2);
  assert.match(chunks[0], /^insert into food_db_cache \(food_code, name_kr, category, serving_g, kcal, carb_g, protein_g, fat_g, is_product, maker, unit_label, package_g\) values/);
  assert.match(chunks[0], /'O''Neil'/);
  assert.match(chunks[0], /, true, /);
  assert.match(chunks[0], /on conflict \(food_code\) do update set .*is_product = excluded\.is_product.*unit_label = excluded\.unit_label/s);
});

test("제조사가 '해당없음'·빈 값이면 수입업체, 그다음 유통업체, 모두 없으면 null", () => {
  assert.equal(makerOf(row({ mfr: '해당없음', imp: '(주)수입상사', dist: '유통사' })), '(주)수입상사');
  assert.equal(makerOf(row({ mfr: ' ', imp: '해당없음', dist: '유통사' })), '유통사');
  assert.equal(makerOf(row({ mfr: '해당없음', imp: '해당없음', dist: '해당없음' })), null);
  assert.equal(makerOf(row({})), '롯데웰푸드 주식회사');
  const { products } = pickProducts([
    row({ code: 'P1', name: '수입 과자', mfr: '해당없음', imp: '수입사A', date: '2024-01-01' }),
    row({ code: 'P2', name: '수입 과자', mfr: '해당없음', imp: '수입사B', date: '2025-01-01' }),
  ]);
  assert.deepEqual(products.map((p) => [p.food_code, p.maker]), [['P1', '수입사A'], ['P2', '수입사B']], '수입사가 다르면 다른 상품');
});

test('upsert 는 상품 행만 덮어쓴다(같은 코드의 음식 행은 그대로)', () => {
  const sql = chunkSql(pickProducts([row({})]).products)[0];
  assert.match(sql, /do update set [\s\S]*updated_at = now\(\)\s+where food_db_cache\.is_product;\s*$/);
});

test('파일당 행 수: 세 번째 인자(양의 정수), 없으면 5,000', () => {
  assert.equal(chunkSizeArg(undefined), 5000);
  assert.equal(chunkSizeArg('2000'), 2000);
  assert.throws(() => chunkSizeArg('0'));
  assert.throws(() => chunkSizeArg('abc'));
  assert.throws(() => chunkSizeArg('1.5'));
});

test('포장 전체 양(package_g): 식품중량(size)의 g·ml 숫자, 읽을 수 없으면 null', () => {
  const pg = (o) => pickProducts([row(o)]).products[0].package_g;
  assert.equal(pg({}), 180);
  assert.equal(pg({ size: '130ml', per: '100ml', serv: '100ml' }), 130);
  assert.equal(pg({ size: '100ml(g)' }), 100);
  assert.equal(pg({ size: '' }), null);
  assert.equal(pg({ size: '1식' }), null);
});

test('upsert 는 package_g 도 넣고 갱신한다(다시 돌리면 포장 양이 채워진다)', () => {
  const sql = chunkSql(pickProducts([row({})]).products)[0];
  assert.match(sql, /'1회분\(30g\)', 180\)/);
  assert.match(sql, /do update set [\s\S]*package_g = excluded\.package_g[\s\S]*where food_db_cache\.is_product;\s*$/);
  const none = chunkSql(pickProducts([row({ size: '' })]).products)[0];
  assert.match(none, /'1회분\(30g\)', null\)/);
});

test('1개 규칙: 포장이 1회분의 2배 이하면 통째(46g/30g → 1개), 넘으면 1회분(61g/30g)', () => {
  assert.deepEqual(pick(unitOf(row({ name: '홈런볼딸기', kcal: '543', serv: '30g', size: '46g' }))), [46, '1개(46g)', 249.8]);
  assert.deepEqual(pick(unitOf(row({ name: '홈런볼', kcal: '543', serv: '30g', size: '60g' }))), [60, '1개(60g)', 325.8]);
  assert.deepEqual(pick(unitOf(row({ name: '홈런볼', kcal: '543', serv: '30g', size: '61g' }))), [30, '1회분(30g)', 162.9]);
});

test('수량 파싱: kg·L 은 1,000배(g·ml)', () => {
  assert.deepEqual(parseAmount('2kg'), { value: 2000, unit: 'g' });
  assert.deepEqual(parseAmount('1.5L'), { value: 1500, unit: 'ml' });
  assert.deepEqual(parseAmount('1.8ℓ'), { value: 1800, unit: 'ml' });
  assert.equal(pickProducts([row({ size: '2kg', serv: '100g' })]).products[0].package_g, 2000);
});

test('대용량: 포장이 5,000(g·ml)을 넘으면 뺀다', () => {
  const { products, skipped } = pickProducts([
    row({ code: 'P1', size: '5kg' }),
    row({ code: 'P2', name: '대용량 과자', size: '5001g' }),
    row({ code: 'P3', name: '업소용 음료', lv3: '음료류', per: '100ml', size: '18L', serv: '200ml' }),
  ]);
  assert.deepEqual(products.map((p) => p.food_code), ['P1']);
  assert.equal(skipped.bulk, 2);
});

test('1회분이 없으면: 500 이하이고 포장 전체 700 kcal 이하일 때만 통째, 아니면 100g·100ml', () => {
  assert.deepEqual(pick(unitOf(row({ name: '링귀니', serv: '', size: '500g', kcal: '355' }))), [100, '100g', 355]);
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '200g', kcal: '400' }))), [100, '100g', 400]);
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '175g', kcal: '400' }))), [175, '1개(175g)', 700]);
  assert.deepEqual(pick(unitOf(row({ serv: '', size: '1L', per: '100ml', kcal: '40' }))), [100, '100ml', 40]);
});

test('0 kcal 행: 음료·차·커피·생수·탄산이나 제로·무설탕 이름만 남긴다', () => {
  const { products, skipped } = pickProducts([
    row({ code: 'P1', name: '쭈꾸미 볶음', lv3: '즉석식품류', lv4: '즉석조리식품', kcal: '0' }),
    row({ code: 'P2', name: '요거트 젤라또', lv3: '빙과류', lv4: '샤베트', kcal: '0.0' }),
    row({ code: 'P3', name: '콜라 제로', lv3: '음료류', lv4: '탄산음료', kcal: '0' }),
    row({ code: 'P4', name: '아메리카노', lv3: '농산가공식품류', lv4: '액상커피', kcal: '0' }),
    row({ code: 'P5', name: '죠스바 0kcal', lv3: '빙과류', lv4: '빙과', kcal: '0' }),
    row({ code: 'P6', name: '무설탕 젤리', lv3: '과자류·빵류 또는 떡류', lv4: '젤리', kcal: '0' }),
    row({ code: 'P7', name: 'ZERO 캔디', lv3: '과자류·빵류 또는 떡류', lv4: '사탕', kcal: '0' }),
  ]);
  assert.deepEqual(products.map((p) => p.food_code), ['P3', 'P4', 'P5', 'P6', 'P7']);
  assert.equal(skipped.zero, 2);
});

test('이름의 중량·용량 표기는 떼고 저장·중복 판단(지우면 빈 이름이면 원래 이름)', () => {
  assert.equal(cleanName('로즈봉봉(70g)'), '로즈봉봉');
  assert.equal(cleanName('취나물 듬뿍 소불고기 2kg'), '취나물 듬뿍 소불고기');
  assert.equal(cleanName('충샹풍미수좌병-450g'), '충샹풍미수좌병');
  assert.equal(cleanName('로즈 플레이버 터키쉬딜라이트 (125g)'), '로즈 플레이버 터키쉬딜라이트');
  assert.equal(cleanName('콜라 1.5L'), '콜라');
  assert.equal(cleanName('100g당 단백질바'), '100g당 단백질바');
  assert.equal(cleanName('1등급 한우 3겹살'), '1등급 한우 3겹살');
  assert.equal(cleanName('90g'), '90g');
  const { products, skipped } = pickProducts([
    row({ code: 'P1', name: '새우깡 90g', date: '2024-01-01' }),
    row({ code: 'P2', name: '새우깡', date: '2025-01-01' }),
    row({ code: 'P3', name: '로즈봉봉(70g)' }),
  ]);
  assert.deepEqual(products.map((p) => [p.food_code, p.name_kr]), [['P2', '새우깡'], ['P3', '로즈봉봉']]);
  assert.equal(skipped.duplicate, 1);
});

const PICKLE = '절임류 또는 조림류';
const SEASONING = '조미식품';
const codes = (rows, opt) => pickProducts(rows, opt).products.map((p) => p.food_code);

test('절임류 또는 조림류(D66): 김치·단무지/피클·장아찌·기타 조림·절임식품만, 김칫속·과·채당절임은 뺀다', () => {
  const kept = ['배추김치', '기타김치', '물김치', '단무지/피클', '장아찌', '기타 조림', '절임식품'];
  const dropped = ['김칫속', '과·채당절임'];
  const rows = [...kept, ...dropped].map((lv4, i) => row({ code: `P${i}`, name: `반찬${i}`, lv3: PICKLE, lv4, serv: '40g', size: '400g' }));
  assert.deepEqual(codes(rows), kept.map((_, i) => `P${i}`));
  for (const [i, lv4] of kept.entries()) assert.ok(keepCategory(rows[i]), lv4);
  for (const lv4 of dropped) assert.equal(keepCategory(row({ lv3: PICKLE, lv4 })), false, lv4);
  // 소분류 이름은 다른 대분류의 같은 이름으로 새지 않는다
  assert.equal(keepCategory(row({ lv3: '장류', lv4: '배추김치' })), false);
});

test('조미식품(D66): 카레 전부, 기타 소스류는 짜장·카레·하이라이스·덮밥 소스 이름만, 나머지 소분류는 이름과 무관하게 뺀다', () => {
  const rows = [
    row({ code: 'P1', name: '3분카레-A약간매운맛', lv3: SEASONING, lv4: '카레', serv: '', size: '200g', kcal: '85' }),
    row({ code: 'P2', name: '바몬드카레 고형', lv3: SEASONING, lv4: '카레' }),
    row({ code: 'P3', name: '3분짜장', lv3: SEASONING, lv4: '기타 소스류', serv: '', size: '200g', kcal: '108' }),
    row({ code: 'P4', name: '제육 덮밥소스', lv3: SEASONING, lv4: '기타 소스류' }),
    row({ code: 'P5', name: '데리야끼 소스', lv3: SEASONING, lv4: '기타 소스류' }),
    row({ code: 'P6', name: '카레가루', lv3: SEASONING, lv4: '향신료' }),
    row({ code: 'P7', name: '짜장 분말스프', lv3: SEASONING, lv4: '분말스프' }),
    ...['식초', '드레싱', '마요네즈', '토마토케첩', '고춧가루', '소금', '복합조미식품'].map((lv4, i) =>
      row({ code: `Q${i}`, name: `조미${i}`, lv3: SEASONING, lv4 })),
  ];
  assert.deepEqual(codes(rows), ['P1', 'P2', 'P3', 'P4']);
  // 다른 규칙도 그대로: 1회분 표기를 읽을 수 없으면 500 이하 포장 통째(3분카레 200g → 1개 170 kcal)
  const curry = pickProducts([rows[0]]).products[0];
  assert.deepEqual([curry.unit_label, curry.kcal, curry.category], ['1개(200g)', 170, '카레']);
});

test('덮밥 소스 이름(READY_SAUCE_NAME): 짜장·카레·하이라이스·덮밥 소스', () => {
  for (const n of ['3분짜장', '간짜장', '짜장 소스', '쇠고기카레', '하이라이스', '제육덮밥소스', '마파두부 덮밥 소스', '춘천식 닭갈비덮밥소스(순한맛)'])
    assert.match(n, READY_SAUCE_NAME, n);
  for (const n of ['데리야끼 소스', '스테이크소스', '간장 덮밥용 양념', '굴소스', '덮밥', '불고기 양념'])
    assert.doesNotMatch(n, READY_SAUCE_NAME, n);
});

test('다시 넣은 소분류에도 기존 규칙: 대용량·0 kcal·중량 표기·중복', () => {
  const { products, skipped } = pickProducts([
    row({ code: 'P1', name: '포기김치 10kg', lv3: PICKLE, lv4: '배추김치', size: '10kg', serv: '40g' }),
    row({ code: 'P2', name: '백김치(500g)', lv3: PICKLE, lv4: '배추김치', size: '500g', serv: '40g', kcal: '15', date: '2024-01-01' }),
    row({ code: 'P3', name: '백김치', lv3: PICKLE, lv4: '배추김치', size: '500g', serv: '40g', kcal: '15', date: '2025-01-01' }),
    row({ code: 'P4', name: '단무지', lv3: PICKLE, lv4: '단무지/피클', kcal: '0' }),
  ]);
  assert.deepEqual(products.map((p) => [p.food_code, p.name_kr, p.unit_label, p.kcal]), [['P3', '백김치', '1회분(40g)', 6]]);
  assert.deepEqual([skipped.bulk, skipped.duplicate, skipped.zero], [1, 1, 1]);
});

test('같은 상품이 원래 대분류에도 있으면 원래 행을 남긴다(더 최근이어도 다시 넣은 행이 밀어내지 않음)', () => {
  const rows = [
    row({ code: 'P123-1', name: '볶음김치', lv3: '즉석식품류', lv4: '반찬', mfr: '다림식품', date: '2020-01-01' }),
    row({ code: 'P114-1', name: '볶음김치', lv3: PICKLE, lv4: '배추김치', mfr: '다림식품', date: '2025-01-01' }),
  ];
  assert.deepEqual(codes(rows), ['P123-1']);
});

test('--only-lv3: 전체와 같게 고른 뒤 그 대분류 상품만(전체 = 원래 대분류 + 추가분)', () => {
  const rows = [
    row({ code: 'P1' }),
    row({ code: 'P2', name: '비비고 포기 배추김치', lv3: PICKLE, lv4: '배추김치' }),
    row({ code: 'P3', name: '3분카레', lv3: SEASONING, lv4: '카레' }),
    row({ code: 'P4', name: '볶음김치', lv3: '즉석식품류', lv4: '반찬', mfr: '다림식품', date: '2020-01-01' }),
    row({ code: 'P5', name: '볶음김치', lv3: PICKLE, lv4: '배추김치', mfr: '다림식품', date: '2025-01-01' }),
    row({ code: 'P6', name: '간장소스', lv3: SEASONING, lv4: '기타 소스류' }),
  ];
  const only = onlyLv3Arg(['a.ndjson', 'out', '2000', `--only-lv3=${PICKLE},${SEASONING}`]);
  assert.deepEqual([...only], [PICKLE, SEASONING]);
  assert.deepEqual(codes(rows, { onlyLv3: only }), ['P2', 'P3']);
  assert.deepEqual(codes(rows), ['P1', 'P2', 'P3', 'P4']);
  assert.equal(onlyLv3Arg(['a', 'b']), null);
  assert.throws(() => onlyLv3Arg(['--only-lv3=장류']));
  assert.throws(() => onlyLv3Arg(['--only-lv3=']));
});
