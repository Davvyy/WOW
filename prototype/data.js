/* =====================================================================
   챌로리(Challory) 프로토타입 — 단일 데이터 소스 + 점수 엔진
   근거: docs/04-칼로리-엔진-및-순위-규칙.md (§2 BMR, §3 소비, §4 섭취, §5 산식)
   모든 화면(P1~P12, OP1~OP4)은 이 파일의 ENGINE/DATA만 읽는다.
   BMR·M·F·A·I·D·S 는 하드코딩하지 않는다.
   ===================================================================== */
(function (global) {
  'use strict';

  // ---------- 엔진 상수 (04 §5.2, 챌린지 공통·시작 후 잠금) ----------
  const CONST = {
    T: 500,            // 일일 목표 순적자 kcal → 100점
    C: 1000,           // 활동 칼로리 상한 (=2T)
    S_MAX: 150,        // 점수 상한
    F_MIN: 1200,       // 섭취 하한 절대값
    F_RATIO: 0.8,      // 섭취 하한 = max(F_MIN, F_RATIO×BMR)
    M_MIN: 700,        // 미기록 끼니 대체값 절대값
    M_RATIO: 0.45,     // 대체값 = max(M_MIN, M_RATIO×BMR)
    AUTO_CONFIRM: 1.3, // 미확정 AI 초안 자동 확정 = max(M, 1.3×AI)
    SNACK_KCAL: 150,   // 150 kcal 미만은 간식 (슬롯 미충족, I_d에는 합산)
    STEPS_CAP: 30000,
    FLOORS_CAP: 50,
    SKIP_PER_DAY: 1,
    SKIP_PER_WEEK: 3,
    MET_WALK: 3.8,     // 2024 Compendium 17190 고정
    MET_STAIR: 6.8,    // 17131
    SEC_PER_FLOOR: 17.5,
    RUN_MET_TIERS: [   // km/h 하한 → MET
      { minKmh: 12.9, met: 12.0 },
      { minKmh: 9.7, met: 9.3 },
      { minKmh: 8.0, met: 8.5 },
      { minKmh: 0, met: 7.5 },
    ],
    FINALIZE_HOUR: '09:00',
    EDIT_WINDOW_H: 48,
    APPEAL_H: 72,
    CHECK_DAYS: 3,
    NUDGE_MIN: { M: 1500, F: 1200 }, // 건강 안내 임계 (산식과 분리)
  };

  const round1 = (x) => Math.round(x * 10) / 10;
  const round10 = (x) => Math.round(x / 10) * 10; // 10 kcal 단위 half-up (양수)
  const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

  const ENGINE = {
    CONST, round1, round10, clamp,

    // §2 Mifflin-St Jeor. sex: 'M' | 'F'
    bmr({ sex, weightKg, heightCm, age }) {
      const raw = 10 * weightKg + 6.25 * heightCm - 5 * age + (sex === 'M' ? 5 : -161);
      return { raw, bmr: round10(raw) };
    },
    // 연도만 수집(02 §3-2). BMR 나이 = 시작 연도 − 출생 연도(04 §2 예1: 1996 → 30).
    ageOnDate(birthYear, dateStr) { return parseInt(dateStr.slice(0, 4), 10) - birthYear; },
    // 만 14세 자격 판정은 해당 연도 12월 31일생으로 보수 적용(06 P2 [제안])
    ageConservative(birthYear, dateStr) { return parseInt(dateStr.slice(0, 4), 10) - birthYear - 1; },
    M(bmr) { return Math.max(CONST.M_MIN, CONST.M_RATIO * bmr); },
    F(bmr) { return Math.max(CONST.F_MIN, CONST.F_RATIO * bmr); },

    // §3.2 세션 창 밖 걸음 → net kcal
    stepsNet(stepsOut, weightKg) {
      const s = Math.min(stepsOut, CONST.STEPS_CAP);
      return s * (CONST.MET_WALK - 1) * weightKg / 6000;
    },
    kcalPerStep(weightKg) { return (CONST.MET_WALK - 1) * weightKg / 6000; },
    runMet(kmh) { return CONST.RUN_MET_TIERS.find(t => kmh >= t.minKmh).met; },
    // §3.3 세션 net
    sessionNet(met, weightKg, hours) { return (met - 1) * weightKg * hours; },
    // §3.4 층수 보너스
    floorsBonus(floors, weightKg) {
      return Math.min(floors, CONST.FLOORS_CAP) * (CONST.MET_STAIR - 1) * weightKg * CONST.SEC_PER_FLOOR / 3600;
    },
    // A_d = min(걸음 net + 세션 net + 층수, C)
    activity({ weightKg, stepsTotal = 0, sessions = [], floors = 0 }) {
      const sessionSteps = sessions.reduce((a, s) => a + (s.steps || 0), 0);
      const stepsOut = Math.max(0, stepsTotal - sessionSteps);
      const steps = this.stepsNet(stepsOut, weightKg);
      const sess = sessions.reduce((a, s) => a + this.sessionNet(s.met, weightKg, s.minutes / 60), 0);
      const fl = floors > 0 ? this.floorsBonus(floors, weightKg) : 0;
      const raw = steps + sess + fl;
      return { stepsOut, stepsNet: round1(steps), sessionNet: round1(sess), floorsBonus: round1(fl), raw: round1(raw), A: round1(Math.min(raw, CONST.C)), capped: raw > CONST.C };
    },

    // §4.3 섭취 I_d: meals = [{slot:'breakfast'|'lunch'|'dinner'|'snack', status, kcal, aiKcal}]
    // status: confirmed | draft | captured | failed | skipped | auto | void | empty
    intake({ bmr, meals, provisional = true, skipsUsedThisWeek = 0 }) {
      const M = this.M(bmr);
      const mains = ['breakfast', 'lunch', 'dinner'];
      let I = 0, confirmedMeals = 0, snacks = 0, substitutedSlots = [], draftSlots = [], pendingSlots = [], skipsToday = 0, skipOver = false;
      for (const slot of mains) {
        const m = meals.find(x => x.slot === slot);
        if (!m || m.status === 'empty') { I += M; substitutedSlots.push(slot); continue; }
        if (m.status === 'skipped') { // 건너뜀 한도: 1일 1회 · 주 3회, 초과분은 대체값 (04 §4.3)
          if (skipsToday < CONST.SKIP_PER_DAY && skipsUsedThisWeek + skipsToday < CONST.SKIP_PER_WEEK) { skipsToday++; continue; }
          I += M; substitutedSlots.push(slot); skipOver = true; continue;
        }
        if (m.status === 'void') { I += M; substitutedSlots.push(slot); continue; }
        if (m.status === 'confirmed' || m.status === 'auto') {
          if (m.kcal >= CONST.SNACK_KCAL) { I += m.kcal; confirmedMeals++; }
          else { I += m.kcal + M; substitutedSlots.push(slot); snacks++; } // 간식 수준 확정 → 슬롯 미충족
          continue;
        }
        if (m.status === 'draft') { // 미확정 AI 초안 → max(M, 1.3×AI), 항상 ≥ M 이라 끼니 슬롯 충족 (04 §4.3)
          const v = Math.max(M, CONST.AUTO_CONFIRM * (m.aiKcal || 0));
          I += v; confirmedMeals++; draftSlots.push({ slot, value: v }); continue;
        }
        // captured / failed (분석 없음, 확정 대기) → M 으로 잠정 계산
        I += M; pendingSlots.push(slot);
      }
      for (const m of meals.filter(x => x.slot === 'snack' && (x.status === 'confirmed' || x.status === 'auto'))) { I += m.kcal; snacks++; }
      return { I: round1(I), M, confirmedMeals, snacks, substitutedSlots, draftSlots, pendingSlots, skipsToday, skipOver };
    },

    // §5.1 D_d, S_d
    score({ bmr, A, I, confirmedMeals }) {
      const F = this.F(bmr);
      const Ieff = Math.max(I, F);
      const D = bmr + Math.min(A, CONST.C) - Ieff;
      let S = 100 * clamp(D / CONST.T, 0, CONST.S_MAX / 100);
      if (confirmedMeals === 0) S = 0;
      return { F, floorApplied: I < F, D: round1(D), S: round1(S), ratio: clamp(D / CONST.T, 0, 1.5) };
    },

    // 하루 전체 계산 (P5·P10·P11·OP1 시뮬레이터 공용 = /simulate)
    simulate({ profile, stepsTotal, sessions = [], floors = 0, meals }) {
      const { bmr } = this.bmr(profile);
      const act = this.activity({ weightKg: profile.weightKg, stepsTotal, sessions, floors });
      const inn = this.intake({ bmr, meals });
      const sc = this.score({ bmr, A: act.A, I: inn.I, confirmedMeals: inn.confirmedMeals });
      return { bmr, act, inn, sc, E: round1(bmr + act.A) };
    },
  };

  // ---------- 숫자 포맷 ----------
  const fmt = {
    int: (n) => Math.round(n).toLocaleString('ko-KR'),
    kcal: (n) => Math.round(n).toLocaleString('ko-KR'),
    k1: (n) => (Math.round(n * 10) / 10).toLocaleString('ko-KR', { minimumFractionDigits: 1, maximumFractionDigits: 1 }),
    signed: (n) => (n > 0 ? '+' : n < 0 ? '−' : '') + Math.abs(Math.round(n)).toLocaleString('ko-KR'),
    pct: (r) => Math.round(r * 100) + '%',
    k2: (n) => n.toLocaleString('ko-KR', { maximumFractionDigits: 2 }),
  };

  // ---------- 예시 데이터 (단일 소스) ----------
  const CHALLENGE = {
    name: '가을 걷기 챌린지', code: 'K7Q2MD',
    start: '2026-10-06', end: '2026-11-02', days: 28,
    capacity: 60, joined: 42,
    today: '2026-10-13', dayIndex: 8, // D+8
    syncTime: '21:10', source: '삼성헬스', platform: 'Health Connect',
    finalizeAt: '11.3 09:00', objectionUntil: '11.10',
    notice: { title: '최종 결과는 11.3 09:00에 확정돼요', body: '마지막 날(11.2) 기록은 11.3 09:00에 확정되고, 운영자 확인 뒤 같은 날 발표돼요. 이의 기간은 11.10까지예요.', date: '10.12' },
  };

  const ME = {
    nickname: '지수', sex: 'M', birthYear: 1996, heightCm: 175, weightKg: 70,
    device: 'Galaxy', source: '삼성헬스',
  };
  ME.age = ENGINE.ageOnDate(ME.birthYear, CHALLENGE.start); // 30
  const meBmr = ENGINE.bmr({ sex: ME.sex, weightKg: ME.weightKg, heightCm: ME.heightCm, age: ME.age });
  ME.bmrRaw = meBmr.raw; ME.bmr = meBmr.bmr; ME.M = ENGINE.M(ME.bmr); ME.F = ENGINE.F(ME.bmr);
  ME.kcalPerStep = ENGINE.kcalPerStep(ME.weightKg);

  // 오늘(D+8) 식사 — P7 기본 변형은 점심을 "초안 780"으로 보여주고, P5 기본은 3끼 확정
  const TODAY_MEALS = [
    { slot: 'breakfast', label: '아침', time: '07:40', status: 'confirmed', kcal: 420, aiKcal: 450, title: '계란토스트 · 바나나', items: ['계란토스트 1개 320', '바나나 1개 100'] },
    { slot: 'lunch', label: '점심', time: '12:20', status: 'confirmed', kcal: 780, aiKcal: 850, title: '김치찌개 백반', items: ['흰쌀밥 1공기 310', '김치찌개 1인분 260', '계란말이 2조각 180', '멸치볶음 1젓가락 20', '배추김치 1젓가락 10'] }, // AI 초안 850(김 1봉 70 포함) → 김 해제 후 780 확정
    { slot: 'dinner', label: '저녁', time: '19:05', status: 'confirmed', kcal: 600, aiKcal: 640, title: '닭가슴살 샐러드 · 고구마', items: ['닭가슴살 샐러드 1인분 380', '군고구마 1개 220'] },
  ];

  // P7 점심 AI 초안 항목 (04 §4.1 JSON → 식약처 DB 매핑 결과)
  const LUNCH_DRAFT = {
    slot: 'lunch', label: '점심', time: '12:20', photoLabel: '김치찌개 백반 사진', aiTotal: 850, // 6항목 합 = 850, 사용자가 김을 해제하면 780
    items: [
      { id: 'rice', name: '흰쌀밥', candidates: ['흰쌀밥', '현미밥', '잡곡밥'], candKcal: [310, 300, 305], portion: '1공기', grams: 210, mult: 1, kcalPer: 310, kind: 'rice', confidence: 'sure' },
      { id: 'stew', name: '김치찌개', candidates: ['김치찌개', '부대찌개', '된장찌개'], candKcal: [260, 480, 170], portion: '1인분', grams: 400, mult: 1, kcalPer: 260, kind: 'soup', broth: true, confidence: 'sure' },
      { id: 'egg', name: '계란말이', candidates: ['계란말이', '계란찜', '계란후라이'], candKcal: [90, 80, 95], portion: '조각', count: 2, mult: 1, kcalPer: 90, kind: 'count', confidence: 'check' },
      { id: 'anch', name: '멸치볶음', candidates: ['멸치볶음', '진미채볶음', '건새우볶음'], candKcal: [20, 30, 25], portion: '1젓가락', grams: 12, mult: 1, kcalPer: 20, kind: 'side', confidence: 'sure' },
      { id: 'kimchi', name: '배추김치', candidates: ['배추김치', '총각김치', '깍두기'], candKcal: [10, 12, 12], portion: '1젓가락', grams: 15, mult: 1, kcalPer: 10, kind: 'side', confidence: 'sure' },
      { id: 'gim', name: '김', candidates: ['김', '조미김', '김부각'], candKcal: [70, 70, 120], portion: '1봉', grams: 5, mult: 1, kcalPer: 70, kind: 'side', confidence: 'sure', defaultUnchecked: true }, // 실제로는 먹지 않은 항목 → 기본 해제
    ],
  };

  // 오늘 활동 (Galaxy·삼성헬스, 세션 없음, 층수 없음)
  const TODAY_ACTIVITY = { stepsTotal: 9000, stepsRecorded: 9000, sessions: [], floors: 0 };
  // iPhone 변형: 기록 9,340 중 수동 입력 340 미인정 → 검증 9,000
  const TODAY_ACTIVITY_IOS = { stepsTotal: 9000, stepsRecorded: 9340, stepsManual: 340, sessions: [], floors: 0, platformActive: 310 };

  // 워치 예시 참가자 (02 §5 예시 2, 04 §6 예2) — 밤산책
  const WATCH_USER = { nickname: '밤산책', sex: 'F', birthYear: 1996, heightCm: 163, weightKg: 58, device: 'iPhone + Apple Watch', source: 'Apple 건강' };
  WATCH_USER.age = ENGINE.ageOnDate(WATCH_USER.birthYear, CHALLENGE.start);
  WATCH_USER.bmr = ENGINE.bmr(WATCH_USER).bmr;
  const WATCH_ACTIVITY = { stepsTotal: 12000, sessions: [{ type: 'run', label: '달리기', minutes: 30, kmh: 9, met: ENGINE.runMet(9), steps: 4500, start: '06:30', source: 'Apple Watch' }], floors: 0, platformActive: 380 };
  const WATCH_MEALS = [{ slot: 'breakfast', status: 'confirmed', kcal: 380 }, { slot: 'lunch', status: 'confirmed', kcal: 520 }, { slot: 'dinner', status: 'confirmed', kcal: 450 }];

  // 오늘 계산 (지수)
  const TODAY = ENGINE.simulate({ profile: ME, stepsTotal: TODAY_ACTIVITY.stepsTotal, sessions: [], floors: 0, meals: TODAY_MEALS });
  // 검토 시나리오(걸음 26,000 > 25,000 플래그) — P5·P8·P9·P10 review 변형 공용
  const REVIEW_CASE = { steps: 26000 };
  const REVIEW_TODAY = ENGINE.simulate({ profile: ME, stepsTotal: REVIEW_CASE.steps, sessions: [], floors: 0, meals: TODAY_MEALS });
  const WATCH_TODAY = ENGINE.simulate({ profile: WATCH_USER, stepsTotal: WATCH_ACTIVITY.stepsTotal, sessions: WATCH_ACTIVITY.sessions, floors: 0, meals: WATCH_MEALS });

  // ---------- 점수 장부 D1~D8 (10.6~10.13) ----------
  // 각 날의 입력만 적고, 결과는 엔진으로 계산한다. D1~D3은 점검 기간(누적 미반영).
  const LEDGER_INPUT = [
    { d: 1, date: '10.6', steps: 9480, meals: [c(430), c(720), c(610)], note: '점검 기간' },
    { d: 2, date: '10.7', steps: 11200, meals: [c(400), c(810), c(590)], note: '점검 기간' },
    { d: 3, date: '10.8', steps: 9200, meals: [empty(), c(780), c(650)], note: '점검 기간 · 아침 미기록' },
    { d: 4, date: '10.9', steps: 10806, meals: [c(410), c(690), c(460)] },
    { d: 5, date: '10.10', steps: 12321, meals: [c(430), c(780), c(410)], history: '점심 850→780 확정(본인)' },
    { d: 6, date: '10.11', steps: 9000, meals: [c(300), c(480), c(370)], health: true },
    { d: 7, date: '10.12', steps: 10898, meals: [c(420), c(780), c(600)], revision: { reason: 'dup_photo', slot: 'dinner', after: [c(420), c(780), voidMeal()] } },
    { d: 8, date: '10.13', steps: 9000, meals: TODAY_MEALS, provisional: true },
  ];
  function c(k) { return { status: 'confirmed', kcal: k }; }
  function empty() { return { status: 'empty' }; }
  function voidMeal() { return { status: 'void' }; }
  function withSlots(meals) { return meals.map((m, i) => Object.assign({ slot: ['breakfast', 'lunch', 'dinner'][i] }, m)); }

  const LEDGER = LEDGER_INPUT.map(row => {
    const meals = row.meals[0].slot ? row.meals : withSlots(row.meals);
    const r = ENGINE.simulate({ profile: ME, stepsTotal: row.steps, meals });
    const out = { d: row.d, date: row.date, steps: row.steps, A: r.act.A, I: r.inn.I, D: r.sc.D, S: r.sc.S, F: r.sc.F,
      floorApplied: r.sc.floorApplied, substituted: r.inn.substitutedSlots, check: row.d <= CONST.CHECK_DAYS, provisional: !!row.provisional,
      note: row.note || '', history: row.history || '', health: !!row.health, bmr: r.bmr };
    if (row.revision) {
      const r2 = ENGINE.simulate({ profile: ME, stepsTotal: row.steps, meals: withSlots(row.revision.after) });
      out.revision = { reason: row.revision.reason, slot: row.revision.slot, before: r.sc.S, after: r2.sc.S, I_after: r2.inn.I, D_after: r2.sc.D };
      out.S_before = r.sc.S; out.S = r2.sc.S; out.I = r2.inn.I; out.D = r2.sc.D; out.substituted = r2.inn.substitutedSlots;
    }
    return out;
  });
  const CUMULATIVE = round1(LEDGER.filter(x => !x.check && !x.provisional).reduce((a, x) => a + x.S, 0)); // 확정분만
  const TODAY_ROW = LEDGER[LEDGER.length - 1];

  // ---------- 리더보드 ----------
  const LEADERBOARD = {
    total: 42,
    cumulative: [
      { rank: 1, name: '달려라하니', score: 486.2, fill: 4, badge: 'watch' },
      { rank: 2, name: '강남콩', score: 451.0, fill: 4 },
      { rank: 3, name: '밤산책', score: 388.7, fill: 4, badge: 'watch' },
      { rank: 4, name: ME.nickname, score: CUMULATIVE, fill: 4, me: true, delta: 2 },
      { rank: 5, name: '오이냉국', score: 301.9, fill: 3, tie: true },
      { rank: 5, name: '새벽러닝', score: 301.9, fill: 4, tie: true },
      { rank: 7, name: '집계 중', score: null, fill: 0, aggregating: true },
      { rank: 8, name: '라떼한잔', score: 268.4, fill: 2 },
      { rank: 9, name: '마포구민', score: 251.0, fill: 3 },
      { rank: 10, name: '야근요정', score: 236.5, fill: 3 },
    ],
    today: [
      { rank: 1, name: '강남콩', score: 118.4, fill: 4 },
      { rank: 2, name: '밤산책', score: WATCH_TODAY.sc.S, fill: 4, badge: 'watch' },
      { rank: 3, name: '초록이', score: 64.0, fill: 4 },
      { rank: 4, name: '달려라하니', score: 58.2, fill: 3, badge: 'watch' },
      { rank: 5, name: '오이냉국', score: 51.6, fill: 3 },
      { rank: 6, name: '집계 중', score: null, fill: 0, aggregating: true },
      { rank: 17, name: ME.nickname, score: TODAY_ROW.S, fill: 4, me: true, delta: 0, gapToPrev: 3.2 },
    ],
  };
  // 주간 피드백: 점검 기간 뒤 확정된 날(D4~D7)로 계산
  const WEEK_ROWS = LEDGER.filter(x => !x.check && !x.provisional);
  LEADERBOARD.weekly = { days: WEEK_ROWS.length, avg: round1(WEEK_ROWS.reduce((a, x) => a + x.S, 0) / WEEK_ROWS.length), dinnerConfirmRate: WEEK_ROWS.filter(x => !x.substituted.includes('dinner')).length / WEEK_ROWS.length };

  // ---------- 최종 결과 (Published 변형, 11.3 발표) ----------
  const FINAL = {
    list: [
      { rank: 1, name: '달려라하니', score: 1310.4, fill: 4 },
      { rank: 2, name: '강남콩', score: 1254.0, fill: 4 },
      { rank: 3, name: '밤산책', score: 1102.7, fill: 4 },
      { rank: 4, name: ME.nickname, score: 1041.3, fill: 4, me: true },
      { rank: 5, name: '초록이', score: 988.0, fill: 4 },
    ],
  };
  FINAL.me = FINAL.list.find(x => x.me);

  // ---------- 알림·판정 템플릿 (06 §6) ----------
  const REASON = {
    steps_spike: '걸음 기록이 평소보다 크게 높아 확인했어요',
    source_unknown: '확인되지 않은 출처의 운동 기록이 있었어요',
    dup_photo: '같은 사진이 두 번 이상 사용됐어요',
    downward_edit: '확정값이 AI 추정보다 절반 넘게 낮았어요',
    skip_abuse: "'건너뜀'이 한도를 넘었어요",
  };
  const VERDICT = {
    approve: { label: '승인', text: '확인이 끝났어요', effect: '점수 변동 없음' },
    warn: { label: '경고', text: '이번은 경고 {n}/3이에요', effect: '점수 변동 없음' },
    void: { label: '무효', text: '{대체 처리}로 다시 계산했어요', effect: '{날짜} {전}→{후}점 · 누적 {차액}' },
    exclude: { label: '순위 제외', text: '경고가 3회 누적되어 이번 챌린지 순위에서 빠졌어요', effect: '점수와 기록은 계속 볼 수 있어요' },
    expired: { label: '소명 기간 만료', text: '설명 기간이 지나 기록으로만 확인했어요', effect: '' },
  };

  global.CHALLORY = { ENGINE, CONST, fmt, CHALLENGE, ME, TODAY, FINAL, REVIEW_CASE, REVIEW_TODAY, TODAY_MEALS, LUNCH_DRAFT, TODAY_ACTIVITY, TODAY_ACTIVITY_IOS,
    WATCH_USER, WATCH_ACTIVITY, WATCH_MEALS, WATCH_TODAY, LEDGER, CUMULATIVE, TODAY_ROW, LEADERBOARD, REASON, VERDICT };
})(typeof window !== 'undefined' ? window : globalThis);
