// 건강 연결 화면(P4)을 앱 안(설정 연결 줄·활동 탭 연결 진단)에서 열면 실제 오늘 걸음·출처·동기화 시각을 보이고,
// 온보딩 버튼(시작하기 · 나중에 연결) 대신 '권한 다시 확인'을 준다(#9). 갤럭시 전용 안내는 삼성헬스 출처일 때만(#16).
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/services/health/mock_health_source.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 서버 세션의 마지막 동기화 출처([source], 서버에 기록이 없으면 '—')만 다른 서버
class _Remote extends MockChalloryApi {
  _Remote({this.source = '—'});
  final String source;
  @override
  bool get isRemote => true;
  @override
  Future<List<ChallengeSession>> fetchSessions() async {
    final m = mockChallenge;
    final ch = ChallengeInfo(name: m.name, code: m.code, start: m.start, end: m.end, days: m.days, capacity: m.capacity, joined: m.joined,
        today: m.today, dayIndex: m.dayIndex, syncTime: '—', source: source, platform: m.platform, noticeTitle: '', noticeBody: '',
        noticeDate: '', objectionUntil: m.objectionUntil);
    return [ChallengeSession(challenge: ch, me: mockMe, rules: EngineRules.defaults, status: 'running', challengeId: 'c-1', participantId: 'p-1')];
  }
}

class _Act extends ActivityNotifier {
  _Act(this.a);
  final TodayActivity a;
  @override
  TodayActivity build() => a;
}

List<Override> _remote({TodayActivity? act, bool ios = false, String serverSource = '—'}) => [
      apiProvider.overrideWithValue(_Remote(source: serverSource)),
      authServiceProvider.overrideWithValue(MockAuthService(true)),
      healthSourceProvider.overrideWithValue(MockHealthSource(ios: ios)),
      if (act != null) activityProvider.overrideWith(() => _Act(act)),
    ];

void main() {
  tearDown(resetSession);

  testWidgets('설정 → 연결: 실제 오늘 걸음·출처·동기화 시각, 온보딩 버튼 없음', (tester) async {
    await pumpApp(tester, location: R.p4Check(ok: true),
        overrides: _remote(act: const TodayActivity(stepsTotal: 4321, source: 'Google 피트니스', syncTime: '15:20')));
    expect(find.text('오늘 4,321걸음을 읽었어요 ✓', findRichText: true), findsOneWidget);
    expect(find.text('출처 Google 피트니스 · Health Connect · 15:20'), findsOneWidget);
    expect(find.textContaining('6,210', findRichText: true), findsNothing);
    expect(find.text('시작하기'), findsNothing);
    expect(find.text('나중에 연결 (활동 0으로 집계)'), findsNothing);
    expect(find.text('권한 다시 확인'), findsOneWidget);
  });

  testWidgets('온보딩 P4 는 그대로(연결 · 나중에 연결)', (tester) async {
    await pumpApp(tester, location: R.p4, overrides: _remote());
    expect(find.text('Health Connect 연결'), findsOneWidget);
    expect(find.text('나중에 연결 (활동 0으로 집계)'), findsOneWidget);
    expect(find.text('권한 다시 확인'), findsNothing);
  });

  testWidgets('걸음 없음 · 삼성헬스가 아닌 출처: 갤럭시 전용 안내 대신 일반 안내', (tester) async {
    await pumpApp(tester, location: R.p4Check(ok: false), overrides: _remote(act: const TodayActivity(stepsTotal: 0)));
    expect(find.text('아직 읽은 걸음이 없어요'), findsOneWidget);
    expect(find.textContaining('삼성헬스 → 설정 → Health Connect → 데이터 동기화'), findsNothing);
    expect(find.text('데이터 출처'), findsOneWidget);
    expect(find.text('Health Connect'), findsWidgets, reason: '출처를 모르면 플랫폼 이름');
    expect(find.text('삼성헬스 열기'), findsNothing);
    expect(find.textContaining('걸음을 기록하는 앱'), findsWidgets);
  });

  testWidgets('걸음 없음 · 마지막 출처가 삼성헬스: 삼성헬스 안내', (tester) async {
    await pumpApp(tester, location: R.p4Check(ok: false),
        overrides: _remote(act: const TodayActivity(stepsTotal: 0, source: '삼성헬스', syncTime: '08:10')));
    expect(find.textContaining('삼성헬스 → 설정 → Health Connect'), findsWidgets);
    expect(find.text('삼성헬스 열기'), findsOneWidget);
  });

  testWidgets('걸음 없음 · 이 기기에서 못 읽었지만 서버의 마지막 출처가 삼성헬스: 삼성헬스 안내', (tester) async {
    await pumpApp(tester, location: R.p4Check(ok: false), overrides: _remote(act: const TodayActivity(stepsTotal: 0), serverSource: '삼성헬스'));
    expect(find.text('삼성헬스 열기'), findsOneWidget);
  });

  testWidgets('iPhone: 갤럭시 가이드·삼성헬스 안내가 없다', (tester) async {
    await pumpApp(tester, location: R.p4Check(ok: false), overrides: _remote(act: const TodayActivity(stepsTotal: 0), ios: true));
    expect(find.textContaining('Galaxy'), findsNothing);
    expect(find.textContaining('삼성헬스'), findsNothing);
    expect(find.textContaining('건강 앱'), findsWidgets);
  });

  testWidgets('활동 탭 걸음 0: 출처가 삼성헬스가 아니면 일반 안내', (tester) async {
    await pumpApp(tester, location: R.activity, overrides: _remote(act: const TodayActivity(stepsTotal: 0)));
    expect(find.text('걸음이 0이에요'), findsOneWidget);
    expect(find.textContaining('삼성헬스'), findsNothing);
    expect(find.textContaining('걸음을 기록하는 앱'), findsOneWidget);
  });

  testWidgets('활동 탭 걸음 0: 출처가 삼성헬스면 삼성헬스 안내', (tester) async {
    await pumpApp(tester, location: R.activity, overrides: _remote(act: const TodayActivity(stepsTotal: 0, source: '삼성헬스', syncTime: '08:10')));
    expect(find.textContaining('삼성헬스 → 설정 → Health Connect'), findsOneWidget);
    expect(find.text('삼성헬스 열기'), findsOneWidget);
  });
}
