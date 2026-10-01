import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/engine/engine.dart';
import 'challory_api.dart';

/// Edge Functions(supabase/functions/*) + PostgREST(RLS) 구현.
class SupabaseChalloryApi implements ChalloryApi {
  SupabaseChalloryApi(this._client);
  final SupabaseClient _client;

  @override
  bool get isRemote => true;

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
}
