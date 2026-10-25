// 이번 주 건너뜀 사용 수: 서버 모드는 프로토타입 값(1)이 아니라 내 장부의 건너뜀 끼니로 센다.
// 서버 skips_used_before 와 같은 규칙(D3): 같은 주(월~일, KST)의 오늘 전 날짜 · 간식 제외 · 하루 최대 skip_per_day · 주 상한 skip_per_week.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart' show ApiException;
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MealInput _skip(MealSlot s) => MealInput(slot: s, status: MealStatus.skipped);
MealInput _ok(MealSlot s) => MealInput(slot: s, status: MealStatus.confirmed, kcal: 500);

LedgerRow _row(String localDate, List<MealInput> meals) => LedgerRow(
      d: 1, date: localDate, steps: 0, bmr: 1600, a: 0, i: 0, dd: 0, s: 0, f: 0, floorApplied: false, substituted: const [],
      check: false, provisional: false, note: '', history: '', health: false, meals: meals, localDate: localDate);

class _Remote extends MockChalloryApi {
  _Remote(this.rows, {this.fail = false});
  final List<LedgerRow> rows;
  final bool fail;
  @override
  bool get isRemote => true;
  @override
  Future<List<LedgerRow>> fetchLedger() async {
    if (fail) throw const ApiException(0, 'offline');
    return rows;
  }
}

/// 세션이 서버 계산값(challenge_session.skips_used_this_week)을 주는 서버
class _SessionSkips extends _Remote {
  _SessionSkips(super.rows, this.skips);
  final int? skips;
  @override
  Future<List<ChallengeSession>> fetchSessions() async => [
        ChallengeSession(challenge: mockChallenge, me: mockMe, rules: EngineRules.defaults, status: 'running', challengeId: 'c-1',
            participantId: 'p-1', skipsUsedThisWeek: skips),
      ];
}

void main() {
  tearDown(resetSession);
  const rules = EngineRules();
  final tue = DateTime(2026, 10, 13); // 화요일 — 이번 주는 10.12(월)부터

  group('skipsUsedThisWeek', () {
    test('같은 주 오늘 전 날짜의 건너뜀만 센다(지난주·오늘·간식 제외)', () {
      final rows = [
        _row('2026-10-11', [_skip(MealSlot.lunch)]), // 지난주 일요일
        _row('2026-10-12', [_skip(MealSlot.breakfast), _ok(MealSlot.lunch)]),
        _row('2026-10-13', [_skip(MealSlot.dinner)]), // 오늘은 오늘 끼니 목록으로 센다
      ];
      expect(skipsUsedThisWeek(rows, today: tue, rules: rules), 1);
    });

    test('하루 최대 skip_per_day 만 인정', () {
      final rows = [
        _row('2026-10-12', [_skip(MealSlot.breakfast), _skip(MealSlot.lunch), _skip(MealSlot.dinner)]),
      ];
      expect(skipsUsedThisWeek(rows, today: tue, rules: rules), 1);
      expect(skipsUsedThisWeek(rows, today: tue, rules: const EngineRules(skipPerDay: 2)), 2);
    });

    test('주 상한 skip_per_week 를 넘지 않는다', () {
      final rows = [
        for (final d in ['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16']) _row(d, [_skip(MealSlot.lunch)]),
      ];
      expect(skipsUsedThisWeek(rows, today: DateTime(2026, 10, 18), rules: rules), 3);
    });

    test('월요일이면 지난주 건너뜀은 0', () {
      final rows = [_row('2026-10-11', [_skip(MealSlot.lunch)])];
      expect(skipsUsedThisWeek(rows, today: DateTime(2026, 10, 12), rules: rules), 0);
    });

    test('간식 건너뜀은 세지 않는다 · 날짜 없는 행(모의 장부)은 건너뛴다', () {
      final rows = [
        _row('2026-10-12', [_skip(MealSlot.snack)]),
        LedgerRow(d: 7, date: '10.12', steps: 0, bmr: 1600, a: 0, i: 0, dd: 0, s: 0, f: 0, floorApplied: false, substituted: const [],
            check: false, provisional: false, note: '', history: '', health: false, meals: [_skip(MealSlot.lunch)]),
      ];
      expect(skipsUsedThisWeek(rows, today: tue, rules: rules), 0);
    });
  });

  group('skipsUsedProvider', () {
    ProviderContainer remote(_Remote api) {
      final c = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        authServiceProvider.overrideWithValue(MockAuthService(true)),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('서버 모드: 건너뜀 기록이 없으면 0(프로토타입 1 이 아님)', () async {
      final c = remote(_Remote([_row('2026-10-12', [_ok(MealSlot.lunch)])]));
      c.listen(skipsUsedProvider, (_, _) {});
      await c.read(ledgerProvider.future);
      expect(curChallenge.today, tue);
      expect(c.read(skipsUsedProvider), 0);
    });

    test('서버 모드: 이번 주 장부의 건너뜀을 센다', () async {
      final c = remote(_Remote([_row('2026-10-12', [_skip(MealSlot.dinner)])]));
      c.listen(skipsUsedProvider, (_, _) {});
      await c.read(ledgerProvider.future);
      expect(c.read(skipsUsedProvider), 1);
    });

    test('서버 모드: 장부를 못 읽으면 0 에서 시작한다(건너뜀 응답의 한도 초과 안내를 믿는다)', () async {
      final c = remote(_Remote(const [], fail: true));
      c.listen(skipsUsedProvider, (_, _) {});
      c.listen(ledgerProvider, (_, _) {});
      for (var i = 0; i < 20 && !c.read(ledgerProvider).hasError; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.read(ledgerProvider).hasError, isTrue);
      expect(c.read(skipsUsedProvider), 0);
    });

    test('서버 모드: 세션이 이번 주 건너뜀 수를 주면 장부를 세지 않고 그 값을 쓴다', () async {
      final c = remote(_SessionSkips([_row('2026-10-12', [_skip(MealSlot.dinner)])], 2));
      c.listen(skipsUsedProvider, (_, _) {});
      await c.read(sessionProvider.future);
      await c.read(ledgerProvider.future);
      expect(c.read(skipsUsedProvider), 2);
    });

    test('서버 모드: 이전 서버(세션에 값 없음)는 장부로 센다', () async {
      final c = remote(_SessionSkips([_row('2026-10-12', [_skip(MealSlot.dinner)])], null));
      c.listen(skipsUsedProvider, (_, _) {});
      await c.read(sessionProvider.future);
      await c.read(ledgerProvider.future);
      expect(c.read(skipsUsedProvider), 1);
    });

    test('모의 모드: 프로토타입 시나리오(이번 주 1회 사용)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(skipsUsedProvider), 1);
    });
  });

  testWidgets('서버 모드 P7: 이번 주 건너뜀을 안 썼으면 "건너뜀 (남은 3회)"', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter(initialLocation: R.meal(MealSlot.dinner));
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(_Remote([_row('2026-10-12', [_ok(MealSlot.dinner)])])),
        authServiceProvider.overrideWithValue(MockAuthService(true)),
      ],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(find.text('건너뜀 (남은 3회)'), findsOneWidget);
    expect(find.text('건너뜀 (남은 2회)'), findsNothing);
  });
}
