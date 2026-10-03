// node --test supabase/seed/
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { aliasesFor, parseCsv, pickFoods, toSql } from './load_food_db.mjs';

const HEADER = '식품코드,식품명,식품기원명,식품대분류명,영양성분함량기준량,에너지(kcal),단백질(g),지방(g),탄수화물(g),식품중량';
const csv = (...rows) => parseCsv([HEADER, ...rows].join('\n'));
const byName = (foods) => new Map(foods.map((f) => [f.name_kr, f]));

test('1인분 kcal·탄단지는 기준량당 값 × 식품중량 ÷ 기준량', () => {
  const { foods } = pickFoods(csv('D1,김밥,가정식(분석 함량),밥류,100g,140,4.83,4.57,20,230g'));
  assert.deepEqual(
    { serving_g: foods[0].serving_g, kcal: foods[0].kcal, protein_g: foods[0].protein_g, fat_g: foods[0].fat_g, carb_g: foods[0].carb_g },
    { serving_g: 230, kcal: 322, protein_g: 11.1, fat_g: 10.5, carb_g: 46 },
  );
});

test('같은 이름은 실제 분량(100g·ml 아님)이 있는 행을 먼저, 그 안에서 실측·성인 기원 순', () => {
  const { foods } = pickFoods(csv(
    'D301,비빔밥,외식(분석함량),밥류,100g,142,4.5,3.8,22.5,100g',
    'D401,비빔밥,외식(재료량 기반 산출함량),밥류,100ml,133,5,3,20,530ml',
    'D501,비빔밥,초등학교급식(재료량 기반 산출 함량),밥류,100ml,204,6,4,30,222.48ml',
  ));
  assert.equal(byName(foods).get('비빔밥').food_code, 'D401');
});

test('모든 행이 100g 뿐이면 100g 을 1인분으로 둔다', () => {
  const { foods } = pickFoods(csv('D9,현미죽,외식(분석함량),죽 및 스프류,100g,70,2,1,13,100g'));
  assert.equal(foods[0].serving_g, 100);
});

test('프랜차이즈·간편조리세트·식품중량 없는 행은 뺀다', () => {
  const { foods, skipped } = pickFoods(csv(
    'F1,커피_아메리카노,외식(프랜차이즈 등 업체 제공 영양정보),음료 및 차류,100g,4,0,0,1,473g',
    'K1,피자_간편조리세트_치즈피자,외식(분석함량),빵 및 과자류,100g,250,10,10,30,728g',
    'N1,된장국,가정식(분석 함량),국 및 탕류,100g,30,2,1,3,',
  ));
  assert.equal(foods.length, 0);
  assert.deepEqual({ franchise: skipped.franchise, mealKit: skipped.mealKit, noWeight: skipped.noWeight }, { franchise: 1, mealKit: 1, noWeight: 1 });
});

test('두 단계 이름 A_B 동의어: B 가 A 로 끝나면 B, 아니면 B+A. 세 단계 이상·이미 있는 음식 이름은 만들지 않음', () => {
  const names = new Set(['김밥_참치', '국밥_순대국밥', '삼각김밥_숯불갈비', '흑미밥_찹쌀', '김치찌개', '찌개_김치', '순두부찌개_해물_매운']);
  assert.deepEqual(aliasesFor('김밥_참치', names), ['참치김밥']);
  assert.deepEqual(aliasesFor('국밥_순대국밥', names), ['순대국밥']);
  assert.deepEqual(aliasesFor('삼각김밥_숯불갈비', names), ['숯불갈비삼각김밥']);
  assert.deepEqual(aliasesFor('찌개_김치', names), []); // '김치찌개' 가 이미 음식 이름
  assert.deepEqual(aliasesFor('순두부찌개_해물_매운', names), []);
  assert.deepEqual(aliasesFor('김치찌개', names), []);
});

test('쌀밥은 외식(분석) 100g당 값 × 한 공기 210g, 공기밥·흰쌀밥·흰밥·밥 동의어', () => {
  const { foods, synonyms } = pickFoods(csv(
    'D501,쌀밥,초등학교급식(재료량 기반 산출 함량),밥류,100ml,120,2,0.3,27,250ml',
    'D301,쌀밥,외식(분석함량),밥류,100g,166,3.4,0.3,37.3,100g',
    'D601,쌀밥,중고등학교급식(재료량 기반 산출함량),밥류,100ml,120,2,0.3,27,450ml',
  ));
  const rice = byName(foods).get('쌀밥');
  assert.deepEqual({ code: rice.food_code, serving_g: rice.serving_g, kcal: rice.kcal }, { code: 'D301', serving_g: 210, kcal: 348.6 });
  assert.deepEqual(synonyms.filter((s) => s.food_code === 'D301').map((s) => s.alias).sort(), ['공기밥', '밥', '흰밥', '흰쌀밥'].sort());
});

test('SQL: 예시 음식 삭제 → 음식 upsert → 동의어 추가, 작은따옴표 이스케이프', () => {
  const { foods, synonyms } = pickFoods(csv("D1,김밥_참치,가정식(분석 함량),밥류,100g,150,5,5,20,230g", "D2,아귀'찜,외식(분석함량),찜류,100g,90,10,2,5,300g"));
  const sql = toSql(foods, synonyms);
  assert.ok(sql.indexOf("delete from food_db_cache where food_code ~ '^D[0-9]{6}$'") < sql.indexOf('insert into food_db_cache'));
  assert.ok(sql.indexOf('insert into food_db_cache') < sql.indexOf('insert into food_synonyms'));
  assert.match(sql, /'아귀''찜'/);
  assert.match(sql, /\('참치김밥', 'D1'\)/);
});
