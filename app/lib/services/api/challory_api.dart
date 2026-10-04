import 'dart:typed_data';

import '../../core/engine/engine.dart';
import '../../data/mock/mock_data.dart' show Leaderboard;
import '../../data/models.dart';
import '../../state/session.dart' show ChallengeSession;

/// 서버 호출 계약(supabase/functions/* · docs/05 API). 화면·상태는 이 인터페이스만 쓴다.
/// [SupabaseChalloryApi] 는 Edge Function·PostgREST, [MockChalloryApi] 는 서버 없이 같은 응답 모양을 흉내 낸다.
/// 모든 쓰기 호출은 Idempotency-Key 를 붙이고, 재시도 때 같은 키를 다시 쓴다(05 §4 멱등 규약).
abstract class ChalloryApi {
  bool get isRemote;

  /// API #2 초대코드 조회(로그인 전에도 가능). 없거나 모집이 끝났으면 null.
  Future<InviteSummary?> getInvite(String code);

  /// API #3 참가: 자격 게이트·기록 모드·BMR 잠금은 서버(join_challenge)가 판정
  Future<JoinResult> joinChallenge(JoinRequest req);

  /// 로그인한 사용자가 이미 참가 중인 챌린지가 있는지(재설치·재로그인 시 온보딩 건너뛰기)
  Future<bool> hasParticipation();

  /// API #33 내 챌린지 세션(요약·규칙 상수·잠긴 프로필·최근 공지). 참가 중이 아니면 null.
  Future<ChallengeSession?> fetchSession();

  /// 참가 중인 챌린지 세션 전부(최근 참가 순). 강퇴·나감 제외. 참가한 곳이 없으면 빈 목록.
  Future<List<ChallengeSession>> fetchSessions();

  /// 코드 없이 참가할 수 있는 열린(월간) 챌린지. 내 참가 상태([OpenChallenge.myStatus])를 함께 준다.
  Future<List<OpenChallenge>> fetchOpenChallenges();

  /// 챌린지에서 나간다(leave_challenge). 나간 챌린지에는 다시 참가할 수 없다.
  Future<void> leaveChallenge(String challengeId);

  /// 다음 달 월간 챌린지에 자동으로 참가할지(profiles.auto_continue). 기본 켬.
  Future<bool> fetchAutoContinue();

  /// 다음 달 자동 참가 설정을 바꾼다(본인 프로필 행).
  Future<void> setAutoContinue(bool on);

  /// 공지 목록(N-03, 최신순). 예약 발송 시각이 지난 것만.
  Future<List<Notice>> fetchNotices();

  /// 공지 읽음 표시(notifications.read_at, 본인 행)
  Future<void> markNoticesRead(List<String> ids);

  /// API #18 응원(보내는 사람 기준 하루 1회). 이미 보냈으면 409.
  Future<void> sendCheer(String toParticipantId);

  /// 오늘(KST) 내가 응원한 참가자 id(없으면 null)
  Future<String?> cheeredToday();

  /// API #20 내 검토(사유·SLA·판정 문장·보낸 소명)
  Future<List<MyReview>> fetchMyReviews();

  /// API #21 소명 1회(72h)
  Future<void> submitAppeal(String reviewId, String text);

  /// API #34 결과 이의(발표 후 7일·1회)
  Future<void> submitObjection(String text);

  /// API #14 음식 검색(식약처 DB, 동의어 → pg_trgm, 상위 10)
  Future<List<FoodHit>> searchFoods(String q);

  /// 최근 음식(30일 내 내가 확정한 음식, 최신순)
  Future<List<FoodHit>> recentFoods();

  /// API #17 리더보드: 최신 스냅샷(오늘·누적) + 내 행(본인 점수는 내 장부에서)
  Future<Leaderboard> fetchLeaderboard();

  /// API #15 내 점수 장부(일별 분해·정정 이력)
  Future<List<LedgerRow>> fetchLedger();

  /// API #8 사진 행 + 서명 업로드 URL
  Future<PhotoUploadTicket> requestPhotoUpload(PreparedPhoto photo, {required String idempotencyKey});

  /// 서명 URL 로 이미지 PUT
  Future<void> uploadPhoto(PhotoUploadTicket ticket, Uint8List bytes);

  /// API #9 끼니 생성(서버 재검증 · 슬롯 태그 · 지연 업로드 규칙)
  /// [slot] 은 촬영 화면에서 고른 끼니: 그 슬롯으로 저장한다(D58). 없으면 서버 시각으로 슬롯을 정한다.
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey, MealSlot? slot});

  /// 끼니 1건 + 초안 항목(분석 완료 확인용)
  Future<ServerMeal?> fetchMeal(String mealId);

  /// 본인 끼니(해당 KST 날짜, RLS 본인 행) — P5 시작 시 서버 상태로 맞춘다
  Future<List<ServerMeal>> fetchMealsOn(String localDate);

  /// API #12 확정(If-Match: version)
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey});

  /// API #13 건너뜀
  Future<SkipResult> skipMeal(String localDate, MealSlot slot, {required String idempotencyKey});

  /// 끼니 지우기(Edge meal-delete). 서버가 사진·항목을 지우고 그날 점수를 다시 계산한다.
  /// 404 기록 없음 · 403 남의 기록 · 422 확정된 날짜·판정된 기록은 [ApiException] 으로 서버 문구 그대로.
  Future<void> deleteMeal(String mealId, {required String idempotencyKey});

  /// API #10 사진 없는 직접 입력·검색 확정
  Future<ConfirmResult> createManualMeal(MealSlot slot, List<Map<String, dynamic>> items, {String? localDate, required String idempotencyKey});

  /// API #6 활동 배치(client_batch_id = Idempotency-Key)
  Future<Map<String, dynamic>> syncActivity(Map<String, dynamic> batch);

  /// API #19 익명 신고
  Future<void> report({String? participantId, String? mealId, required String reason, required String idempotencyKey});

  /// API #22 계정 삭제(확인 문구 "삭제")
  Future<void> deleteAccount(String confirm);

  /// 푸시 기기 등록(RPC register_device). [deviceId] 는 이전에 받은 값(없으면 새 행). 같은 토큰의 다른 행은 서버가 지운다.
  /// [permission]: granted · denied · not_asked. 반환: 기기 행 id(기기에 저장해 다음에 넘긴다).
  Future<String> registerDevice({String? deviceId, required String platform, String? token, required String permission, String? appVersion});

  /// 로그아웃 때 이 기기 행을 지워 더는 이 계정 알림이 오지 않게 한다(RLS: 본인 행)
  Future<void> unregisterDevice(String deviceId);
}

class InviteSummary {
  const InviteSummary({required this.challengeId, required this.name, required this.status, required this.startDate,
      required this.endDate, this.capacity, required this.joined, required this.days, this.kind = 'operator', this.joinOpen = true,
      required this.joinable});
  final String challengeId;
  final String name;
  final String status;
  final DateTime startDate;
  final DateTime endDate;
  final int? capacity;
  final int joined;
  final int days;
  final String kind;
  final bool joinOpen;

  /// 지금 참가할 수 있는지(서버 판정). 이전 서버는 모집 중일 때만
  final bool joinable;

  bool get full => capacity != null && joined >= capacity!;

  factory InviteSummary.fromJson(Map<String, dynamic> j) => InviteSummary(
        challengeId: j['challenge_id'] as String,
        name: j['name'] as String,
        status: j['status'] as String,
        startDate: DateTime.parse(j['start_date'] as String),
        endDate: DateTime.parse(j['end_date'] as String),
        capacity: (j['capacity'] as num?)?.toInt(),
        joined: (j['joined'] as num).toInt(),
        days: (j['days'] as num).toInt(),
        kind: j['kind'] as String? ?? 'operator',
        joinOpen: j['join_open'] as bool? ?? true,
        joinable: j['joinable'] as bool? ?? (j['status'] == 'recruiting'),
      );
}

class JoinRequest {
  const JoinRequest({this.code, this.challengeId, required this.nickname, required this.sex, required this.birthYear, required this.heightCm,
      required this.weightKg, this.pregnancy = false, this.eatingDisorder = false, required this.terms, required this.sensitiveHealth,
      required this.overseasAi, this.autoContinue})
      : assert(code != null || challengeId != null);

  /// 운영자 챌린지 초대 코드. 월간 챌린지는 [challengeId] 로 참가한다
  final String? code;
  final String? challengeId;
  final bool? autoContinue;
  final String nickname;
  final Sex sex;
  final int birthYear;
  final double heightCm;
  final double weightKg;
  final bool pregnancy;
  final bool eatingDisorder;
  final bool terms;
  final bool sensitiveHealth;
  final bool overseasAi;

  Map<String, dynamic> toJson() => {
        if (challengeId != null) 'challenge_id': challengeId else 'code': code,
        'nickname': nickname,
        'sex': sex == Sex.m ? 'M' : 'F',
        'birth_year': birthYear,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'pregnancy': pregnancy,
        'eating_disorder': eatingDisorder,
        'consents': {'terms': terms, 'sensitive_health': sensitiveHealth, 'overseas_ai': overseasAi},
        if (autoContinue != null) 'auto_continue': autoContinue,
      };
}

class JoinResult {
  const JoinResult({required this.participantId, required this.challengeId, required this.bmr, required this.recordMode,
      this.kind = 'operator', this.checkStart});
  final String participantId;
  final String challengeId;
  final int bmr;
  final bool recordMode;
  final String kind;
  final DateTime? checkStart;

  factory JoinResult.fromJson(Map<String, dynamic> j) => JoinResult(
        participantId: j['participant_id'] as String,
        challengeId: j['challenge_id'] as String,
        bmr: (j['bmr'] as num).toInt(),
        recordMode: j['record_mode'] as bool? ?? false,
        kind: j['kind'] as String? ?? 'operator',
        checkStart: j['check_start'] == null ? null : DateTime.parse(j['check_start'] as String),
      );
}

class ApiException implements Exception {
  const ApiException(this.status, this.message);
  final int status;
  final String message;

  /// 네트워크 단절·5xx → 오프라인 큐로 재시도할 대상
  bool get retryable => status == 0 || status >= 500 || status == 408 || status == 429;
  @override
  String toString() => 'ApiException($status, $message)';
}

/// 기기에서 리사이즈(긴 변 ≤1,568 px)·EXIF 제거·SHA-256 계산을 마친 사진
class PreparedPhoto {
  const PreparedPhoto({required this.bytes, required this.sha256, required this.width, required this.height, required this.capturedAt});
  final Uint8List bytes;
  final String sha256;
  final int width;
  final int height;
  final DateTime capturedAt;
}

class PhotoUploadTicket {
  const PhotoUploadTicket({required this.photoId, required this.storagePath, required this.token, this.signedUrl});
  final String photoId;
  final String storagePath;
  final String token;
  final String? signedUrl;
}

class CreatedMeal {
  const CreatedMeal({required this.mealId, required this.slot, required this.localDate, required this.analyze,
      this.lateUpload = false, this.counted = true, this.dupPhoto = false});
  final String mealId;
  final MealSlot slot;
  final String localDate;
  final bool analyze;
  final bool lateUpload;
  final bool counted;
  final bool dupPhoto;

  factory CreatedMeal.fromJson(Map<String, dynamic> j) => CreatedMeal(
        mealId: j['meal_id'] as String,
        slot: MealSlot.values.byName(j['slot'] as String),
        localDate: j['local_date'] as String,
        analyze: j['analyze'] as bool? ?? false,
        lateUpload: j['late_upload'] as bool? ?? false,
        counted: j['counted'] as bool? ?? true,
        dupPhoto: j['dup_photo'] as bool? ?? false,
      );
}

/// 서버 초안 항목(meal_items)
class ServerMealItem {
  const ServerMealItem({required this.candidates, required this.candidateKcal, required this.candidateFoodCodes, required this.count,
      required this.portionMultiplier, required this.hasBroth, required this.needsCheck, required this.aiKcal,
      this.chosen = 0, this.eaten = true, this.brothOff = false});
  final List<String> candidates;
  final List<double> candidateKcal;
  final List<String?> candidateFoodCodes;
  final int count;
  final double portionMultiplier;
  final bool hasBroth;
  final bool needsCheck;
  final double aiKcal;

  /// 고른 후보 인덱스(chosen_name 의 자리)
  final int chosen;

  /// 먹음 체크(확정 때 저장된 eaten)
  final bool eaten;
  final bool brothOff;

  factory ServerMealItem.fromJson(Map<String, dynamic> j) {
    final ai = (j['ai_kcal'] as num?)?.toDouble() ?? 0;
    final chosen = (j['chosen_name'] as String?) ?? ((j['name_candidates'] as List?)?.firstOrNull as String? ?? '음식');
    var cands = [for (final c in (j['name_candidates'] as List? ?? const [])) c as String];
    var kcals = [for (final k in (j['candidate_kcal'] as List? ?? const [])) (k as num).toDouble()];
    var codes = [for (final c in (j['candidate_food_codes'] as List? ?? const [])) c as String?];
    final count = (j['count'] as num?)?.toInt() ?? 1;
    final mult = (j['portion_multiplier'] as num?)?.toDouble() ?? 1;
    final brothOff = j['broth_off'] as bool? ?? false;
    if (kcals.length != cands.length || cands.isEmpty) {
      // 후보 kcal 이 없는 행(구버전·직접 입력): 선택 이름 하나만. 1인분 kcal 이 없는 옛 확정 행은 확정 kcal 에서 되살린다.
      final confirmed = (j['confirmed_kcal'] as num?)?.toDouble();
      final bite = (j['bite_fraction'] as num?)?.toDouble() ?? 1;
      final factor = mult * count * bite * (brothOff ? EngineRules.defaults.brothFactor : 1);
      final serving = (j['serving_kcal'] as num?)?.toDouble() ??
          (confirmed != null && factor > 0 ? confirmed / factor : ai);
      cands = [chosen];
      kcals = [serving];
      codes = [j['food_code'] as String?];
    }
    return ServerMealItem(
      candidates: cands,
      candidateKcal: kcals,
      candidateFoodCodes: codes.length == cands.length ? codes : List.filled(cands.length, null),
      count: count,
      portionMultiplier: mult,
      hasBroth: (j['has_broth'] as bool? ?? false) || brothOff,
      needsCheck: j['needs_check'] as bool? ?? false,
      aiKcal: ai,
      chosen: cands.indexOf(chosen).clamp(0, cands.length - 1),
      eaten: j['eaten'] as bool? ?? true,
      brothOff: brothOff,
    );
  }
}

class ServerMeal {
  const ServerMeal({required this.id, required this.status, required this.version, this.aiKcal, this.confirmedKcal, this.items = const [],
      this.slot, this.capturedAt, this.lateUpload = false, this.engine});
  final String id;
  final MealSlot? slot;
  final DateTime? capturedAt;
  final bool lateUpload;
  final String? engine;
  final MealStatus status;
  final int version;
  final double? aiKcal;
  final double? confirmedKcal;
  final List<ServerMealItem> items;

  factory ServerMeal.fromJson(Map<String, dynamic> j) => ServerMeal(
        id: j['id'] as String,
        status: j['status'] == 'void' ? MealStatus.voided : MealStatus.values.byName(j['status'] as String),
        version: (j['version'] as num?)?.toInt() ?? 1,
        aiKcal: (j['ai_kcal'] as num?)?.toDouble(),
        confirmedKcal: (j['confirmed_kcal'] as num?)?.toDouble(),
        items: [for (final it in (j['meal_items'] as List? ?? const [])) ServerMealItem.fromJson(Map<String, dynamic>.from(it as Map))],
        slot: j['slot'] == null ? null : MealSlot.values.byName(j['slot'] as String),
        capturedAt: j['captured_at'] == null ? null : DateTime.parse(j['captured_at'] as String),
        lateUpload: j['late_upload'] as bool? ?? false,
        engine: j['engine'] as String?,
      );
}

class ConfirmResult {
  const ConfirmResult({required this.mealId, required this.confirmedKcal, required this.version, this.status = 'confirmed',
      this.flags = const [], this.sD, this.unchanged = false});
  final String mealId;
  final double confirmedKcal;
  final int version;
  final String status;
  final List<String> flags;
  final double? sD;
  final bool unchanged;

  factory ConfirmResult.fromJson(Map<String, dynamic> j) => ConfirmResult(
        mealId: j['meal_id'] as String,
        confirmedKcal: (j['confirmed_kcal'] as num).toDouble(),
        version: (j['version'] as num?)?.toInt() ?? 1,
        status: j['status'] as String? ?? 'confirmed',
        flags: [for (final f in (j['flags'] as List? ?? const [])) f as String],
        sD: (j['s_d'] as num?)?.toDouble(),
        unchanged: j['unchanged'] as bool? ?? false,
      );
}

class SkipResult {
  const SkipResult({required this.remainingWeek, required this.overLimit});
  final int remainingWeek;
  final bool overLimit;
}
