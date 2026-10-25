// 활동 탭 '검토 중': 서버 모드는 홈·순위와 같은 서버 값(오늘 순위표 내 행의 under_review)을 쓴다.
// 걸음 25,000 기준 앱 판정은 모의 모드(시나리오)에서만.
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Remote extends MockChalloryApi {
  _Remote({required this.underReview});
  final bool underReview;
  @override
  bool get isRemote => true;
  @override
  Future<Leaderboard> fetchLeaderboard() async => Leaderboard(
        total: 2,
        cumulative: const [LeaderRow(rank: 1, name: '지수', me: true, score: 100)],
        today: [LeaderRow(rank: 1, name: '지수', me: true, score: 20, underReview: underReview), const LeaderRow(rank: 2, name: '민호', score: 10)],
      );
}

class _Steps extends ActivityNotifier {
  _Steps(this.steps);
  final int steps;
  @override
  TodayActivity build() => TodayActivity(stepsTotal: steps, stepsRecorded: steps, source: '삼성헬스', syncTime: '12:00');
}

Future<void> _pump(WidgetTester tester, {MockChalloryApi? api, required int steps}) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(resetSession);
  final router = buildRouter(initialLocation: R.activity);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      if (api != null) apiProvider.overrideWithValue(api),
      authServiceProvider.overrideWithValue(MockAuthService(true)),
      activityProvider.overrideWith(() => _Steps(steps)),
    ],
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('서버 모드: 걸음이 25,000을 넘어도 서버 검토가 없으면 "검토 중"이 아니다', (tester) async {
    await _pump(tester, api: _Remote(underReview: false), steps: 26000);
    expect(find.text('검토 중 · 잠정 유지'), findsNothing);
    expect(find.textContaining('검토 중이에요'), findsNothing);
    expect(find.text('12:00 동기화 · 삼성헬스'), findsOneWidget);
  });

  testWidgets('서버 모드: 서버가 검토 중이면 걸음이 적어도 "검토 중"', (tester) async {
    await _pump(tester, api: _Remote(underReview: true), steps: 8000);
    expect(find.text('검토 중 · 잠정 유지'), findsOneWidget);
  });

  testWidgets('모의 모드: 걸음 25,000 초과는 검토 시나리오', (tester) async {
    await _pump(tester, steps: reviewStepsCase);
    expect(find.text('검토 중 · 잠정 유지'), findsOneWidget);
  });
}
