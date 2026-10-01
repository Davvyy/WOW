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
  });

  final String id;

  /// 후보별 식약처 food_code(서버 초안·검색 결과). 없으면 serving kcal 만 보낸다.
  final List<String?> foodCodes;

  /// 검색으로 추가한 항목(input_type=search)
  final bool fromSearch;
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

  /// 분량 배수(밥 0.5/1/1.5, 반찬 젓가락 수)
  final double mult;
  final bool brothOff;
  final int count;

  String get name => candidates[cand];

  /// 체크 여부와 무관하게 현재 선택의 kcal
  double get rawKcal {
    var k = candKcal[cand].toDouble();
    k = kind == ItemKind.count ? k * count : k * mult;
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
  });

  final MealSlot slot;

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
  }) =>
      MealRecord(
        slot: slot,
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
      );
}

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
  });
  final int d;
  final String date;
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
}
