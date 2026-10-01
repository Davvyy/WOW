// supabase/seed.sql 생성기. 입력은 프로토타입과 같은 원천 값(걸음·끼니·세션)만 넣고,
// 점수(BMR·A·I·D·S)는 seed.sql 끝에서 SQL 배치 함수(run_finalize·compute_daily_score)가 계산한다.
// 원천: prototype/data.js (CHALLENGE·ME·TODAY_MEALS·LEDGER_INPUT·WATCH_*), prototype/console.html (PEOPLE_RAW·genLedger·QUEUE·HEALTH_ALERTS)
// 사용: node supabase/seed/generate_seed.mjs > supabase/seed.sql
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = path.dirname(fileURLToPath(import.meta.url));
const ctx = { globalThis: {} };
vm.createContext(ctx);
vm.runInContext(readFileSync(path.join(here, '../../prototype/data.js'), 'utf8')
  .replace("typeof window !== 'undefined' ? window : globalThis", 'globalThis'), ctx);
const { CHALLENGE, ME, TODAY_MEALS, WATCH_USER, WATCH_ACTIVITY, WATCH_MEALS, LUNCH_DRAFT } = ctx.globalThis.CHALLORY;

const uuid = (s) => {
  const h = createHash('md5').update('challory:' + s).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const q = (v) => (v === null || v === undefined ? 'null' : typeof v === 'number' || typeof v === 'boolean' ? String(v) : `'${String(v).replace(/'/g, "''")}'`);
const j = (o) => `${q(JSON.stringify(o))}::jsonb`;
const out = [];
const emit = (s) => out.push(s);

const START = CHALLENGE.start; // 2026-10-06
const dateOf = (d) => { const t = new Date(START + 'T00:00:00Z'); t.setUTCDate(t.getUTCDate() + d - 1); return t.toISOString().slice(0, 10); };
const DAYS = 8; // D1~D8 (10.6~10.13), 오늘 = D8

// ---- data.js LEDGER_INPUT (data.js 안의 비공개 상수와 같은 값) ----
const c = (k, ai) => ({ status: 'confirmed', kcal: k, aiKcal: ai });
const ME_LEDGER = [
  { d: 1, steps: 9480, meals: [c(430), c(720), c(610)] },
  { d: 2, steps: 11200, meals: [c(400), c(810), c(590)] },
  { d: 3, steps: 9200, meals: [null, c(780), c(650)] },
  { d: 4, steps: 10806, meals: [c(410), c(690), c(460)] },
  { d: 5, steps: 12321, meals: [c(430), c(780, 850), c(410)] }, // 점심 850→780 확정(본인)
  { d: 6, steps: 9000, meals: [c(300), c(480), c(370)] },
  { d: 7, steps: 10898, meals: [c(420), c(780), c(600)] },      // 저녁 사진 중복 → R-0415(미결)
  { d: 8, steps: 9000, meals: TODAY_MEALS.map(m => c(m.kcal, m.aiKcal)) },
];

// ---- console.html PEOPLE_RAW / genLedger (같은 결정적 생성식) ----
const PEOPLE_RAW = [
  { name: '달려라하니', sex: 'F', birthYear: 1992, heightCm: 165, weightKg: 57, source: 'Apple 건강', badge: 'watch', baseSteps: 12400, spikeDay: 7, spikeSteps: 28400, mealScale: 0.8, warns: 0, mealsToday: 3, ios: true },
  { name: '강남콩', sex: 'M', birthYear: 1990, heightCm: 178, weightKg: 76, source: '삼성헬스', baseSteps: 11800, warns: 0, mealsToday: 3 },
  { name: WATCH_USER.nickname, sex: WATCH_USER.sex, birthYear: WATCH_USER.birthYear, heightCm: WATCH_USER.heightCm, weightKg: WATCH_USER.weightKg, badge: 'watch', baseSteps: 11500, lowIntakeDays: [4, 5, 6], warns: 0, mealsToday: 3, ios: true },
  { name: ME.nickname, sex: ME.sex, birthYear: ME.birthYear, heightCm: ME.heightCm, weightKg: ME.weightKg, baseSteps: 9000, warns: 0, mealsToday: 3, me: true },
  { name: '오이냉국', sex: 'F', birthYear: 1988, heightCm: 160, weightKg: 62, baseSteps: 7600, warns: 2, mealsToday: 2, noAi: true },
  { name: '초록이', sex: 'M', birthYear: 1999, heightCm: 172, weightKg: 68, baseSteps: 10200, warns: 0, mealsToday: 3, ios: true },
  { name: '라떼한잔', sex: 'F', birthYear: 1995, heightCm: 158, weightKg: 54, baseSteps: 6900, zeroFrom: 8, warns: 0, mealsToday: 1 },
  { name: '마포구민', sex: 'M', birthYear: 1985, heightCm: 174, weightKg: 80, baseSteps: 8400, warns: 1, mealsToday: 2 },
  { name: '야근요정', sex: 'F', birthYear: 1993, heightCm: 162, weightKg: 55, baseSteps: 7200, zeroFrom: 8, warns: 0, mealsToday: 2 },
  { name: '새벽커피', sex: 'F', birthYear: 2001, heightCm: 167, weightKg: 49, baseSteps: 6800, record: 'bmi', warns: 0, mealsToday: 3, ios: true },
  { name: '한강러너', sex: 'M', birthYear: 1997, heightCm: 180, weightKg: 73, baseSteps: 13100, zeroFrom: 7, warns: 0, mealsToday: 0 },
  { name: '도토리', sex: 'M', birthYear: 1994, heightCm: 170, weightKg: 66, baseSteps: 11300, warns: 0, mealsToday: 3 },
];
function genLedger(p, i) {
  if (p.me) return ME_LEDGER.map(r => ({ d: r.d, steps: r.steps, sessions: [], meals: r.meals }));
  const rows = [];
  for (let d = 1; d <= DAYS; d++) {
    let steps = Math.round(p.baseSteps * (0.86 + ((i * 7 + d * 13) % 9) / 32) / 10) * 10;
    if (p.spikeDay === d) steps = p.spikeSteps;
    if (p.zeroFrom && d >= p.zeroFrom) steps = null; // 미동기화
    let sessions = [];
    const kc = [360 + ((i * 3 + d * 5) % 6) * 20, 640 + ((i * 5 + d * 7) % 8) * 25, 500 + ((i * 2 + d * 11) % 7) * 20];
    let meals = kc.map(k => c(k));
    if (p.mealScale) meals = meals.map(m => c(Math.round(m.kcal * p.mealScale / 10) * 10));
    if (p.lowIntakeDays && p.lowIntakeDays.includes(d)) meals = meals.map(m => c(Math.round(m.kcal * 0.55 / 10) * 10));
    if (d === 8) meals = meals.map((m, si) => (si < p.mealsToday ? m : null));
    if (p.name === WATCH_USER.nickname && d === 8) { // 예시 2(72.1)
      steps = WATCH_ACTIVITY.stepsTotal; sessions = WATCH_ACTIVITY.sessions; meals = WATCH_MEALS.map(m => c(m.kcal));
    }
    rows.push({ d, steps, sessions, meals });
  }
  return rows;
}

// ---- 계정·챌린지 ----
const OP = uuid('user:민호');
const CH = uuid('challenge:가을 걷기 챌린지');
const DEFAULT_MD = '## 운영자 추가 규칙\n- 회식 날(10.17)은 저녁 자동 확정 대신 대체값 적용을 요청할 수 있어요(운영자에게 메시지).\n- 상품은 상위 3명 + 반영률 100% 달성자 추첨 2명.';
emit(`-- 생성 파일: node supabase/seed/generate_seed.mjs > supabase/seed.sql (직접 수정하지 말 것)
-- 프로토타입 예시: ${CHALLENGE.name} ${CHALLENGE.start}~${CHALLENGE.end}, 오늘 ${CHALLENGE.today}(D+${CHALLENGE.dayIndex}).
-- 원천 값만 넣고 점수는 끝의 배치 함수가 계산한다. 10.12 지수 저녁(사진 중복)은 판정 전(R-0415 미결) 상태.
begin;
set local session_replication_role = default;
insert into auth.users (id, email) values (${q(OP)}, 'minho@example.com') on conflict do nothing;
insert into users (id, provider, nickname, is_operator) values (${q(OP)}, 'kakao', '민호', true) on conflict do nothing;
insert into challenges (id, name, status, start_date, end_date, capacity, invite_code, rules_md, operator_id)
values (${q(CH)}, ${q(CHALLENGE.name)}, 'checking', ${q(CHALLENGE.start)}, ${q(CHALLENGE.end)}, ${CHALLENGE.capacity}, ${q(CHALLENGE.code)}, ${q(DEFAULT_MD)}, ${q(OP)});
insert into challenge_rules (challenge_id, locked_at) values (${q(CH)}, '${CHALLENGE.start} 00:00+09');
`);

// ---- 음식 DB(예시 값) — 실제 식약처 15100070 적재는 supabase/README.md 참조 ----
const FOODS = [
  ['D000001', '흰쌀밥', '밥류', 210, 310], ['D000002', '현미밥', '밥류', 210, 300], ['D000003', '잡곡밥', '밥류', 210, 305],
  ['D000010', '김치찌개', '찌개류', 400, 260], ['D000011', '부대찌개', '찌개류', 400, 480], ['D000012', '된장찌개', '찌개류', 400, 170],
  ['D000020', '계란말이', '반찬류', 60, 90], ['D000021', '계란찜', '반찬류', 100, 80], ['D000022', '계란후라이', '반찬류', 50, 95],
  ['D000030', '멸치볶음', '반찬류', 12, 20], ['D000031', '진미채볶음', '반찬류', 12, 30], ['D000032', '건새우볶음', '반찬류', 12, 25],
  ['D000040', '배추김치', '김치류', 15, 10], ['D000041', '총각김치', '김치류', 15, 12], ['D000042', '깍두기', '김치류', 15, 12],
  ['D000050', '김', '반찬류', 5, 70], ['D000051', '조미김', '반찬류', 5, 70], ['D000052', '김부각', '반찬류', 20, 120],
  ['D000060', '곰탕', '국·탕류', 600, 330], ['D000062', '갈비탕', '국·탕류', 600, 420],
  ['D000070', '김밥', '밥류', 230, 420], ['D000071', '비빔밥', '밥류', 450, 600], ['D000072', '짜장면', '면류', 650, 790],
  ['D000080', '계란토스트', '빵류', 150, 320], ['D000081', '바나나', '과일류', 120, 100], ['D000082', '닭가슴살 샐러드', '샐러드류', 250, 380],
  ['D000083', '군고구마', '서류', 150, 220], ['D000084', '아메리카노', '음료류', 355, 10], ['D000085', '카페라떼', '음료류', 355, 180],
];
emit(`insert into food_db_cache (food_code, name_kr, category, serving_g, kcal) values\n${FOODS.map(f => `  (${f.map(q).join(', ')})`).join(',\n')};`);
const SYN = [['설렁탕', 'D000060'], ['사골곰탕', 'D000060'], ['공기밥', 'D000001'], ['쌀밥', 'D000001'], ['밥', 'D000001'], ['라떼', 'D000085'], ['커피', 'D000084'], ['계란 후라이', 'D000022'], ['달걀말이', 'D000020'], ['고구마', 'D000083']];
emit(`insert into food_synonyms (alias, food_code) values\n${SYN.map(s => `  (${s.map(q).join(', ')})`).join(',\n')};`);

// ---- 참가자·활동·끼니 ----
const SRC = { ios: { origin: 'com.apple.health', method: 'AUTOMATICALLY_RECORDED' }, android: { origin: 'com.sec.android.app.shealth', method: 'AUTOMATICALLY_RECORDED' } };
const SLOTS = ['breakfast', 'lunch', 'dinner'];
const TIMES = { breakfast: '07:40', lunch: '12:20', dinner: '19:05' };
const ids = {};
PEOPLE_RAW.forEach((p, i) => {
  const uid = uuid('user:' + p.name);
  const pid = uuid('participant:' + p.name);
  ids[p.name] = { uid, pid };
  const age = 2026 - p.birthYear;
  const rec = p.record || null;
  emit(`insert into auth.users (id) values (${q(uid)}) on conflict do nothing;
insert into users (id, provider, nickname) values (${q(uid)}, ${q(p.ios ? 'apple' : 'kakao')}, ${q(p.name)});
insert into profiles (user_id, sex, birth_year, height_cm, weight_kg, bmr_age, record_mode, record_mode_reason)
  values (${q(uid)}, ${q(p.sex)}, ${p.birthYear}, ${p.heightCm}, ${p.weightKg}, ${age}, ${!!rec}, ${q(rec)});
insert into consents (user_id, type, version) values (${q(uid)}, 'terms', 'v1'), (${q(uid)}, 'sensitive_health', 'v1')${p.noAi ? '' : `, (${q(uid)}, 'overseas_ai', 'v1')`};
insert into devices (user_id, platform, push_token, push_permission, app_version) values (${q(uid)}, ${q(p.ios ? 'ios' : 'android')}, ${q('demo-token-' + i)}, 'granted', '1.0.0');
insert into participants (id, challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, status, rank_eligible, warning_count, grade_badge, joined_at)
  values (${q(pid)}, ${q(CH)}, ${q(uid)}, ${q(p.name)}, ${q(p.sex)}, ${p.birthYear}, ${age}, ${p.heightCm}, ${p.weightKg},
    bmr_kcal(${q(p.sex)}, ${p.weightKg}, ${p.heightCm}, ${age}), ${q(rec ? 'record_mode' : 'active')}, ${!rec}, ${p.warns}, ${q(p.badge || null)}, '2026-10-03 10:00+09');`);
  const src = p.ios ? SRC.ios : SRC.android;
  for (const row of genLedger(p, i)) {
    const date = dateOf(row.d);
    if (row.steps !== null) {
      const syncAt = row.d === DAYS ? `${date} 21:10+09` : `${date} 23:30+09`;
      emit(`insert into daily_activity (participant_id, challenge_id, local_date, steps_total, steps_manual, floors, sources, synced_at)
  values (${q(pid)}, ${q(CH)}, ${q(date)}, ${row.steps}, ${p.ios ? 0 : 'null'}, null, ${j([{ ...src, steps: row.steps }])}, '${syncAt}');`);
    }
    for (const s of row.sessions) {
      const [hh, mm] = s.start.split(':').map(Number);
      const st = `${date} ${s.start}+09`;
      const endMin = hh * 60 + mm + s.minutes;
      const en = `${date} ${String(Math.floor(endMin / 60)).padStart(2, '0')}:${String(endMin % 60).padStart(2, '0')}+09`;
      emit(`insert into activity_sessions (participant_id, challenge_id, local_date, platform_uid, type, start_at, end_at, steps_in_range, distance_m, avg_speed_kmh, origin, recording_method)
  values (${q(pid)}, ${q(CH)}, ${q(date)}, ${q('hk:' + p.name + ':' + date)}, 'running', '${st}', '${en}', ${s.steps}, ${s.kmh * 1000 * s.minutes / 60}, ${s.kmh}, 'com.apple.health.watch', 'AUTOMATICALLY_RECORDED');`);
    }
    row.meals.forEach((m, si) => {
      if (!m) return;
      const slot = SLOTS[si];
      const mid = uuid(`meal:${p.name}:${date}:${slot}`);
      const phid = uuid(`photo:${p.name}:${date}:${slot}`);
      // 지수 10.12 저녁은 10.10 저녁 사진과 같은 해시(사진 중복 → R-0415)
      const sha = p.me && row.d === 7 && slot === 'dinner' ? uuid(`sha:${p.name}:${dateOf(5)}:dinner`).replace(/-/g, '') : uuid(`sha:${p.name}:${date}:${slot}`).replace(/-/g, '');
      emit(`insert into photos (id, participant_id, challenge_id, storage_path, sha256, sha256_server, width, height, bytes, client_captured_at, server_received_at, verified_at)
  values (${q(phid)}, ${q(pid)}, ${q(CH)}, ${q(`${CH}/${pid}/${date}-${slot}.jpg`)}, ${q(sha)}, ${q(sha)}, 1568, 1176, 412000, '${date} ${TIMES[slot]}+09', '${date} ${TIMES[slot]}+09', '${date} ${TIMES[slot]}+09');
insert into meals (id, participant_id, challenge_id, local_date, slot, status, photo_id, engine, ai_kcal, confirmed_kcal, delta_ratio, captured_at, confirmed_at)
  values (${q(mid)}, ${q(pid)}, ${q(CH)}, ${q(date)}, ${q(slot)}, 'confirmed', ${q(phid)}, ${q(p.noAi ? 'none' : 'gemini')}, ${m.aiKcal ?? (p.noAi ? 'null' : m.kcal)}, ${m.kcal}, ${m.aiKcal ? (m.kcal / m.aiKcal).toFixed(4) : (p.noAi ? 'null' : 1)}, '${date} ${TIMES[slot]}+09', '${date} ${TIMES[slot]}+09');`);
    });
  }
});

// 지수 오늘 점심 항목(P7 초안 6항목 → 김 해제 후 780 확정)
const lunchId = uuid(`meal:${ME.nickname}:${dateOf(8)}:lunch`);
const FOOD_CODE = { 흰쌀밥: 'D000001', 김치찌개: 'D000010', 계란말이: 'D000020', 멸치볶음: 'D000030', 배추김치: 'D000040', 김: 'D000050' };
emit(`insert into meal_items (meal_id, name_candidates, chosen_name, food_code, input_type, count, portion_bucket, portion_multiplier, eaten, confidence, match_score, ai_kcal, confirmed_kcal) values
${LUNCH_DRAFT.items.map(it => `  (${q(lunchId)}, array[${it.candidates.map(q).join(', ')}], ${q(it.name)}, ${q(FOOD_CODE[it.name])}, 'ai', ${it.count || 1}, 'one', 1.0, ${!it.defaultUnchecked}, ${q(it.confidence === 'sure' ? 'high' : 'mid')}, 0.9, ${it.kcalPer * (it.count || 1)}, ${it.kcalPer * (it.count || 1)})`).join(',\n')};`);

// ---- 검토 큐(console.html QUEUE) ----
const ji = ids[ME.nickname], hani = ids['달려라하니'], oi = ids['오이냉국'];
const R0412 = uuid('review:R-0412'), R0415 = uuid('review:R-0415'), R0417 = uuid('review:R-0417');
emit(`insert into reviews (id, challenge_id, participant_id, type, local_date, target, status, reason_template, notified_at, sla_due_at, created_at) values
  (${q(R0412)}, ${q(CH)}, ${q(hani.pid)}, 'steps_spike', '2026-10-12', ${j({ key: '2026-10-12', steps: 28400, code: 'R-0412' })}, 'appealed', 'steps_spike', '2026-10-13 09:00+09', '2026-10-16 09:00+09', '2026-10-13 09:00+09'),
  (${q(R0415)}, ${q(CH)}, ${q(ji.pid)}, 'dup_photo', '2026-10-12', ${j({ key: uuid(`meal:${ME.nickname}:${dateOf(7)}:dinner`), meal_id: uuid(`meal:${ME.nickname}:${dateOf(7)}:dinner`), code: 'R-0415' })}, 'open', 'dup_photo', '2026-10-13 09:00+09', '2026-10-16 09:00+09', '2026-10-13 09:00+09'),
  (${q(R0417)}, ${q(CH)}, ${q(oi.pid)}, 'report', '2026-10-13', ${j({ slot: 'lunch', meal_id: uuid(`meal:오이냉국:${dateOf(8)}:lunch`), code: 'R-0417' })}, 'open', null, '2026-10-13 13:41+09', '2026-10-16 13:41+09', '2026-10-13 13:41+09');
insert into review_reporters (review_id, reporter_participant_id, reason) values (${q(R0417)}, ${q(ids['도토리'].pid)}, '10.13 점심 사진이 음식이 아니라 메뉴판 사진 같아요. 확인 부탁드려요.');
insert into appeals (review_id, participant_id, text, created_at) values (${q(R0412)}, ${q(hani.pid)}, '10.12에 하프마라톤 대회(21.1 km)에 나갔어요. 워치에서 운동으로 기록된 2시간 3분 세션 화면을 함께 보내요. 평소보다 많이 걸은 날이 맞아요.', '2026-10-13 08:12+09');
insert into participant_notes (participant_id, challenge_id, operator_note) values (${q(ids['라떼한잔'].pid)}, ${q(CH)}, '10.12 밤부터 동기화 없음 · 카톡 안내 예정');`);

// ---- 점수 계산: 날짜별 확정 배치 재생(D1~D7) + 오늘(D8) 잠정 ----
emit(`-- D+1 09:00 확정 배치를 날짜 순서대로 재생한다(점검 기간 마지막 날 기준선 중앙값 포함)
select run_finalize('${dateOf(2)} 09:00+09');
select run_finalize('${dateOf(3)} 09:00+09');
select run_finalize('${dateOf(4)} 09:00+09');
update challenges set status = 'running' where id = ${q(CH)};
${[5, 6, 7, 8].map(d => `select run_finalize('${dateOf(d)} 09:00+09');`).join('\n')}
select compute_daily_score(id, '${dateOf(8)}', 'provisional') from participants where challenge_id = ${q(CH)};
select build_leaderboard(${q(CH)}, 'today', '${dateOf(8)}', false, '${dateOf(8)} 21:00+09');
select build_leaderboard(${q(CH)}, 'cumulative', '${dateOf(8)}', false, '${dateOf(8)} 21:00+09');
insert into health_alerts (participant_id, challenge_id, type, local_date, detail) values
  (${q(ids[WATCH_USER.nickname].pid)}, ${q(CH)}, 'low_intake_3d', '2026-10-11', ${j({ from: '2026-10-09', to: '2026-10-11', nudge_at: '2026-10-12 09:10' })}),
  (${q(ids['강남콩'].pid)}, ${q(CH)}, 'high_activity_3d', '2026-10-12', ${j({ from: '2026-10-10', to: '2026-10-12', nudge_at: '2026-10-13 09:10' })});
insert into cheers (challenge_id, from_participant_id, to_participant_id, local_date) values (${q(CH)}, ${q(ji.pid)}, ${q(ids[WATCH_USER.nickname].pid)}, '${dateOf(8)}');
commit;`);

console.log(out.join('\n'));
