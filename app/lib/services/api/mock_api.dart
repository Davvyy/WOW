import 'dart:typed_data';

import '../../core/engine/engine.dart';
import '../../data/mock/mock_data.dart';
import '../../data/models.dart';
import '../../state/session.dart' show ChallengeSession;
import 'challory_api.dart';

/// 서버 없이 같은 흐름을 돌리는 모의 구현(SUPABASE_URL 미설정 · 테스트).
/// 서버 규칙 중 화면에 보이는 것만 흉내 낸다: 서버 시각 슬롯 태그, 분석 2초 뒤 초안, 버전 증가, 확인 문구.
class MockChalloryApi implements ChalloryApi {
  MockChalloryApi({this.analysisDelay = const Duration(seconds: 2), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration analysisDelay;
  final DateTime Function() _clock;
  final calls = <String>[];
  final _meals = <String, _MockMeal>{};
  var _seq = 0;

  /// 다음 호출을 에 이 오류를 던진다(테스트용: 오프라인 등)
  ApiException? failNext;

  @override
  bool get isRemote => false;

  void _maybeFail(String name) {
    calls.add(name);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  /// 모의 코드: K7Q2MD 유효 · FULL00 모집 마감 · BLOCK0 참가 불가 · 그 외 없음(P1 프로토타입과 같음)
  @override
  Future<InviteSummary?> getInvite(String code) async {
    calls.add('get_invite');
    final ch = mockChallenge;
    InviteSummary s(String status, int joined) => InviteSummary(challengeId: 'mock-challenge', name: ch.name, status: status,
        startDate: ch.start, endDate: ch.end, capacity: ch.capacity, joined: joined, days: ch.days,
        joinable: status == 'recruiting');
    return switch (code.toUpperCase()) {
      'K7Q2MD' => s('recruiting', ch.joined),
      'FULL00' => s('recruiting', ch.capacity),
      'BLOCK0' => s('recruiting', ch.joined), // 재가입 차단은 로그인 뒤 참가 단계에서 거절(사유 미노출)
      _ => null,
    };
  }

  JoinRequest? lastJoin;

  @override
  Future<JoinResult> joinChallenge(JoinRequest req) async {
    _maybeFail('join_challenge');
    lastJoin = req;
    if (!req.terms || !req.sensitiveHealth) throw const ApiException(422, '필수 동의가 필요해요');
    if (req.code == 'BLOCK0') throw const ApiException(403, '참가할 수 없는 챌린지예요');
    final age = mockChallenge.start.year - req.birthYear;
    if (age - 1 < 14) throw const ApiException(422, '만 14세 이상부터 참가할 수 있어요');
    final bmi = req.weightKg / ((req.heightCm / 100) * (req.heightCm / 100));
    final bmr = ChalloryEngine.bmr(Profile(sex: req.sex, weightKg: req.weightKg, heightCm: req.heightCm, age: age)).bmr;
    return JoinResult(participantId: 'mock-participant', challengeId: 'mock-challenge', bmr: bmr,
        recordMode: age - 1 < 19 || bmi < 18.5 || req.pregnancy || req.eatingDisorder);
  }

  bool participating = false;

  @override
  Future<ChallengeSession?> fetchSession() async {
    calls.add('session');
    return ChallengeSession.mock;
  }

  /// 프로토타입 공지 3건(최신이 안 읽음)
  final notices = <Notice>[
    Notice(id: 'n3', title: mockChallenge.noticeTitle, body: mockChallenge.noticeBody, at: DateTime(2026, 10, 12, 18)),
    Notice(id: 'n2', title: '점검 기간이 끝났어요 · 10.9부터 누적 반영', body: '첫 3일 점검 기간이 끝났어요. 10.9부터 점수가 누적에 들어가요.', at: DateTime(2026, 10, 9, 9, 30), read: true),
    Notice(id: 'n1', title: '가을 걷기 챌린지가 시작됐어요', body: '오늘부터 28일 동안 진행돼요. 첫 3일은 점검 기간이에요.', at: DateTime(2026, 10, 6, 9), read: true),
  ];

  @override
  Future<List<Notice>> fetchNotices() async {
    calls.add('notices');
    return List.of(notices);
  }

  @override
  Future<void> markNoticesRead(List<String> ids) async {
    calls.add('notices-read');
    for (var i = 0; i < notices.length; i++) {
      if (ids.contains(notices[i].id)) notices[i] = notices[i].markRead();
    }
  }

  @override
  Future<List<FoodHit>> searchFoods(String q) async {
    calls.add('food_search:$q');
    return [for (final (n, k) in mockFoodDb) if (n.contains(q.trim())) FoodHit(name: n, kcal: k)];
  }

  @override
  Future<List<FoodHit>> recentFoods() async {
    calls.add('recent_foods');
    return [for (final (n, k) in mockFoodDb.take(6)) FoodHit(name: n, kcal: k, recent: true)];
  }

  String? cheeredTo;
  final reviews = <MyReview>[];
  final appeals = <String, String>{};
  String? objection;

  @override
  Future<void> sendCheer(String toParticipantId) async {
    _maybeFail('cheers');
    if (cheeredTo != null) throw const ApiException(409, '오늘은 이미 응원했어요');
    cheeredTo = toParticipantId;
  }

  @override
  Future<String?> cheeredToday() async => cheeredTo;

  @override
  Future<List<MyReview>> fetchMyReviews() async {
    calls.add('reviews');
    return List.of(reviews);
  }

  @override
  Future<void> submitAppeal(String reviewId, String text) async {
    _maybeFail('appeals');
    if (appeals.containsKey(reviewId)) throw const ApiException(422, '설명은 1회만 남길 수 있어요');
    appeals[reviewId] = text;
  }

  @override
  Future<void> submitObjection(String text) async {
    _maybeFail('objection');
    if (objection != null) throw const ApiException(409, '이의는 1회만 남길 수 있어요');
    objection = text;
  }

  @override
  Future<Leaderboard> fetchLeaderboard() async {
    calls.add('leaderboard');
    return mockLeaderboard;
  }

  @override
  Future<List<LedgerRow>> fetchLedger() async {
    calls.add('ledger');
    return mockLedger;
  }

  @override
  Future<bool> hasParticipation() async => participating;

  @override
  Future<PhotoUploadTicket> requestPhotoUpload(PreparedPhoto p, {required String idempotencyKey}) async {
    _maybeFail('photo-upload-url');
    final id = 'photo-${++_seq}';
    return PhotoUploadTicket(photoId: id, storagePath: 'mock/$id.jpg', token: 'mock');
  }

  @override
  Future<void> uploadPhoto(PhotoUploadTicket t, Uint8List bytes) async => _maybeFail('upload');

  @override
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey}) async {
    _maybeFail('meals');
    final id = 'meal-${++_seq}';
    final now = _clock();
    final slot = slotForKst(now);
    _meals[id] = _MockMeal(slot, now);
    return CreatedMeal(mealId: id, slot: slot, localDate: '${now.year}-${now.month}-${now.day}', analyze: true);
  }

  @override
  Future<ServerMeal?> fetchMeal(String mealId) async {
    calls.add('fetchMeal');
    final m = _meals[mealId];
    if (m == null) return null;
    if (_clock().difference(m.createdAt) < analysisDelay) {
      return ServerMeal(id: mealId, status: MealStatus.captured, version: m.version);
    }
    final items = mockDraftItems(m.slot);
    return ServerMeal(
      id: mealId,
      status: MealStatus.draft,
      version: m.version,
      aiKcal: mockAiTotal(m.slot),
      items: [
        for (final it in items)
          ServerMealItem(candidates: it.candidates, candidateKcal: [for (final k in it.candKcal) k.toDouble()],
              candidateFoodCodes: List.filled(it.candidates.length, null), count: it.count, portionMultiplier: it.mult,
              hasBroth: false, needsCheck: false, aiKcal: it.rawKcal),
      ],
    );
  }

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => const []; // 모의 모드는 시드 끼니를 그대로 쓴다

  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    _maybeFail('meal-confirm');
    final m = _meals.putIfAbsent(mealId, () => _MockMeal(MealSlot.lunch, _clock()));
    if (m.version != version) throw const ApiException(412, 'version mismatch');
    m.version++;
    return ConfirmResult(mealId: mealId, confirmedKcal: wireTotal(items), version: m.version);
  }

  @override
  Future<SkipResult> skipMeal(String localDate, MealSlot slot, {required String idempotencyKey}) async {
    _maybeFail('meal-skip');
    return const SkipResult(remainingWeek: 1, overLimit: false);
  }

  @override
  Future<ConfirmResult> createManualMeal(MealSlot slot, List<Map<String, dynamic>> items, {String? localDate, required String idempotencyKey}) async {
    _maybeFail('meal-manual');
    final id = 'meal-${++_seq}';
    _meals[id] = _MockMeal(slot, _clock())..version = 2;
    return ConfirmResult(mealId: id, confirmedKcal: wireTotal(items), version: 2);
  }

  @override
  Future<Map<String, dynamic>> syncActivity(Map<String, dynamic> batch) async {
    _maybeFail('sync-activity');
    return {'days': const []};
  }

  @override
  Future<void> report({String? participantId, String? mealId, required String reason, required String idempotencyKey}) async =>
      _maybeFail('reports');

  @override
  Future<void> deleteAccount(String confirm) async {
    _maybeFail('account');
    if (confirm != '삭제') throw const ApiException(422, '확인을 위해 "삭제"를 입력해 주세요');
  }
  /// 등록된 기기(id → 토큰·권한). 테스트가 확인한다.
  final devices = <String, ({String platform, String? token, String permission})>{};

  @override
  Future<String> registerDevice({String? deviceId, required String platform, String? token, required String permission, String? appVersion}) async {
    _maybeFail('register_device');
    final id = deviceId != null && devices.containsKey(deviceId) ? deviceId : 'mock-device-${++_seq}';
    devices[id] = (platform: platform, token: token, permission: permission);
    return id;
  }

  @override
  Future<void> unregisterDevice(String deviceId) async {
    _maybeFail('unregister_device');
    devices.remove(deviceId);
  }
}

class _MockMeal {
  _MockMeal(this.slot, this.createdAt);
  final MealSlot slot;
  final DateTime createdAt;
  int version = 1;
}

/// 서버 confirm_meal 과 같은 합계(국물 ×0.6, 먹은 것만)
double wireTotal(List<Map<String, dynamic>> items) {
  var t = 0.0;
  for (final i in items) {
    if (i['eaten'] == false) continue;
    var k = (i['serving_kcal'] as num).toDouble() * (i['portion_multiplier'] as num? ?? 1).toDouble() * (i['count'] as num? ?? 1).toDouble();
    if (i['broth_off'] == true) k *= EngineRules.defaults.brothFactor;
    t += k;
  }
  return (t * 10 + 0.5).floorToDouble() / 10;
}

/// 서버 slot_for 와 같은 KST 경계(04:00 / 10:30 / 15:00 / 22:00)
MealSlot slotForKst(DateTime t) {
  final k = t.toUtc().add(const Duration(hours: 9));
  final m = k.hour * 60 + k.minute;
  if (m >= 4 * 60 && m < 10 * 60 + 30) return MealSlot.breakfast;
  if (m >= 10 * 60 + 30 && m < 15 * 60) return MealSlot.lunch;
  if (m >= 15 * 60 && m < 22 * 60) return MealSlot.dinner;
  return MealSlot.snack;

}
