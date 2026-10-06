// P7 표시 오류: 가정 분량은 지금 먹은 양을 따른다(0 g 은 숨김) · 먹은 양 줄이 스테퍼와 겹치지 않는다 ·
// 이미 반영된 끼니에는 건너뜀·건너뜀 한도 안내가 없다 · 요약에서 0개인 부분은 뺀다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 이번 주 건너뜀 3회를 모두 쓴 상태
class _AllSkipsUsed extends SkipsNotifier {
  @override
  int build() => 3;
}

const _apple = MealItem(id: 'a', candidates: ['사과', '조각사과', '과일'], candKcal: [113, 147, 113], portion: '1인분', kind: ItemKind.side, mult: 1.5);

/// 기본 시드 + 점심 [lunch] 하나
List<MealRecord> _withLunch(MealRecord lunch) => [
      for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
      lunch,
    ];

MealRecord _appleLunch({MealStatus status = MealStatus.confirmed, List<MealItem> items = const [_apple]}) => MealRecord(
    slot: MealSlot.lunch, status: status, kcal: status == MealStatus.draft ? 0 : 170, aiKcal: 113, title: '사과', time: '11:36', serverId: 'm-apple', items: items);

Future<void> _open(WidgetTester tester, MealRecord lunch, {double width = 420}) async {
  tester.view.physicalSize = Size(width, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(initialLocation: R.meal(MealSlot.lunch, meal: lunch.key));
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mealsProvider.overrideWith(() => MealsNotifier(_withLunch(lunch))),
      skipsUsedProvider.overrideWith(_AllSkipsUsed.new),
    ],
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

Finder _skipButton() => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith('건너뜀'));

void main() {
  group('A1 가정 분량', () {
    testWidgets('1.5인분이면 "1.5인분", 무게를 모르면 g 을 쓰지 않는다', (tester) async {
      await _open(tester, _appleLunch());
      expect(find.text('가정 분량 · 1.5인분'), findsOneWidget);
      expect(find.textContaining('약 0 g'), findsNothing);
    });

    testWidgets('스테퍼를 바꾸면 가정 분량도 바뀐다', (tester) async {
      await _open(tester, _appleLunch(status: MealStatus.draft));
      await tester.tap(find.byTooltip('더 먹음'));
      await tester.pumpAndSettle();
      expect(find.text('가정 분량 · 1.6인분'), findsOneWidget);
    });

    testWidgets('밥은 공기 단위와 먹은 양만큼의 무게', (tester) async {
      await _open(tester, _appleLunch(status: MealStatus.draft, items: const [
        MealItem(id: 'b', candidates: ['흰쌀밥'], candKcal: [310], portion: '1공기', kind: ItemKind.rice, grams: 210, mult: 1.5),
        MealItem(id: 's', candidates: ['김치찌개'], candKcal: [260], portion: '1인분', kind: ItemKind.soup, grams: 0),
      ]));
      expect(find.text('가정 분량 · 1.5공기 · 약 315 g'), findsOneWidget);
      expect(find.text('가정 분량 · 1인분'), findsOneWidget);
    });
  });

  testWidgets('A2 360dp: 먹은 양 줄과 스테퍼가 겹치지 않고 넘치지 않는다', (tester) async {
    await _open(tester, _appleLunch(), width: 360);
    expect(tester.takeException(), isNull);
    final label = tester.getRect(find.text('먹은 양 · 0.1인분 단위'));
    final pill = find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).border != null);
    final stepper = tester.getRect(find.ancestor(of: find.byTooltip('더 먹음'), matching: pill).first);
    expect(label.overlaps(stepper), isFalse, reason: '$label vs $stepper');
    expect(label.bottom, lessThanOrEqualTo(stepper.top), reason: '이름 줄은 스테퍼 위 따로 한 줄');
    expect(label.right, lessThanOrEqualTo(360));
  });

  group('A3 이미 반영된 끼니', () {
    for (final s in [MealStatus.confirmed, MealStatus.auto, MealStatus.corrected]) {
      testWidgets('$s: 건너뜀 버튼과 한도 안내가 없다', (tester) async {
        await _open(tester, _appleLunch(status: s));
        expect(_skipButton(), findsNothing);
        expect(find.textContaining('이번 주 건너뜀'), findsNothing);
      });
    }

    testWidgets('초안 끼니는 지금처럼 건너뜀 버튼(한도면 꺼짐)과 안내', (tester) async {
      await _open(tester, _appleLunch(status: MealStatus.draft));
      expect(_skipButton(), findsOneWidget);
      expect(find.textContaining('이번 주 건너뜀 3회를 모두 썼어요'), findsOneWidget);
    });
  });

  testWidgets('A4 요약: 0개인 부분은 뺀다', (tester) async {
    await _open(tester, _appleLunch());
    expect(find.text('AI 초안 약 113 · 1개 확실'), findsOneWidget);
    expect(find.textContaining('0개'), findsNothing);
  });
}
