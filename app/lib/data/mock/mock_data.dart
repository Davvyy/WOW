// prototype/data.js 의 예시 데이터 포팅. BMR·M·F·A·I·D·S 는 하드코딩하지 않고 엔진으로 계산한다.
import '../../core/engine/engine.dart';
import '../models.dart';

const engine = ChalloryEngine();

final mockChallenge = ChallengeInfo(
  name: '가을 걷기 챌린지',
  code: 'K7Q2MD',
  start: DateTime(2026, 10, 6),
  end: DateTime(2026, 11, 2),
  days: 28,
  capacity: 60,
  joined: 42,
  today: DateTime(2026, 10, 13),
  dayIndex: 8,
  syncTime: '21:10',
  source: '삼성헬스',
  platform: 'Health Connect',
  noticeTitle: '최종 결과는 11.3 09:00에 확정돼요',
  noticeBody: '마지막 날(11.2) 기록은 11.3 09:00에 확정되고, 운영자 확인 뒤 같은 날 발표돼요. 이의 기간은 11.10까지예요.',
  noticeDate: '10.12',
  objectionUntil: '11.10',
);

MeInfo _buildMe() {
  const sex = Sex.m;
  const birthYear = 1996;
  const h = 175.0;
  const w = 70.0;
  final age = ChalloryEngine.ageOnDate(birthYear, mockChallenge.start); // 30
  final b = ChalloryEngine.bmr(Profile(sex: sex, weightKg: w, heightCm: h, age: age));
  return MeInfo(nickname: '지수', sex: sex, birthYear: birthYear, heightCm: h, weightKg: w, age: age, bmr: b.bmr, bmrRaw: b.raw);
}

final mockMe = _buildMe();

/// 같은 BMR 에서 파생되는 값(엔진 호출)
double get meM => engine.m(mockMe.bmr);
double get meF => engine.f(mockMe.bmr);

// ---------- 오늘(10.13, D+8) 끼니 ----------
MealItem _item(String id, List<String> cands, List<int> kcal, String portion, ItemKind kind,
        {int? grams, int baseCount = 1, Confidence conf = Confidence.sure, bool checked = true}) =>
    MealItem(id: id, candidates: cands, candKcal: kcal, portion: portion, kind: kind, grams: grams, baseCount: baseCount, confidence: conf, checked: checked, count: baseCount);

/// P7 점심 AI 초안 6항목 합 850. '김'을 해제하면 780.
List<MealItem> lunchDraftItems({bool gimChecked = true}) => [
      _item('rice', ['흰쌀밥', '현미밥', '잡곡밥'], [310, 300, 305], '1공기', ItemKind.rice, grams: 210),
      _item('stew', ['김치찌개', '부대찌개', '된장찌개'], [260, 480, 170], '1인분', ItemKind.soup, grams: 400),
      _item('egg', ['계란말이', '계란찜', '계란후라이'], [90, 80, 95], '조각', ItemKind.count, baseCount: 2, conf: Confidence.check),
      _item('anch', ['멸치볶음', '진미채볶음', '건새우볶음'], [20, 30, 25], '1젓가락', ItemKind.side, grams: 12),
      _item('kimchi', ['배추김치', '총각김치', '깍두기'], [10, 12, 12], '1젓가락', ItemKind.side, grams: 15),
      _item('gim', ['김', '조미김', '김부각'], [70, 70, 120], '1봉', ItemKind.side, grams: 5, checked: gimChecked),
    ];

const lunchAiTotal = 850.0;

List<MealItem> _breakfastItems() => [
      _item('toast', ['계란토스트', '샌드위치', '식빵'], [320, 380, 260], '1개', ItemKind.count),
      _item('banana', ['바나나', '사과', '귤'], [100, 80, 45], '1개', ItemKind.count, grams: 120),
    ];

List<MealItem> _dinnerItems() => [
      _item('salad', ['닭가슴살 샐러드', '연어 샐러드', '두부 샐러드'], [380, 420, 300], '1인분', ItemKind.side, grams: 300),
      _item('sweet', ['군고구마', '삶은 감자', '단호박'], [220, 130, 150], '1개', ItemKind.count, grams: 200, conf: Confidence.check),
    ];

List<MealItem> _snackItems() => [
      _item('coffee', ['아메리카노', '카페라떼', '바닐라라떼'], [10, 180, 260], '1잔', ItemKind.count, grams: 355),
      _item('cookie', ['쿠키', '스콘', '마들렌'], [90, 230, 110], '1개', ItemKind.count, grams: 20, conf: Confidence.check),
    ];

/// 촬영 직후 서버가 돌려줄 AI 초안(모의). 실제 분석은 서버 Edge Function.
List<MealItem> mockDraftItems(MealSlot slot) => switch (slot) {
      MealSlot.breakfast => _breakfastItems(),
      MealSlot.lunch => lunchDraftItems(),
      MealSlot.dinner => _dinnerItems(),
      MealSlot.snack => _snackItems(),
    };

/// 슬롯별 AI 초안 합계
double mockAiTotal(MealSlot slot) => mockDraftItems(slot).fold(0.0, (a, it) => a + it.rawKcal);

List<MealRecord> buildTodayMeals() => [
      MealRecord(
        slot: MealSlot.breakfast,
        status: MealStatus.confirmed,
        kcal: 420,
        aiKcal: 450,
        time: '07:40',
        title: '계란토스트 · 바나나',
      ),
      MealRecord(
        slot: MealSlot.lunch,
        status: MealStatus.confirmed,
        kcal: 780,
        aiKcal: 850,
        time: '12:20',
        title: '김치찌개 백반',
        items: lunchDraftItems(gimChecked: false),
      ),
      MealRecord(
        slot: MealSlot.dinner,
        status: MealStatus.confirmed,
        kcal: 600,
        aiKcal: 640,
        time: '19:05',
        title: '닭가슴살 샐러드 · 고구마',
      ),
      const MealRecord(slot: MealSlot.snack),
    ];

/// 점심이 아직 미확정 AI 초안인 시작 상태(P7 데모·테스트용)
List<MealRecord> buildLunchDraftMeals() {
  final m = buildTodayMeals();
  m[1] = const MealRecord(
    slot: MealSlot.lunch,
    status: MealStatus.draft,
    aiKcal: lunchAiTotal,
    time: '12:20',
    title: '김치찌개 백반',
  ).copyWith(items: lunchDraftItems());
  return m;
}

// ---------- 활동 ----------
class TodayActivity {
  const TodayActivity({
    required this.stepsTotal,
    this.stepsRecorded,
    this.stepsManual = 0,
    this.floors = 0,
    this.sessions = const [],
    this.platformActiveKcal,
    this.hasManualSource = false,
    this.source = '삼성헬스',
    this.syncTime = '21:10',
  });
  final int stepsTotal;
  final int? stepsRecorded;
  final int stepsManual;
  final int floors;
  final List<SessionInput> sessions;
  final double? platformActiveKcal;
  final bool hasManualSource;
  final String source;
  final String syncTime;
}

const mockTodayActivity = TodayActivity(stepsTotal: 9000, stepsRecorded: 9000);
const mockTodayActivityIos = TodayActivity(stepsTotal: 9000, stepsRecorded: 9340, stepsManual: 340, platformActiveKcal: 310, source: 'Apple 건강');
const reviewStepsCase = 26000;

// ---------- 워치 예시 참가자 ----------
const mockWatchProfile = Profile(sex: Sex.f, weightKg: 58, heightCm: 163, age: 30);
const mockWatchSession = SessionInput(type: SessionType.running, minutes: 30, distanceM: 4500, stepsInRange: 4500);
const mockWatchMeals = [
  MealInput(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: 380),
  MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 520),
  MealInput(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: 450),
];
SimulateResult watchToday() => engine.simulate(const SimulateInput(
      profile: mockWatchProfile,
      stepsTotal: 12000,
      sessions: [mockWatchSession],
      meals: mockWatchMeals,
    ));

// ---------- 점수 장부 D1~D8 (10.6~10.13) ----------
MealInput _c(MealSlot s, double k) => MealInput(slot: s, status: MealStatus.confirmed, kcal: k);
MealInput _e(MealSlot s) => MealInput(slot: s, status: MealStatus.empty);
MealInput _v(MealSlot s) => MealInput(slot: s, status: MealStatus.voided);
List<MealInput> _day(double b, double l, double d) => [_c(MealSlot.breakfast, b), _c(MealSlot.lunch, l), _c(MealSlot.dinner, d)];

class _LedgerSeed {
  const _LedgerSeed(this.d, this.date, this.steps, this.meals,
      {this.note = '', this.history = '', this.health = false, this.provisional = false, this.revisionMeals, this.revisionReason});
  final int d;
  final String date;
  final int steps;
  final List<MealInput> meals;
  final String note;
  final String history;
  final bool health;
  final bool provisional;
  final List<MealInput>? revisionMeals;
  final String? revisionReason;
}

List<MealInput> _todayInputs() => buildTodayMeals().map((m) => m.toInput()).toList();

List<LedgerRow> buildLedger() {
  final seeds = <_LedgerSeed>[
    _LedgerSeed(1, '10.6', 9480, _day(430, 720, 610), note: '점검 기간'),
    _LedgerSeed(2, '10.7', 11200, _day(400, 810, 590), note: '점검 기간'),
    _LedgerSeed(3, '10.8', 9200, [_e(MealSlot.breakfast), _c(MealSlot.lunch, 780), _c(MealSlot.dinner, 650)], note: '점검 기간 · 아침 미기록'),
    _LedgerSeed(4, '10.9', 10806, _day(410, 690, 460)),
    _LedgerSeed(5, '10.10', 12321, _day(430, 780, 410), history: '점심 850→780 확정(본인)'),
    _LedgerSeed(6, '10.11', 9000, _day(300, 480, 370), health: true),
    _LedgerSeed(7, '10.12', 10898, _day(420, 780, 600),
        revisionMeals: [_c(MealSlot.breakfast, 420), _c(MealSlot.lunch, 780), _v(MealSlot.dinner)], revisionReason: 'dup_photo'),
    _LedgerSeed(8, '10.13', 9000, _todayInputs(), provisional: true),
  ];
  return [
    for (final s in seeds)
      () {
        final r = engine.simulate(SimulateInput(profile: mockMe.profile, stepsTotal: s.steps, meals: s.meals));
        if (s.revisionMeals == null) {
          return LedgerRow(
            d: s.d,
            date: s.date,
            steps: s.steps,
            bmr: r.bmr,
            a: r.activity.aD,
            i: r.intake.iD,
            dd: r.score.dD,
            s: r.score.sD,
            f: r.score.fP,
            floorApplied: r.score.floorApplied,
            substituted: r.intake.substituteSlots,
            check: s.d <= engine.rules.checkDays,
            provisional: s.provisional,
            note: s.note,
            history: s.history,
            health: s.health,
            meals: s.meals,
          );
        }
        final r2 = engine.simulate(SimulateInput(profile: mockMe.profile, stepsTotal: s.steps, meals: s.revisionMeals!));
        return LedgerRow(
          d: s.d,
          date: s.date,
          steps: s.steps,
          bmr: r2.bmr,
          a: r2.activity.aD,
          i: r2.intake.iD,
          dd: r2.score.dD,
          s: r2.score.sD,
          f: r2.score.fP,
          floorApplied: r2.score.floorApplied,
          substituted: r2.intake.substituteSlots,
          check: s.d <= engine.rules.checkDays,
          provisional: false,
          note: s.note,
          history: s.history,
          health: s.health,
          meals: s.revisionMeals!,
          revisionReason: s.revisionReason,
          sBefore: r.score.sD,
        );
      }(),
  ];
}

final mockLedger = buildLedger();

/// 확정분 누적(점검 기간·잠정 제외)
double get mockCumulative => round1(mockLedger.where((x) => !x.check && !x.provisional).fold(0.0, (a, x) => a + x.s));

// ---------- 리더보드 ----------
class Leaderboard {
  const Leaderboard({required this.total, required this.cumulative, required this.today, this.todayFinal = false, this.asOf});
  final int total;
  final List<LeaderRow> cumulative;
  final List<LeaderRow> today;

  /// 오늘 탭이 확정 스냅샷인지(잠정이면 false)
  final bool todayFinal;

  /// 스냅샷 시각(서버). 모의는 null
  final DateTime? asOf;

  /// 내 행이 없으면 null(기록 모드·순위 비공개 등)
  LeaderRow? meIn(List<LeaderRow> list) {
    for (final r in list) {
      if (r.me) return r;
    }
    return null;
  }

  /// 누적 3위(점수가 보이는 행 기준) 점수 — "3위까지 n점"
  double? get thirdScore {
    final shown = cumulative.where((r) => !r.aggregating && r.score != null).toList();
    return shown.length >= 3 ? shown[2].score : null;
  }
}

class WeeklyFeedback {
  const WeeklyFeedback(this.days, this.avg, this.dinnerConfirmRate);
  final int days;
  final double avg;
  final double dinnerConfirmRate;
}

Leaderboard buildLeaderboard() {
  final me = mockMe.nickname;
  final todayRow = mockLedger.last;
  return Leaderboard(
    total: 42,
    cumulative: [
      const LeaderRow(rank: 1, name: '달려라하니', score: 486.2, fill: 4, watch: true),
      const LeaderRow(rank: 2, name: '강남콩', score: 451.0, fill: 4),
      const LeaderRow(rank: 3, name: '밤산책', score: 388.7, fill: 4, watch: true),
      LeaderRow(rank: 4, name: me, score: mockCumulative, fill: 4, me: true, delta: 2),
      const LeaderRow(rank: 5, name: '오이냉국', score: 301.9, fill: 3, tie: true),
      const LeaderRow(rank: 5, name: '새벽러닝', score: 301.9, fill: 4, tie: true),
      const LeaderRow(rank: 7, name: '집계 중', fill: 0, aggregating: true),
      const LeaderRow(rank: 8, name: '라떼한잔', score: 268.4, fill: 2),
      const LeaderRow(rank: 9, name: '마포구민', score: 251.0, fill: 3),
      const LeaderRow(rank: 10, name: '야근요정', score: 236.5, fill: 3),
    ],
    today: [
      const LeaderRow(rank: 1, name: '강남콩', score: 118.4, fill: 4),
      LeaderRow(rank: 2, name: '밤산책', score: watchToday().score.sD, fill: 4, watch: true),
      const LeaderRow(rank: 3, name: '초록이', score: 64.0, fill: 4),
      const LeaderRow(rank: 4, name: '달려라하니', score: 58.2, fill: 3, watch: true),
      const LeaderRow(rank: 5, name: '오이냉국', score: 51.6, fill: 3),
      const LeaderRow(rank: 6, name: '집계 중', fill: 0, aggregating: true),
      LeaderRow(rank: 17, name: me, score: todayRow.s, fill: 4, me: true, gapToPrev: 3.2),
    ],
  );
}

WeeklyFeedback buildWeekly() {
  final rows = mockLedger.where((x) => !x.check && !x.provisional).toList();
  final avg = round1(rows.fold(0.0, (a, x) => a + x.s) / rows.length);
  final dinner = rows.where((x) => !x.substituted.contains(MealSlot.dinner)).length / rows.length;
  return WeeklyFeedback(rows.length, avg, dinner);
}

final mockLeaderboard = buildLeaderboard();
final mockWeekly = buildWeekly();

// ---------- 최종 결과(Published) ----------
final mockFinal = <LeaderRow>[
  const LeaderRow(rank: 1, name: '달려라하니', score: 1310.4, fill: 4),
  const LeaderRow(rank: 2, name: '강남콩', score: 1254.0, fill: 4),
  const LeaderRow(rank: 3, name: '밤산책', score: 1102.7, fill: 4),
  LeaderRow(rank: 4, name: mockMe.nickname, score: 1041.3, fill: 4, me: true),
  const LeaderRow(rank: 5, name: '초록이', score: 988.0, fill: 4),
];

// ---------- 판정 템플릿 (docs/06 §6) ----------
const reasonText = {
  'steps_spike': '걸음 기록이 평소보다 크게 높아 확인했어요',
  'source_unknown': '확인되지 않은 출처의 운동 기록이 있었어요',
  'dup_photo': '같은 사진이 두 번 이상 사용됐어요',
  'downward_edit': '확정값이 AI 추정보다 절반 넘게 낮았어요',
  'skip_abuse': "'건너뜀'이 한도를 넘었어요",
};

class Verdict {
  const Verdict(this.label, this.text, this.effect);
  final String label;
  final String text;
  final String effect;
}

const verdictText = {
  'approve': Verdict('승인', '확인이 끝났어요', '점수 변동 없음'),
  'warn': Verdict('경고', '이번은 경고 {n}/3이에요', '점수 변동 없음'),
  'void': Verdict('무효', '{대체 처리}로 다시 계산했어요', '{날짜} {전}→{후}점 · 누적 {차액}'),
  'exclude': Verdict('순위 제외', '경고가 3회 누적되어 이번 챌린지 순위에서 빠졌어요', '점수와 기록은 계속 볼 수 있어요'),
  'expired': Verdict('소명 기간 만료', '설명 기간이 지나 기록으로만 확인했어요', ''),
};
