import '../core/engine/engine.dart';

const slotLabel = {
  MealSlot.breakfast: '아침',
  MealSlot.lunch: '점심',
  MealSlot.dinner: '저녁',
  MealSlot.snack: '간식',
};

enum ItemKind { rice, soup, count, side }

enum Confidence { sure, check, manual }

/// P7 항목 카드 하나(AI 초안 항목 + 사용자 편집 상태).
class MealItem {
  const MealItem({
    required this.id,
    required this.candidates,
    required this.candKcal,
    required this.portion,
    required this.kind,
    this.grams,
    this.baseCount = 1,
    this.confidence = Confidence.sure,
    this.checked = true,
    this.cand = 0,
    this.mult = 1,
    this.brothOff = false,
    this.count = 1,
    this.foodCodes = const [],
    this.fromSearch = false,
    this.unitLabels = const [],
  });

  final String id;

  /// 후보별 식약처 food_code(서버 초안·검색 결과). 없으면 serving kcal 만 보낸다.
  final List<String?> foodCodes;

  /// 검색으로 추가한 항목(input_type=search)
  final bool fromSearch;

  /// 후보별 가공식품(상품) 1개 단위 라벨('1회분(30g)' · '1개(40g)' · '100g', D63). 음식·직접 입력 후보는 null
  final List<String?> unitLabels;

  final List<String> candidates;
  final List<int> candKcal;
  final String portion;
  final ItemKind kind;
  final int? grams;
  final int baseCount;
  final Confidence confidence;
  final bool checked;

  /// 선택된 후보 인덱스(이름과 kcal이 함께 바뀐다)
  final int cand;

  /// 먹은 양 배수(0.1 단위, 0.1~3.0). 개수 항목은 1개 크기 배수(달걀 2개 × 1.2배)
  final double mult;
  final bool brothOff;
  final int count;

  String get name => candidates[cand];

  /// 고른 후보가 상품이면 그 단위 라벨, 아니면 null
  String? get unitLabel => cand < unitLabels.length ? unitLabels[cand] : null;

  /// 체크 여부와 무관하게 현재 선택의 kcal
  double get rawKcal {
    var k = candKcal[cand].toDouble();
    k = kind == ItemKind.count ? k * count * mult : k * mult; // 개수 항목: 개수 × 1개 크기 배수
    if (kind == ItemKind.soup && brothOff) k *= EngineRules.defaults.brothFactor; // 국물 −40%
    return k;
  }

  /// 합계에 들어가는 kcal(먹은 것만)
  double get kcal => checked ? rawKcal : 0;

  MealItem copyWith({bool? checked, int? cand, double? mult, bool? brothOff, int? count}) => MealItem(
        id: id,
        candidates: candidates,
        candKcal: candKcal,
        portion: portion,
        kind: kind,
        grams: grams,
        baseCount: baseCount,
        confidence: confidence,
        checked: checked ?? this.checked,
        cand: cand ?? this.cand,
        mult: mult ?? this.mult,
        brothOff: brothOff ?? this.brothOff,
        count: count ?? this.count,
        foodCodes: foodCodes,
        fromSearch: fromSearch,
        unitLabels: unitLabels,
      );
}

/// 오늘의 끼니 1건. status 는 05 meals.status 와 같은 [MealStatus].
/// captured 는 "분석 중"(noAnalysis=false) 또는 "분석 없이 저장"(noAnalysis=true).
class MealRecord {
  const MealRecord({
    required this.slot,
    this.status = MealStatus.empty,
    this.kcal = 0,
    this.aiKcal,
    this.title = '',
    this.time = '',
    this.items = const [],
    this.noAnalysis = false,
    this.corrected = false,
    this.serverId,
    this.version = 1,
    this.lateUpload = false,
    this.pendingUpload = false,
    this.localKey,
  });

  final MealSlot slot;

  /// 이 폰에서 끼니를 가리키는 키. 아직 서버 id 가 없는 촬영(업로드 중·대기)도 이 키로 찾는다.
  /// 서버에서 읽은 끼니는 서버 id 를 쓰고, 촬영으로 만든 끼니는 서버 id 가 생겨도 이 키를 유지한다.
  final String? localKey;

  /// 끼니 식별자(P7 경로 `meal=`). [matches] 는 로컬 키와 서버 id 를 모두 받는다.
  String get key => localKey ?? serverId ?? slot.name;
  bool matches(String k) => localKey == k || serverId == k;

  /// 서버 meals.id / meals.version(확정 If-Match). 모의 시드 끼니는 null.
  final String? serverId;
  final int version;

  /// 지연 업로드 배지(05 §6)
  final bool lateUpload;

  /// 오프라인 등으로 업로드 대기 중(재시도 큐)
  final bool pendingUpload;
  final MealStatus status;
  final double kcal;
  final double? aiKcal;
  final String title;
  final String time;
  final List<MealItem> items;
  final bool noAnalysis;
  final bool corrected;

  MealInput toInput() => MealInput(slot: slot, status: status, kcal: kcal, aiKcal: aiKcal);

  MealRecord copyWith({
    MealSlot? slot,
    MealStatus? status,
    double? kcal,
    double? aiKcal,
    String? title,
    String? time,
    List<MealItem>? items,
    bool? noAnalysis,
    bool? corrected,
    String? serverId,
    int? version,
    bool? lateUpload,
    bool? pendingUpload,
    String? localKey,
  }) =>
      MealRecord(
        slot: slot ?? this.slot,
        status: status ?? this.status,
        kcal: kcal ?? this.kcal,
        aiKcal: aiKcal ?? this.aiKcal,
        title: title ?? this.title,
        time: time ?? this.time,
        items: items ?? this.items,
        noAnalysis: noAnalysis ?? this.noAnalysis,
        corrected: corrected ?? this.corrected,
        serverId: serverId ?? this.serverId,
        version: version ?? this.version,
        lateUpload: lateUpload ?? this.lateUpload,
        pendingUpload: pendingUpload ?? this.pendingUpload,
        localKey: localKey ?? this.localKey,
      );
}

/// 확정값이 섭취에 들어가는 상태(확정·자동 확정·정정)
bool isCountedStatus(MealStatus s) => s == MealStatus.confirmed || s == MealStatus.auto || s == MealStatus.corrected;

/// [meals] 중 [slot] 의 끼니(빈 칸 표시용 행 제외). 목록 순서(촬영 시각 순) 그대로.
List<MealRecord> mealsIn(List<MealRecord> meals, MealSlot slot) =>
    [for (final m in meals) if (m.slot == slot && m.status != MealStatus.empty) m];

/// [slot] 을 건너뛸 수 있는지: 끼니 슬롯이고, 기록이 없거나 간식 수준([snackKcal] 미만) 확정 기록만 있을 때.
/// 간식 수준 기록은 슬롯을 채우지 않으므로(커피만 마신 저녁 등) 건너뜀으로 대체값을 피할 수 있다. 엔진·서버 규칙과 같다.
bool canSkipSlot(List<MealRecord> meals, MealSlot slot, {required double snackKcal}) =>
    slot != MealSlot.snack && mealsIn(meals, slot).every((m) => isCountedStatus(m.status) && m.kcal < snackKcal);

class ChallengeInfo {
  const ChallengeInfo({
    required this.name,
    required this.code,
    required this.start,
    required this.end,
    required this.days,
    required this.capacity,
    required this.joined,
    required this.today,
    required this.dayIndex,
    required this.syncTime,
    required this.source,
    required this.platform,
    required this.noticeTitle,
    required this.noticeBody,
    required this.noticeDate,
    required this.objectionUntil,
  });
  final String name;
  final String code;
  final DateTime start;
  final DateTime end;
  final int days;
  final int capacity;
  final int joined;
  final DateTime today;
  final int dayIndex;
  final String syncTime;
  final String source;
  final String platform;
  final String noticeTitle;
  final String noticeBody;
  final String noticeDate;
  final String objectionUntil;
}

class MeInfo {
  const MeInfo({
    required this.nickname,
    required this.sex,
    required this.birthYear,
    required this.heightCm,
    required this.weightKg,
    required this.age,
    required this.bmr,
    required this.bmrRaw,
  });
  final String nickname;
  final Sex sex;
  final int birthYear;
  final double heightCm;
  final double weightKg;
  final int age;
  final int bmr;
  final double bmrRaw;

  Profile get profile => Profile(sex: sex, weightKg: weightKg, heightCm: heightCm, age: age);
}

/// 점수 장부 한 줄(P10). 값은 엔진이 계산한다.
class LedgerRow {
  const LedgerRow({
    required this.d,
    required this.date,
    required this.steps,
    required this.bmr,
    required this.a,
    required this.i,
    required this.dd,
    required this.s,
    required this.f,
    required this.floorApplied,
    required this.substituted,
    required this.check,
    required this.provisional,
    required this.note,
    required this.history,
    required this.health,
    required this.meals,
    this.revisionReason,
    this.sBefore,
    this.localDate,
    this.finalizedAt,
    this.substituteValues = const {},
  });
  final int d;
  final String date;

  /// 대체값을 더한 칸 → 쓴 값(서버 breakdown.intake.substitute_values, D61). 없으면 M_p 로 본다.
  final Map<MealSlot, double> substituteValues;

  /// 날짜(YYYY-MM-DD, KST). 서버 행만 채운다(모의 장부는 null).
  final String? localDate;

  /// 확정 시각(daily_scores.finalized_at). 확정 전이거나 서버가 주지 않으면 null.
  final DateTime? finalizedAt;
  final int steps;
  final int bmr;
  final double a;
  final double i;
  final double dd;
  final double s;
  final double f;
  final bool floorApplied;
  final List<MealSlot> substituted;
  final bool check;
  final bool provisional;
  final String note;
  final String history;
  final bool health;
  final List<MealInput> meals;
  final String? revisionReason;
  final double? sBefore;
  bool get hasRevision => revisionReason != null;
}

class LeaderRow {
  const LeaderRow({
    required this.rank,
    required this.name,
    this.score,
    this.fill = 0,
    this.watch = false,
    this.me = false,
    this.delta = 0,
    this.tie = false,
    this.aggregating = false,
    this.gapToPrev,
    this.participantId,
    this.underReview = false,
    this.pending = false,
    this.avg,
    this.rate,
    this.days,
    this.minDays,
  });
  final int rank;
  final String name;
  final double? score;
  final int fill;
  final bool watch;
  final bool me;
  final int delta;
  final bool tie;
  final bool aggregating;
  final double? gapToPrev;

  /// 서버 스냅샷 행의 participant_id(신고 대상). 모의 행·집계 중 행은 null.
  final String? participantId;

  /// 본인 행만: 검토 중(잠정 유지, 타인에게는 '집계 중')
  final bool underReview;

  /// 순위 대기(최소 참여일 전, rank 0)
  final bool pending;

  /// 누적 행: 일평균 점수·참여율·참여일·최소 참여일 (서버가 주지 않으면 null)
  final double? avg;
  final double? rate;
  final int? days;
  final int? minDays;
}

/// 운영자 공지(N-03). 서버 notifications(type N-03, 본인 행) 한 건.
class Notice {
  const Notice({required this.id, required this.title, required this.body, required this.at, this.read = false});
  final String id;
  final String title;
  final String body;

  /// 발송(예약) 시각 — KST 벽시계 기준
  final DateTime at;
  final bool read;

  Notice markRead() => Notice(id: id, title: title, body: body, at: at, read: true);
}

/// 내 검토 1건(reviews, 본인 행) + 내가 보낸 소명/이의 본문(appeals)
class MyReview {
  const MyReview({required this.id, required this.type, required this.status, this.localDate, this.slaDueAt, this.reasonTemplate,
      this.verdict, this.message, this.appealText, this.decidedAt});
  final String id;

  /// reviews.type (steps_spike·dup_photo·report·objection …)
  final String type;

  /// open · appealed · decided
  final String status;
  final DateTime? localDate;
  final DateTime? slaDueAt;
  final String? reasonTemplate;
  final String? verdict;

  /// 판정 통지 문장(사유+판정+점수 영향, 서버 verdict_message)
  final String? message;
  final String? appealText;
  final DateTime? decidedAt;

  bool get open => status == 'open';
  bool get decided => status == 'decided';
}

/// 검토 사유 문장(docs/06 §6 판정 템플릿). 키는 reviews.type·reason_template
const reasonText = {
  'steps_spike': '걸음 기록이 평소보다 크게 높아 확인했어요',
  'source_unknown': '확인되지 않은 출처의 운동 기록이 있었어요',
  'dup_photo': '같은 사진이 두 번 이상 사용됐어요',
  'downward_edit': '확정값이 AI 추정보다 절반 넘게 낮았어요',
  'skip_abuse': "'건너뜀'이 한도를 넘었어요",
};

/// 사유를 모르거나 검토 목록을 아직 못 받았을 때 홈·활동 배너 문장
const reviewReasonFallback = '기록을 확인하고 있어요';

/// [day] 날짜에 걸린 열린(소명 전·후, 판정 전) 검토 중 첫 건. 없으면 null
MyReview? openReviewOn(List<MyReview>? reviews, DateTime day) {
  for (final r in reviews ?? const <MyReview>[]) {
    final d = r.localDate;
    if (!r.decided && d != null && d.year == day.year && d.month == day.month && d.day == day.day) return r;
  }
  return null;
}

/// 홈·활동 화면 검토 배너가 보여줄 사유. 걸음 급증이면 [spike] 가 true(화면이 걸음 수를 넣어 기존 문구를 쓴다).
/// 모의 모드는 걸음 급증 시나리오만 있어 항상 급증. 서버 모드는 그날 열린 검토 [review] 의 종류를 따른다.
/// 종류를 모르거나 검토 목록을 아직 못 받았으면 일반 문구.
({bool spike, String lead, String rest}) reviewBannerText({required bool remote, MyReview? review}) {
  if (!remote) return (spike: true, lead: '', rest: '');
  final key = review?.reasonTemplate ?? review?.type;
  if (key == 'steps_spike') return (spike: true, lead: '', rest: '');
  final reason = reasonText[key];
  if (reason == null) return (spike: false, lead: reviewReasonFallback, rest: '');
  return (spike: false, lead: reason, rest: ' · 72시간 안에 설명을 남길 수 있어요');
}

/// 음식 검색·최근 음식 한 건(1인분 kcal). 서버: food_search(식약처 DB, pg_trgm) / recent_foods(30일 확정)
/// 가공식품(상품) 행(D63)은 1개(포장 전체·1회분·100g) kcal 과 제조사·단위 라벨을 함께 준다.
class FoodHit {
  const FoodHit({required this.name, required this.kcal, this.foodCode, this.recent = false, this.isProduct = false, this.maker, this.unitLabel});
  final String name;
  final int kcal;
  final String? foodCode;
  final bool recent;
  final bool isProduct;
  final String? maker;

  /// 상품 1개 단위 라벨('1회분(30g)' 등). 음식은 null
  final String? unitLabel;

  /// 화면용 제조사 이름(회사 형태 표기를 뺀다)
  String? get makerLabel => switch (maker) { final m? => shortMaker(m), null => null };
}

/// 제조사 이름에서 회사 형태 표기를 뺀다: '롯데웰푸드 주식회사' → '롯데웰푸드', '(주)서주' → '서주'
String shortMaker(String maker) {
  final s = maker.replaceAll(RegExp(r'농업회사법인|영농조합법인|유한회사|주식회사|\(주\)|\(유\)|㈜'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? maker.trim() : s;
}

/// 상품 단위 라벨 → 먹은 양 스테퍼 단위: '1회분(30g)' → '회분', 그 밖('1개(40g)' · '100g')은 '개'
String productStepUnit(String unitLabel) => unitLabel.startsWith('1회분') ? '회분' : '개';

/// 순위 통계(서버 participant_rank_stats, D49): 순위 점수 = 일평균 × (1 + 참여율). 최소 참여일 전이면 순위 대기.
class RankStats {
  const RankStats({required this.days, required this.avail, required this.minDays, this.avg, this.rate, required this.pending, this.score});
  final int days;
  final int avail;
  final int minDays;
  final double? avg;
  final double? rate;
  final bool pending;
  final double? score;

  factory RankStats.fromJson(Map<String, dynamic> j) => RankStats(
        days: (j['days'] as num?)?.toInt() ?? 0,
        avail: (j['avail'] as num?)?.toInt() ?? 0,
        minDays: (j['min_days'] as num?)?.toInt() ?? 1,
        avg: (j['avg'] as num?)?.toDouble(),
        rate: (j['rate'] as num?)?.toDouble(),
        pending: j['pending'] as bool? ?? true,
        score: (j['score'] as num?)?.toDouble(),
      );
}

/// 코드 없이 참가할 수 있는 월간 챌린지(open_challenges)
class OpenChallenge {
  const OpenChallenge({required this.challengeId, required this.name, required this.kind, required this.startDate, required this.endDate,
      required this.days, required this.joined, required this.joinable, this.myStatus});
  final String challengeId;
  final String name;
  final String kind;
  final DateTime startDate;
  final DateTime endDate;
  final int days;
  final int joined;
  final bool joinable;

  /// 내 참가 상태(active·left 등). 참가한 적 없으면 null
  final String? myStatus;

  factory OpenChallenge.fromJson(Map<String, dynamic> j) => OpenChallenge(
        challengeId: j['challenge_id'] as String,
        name: j['name'] as String,
        kind: j['kind'] as String? ?? 'monthly',
        startDate: DateTime.parse(j['start_date'] as String),
        endDate: DateTime.parse(j['end_date'] as String),
        days: (j['days'] as num).toInt(),
        joined: (j['joined'] as num?)?.toInt() ?? 0,
        joinable: j['joinable'] as bool? ?? false,
        myStatus: j['me'] as String?,
      );
}
