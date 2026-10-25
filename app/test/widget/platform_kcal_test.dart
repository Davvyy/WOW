// 활동 탭 '플랫폼 활동 칼로리'(참고값·순위 미반영): Android 도 Health Connect 에서 받은 값이 있으면 보여 준다(D74)
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _AndroidWithKcal extends ActivityNotifier {
  @override
  TodayActivity build() => const TodayActivity(stepsTotal: 5046, stepsRecorded: 5046, platformActiveKcal: 177.8, source: '삼성헬스');
}

class _AndroidNoKcal extends ActivityNotifier {
  @override
  TodayActivity build() => const TodayActivity(stepsTotal: 5046, stepsRecorded: 5046, source: '삼성헬스');
}

void main() {
  tearDown(resetSession);

  testWidgets('Android: 받은 활동 칼로리가 있으면 "Health Connect 활동 178 kcal"', (tester) async {
    await pumpApp(tester, location: R.activity, overrides: [activityProvider.overrideWith(_AndroidWithKcal.new)]);
    expect(find.text('Health Connect 활동 178 kcal'), findsOneWidget);
    expect(find.textContaining('제공 안 됨'), findsNothing);
  });

  testWidgets('Android: 받은 값이 없으면 "받은 값 없음"', (tester) async {
    await pumpApp(tester, location: R.activity, overrides: [activityProvider.overrideWith(_AndroidNoKcal.new)]);
    expect(find.text('Health Connect 활동 칼로리 — 받은 값 없음'), findsOneWidget);
  });

  testWidgets('iOS 표시는 그대로: "Apple 건강 활동 310 kcal"', (tester) async {
    await pumpApp(tester, location: R.activity, overrides: [activityProvider.overrideWith(() => _Fixed(mockTodayActivityIos))]);
    expect(find.text('Apple 건강 활동 310 kcal'), findsOneWidget);
  });
}

class _Fixed extends ActivityNotifier {
  _Fixed(this.v);
  final TodayActivity v;
  @override
  TodayActivity build() => v;
}
