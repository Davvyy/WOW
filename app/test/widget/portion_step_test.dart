// P7 먹은 양: 밥·국·반찬·기타 공통 0.1인분 스테퍼(0.1~3.0)와 ½·1·1.5·2 빠른 칩(D60)
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _ConfirmSpy extends MockChalloryApi {
  List<Map<String, dynamic>>? sent;
  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    sent = items;
    return ConfirmResult(mealId: mealId, confirmedKcal: wireTotal(items), version: version + 1);
  }
}

/// 기본 시드 + 점심에 AI 초안 하나(라면 450)
List<MealRecord> _ramenLunch(List<MealItem> items) => [
      for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
      MealRecord(slot: MealSlot.lunch, status: MealStatus.draft, aiKcal: 450, title: '라면', time: '12:10', serverId: 'm-ramen', version: 1, items: items),
    ];

const _ramen = MealItem(id: 'r', candidates: ['라면'], candKcal: [450], portion: '1인분', kind: ItemKind.side);

Future<_ConfirmSpy> _open(WidgetTester tester, [List<MealItem> items = const [_ramen]]) async {
  final api = _ConfirmSpy();
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-ramen'), overrides: [
    apiProvider.overrideWithValue(api),
    mealsProvider.overrideWith(() => MealsNotifier(_ramenLunch(items))),
  ]);
  return api;
}

Finder _less() => find.byTooltip('덜 먹음');
Finder _more() => find.byTooltip('더 먹음');
Finder _quick(String label) => find.descendant(of: find.byType(ChSeg<int>), matching: find.text(label));

Future<void> _tap(WidgetTester tester, Finder f, [int times = 1]) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('450 kcal 항목: + 두 번 → 1.2인분 · 합계 540, 옛 젓가락 스테퍼는 없다', (tester) async {
    await _open(tester);
    expect(find.text('1.0인분'), findsOneWidget);
    expect(find.textContaining('반찬 1젓가락'), findsNothing);
    await _tap(tester, _more(), 2);
    expect(find.text('1.2인분'), findsOneWidget);
    expect(find.textContaining('확정 · 약 540 kcal'), findsOneWidget);
  });

  testWidgets("'2' 칩 → 900 kcal, 확정하면 portion_multiplier 2.0 · count 1", (tester) async {
    final api = await _open(tester);
    await _tap(tester, _quick('2'));
    expect(find.text('2.0인분'), findsOneWidget);
    expect(find.textContaining('확정 · 약 900 kcal'), findsOneWidget);
    await _tap(tester, find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith('확정')));
    expect(api.sent, hasLength(1));
    expect(api.sent!.single['portion_multiplier'], 2.0);
    expect(api.sent!.single['count'], 1);
  });

  testWidgets("'½' 칩 → 0.5인분, − 는 0.1에서 멈춘다", (tester) async {
    await _open(tester);
    await _tap(tester, _quick('½'));
    expect(find.text('0.5인분'), findsOneWidget);
    await _tap(tester, _less(), 4);
    expect(find.text('0.1인분'), findsOneWidget);
    expect(tester.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.remove_rounded), matching: find.byType(IconButton))).onPressed, isNull);
    await tester.tap(_less(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('0.1인분'), findsOneWidget);
    expect(find.textContaining('확정 · 약 45 kcal'), findsOneWidget);
  });

  testWidgets('+ 는 3.0에서 멈춘다', (tester) async {
    await _open(tester);
    await _tap(tester, _quick('2'));
    await _tap(tester, _more(), 10);
    expect(find.text('3.0인분'), findsOneWidget);
    expect(tester.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.add_rounded), matching: find.byType(IconButton))).onPressed, isNull);
    expect(find.textContaining('확정 · 약 1,350 kcal'), findsOneWidget);
  });

  testWidgets('− / + 버튼은 48 px 이상', (tester) async {
    await _open(tester);
    for (final f in [_less(), _more()]) {
      final size = tester.getSize(f);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('밥은 공기 단위, 국은 국물 토글과 함께 같은 스테퍼', (tester) async {
    await _open(tester, const [
      MealItem(id: 'b', candidates: ['흰쌀밥'], candKcal: [300], portion: '1공기', kind: ItemKind.rice),
      MealItem(id: 's', candidates: ['된장국'], candKcal: [100], portion: '1인분', kind: ItemKind.soup),
    ]);
    expect(find.text('반 공기'), findsNothing);
    expect(find.text('곱빼기'), findsNothing);
    expect(find.text('1.0공기'), findsOneWidget);
    expect(find.text('1.0인분'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ChSwitch && w.label == '국물 안 먹음'), findsOneWidget);
    await _tap(tester, _more().first, 5);
    expect(find.text('1.5공기'), findsOneWidget);
    expect(find.textContaining('확정 · 약 550 kcal'), findsOneWidget);
  });
}
