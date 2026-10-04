// node --test supabase/seed/match_audit_test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AUDIT, BRAND_MAKERS, auditSql, candidatesOf, makerFragments, makerKey, makerMatches, norm, parseRows, scoreAll, scoreRow } from './match_audit.mjs';

test('norm: SQL food_name_norm 과 같은 정규화(전각·기호·대소문자)', () => {
  assert.equal(norm('２％ 부족할 때'), '2부족할때');
  assert.equal(norm('Maxim 에스프레소 T.O.P [블랙]-1_2/3,4'), 'maxim에스프레소top블랙1234');
  assert.equal(norm('㈜오뚜기'), '주오뚜기');
});

test('목록: 약 200개, 이름 중복 없음, 브랜드 키는 별칭 표에 있거나 직접 적은 조각', () => {
  assert.ok(AUDIT.length >= 200 && AUDIT.length <= 240, `항목 ${AUDIT.length}개`);
  assert.equal(new Set(AUDIT.map((e) => e[0])).size, AUDIT.length);
  for (const [q, want, mk] of AUDIT) {
    assert.ok(want && mk, q);
    assert.ok(makerFragments(mk).every((f) => f.length > 0), q);
  }
  assert.deepEqual(makerFragments('CJ'), ['씨제이', 'cj']);
  assert.deepEqual(makerFragments('웅진|삼양패키징'), ['웅진', '삼양패키징']);
  assert.ok(BRAND_MAKERS.하겐다즈.includes('HAAGEN'));
});

test('SQL: 읽기 전용 select, 따옴표 이스케이프, --json 은 한 행 JSON', () => {
  const sql = auditSql([["롯데 칙촉", '칙촉', '롯데'], ["it's", 'x', 'y']]);
  assert.match(sql, /^select /);
  assert.match(sql, /\(1, 'it''s', array\['it''s'\]\)/);
  assert.match(sql, /\(0, '롯데 칙촉', array\['롯데 칙촉', '칙촉'\]\)/);
  assert.match(sql, /map_food_candidates\(x\.c, true\)/);
  assert.doesNotMatch(sql, /\b(insert|update|delete|create|drop|alter)\b/i);
  assert.match(auditSql(AUDIT, { json: true }), /^select json_build_object\('rows'/);
});

test('parseRows: db query 안내 줄이 앞에 있어도 읽는다', () => {
  assert.deepEqual(parseRows('Initialising login role...\n{"rows":[{"i":0}]}'), [{ i: 0 }]);
  assert.deepEqual(parseRows('{"rows":[]}'), []);
});

const row = (o) => ({ i: 0, mt: 'auto', food_code: 'P1', is_product: true, serving_g: 30, kcal: 150, unit_label: '1회분(30g)', ...o });

test('채점: 이름·제조사(별칭, 공백·대소문자 무시)', () => {
  assert.equal(scoreRow(['롯데 칙촉', '칙촉', '롯데'], row({ name_kr: '칙촉', maker: '롯데웰푸드(주)' })).ok, true);
  assert.equal(scoreRow(['하겐다즈 바닐라', '바닐라', '하겐다즈'], row({ name_kr: '바닐라 미니컵', maker: 'Haagen-Dazs Arras' })).ok, true);
  const wrongMaker = scoreRow(['롯데 수박바', '수박바', '롯데'], row({ name_kr: '우리쌀 수박바', maker: '영영베이커리&푸드' }));
  assert.equal(wrongMaker.ok, false);
  assert.equal(wrongMaker.nameOk, true);
  assert.equal(wrongMaker.makerOk, false);
  assert.equal(scoreRow(['x', 'x', 'y'], undefined).ok, false);
});

test('채점: unit ml · kcal 점검 · 없는 상품', () => {
  const powder = row({ name_kr: '스타벅스 카페라테', maker: 'NESTLE UK', unit_label: '100g', serving_g: 100, kcal: 429 });
  assert.equal(scoreRow(['스타벅스 카페라떼', '라떼|라테', '스타벅스', { unit: 'ml' }], powder).ok, false);
  const rtd = row({ name_kr: '스타벅스 카페라떼', maker: '동서식품(주)', unit_label: '1개(320ml)', serving_g: 320, kcal: 179 });
  assert.equal(scoreRow(['스타벅스 카페라떼', '라떼|라테', '스타벅스', { unit: 'ml' }], rtd).ok, true);
  assert.equal(scoreRow(['a', 'a', 'b'], row({ name_kr: 'a', maker: 'b', kcal: 400, serving_g: 30 })).kcalOk, false);
  assert.equal(scoreRow(['a', 'a', 'b'], row({ name_kr: 'a', maker: 'b', kcal: 0, serving_g: 30 })).kcalOk, false);
  const absent = ['오리온 썬칩', '썬칩', '오리온', { absent: true }];
  assert.equal(scoreRow(absent, row({ mt: 'none', food_code: null })).ok, true);
  assert.equal(scoreRow(absent, row({ is_product: false, name_kr: '감자칩', maker: null })).ok, true);
  assert.equal(scoreRow(absent, row({ mt: 'chips', name_kr: '썬칩 하비스트', maker: 'FRITO-LAY' })).ok, true);
  assert.equal(scoreRow(absent, row({ mt: 'auto', name_kr: '썬칩 하비스트', maker: 'FRITO-LAY' })).ok, false);
  assert.equal(scoreRow(absent, row({ mt: 'chips', name_kr: '오리온 카스타드', maker: '(주)오리온' })).ok, false);
});

test('scoreAll: 통과율과 틀린 항목', () => {
  const entries = [['롯데 칙촉', '칙촉', '롯데'], ['농심 새우깡', '새우깡', '농심']];
  const s = scoreAll([row({ i: 0, name_kr: '칙촉', maker: '롯데제과(주)' }), row({ i: 1, name_kr: '양파링', maker: '(주)농심' })], entries);
  assert.equal(s.pass, 1);
  assert.equal(s.rate, 50);
  assert.deepEqual(s.misses.map((m) => m.q), ['농심 새우깡']);
});

test('후보 이름: AI 처럼 [이름, 첫 낱말을 뗀 이름]', () => {
  assert.deepEqual(candidatesOf('동서 맥심 티오피'), ['동서 맥심 티오피', '맥심 티오피']);
  assert.deepEqual(candidatesOf('레드불'), ['레드불']);
});

test('제조사: SQL 과 같게 2글자 조각은 앞글자만, 3글자 이상은 이름 안', () => {
  assert.equal(makerKey('농업회사법인(주)동서웰빙'), '동서웰빙');
  assert.equal(makerMatches('롯데웰푸드(주)', ['롯데']), true);
  assert.equal(makerMatches('크리스피크림롯데김해아울렛점', ['롯데']), false);
  assert.equal(makerMatches('현대상회', ['대상']), false);
  assert.equal(makerMatches('THE HERSHEY COMPANY', ['hershey']), true);
  assert.equal(makerMatches(null, ['롯데']), false);
});

test('채점: 이름 조각 끝의 $ 는 끝맺음', () => {
  assert.equal(scoreRow(['비비고 김치', '김치$', 'CJ'], row({ name_kr: '비비고 김치찌개', maker: '씨제이제일제당(주)' })).ok, false);
  assert.equal(scoreRow(['비비고 김치', '김치$', 'CJ'], row({ name_kr: '비비고 포기배추김치', maker: '씨제이제일제당(주)' })).ok, true);
});

test('scoreAll: 자동 비율과 틀린 자동', () => {
  const entries = [['롯데 칙촉', '칙촉', '롯데'], ['농심 새우깡', '새우깡', '농심'], ['오리온 투유', '투유', '오리온']];
  const s = scoreAll([row({ i: 0, name_kr: '칙촉', maker: '롯데제과(주)' }), row({ i: 1, name_kr: '양파링', maker: '(주)농심' }),
    row({ i: 2, mt: 'chips', name_kr: '투유', maker: '(주)오리온' })], entries);
  assert.equal(s.auto, 2);
  assert.equal(s.autoRate, 66.7);
  assert.equal(s.autoWrong, 1);
});
