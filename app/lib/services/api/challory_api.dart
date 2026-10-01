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
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey});

  /// 끼니 1건 + 초안 항목(분석 완료 확인용)
  Future<ServerMeal?> fetchMeal(String mealId);

  /// 본인 끼니(해당 KST 날짜, RLS 본인 행) — P5 시작 시 서버 상태로 맞춘다
  Future<List<ServerMeal>> fetchMealsOn(String localDate);

  /// API #12 확정(If-Match: version)
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey});

  /// API #13 건너뜀
  Future<SkipResult> skipMeal(String localDate, MealSlot slot, {required String idempotencyKey});

  /// API #10 사진 없는 직접 입력·검색 확정
  Future<ConfirmResult> createManualMeal(MealSlot slot, List<Map<String, dynamic>> items, {String? localDate, required String idempotencyKey});

  /// API #6 활동 배치(client_batch_id = Idempotency-Key)
  Future<Map<String, dynamic>> syncActivity(Map<String, dynamic> batch);

  /// API #19 익명 신고
  Future<void> report({String? participantId, String? mealId, required String reason, required String idempotencyKey});

  /// API #22 계정 삭제(확인 문구 "삭제")
  Future<void> deleteAccount(String confirm);
}

class InviteSummary {
  const InviteSummary({required this.challengeId, required this.name, required this.status, required this.startDate,
      required this.endDate, required this.capacity, required this.joined, required this.days});
  final String challengeId;
  final String name;
  final String status;
  final DateTime startDate;
  final DateTime endDate;
  final int capacity;
  final int joined;
  final int days;

  bool get recruiting => status == 'recruiting';
  bool get full => joined >= capacity;

  factory InviteSummary.fromJson(Map<String, dynamic> j) => InviteSummary(
        challengeId: j['challenge_id'] as String,
        name: j['name'] as String,
        status: j['status'] as String,
        startDate: DateTime.parse(j['start_date'] as String),
        endDate: DateTime.parse(j['end_date'] as String),
        capacity: (j['capacity'] as num).toInt(),
        joined: (j['joined'] as num).toInt(),
        days: (j['days'] as num).toInt(),
      );
}

class JoinRequest {
  const JoinRequest({required this.code, required this.nickname, required this.sex, required this.birthYear, required this.heightCm,
      required this.weightKg, this.pregnancy = false, this.eatingDisorder = false, required this.terms, required this.sensitiveHealth,
      required this.overseasAi});
  final String code;
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
        'code': code,
        'nickname': nickname,
        'sex': sex == Sex.m ? 'M' : 'F',
        'birth_year': birthYear,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'pregnancy': pregnancy,
        'eating_disorder': eatingDisorder,
        'consents': {'terms': terms, 'sensitive_health': sensitiveHealth, 'overseas_ai': overseasAi},
      };
}

class JoinResult {
  const JoinResult({required this.participantId, required this.challengeId, required this.bmr, required this.recordMode});
  final String participantId;
  final String challengeId;
  final int bmr;
  final bool recordMode;

  factory JoinResult.fromJson(Map<String, dynamic> j) => JoinResult(
        participantId: j['participant_id'] as String,
        challengeId: j['challenge_id'] as String,
        bmr: (j['bmr'] as num).toInt(),
        recordMode: j['record_mode'] as bool? ?? false,
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
      required this.portionMultiplier, required this.hasBroth, required this.needsCheck, required this.aiKcal});
  final List<String> candidates;
  final List<double> candidateKcal;
  final List<String?> candidateFoodCodes;
  final int count;
  final double portionMultiplier;
  final bool hasBroth;
  final bool needsCheck;
  final double aiKcal;

  factory ServerMealItem.fromJson(Map<String, dynamic> j) {
    final ai = (j['ai_kcal'] as num?)?.toDouble() ?? 0;
    final chosen = (j['chosen_name'] as String?) ?? ((j['name_candidates'] as List?)?.firstOrNull as String? ?? '음식');
    var cands = [for (final c in (j['name_candidates'] as List? ?? const [])) c as String];
    var kcals = [for (final k in (j['candidate_kcal'] as List? ?? const [])) (k as num).toDouble()];
    var codes = [for (final c in (j['candidate_food_codes'] as List? ?? const [])) c as String?];
    if (kcals.length != cands.length || cands.isEmpty) {
      // 후보 kcal 이 없는 행(구버전·직접 입력): 선택 이름 하나만
      final serving = (j['serving_kcal'] as num?)?.toDouble() ?? ai;
      cands = [chosen];
      kcals = [serving];
      codes = [j['food_code'] as String?];
    }
    return ServerMealItem(
      candidates: cands,
      candidateKcal: kcals,
      candidateFoodCodes: codes.length == cands.length ? codes : List.filled(cands.length, null),
      count: (j['count'] as num?)?.toInt() ?? 1,
      portionMultiplier: (j['portion_multiplier'] as num?)?.toDouble() ?? 1,
      hasBroth: j['has_broth'] as bool? ?? false,
      needsCheck: j['needs_check'] as bool? ?? false,
      aiKcal: ai,
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
