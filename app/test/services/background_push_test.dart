import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/health/health_models.dart';
import 'package:challory/services/health/health_source.dart';
import 'package:challory/services/push/background_push.dart';
import 'package:challory/services/push/push_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Health implements HealthSource {
  _Health({this.days = const [], this.error});
  final List<HealthDay> days;
  final Object? error;
  int fetches = 0;
  @override
  String get platformLabel => 'Health Connect';
  @override
  Future<HealthAvailability> availability() async => HealthAvailability.ready;
  @override
  Future<PermissionResult> requestPermissions() async => PermissionResult.granted;
  @override
  Future<PermissionResult> permissionStatus() async => PermissionResult.granted;
  @override
  Future<List<HealthDay>> fetchDays({DateTime? now}) async {
    fetches++;
    if (error != null) throw error!;
    return days;
  }
}

class _Api extends MockChalloryApi {
  _Api({this.fail = false});
  final bool fail;
  final batches = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> syncActivity(Map<String, dynamic> batch) async {
    if (fail) throw const ApiException(503, '잠시 뒤 다시 시도해 주세요');
    batches.add(batch);
    return {'ok': true};
  }
}

final _today = [HealthDay(localDate: '2026-10-13', stepsTotal: 8120)];

void main() {
  group('백그라운드 푸시: 걸음 동기화 리마인드(N-02 sync)만 처리', () {
    test('N-02 sync 만 대상이고 confirm·다른 알림은 아님', () {
      expect(isBackgroundStepSync(const PushMessage(data: {'type': 'N-02', 'kind': 'sync'})), isTrue);
      expect(isBackgroundStepSync(const PushMessage(data: {'type': 'N-02', 'kind': 'confirm', 'slot': 'lunch'})), isFalse);
      expect(isBackgroundStepSync(const PushMessage(data: {'type': 'N-04', 'meal_id': 'm1'})), isFalse);
    });

    test('로그인돼 있으면 건강 데이터를 읽어 sync-activity 배치로 올린다', () async {
      final health = _Health(days: _today), api = _Api();
      final r = await syncStepsInBackground(loggedIn: true, health: health, api: api);
      expect(r, BackgroundSyncResult.uploaded);
      expect(api.batches.single['days'], [_today.single.toJson()]);
      expect(api.batches.single['client_batch_id'], isNotEmpty);
    });

    test('로그인이 없으면 읽지도 올리지도 않음', () async {
      final health = _Health(days: _today), api = _Api();
      expect(await syncStepsInBackground(loggedIn: false, health: health, api: api), BackgroundSyncResult.notLoggedIn);
      expect(health.fetches, 0);
      expect(api.batches, isEmpty);
    });

    test('읽은 날이 없으면 올리지 않음', () async {
      final api = _Api();
      expect(await syncStepsInBackground(loggedIn: true, health: _Health(), api: api), BackgroundSyncResult.noData);
      expect(api.batches, isEmpty);
    });

    test('읽기·업로드가 실패해도 예외를 던지지 않고 failed (다음에 앱을 열 때 다시 올림)', () async {
      expect(await syncStepsInBackground(loggedIn: true, health: _Health(error: StateError('권한 없음')), api: _Api()),
          BackgroundSyncResult.failed);
      expect(await syncStepsInBackground(loggedIn: true, health: _Health(days: _today), api: _Api(fail: true)),
          BackgroundSyncResult.failed);
    });
  });
}
