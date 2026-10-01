import 'health_models.dart';
import 'health_source.dart';

/// 실기기가 아닐 때(데스크톱·웹·테스트) 쓰는 모의 원천.
/// 값은 prototype/data.js 의 TODAY_ACTIVITY 와 장부 D6·D7 걸음을 따른다.
class MockHealthSource implements HealthSource {
  const MockHealthSource({this.ios = false});

  /// true 면 iPhone 변형(기록 9,340 · 수동 340 미인정)
  final bool ios;

  @override
  String get platformLabel => ios ? 'Apple 건강' : 'Health Connect';

  @override
  Future<HealthAvailability> availability() async => HealthAvailability.mock;

  @override
  Future<PermissionResult> requestPermissions() async => PermissionResult.granted;

  @override
  Future<PermissionResult> permissionStatus() async => PermissionResult.granted;

  @override
  Future<List<HealthDay>> fetchDays({DateTime? now}) async {
    final dates = kstWindowDates(now ?? DateTime.now());
    const origin = 'com.sec.android.app.shealth';
    HealthOrigin src() => HealthOrigin(origin: ios ? 'com.apple.health' : origin, method: RecordMethod.automatic);
    final steps = [ios ? 9340 : 9000, 10898, 9000];
    return [
      for (var i = 0; i < 3; i++)
        HealthDay(
          localDate: dates[i],
          stepsTotal: steps[i],
          stepsManual: ios ? (i == 0 ? 340 : 0) : null,
          floors: 0,
          platformActiveKcal: ios ? 310 : null,
          sources: [src()],
        ),
    ];
  }
}
