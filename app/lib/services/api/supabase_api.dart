import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/engine/engine.dart';
import '../../data/mock/mock_data.dart' show Leaderboard;
import '../../data/models.dart';
import '../../state/session.dart' show ChallengeSession, currentSession, isMockSession;
import 'challory_api.dart';
import 'server_mapping.dart';

/// Edge Functions(supabase/functions/*) + PostgREST(RLS) 구현.
class SupabaseChalloryApi implements ChalloryApi {
  SupabaseChalloryApi(this._client);
  final SupabaseClient _client;

  @override
  bool get isRemote => true;

  /// 서버에서 받은 세션의 참가자·챌린지 id. 모의 세션('mock-p' 등)은 서버 uuid 가 아니므로 "없음"으로 본다.
  String? get _myParticipantId => isMockSession(currentSession) ? null : currentSession.participantId;
  String? get _myChallengeId => isMockSession(currentSession) ? null : currentSession.challengeId;

  Future<Map<String, dynamic>> _fn(String name, Object? body, {Map<String, String> headers = const {}, HttpMethod method = HttpMethod.post}) async {
    try {
      final res = await _client.functions.invoke(name, body: body, headers: headers, method: method);
      final d = res.data;
      if (d is Map) return Map<String, dynamic>.from(d);
      if (d is String && d.isNotEmpty) return Map<String, dynamic>.from(jsonDecode(d) as Map);
      return const {};
    } on FunctionException catch (e) {
      final det = e.details;
      final msg = det is Map ? (det['error']?.toString() ?? e.reasonPhrase ?? '') : (det?.toString() ?? e.reasonPhrase ?? '');
      throw ApiException(e.status, msg);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, e.toString()); // 네트워크 단절 등 → 재시도 대상
    }
  }

  Future<Object?> _rpc(String fn, Map<String, dynamic> params) async {
    try {
      return await _client.rpc(fn, params: params);
    } on PostgrestException catch (e) {
      // SQL 함수의 SQLSTATE 'PTnnn' → HTTP nnn (supabase/README.md)
      final m = RegExp(r'^PT(\d{3})$').firstMatch(e.code ?? '');
      throw ApiException(m != null ? int.parse(m.group(1)!) : (e.code == '42501' ? 403 : 500), e.message);
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<InviteSummary?> getInvite(String code) async {
    final j = await _rpc('get_invite', {'p_code': code});
    return j == null ? null : InviteSummary.fromJson(Map<String, dynamic>.from(j as Map));
  }

  @override
  Future<JoinResult> joinChallenge(JoinRequest req) async =>
      JoinResult.fromJson(Map<String, dynamic>.from(await _rpc('join_challenge', {'p': req.toJson()}) as Map));

  @override
  Future<bool> hasParticipation() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final rows = await _client.from('participants').select('id').eq('user_id', uid).not('status', 'in', '(kicked,left)').limit(1);
      return rows.isNotEmpty;
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  /// 로그인 사용자의 현재 참가(가장 최근). 강퇴·탈퇴 제외.
  Future<Map<String, dynamic>> _me() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw const ApiException(401, '로그인이 필요해요');
    // 선택한 챌린지(세션의 참가 행)가 있으면 그 행, 없으면 가장 최근 참가
    final picked = _myChallengeId != null ? _myParticipantId : null;
    var q = _client.from('participants')
        .select('id, nickname, challenge_id, rank_eligible, leaderboard_visible, status, challenges(start_date, status)')
        .eq('user_id', uid).not('status', 'in', '(kicked,left)');
    if (picked != null) q = q.eq('id', picked);
    final row = await q.order('joined_at', ascending: false).limit(1).maybeSingle();
    if (row == null) throw const ApiException(404, '참가 중인 챌린지가 없어요');
    return row;
  }

  Future<Map<String, dynamic>?> _latestSnapshot(String challengeId, String scope) => _client.from('leaderboard_snapshots')
      .select('local_date, as_of, is_final, rows').eq('challenge_id', challengeId).eq('scope', scope)
      .order('as_of', ascending: false).limit(1).maybeSingle();

  @override
  Future<ChallengeSession?> fetchSession() async {
    final j = await _rpc('my_challenge_summary', const {});
    if (j == null) return null;
    return sessionFromSummary(Map<String, dynamic>.from(j as Map),
        platformLabel: defaultTargetPlatform == TargetPlatform.iOS ? 'Apple 건강' : 'Health Connect');
  }

  @override
  Future<List<ChallengeSession>> fetchSessions() async {
    final list = await _rpc('my_challenges', const {}) as List? ?? const [];
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'Apple 건강' : 'Health Connect';
    final out = <ChallengeSession>[];
    for (final item in list) {
      final id = (Map<String, dynamic>.from(item as Map)['challenge'] as Map)['id'] as String;
      final j = await _rpc('challenge_session', {'p_challenge': id});
      if (j != null) out.add(sessionFromSummary(Map<String, dynamic>.from(j as Map), platformLabel: platform));
    }
    return out;
  }

  @override
  Future<List<OpenChallenge>> fetchOpenChallenges() async {
    final list = await _rpc('open_challenges', const {}) as List? ?? const [];
    return [for (final o in list) OpenChallenge.fromJson(Map<String, dynamic>.from(o as Map))];
  }

  @override
  Future<void> leaveChallenge(String challengeId) async {
    await _rpc('leave_challenge', {'p_challenge': challengeId});
  }

  @override
  Future<bool> fetchAutoContinue() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return true;
    try {
      final row = await _client.from('profiles').select('auto_continue').eq('user_id', uid).maybeSingle();
      return row?['auto_continue'] as bool? ?? true;
    } catch (e) {
      throw _pg(e);
    }
  }

  @override
  Future<void> setAutoContinue(bool on) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw const ApiException(401, '로그인이 필요해요');
    try {
      await _client.from('profiles').update({'auto_continue': on}).eq('user_id', uid);
    } catch (e) {
      throw _pg(e, denied: '설정을 바꿀 수 없어요');
    }
  }

  @override
  Future<List<Notice>> fetchNotices() async {
    try {
      final rows = await _client.from('notifications').select('id, title, body, scheduled_at, read_at')
          .eq('type', 'N-03').lte('scheduled_at', DateTime.now().toUtc().toIso8601String())
          .order('scheduled_at', ascending: false).limit(50);
      return [for (final r in rows) noticeFromServer(r)];
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<void> markNoticesRead(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      // RLS: 본인 행만, 컬럼 권한: read_at 만
      await _client.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .inFilter('id', ids).isFilter('read_at', null);
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<List<FoodHit>> searchFoods(String q) async {
    if (q.trim().isEmpty) return const [];
    final rows = await _rpc('food_search', {'q': q.trim()}) as List? ?? const [];
    return [for (final r in rows) foodHitFromServer(Map<String, dynamic>.from(r as Map))];
  }

  @override
  Future<List<FoodHit>> recentFoods() async {
    final rows = await _rpc('recent_foods', const {}) as List? ?? const [];
    return [for (final r in rows) foodHitFromServer(Map<String, dynamic>.from(r as Map), recent: true)];
  }

  /// 테이블 직접 쓰기(RLS) 오류 → ApiException
  ApiException _pg(Object e, {String? conflict, String? denied}) {
    if (e is PostgrestException) {
      if (e.code == '23505') return ApiException(409, conflict ?? '이미 반영됐어요');
      if (e.code == '42501') return ApiException(403, denied ?? '보낼 수 없어요');
      return ApiException(500, e.message);
    }
    return ApiException(0, e.toString());
  }

  String _kstToday() {
    final k = DateTime.now().toUtc().add(const Duration(hours: 9));
    return '${k.year}-${k.month.toString().padLeft(2, '0')}-${k.day.toString().padLeft(2, '0')}';
  }

  @override
  Future<void> sendCheer(String toParticipantId) async {
    final from = _myParticipantId;
    final challenge = _myChallengeId;
    if (from == null || challenge == null) throw const ApiException(422, '챌린지 정보를 아직 불러오지 못했어요');
    try {
      // RLS: 본인 participant 로만, 같은 챌린지 대상, 오늘(KST) 날짜. UNIQUE(from, local_date) = 하루 1회
      await _client.from('cheers').insert({
        'challenge_id': challenge,
        'from_participant_id': from,
        'to_participant_id': toParticipantId,
        'local_date': _kstToday(),
      });
    } catch (e) {
      throw _pg(e, conflict: '오늘은 이미 응원했어요', denied: '응원을 보낼 수 없어요');
    }
  }

  @override
  Future<String?> cheeredToday() async {
    final me = _myParticipantId;
    if (me == null) return null;
    try {
      final row = await _client.from('cheers').select('to_participant_id').eq('from_participant_id', me).eq('local_date', _kstToday()).maybeSingle();
      return row?['to_participant_id'] as String?;
    } catch (e) {
      throw _pg(e);
    }
  }

  @override
  Future<List<MyReview>> fetchMyReviews() async {
    final me = _myParticipantId;
    if (me == null) return const [];
    try {
      final rows = await _client.from('reviews')
          .select('id, type, status, local_date, sla_due_at, reason_template, verdict, message, decided_at, appeals(text)')
          .eq('participant_id', me).order('created_at', ascending: false);
      return [for (final r in rows) myReviewFromServer(r)];
    } catch (e) {
      throw _pg(e);
    }
  }

  @override
  Future<void> submitAppeal(String reviewId, String text) async {
    final me = _myParticipantId;
    try {
      // RLS: 본인 검토 · open · 72h 이내. UNIQUE(review_id) = 1회
      await _client.from('appeals').insert({'review_id': reviewId, 'participant_id': me, 'text': text.trim()});
    } catch (e) {
      throw _pg(e, conflict: '설명은 1회만 남길 수 있어요', denied: '설명 기간이 지났거나 이미 확인이 끝났어요');
    }
  }

  @override
  Future<void> submitObjection(String text) async {
    await _rpc('submit_objection', {'p_text': text});
  }

  @override
  Future<Leaderboard> fetchLeaderboard() async {
    try {
      final me = await _me();
      final cid = me['challenge_id'] as String;
      final today = await _latestSnapshot(cid, 'today');
      final cum = await _latestSnapshot(cid, 'cumulative');
      final scores = await _client.from('daily_scores').select('local_date, s_d, is_final, is_counted, under_review').eq('participant_id', me['id']);
      final todayDate = today?['local_date'] as String?;
      double? myToday;
      var myCum = 0.0;
      var review = false;
      for (final r in scores) {
        if (r['local_date'] == todayDate) myToday = (r['s_d'] as num?)?.toDouble();
        if (r['is_counted'] == true && r['is_final'] == true) myCum += (r['s_d'] as num?)?.toDouble() ?? 0;
        review |= r['under_review'] == true;
      }
      return leaderboardFromServer(
        todayRows: today?['rows'] as List? ?? const [],
        cumulativeRows: cum?['rows'] as List? ?? const [],
        myParticipantId: me['id'] as String,
        myNickname: me['nickname'] as String,
        myToday: myToday,
        myCumulative: double.parse(myCum.toStringAsFixed(1)),
        myUnderReview: review,
        myRankEligible: me['rank_eligible'] == true && me['leaderboard_visible'] == true,
        todayFinal: today?['is_final'] as bool? ?? false,
        asOf: today?['as_of'] == null ? null : DateTime.parse(today!['as_of'] as String),
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<List<LedgerRow>> fetchLedger() async {
    try {
      final me = await _me();
      final start = DateTime.parse((me['challenges'] as Map)['start_date'] as String);
      final rows = await _client.from('daily_scores')
          .select('id, local_date, bmr, a_d, i_d, f_p, d_d, s_d, is_counted, is_final, under_review, breakdown')
          .eq('participant_id', me['id']).order('local_date');
      final ids = [for (final r in rows) r['id'] as String];
      final revs = ids.isEmpty ? <Map<String, dynamic>>[] : await _client.from('score_revisions')
          .select('daily_score_id, prev_s_d, new_s_d, reason, review_id, created_at').inFilter('daily_score_id', ids).order('created_at');
      final reviewIds = {for (final r in revs) if (r['review_id'] != null) r['review_id'] as String};
      final types = <String, String>{};
      if (reviewIds.isNotEmpty) {
        for (final r in await _client.from('reviews').select('id, type').inFilter('id', reviewIds.toList())) {
          types[r['id'] as String] = r['type'] as String;
        }
      }
      return [
        for (final r in rows)
          ledgerRowFromServer(r, start, revisions: [for (final v in revs) if (v['daily_score_id'] == r['id']) v], reviewTypes: types),
      ];
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<PhotoUploadTicket> requestPhotoUpload(PreparedPhoto p, {required String idempotencyKey}) async {
    final j = await _fn('photo-upload-url', {
      'sha256': p.sha256,
      'bytes': p.bytes.length,
      'width': p.width,
      'height': p.height,
      'client_captured_at': p.capturedAt.toUtc().toIso8601String(),
    }, headers: {'Idempotency-Key': idempotencyKey});
    return PhotoUploadTicket(photoId: j['photo_id'] as String, storagePath: j['storage_path'] as String, token: j['token'] as String,
        signedUrl: j['signed_url'] as String?);
  }

  @override
  Future<void> uploadPhoto(PhotoUploadTicket t, Uint8List bytes) async {
    try {
      await _client.storage.from('meal-photos').uploadBinaryToSignedUrl(t.storagePath, t.token, bytes,
          const FileOptions(contentType: 'image/jpeg', upsert: true));
    } on StorageException catch (e) {
      throw ApiException(int.tryParse(e.statusCode ?? '') ?? 0, e.message);
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey}) async =>
      CreatedMeal.fromJson(await _fn('meals', {'photo_id': photoId, 'queued': queued}, headers: {'Idempotency-Key': idempotencyKey}));

  static const _mealCols = 'id, slot, status, version, engine, ai_kcal, confirmed_kcal, captured_at, late_upload, '
      'meal_items(chosen_name, name_candidates, food_code, count, portion_multiplier, has_broth, needs_check, ai_kcal, serving_kcal, '
      'candidate_kcal, candidate_food_codes)';

  @override
  Future<ServerMeal?> fetchMeal(String mealId) async {
    try {
      final row = await _client.from('meals').select(_mealCols).eq('id', mealId).maybeSingle();
      return row == null ? null : ServerMeal.fromJson(row);
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async {
    try {
      final rows = await _client.from('meals').select(_mealCols).eq('local_date', localDate).eq('counted', true)
          .neq('status', 'void').order('captured_at');
      return [for (final r in rows) ServerMeal.fromJson(r)];
    } catch (e) {
      throw ApiException(0, e.toString());
    }
  }

  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async =>
      ConfirmResult.fromJson(await _fn('meal-confirm', {'meal_id': mealId, 'items': items},
          headers: {'Idempotency-Key': idempotencyKey, 'If-Match': '$version'}));

  @override
  Future<SkipResult> skipMeal(String localDate, MealSlot slot, {required String idempotencyKey}) async {
    final j = await _fn('meal-skip', {'local_date': localDate, 'slot': slot.name}, headers: {'Idempotency-Key': idempotencyKey});
    return SkipResult(remainingWeek: (j['remaining_week'] as num?)?.toInt() ?? 0, overLimit: j['over_limit'] as bool? ?? false);
  }

  @override
  Future<ConfirmResult> createManualMeal(MealSlot slot, List<Map<String, dynamic>> items, {String? localDate, required String idempotencyKey}) async =>
      ConfirmResult.fromJson(await _fn('meal-manual', {'slot': slot.name, 'items': items, 'local_date': ?localDate},
          headers: {'Idempotency-Key': idempotencyKey}));

  @override
  Future<Map<String, dynamic>> syncActivity(Map<String, dynamic> batch) =>
      _fn('sync-activity', batch, headers: {'Idempotency-Key': batch['client_batch_id'] as String});

  @override
  Future<void> report({String? participantId, String? mealId, required String reason, required String idempotencyKey}) async {
    if (participantId == null && mealId == null) throw const ApiException(422, '신고 대상을 찾지 못했어요');
    await _fn('reports', {'participant_id': ?participantId, 'meal_id': ?mealId, 'reason': reason}, headers: {'Idempotency-Key': idempotencyKey});
  }

  @override
  Future<void> deleteAccount(String confirm) async {
    await _fn('account', {'confirm': confirm}, method: HttpMethod.delete);
    await _client.auth.signOut();
  }

  @override
  Future<String> registerDevice({String? deviceId, required String platform, String? token, required String permission, String? appVersion}) async {
    final id = await _rpc('register_device', {
      'p_device': deviceId,
      'p_platform': platform,
      'p_token': token,
      'p_permission': permission,
      'p_app_version': appVersion,
    });
    return id as String;
  }

  @override
  Future<void> unregisterDevice(String deviceId) async {
    try {
      await _client.from('devices').delete().eq('id', deviceId);
    } catch (e) {
      throw _pg(e);
    }
  }
}
